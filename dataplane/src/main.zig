//! omnigate data plane: OpenAI/Anthropic-compatible streaming proxy.
//!
//! Environment:
//!   OMNIGATE_LISTEN          host:port to listen on        (default 127.0.0.1:8080)
//!   OMNIGATE_CONTROL_URL     control plane base URL        (default http://127.0.0.1:4000)
//!   OMNIGATE_INTERNAL_TOKEN  shared secret for /internal/* (required)
//!   OMNIGATE_POLL_MS         config poll interval in ms    (default 2000)
//!   OMNIGATE_FLUSH_MS        usage flush interval in ms    (default 500)
//!   OMNIGATE_SPOOL           usage spool file              (default omnigate-usage.spool;
//!                            set to "off" for memory-only)
//!   <api_key_env>            provider keys named by each upstream in the config

const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const control = @import("control.zig");
const proxy = @import("proxy.zig");
const reporter = @import("reporter.zig");

const log = std.log.scoped(.main);

pub const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    client: *std.http.Client,
    store: *config.Store,
    reporter: *reporter.Reporter,
    env: *const std.process.Environ.Map,
    control_url: []const u8,
    internal_token: []const u8,
    poll_interval_ms: i64,
    flush_interval_ms: i64,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    const listen = env.get("OMNIGATE_LISTEN") orelse "127.0.0.1:8080";
    const control_url = env.get("OMNIGATE_CONTROL_URL") orelse "http://127.0.0.1:4000";
    const internal_token = env.get("OMNIGATE_INTERNAL_TOKEN") orelse {
        log.err("OMNIGATE_INTERNAL_TOKEN is not set", .{});
        return error.MissingInternalToken;
    };
    const poll_ms: i64 = if (env.get("OMNIGATE_POLL_MS")) |s| try std.fmt.parseInt(i64, s, 10) else 2000;
    const flush_ms: i64 = if (env.get("OMNIGATE_FLUSH_MS")) |s| try std.fmt.parseInt(i64, s, 10) else 500;
    const spool_env = env.get("OMNIGATE_SPOOL") orelse "omnigate-usage.spool";
    const spool_path: ?[]const u8 = if (std.mem.eql(u8, spool_env, "off")) null else spool_env;

    const colon = std.mem.findScalarLast(u8, listen, ':') orelse return error.InvalidListenAddress;
    const port = try std.fmt.parseInt(u16, listen[colon + 1 ..], 10);
    const address = try Io.net.IpAddress.parse(listen[0..colon], port);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var store: config.Store = .{};
    defer store.deinit(gpa);

    var usage_reporter = reporter.Reporter.init(gpa, io, Io.Dir.cwd(), spool_path) catch |err| {
        log.err("cannot open usage spool {s}: {t}", .{ spool_env, err });
        return err;
    };
    defer usage_reporter.deinit();

    var app: App = .{
        .gpa = gpa,
        .io = io,
        .client = &client,
        .store = &store,
        .reporter = &usage_reporter,
        .env = env,
        .control_url = control_url,
        .internal_token = internal_token,
        .poll_interval_ms = poll_ms,
        .flush_interval_ms = flush_ms,
    };

    control.syncOnce(&app) catch |err| {
        log.warn("initial config sync failed ({t}); serving 503 until the control plane answers", .{err});
    };

    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    log.info("omnigate data plane listening on {s} (control plane {s})", .{ listen, control_url });

    var group: Io.Group = .init;
    defer group.cancel(io);

    try group.concurrent(io, control.pollLoop, .{&app});
    try group.concurrent(io, reporter.flushLoop, .{&app});

    while (true) {
        const stream = server.accept(io) catch |err| {
            log.warn("accept failed: {t}", .{err});
            continue;
        };
        group.concurrent(io, proxy.handleConnection, .{ &app, stream }) catch |err| {
            log.warn("cannot spawn connection task: {t}", .{err});
            stream.close(io);
        };
    }
}

test {
    _ = config;
    _ = reporter;
    _ = @import("usage.zig");
}
