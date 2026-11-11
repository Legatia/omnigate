//! Usage spool: at-least-once delivery of usage events to the control plane.
//!
//! Requests never wait on the control plane. Each event is appended to an
//! in-memory queue and to a spool file; a background task sends batches and
//! retries with backoff. Events survive a control-plane outage (queue) and a
//! data-plane restart (spool file is reloaded on boot).
//!
//! The spool file is append-only between compactions: delivered events stay
//! at its front until either the queue drains (the file is emptied) or the
//! delivered part outweighs what is still pending (the file is rewritten to
//! hold only the pending events). So its size follows what is undelivered,
//! not how long the process has been running. After a crash it can hold
//! events that were already delivered; they are resent, and the control
//! plane drops them by event id.
//!
//! What happens when there is more than can be held (a long outage of the
//! control plane): the OLDEST events are kept and newer ones are dropped,
//! counted and logged. Oldest, because they are the ones a batch in flight
//! refers to (it is acknowledged by count from the front), and because a
//! queue that sheds from the front would turn one long outage into silent
//! loss of everything before it. The same rule applies to a spool file found
//! at startup that holds more than the queue may: the front of it is loaded,
//! the rest is discarded with an error in the log, and the gateway starts.
//! A large spool is never a reason not to start.
//!
//! Appends are not fsynced: a power loss can drop the last few events. That is
//! a deliberate trade against putting an fsync on every request.

const std = @import("std");
const Io = std.Io;
const control = @import("control.zig");
const App = @import("main.zig").App;

const log = std.log.scoped(.usage);
/// For losses an operator must see. (The test runner fails a run in which an
/// error was logged, and the tests provoke these on purpose.)
const loud = if (@import("builtin").is_test) log.warn else log.err;

/// Events per POST.
pub const batch_max = 500;
/// Events held while the control plane is unreachable. Beyond this, new
/// events are dropped (and counted) rather than exhausting memory.
pub const queue_max = 100_000;
const max_backoff_ms = 10_000;
/// ... and the bytes they may take, whatever their number.
pub const queue_max_bytes = 128 * 1024 * 1024;
/// The spool file is rewritten once the delivered events at its front take
/// more than this and more than the pending ones behind them.
const compact_min_dead_bytes = 1024 * 1024;
/// No event is this long; a longer line in a spool file is damage.
const max_line_bytes = 1024 * 1024;

pub const Limits = struct {
    max_events: usize = queue_max,
    max_bytes: usize = queue_max_bytes,
    compact_min_dead_bytes: usize = compact_min_dead_bytes,
};
/// Buffer kept allocated while the queue is empty.
const idle_capacity_max = 1024 * 1024;

pub const Batch = struct {
    body: []u8,
    count: usize,
};

