//! Deadlines for client connections.
//!
//! A read from a client that never sends, or from an upstream that goes
//! silent in the middle of a stream, would otherwise hold its task (and
//! thread) for ever. Every connection task has a `Conn`; it arms a deadline
//! before it may block and re-arms it whenever bytes move. One background
//! task sweeps the connections a few times a second and cancels the task of
//! any whose deadline has passed: the blocked read or write then fails with
//! `error.Canceled`, and the task sees `timedOut()`.
//!
//! Cancelling the task, rather than shutting the socket down, is what works
//! everywhere: on Windows a socket shutdown from another thread does not wake
//! a blocked read.
//!
//! Arming costs one clock read and one atomic store, unlike racing each read
//! against a timer task, so it is cheap enough to do for every chunk of a
//! stream.
//!
//! The same sweep frees the bookkeeping of connections that have finished.

const std = @import("std");
const Io = std.Io;

pub const sweep_interval_ms = 250;

pub const Conn = struct {
    stream: Io.net.Stream,
    /// The connection's task. Null only in tests. Touched by the watchdog
    /// task alone (and by `cancelAll` once that task has stopped).
    future: ?Io.Future(void) = null,
    node: std.DoublyLinkedList.Node = .{},
    /// Monotonic milliseconds after which the task is cancelled; 0 = not armed.
    deadline_ms: std.atomic.Value(i64) = .init(0),
    fired: std.atomic.Value(bool) = .init(false),
    /// True while the connection waits for its next request: closing it then
    /// loses nothing, which is what a graceful stop wants to know.
    idle: std.atomic.Value(bool) = .init(false),
    /// Set by the task as its last act.
    done: std.atomic.Value(bool) = .init(false),
    /// Scratch link used inside one sweep.
    next_victim: ?*Conn = null,

    /// Cancel the task if nothing re-arms or disarms within `timeout_ms`.
    /// 0 disarms.
    pub fn arm(c: *Conn, io: Io, timeout_ms: u32) void {
        if (timeout_ms == 0) return c.disarm();
        c.deadline_ms.store(nowMs(io) + timeout_ms, .release);
    }

    pub fn disarm(c: *Conn) void {
        c.deadline_ms.store(0, .release);
    }

    /// Did the watchdog cancel this connection?
    pub fn timedOut(c: *const Conn) bool {
        return c.fired.load(.acquire);
    }
};

pub const Watchdog = struct {
    /// Allocates the `Conn`s. Null in tests, which bring their own.
    gpa: ?std.mem.Allocator = null,
    mutex: Io.Mutex = .init,
    conns: std.DoublyLinkedList = .{},
    /// Set at shutdown: treat idle connections as expired.
    stop_idle: std.atomic.Value(bool) = .init(false),
    /// Finished `Conn`s kept for reuse (linked through `next_victim`). They
    /// are handed out on the accept thread and given back on the watchdog
    /// thread; recycling them here keeps that cross-thread traffic away from
    /// the allocator. Never more of them than the peak number of connections.
    spare: ?*Conn = null,

    pub const Swept = struct { reaped: u32 = 0, cancelled: u32 = 0 };

    /// A zeroed-out `Conn` for a new connection, or null when out of memory.
    pub fn create(w: *Watchdog, io: Io, stream: Io.net.Stream) ?*Conn {
        const gpa = w.gpa orelse return null;
        w.mutex.lockUncancelable(io);
        const reused = w.spare;
        if (reused) |c| w.spare = c.next_victim;
        w.mutex.unlock(io);
        const c = reused orelse (gpa.create(Conn) catch return null);
        c.* = .{ .stream = stream };
        return c;
    }

    /// Give back a `Conn` that never got a task (or whose task has ended).
    pub fn recycle(w: *Watchdog, io: Io, c: *Conn) void {
        if (w.gpa == null) return;
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        c.next_victim = w.spare;
        w.spare = c;
    }

    pub fn deinit(w: *Watchdog) void {
        const gpa = w.gpa orelse return;
        while (w.spare) |c| {
            w.spare = c.next_victim;
            gpa.destroy(c);
        }
    }

    /// Register a connection whose `future` is already set.
    pub fn add(w: *Watchdog, io: Io, c: *Conn) void {
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        w.conns.append(&c.node);
    }

    /// One pass: free what has finished, cancel what has run out of time.
    pub fn sweep(w: *Watchdog, io: Io, now_ms: i64) Swept {
        var out: Swept = .{};
        var finished: ?*Conn = null;
        var expired: ?*Conn = null;
        const stop_idle = w.stop_idle.load(.acquire);

        {
            w.mutex.lockUncancelable(io);
            defer w.mutex.unlock(io);
            var it = w.conns.first;
            while (it) |node| {
                it = node.next;
                const c: *Conn = @fieldParentPtr("node", node);
                if (c.done.load(.acquire)) {
                    w.conns.remove(node);
                    c.next_victim = finished;
                    finished = c;
                    continue;
                }
                if (c.fired.load(.acquire)) continue;
                const deadline = c.deadline_ms.load(.acquire);
                const late = deadline != 0 and now_ms >= deadline;
                if (late or (stop_idle and c.idle.load(.acquire))) {
                    c.fired.store(true, .release);
                    w.conns.remove(node);
                    c.next_victim = expired;
                    expired = c;
                }
            }
        }

        // Outside the lock: neither call touches the list.
        while (finished) |c| {
            finished = c.next_victim;
            if (c.future) |*f| f.await(io);
            w.recycle(io, c);
            out.reaped += 1;
        }
        while (expired) |c| {
            expired = c.next_victim;
            // Returns once the task has seen the cancellation and ended.
            if (c.future) |*f| f.cancel(io);
            w.recycle(io, c);
            out.cancelled += 1;
        }
        return out;
    }

    /// Cancel every remaining connection. Only after `run` has stopped.
    pub fn cancelAll(w: *Watchdog, io: Io) u32 {
        var n: u32 = 0;
        while (true) {
            w.mutex.lockUncancelable(io);
            const node = w.conns.popFirst();
            w.mutex.unlock(io);
            const c: *Conn = @fieldParentPtr("node", node orelse break);
            c.fired.store(true, .release);
            if (c.future) |*f| f.cancel(io);
            w.recycle(io, c);
            n += 1;
        }
        return n;
    }

    /// Background task.
    pub fn run(w: *Watchdog, io: Io) Io.Cancelable!void {
        while (true) {
            try io.sleep(.fromMilliseconds(sweep_interval_ms), .awake);
            _ = w.sweep(io, nowMs(io));
        }
    }
};

