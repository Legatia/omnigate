//! omnigate data plane: OpenAI/Anthropic-compatible streaming proxy.
//!
//!   omnigate-dp               serve
//!   omnigate-dp healthcheck   ask the instance configured by OMNIGATE_LISTEN
//!                             for /healthz; exit 0 if it answers 200 within
//!                             three seconds, else 1 (for container health
//!                             checks: the image has no shell and no curl)
//!
//! Environment:
//!   OMNIGATE_LISTEN          host:port to listen on        (default 127.0.0.1:8080)
//!   OMNIGATE_CONTROL_URL     control plane base URL        (default http://127.0.0.1:4000)
//!   OMNIGATE_INTERNAL_TOKEN  shared secret for /internal/* (required; an
//!                            empty value counts as not set)
//!   OMNIGATE_POLL_MS         config poll interval in ms    (default 2000)
//!   OMNIGATE_FLUSH_MS        usage flush interval in ms    (default 500)
//!   OMNIGATE_UPSTREAM_TIMEOUT_MS  max wait for upstream response headers
//!                            (default 600000; 0 = no limit; an upstream's
//!                            `timeout_ms` in the config overrides it)
//!   OMNIGATE_COOLDOWN_FAILURES  consecutive failures before an upstream is
//!                            tried last (default 5; 0 disables)
//!   OMNIGATE_COOLDOWN_MS     how long it stays that way (default 30000)
//!   OMNIGATE_SPOOL           usage spool file              (default omnigate-usage.spool;
//!                            set to "off" for memory-only)
//!   OMNIGATE_CONFIG_CACHE    last config from the control plane, reused when
//!                            starting while it is down (default
//!                            omnigate-config.cache.json; "off" disables)
//!   OMNIGATE_CLIENT_TIMEOUT_MS  how long a client may take to send a request
//!                            (head and body), and how long an idle keep-alive
//!                            connection is kept (default 30000; 0 = no limit)
//!   OMNIGATE_STREAM_IDLE_TIMEOUT_MS  give up on an upstream that has sent
//!                            its response head and then sends nothing for
//!                            this long: a response being streamed is cut
//!                            off; one of which nothing has reached the
//!                            client yet goes to the next upstream instead
//!                            (default 300000; 0 = no limit)
//!   OMNIGATE_CLIENT_STALL_TIMEOUT_MS  give up on a client that takes none of
//!                            a response for this long while staying
//!                            connected. That is every response written
//!                            after the request was read: a relayed answer
//!                            (the upstream is then read to its end without
//!                            the client, as for one that left), a file, and
//!                            the gateway's own answers (errors, the model
//!                            list, cache hits). A refusal sent before the
//!                            request body was read is under the client
//!                            timeout (default 30000; 0 = use the stream
//!                            idle timeout)
//!   OMNIGATE_MAX_CONNECTIONS  client connections served at once; further ones
//!                            get an immediate 503 (default 4096)
//!   OMNIGATE_MAX_CONCURRENT_PER_KEY  requests one gateway key may have in
//!                            flight at once; further ones get 429 (default
//!                            512; 0 = no cap; a key's `max_concurrent` in the
//!                            config overrides it)
//!   OMNIGATE_REQUEST_MEMORY_MB  memory all request bodies in flight may take
//!                            together (each counted twice: as received and as
//!                            sent on); one key may hold a quarter of it.
//!                            Beyond it requests get 503, or 429 for the key's
//!                            share (default 1024; 0 = no cap)
//!   OMNIGATE_PARSE_MEMORY_MB  memory that may be reserved at once for
//!                            parsing JSON into trees, which only translation
//!                            between protocols, the response cache and
//!                            rewriting an existing stream_options need. One
//!                            tree may take 128 times its text plus 1 MiB, at
//!                            most 96 MiB (a request that needs more gets
//!                            400); one key may reserve half the budget.
//!                            Beyond it requests get 503, or 429 for the
//!                            key's share (default 1024; 0 = no budget, the
//!                            per-tree cap still applies)
//!   OMNIGATE_ABORT_DRAIN_MS  when a client leaves (or stalls) mid-stream, the
//!                            upstream is read on without it to learn the
//!                            final usage; after this long it is cut off and
//!                            an estimate is billed (default 120000; 0 = bill
//!                            the estimate at once)
//!   OMNIGATE_ABORT_DRAIN_MAX_MB  ... or after this much more of the answer
//!                            (default 64)
//!   OMNIGATE_SHUTDOWN_GRACE_MS  on SIGINT/SIGTERM (Ctrl-C/Ctrl-Break on
//!                            Windows): how long requests in flight may take
//!                            to finish before the process exits (default 10000)
//!   OMNIGATE_CACHE_MAX_MB    memory for the response cache used by routes
//!                            that set `cache_ttl_s` (default 64; 0 = off)
//!   OMNIGATE_LOG_LEVEL       debug | info | warn | error   (default info)
//!   OMNIGATE_LOG_FORMAT      text | json                   (default text)
//!   <api_key_env>            provider keys named by each upstream in the config

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const balance = @import("balance.zig");
const cache = @import("cache.zig");
const config = @import("config.zig");
const control = @import("control.zig");
const counters = @import("counters.zig");
const health = @import("health.zig");
const limits = @import("limits.zig");
const logging = @import("logging.zig");
const proxy = @import("proxy.zig");
const quirks = @import("quirks.zig");
const ratelimit = @import("ratelimit.zig");
const reporter = @import("reporter.zig");
const watchdog = @import("watchdog.zig");

