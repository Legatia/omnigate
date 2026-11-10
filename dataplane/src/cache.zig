//! Exact-match response cache for text requests.
//!
//! Opt-in per route (`cache_ttl_s` in the config). When a route has it, a
//! successful non-streaming answer is remembered, and an identical request
//! from the same gateway key within the TTL is answered from memory without
//! calling the provider.
//!
//! "Identical" means: same route model, same endpoint path, same gateway key,
//! and the same request JSON once object keys are put in a fixed order (so
//! `{"a":1,"b":2}` and `{"b":2,"a":1}` are one request; whitespace never
//! matters). The gateway key is part of the identity so that one key can
//! never be served another key's answer.
//!
//! The store is bounded by total bytes; the least recently used entries are
//! evicted first. It lives in this process only: a restart starts empty, and
//! several data planes each have their own.

const std = @import("std");
const Io = std.Io;

pub const Key = [32]u8;

/// What is charged against the byte budget per entry besides its payload.
const entry_overhead = 160;

pub const Hit = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
};

pub const Cache = struct {
    gpa: std.mem.Allocator,
    /// 0 turns the cache off altogether.
    max_bytes: usize,
    mutex: Io.Mutex = .init,
    map: std.AutoHashMapUnmanaged(Key, *Entry) = .empty,
    /// Most recently used first.
    lru: std.DoublyLinkedList = .{},
    bytes: usize = 0,

    const Entry = struct {
        node: std.DoublyLinkedList.Node = .{},
        key: Key,
        status: u16,
        content_type: []u8,
        body: []u8,
        expires_ms: i64,

        fn cost(e: *const Entry) usize {
            return e.body.len + e.content_type.len + entry_overhead;
        }
    };

    pub fn init(gpa: std.mem.Allocator, max_bytes: usize) Cache {
        return .{ .gpa = gpa, .max_bytes = max_bytes };
    }

    pub fn deinit(c: *Cache) void {
        var it = c.map.valueIterator();
        while (it.next()) |e| c.free(e.*);
        c.map.deinit(c.gpa);
    }

    /// The largest answer worth keeping: one entry may not push out most of
    /// the cache.
    pub fn maxEntryBytes(c: *const Cache) usize {
        return c.max_bytes / 4;
    }

    /// A live entry, copied into `arena` so the caller holds no lock and the
    /// entry may be evicted while the answer is being written.
    pub fn get(c: *Cache, io: Io, arena: std.mem.Allocator, key: *const Key, now_ms: i64) ?Hit {
        if (c.max_bytes == 0) return null;
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);

        const e = c.map.get(key.*) orelse return null;
        if (now_ms >= e.expires_ms) {
            c.remove(e);
            return null;
        }
        const body = arena.dupe(u8, e.body) catch return null;
        const content_type = arena.dupe(u8, e.content_type) catch return null;
        // Used just now: move to the front.
        c.lru.remove(&e.node);
        c.lru.prepend(&e.node);
        return .{ .status = e.status, .content_type = content_type, .body = body };
    }

    /// Remember an answer for `ttl_ms`. Silently does nothing when the answer
    /// is too large or memory is short: a cache may always decline.
    pub fn put(c: *Cache, io: Io, key: *const Key, status: u16, content_type: []const u8, body: []const u8, ttl_ms: i64, now_ms: i64) void {
        if (c.max_bytes == 0 or ttl_ms <= 0) return;
        if (body.len + content_type.len + entry_overhead > c.maxEntryBytes()) return;

        const e = c.gpa.create(Entry) catch return;
        const body_copy = c.gpa.dupe(u8, body) catch {
            c.gpa.destroy(e);
            return;
        };
        const type_copy = c.gpa.dupe(u8, content_type) catch {
            c.gpa.free(body_copy);
            c.gpa.destroy(e);
            return;
        };
        e.* = .{ .key = key.*, .status = status, .content_type = type_copy, .body = body_copy, .expires_ms = now_ms + ttl_ms };

        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);

        if (c.map.get(key.*)) |old| c.remove(old);
        c.map.put(c.gpa, key.*, e) catch {
            c.free(e);
            return;
        };
        c.lru.prepend(&e.node);
        c.bytes += e.cost();

        // Make room: least recently used go first (never the one just added).
        while (c.bytes > c.max_bytes) {
            const last = c.lru.last orelse break;
            const victim: *Entry = @fieldParentPtr("node", last);
            if (victim == e) break;
            c.remove(victim);
        }
    }

    pub fn count(c: *Cache, io: Io) usize {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        return c.map.count();
    }

    pub fn usedBytes(c: *Cache, io: Io) usize {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        return c.bytes;
    }

    /// Caller holds the mutex.
    fn remove(c: *Cache, e: *Entry) void {
        _ = c.map.remove(e.key);
        c.lru.remove(&e.node);
        c.bytes -= e.cost();
        c.free(e);
    }

    fn free(c: *Cache, e: *Entry) void {
        c.gpa.free(e.body);
        c.gpa.free(e.content_type);
        c.gpa.destroy(e);
    }
};