pub const Reporter = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    /// The undelivered events, oldest first, as one run of bytes: each event
    /// is a line of JSON ending in '\n', exactly as in the spool file. One
    /// buffer that is reused, rather than one allocation per event that a
    /// request thread makes and the flush thread frees: that pattern makes
    /// memory creep under a thread-caching allocator.
    bytes: std.ArrayList(u8) = .empty,
    /// Offset in `bytes` of the oldest undelivered event.
    head: usize = 0,
    /// Events in `bytes[head..]`.
    count: usize = 0,
    file: ?Io.File = null,
    file_len: u64 = 0,
    dropped: u64 = 0,
    file_failed: bool = false,
    limits: Limits = .{},
    /// Times the spool file was rewritten to shed delivered events.
    compactions: u64 = 0,

    /// Opens (or creates) the spool file and reloads any events left in it.
    /// With `path == null` the spool is memory-only.
    pub fn init(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, path: ?[]const u8) !Reporter {
        return initWith(gpa, io, dir, path, .{});
    }

    pub fn initWith(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, path: ?[]const u8, limits: Limits) !Reporter {
        var r: Reporter = .{ .gpa = gpa, .io = io, .limits = limits };
        errdefer r.bytes.deinit(gpa);
        const p = path orelse return r;

        const file = try dir.createFile(io, p, .{ .read = true, .truncate = false });
        errdefer file.close(io);
        r.file = file;

        const len = try file.length(io);
        if (len == 0) return r;

        // Read in pieces, so that a spool of any size costs no more memory
        // than the events that are kept. A crash mid-append leaves a torn
        // final line; keep only whole, valid JSON lines so one bad line
        // cannot poison every batch.
        const piece = try gpa.alloc(u8, 256 * 1024);
        defer gpa.free(piece);
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        var line_too_long = false;
        var damaged = false;
        var full = false;
        var offset: u64 = 0;
        read: while (offset < len) {
            const n = try file.readPositionalAll(io, piece, offset);
            if (n == 0) break;
            offset += n;
            var rest: []const u8 = piece[0..n];
            while (std.mem.findScalar(u8, rest, '\n')) |nl| {
                const whole: []const u8 = if (line.items.len == 0) rest[0..nl] else whole: {
                    if (line.items.len + nl <= max_line_bytes) try line.appendSlice(gpa, rest[0..nl]) else line_too_long = true;
                    break :whole line.items;
                };
                rest = rest[nl + 1 ..];
                defer {
                    line.clearRetainingCapacity();
                    line_too_long = false;
                }
                if (whole.len == 0 and !line_too_long) continue;
                if (line_too_long or !(try std.json.validate(gpa, whole))) {
                    damaged = true;
                    continue;
                }
                if (r.count >= limits.max_events or r.bytes.items.len + whole.len + 1 > limits.max_bytes) {
                    full = true;
                    break :read;
                }
                try r.bytes.ensureUnusedCapacity(gpa, whole.len + 1);
                r.bytes.appendSliceAssumeCapacity(whole);
                r.bytes.appendAssumeCapacity('\n');
                r.count += 1;
            }
            if (line.items.len + rest.len <= max_line_bytes) try line.appendSlice(gpa, rest) else line_too_long = true;
        }
        // Whatever is left without a line ending is a torn append.
        if (!full and (line.items.len > 0 or line_too_long)) damaged = true;

        if (full) {
            // Not a reason to stay down: say what is lost, loudly, and start.
            loud("the usage spool holds more than can be queued ({d} bytes on disk): keeping the oldest {d} events ({d} bytes) and DISCARDING the rest", .{ len, r.count, r.bytes.items.len });
        } else if (damaged) {
            log.warn("spool had damaged data; rewriting it", .{});
        }
        if (full or damaged) {
            // Overwrite, then cut: at every moment the file holds each kept
            // event at least once.
            try file.writePositionalAll(io, r.bytes.items, 0);
            try file.setLength(io, r.bytes.items.len);
            r.file_len = r.bytes.items.len;
        } else {
            r.file_len = offset;
        }

        if (r.count > 0) {
            log.info("reloaded {d} undelivered usage events from spool", .{r.count});
        }
        return r;
    }

    pub fn deinit(r: *Reporter) void {
        r.bytes.deinit(r.gpa);
        if (r.file) |f| f.close(r.io);
    }

    pub fn pending(r: *Reporter) usize {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        return r.count;
    }

    /// Queue one JSON-encoded event. Never blocks on the network.
    pub fn enqueue(r: *Reporter, json: []const u8) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);

        // The oldest are kept (see the module comment for why).
        if (r.count >= r.limits.max_events or r.bytes.items.len - r.head + json.len + 1 > r.limits.max_bytes)
            return r.drop("queue full");

        r.bytes.ensureUnusedCapacity(r.gpa, json.len + 1) catch return r.drop("out of memory");
        const start = r.bytes.items.len;
        r.bytes.appendSliceAssumeCapacity(json);
        r.bytes.appendAssumeCapacity('\n');
        r.count += 1;

        if (r.file) |f| {
            const line = r.bytes.items[start..];
            if (f.writePositionalAll(r.io, line, r.file_len)) |_| {
                r.file_len += line.len;
            } else |err| {
                // Still queued in memory; only restart-durability is lost.
                if (!r.file_failed) log.err("spool write failed ({t}); usage is memory-only until it recovers", .{err});
                r.file_failed = true;
            }
        }
    }

    fn drop(r: *Reporter, reason: []const u8) void {
        r.dropped += 1;
        if (r.dropped == 1 or r.dropped % 1000 == 0) {
            loud("dropping usage event ({s}); {d} dropped so far", .{ reason, r.dropped });
        }
    }

    /// Builds `{"events":[...]}` from the oldest events. Caller frees `body`.
    /// The events stay queued until `ack`.
    pub fn nextBatch(r: *Reporter, gpa: std.mem.Allocator) !?Batch {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);

        const count = @min(r.count, batch_max);
        if (count == 0) return null;

        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try out.writer.writeAll("{\"events\":[");
        var rest: []const u8 = r.bytes.items[r.head..];
        for (0..count) |i| {
            // Always found: every queued event ends in '\n', and JSON text
            // never contains a raw one.
            const end = std.mem.findScalar(u8, rest, '\n').?;
            if (i != 0) try out.writer.writeByte(',');
            try out.writer.writeAll(rest[0..end]);
            rest = rest[end + 1 ..];
        }
        try out.writer.writeAll("]}");
        return .{ .body = try out.toOwnedSlice(), .count = count };
    }

    /// Removes the `count` oldest events after the control plane accepted them.
    pub fn ack(r: *Reporter, count: usize) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);

        for (0..count) |_| {
            const end = std.mem.findScalar(u8, r.bytes.items[r.head..], '\n').?;
            r.head += end + 1;
        }
        r.count -= count;

        if (r.count == 0) {
            r.head = 0;
            // Keep a modest buffer for reuse; give back what an outage piled up.
            if (r.bytes.capacity > idle_capacity_max) r.bytes.clearAndFree(r.gpa) else r.bytes.clearRetainingCapacity();
            if (r.file) |f| {
                if (f.setLength(r.io, 0)) |_| {
                    r.file_len = 0;
                    r.file_failed = false;
                } else |err| {
                    log.warn("spool truncate failed: {t}", .{err});
                }
            }
        } else {
            if (r.head >= r.bytes.items.len / 2) {
                // Slide the remaining events to the front so the delivered part
                // of the buffer is reused instead of growing behind us.
                const remaining = r.bytes.items.len - r.head;
                std.mem.copyForwards(u8, r.bytes.items[0..remaining], r.bytes.items[r.head..]);
                r.bytes.shrinkRetainingCapacity(remaining);
                r.head = 0;
            }
            r.compactFile();
        }
    }

    /// Rewrite the spool file to hold only the pending events, once the
    /// delivered ones at its front outweigh them. Without this a gateway
    /// whose queue never quite empties (steady traffic) would grow the file
    /// for as long as it runs. Called with the mutex held.
    ///
    /// The pending events are written over the front of the file and the
    /// file is then cut to their length. The bytes come from memory, so
    /// overwriting the region being replaced is safe, and a crash part way
    /// leaves a file in which every pending event is still present at least
    /// once (plus one torn line and some duplicates, both of which a reload
    /// and the ledger's dedup deal with).
    fn compactFile(r: *Reporter) void {
        const f = r.file orelse return;
        const pending_bytes = r.bytes.items[r.head..];
        const dead = r.file_len -| pending_bytes.len;
        if (dead < r.limits.compact_min_dead_bytes or dead < pending_bytes.len) return;
        f.writePositionalAll(r.io, pending_bytes, 0) catch |err| {
            if (!r.file_failed) log.err("spool rewrite failed ({t}); usage is memory-only until it recovers", .{err});
            r.file_failed = true;
            return;
        };
        f.setLength(r.io, pending_bytes.len) catch |err| {
            // The file is whole but still long; appends go on at its end.
            log.warn("spool truncate failed: {t}", .{err});
            return;
        };
        r.file_len = pending_bytes.len;
        r.file_failed = false;
        r.compactions += 1;
    }
};

