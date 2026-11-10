//! In which order a request tries a route's targets.
//!
//! A route names its strategy:
//!
//!   * `failover` (the default): config order. The first target takes all the
//!     traffic; the others are there for when it fails.
//!   * `round_robin`: the starting target rotates with every request; the
//!     rest follow in ring order as failover.
//!   * `weighted`: the starting target is drawn at random in proportion to
//!     each target's `weight`; the rest follow in config order as failover.
//!     A weight of 0 means "never first, but still a fallback".
//!
//! Whatever the strategy, targets whose upstream is cooling down after
//! repeated failures (see health.zig) are moved to the end: they are still
//! tried, as a last resort, so ordering alone never fails a request.
//!
//! `order` is a pure function of its arguments so that it can be tested
//! exhaustively; the per-route request counter it needs for round robin
//! lives in `Counters`.

const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");

pub const Strategy = enum { failover, round_robin, weighted };

/// An absent or unknown strategy name means failover: a newer control plane
/// must not be able to break an older data plane with a word it does not know.
pub fn parseStrategy(name: ?[]const u8) Strategy {
    const s = name orelse return .failover;
    return std.meta.stringToEnum(Strategy, s) orelse .failover;
}

/// Fill `out` with the indices of `targets` in the order to try them.
///
/// `cooling[i]` says whether target i's upstream is cooling down. `counter`
/// is this route's request number (used by round robin) and `random` a
/// uniformly random value (used by weighted); the other strategies ignore
/// them. All three slices have the same length.
pub fn order(
    out: []usize,
    targets: []const config.Target,
    cooling: []const bool,
    strategy: Strategy,
    counter: u64,
    random: u64,
) void {
    const n = targets.len;
    std.debug.assert(out.len == n and cooling.len == n);
    if (n == 0) return;

    // 1. The order the strategy would like.
    switch (strategy) {
        .failover => for (out, 0..) |*o, i| {
            o.* = i;
        },
        .round_robin => {
            const start: usize = @intCast(counter % n);
            for (out, 0..) |*o, i| o.* = (start + i) % n;
        },
        .weighted => {
            // Draw among the targets that can actually serve right now, so
            // that a cooling upstream's share goes to the others in
            // proportion instead of all to the first one in the config.
            const first = pickWeighted(targets, cooling, random);
            var k: usize = 0;
            if (first) |f| {
                out[0] = f;
                k = 1;
            }
            for (0..n) |i| {
                if (first != null and i == first.?) continue;
                out[k] = i;
                k += 1;
            }
        },
    }

    // 2. Cooling targets last, keeping the relative order within each group.
    //    Insertion-style stable partition; routes have a handful of targets.
    var healthy_end: usize = 0;
    for (0..n) |i| {
        if (cooling[out[i]]) continue;
        const idx = out[i];
        var j = i;
        while (j > healthy_end) : (j -= 1) out[j] = out[j - 1];
        out[healthy_end] = idx;
        healthy_end += 1;
    }
}

/// The index drawn by `random` among healthy targets with a positive weight,
/// or null when there is none to draw from.
fn pickWeighted(targets: []const config.Target, cooling: []const bool, random: u64) ?usize {
    var total: u64 = 0;
    for (targets, cooling) |t, c| {
        if (!c) total += t.weight;
    }
    if (total == 0) return null;

    var r = random % total;
    for (targets, cooling, 0..) |t, c, i| {
        if (c or t.weight == 0) continue;
        if (r < t.weight) return i;
        r -= t.weight;
    }
    unreachable;
}

/// Per-route request counters for round robin. In memory, per process: after
/// a restart every route simply starts again at its first target.
pub const Counters = struct {
    mutex: Io.Mutex = .init,
    /// Keys are owned copies of route model names.
    by_route: std.StringHashMapUnmanaged(u64) = .empty,

    /// Routes are few. If config churn ever leaves this many names behind,
    /// forget them all; the only effect is that rotations start over.
    const max_routes = 4096;

    pub fn deinit(c: *Counters, gpa: std.mem.Allocator) void {
        c.clear(gpa);
        c.by_route.deinit(gpa);
    }

    /// This route's request number: 0, 1, 2, ... Never fails; if memory is
    /// short the request is treated as the route's first.
    pub fn next(c: *Counters, gpa: std.mem.Allocator, io: Io, route_model: []const u8) u64 {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);

        if (c.by_route.getPtr(route_model)) |n| {
            const current = n.*;
            n.* +%= 1;
            return current;
        }
        if (c.by_route.count() >= max_routes) c.clear(gpa);
        const owned = gpa.dupe(u8, route_model) catch return 0;
        c.by_route.put(gpa, owned, 1) catch {
            gpa.free(owned);
            return 0;
        };
        return 0;
    }

    fn clear(c: *Counters, gpa: std.mem.Allocator) void {
        var it = c.by_route.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        c.by_route.clearRetainingCapacity();
    }
};

// --------------------------------------------------------------------------
// tests
// --------------------------------------------------------------------------

