//! Bounds on what one request, and one gateway key, can make this process
//! hold in memory at once.
//!
//! A panic or an out-of-memory kill ends every connection, so nothing a
//! single client sends may decide how much memory the process uses:
//!
//!   * `Gate` caps how many requests of one key are in flight, and how many
//!     bytes of request memory they hold, in total and per key. It is
//!     consulted before a body is read.
//!   * `Tree` is where a body is parsed into a JSON value tree when that
//!     cannot be avoided (translation, the response cache, provider quirks).
//!     A tree can be hundreds of times the size of its text (a megabyte of
//!     `0,0,0,...` is 180 MiB of tree), so each one is built inside an
//!     allocator with a cap (`treeCap`), and the caps of all trees being
//!     built are reserved against a budget first (`Gate.reserveTree`), again
//!     in total and per key.
//!
//! Hitting any of these is an ordinary refusal (400, 429 or 503), not a
//! failure.

const std = @import("std");
const Io = std.Io;
const Alignment = std.mem.Alignment;

pub const Gate = struct {
    /// Requests of one key in flight at once; 0 = no cap. A key's own
    /// `max_concurrent` from the config, when set, takes its place.
    max_concurrent: u32 = 512,
    /// Bytes of request memory held at once by all keys; 0 = no cap.
    memory_budget: u64 = 1024 * 1024 * 1024,
    /// Bytes reserved at once for JSON value trees; 0 = no cap.
    tree_budget: u64 = 1024 * 1024 * 1024,
    mutex: Io.Mutex = .init,
    keys: std.AutoHashMapUnmanaged([64]u8, Entry) = .empty,
    total_bytes: u64 = 0,
    total_tree_bytes: u64 = 0,

    const Entry = struct { inflight: u32 = 0, bytes: u64 = 0, tree_bytes: u64 = 0 };

    pub const Admission = enum {
        ok,
        /// The key has `max_concurrent` requests in flight already.
        concurrency,
        /// The key holds its share of the budget already.
        key_share,
        /// The budget as a whole is spoken for.
        budget,
    };

    /// The share of the request-memory budget one key may hold: enough for
    /// a few of the largest requests, never all of it.
    pub fn keyShare(g: *const Gate) u64 {
        return g.memory_budget / 4;
    }

    /// The share of the tree budget one key may reserve. Half: a tree lives
    /// for the milliseconds a conversion takes, so a key with heavy traffic
    /// legitimately has several at once, and two keys cannot take it all.
    pub fn treeShare(g: *const Gate) u64 {
        return g.tree_budget / 2;
    }

    pub fn deinit(g: *Gate, gpa: std.mem.Allocator) void {
        g.keys.deinit(gpa);
    }

    /// Count a request of `key` as in flight, holding `bytes` of memory.
    /// Anything but `.ok` admits nothing; `.ok` must be paired with `leave`
    /// with the same `bytes`.
    pub fn enter(g: *Gate, gpa: std.mem.Allocator, io: Io, key: *const [64]u8, key_cap: u32, bytes: u64) Admission {
        const cap = if (key_cap != 0) key_cap else g.max_concurrent;
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        if (g.memory_budget != 0 and g.total_bytes +| bytes > g.memory_budget) return .budget;
        const gop = g.keys.getOrPut(gpa, key.*) catch {
            // The table cannot grow: without an entry there is nothing to
            // count against, and nothing `leave` could give back.
            return .budget;
        };
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const e = gop.value_ptr;
        const refused: ?Admission = if (cap != 0 and e.inflight >= cap)
            .concurrency
        else if (g.memory_budget != 0 and e.bytes +| bytes > g.keyShare())
            .key_share
        else
            null;
        if (refused) |why| {
            if (e.inflight == 0) _ = g.keys.remove(key.*);
            return why;
        }
        e.inflight += 1;
        e.bytes += bytes;
        g.total_bytes += bytes;
        return .ok;
    }

    pub fn leave(g: *Gate, io: Io, key: *const [64]u8, bytes: u64) void {
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        const e = g.keys.getPtr(key.*) orelse return;
        e.inflight -|= 1;
        const n = @min(bytes, e.bytes);
        e.bytes -= n;
        g.total_bytes -|= n;
        if (e.inflight == 0) {
            g.total_bytes -|= e.bytes;
            g.total_tree_bytes -|= e.tree_bytes;
            _ = g.keys.remove(key.*);
        }
    }

    /// Set aside `bytes` (a tree's cap) for a request of `key` that is in
    /// flight (it has `enter`ed). `.ok` must be paired with `releaseTree`.
    pub fn reserveTree(g: *Gate, io: Io, key: *const [64]u8, bytes: u64) Admission {
        if (g.tree_budget == 0) return .ok;
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        // No entry: not a request this gate knows. Nothing to hold it to.
        const e = g.keys.getPtr(key.*) orelse return .ok;
        if (e.tree_bytes +| bytes > g.treeShare()) return .key_share;
        if (g.total_tree_bytes +| bytes > g.tree_budget) return .budget;
        e.tree_bytes += bytes;
        g.total_tree_bytes += bytes;
        return .ok;
    }

    pub fn releaseTree(g: *Gate, io: Io, key: *const [64]u8, bytes: u64) void {
        if (g.tree_budget == 0) return;
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        const e = g.keys.getPtr(key.*) orelse return;
        const n = @min(bytes, e.tree_bytes);
        e.tree_bytes -= n;
        g.total_tree_bytes -|= n;
    }
};

