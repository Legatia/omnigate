//! Talks to the Elixir control plane: pulls config snapshots, pushes usage.
//!
//! A control-plane outage must never take the gateway down: every failure
//! here is logged and the data plane keeps serving its last good snapshot.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const config = @import("config.zig");
const framing = @import("framing.zig");
const App = @import("main.zig").App;

const log = std.log.scoped(.control);

pub const internal_header = "x-omnigate-internal";

/// No answer from the control plane is larger than this (a config snapshot
/// with tens of thousands of keys is a few megabytes).
const max_response_bytes = 256 * 1024 * 1024;

/// One request to the control plane, given up with `error.ControlTimeout`
/// after `call_timeout_ms`.
///
/// Deliberately not `http.Client.fetch`: in Zig 0.17 it unwraps
/// `response.bodyErr().?` and panics when a pooled keep-alive connection was
/// reset by the peer. We also skip the connection pool (`keep_alive = false`)
/// so a restarted control plane never leaves us holding a dead socket.
fn call(app: *App, method: http.Method, path: []const u8, payload: ?[]const u8, out: ?*Io.Writer) anyerror!http.Status {
    const Race = union(enum) {
        done: anyerror!http.Status,
        timer: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var race: Io.Select(Race) = .init(app.io, &results);

    // No spare concurrency: better an untimed call than none.
    race.concurrent(.done, callUntimed, .{ app, method, path, payload, out }) catch return callUntimed(app, method, path, payload, out);
    race.concurrent(.timer, sleepMs, .{ app.io, call_timeout_ms.load(.acquire) }) catch {};

    const first = race.await() catch |err| {
        race.cancelDiscard();
        return err;
    };
    switch (first) {
        .done => |result| {
            race.cancelDiscard();
            return result;
        },
        .timer => {
            // Cancel the exchange; if it finished in the meantime, use it.
            var late: ?http.Status = null;
            while (race.cancel()) |leftover| switch (leftover) {
                .done => |result| {
                    if (result) |status| {
                        late = status;
                    } else |_| {}
                },
                .timer => {},
            };
            return late orelse error.ControlTimeout;
        },
    }
}

/// How long one request to the control plane may take, connecting included.
/// Without a limit, an address that swallows packets (a host that is down
/// behind a firewall that drops) held the caller for as long as the
/// operating system keeps trying: at start that was before the listener
/// opened, so a data plane with a good cached config served nothing for
/// minutes; later it stopped the config poll or the usage reporter.
pub const default_call_timeout_ms: u32 = 10_000;
/// The limit in force. Shortened once, at shutdown, for the last attempts to
/// hand over usage and counters (`shutdown_call_timeout_ms`): a stop must not
/// wait ten seconds twice for a control plane that is not there.
pub var call_timeout_ms: std.atomic.Value(u32) = .init(default_call_timeout_ms);
pub const shutdown_call_timeout_ms: u32 = 2_000;

fn sleepMs(io: Io, ms: u32) Io.Cancelable!void {
    return io.sleep(.fromMilliseconds(ms), .awake);
}

fn callUntimed(app: *App, method: http.Method, path: []const u8, payload: ?[]const u8, out: ?*Io.Writer) anyerror!http.Status {
    const url = try std.fmt.allocPrint(app.gpa, "{s}{s}", .{ app.control_url, path });
    defer app.gpa.free(url);
    const uri = try std.Uri.parse(url);

    const extra = [_]http.Header{.{ .name = internal_header, .value = app.internal_token }};
    var req = try app.client.request(method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = if (payload != null) .{ .override = "application/json" } else .default,
            .accept_encoding = .{ .override = "identity" },
            .user_agent = .{ .override = @import("main.zig").user_agent },
        },
        .extra_headers = &extra,
    });
    // The response body is read here, never by std, and the connection is
    // closed unless the exchange is proven complete (see framing.finish).
    var head_received = false;
    defer framing.finish(&req, head_received);

    if (payload) |p| {
        req.transfer_encoding = .{ .content_length = p.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(p);
        try body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var response = try req.receiveHead(&.{});
    head_received = true;
    const status = response.head.status;

    // The control plane is ours, but what answers on its address is still
    // a network peer: its body is read with the same bounded reader as an
    // upstream's, and a body that ends early is a failed call.
    var body = try framing.takeBody(&req, &response);
    var chunk: [16 * 1024]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = try body.read(&chunk);
        if (n == 0) break;
        total += n;
        if (total > max_response_bytes) return error.ResponseTooLarge;
        if (out) |w| try w.writeAll(chunk[0..n]);
    }
    return status;
}

/// Fetch `/internal/config` and install it if its version changed.
pub fn syncOnce(app: *App) !void {
    var body: Io.Writer.Allocating = .init(app.gpa);
    defer body.deinit();

    const status = try call(app, .GET, "/internal/config", null, &body.writer);
    if (status != .ok) {
        log.warn("config fetch returned {d}", .{@backingInt(status)});
        return error.BadStatus;
    }
    // The control plane answered with a config: what it says about attested
    // targets is confirmed as of now (see `syncedAgoMs`).
    app.config_synced_ms.store(Io.Timestamp.now(app.io, .awake).toMilliseconds(), .release);
    if (try install(app, body.written())) saveCache(app, body.written());
}

