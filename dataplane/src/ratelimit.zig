//! Per-key request rate limiting (token bucket).
//!
//! A key with `rpm = N` may burst up to N requests and is refilled at N per
//! minute. State lives in memory only: a restart forgives the last minute,
//! which is the right trade for a limiter that must never block on I/O.
//!
//! The bucket is local, and a request is decided from it alone. Several data
//! planes behind one control plane tell each other, through it, what they
//! allowed (limitsync.zig): `takeReport` is what this process allowed since
//! the last report, `debit` takes what the others allowed out of the bucket
//! here. A bucket can therefore go below zero; it owes at most one full
//! bucket, so a key is never shut out for longer than its limit explains.

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
        /// Fractional requests available, in thousandths. Negative when
        /// other data planes allowed more than was left here (`debit`).
        milli_tokens: i64,
        last_ms: i64,
        rpm: u32,
        /// Requests allowed here since the last `takeReport`.
        taken: u32 = 0,
    };

    /// What one key was allowed, here (`takeReport`) or elsewhere (`debit`).
    pub const Taken = struct { key: [64]u8, n: u32, rpm: u32 };

    pub fn deinit(l: *Limiter, gpa: std.mem.Allocator) void {
        l.buckets.deinit(gpa);
    }

    /// `rpm == 0` means unlimited. `now_ms` is a monotonic clock reading.
    pub fn check(l: *Limiter, gpa: std.mem.Allocator, io: Io, key_sha256: *const [64]u8, rpm: u32, now_ms: i64) Decision {
        if (rpm == 0) return .allowed;

        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);

        const b = l.bucket(gpa, key_sha256, rpm, now_ms) orelse return .allowed; // fail open on OOM
        if (b.milli_tokens >= 1000) {
            b.milli_tokens -= 1000;
            b.taken +|= 1;
            return .allowed;
        }
        const missing: u64 = @intCast(1000 - b.milli_tokens);
        // ms until `missing` milli-tokens have been refilled, rounded up.
        const wait_ms = (missing * 60 + rpm - 1) / rpm;
        return .{ .retry_after_s = @intCast(@max(1, (wait_ms + 999) / 1000)) };
    }

    /// The bucket of a key, refilled up to `now_ms`. The caller holds the mutex.
    fn bucket(l: *Limiter, gpa: std.mem.Allocator, key_sha256: *const [64]u8, rpm: u32, now_ms: i64) ?*Bucket {
        const capacity: i64 = @as(i64, rpm) * 1000;
        const gop = l.buckets.getOrPut(gpa, key_sha256.*) catch return null;
        if (!gop.found_existing or gop.value_ptr.rpm != rpm) {
            // New key, or its limit changed in config: start with a full bucket.
            gop.value_ptr.* = .{ .milli_tokens = capacity, .last_ms = now_ms, .rpm = rpm };
        }
        const b = gop.value_ptr;

        // Refill: rpm requests per 60_000 ms == rpm*1000 milli-tokens per 60_000 ms.
        // (Two buckets' worth fills any bucket, however much it owes.)
        const elapsed: u64 = @intCast(@max(0, now_ms - b.last_ms));
        const refill: i64 = @intCast(@min(elapsed *| rpm / 60, @as(u64, @intCast(2 * capacity))));
        if (b.milli_tokens + refill >= capacity) {
            b.milli_tokens = capacity;
            b.last_ms = now_ms;
        } else if (refill > 0) {
            b.milli_tokens += refill;
            // Advance only by the time this refill accounts for, so integer
            // truncation never loses a fraction of a request.
            b.last_ms += @divTrunc(refill * 60, rpm);
        }
        return b;
    }

    /// What each limited key was allowed here since the last call, which
    /// starts the count again. The caller frees the slice.
    pub fn takeReport(l: *Limiter, gpa: std.mem.Allocator, io: Io) ![]Taken {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        var out: std.ArrayList(Taken) = .empty;
        errdefer out.deinit(gpa);
        var it = l.buckets.iterator();
        while (it.next()) |entry| {
            const b = entry.value_ptr;
            if (b.taken == 0) continue;
            try out.append(gpa, .{ .key = entry.key_ptr.*, .n = b.taken, .rpm = b.rpm });
        }
        const report = try out.toOwnedSlice(gpa);
        // Only once the whole report exists: a failure above loses nothing.
        it = l.buckets.iterator();
        while (it.next()) |entry| entry.value_ptr.taken = 0;
        return report;
    }

    /// Other data planes allowed `n` requests of this key: take them out of
    /// the bucket here. It may go below zero, by at most one full bucket.
    pub fn debit(l: *Limiter, gpa: std.mem.Allocator, io: Io, key_sha256: *const [64]u8, rpm: u32, n: u32, now_ms: i64) void {
        if (rpm == 0 or n == 0) return;
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        const b = l.bucket(gpa, key_sha256, rpm, now_ms) orelse return;
        const capacity: i64 = @as(i64, rpm) * 1000;
        b.milli_tokens = @max(-capacity, b.milli_tokens -| @as(i64, n) * 1000);
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

test "what other data planes allowed comes out of the bucket here" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var l: Limiter = .{};
    defer l.deinit(gpa);
    const a: [64]u8 = @splat('a');
    const b: [64]u8 = @splat('b');

    // 6 rpm: two allowed here, three elsewhere, so one is left.
    for (0..2) |_| try std.testing.expectEqual(Decision.allowed, l.check(gpa, io, &a, 6, 0));
    l.debit(gpa, io, &a, 6, 3, 0);
    try std.testing.expectEqual(Decision.allowed, l.check(gpa, io, &a, 6, 0));
    try std.testing.expectEqual(Decision{ .retry_after_s = 10 }, l.check(gpa, io, &a, 6, 0));

    // More than was left: the bucket owes, and the wait says so.
    l.debit(gpa, io, &a, 6, 2, 0);
    try std.testing.expectEqual(Decision{ .retry_after_s = 30 }, l.check(gpa, io, &a, 6, 0));
    try std.testing.expect(l.check(gpa, io, &a, 6, 29_000) == .retry_after_s);
    try std.testing.expectEqual(Decision.allowed, l.check(gpa, io, &a, 6, 30_000));

    // The debt is never more than one full bucket: after a flood elsewhere a
    // request fits again once a bucket and one request have been refilled.
    l.debit(gpa, io, &a, 6, 1_000_000, 30_000);
    try std.testing.expectEqual(Decision{ .retry_after_s = 70 }, l.check(gpa, io, &a, 6, 30_000));
    try std.testing.expectEqual(Decision.allowed, l.check(gpa, io, &a, 6, 100_000));

    // A key this process has not seen yet starts full, less what is debited.
    l.debit(gpa, io, &b, 2, 1, 0);
    try std.testing.expectEqual(Decision.allowed, l.check(gpa, io, &b, 2, 0));
    try std.testing.expect(l.check(gpa, io, &b, 2, 0) == .retry_after_s);
    // No limit, nothing to do.
    l.debit(gpa, io, &b, 0, 5, 0);
}

test "the report holds what was allowed here, once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var l: Limiter = .{};
    defer l.deinit(gpa);
    const a: [64]u8 = @splat('a');
    const b: [64]u8 = @splat('b');
    const c: [64]u8 = @splat('c');

    for (0..3) |_| _ = l.check(gpa, io, &a, 2, 0); // two allowed, one refused
    _ = l.check(gpa, io, &b, 5, 0);
    _ = l.check(gpa, io, &c, 0, 0); // unlimited: never reported
    l.debit(gpa, io, &b, 5, 2, 0); // what others allowed is not ours to report

    const first = try l.takeReport(gpa, io);
    defer gpa.free(first);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    for (first) |t| {
        if (t.key[0] == 'a') {
            try std.testing.expectEqual(@as(u32, 2), t.n);
            try std.testing.expectEqual(@as(u32, 2), t.rpm);
        } else {
            try std.testing.expectEqual(@as(u8, 'b'), t.key[0]);
            try std.testing.expectEqual(@as(u32, 1), t.n);
            try std.testing.expectEqual(@as(u32, 5), t.rpm);
        }
    }
    const second = try l.takeReport(gpa, io);
    defer gpa.free(second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}