/// The identity of a request: route model, endpoint path, gateway key hash,
/// and the request JSON in canonical form.
pub fn keyFor(arena: std.mem.Allocator, route_model: []const u8, path: []const u8, gateway_key_sha256: []const u8, request: std.json.Value) !Key {
    var canonical: Io.Writer.Allocating = .init(arena);
    try writeCanonical(arena, &canonical.writer, request);

    var h = std.crypto.hash.sha2.Sha256.init(.{});
    // Length-prefixed, so no choice of strings can make two different
    // requests hash the same input.
    for ([_][]const u8{ route_model, path, gateway_key_sha256, canonical.written() }) |part| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, part.len, .little);
        h.update(&len);
        h.update(part);
    }
    var out: Key = undefined;
    h.final(&out);
    return out;
}

/// JSON with object keys in byte order at every level and no whitespace.
pub fn writeCanonical(arena: std.mem.Allocator, w: *Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .object => |obj| {
            const keys = try arena.dupe([]const u8, obj.keys());
            std.mem.sort([]const u8, keys, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);
            try w.writeByte('{');
            for (keys, 0..) |k, i| {
                if (i > 0) try w.writeByte(',');
                try std.json.Stringify.value(k, .{}, w);
                try w.writeByte(':');
                try writeCanonical(arena, w, obj.get(k).?);
            }
            try w.writeByte('}');
        },
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeCanonical(arena, w, item);
            }
            try w.writeByte(']');
        },
        else => try std.json.Stringify.value(value, .{}, w),
    }
}

const testing = std.testing;

fn testKey(n: u8) Key {
    return @splat(n);
}

fn canonicalOf(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, text, .{});
    var out: Io.Writer.Allocating = .init(arena);
    try writeCanonical(arena, &out.writer, parsed.value);
    return out.written();
}

fn keyOf(arena: std.mem.Allocator, model: []const u8, path: []const u8, gateway_key: []const u8, text: []const u8) !Key {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, text, .{});
    return keyFor(arena, model, path, gateway_key, parsed.value);
}

test "canonical form ignores key order and whitespace at every depth, but not array order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try canonicalOf(arena,
        \\{ "model": "m", "messages": [ {"role": "user", "content": "hi"} ], "temperature": 0.5, "n": 1 }
    );
    const b = try canonicalOf(arena,
        \\{"temperature":0.5,"n":1,"messages":[{"content":"hi","role":"user"}],"model":"m"}
    );
    try testing.expectEqualStrings(a, b);
    try testing.expectEqualStrings(
        \\{"messages":[{"content":"hi","role":"user"}],"model":"m","n":1,"temperature":0.5}
    , a);

    const reordered = try canonicalOf(arena, "{\"x\":[1,2]}");
    const other = try canonicalOf(arena, "{\"x\":[2,1]}");
    try testing.expect(!std.mem.eql(u8, reordered, other));
}