fn targetsWithWeights(comptime weights: []const u32) [weights.len]config.Target {
    var out: [weights.len]config.Target = undefined;
    for (weights, 0..) |w, i| out[i] = .{ .upstream = "u", .model = "m", .weight = w };
    return out;
}

fn expectOrder(expected: []const usize, targets: []const config.Target, cooling: []const bool, strategy: Strategy, counter: u64, random: u64) !void {
    var buf: [8]usize = undefined;
    const out = buf[0..targets.len];
    order(out, targets, cooling, strategy, counter, random);
    try std.testing.expectEqualSlices(usize, expected, out);
}

test "strategy names: unknown or absent means failover" {
    try std.testing.expectEqual(Strategy.failover, parseStrategy(null));
    try std.testing.expectEqual(Strategy.failover, parseStrategy("failover"));
    try std.testing.expectEqual(Strategy.round_robin, parseStrategy("round_robin"));
    try std.testing.expectEqual(Strategy.weighted, parseStrategy("weighted"));
    try std.testing.expectEqual(Strategy.failover, parseStrategy("least_latency"));
    try std.testing.expectEqual(Strategy.failover, parseStrategy(""));
    try std.testing.expectEqual(Strategy.failover, parseStrategy("Round_Robin"));
}

test "failover keeps config order whatever the counter and random value" {
    const t = targetsWithWeights(&.{ 1, 1, 1 });
    const none = [_]bool{ false, false, false };
    for ([_]u64{ 0, 1, 2, 7, std.math.maxInt(u64) }) |v| {
        try expectOrder(&.{ 0, 1, 2 }, &t, &none, .failover, v, v);
    }
}

test "round robin rotates the start and keeps ring order behind it" {
    const t = targetsWithWeights(&.{ 1, 1, 1 });
    const none = [_]bool{ false, false, false };
    try expectOrder(&.{ 0, 1, 2 }, &t, &none, .round_robin, 0, 0);
    try expectOrder(&.{ 1, 2, 0 }, &t, &none, .round_robin, 1, 0);
    try expectOrder(&.{ 2, 0, 1 }, &t, &none, .round_robin, 2, 0);
    try expectOrder(&.{ 0, 1, 2 }, &t, &none, .round_robin, 3, 0);
    // Weights play no part in round robin.
    const w = targetsWithWeights(&.{ 0, 9, 1 });
    try expectOrder(&.{ 1, 2, 0 }, &w, &none, .round_robin, 4, 0);
    // Every target leads equally often over whole cycles.
    var leads = [_]usize{ 0, 0, 0 };
    for (0..300) |c| {
        var out: [3]usize = undefined;
        order(&out, &t, &none, .round_robin, c, 0);
        leads[out[0]] += 1;
    }
    try std.testing.expectEqualSlices(usize, &.{ 100, 100, 100 }, &leads);
    // The largest counter value is as valid as any other.
    try expectOrder(&.{ 0, 1, 2 }, &t, &none, .round_robin, std.math.maxInt(u64), 0);
}

test "weighted: every random value maps to a target in exact proportion" {
    const t = targetsWithWeights(&.{ 3, 1, 0, 2 });
    const none = [_]bool{ false, false, false, false };
    var firsts = [_]usize{ 0, 0, 0, 0 };
    // One pass over a whole period of the modulus hits each slot exactly once.
    for (0..6) |r| {
        var out: [4]usize = undefined;
        order(&out, &t, &none, .weighted, 0, r);
        firsts[out[0]] += 1;
        // The others follow in config order.
        var prev: ?usize = null;
        for (out[1..]) |i| {
            try std.testing.expect(i != out[0]);
            if (prev) |p| try std.testing.expect(i > p);
            prev = i;
        }
    }
    try std.testing.expectEqualSlices(usize, &.{ 3, 1, 0, 2 }, &firsts);
    try expectOrder(&.{ 0, 1, 2, 3 }, &t, &none, .weighted, 0, 0);
    try expectOrder(&.{ 1, 0, 2, 3 }, &t, &none, .weighted, 0, 3);
    try expectOrder(&.{ 3, 0, 1, 2 }, &t, &none, .weighted, 0, 5);
    try expectOrder(&.{ 0, 1, 2, 3 }, &t, &none, .weighted, 0, 6); // wraps
}

test "weighted: proportions hold over many random draws" {
    const t = targetsWithWeights(&.{ 3, 1 });
    const none = [_]bool{ false, false };
    var prng: std.Random.DefaultPrng = .init(0x6f6d6e69);
    const rand = prng.random();
    var first0: usize = 0;
    const draws = 20_000;
    for (0..draws) |_| {
        var out: [2]usize = undefined;
        order(&out, &t, &none, .weighted, 0, rand.int(u64));
        if (out[0] == 0) first0 += 1;
        try std.testing.expectEqual(@as(usize, 1), out[0] + out[1]);
    }
    // Expect 75%; allow two percentage points either way.
    try std.testing.expect(first0 > draws * 73 / 100 and first0 < draws * 77 / 100);
}