pub fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

const no_stream: Io.net.Stream = undefined;

test "only armed, expired connections are cancelled, and only once" {
    const io = std.testing.io;
    var w: Watchdog = .{};
    var a: Conn = .{ .stream = no_stream };
    var b: Conn = .{ .stream = no_stream };
    var c: Conn = .{ .stream = no_stream };
    w.add(io, &a);
    w.add(io, &b);
    w.add(io, &c);

    a.deadline_ms.store(100, .release);
    b.deadline_ms.store(200, .release);
    // c is not armed.

    try std.testing.expectEqual(@as(u32, 0), w.sweep(io, 99).cancelled);
    try std.testing.expectEqual(@as(u32, 1), w.sweep(io, 150).cancelled);
    try std.testing.expect(a.timedOut() and !b.timedOut() and !c.timedOut());

    // Re-arming b pushes its deadline out; a is gone and cannot fire twice.
    b.deadline_ms.store(400, .release);
    try std.testing.expectEqual(@as(u32, 0), w.sweep(io, 300).cancelled);
    try std.testing.expectEqual(@as(u32, 1), w.sweep(io, 400).cancelled);
    try std.testing.expect(b.timedOut() and !c.timedOut());

    // A disarmed connection is never cancelled.
    c.deadline_ms.store(10, .release);
    c.disarm();
    try std.testing.expectEqual(@as(u32, 0), w.sweep(io, 1_000_000).cancelled);
    try std.testing.expect(!c.timedOut());
    try std.testing.expectEqual(@as(u32, 1), w.cancelAll(io));
}

test "finished connections are reaped, not cancelled" {
    const io = std.testing.io;
    var w: Watchdog = .{};
    var a: Conn = .{ .stream = no_stream };
    var b: Conn = .{ .stream = no_stream };
    w.add(io, &a);
    w.add(io, &b);
    a.deadline_ms.store(1, .release); // would be late, but it has finished
    a.done.store(true, .release);

    const swept = w.sweep(io, 1000);
    try std.testing.expectEqual(@as(u32, 1), swept.reaped);
    try std.testing.expectEqual(@as(u32, 0), swept.cancelled);
    try std.testing.expect(!a.timedOut());
    try std.testing.expectEqual(@as(u32, 1), w.cancelAll(io));
    try std.testing.expectEqual(@as(u32, 0), w.cancelAll(io));
}

test "a graceful stop takes only connections that are between requests" {
    const io = std.testing.io;
    var w: Watchdog = .{};
    var waiting: Conn = .{ .stream = no_stream };
    var busy: Conn = .{ .stream = no_stream };
    w.add(io, &waiting);
    w.add(io, &busy);
    waiting.idle.store(true, .release);

    try std.testing.expectEqual(@as(u32, 0), w.sweep(io, 0).cancelled);
    w.stop_idle.store(true, .release);
    try std.testing.expectEqual(@as(u32, 1), w.sweep(io, 0).cancelled);
    try std.testing.expect(waiting.timedOut() and !busy.timedOut());
    // The busy one becomes idle later and is taken by the next sweep.
    busy.idle.store(true, .release);
    try std.testing.expectEqual(@as(u32, 1), w.sweep(io, 0).cancelled);
}
