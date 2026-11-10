//! Usage spool: at-least-once delivery of usage events to the control plane.
//!
//! Requests never wait on the control plane. Each event is appended to an
//! in-memory queue and to a spool file; a background task sends batches and
//! retries with backoff. Events survive a control-plane outage (queue) and a
//! data-plane restart (spool file is reloaded on boot).
//!
//! The spool file is truncated only when the queue drains completely. After a
//! crash it can therefore hold events that were already delivered; they are
//! resent, and the control plane drops them by event id.
//!
//! Appends are not fsynced: a power loss can drop the last few events. That is
//! a deliberate trade against putting an fsync on every request.

const std = @import("std");
const Io = std.Io;
const control = @import("control.zig");
const App = @import("main.zig").App;

const log = std.log.scoped(.usage);

/// Events per POST.
pub const batch_max = 500;
/// Events held while the control plane is unreachable. Beyond this, new
/// events are dropped (and counted) rather than exhausting memory.
pub const queue_max = 100_000;
const max_backoff_ms = 10_000;
const max_spool_bytes = 256 * 1024 * 1024;

pub const Batch = struct {
    body: []u8,
    count: usize,
};

pub const Reporter = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    /// Owned lines, each ending in '\n' exactly as stored in the spool file.
    queue: std.ArrayList([]u8) = .empty,
    file: ?Io.File = null,
    file_len: u64 = 0,
    dropped: u64 = 0,
    file_failed: bool = false,

    /// Opens (or creates) the spool file and reloads any events left in it.
    /// With `path == null` the spool is memory-only.
    pub fn init(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, path: ?[]const u8) !Reporter {
        var r: Reporter = .{ .gpa = gpa, .io = io };
        const p = path orelse return r;

        const file = try dir.createFile(io, p, .{ .read = true, .truncate = false });
        errdefer file.close(io);
        r.file = file;

        const len = try file.length(io);
        if (len == 0) return r;
        if (len > max_spool_bytes) return error.SpoolTooLarge;

        const buf = try gpa.alloc(u8, @intCast(len));
        defer gpa.free(buf);
        const n = try file.readPositionalAll(io, buf, 0);
        const data = buf[0..n];

        // A crash mid-append leaves a torn final line. Keep only whole,
        // valid JSON lines so one bad line cannot poison every batch.
        var damaged = n > 0 and data[n - 1] != '\n';
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (r.queue.items.len >= queue_max or !(try std.json.validate(gpa, line))) {
                damaged = true;
                continue;
            }
            const owned = try gpa.alloc(u8, line.len + 1);
            @memcpy(owned[0..line.len], line);
            owned[line.len] = '\n';
            try r.queue.append(gpa, owned);
        }

        if (damaged) {
            log.warn("spool had damaged or excess data; rewriting it", .{});
            try file.setLength(io, 0);
            var off: u64 = 0;
            for (r.queue.items) |line| {
                try file.writePositionalAll(io, line, off);
                off += line.len;
            }
            r.file_len = off;
        } else {
            r.file_len = n;
        }

        if (r.queue.items.len > 0) {
            log.info("reloaded {d} undelivered usage events from spool", .{r.queue.items.len});
        }
        return r;
    }

    pub fn deinit(r: *Reporter) void {
        for (r.queue.items) |line| r.gpa.free(line);
        r.queue.deinit(r.gpa);
        if (r.file) |f| f.close(r.io);
    }

    pub fn pending(r: *Reporter) usize {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        return r.queue.items.len;
    }

    /// Queue one JSON-encoded event. Never blocks on the network.
    pub fn enqueue(r: *Reporter, json: []const u8) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);

        if (r.queue.items.len >= queue_max) return r.drop("queue full");

        const line = r.gpa.alloc(u8, json.len + 1) catch return r.drop("out of memory");
        @memcpy(line[0..json.len], json);
        line[json.len] = '\n';
        r.queue.append(r.gpa, line) catch {
            r.gpa.free(line);
            return r.drop("out of memory");
        };

        if (r.file) |f| {
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
            log.err("dropping usage event ({s}); {d} dropped so far", .{ reason, r.dropped });
        }
    }

    /// Builds `{"events":[...]}` from the oldest events. Caller frees `body`.
    /// The events stay queued until `ack`.
    pub fn nextBatch(r: *Reporter, gpa: std.mem.Allocator) !?Batch {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);

        const count = @min(r.queue.items.len, batch_max);
        if (count == 0) return null;

        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try out.writer.writeAll("{\"events\":[");
        for (r.queue.items[0..count], 0..) |line, i| {
            if (i != 0) try out.writer.writeByte(',');
            try out.writer.writeAll(line[0 .. line.len - 1]);
        }
        try out.writer.writeAll("]}");
        return .{ .body = try out.toOwnedSlice(), .count = count };
    }

    /// Removes the `count` oldest events after the control plane accepted them.
    pub fn ack(r: *Reporter, count: usize) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);

        for (r.queue.items[0..count]) |line| r.gpa.free(line);
        r.queue.replaceRangeAssumeCapacity(0, count, &.{});

        if (r.queue.items.len == 0) {
            if (r.file) |f| {
                if (f.setLength(r.io, 0)) |_| {
                    r.file_len = 0;
                    r.file_failed = false;
                } else |err| {
                    log.warn("spool truncate failed: {t}", .{err});
                }
            }
        }
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
