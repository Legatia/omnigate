//! Per-key request rate limiting (token bucket), local to this data plane.
//!
//! A key with `rpm = N` may burst up to N requests and is refilled at N per
//! minute. State lives in memory only: a restart forgives the last minute,
//! which is the right trade for a limiter that must never block on I/O.
//! Limits are per data-plane process; cluster-wide limits are a control-plane
//! concern and not implemented yet.

const std = @import("std");
const Io = std.Io;

pub const Decision = union(enum) {
    allowed,
    /// Denied; the caller may retry after this many seconds.
    retry_after_s: u32,
};

pub const Limiter = struct {
    mutex: Io.Mutex = .init,
    buckets: std.AutoHashMapUnmanaged([64]u8, Bucket) = .empty,

    const Bucket = struct {
        /// Fractional requests available, in thousandths.
        milli_tokens: u64,
        last_ms: i64,
        rpm: u32,
    };

    pub fn deinit(l: *Limiter, gpa: std.mem.Allocator) void {
        l.buckets.deinit(gpa);
    }

    /// `rpm == 0` means unlimited. `now_ms` is a monotonic clock reading.
    pub fn check(l: *Limiter, gpa: std.mem.Allocator, io: Io, key_sha256: *const [64]u8, rpm: u32, now_ms: i64) Decision {
        if (rpm == 0) return .allowed;

        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);

        const capacity: u64 = @as(u64, rpm) * 1000;
        const gop = l.buckets.getOrPut(gpa, key_sha256.*) catch return .allowed; // fail open on OOM
        if (!gop.found_existing or gop.value_ptr.rpm != rpm) {
            // New key, or its limit changed in config: start with a full bucket.
            gop.value_ptr.* = .{ .milli_tokens = capacity, .last_ms = now_ms, .rpm = rpm };
        }
        const b = gop.value_ptr;

        // Refill: rpm requests per 60_000 ms == rpm*1000 milli-tokens per 60_000 ms.
        const elapsed: u64 = @intCast(@max(0, now_ms - b.last_ms));
        const refill = elapsed * rpm / 60;
        if (b.milli_tokens + refill >= capacity) {
            b.milli_tokens = capacity;
            b.last_ms = now_ms;
        } else if (refill > 0) {
            b.milli_tokens += refill;
            // Advance only by the time this refill accounts for, so integer
            // truncation never loses a fraction of a request.
            b.last_ms += @intCast(refill * 60 / rpm);
        }

        if (b.milli_tokens >= 1000) {
            b.milli_tokens -= 1000;
            return .allowed;
        }
        const missing = 1000 - b.milli_tokens;
        // ms until `missing` milli-tokens have been refilled, rounded up.
        const wait_ms = (missing * 60 + rpm - 1) / rpm;
        return .{ .retry_after_s = @intCast(@max(1, (wait_ms + 999) / 1000)) };
    }
};

test "unlimited keys are never limited" {
    var l: Limiter = .{};
    defer l.deinit(std.testing.allocator);
    const key: [64]u8 = @splat('a');
    for (0..1000) |_| {
        try std.testing.expectEqual(Decision.allowed, l.check(std.testing.allocator, std.testing.io, &key, 0, 0));
    }
}

test "burst then deny with a retry hint, then refill" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var l: Limiter = .{};
    defer l.deinit(gpa);
    const key: [64]u8 = @splat('a');

    // 5 rpm: five immediately, the sixth is denied.
    for (0..5) |_| try std.testing.expectEqual(Decision.allowed, l.check(gpa, io, &key, 5, 1000));
    const denied = l.check(gpa, io, &key, 5, 1000);
    try std.testing.expectEqual(Decision{ .retry_after_s = 12 }, denied);

    // One request refills every 12 s.
    try std.testing.expect(l.check(gpa, io, &key, 5, 1000 + 11_000) == .retry_after_s);
    try std.testing.expectEqual(Decision.allowed, l.check(gpa, io, &key, 5, 1000 + 12_000));
    try std.testing.expect(l.check(gpa, io, &key, 5, 1000 + 12_001) == .retry_after_s);

    // A long idle period refills to capacity, not beyond.
    for (0..5) |_| try std.testing.expectEqual(Decision.allowed, l.check(gpa, io, &key, 5, 10_000_000));
    try std.testing.expect(l.check(gpa, io, &key, 5, 10_000_000) == .retry_after_s);
}

test "keys are independent and a changed limit resets the bucket" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var l: Limiter = .{};
    defer l.deinit(gpa);
    const a: [64]u8 = @splat('a');
    const b: [64]u8 = @splat('b');

    try std.testing.expectEqual(Decision.allowed, l.check(gpa, io, &a, 1, 0));
    try std.testing.expect(l.check(gpa, io, &a, 1, 0) == .retry_after_s);
    try std.testing.expectEqual(Decision.allowed, l.check(gpa, io, &b, 1, 0));

    // Raising a's limit takes effect immediately.
    try std.testing.expectEqual(Decision.allowed, l.check(gpa, io, &a, 2, 0));
}