/// Milliseconds since the control plane last answered a config poll, or null
/// when it has not in this process (the config then comes from the cache
/// file). An attestation verdict in the snapshot only counts while this is
/// recent: see `config.Attestation.holds`.
pub fn syncedAgoMs(app: *App) ?i64 {
    const at = app.config_synced_ms.load(.acquire);
    if (at == never_synced) return null;
    return Io.Timestamp.now(app.io, .awake).toMilliseconds() - at;
}

pub const never_synced: i64 = std.math.minInt(i64);

/// Parse a snapshot and make it current. Returns false when it is the
/// version already being served.
fn install(app: *App, bytes: []const u8) !bool {
    const gpa = app.gpa;
    const parsed = try gpa.create(config.Parsed);
    errdefer gpa.destroy(parsed);
    parsed.* = try config.parse(gpa, bytes);

    if (app.store.currentVersion(app.io)) |v| {
        if (std.mem.eql(u8, v, parsed.value.version)) {
            parsed.deinit();
            gpa.destroy(parsed);
            return false;
        }
    }
    log.info("installed config version {s} ({d} routes, {d} keys)", .{
        parsed.value.version, parsed.value.routes.len, parsed.value.keys.len,
    });
    try app.store.install(app.io, gpa, parsed);
    return true;
}

/// Start from the last snapshot the control plane gave us, so a data plane
/// that restarts during a control-plane outage still serves traffic. The
/// snapshot holds key hashes and routes, never secrets.
pub fn loadCache(app: *App) !void {
    const path = app.config_cache_path orelse return error.CacheDisabled;
    const bytes = try Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(64 * 1024 * 1024));
    defer app.gpa.free(bytes);
    _ = try install(app, bytes);
}

/// Best effort: a cache that cannot be written only costs the restart case.
fn saveCache(app: *App, bytes: []const u8) void {
    const path = app.config_cache_path orelse return;
    const cwd = Io.Dir.cwd();
    const tmp = std.fmt.allocPrint(app.gpa, "{s}.tmp", .{path}) catch return;
    defer app.gpa.free(tmp);
    // Write beside it, then rename, so a crash never leaves half a snapshot.
    cwd.writeFile(app.io, .{ .sub_path = tmp, .data = bytes }) catch |err| {
        log.warn("cannot write config cache {s}: {t}", .{ tmp, err });
        return;
    };
    cwd.rename(tmp, cwd, path, app.io) catch |err| {
        log.warn("cannot move config cache into place at {s}: {t}", .{ path, err });
    };
}

/// Background task: poll for config changes (budgets flip keys to blocked).
pub fn pollLoop(app: *App) Io.Cancelable!void {
    var healthy = true;
    while (true) {
        try app.io.sleep(.fromMilliseconds(app.poll_interval_ms), .awake);
        if (syncOnce(app)) |_| {
            if (!healthy) log.info("control plane reachable again", .{});
            healthy = true;
        } else |err| {
            // A cancellation is delivered once. Taken for an ordinary failure
            // here, the loop would sleep again and never end: the data plane
            // then never finished stopping when its control plane was slow
            // to refuse or to answer.
            if (err == error.Canceled) return error.Canceled;
            // Log once per outage, not every poll.
            if (healthy) log.warn("config sync failed ({t}); serving last good config", .{err});
            healthy = false;
        }
    }
}

pub const BatchOutcome = enum {
    /// Recorded (or recognised as duplicates). Safe to forget the events.
    accepted,
    /// The control plane says the batch itself is unacceptable; resending
    /// the same bytes cannot succeed.
    rejected,
};

/// POST the rejection counters (see counters.zig). An error means the control
/// plane did not take them, for whatever reason, and they should be kept.
pub fn postCounters(app: *App, body: []const u8) !void {
    const status = try call(app, .POST, "/internal/counters", body, null);
    if (status != .ok) return error.BadStatus;
}

/// POST what this data plane allowed its rate-limited keys and read what the
/// others allowed into `out` (see limitsync.zig). An error means the control
/// plane did not take the report.
pub fn postLimitSync(app: *App, body: []const u8, out: *Io.Writer) !void {
    const status = try call(app, .POST, "/internal/limits/sync", body, out);
    if (status != .ok) return error.BadStatus;
}

/// POST a `{"events":[...]}` usage batch. An error means "try again later".
pub fn postUsageBatch(app: *App, body: []const u8) !BatchOutcome {
    const status = try call(app, .POST, "/internal/usage/batch", body, null);
    return switch (status) {
        .ok => .accepted,
        .bad_request, .payload_too_large, .unprocessable_entity => .rejected,
        // 401 (token mismatch), 5xx, anything else: keep the events and retry.
        else => error.BadStatus,
    };
}
