//! Shares the rate limit between the data planes of one control plane.
//!
//! Each data plane decides every request from its own buckets
//! (ratelimit.zig), so without this several data planes each allow a key
//! its full limit. Every sync interval this task tells the control plane
//! what each limited key was allowed here since the last time, and is told
//! what the other data planes allowed in the meantime:
//!
//!     POST /internal/limits/sync
//!     {"instance":"<id>","taken":[{"key":"<sha256 hex>","n":3,"rpm":60}, ...]}
//!
//!     200 {"others":[{"key":"<sha256 hex>","n":5,"rpm":60}, ...]}
//!
//! and takes that out of its buckets. No request ever waits for this: the
//! limit is exact within one data plane and approximate across them. What
//! arrives at several data planes within one interval is allowed by each
//! before they hear of each other; the buckets then owe it, so over time a
//! key gets its limit and not a multiple of it.
//!
//! Best effort by design, like the limiter itself. A report the control
//! plane did not take is dropped (resending it could count it twice), so
//! while the control plane is away, or is a version without this endpoint,
//! every data plane limits on its own, as before.

const std = @import("std");
const Io = std.Io;
const control = @import("control.zig");
const ratelimit = @import("ratelimit.zig");
const App = @import("main.zig").App;

const log = std.log.scoped(.limitsync);

const max_backoff_ms = 10_000;

/// Names this process to the control plane for as long as it runs.
pub const Instance = [16]u8;

pub fn newInstance(io: Io) Instance {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

/// The request body.
pub fn encode(gpa: std.mem.Allocator, instance: *const Instance, taken: []const ratelimit.Limiter.Taken) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{{\"instance\":\"{s}\",\"taken\":[", .{instance});
    for (taken, 0..) |t, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"key\":\"{s}\",\"n\":{d},\"rpm\":{d}}}", .{ t.key, t.n, t.rpm });
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

const Answer = struct {
    others: []const Other = &.{},

    const Other = struct { key: []const u8 = "", n: u64 = 0, rpm: u64 = 0 };
};

/// Take what the answer says other data planes allowed out of the buckets.
/// Returns how many entries were applied; entries that make no sense (not a
/// key hash, no limit) are skipped.
pub fn apply(limiter: *ratelimit.Limiter, gpa: std.mem.Allocator, io: Io, body: []const u8, now_ms: i64) !usize {
    const parsed = try std.json.parseFromSlice(Answer, gpa, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var applied: usize = 0;
    for (parsed.value.others) |o| {
        if (o.key.len != 64 or o.n == 0 or o.rpm == 0 or o.rpm > std.math.maxInt(u32)) continue;
        const n: u32 = @intCast(@min(o.n, std.math.maxInt(u32)));
        limiter.debit(gpa, io, o.key[0..64], @intCast(o.rpm), n, now_ms);
        applied += 1;
    }
    return applied;
}

/// One exchange. An error means the control plane did not take the report.
fn syncOnce(app: *App) !void {
    const gpa = app.gpa;
    const taken = try app.limiter.takeReport(gpa, app.io);
    defer gpa.free(taken);
    const body = try encode(gpa, &app.instance, taken);
    defer gpa.free(body);

    var answer: Io.Writer.Allocating = .init(gpa);
    defer answer.deinit();
    try control.postLimitSync(app, body, &answer.writer);
    const now_ms = Io.Timestamp.now(app.io, .awake).toMilliseconds();
    _ = try apply(app.limiter, gpa, app.io, answer.written(), now_ms);
}

/// Background task. `app.limit_sync_ms` is above zero.
pub fn syncLoop(app: *App) Io.Cancelable!void {
    var delay_ms: i64 = app.limit_sync_ms;
    var healthy = true;
    while (true) {
        try app.io.sleep(.fromMilliseconds(delay_ms), .awake);
        if (syncOnce(app)) |_| {
            if (!healthy) log.info("rate limits are shared with the other data planes again", .{});
            healthy = true;
            delay_ms = app.limit_sync_ms;
        } else |err| {
            if (err == error.Canceled) return error.Canceled;
            // Once per outage. A control plane without this endpoint lands
            // here too.
            if (healthy) log.warn("rate limits are not shared with other data planes for now ({t}); limiting locally", .{err});
            healthy = false;
            delay_ms = @min(delay_ms * 2, max_backoff_ms);
        }
    }
}

const testing = std.testing;

test "the request names the instance and what each key was allowed" {
    const gpa = testing.allocator;
    const instance: Instance = "0123456789abcdef".*;
    const taken = [_]ratelimit.Limiter.Taken{
        .{ .key = @splat('a'), .n = 3, .rpm = 60 },
        .{ .key = @splat('b'), .n = 1, .rpm = 5 },
    };
    const body = try encode(gpa, &instance, &taken);
    defer gpa.free(body);
    const a: [64]u8 = @splat('a');
    const b: [64]u8 = @splat('b');
    const want = try std.fmt.allocPrint(gpa, "{{\"instance\":\"0123456789abcdef\",\"taken\":[{{\"key\":\"{s}\",\"n\":3,\"rpm\":60}},{{\"key\":\"{s}\",\"n\":1,\"rpm\":5}}]}}", .{ a, b });
    defer gpa.free(want);
    try testing.expectEqualStrings(want, body);

    const none = try encode(gpa, &instance, &.{});
    defer gpa.free(none);
    try testing.expectEqualStrings("{\"instance\":\"0123456789abcdef\",\"taken\":[]}", none);
}

test "an answer is taken out of the buckets, and nonsense in it is skipped" {
    const gpa = testing.allocator;
    const io = testing.io;
    var l: ratelimit.Limiter = .{};
    defer l.deinit(gpa);
    const a: [64]u8 = @splat('a');

    const body = try std.fmt.allocPrint(gpa,
        \\{{"others":[{{"key":"{s}","n":2,"rpm":3}},{{"key":"short","n":1,"rpm":3}},
        \\{{"key":"{s}","n":0,"rpm":3}},{{"key":"{s}","n":1,"rpm":0}},{{"n":1}}],"instances":2,"new":true}}
    , .{ a, a, a });
    defer gpa.free(body);
    try testing.expectEqual(@as(usize, 1), try apply(&l, gpa, io, body, 0));
    // Three a minute, two of them allowed elsewhere: one is left here.
    try testing.expectEqual(ratelimit.Decision.allowed, l.check(gpa, io, &a, 3, 0));
    try testing.expect(l.check(gpa, io, &a, 3, 0) == .retry_after_s);

    try testing.expectEqual(@as(usize, 0), try apply(&l, gpa, io, "{}", 0));
    try testing.expectError(error.SyntaxError, apply(&l, gpa, io, "not json", 0));
}