const log = std.log.scoped(.main);

/// From `build.zig.zon`, by way of `build.zig`.
pub const version = @import("build_options").version;
/// What the gateway calls itself to upstreams and to the control plane.
pub const user_agent = "omnigate/" ++ version;

/// Exit status after a panic, so a supervisor can tell it from a clean stop
/// (0) and from a startup error (1). 70 is sysexits' EX_SOFTWARE.
pub const panic_exit_code = 70;

/// Last line of defence. Input is validated so that it cannot reach a panic
/// (see guard.zig), but a panic in any task ends the whole process, so if
/// one ever happens it must at least be visible and restartable: one log
/// line in the configured format, then exit with `panic_exit_code`. Nothing
/// is flushed here on purpose: usage events are appended to the spool file as
/// they are queued, so they are already with the operating system and are
/// delivered after the restart. What a panic does lose is whatever had not
/// become an event yet (requests still in flight) and the refusal counters
/// since their last flush; with OMNIGATE_SPOOL=off, also the unsent queue.
///
/// Debug builds keep std's handler, whose stack trace is worth more there.
pub const panic = std.debug.FullPanic(if (@import("builtin").mode == .debug) std.debug.defaultPanic else panicExit);

fn panicExit(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    _ = first_trace_addr;
    logging.panicLine(msg);
    std.process.exit(panic_exit_code);
}

/// Every level is compiled in; `logging` filters at run time.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
    // In debug builds std prints a stack trace for every OS status it has no
    // error name for. On Windows that includes a write to a client that has
    // hung up (LOCAL_DISCONNECT, PIPE_DISCONNECTED), which for a proxy is
    // routine; under load the traces swamp the log and stall the workers.
    .unexpected_error_tracing = false,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    client: *std.http.Client,
    store: *config.Store,
    reporter: *reporter.Reporter,
    limiter: *ratelimit.Limiter,
    health: *health.Health,
    balancer: *balance.Counters,
    quirks: *quirks.Quirks,
    watchdog: *watchdog.Watchdog,
    /// Requests refused before routing, by key and reason.
    counters: *counters.Counters,
    /// Answers remembered for routes that opt in with `cache_ttl_s`.
    cache: *cache.Cache,
    /// Per-key concurrency, request memory and tree memory (see limits.zig).
    gate: *limits.Gate,
    /// Upstream answers being read to their end after their client left.
    drains: *proxy.Drains,
    /// Client connections being served right now.
    active_connections: std.atomic.Value(u32) = .init(0),
    /// Set once a stop was requested: finish what is in flight, start nothing new.
    shutting_down: std.atomic.Value(bool) = .init(false),
    env: *const std.process.Environ.Map,
    control_url: []const u8,
    internal_token: []const u8,
    poll_interval_ms: i64,
    flush_interval_ms: i64,
    upstream_timeout_ms: u32,
    client_timeout_ms: u32,
    stream_idle_timeout_ms: u32,
    /// How long one write to a client may take nothing (never 0).
    client_stall_timeout_ms: u32,
    abort_drain_ms: u32,
    abort_drain_max_bytes: u64,
    max_connections: u32,
    config_cache_path: ?[]const u8,
    /// When this process started (Unix seconds); reported as the creation
    /// time of every model in `/v1/models`.
    started_unix_s: i64,
};