/// Background task: deliver queued events, retrying with backoff.
pub fn flushLoop(app: *App) Io.Cancelable!void {
    const r = app.reporter;
    var delay_ms: i64 = app.flush_interval_ms;
    var healthy = true;

    while (true) {
        try app.io.sleep(.fromMilliseconds(delay_ms), .awake);

        while (true) {
            const batch = (r.nextBatch(app.gpa) catch null) orelse break;
            defer app.gpa.free(batch.body);

            const outcome = control.postUsageBatch(app, batch.body) catch |err| {
                // Delivered once: pass it on, or this loop outlives the stop
                // (see control.pollLoop). The batch stays queued.
                if (err == error.Canceled) return error.Canceled;
                if (healthy) log.warn("usage delivery failed ({t}); spooling, {d} events queued", .{ err, r.pending() });
                healthy = false;
                delay_ms = @min(delay_ms * 2, max_backoff_ms);
                break;
            };
            switch (outcome) {
                .accepted => {},
                // The control plane will never take this batch; retrying
                // would block every later event behind it.
                .rejected => log.err("control plane rejected a usage batch; discarding {d} events", .{batch.count}),
            }
            r.ack(batch.count);
            if (!healthy) log.info("usage delivery resumed", .{});
            healthy = true;
            delay_ms = app.flush_interval_ms;
        }
    }
}

