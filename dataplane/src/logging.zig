//! Log output: level filter, optional JSON lines, and the access log.
//!
//!   OMNIGATE_LOG_LEVEL   debug | info | warn | error   (default info)
//!   OMNIGATE_LOG_FORMAT  text | json                   (default text)
//!
//! In JSON mode every line on stderr is one object:
//!   {"ts":<unix ms>,"level":"info","scope":"proxy","msg":"..."}
//! and access-log lines carry their fields as JSON members instead of text.

const std = @import("std");
const Io = std.Io;

/// Messages above this level are dropped (`std.log.Level`: err < warn < info < debug).
var max_level: std.atomic.Value(u8) = .init(@intFromEnum(std.log.Level.info));
var json: bool = false;
/// For timestamps; set once at startup, before any other task runs.
var clock_io: ?Io = null;

pub const ConfigError = error{ InvalidLogLevel, InvalidLogFormat };

pub fn configure(io: Io, level_text: ?[]const u8, format_text: ?[]const u8) ConfigError!void {
    clock_io = io;
    if (level_text) |t| max_level.store(@intFromEnum(try parseLevel(t)), .release);
    if (format_text) |t| {
        if (std.mem.eql(u8, t, "json")) {
            json = true;
        } else if (std.mem.eql(u8, t, "text")) {
            json = false;
        } else return error.InvalidLogFormat;
    }
}

pub fn parseLevel(text: []const u8) ConfigError!std.log.Level {
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(text, "debug")) return .debug;
    if (eql(text, "info")) return .info;
    if (eql(text, "warn") or eql(text, "warning")) return .warn;
    if (eql(text, "error") or eql(text, "err")) return .err;
    return error.InvalidLogLevel;
}

pub fn enabled(level: std.log.Level) bool {
    return @intFromEnum(level) <= max_level.load(.acquire);
}

/// Installed as `std_options.logFn`.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!enabled(level)) return;
    if (!json) return std.log.defaultLog(level, scope, format, args);

    // Format the message first, so the lock is held only for the write.
    var msg_buf: [2048]u8 = undefined;
    var msg: Io.Writer = .fixed(&msg_buf);
    msg.print(format, args) catch {}; // a message that does not fit is cut off

    var line_buf: [4608]u8 = undefined;
    var line: Io.Writer = .fixed(&line_buf);
    writeLinePrefix(&line, level, @tagName(scope)) catch return;
    line.writeAll(",\"msg\":") catch return;
    std.json.Stringify.value(msg.buffered(), .{}, &line) catch return;
    line.writeAll("}\n") catch return;
    emit(line.buffered());
}

pub const Access = struct {
    method: []const u8 = "",
    path: Text(160) = .{},
    status: u16 = 0,
    key: Text(64) = .{},
    model: Text(96) = .{},
    upstream: Text(64) = .{},
    attempts: u32 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    latency_ms: i64 = 0,
    request_id: Text(32) = .{},
    /// Why the request ended without a normal response, if it did.
    aborted: ?anyerror = null,
};

/// A short string copied into the struct, so it outlives the request arena.
pub fn Text(comptime capacity: usize) type {
    return struct {
        buf: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn set(t: *@This(), s: []const u8) void {
            t.len = @min(s.len, capacity);
            @memcpy(t.buf[0..t.len], s[0..t.len]);
        }

        pub fn get(t: *const @This()) []const u8 {
            return t.buf[0..t.len];
        }
    };
}

/// One line per finished request. Health probes are logged at debug level.
pub fn access(a: *const Access, level: std.log.Level) void {
    if (!enabled(level)) return;
    var line_buf: [1536]u8 = undefined;
    var line: Io.Writer = .fixed(&line_buf);
    if (json) {
        writeLinePrefix(&line, level, "access") catch return;
        writeAccessJson(&line, a) catch return;
        line.writeAll("}\n") catch return;
        emit(line.buffered());
    } else {
        writeAccessText(&line, a) catch {};
        // Through the normal path, so it gets the usual prefix and colours.
        std.log.defaultLog(.info, .access, "{s}", .{line.buffered()});
    }
}