// ---------------------------------------------------------------------------
// stop signals
// ---------------------------------------------------------------------------

/// Set from a signal handler (POSIX) or the console control thread (Windows).
var stop_requested: std.atomic.Value(bool) = .init(false);

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (ctrl_type: u32) callconv(.winapi) c_int,
    add: c_int,
) callconv(.winapi) c_int;

fn consoleCtrlHandler(ctrl_type: u32) callconv(.winapi) c_int {
    // CTRL_C, CTRL_BREAK, CTRL_CLOSE, CTRL_LOGOFF, CTRL_SHUTDOWN all mean "stop".
    _ = ctrl_type;
    stop_requested.store(true, .release);
    return 1; // handled: do not kill the process now
}

fn posixStopHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    stop_requested.store(true, .release);
}

/// SIGINT and SIGTERM (Ctrl-C, Ctrl-Break, console close on Windows) ask for
/// a graceful stop. As PID 1 in a container a process gets no default signal
/// actions at all, so without this `docker stop` would wait for its kill
/// timeout.
fn installStopHandlers() void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleCtrlHandler(&consoleCtrlHandler, 1);
    } else {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = posixStopHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TERM, &act, null);
        std.posix.sigaction(.INT, &act, null);
    }
}

/// Background task: notices the stop request, then wakes the accept loop,
/// which is blocked in `accept`, by connecting to it.
fn stopWatcher(app: *App, wake: Io.net.IpAddress) Io.Cancelable!void {
    while (!stop_requested.load(.acquire)) {
        try app.io.sleep(.fromMilliseconds(100), .awake);
    }
    app.shutting_down.store(true, .release);
    if (wake.connect(app.io, .{ .mode = .stream })) |s| s.close(app.io) else |_| {}
}

fn watchdogTask(app: *App) Io.Cancelable!void {
    return app.watchdog.run(app.io);
}

// Sent before the request is read, so the client's protocol is unknown: the
// OpenAI shape, which is also the gateway's default (see errors.zig).
const overloaded_body = "{\"error\":{\"message\":\"too many connections; try again shortly\",\"type\":\"server_error\",\"param\":null,\"code\":\"overloaded\"}}";
const overloaded_response = std.fmt.comptimePrint(
    "HTTP/1.1 503 Service Unavailable\r\ncontent-type: application/json\r\nretry-after: 1\r\nconnection: close\r\ncontent-length: {d}\r\n\r\n{s}",
    .{ overloaded_body.len, overloaded_body },
);

/// Over the connection cap: answer at once, without reading the request.
fn refuse(io: Io, stream: Io.net.Stream) void {
    defer stream.close(io);
    var buf: [overloaded_response.len]u8 = undefined;
    var w = stream.writer(io, &buf);
    w.interface.writeAll(overloaded_response) catch return;
    w.interface.flush() catch return;
    stream.shutdown(io, .send) catch {};
}