test "the key separates models, paths, gateway keys and bodies" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "{\"model\":\"m\",\"messages\":[]}";
    const base = try keyOf(arena, "m", "/v1/chat/completions", "keyhash-a", body);
    try testing.expectEqual(base, try keyOf(arena, "m", "/v1/chat/completions", "keyhash-a", "{ \"messages\": [], \"model\": \"m\" }"));
    try testing.expect(!std.mem.eql(u8, &base, &try keyOf(arena, "m2", "/v1/chat/completions", "keyhash-a", body)));
    try testing.expect(!std.mem.eql(u8, &base, &try keyOf(arena, "m", "/v1/messages", "keyhash-a", body)));
    // Another gateway key never shares an entry.
    try testing.expect(!std.mem.eql(u8, &base, &try keyOf(arena, "m", "/v1/chat/completions", "keyhash-b", body)));
    try testing.expect(!std.mem.eql(u8, &base, &try keyOf(arena, "m", "/v1/chat/completions", "keyhash-a", "{\"model\":\"m\",\"messages\":[1]}")));
    // Moving a byte from one part to the next changes the key.
    try testing.expect(!std.mem.eql(u8, &try keyOf(arena, "ab", "c", "k", body), &try keyOf(arena, "a", "bc", "k", body)));
}

test "hit within the TTL, miss after it" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c: Cache = .init(testing.allocator, 1024 * 1024);
    defer c.deinit();
    const k = testKey(1);

    try testing.expectEqual(@as(?Hit, null), c.get(io, arena, &k, 0));
    c.put(io, &k, 200, "application/json", "{\"ok\":true}", 1000, 0);

    const hit = c.get(io, arena, &k, 999).?;
    try testing.expectEqual(@as(u16, 200), hit.status);
    try testing.expectEqualStrings("application/json", hit.content_type);
    try testing.expectEqualStrings("{\"ok\":true}", hit.body);

    try testing.expectEqual(@as(?Hit, null), c.get(io, arena, &k, 1000));
    // The expired entry is gone, not just hidden.
    try testing.expectEqual(@as(usize, 0), c.count(io));
    try testing.expectEqual(@as(usize, 0), c.usedBytes(io));
}

test "a newer answer replaces the older one" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var c: Cache = .init(testing.allocator, 1024 * 1024);
    defer c.deinit();
    const k = testKey(1);
    c.put(io, &k, 200, "application/json", "old", 1000, 0);
    c.put(io, &k, 200, "application/json", "newer", 1000, 0);
    try testing.expectEqualStrings("newer", c.get(io, arena_state.allocator(), &k, 1).?.body);
    try testing.expectEqual(@as(usize, 1), c.count(io));
}

test "eviction by size removes the least recently used first" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body: [1000]u8 = @splat('x');
    // Room for fourteen entries of this size, not fifteen.
    const per_entry = body.len + "t".len + entry_overhead;
    var big: Cache = .init(testing.allocator, per_entry * 14 + per_entry / 2);
    defer big.deinit();
    const capacity = big.max_bytes / per_entry;
    try testing.expectEqual(@as(usize, 14), capacity);

    for (0..capacity) |i| big.put(io, &testKey(@intCast(i)), 200, "t", &body, 1000, 0);
    try testing.expectEqual(capacity, big.count(io));

    // Touch the oldest, so the second oldest becomes the eviction candidate.
    try testing.expect(big.get(io, arena, &testKey(0), 1) != null);
    big.put(io, &testKey(200), 200, "t", &body, 1000, 1);

    try testing.expectEqual(capacity, big.count(io));
    try testing.expect(big.get(io, arena, &testKey(0), 2) != null);
    try testing.expectEqual(@as(?Hit, null), big.get(io, arena, &testKey(1), 2));
    try testing.expect(big.get(io, arena, &testKey(200), 2) != null);
    try testing.expect(big.usedBytes(io) <= big.max_bytes);
}

test "an answer larger than a quarter of the budget is not kept, and a zero budget keeps nothing" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c: Cache = .init(testing.allocator, 4000);
    defer c.deinit();
    const large: [2000]u8 = @splat('x');
    c.put(io, &testKey(1), 200, "t", &large, 1000, 0);
    try testing.expectEqual(@as(usize, 0), c.count(io));
    c.put(io, &testKey(2), 200, "t", "small", 1000, 0);
    try testing.expectEqual(@as(usize, 1), c.count(io));

    var off: Cache = .init(testing.allocator, 0);
    defer off.deinit();
    off.put(io, &testKey(1), 200, "t", "x", 1000, 0);
    try testing.expectEqual(@as(?Hit, null), off.get(io, arena, &testKey(1), 0));
}
