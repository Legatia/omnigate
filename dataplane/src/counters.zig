//! Counts of requests the gateway refused before routing them.
//!
//! A request with a bad key, over its rate limit, for a model the key may not
//! use, and so on never reaches an upstream, so it never becomes a usage
//! event and the ledger cannot see it. These counters make such requests
//! visible: they are kept per (key name, reason), where the reason is the
//! error `code` the client was given, and handed to the control plane every
//! flush interval as
//!
//!     POST /internal/counters
//!     {"counters":[{"key":"<name or ->","reason":"rate_limit_exceeded","count":3}, ...]}
//!
//! Best effort by design: nothing is written to disk, a restart forgets what
//! was not yet sent, and if the control plane is away the counts simply keep
//! adding up here until it is back. The number of distinct series is capped
//! so that a flood of made-up keys cannot grow memory; past the cap, new
//! series are folded into the key "-".

const std = @import("std");
const Io = std.Io;
const control = @import("control.zig");
const App = @import("main.zig").App;

const log = std.log.scoped(.counters);

/// The key name used when the request could not be tied to a known key.
pub const unknown_key = "-";

/// Most distinct (key, reason) series held at once.
pub const max_series = 1000;
const max_backoff_ms = 10_000;

/// "key\nreason" -> count. Keys are owned. Key names come from the config and
/// reasons from this program, and neither contains a newline.
const Map = std.StringHashMapUnmanaged(u64);

pub const Counters = struct {
    mutex: Io.Mutex = .init,
    map: Map = .empty,

    pub fn deinit(c: *Counters, gpa: std.mem.Allocator) void {
        freeMap(gpa, &c.map);
    }

    /// Count one refused request. Never fails: on memory pressure the count
    /// is dropped, which is the right trade for a diagnostic.
    pub fn count(c: *Counters, gpa: std.mem.Allocator, io: Io, key_name: []const u8, reason: []const u8) void {
        c.add(gpa, io, if (key_name.len == 0) unknown_key else key_name, reason, 1);
    }

    /// Count `n` of something that is not a refusal (values redacted, by
    /// class: the reasons that start `redacted_`). Same rules as `count`.
    pub fn countN(c: *Counters, gpa: std.mem.Allocator, io: Io, key_name: []const u8, reason: []const u8, n: u64) void {
        c.add(gpa, io, if (key_name.len == 0) unknown_key else key_name, reason, n);
    }

    fn add(c: *Counters, gpa: std.mem.Allocator, io: Io, key_name: []const u8, reason: []const u8, n: u64) void {
        var buf: [256]u8 = undefined;
        const series = std.fmt.bufPrint(&buf, "{s}\n{s}", .{ key_name, reason }) catch return;

        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);

        if (c.map.getPtr(series)) |existing| {
            existing.* +|= n;
            return;
        }
        if (c.map.count() >= max_series and !std.mem.eql(u8, key_name, unknown_key)) {
            // Too many series: keep the reason, give up the key.
            const folded = std.fmt.bufPrint(&buf, "{s}\n{s}", .{ unknown_key, reason }) catch return;
            if (c.map.getPtr(folded)) |existing| {
                existing.* +|= n;
                return;
            }
            c.insert(gpa, folded, n);
            return;
        }
        c.insert(gpa, series, n);
    }

    fn insert(c: *Counters, gpa: std.mem.Allocator, series: []const u8, n: u64) void {
        const owned = gpa.dupe(u8, series) catch return;
        c.map.put(gpa, owned, n) catch gpa.free(owned);
    }

    pub fn seriesCount(c: *Counters, io: Io) usize {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        return c.map.count();
    }

    /// Take everything counted so far, leaving the counters empty. The caller
    /// owns the result and either frees it (`freeMap`) once delivered or
    /// gives it back with `restore`.
    pub fn take(c: *Counters, io: Io) Map {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        const taken = c.map;
        c.map = .empty;
        return taken;
    }

    /// Put undelivered counts back, on top of whatever was counted meanwhile.
    pub fn restore(c: *Counters, gpa: std.mem.Allocator, io: Io, taken: *Map) void {
        var it = taken.iterator();
        while (it.next()) |entry| {
            const series = entry.key_ptr.*;
            const split = std.mem.findScalarLast(u8, series, '\n') orelse continue;
            c.add(gpa, io, series[0..split], series[split + 1 ..], entry.value_ptr.*);
        }
        freeMap(gpa, taken);
    }
};

pub fn freeMap(gpa: std.mem.Allocator, map: *Map) void {
    var it = map.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    map.deinit(gpa);
    map.* = .empty;
}

/// The request body for `POST /internal/counters`.
pub fn encode(gpa: std.mem.Allocator, map: *const Map) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"counters\":[");
    var first = true;
    var it = map.iterator();
    while (it.next()) |entry| {
        const series = entry.key_ptr.*;
        const split = std.mem.findScalarLast(u8, series, '\n') orelse continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"key\":");
        try std.json.Stringify.value(series[0..split], .{}, w);
        try w.writeAll(",\"reason\":");
        try std.json.Stringify.value(series[split + 1 ..], .{}, w);
        try w.print(",\"count\":{d}}}", .{entry.value_ptr.*});
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