/// A numeric setting, read strictly: unset or empty means `default`; anything
/// that is not a whole number of type `T` (trailing junk, a sign that does
/// not fit, out of range) stops the gateway at startup with a message that
/// names the variable. A typo must not quietly become a default.
fn envInt(env: *const std.process.Environ.Map, comptime T: type, name: []const u8, default: T) !T {
    const raw = env.get(name) orelse return default;
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return default;
    return parseSetting(T, text) orelse {
        log.err("{s} is not a valid number: \"{s}\" (expected a whole number from {d} to {d})", .{ name, raw, std.math.minInt(T), std.math.maxInt(T) });
        return error.InvalidEnvironment;
    };
}

/// Digits only: `std.fmt.parseInt` would also take `1_000` and `+5`.
fn parseSetting(comptime T: type, text: []const u8) ?T {
    if (text.len == 0) return null;
    for (text) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(T, text, 10) catch null;
}

test "numeric settings are parsed strictly" {
    try std.testing.expectEqual(@as(?u32, 2000), parseSetting(u32, "2000"));
    try std.testing.expectEqual(@as(?u32, 0), parseSetting(u32, "0"));
    try std.testing.expectEqual(@as(?u16, 65535), parseSetting(u16, "65535"));
    for ([_][]const u8{ "", "5x", "x5", "-1", "+5", "1_000", "1.5", " 5", "5 ", "0x10", "99999999999" }) |bad| {
        try std.testing.expectEqual(@as(?u32, null), parseSetting(u32, bad));
    }
    try std.testing.expectEqual(@as(?u16, null), parseSetting(u16, "65536"));
}

/// Where to listen, and where to connect to reach that listener from this
/// machine (the wildcard addresses are not connectable everywhere).
const Listen = struct { bind: Io.net.IpAddress, local: Io.net.IpAddress };

fn parseListen(listen: []const u8) !Listen {
    const colon = std.mem.findScalarLast(u8, listen, ':') orelse {
        log.err("OMNIGATE_LISTEN must be host:port, got \"{s}\"", .{listen});
        return error.InvalidListenAddress;
    };
    const port = parseSetting(u16, listen[colon + 1 ..]) orelse {
        log.err("OMNIGATE_LISTEN has no valid port: \"{s}\"", .{listen});
        return error.InvalidListenAddress;
    };
    const host = listen[0..colon];
    const local_host = if (std.mem.eql(u8, host, "0.0.0.0")) "127.0.0.1" else if (std.mem.eql(u8, host, "::")) "::1" else host;
    return .{ .bind = try Io.net.IpAddress.parse(host, port), .local = try Io.net.IpAddress.parse(local_host, port) };
}

test "the listen address and how to reach it locally" {
    const any = try parseListen("0.0.0.0:8080");
    try std.testing.expectEqual(@as(u16, 8080), any.bind.getPort());
    try std.testing.expect(any.local.eql(&try Io.net.IpAddress.parse("127.0.0.1", 8080)));
    const one = try parseListen("127.0.0.1:9");
    try std.testing.expect(one.local.eql(&one.bind));
    try std.testing.expect((try parseListen("::1:8080")).local.eql(&try Io.net.IpAddress.parse("::1", 8080)));
}

const healthcheck_timeout_ms = 3000;

/// `omnigate-dp healthcheck`: is the instance on OMNIGATE_LISTEN answering?
/// Returns the process exit status.
fn healthcheck(io: Io, listen: []const u8) u8 {
    const where = parseListen(listen) catch return 1;
    const Race = union(enum) { probe: bool, timer: Io.Cancelable!void };
    var results: [2]Race = undefined;
    var race: Io.Select(Race) = .init(io, &results);
    race.concurrent(.probe, probeHealth, .{ io, where.local }) catch return 1;
    race.concurrent(.timer, sleepMs, .{ io, healthcheck_timeout_ms }) catch {};
    const first = race.await() catch {
        race.cancelDiscard();
        return 1;
    };
    race.cancelDiscard();
    return switch (first) {
        .probe => |healthy| if (healthy) 0 else 1,
        .timer => 1,
    };
}

fn sleepMs(io: Io, ms: u32) Io.Cancelable!void {
    return io.sleep(.fromMilliseconds(ms), .awake);
}

