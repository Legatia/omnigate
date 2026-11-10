//! Upstream cooldowns (a simple circuit breaker).
//!
//! An upstream that fails `threshold` times in a row is "cooling" for
//! `cooldown_ms`: requests try their other targets first and come back to it
//! only as a last resort, so a dead provider costs one timeout, not one per
//! request. One success clears it. When the cooldown ends the next request
//! tries it again; if that fails it cools down again at once.
//!
//! State is per data-plane process and in memory only.

const std = @import("std");
const Io = std.Io;

pub const Health = struct {
    /// Consecutive failures before an upstream cools down. 0 disables.
    threshold: u32 = 5,
    cooldown_ms: i64 = 30_000,
    mutex: Io.Mutex = .init,
    /// Keys are owned copies of upstream names.
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        consecutive_failures: u32 = 0,
        cooling_until_ms: i64 = 0,
    };

    pub fn deinit(h: *Health, gpa: std.mem.Allocator) void {
        var it = h.entries.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        h.entries.deinit(gpa);
    }

    pub fn isCooling(h: *Health, io: Io, upstream: []const u8, now_ms: i64) bool {
        if (h.threshold == 0) return false;
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        const e = h.entries.getPtr(upstream) orelse return false;
        return now_ms < e.cooling_until_ms;
    }

    /// Returns true when this failure started a cooldown.
    pub fn recordFailure(h: *Health, gpa: std.mem.Allocator, io: Io, upstream: []const u8, now_ms: i64) bool {
        if (h.threshold == 0) return false;
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);

        const e = h.entries.getPtr(upstream) orelse blk: {
            const owned = gpa.dupe(u8, upstream) catch return false;
            h.entries.put(gpa, owned, .{}) catch {
                gpa.free(owned);
                return false;
            };
            break :blk h.entries.getPtr(upstream).?;
        };
        e.consecutive_failures +|= 1;
        if (e.consecutive_failures >= h.threshold) {
            e.cooling_until_ms = now_ms + h.cooldown_ms;
            // Exactly at the threshold, or a failed probe after a cooldown.
            return true;
        }
        return false;
    }

    pub fn recordSuccess(h: *Health, io: Io, upstream: []const u8) void {
        if (h.threshold == 0) return;
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        if (h.entries.getPtr(upstream)) |e| e.* = .{};
    }
};

test "cools down after the threshold and recovers on success" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var h: Health = .{ .threshold = 3, .cooldown_ms = 1000 };
    defer h.deinit(gpa);

    try std.testing.expect(!h.isCooling(io, "a", 0));
    try std.testing.expect(!h.recordFailure(gpa, io, "a", 0));
    try std.testing.expect(!h.recordFailure(gpa, io, "a", 0));
    try std.testing.expect(!h.isCooling(io, "a", 0));
    try std.testing.expect(h.recordFailure(gpa, io, "a", 0));
    try std.testing.expect(h.isCooling(io, "a", 999));
    try std.testing.expect(!h.isCooling(io, "b", 999)); // others unaffected

    // Cooldown over: it may be tried again. A failed probe cools it at once.
    try std.testing.expect(!h.isCooling(io, "a", 1000));
    try std.testing.expect(h.recordFailure(gpa, io, "a", 1000));
    try std.testing.expect(h.isCooling(io, "a", 1500));

    // One success clears everything.
    h.recordSuccess(io, "a");
    try std.testing.expect(!h.isCooling(io, "a", 1500));
    try std.testing.expect(!h.recordFailure(gpa, io, "a", 1500));
}

test "a success between failures resets the count" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var h: Health = .{ .threshold = 2, .cooldown_ms = 1000 };
    defer h.deinit(gpa);

    _ = h.recordFailure(gpa, io, "a", 0);
    h.recordSuccess(io, "a");
    try std.testing.expect(!h.recordFailure(gpa, io, "a", 0));
    try std.testing.expect(!h.isCooling(io, "a", 0));
}

test "threshold 0 disables cooldowns" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var h: Health = .{ .threshold = 0 };
    defer h.deinit(gpa);
    for (0..10) |_| try std.testing.expect(!h.recordFailure(gpa, io, "a", 0));
    try std.testing.expect(!h.isCooling(io, "a", 0));
}