fn writeAccessText(w: *Io.Writer, a: *const Access) Io.Writer.Error!void {
    try w.print("{s} {s} {d}", .{ a.method, a.path.get(), a.status });
    if (a.key.len > 0) try w.print(" key={s}", .{a.key.get()});
    if (a.model.len > 0) try w.print(" model={s}", .{a.model.get()});
    if (a.upstream.len > 0) try w.print(" upstream={s} attempts={d}", .{ a.upstream.get(), a.attempts });
    if (a.input_tokens != 0 or a.output_tokens != 0) try w.print(" in={d} out={d}", .{ a.input_tokens, a.output_tokens });
    try w.print(" {d}ms", .{a.latency_ms});
    if (a.request_id.len > 0) try w.print(" id={s}", .{a.request_id.get()});
    if (a.aborted) |err| try w.print(" aborted={t}", .{err});
}

fn writeAccessJson(w: *Io.Writer, a: *const Access) Io.Writer.Error!void {
    try w.writeAll(",\"method\":");
    try std.json.Stringify.value(a.method, .{}, w);
    try w.writeAll(",\"path\":");
    try std.json.Stringify.value(a.path.get(), .{}, w);
    try w.print(",\"status\":{d}", .{a.status});
    if (a.key.len > 0) {
        try w.writeAll(",\"key\":");
        try std.json.Stringify.value(a.key.get(), .{}, w);
    }
    if (a.model.len > 0) {
        try w.writeAll(",\"model\":");
        try std.json.Stringify.value(a.model.get(), .{}, w);
    }
    if (a.upstream.len > 0) {
        try w.writeAll(",\"upstream\":");
        try std.json.Stringify.value(a.upstream.get(), .{}, w);
        try w.print(",\"attempts\":{d}", .{a.attempts});
    }
    try w.print(",\"input_tokens\":{d},\"output_tokens\":{d},\"latency_ms\":{d}", .{ a.input_tokens, a.output_tokens, a.latency_ms });
    if (a.request_id.len > 0) {
        try w.writeAll(",\"request_id\":");
        try std.json.Stringify.value(a.request_id.get(), .{}, w);
    }
    if (a.aborted) |err| try w.print(",\"aborted\":\"{t}\"", .{err});
}

fn writeLinePrefix(w: *Io.Writer, level: std.log.Level, scope: []const u8) Io.Writer.Error!void {
    const ts: i64 = if (clock_io) |io| Io.Timestamp.now(io, .real).toMilliseconds() else 0;
    try w.print("{{\"ts\":{d},\"level\":\"{s}\",\"scope\":\"{s}\"", .{ ts, levelName(level), scope });
}

fn levelName(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}

fn emit(bytes: []const u8) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    stderr.writer.writeAll(bytes) catch {};
}

test "levels parse and order" {
    try std.testing.expectEqual(std.log.Level.warn, try parseLevel("WARN"));
    try std.testing.expectEqual(std.log.Level.err, try parseLevel("error"));
    try std.testing.expectError(error.InvalidLogLevel, parseLevel("loud"));
}

test "access line: text and JSON carry the same fields, and never the key itself" {
    var a: Access = .{ .method = "POST", .status = 200, .attempts = 2, .input_tokens = 11, .output_tokens = 6, .latency_ms = 12 };
    a.path.set("/v1/chat/completions");
    a.key.set("main");
    a.model.set("chat");
    a.upstream.set("mock-ok");
    a.request_id.set("0123456789abcdef0123456789abcdef");

    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeAccessText(&w, &a);
    try std.testing.expectEqualStrings(
        "POST /v1/chat/completions 200 key=main model=chat upstream=mock-ok attempts=2 in=11 out=6 12ms id=0123456789abcdef0123456789abcdef",
        w.buffered(),
    );

    var jbuf: [1024]u8 = undefined;
    var jw: Io.Writer = .fixed(&jbuf);
    try jw.writeAll("{\"x\":1");
    try writeAccessJson(&jw, &a);
    try jw.writeAll("}");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, jw.buffered(), .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqualStrings("main", o.get("key").?.string);
    try std.testing.expectEqualStrings("mock-ok", o.get("upstream").?.string);
    try std.testing.expectEqual(@as(i64, 200), o.get("status").?.integer);
    try std.testing.expectEqual(@as(i64, 2), o.get("attempts").?.integer);
    try std.testing.expectEqual(@as(i64, 6), o.get("output_tokens").?.integer);
}

test "a long path is cut, not overflowed" {
    var a: Access = .{};
    var long: [501]u8 = @splat('x');
    long[0] = '/';
    a.path.set(&long);
    try std.testing.expectEqual(@as(usize, 160), a.path.get().len);
}
