//! Talks to the Elixir control plane: pulls config snapshots, pushes usage.
//!
//! A control-plane outage must never take the gateway down: every failure
//! here is logged and the data plane keeps serving its last good snapshot.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const config = @import("config.zig");
const App = @import("main.zig").App;

const log = std.log.scoped(.control);

pub const internal_header = "x-omnigate-internal";

/// One request to the control plane.
///
/// Deliberately not `http.Client.fetch`: in Zig 0.17 it unwraps
/// `response.bodyErr().?` and panics when a pooled keep-alive connection was
/// reset by the peer. We also skip the connection pool (`keep_alive = false`)
/// so a restarted control plane never leaves us holding a dead socket.
fn call(app: *App, method: http.Method, path: []const u8, payload: ?[]const u8, out: ?*Io.Writer) !http.Status {
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
            .user_agent = .{ .override = "omnigate/0.1" },
        },
        .extra_headers = &extra,
    });
    defer req.deinit();

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
    const status = response.head.status;

    var transfer_buf: [64]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    if (out) |w| {
        _ = reader.streamRemaining(w) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            else => |e| return e,
        };
    } else {
        _ = reader.discardRemaining() catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        };
    }
    return status;
}

/// Fetch `/internal/config` and install it if its version changed.
pub fn syncOnce(app: *App) !void {
    const gpa = app.gpa;

    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    const status = try call(app, .GET, "/internal/config", null, &body.writer);
    if (status != .ok) {
        log.warn("config fetch returned {d}", .{@backingInt(status)});
        return error.BadStatus;
    }

    const parsed = try gpa.create(config.Parsed);
    errdefer gpa.destroy(parsed);
    parsed.* = try config.parse(gpa, body.written());

    if (app.store.currentVersion(app.io)) |v| {
        if (std.mem.eql(u8, v, parsed.value.version)) {
            parsed.deinit();
            gpa.destroy(parsed);
            return;
        }
    }
    log.info("installed config version {s} ({d} routes, {d} keys)", .{
        parsed.value.version, parsed.value.routes.len, parsed.value.keys.len,
    });
    try app.store.install(app.io, gpa, parsed);
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
