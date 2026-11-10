//! omnigate data plane: OpenAI/Anthropic-compatible streaming proxy.
//!
//! Environment:
//!   OMNIGATE_LISTEN          host:port to listen on        (default 127.0.0.1:8080)
//!   OMNIGATE_CONTROL_URL     control plane base URL        (default http://127.0.0.1:4000)
//!   OMNIGATE_INTERNAL_TOKEN  shared secret for /internal/* (required)
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
//!   OMNIGATE_STREAM_IDLE_TIMEOUT_MS  abort a response that is being streamed
//!                            when the upstream sends nothing, or the client
//!                            reads nothing, for this long (default 300000;
//!                            0 = no limit)
//!   OMNIGATE_MAX_CONNECTIONS  client connections served at once; further ones
//!                            get an immediate 503 (default 4096)
//!   OMNIGATE_SHUTDOWN_GRACE_MS  on SIGINT/SIGTERM (Ctrl-C/Ctrl-Break on
//!                            Windows): how long requests in flight may take
//!                            to finish before the process exits (default 10000)
//!   OMNIGATE_LOG_LEVEL       debug | info | warn | error   (default info)
//!   OMNIGATE_LOG_FORMAT      text | json                   (default text)
//!   <api_key_env>            provider keys named by each upstream in the config

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const balance = @import("balance.zig");
const config = @import("config.zig");
const control = @import("control.zig");
const health = @import("health.zig");
const logging = @import("logging.zig");
const proxy = @import("proxy.zig");
const quirks = @import("quirks.zig");
const ratelimit = @import("ratelimit.zig");
const reporter = @import("reporter.zig");
const watchdog = @import("watchdog.zig");

const log = std.log.scoped(.main);

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
    max_connections: u32,
    config_cache_path: ?[]const u8,
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

const overloaded_body = "{\"error\":{\"type\":\"overloaded\",\"message\":\"too many connections; try again shortly\"}}";
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

fn envInt(env: *const std.process.Environ.Map, comptime T: type, name: []const u8, default: T) !T {
    const text = env.get(name) orelse return default;
    return std.fmt.parseInt(T, text, 10) catch {
        log.err("{s} is not a valid number: {s}", .{ name, text });
        return error.InvalidEnvironment;
    };
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

    logging.configure(io, env.get("OMNIGATE_LOG_LEVEL"), env.get("OMNIGATE_LOG_FORMAT")) catch |err| {
        log.err("bad OMNIGATE_LOG_LEVEL or OMNIGATE_LOG_FORMAT: {t}", .{err});
        return err;
    };

    const listen = env.get("OMNIGATE_LISTEN") orelse "127.0.0.1:8080";
    const control_url = env.get("OMNIGATE_CONTROL_URL") orelse "http://127.0.0.1:4000";
    const internal_token = env.get("OMNIGATE_INTERNAL_TOKEN") orelse {
        log.err("OMNIGATE_INTERNAL_TOKEN is not set", .{});
        return error.MissingInternalToken;
    };
    const poll_ms: i64 = if (env.get("OMNIGATE_POLL_MS")) |s| try std.fmt.parseInt(i64, s, 10) else 2000;
    const flush_ms: i64 = if (env.get("OMNIGATE_FLUSH_MS")) |s| try std.fmt.parseInt(i64, s, 10) else 500;
    const upstream_timeout_ms: u32 = if (env.get("OMNIGATE_UPSTREAM_TIMEOUT_MS")) |s| try std.fmt.parseInt(u32, s, 10) else 600_000;
    const client_timeout_ms = try envInt(env, u32, "OMNIGATE_CLIENT_TIMEOUT_MS", 30_000);
    const stream_idle_timeout_ms = try envInt(env, u32, "OMNIGATE_STREAM_IDLE_TIMEOUT_MS", 300_000);
    const max_connections = try envInt(env, u32, "OMNIGATE_MAX_CONNECTIONS", 4096);
    const shutdown_grace_ms = try envInt(env, u32, "OMNIGATE_SHUTDOWN_GRACE_MS", 10_000);
    const spool_env = env.get("OMNIGATE_SPOOL") orelse "omnigate-usage.spool";
    const spool_path: ?[]const u8 = if (std.mem.eql(u8, spool_env, "off")) null else spool_env;

    const cache_env = env.get("OMNIGATE_CONFIG_CACHE") orelse "omnigate-config.cache.json";
    const config_cache_path: ?[]const u8 = if (std.mem.eql(u8, cache_env, "off")) null else cache_env;

    const colon = std.mem.findScalarLast(u8, listen, ':') orelse return error.InvalidListenAddress;
    const port = try std.fmt.parseInt(u16, listen[colon + 1 ..], 10);
    const host = listen[0..colon];
    const address = try Io.net.IpAddress.parse(host, port);
    // Where to connect to reach our own listener (see `stopWatcher`).
    const wake_host = if (std.mem.eql(u8, host, "0.0.0.0")) "127.0.0.1" else if (std.mem.eql(u8, host, "::")) "::1" else host;
    const wake_address = try Io.net.IpAddress.parse(wake_host, port);

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
        .threshold = if (env.get("OMNIGATE_COOLDOWN_FAILURES")) |s| try std.fmt.parseInt(u32, s, 10) else 5,
        .cooldown_ms = if (env.get("OMNIGATE_COOLDOWN_MS")) |s| try std.fmt.parseInt(i64, s, 10) else 30_000,
    };
    defer upstream_health.deinit(gpa);

    var model_quirks: quirks.Quirks = .{};
    defer model_quirks.deinit(gpa);

    var balancer: balance.Counters = .{};
    defer balancer.deinit(gpa);

    var sockets: watchdog.Watchdog = .{ .gpa = gpa };
    defer sockets.deinit();

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
        .env = env,
        .control_url = control_url,
        .internal_token = internal_token,
        .poll_interval_ms = poll_ms,
        .flush_interval_ms = flush_ms,
        .upstream_timeout_ms = upstream_timeout_ms,
        .client_timeout_ms = client_timeout_ms,
        .stream_idle_timeout_ms = stream_idle_timeout_ms,
        .max_connections = max_connections,
        .config_cache_path = config_cache_path,
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
    }

    try background.concurrent(io, control.pollLoop, .{&app});
    try background.concurrent(io, reporter.flushLoop, .{&app});
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
            refuse(io, stream);
            continue;
        }
        const conn = sockets.create(io, stream) orelse {
            _ = app.active_connections.fetchSub(1, .acq_rel);
            refuse(io, stream);
            continue;
        };
        conn.future = io.concurrent(proxy.handleConnection, .{ &app, conn }) catch |err| {
            _ = app.active_connections.fetchSub(1, .acq_rel);
            log.warn("cannot spawn connection task: {t}", .{err});
            sockets.recycle(io, conn);
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

    // The flush task is gone; make one last attempt to hand over usage.
    // Whatever stays behind is in the spool file for the next start.
    const undelivered = reporter.drain(&app, 20);
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
    _ = quirks;
    _ = logging;
    _ = watchdog;
    _ = @import("translate.zig");
    _ = @import("usage.zig");
}