/// What a tree of a text of `text_len` bytes may take. Measured on real
/// request shapes, a translation needs 10 to 70 times its text (a long
/// conversation of short messages is the densest; one long string needs 7),
/// and text made of nothing but tiny values needs 180 to 300. So: a multiple
/// that fits every ordinary request with room to spare, and above all a
/// ceiling that no request can pass whatever it is made of.
pub fn treeCap(text_len: usize) usize {
    return @min(tree_max, text_len *| tree_factor +| tree_slack);
}

pub const tree_factor = 128;
pub const tree_slack = 1024 * 1024;
/// The ceiling. Enough for the largest request body (8 MiB) when it is
/// mostly long strings, which is what large requests are (images, documents).
pub const tree_max = 96 * 1024 * 1024;

/// An allocator that hands out at most `left` bytes. Not thread safe: one
/// per request (or stream).
pub const Capped = struct {
    child: std.mem.Allocator,
    /// Bytes this allocator may still hand out.
    left: usize,
    held: usize = 0,
    /// An allocation was refused because of the cap (as opposed to the
    /// machine being out of memory).
    refused: bool = false,

    pub fn allocator(c: *Capped) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn grant(c: *Capped, n: usize) bool {
        if (n > c.left) {
            c.refused = true;
            return false;
        }
        c.left -= n;
        c.held += n;
        return true;
    }

    fn ungrant(c: *Capped, n: usize) void {
        c.left += n;
        c.held -= n;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        if (!c.grant(len)) return null;
        return c.child.rawAlloc(len, alignment, ret_addr) orelse {
            c.ungrant(len);
            return null;
        };
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) {
            if (!c.grant(new_len - memory.len)) return false;
            if (c.child.rawResize(memory, alignment, new_len, ret_addr)) return true;
            c.ungrant(new_len - memory.len);
            return false;
        }
        if (!c.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        c.ungrant(memory.len - new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) {
            if (!c.grant(new_len - memory.len)) return null;
            return c.child.rawRemap(memory, alignment, new_len, ret_addr) orelse {
                c.ungrant(new_len - memory.len);
                return null;
            };
        }
        const moved = c.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        c.ungrant(memory.len - new_len);
        return moved;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        c.child.rawFree(memory, alignment, ret_addr);
        c.ungrant(memory.len);
    }
};

/// An arena for one JSON value tree, capped (see the module comment). All of
/// it is returned by `deinit`; nothing allocated from it may outlive that.
pub const Tree = struct {
    capped: Capped,
    arena: std.heap.ArenaAllocator,

    /// `t` must not move after `init` (the arena points back into it).
    pub fn init(t: *Tree, child: std.mem.Allocator, cap: usize) void {
        t.capped = .{ .child = child, .left = cap };
        t.arena = .init(t.capped.allocator());
    }

    pub fn allocator(t: *Tree) std.mem.Allocator {
        return t.arena.allocator();
    }

    /// Did an allocation fail because of the cap (and not because the
    /// machine ran out of memory)?
    pub fn refused(t: *const Tree) bool {
        return t.capped.refused;
    }

    pub fn deinit(t: *Tree) void {
        t.arena.deinit();
        std.debug.assert(t.capped.held == 0);
    }
};