test "weighted: weight 0 never leads but still backs the others up" {
    const t = targetsWithWeights(&.{ 0, 5 });
    const none = [_]bool{ false, false };
    for (0..50) |r| try expectOrder(&.{ 1, 0 }, &t, &none, .weighted, 0, r);
    // When the weighted target is cooling, the zero-weight one serves.
    const second_cooling = [_]bool{ false, true };
    for (0..50) |r| try expectOrder(&.{ 0, 1 }, &t, &second_cooling, .weighted, 0, r);
    // All weights zero: plain config order.
    const zeros = targetsWithWeights(&.{ 0, 0, 0 });
    try expectOrder(&.{ 0, 1, 2 }, &zeros, &.{ false, false, false }, .weighted, 0, 12345);
}

test "weighted: a cooling target's share goes to the healthy ones in proportion" {
    const t = targetsWithWeights(&.{ 5, 3, 1 });
    const first_cooling = [_]bool{ true, false, false };
    var firsts = [_]usize{ 0, 0, 0 };
    for (0..4) |r| {
        var out: [3]usize = undefined;
        order(&out, &t, &first_cooling, .weighted, 0, r);
        firsts[out[0]] += 1;
        try std.testing.expectEqual(@as(usize, 0), out[2]); // cooling goes last
    }
    try std.testing.expectEqualSlices(usize, &.{ 0, 3, 1 }, &firsts);
}

test "cooling targets go last in every strategy, in their original relative order" {
    const t = targetsWithWeights(&.{ 1, 1, 1, 1 });
    const cooling = [_]bool{ true, false, true, false };
    try expectOrder(&.{ 1, 3, 0, 2 }, &t, &cooling, .failover, 0, 0);
    // Ring order from 2 is 2,3,0,1 -> healthy 3,1 then cooling 2,0.
    try expectOrder(&.{ 3, 1, 2, 0 }, &t, &cooling, .round_robin, 2, 0);
    // Healthy are 1 and 3 with weight 1 each: random 1 picks target 3.
    try expectOrder(&.{ 3, 1, 0, 2 }, &t, &cooling, .weighted, 0, 1);
}

test "all cooling: nothing is dropped, the strategy's order is kept" {
    const t = targetsWithWeights(&.{ 2, 1, 1 });
    const all = [_]bool{ true, true, true };
    try expectOrder(&.{ 0, 1, 2 }, &t, &all, .failover, 0, 0);
    try expectOrder(&.{ 1, 2, 0 }, &t, &all, .round_robin, 1, 0);
    try expectOrder(&.{ 0, 1, 2 }, &t, &all, .weighted, 0, 3);
}

test "a single target and an empty route" {
    const t = targetsWithWeights(&.{7});
    for ([_]Strategy{ .failover, .round_robin, .weighted }) |s| {
        try expectOrder(&.{0}, &t, &.{false}, s, 5, 5);
        try expectOrder(&.{0}, &t, &.{true}, s, 5, 5);
    }
    var none: [0]usize = .{};
    order(&none, &.{}, &.{}, .round_robin, 3, 3);
    order(&none, &.{}, &.{}, .weighted, 3, 3);
}

test "every order is a permutation of the targets" {
    var prng: std.Random.DefaultPrng = .init(42);
    const rand = prng.random();
    for (0..2000) |_| {
        const n = rand.intRangeAtMost(usize, 1, 6);
        var targets: [6]config.Target = undefined;
        var cooling: [6]bool = undefined;
        for (0..n) |i| {
            targets[i] = .{ .upstream = "u", .model = "m", .weight = rand.intRangeAtMost(u32, 0, 4) };
            cooling[i] = rand.boolean();
        }
        const strategy = rand.enumValue(Strategy);
        var out: [6]usize = undefined;
        order(out[0..n], targets[0..n], cooling[0..n], strategy, rand.int(u64), rand.int(u64));

        var seen: [6]bool = @splat(false);
        var seen_cooling = false;
        for (out[0..n]) |i| {
            try std.testing.expect(i < n and !seen[i]);
            seen[i] = true;
            // Once a cooling target appears, only cooling targets follow.
            if (cooling[i]) seen_cooling = true else try std.testing.expect(!seen_cooling);
        }
    }
}

test "counters count per route and survive being cleared" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var c: Counters = .{};
    defer c.deinit(gpa);

    try std.testing.expectEqual(@as(u64, 0), c.next(gpa, io, "a"));
    try std.testing.expectEqual(@as(u64, 1), c.next(gpa, io, "a"));
    try std.testing.expectEqual(@as(u64, 0), c.next(gpa, io, "b"));
    try std.testing.expectEqual(@as(u64, 2), c.next(gpa, io, "a"));
    try std.testing.expectEqual(@as(u64, 1), c.next(gpa, io, "b"));

    // Far more route names than any config has: memory stays bounded.
    var name_buf: [32]u8 = undefined;
    for (0..Counters.max_routes * 2 + 10) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "route-{d}", .{i});
        _ = c.next(gpa, io, name);
    }
    try std.testing.expect(c.by_route.count() <= Counters.max_routes);
    _ = c.next(gpa, io, "a");
}