/// One last, bounded attempt to hand over what is queued. For shutdown, after
/// the flush task has stopped (two senders would send the same batch twice).
/// Returns how many events are still waiting; with a spool file they are
/// picked up again at the next start.
pub fn drain(app: *App, max_batches: usize) usize {
    const r = app.reporter;
    var sent: usize = 0;
    while (sent < max_batches) : (sent += 1) {
        const batch = (r.nextBatch(app.gpa) catch null) orelse break;
        defer app.gpa.free(batch.body);
        _ = control.postUsageBatch(app, batch.body) catch break;
        r.ack(batch.count);
    }
    return r.pending();
}

const testing = std.testing;

test "events are batched in order and removed on ack" {
    var r = try Reporter.init(testing.allocator, testing.io, Io.Dir.cwd(), null);
    defer r.deinit();

    r.enqueue("{\"id\":\"a\"}");
    r.enqueue("{\"id\":\"b\"}");
    r.enqueue("{\"id\":\"c\"}");

    const batch = (try r.nextBatch(testing.allocator)).?;
    defer testing.allocator.free(batch.body);
    try testing.expectEqual(@as(usize, 3), batch.count);
    try testing.expectEqualStrings("{\"events\":[{\"id\":\"a\"},{\"id\":\"b\"},{\"id\":\"c\"}]}", batch.body);

    // Not acked yet: a failed send must find the same events again.
    try testing.expectEqual(@as(usize, 3), r.pending());

    r.enqueue("{\"id\":\"d\"}");
    r.ack(batch.count);
    try testing.expectEqual(@as(usize, 1), r.pending());

    const rest = (try r.nextBatch(testing.allocator)).?;
    defer testing.allocator.free(rest.body);
    try testing.expectEqualStrings("{\"events\":[{\"id\":\"d\"}]}", rest.body);
}