const testing = std.testing;

test "a key is held to its concurrency cap, and the cap can be per key" {
    const gpa = testing.allocator;
    const io = testing.io;
    var g: Gate = .{ .max_concurrent = 2 };
    defer g.deinit(gpa);
    const a: [64]u8 = @splat('a');
    const b: [64]u8 = @splat('b');
    const Admission = Gate.Admission;

    try testing.expectEqual(Admission.ok, g.enter(gpa, io, &a, 0, 0));
    try testing.expectEqual(Admission.ok, g.enter(gpa, io, &a, 0, 0));
    try testing.expectEqual(Admission.concurrency, g.enter(gpa, io, &a, 0, 0));
    // Another key is unaffected.
    try testing.expectEqual(Admission.ok, g.enter(gpa, io, &b, 0, 0));
    // The key's own cap, when it has one, replaces the default.
    try testing.expectEqual(Admission.ok, g.enter(gpa, io, &a, 3, 0));
    try testing.expectEqual(Admission.concurrency, g.enter(gpa, io, &a, 3, 0));
    try testing.expectEqual(Admission.concurrency, g.enter(gpa, io, &b, 1, 0));

    g.leave(io, &a, 0);
    try testing.expectEqual(Admission.ok, g.enter(gpa, io, &a, 3, 0));
    for (0..3) |_| g.leave(io, &a, 0);
    g.leave(io, &b, 0);
    // Nothing is remembered about idle keys, refused ones included.
    try testing.expectEqual(@as(u32, 0), g.keys.count());
    try testing.expectEqual(Admission.ok, g.enter(gpa, io, &a, 1, 0));
    try testing.expectEqual(Admission.concurrency, g.enter(gpa, io, &a, 1, 0));
    g.leave(io, &a, 0);
    try testing.expectEqual(@as(u32, 0), g.keys.count());

    var open: Gate = .{ .max_concurrent = 0 };
    defer open.deinit(gpa);
    for (0..1000) |_| try testing.expectEqual(Admission.ok, open.enter(gpa, io, &a, 0, 0));
}

test "request memory is bounded in total and per key" {
    const gpa = testing.allocator;
    const io = testing.io;
    var g: Gate = .{ .memory_budget = 1000 };
    defer g.deinit(gpa);
    const keys = [_][64]u8{ @splat('a'), @splat('b'), @splat('c'), @splat('d'), @splat('e') };
    const Admission = Gate.Admission;

    // One key gets a quarter, however it is split over requests.
    try testing.expectEqual(Admission.ok, g.enter(gpa, io, &keys[0], 0, 200));
    try testing.expectEqual(Admission.ok, g.enter(gpa, io, &keys[0], 0, 50));
    try testing.expectEqual(Admission.key_share, g.enter(gpa, io, &keys[0], 0, 1));
    try testing.expectEqual(Admission.ok, g.enter(gpa, io, &keys[0], 0, 0));
    for (keys[1..4]) |*k| try testing.expectEqual(Admission.ok, g.enter(gpa, io, k, 0, 250));
    // The whole budget is spoken for; a request that needs none still fits.
    try testing.expectEqual(Admission.budget, g.enter(gpa, io, &keys[4], 0, 1));
    try testing.expectEqual(Admission.ok, g.enter(gpa, io, &keys[4], 0, 0));
    g.leave(io, &keys[4], 0);
    g.leave(io, &keys[1], 250);
    try testing.expectEqual(Admission.ok, g.enter(gpa, io, &keys[4], 0, 250));
    try testing.expectEqual(@as(u64, 1000), g.total_bytes);

    // Everything is given back, even if a caller gets its sums wrong.
    g.leave(io, &keys[0], 200);
    g.leave(io, &keys[0], 50);
    g.leave(io, &keys[0], 0);
    g.leave(io, &keys[2], 9999);
    g.leave(io, &keys[3], 0);
    g.leave(io, &keys[4], 250);
    try testing.expectEqual(@as(u64, 0), g.total_bytes);
    try testing.expectEqual(@as(u32, 0), g.keys.count());

    var open: Gate = .{ .memory_budget = 0 };
    defer open.deinit(gpa);
    try testing.expectEqual(Admission.ok, open.enter(gpa, io, &keys[0], 0, 1 << 40));
}