fn probeHealth(io: Io, address: Io.net.IpAddress) bool {
    const stream = address.connect(io, .{ .mode = .stream }) catch return false;
    defer stream.close(io);
    var out_buf: [128]u8 = undefined;
    var out = stream.writer(io, &out_buf);
    out.interface.writeAll("GET /healthz HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n") catch return false;
    out.interface.flush() catch return false;
    var in_buf: [256]u8 = undefined;
    var in = stream.reader(io, &in_buf);
    const status_line = in.interface.takeDelimiterInclusive('\n') catch return false;
    return std.mem.startsWith(u8, status_line, "HTTP/1.1 200 ");
}

pub fn main(init: std.process.Init) !void {
    // In safe builds std hands main its checking allocator: one global lock,
    // and bookkeeping that costs several times the size of a small allocation.
    // That is right for debugging and wrong for serving traffic, so every
    // optimized build (ReleaseSafe included, which is what ships) uses the
    // multi-threaded allocator.
    const gpa = if (builtin.mode == .debug) init.gpa else std.heap.smp_allocator;
    const io = init.io;
    const env = init.environ_map;

    const listen = env.get("OMNIGATE_LISTEN") orelse "127.0.0.1:8080";

    // The one subcommand. Before logging is set up: it prints nothing.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "healthcheck")) {
            std.process.exit(healthcheck(io, listen));
        }
        log.err("unknown argument \"{s}\" (the only subcommand is: healthcheck)", .{args[1]});
        std.process.exit(2);
    }

    logging.configure(io, env.get("OMNIGATE_LOG_LEVEL"), env.get("OMNIGATE_LOG_FORMAT")) catch |err| {
        log.err("bad OMNIGATE_LOG_LEVEL or OMNIGATE_LOG_FORMAT: {t}", .{err});
        return err;
    };
    const control_url = env.get("OMNIGATE_CONTROL_URL") orelse "http://127.0.0.1:4000";
    // `.env.example` ships the variable empty; an empty secret would let the
    // process start and then fail every call to the control plane.
    const internal_token = std.mem.trim(u8, env.get("OMNIGATE_INTERNAL_TOKEN") orelse "", " \t\r\n");
    if (internal_token.len == 0) {
        log.err("OMNIGATE_INTERNAL_TOKEN is not set", .{});
        return error.MissingInternalToken;
    }
    const poll_ms: i64 = try envInt(env, u31, "OMNIGATE_POLL_MS", 2000);
    const flush_ms: i64 = try envInt(env, u31, "OMNIGATE_FLUSH_MS", 500);
    const upstream_timeout_ms = try envInt(env, u32, "OMNIGATE_UPSTREAM_TIMEOUT_MS", 600_000);
    const client_timeout_ms = try envInt(env, u32, "OMNIGATE_CLIENT_TIMEOUT_MS", 30_000);
    const stream_idle_timeout_ms = try envInt(env, u32, "OMNIGATE_STREAM_IDLE_TIMEOUT_MS", 300_000);
    const client_stall_timeout_ms = try envInt(env, u32, "OMNIGATE_CLIENT_STALL_TIMEOUT_MS", 30_000);
    const abort_drain_ms = try envInt(env, u32, "OMNIGATE_ABORT_DRAIN_MS", 120_000);
    const abort_drain_max_mb = try envInt(env, u32, "OMNIGATE_ABORT_DRAIN_MAX_MB", 64);
    const max_concurrent_per_key = try envInt(env, u32, "OMNIGATE_MAX_CONCURRENT_PER_KEY", 512);
    const request_memory_mb = try envInt(env, u32, "OMNIGATE_REQUEST_MEMORY_MB", 1024);
    const parse_memory_mb = try envInt(env, u32, "OMNIGATE_PARSE_MEMORY_MB", 1024);
    const max_connections = try envInt(env, u32, "OMNIGATE_MAX_CONNECTIONS", 4096);
    const shutdown_grace_ms = try envInt(env, u32, "OMNIGATE_SHUTDOWN_GRACE_MS", 10_000);
    const cache_max_mb = try envInt(env, u32, "OMNIGATE_CACHE_MAX_MB", 64);
    const spool_env = env.get("OMNIGATE_SPOOL") orelse "omnigate-usage.spool";
    const spool_path: ?[]const u8 = if (std.mem.eql(u8, spool_env, "off")) null else spool_env;

    const cache_env = env.get("OMNIGATE_CONFIG_CACHE") orelse "omnigate-config.cache.json";
    const config_cache_path: ?[]const u8 = if (std.mem.eql(u8, cache_env, "off")) null else cache_env;

    const where = try parseListen(listen);
    const address = where.bind;
    // Where to connect to reach our own listener (see `stopWatcher`).
    const wake_address = where.local;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var store: config.Store = .{};
    defer store.deinit(gpa);

    var usage_reporter = reporter.Reporter.init(gpa, io, Io.Dir.cwd(), spool_path) catch |err| {
        log.err("cannot open usage spool {s}: {t}", .{ spool_env, err });
        return err;
    };
    defer usage_reporter.deinit();

    var limiter: ratelimit.Limiter = .{};
    defer limiter.deinit(gpa);

    var upstream_health: health.Health = .{
        .threshold = try envInt(env, u32, "OMNIGATE_COOLDOWN_FAILURES", 5),
        .cooldown_ms = try envInt(env, u31, "OMNIGATE_COOLDOWN_MS", 30_000),
    };
    defer upstream_health.deinit(gpa);

    var model_quirks: quirks.Quirks = .{};
    defer model_quirks.deinit(gpa);

    var balancer: balance.Counters = .{};
    defer balancer.deinit(gpa);

    var sockets: watchdog.Watchdog = .{ .gpa = gpa };
    defer sockets.deinit();

    var rejections: counters.Counters = .{};
    defer rejections.deinit(gpa);

    var response_cache: cache.Cache = .init(gpa, @as(usize, cache_max_mb) * 1024 * 1024);
    defer response_cache.deinit();

    var gate: limits.Gate = .{
        .max_concurrent = max_concurrent_per_key,
        .memory_budget = @as(u64, request_memory_mb) * 1024 * 1024,
        .tree_budget = @as(u64, parse_memory_mb) * 1024 * 1024,
    };
    defer gate.deinit(gpa);
    var drains: proxy.Drains = .{};

    var app: App = .{
        .gpa = gpa,
        .io = io,
        .client = &client,
        .store = &store,
        .reporter = &usage_reporter,
        .limiter = &limiter,
        .health = &upstream_health,
        .balancer = &balancer,
        .quirks = &model_quirks,
        .watchdog = &sockets,
        .counters = &rejections,
        .cache = &response_cache,
        .gate = &gate,
        .drains = &drains,
        .env = env,
        .control_url = control_url,
        .internal_token = internal_token,
        .poll_interval_ms = poll_ms,
        .flush_interval_ms = flush_ms,
        .upstream_timeout_ms = upstream_timeout_ms,
        .client_timeout_ms = client_timeout_ms,
        .stream_idle_timeout_ms = stream_idle_timeout_ms,
        .client_stall_timeout_ms = if (client_stall_timeout_ms != 0) client_stall_timeout_ms else stream_idle_timeout_ms,
        .abort_drain_ms = abort_drain_ms,
        .abort_drain_max_bytes = @as(u64, abort_drain_max_mb) * 1024 * 1024,
        .max_connections = max_connections,
        .config_cache_path = config_cache_path,
        .started_unix_s = @divTrunc(Io.Timestamp.now(io, .real).toMilliseconds(), 1000),
    };

    control.syncOnce(&app) catch |err| {
        if (control.loadCache(&app)) |_| {
            log.warn("initial config sync failed ({t}); serving the cached config until the control plane answers", .{err});
        } else |_| {
            log.warn("initial config sync failed ({t}) and there is no cached config; serving 503 until the control plane answers", .{err});
        }
    };

    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    log.info("omnigate data plane listening on {s} (control plane {s})", .{ listen, control_url });

    installStopHandlers();

    // Housekeeping tasks. Connection tasks are not in a group: each has its
    // own future, held by the watchdog, so that it can be cancelled alone.
    var background: Io.Group = .init;
    errdefer {
        background.cancel(io);
        _ = sockets.cancelAll(io);
        drains.stop(io);
    }

    try background.concurrent(io, control.pollLoop, .{&app});
    try background.concurrent(io, reporter.flushLoop, .{&app});
    try background.concurrent(io, counters.flushLoop, .{&app});
    try background.concurrent(io, watchdogTask, .{&app});
    try background.concurrent(io, stopWatcher, .{ &app, wake_address });

    while (true) {
        const stream = server.accept(io) catch |err| {
            if (app.shutting_down.load(.acquire)) break;
            log.warn("accept failed: {t}", .{err});
            continue;
        };
        if (app.shutting_down.load(.acquire)) {
            stream.close(io);
            break;
        }
        if (app.active_connections.fetchAdd(1, .acq_rel) >= app.max_connections) {
            _ = app.active_connections.fetchSub(1, .acq_rel);
            rejections.count(gpa, io, counters.unknown_key, "overloaded");
            refuse(io, stream);
            continue;
        }
        const conn = sockets.create(io, stream) orelse {
            _ = app.active_connections.fetchSub(1, .acq_rel);
            rejections.count(gpa, io, counters.unknown_key, "overloaded");
            refuse(io, stream);
            continue;
        };
        conn.future = io.concurrent(proxy.handleConnection, .{ &app, conn }) catch |err| {
            _ = app.active_connections.fetchSub(1, .acq_rel);
            log.warn("cannot spawn connection task: {t}", .{err});
            sockets.recycle(io, conn);
            rejections.count(gpa, io, counters.unknown_key, "overloaded");
            refuse(io, stream);
            continue;
        };
        sockets.add(io, conn);
    }

    // --- graceful stop ------------------------------------------------------
    log.info("stopping: {d} connection(s) open, waiting up to {d} ms for requests in flight", .{
        app.active_connections.load(.acquire), shutdown_grace_ms,
    });
    // Connections between requests have nothing to finish: the watchdog
    // cancels them on its next sweep, and each busy one as it becomes idle.
    sockets.stop_idle.store(true, .release);
    const deadline = watchdog.nowMs(io) + shutdown_grace_ms;
    while (app.active_connections.load(.acquire) > 0 and watchdog.nowMs(io) < deadline) {
        io.sleep(.fromMilliseconds(25), .awake) catch break;
    }
    const cut_off = app.active_connections.load(.acquire);
    if (cut_off > 0) log.warn("{d} request(s) still running after the grace period; cutting them off", .{cut_off});
    background.cancel(io);
    _ = sockets.cancelAll(io);
    // Answers still being read for clients that left: each bills what it
    // has (an estimate) and ends.
    drains.stop(io);

    // The flush task is gone; make one last attempt to hand over usage.
    // Whatever stays behind is in the spool file for the next start.
    const undelivered = reporter.drain(&app, 20);
    // And the rejection counters, which have no spool: once, best effort.
    _ = counters.flushOnce(&app);
    if (undelivered > 0) {
        log.warn("stopped with {d} usage event(s) undelivered{s}", .{
            undelivered, if (spool_path != null) " (kept in the spool)" else " (no spool: they are lost)",
        });
    } else {
        log.info("stopped cleanly", .{});
    }
}

test {
    _ = config;
    _ = reporter;
    _ = ratelimit;
    _ = health;
    _ = balance;
    _ = cache;
    _ = counters;
    _ = @import("headers.zig");
    _ = @import("guard.zig");
    _ = @import("framing.zig");
    _ = @import("jsonscan.zig");
    _ = limits;
    _ = @import("errors.zig");
    _ = @import("models.zig");
    _ = quirks;
    _ = logging;
    _ = watchdog;
    _ = @import("translate.zig");
    _ = @import("usage.zig");
}