test "delivered events are forgotten while new ones keep arriving" {
    var r = try Reporter.init(testing.allocator, testing.io, Io.Dir.cwd(), null);
    defer r.deinit();

    // Many rounds of: queue some, deliver fewer, so the buffer both slides
    // and wraps its bookkeeping many times.
    var next_id: usize = 0;
    var next_expected: usize = 0;
    var buf: [48]u8 = undefined;
    for (0..200) |round| {
        for (0..7) |_| {
            r.enqueue(try std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{next_id}));
            next_id += 1;
        }
        const take = 3 + round % 5;
        const batch = (try r.nextBatch(testing.allocator)).?;
        defer testing.allocator.free(batch.body);
        // The batch starts with the oldest undelivered event.
        const first = try std.fmt.bufPrint(&buf, "{{\"events\":[{{\"id\":{d}}}", .{next_expected});
        try testing.expect(std.mem.startsWith(u8, batch.body, first));
        const n = @min(take, batch.count);
        r.ack(n);
        next_expected += n;
        try testing.expectEqual(next_id - next_expected, r.pending());
    }
    // The buffer holds what is pending, not everything that ever passed through.
    try testing.expect(r.bytes.items.len < 64 * 1024);

    while (try r.nextBatch(testing.allocator)) |batch| {
        defer testing.allocator.free(batch.body);
        r.ack(batch.count);
    }
    try testing.expectEqual(@as(usize, 0), r.pending());
    try testing.expectEqual(@as(usize, 0), r.bytes.items.len);
}

test "a batch is capped at batch_max" {
    var r = try Reporter.init(testing.allocator, testing.io, Io.Dir.cwd(), null);
    defer r.deinit();

    for (0..batch_max + 7) |_| r.enqueue("{}");
    const batch = (try r.nextBatch(testing.allocator)).?;
    defer testing.allocator.free(batch.body);
    try testing.expectEqual(@as(usize, batch_max), batch.count);
    r.ack(batch.count);
    try testing.expectEqual(@as(usize, 7), r.pending());
}

test "undelivered events survive a restart via the spool file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var r = try Reporter.init(testing.allocator, testing.io, tmp.dir, "usage.spool");
        defer r.deinit();
        r.enqueue("{\"id\":\"a\"}");
        r.enqueue("{\"id\":\"b\"}");
    }
    {
        var r = try Reporter.init(testing.allocator, testing.io, tmp.dir, "usage.spool");
        defer r.deinit();
        try testing.expectEqual(@as(usize, 2), r.pending());
        const batch = (try r.nextBatch(testing.allocator)).?;
        defer testing.allocator.free(batch.body);
        try testing.expectEqualStrings("{\"events\":[{\"id\":\"a\"},{\"id\":\"b\"}]}", batch.body);
        r.ack(batch.count);
    }
    {
        // Fully acked: nothing is resent after the next restart.
        var r = try Reporter.init(testing.allocator, testing.io, tmp.dir, "usage.spool");
        defer r.deinit();
        try testing.expectEqual(@as(usize, 0), r.pending());
    }
}

test "a torn final line in the spool is discarded, not sent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "usage.spool",
        .data = "{\"id\":\"a\"}\n{\"id\":\"b\",\"inp",
    });

    {
        var r = try Reporter.init(testing.allocator, testing.io, tmp.dir, "usage.spool");
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), r.pending());
        // New events must land on a clean line, not glued to the torn one.
        r.enqueue("{\"id\":\"c\"}");
    }
    {
        var r = try Reporter.init(testing.allocator, testing.io, tmp.dir, "usage.spool");
        defer r.deinit();
        const batch = (try r.nextBatch(testing.allocator)).?;
        defer testing.allocator.free(batch.body);
        try testing.expectEqualStrings("{\"events\":[{\"id\":\"a\"},{\"id\":\"c\"}]}", batch.body);
    }
}