test "tree memory is reserved before it is used, in total and per key" {
    const gpa = testing.allocator;
    const io = testing.io;
    var g: Gate = .{ .tree_budget = 1000 };
    defer g.deinit(gpa);
    const keys = [_][64]u8{ @splat('a'), @splat('b'), @splat('c') };
    const Admission = Gate.Admission;
    for (&keys) |*k| try testing.expectEqual(Admission.ok, g.enter(gpa, io, k, 0, 0));

    // One key gets half ...
    try testing.expectEqual(Admission.ok, g.reserveTree(io, &keys[0], 300));
    try testing.expectEqual(Admission.ok, g.reserveTree(io, &keys[0], 200));
    try testing.expectEqual(Admission.key_share, g.reserveTree(io, &keys[0], 1));
    // ... and all of them together no more than the budget.
    try testing.expectEqual(Admission.ok, g.reserveTree(io, &keys[1], 400));
    try testing.expectEqual(Admission.budget, g.reserveTree(io, &keys[2], 101));
    try testing.expectEqual(Admission.ok, g.reserveTree(io, &keys[2], 100));
    g.releaseTree(io, &keys[0], 300);
    try testing.expectEqual(Admission.ok, g.reserveTree(io, &keys[0], 250));
    try testing.expectEqual(@as(u64, 950), g.total_tree_bytes);

    // A request that ends takes its reservations with it, released or not.
    g.leave(io, &keys[0], 0);
    try testing.expectEqual(@as(u64, 500), g.total_tree_bytes);
    g.releaseTree(io, &keys[1], 400);
    g.releaseTree(io, &keys[1], 400); // twice: nothing to give back the second time
    g.releaseTree(io, &keys[2], 100);
    try testing.expectEqual(@as(u64, 0), g.total_tree_bytes);
    g.leave(io, &keys[1], 0);
    g.leave(io, &keys[2], 0);

    var open: Gate = .{ .tree_budget = 0 };
    defer open.deinit(gpa);
    try testing.expectEqual(Admission.ok, open.reserveTree(io, &keys[0], 1 << 40));
}

test "what a tree may take: a multiple of its text, and never more than the ceiling" {
    try testing.expectEqual(@as(usize, tree_slack), treeCap(0));
    try testing.expectEqual(@as(usize, 100 * tree_factor + tree_slack), treeCap(100));
    try testing.expectEqual(@as(usize, tree_max), treeCap(8 * 1024 * 1024));
    try testing.expectEqual(@as(usize, tree_max), treeCap(std.math.maxInt(usize)));
}

test "a tree is stopped at its cap, whatever the text is made of" {
    const gpa = testing.allocator;

    // A megabyte of nothing but zeros in an array: a tree of it would take
    // well over a hundred megabytes. The parse is stopped at the cap.
    const n = 512 * 1024;
    const text = try gpa.alloc(u8, 2 * n + 1);
    defer gpa.free(text);
    text[0] = '[';
    for (0..n) |i| {
        text[1 + 2 * i] = '0';
        text[2 + 2 * i] = if (i + 1 == n) ']' else ',';
    }
    {
        var tree: Tree = undefined;
        tree.init(gpa, 4 * 1024 * 1024);
        defer tree.deinit();
        try testing.expectError(error.OutOfMemory, std.json.parseFromSliceLeaky(std.json.Value, tree.allocator(), text, .{}));
        try testing.expect(tree.refused());
        try testing.expect(tree.capped.held <= 4 * 1024 * 1024);
    }
    {
        // An ordinary document fits in the smallest cap there is, and
        // everything is given back.
        var tree: Tree = undefined;
        tree.init(gpa, treeCap(0));
        const v = try std.json.parseFromSliceLeaky(std.json.Value, tree.allocator(), "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}", .{});
        try testing.expect(v == .object);
        try testing.expect(!tree.refused());
        try testing.expect(tree.capped.held > 0);
        tree.deinit();
        try testing.expectEqual(@as(usize, 0), tree.capped.held);
    }
}