/// Send what has been counted. Returns false when the control plane did not
/// take it (the counts are kept for the next attempt).
pub fn flushOnce(app: *App) bool {
    const c = app.counters;
    var taken = c.take(app.io);
    if (taken.count() == 0) {
        taken.deinit(app.gpa);
        return true;
    }
    const body = encode(app.gpa, &taken) catch {
        c.restore(app.gpa, app.io, &taken);
        return false;
    };
    defer app.gpa.free(body);

    control.postCounters(app, body) catch {
        c.restore(app.gpa, app.io, &taken);
        return false;
    };
    freeMap(app.gpa, &taken);
    return true;
}

/// Background task: hand the counters over every flush interval, backing off
/// while the control plane does not take them.
pub fn flushLoop(app: *App) Io.Cancelable!void {
    var delay_ms: i64 = app.flush_interval_ms;
    var healthy = true;
    while (true) {
        try app.io.sleep(.fromMilliseconds(delay_ms), .awake);
        if (flushOnce(app)) {
            healthy = true;
            delay_ms = app.flush_interval_ms;
        } else {
            // Once per outage. An older control plane without this endpoint
            // lands here too; the counts then just stay bounded in memory.
            if (healthy) log.debug("rejection counters not accepted by the control plane; keeping them", .{});
            healthy = false;
            delay_ms = @min(delay_ms * 2, max_backoff_ms);
        }
    }
}

const testing = std.testing;

fn countOf(map: *const Map, series: []const u8) u64 {
    return map.get(series) orelse 0;
}

test "counts per key and reason, and take empties the counters" {
    const gpa = testing.allocator;
    const io = testing.io;
    var c: Counters = .{};
    defer c.deinit(gpa);

    c.count(gpa, io, "app", "rate_limit_exceeded");
    c.count(gpa, io, "app", "rate_limit_exceeded");
    c.count(gpa, io, "app", "model_not_allowed");
    c.count(gpa, io, "", "invalid_api_key");
    c.count(gpa, io, unknown_key, "invalid_api_key");

    var taken = c.take(io);
    defer freeMap(gpa, &taken);
    try testing.expectEqual(@as(usize, 3), taken.count());
    try testing.expectEqual(@as(u64, 2), countOf(&taken, "app\nrate_limit_exceeded"));
    try testing.expectEqual(@as(u64, 1), countOf(&taken, "app\nmodel_not_allowed"));
    try testing.expectEqual(@as(u64, 2), countOf(&taken, "-\ninvalid_api_key"));
    try testing.expectEqual(@as(usize, 0), c.seriesCount(io));
}

test "undelivered counts are restored on top of new ones" {
    const gpa = testing.allocator;
    const io = testing.io;
    var c: Counters = .{};
    defer c.deinit(gpa);

    c.count(gpa, io, "app", "rate_limit_exceeded");
    var taken = c.take(io);
    // Counted while the failed delivery was in flight.
    c.count(gpa, io, "app", "rate_limit_exceeded");
    c.count(gpa, io, "other", "budget_exceeded");
    c.restore(gpa, io, &taken);

    var now = c.take(io);
    defer freeMap(gpa, &now);
    try testing.expectEqual(@as(u64, 2), countOf(&now, "app\nrate_limit_exceeded"));
    try testing.expectEqual(@as(u64, 1), countOf(&now, "other\nbudget_exceeded"));
}

test "past the series cap, new keys fold into the unknown key and nothing is lost" {
    const gpa = testing.allocator;
    const io = testing.io;
    var c: Counters = .{};
    defer c.deinit(gpa);

    var name_buf: [32]u8 = undefined;
    for (0..max_series + 250) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "key-{d}", .{i});
        c.count(gpa, io, name, "invalid_json");
    }
    // An existing series keeps counting under its own name.
    c.count(gpa, io, "key-0", "invalid_json");

    var taken = c.take(io);
    defer freeMap(gpa, &taken);
    try testing.expectEqual(@as(usize, max_series + 1), taken.count());
    try testing.expectEqual(@as(u64, 250), countOf(&taken, "-\ninvalid_json"));
    try testing.expectEqual(@as(u64, 2), countOf(&taken, "key-0\ninvalid_json"));

    var total: u64 = 0;
    var it = taken.valueIterator();
    while (it.next()) |v| total += v.*;
    try testing.expectEqual(@as(u64, max_series + 251), total);
}

test "the request body is valid JSON with escaped names" {
    const gpa = testing.allocator;
    const io = testing.io;
    var c: Counters = .{};
    defer c.deinit(gpa);
    c.count(gpa, io, "team \"a\"", "rate_limit_exceeded");

    var taken = c.take(io);
    defer freeMap(gpa, &taken);
    const body = try encode(gpa, &taken);
    defer gpa.free(body);
    try testing.expectEqualStrings(
        \\{"counters":[{"key":"team \"a\"","reason":"rate_limit_exceeded","count":1}]}
    , body);

    var empty: Map = .empty;
    const none = try encode(gpa, &empty);
    defer gpa.free(none);
    try testing.expectEqualStrings("{\"counters\":[]}", none);
}