test "the spool file follows what is pending, not how long the gateway has run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var r = try Reporter.initWith(testing.allocator, testing.io, tmp.dir, "usage.spool", .{ .compact_min_dead_bytes = 4096 });
    defer r.deinit();

    // Steady traffic with a queue that never empties: every round queues
    // ten events and delivers ten, always leaving a backlog of five.
    var buf: [96]u8 = undefined;
    var next_id: usize = 0;
    var delivered: usize = 0;
    for (0..5) |_| {
        r.enqueue(try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"pad\":\"0123456789012345678901234567890123456789\"}}", .{next_id}));
        next_id += 1;
    }
    var largest: u64 = 0;
    for (0..2000) |_| {
        for (0..10) |_| {
            r.enqueue(try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"pad\":\"0123456789012345678901234567890123456789\"}}", .{next_id}));
            next_id += 1;
        }
        r.ack(10);
        delivered += 10;
        try testing.expect(r.pending() == 5);
        largest = @max(largest, r.file_len);
    }
    // 20,000 events of ~60 bytes went through; the file never held more
    // than a few kilobytes of them.
    try testing.expect(r.compactions > 100);
    try testing.expect(largest < 16 * 1024);
    try testing.expectEqual(try r.file.?.length(testing.io), r.file_len);

    // What a restart finds: the backlog, in order, after at most the few
    // delivered events that had not been shed yet (the ledger drops those).
    var again = try Reporter.init(testing.allocator, testing.io, tmp.dir, "usage.spool");
    defer again.deinit();
    try testing.expect(again.pending() >= 5 and again.pending() < 300);
    const batch = (try again.nextBatch(testing.allocator)).?;
    defer testing.allocator.free(batch.body);
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(testing.allocator);
    for (delivered..next_id) |id| {
        try tail.print(testing.allocator, "{{\"id\":{d},\"pad\":\"0123456789012345678901234567890123456789\"}}{s}", .{ id, if (id + 1 == next_id) "]}" else "," });
    }
    try testing.expectEqual(@as(usize, 5), next_id - delivered);
    try testing.expect(std.mem.endsWith(u8, batch.body, tail.items));
}

test "a spool larger than the queue is cut down at startup, never a reason not to start" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // 5,000 events on disk, a queue that may hold 100.
    {
        var big: std.ArrayList(u8) = .empty;
        defer big.deinit(testing.allocator);
        for (0..5000) |i| try big.print(testing.allocator, "{{\"id\":{d}}}\n", .{i});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "usage.spool", .data = big.items });
    }
    {
        var r = try Reporter.initWith(testing.allocator, testing.io, tmp.dir, "usage.spool", .{ .max_events = 100 });
        defer r.deinit();
        try testing.expectEqual(@as(usize, 100), r.pending());
        // The oldest are the ones kept, and the file now holds only them.
        const batch = (try r.nextBatch(testing.allocator)).?;
        defer testing.allocator.free(batch.body);
        try testing.expect(std.mem.startsWith(u8, batch.body, "{\"events\":[{\"id\":0},{\"id\":1},"));
        try testing.expect(std.mem.endsWith(u8, batch.body, "{\"id\":99}]}"));
        try testing.expectEqual(r.file_len, try r.file.?.length(testing.io));
        try testing.expect(r.file_len < 1024);
        // Full: a new event is dropped and counted, not queued.
        r.enqueue("{\"id\":\"new\"}");
        try testing.expectEqual(@as(usize, 100), r.pending());
        try testing.expectEqual(@as(u64, 1), r.dropped);
    }
    // The byte limit works the same way.
    {
        var r = try Reporter.initWith(testing.allocator, testing.io, tmp.dir, "usage.spool", .{ .max_bytes = 64 });
        defer r.deinit();
        try testing.expectEqual(@as(usize, 7), r.pending()); // seven 9-byte lines fit in 64 bytes
    }
}

test "a spool with a line that never ends is survived" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(testing.allocator);
        try data.appendSlice(testing.allocator, "{\"id\":\"a\"}\n");
        try data.appendNTimes(testing.allocator, 'x', max_line_bytes + 300 * 1024);
        try data.appendSlice(testing.allocator, "\n{\"id\":\"b\"}\n\n{\"id\":\"c\"}\n");
        try data.appendNTimes(testing.allocator, 'y', max_line_bytes + 5);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "usage.spool", .data = data.items });
    }
    var r = try Reporter.init(testing.allocator, testing.io, tmp.dir, "usage.spool");
    defer r.deinit();
    const batch = (try r.nextBatch(testing.allocator)).?;
    defer testing.allocator.free(batch.body);
    try testing.expectEqualStrings("{\"events\":[{\"id\":\"a\"},{\"id\":\"b\"},{\"id\":\"c\"}]}", batch.body);
    try testing.expectEqual(@as(u64, 33), r.file_len);
}
