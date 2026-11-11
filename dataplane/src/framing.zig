//! How long the body of a response from an upstream (or the control plane)
//! is, and a reader for it.
//!
//! std's HTTP body readers trust the peer: a chunk size too large for the
//! integer it is kept in overflows, and what the head promised is handed on
//! as a fact. An upstream is a network peer like any other, and a panic in
//! one connection's task ends the process for all of them. So the head's
//! framing is decided here, strictly, from its raw bytes, and the body is
//! read here, from the connection's own reader, with every size bounded and
//! a body that ends early reported as the error it is.

const std = @import("std");
const Io = std.Io;
const http = std.http;

/// A single chunk larger than this is refused. (No real server sends one;
/// the point is that the number fits and nothing downstream can overflow.)
pub const max_chunk_size: u64 = 1 << 40;
/// A chunk-size line (hex digits, optional extensions, CRLF).
pub const max_chunk_line = 256;
/// All trailer lines after the last chunk, together.
pub const max_trailer_bytes = 8 * 1024;

pub const Framing = union(enum) {
    /// No body at all (1xx, 204, 304).
    none,
    length: u64,
    chunked,
    /// Neither a length nor chunking: the body is whatever arrives before
    /// the connection closes. Its end cannot be told from a cut connection.
    until_close,
};

/// Decide the framing from a response head as received (status line through
/// the blank line). Refuses anything two implementations could read
/// differently: both a length and chunking, two different lengths, a length
/// that is not a plain number, a transfer coding other than `chunked`.
pub fn ofHead(head: []const u8, status: u16) error{UpstreamUnparseable}!Framing {
    var content_length: ?u64 = null;
    var chunked = false;
    var first = true;
    var it = std.mem.splitScalar(u8, head, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (first) {
            first = false;
            continue;
        }
        if (line.len == 0) break;
        // A continuation line could belong to either header we care about.
        if (line[0] == ' ' or line[0] == '\t') return error.UpstreamUnparseable;
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.UpstreamUnparseable;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (value.len == 0 or value.len > 19) return error.UpstreamUnparseable;
            for (value) |c| if (!std.ascii.isDigit(c)) return error.UpstreamUnparseable;
            const n = std.fmt.parseInt(u64, value, 10) catch return error.UpstreamUnparseable;
            if (content_length) |seen| if (seen != n) return error.UpstreamUnparseable;
            content_length = n;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (chunked or !std.ascii.eqlIgnoreCase(value, "chunked")) return error.UpstreamUnparseable;
            chunked = true;
        }
    }
    if (chunked and content_length != null) return error.UpstreamUnparseable;
    if (status < 200 or status == 204 or status == 304) return .none;
    if (chunked) return .chunked;
    if (content_length) |n| return .{ .length = n };
    return .until_close;
}

pub const BodyReader = struct {
    /// The connection, positioned at the first byte after the head.
    in: *Io.Reader,
    state: State,
    trailer_bytes: usize = 0,

    const State = union(enum) {
        length: u64,
        chunk_head,
        chunk_data: u64,
        chunk_end,
        trailers,
        until_close,
        /// The whole body was read and the connection is at a message
        /// boundary (it may carry another exchange).
        done,
        /// The body ended because the connection did.
        closed,
    };

    pub const Error = error{
        /// The connection failed (or this task was canceled) mid-body.
        ReadFailed,
        /// The connection ended before the body the head promised.
        UpstreamTruncated,
        /// The chunked encoding is malformed or exceeds a bound.
        UpstreamUnparseable,
    };

    pub fn init(in: *Io.Reader, framing: Framing) BodyReader {
        return .{ .in = in, .state = switch (framing) {
            .none => .done,
            .length => |n| if (n == 0) .done else .{ .length = n },
            .chunked => .chunk_head,
            .until_close => .until_close,
        } };
    }

    /// True once the body has been read to its end and the connection could
    /// be used for another exchange.
    pub fn atBoundary(r: *const BodyReader) bool {
        return r.state == .done;
    }

    /// Bytes still to come, when that is known: the head gave a length, or
    /// the body is over. Null while the end can only be seen on arrival
    /// (chunked, or until the connection closes). Whatever `read` returns
    /// from here on adds up to exactly this, or `read` fails.
    pub fn remaining(r: *const BodyReader) ?u64 {
        return switch (r.state) {
            .length => |left| left,
            .done => 0,
            else => null,
        };
    }

    /// Read some of the body: whatever is at hand, up to `dest.len` bytes.
    /// Returns 0 only at the end of the body.
    pub fn read(r: *BodyReader, dest: []u8) Error!usize {
        std.debug.assert(dest.len > 0);
        while (true) switch (r.state) {
            .done, .closed => return 0,
            .length => |left| {
                const n = try r.some(dest, left);
                r.state = if (left == n) .done else .{ .length = left - n };
                return n;
            },
            .chunk_data => |left| {
                const n = try r.some(dest, left);
                r.state = if (left == n) .chunk_end else .{ .chunk_data = left - n };
                return n;
            },
            .until_close => {
                const have = r.in.peekGreedy(1) catch |err| switch (err) {
                    error.EndOfStream => {
                        r.state = .closed;
                        return 0;
                    },
                    error.ReadFailed => return error.ReadFailed,
                };
                const n = @min(have.len, dest.len);
                @memcpy(dest[0..n], have[0..n]);
                r.in.toss(n);
                return n;
            },
            .chunk_head => {
                const line = try r.takeLine(max_chunk_line);
                // Hex digits, then optionally `;extensions`, which are ignored.
                var size: u64 = 0;
                var digits: usize = 0;
                for (line) |c| {
                    const d: u64 = switch (c) {
                        '0'...'9' => c - '0',
                        'a'...'f' => c - 'a' + 10,
                        'A'...'F' => c - 'A' + 10,
                        else => break,
                    };
                    digits += 1;
                    // 16 digits fill a u64 exactly; one more would overflow.
                    if (digits > 16) return error.UpstreamUnparseable;
                    size = size << 4 | d;
                }
                if (digits == 0 or size > max_chunk_size) return error.UpstreamUnparseable;
                const rest = std.mem.trim(u8, line[digits..], " \t");
                if (rest.len != 0 and rest[0] != ';') return error.UpstreamUnparseable;
                r.state = if (size == 0) .trailers else .{ .chunk_data = size };
            },
            .chunk_end => {
                const line = try r.takeLine(max_chunk_line);
                if (line.len != 0) return error.UpstreamUnparseable;
                r.state = .chunk_head;
            },
            .trailers => {
                const line = try r.takeLine(max_trailer_bytes);
                r.trailer_bytes += line.len + 2;
                if (r.trailer_bytes > max_trailer_bytes) return error.UpstreamUnparseable;
                if (line.len == 0) r.state = .done;
            },
        };
    }

    /// Up to `dest.len` and `left` bytes of what the connection has.
    fn some(r: *BodyReader, dest: []u8, left: u64) Error!usize {
        const have = r.in.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return error.UpstreamTruncated,
            error.ReadFailed => return error.ReadFailed,
        };
        const n: usize = @intCast(@min(left, @min(have.len, dest.len)));
        @memcpy(dest[0..n], have[0..n]);
        r.in.toss(n);
        return n;
    }

    /// One line of the chunked framing, without its line ending.
    fn takeLine(r: *BodyReader, max: usize) Error![]const u8 {
        const raw = r.in.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.UpstreamTruncated,
            error.StreamTooLong => return error.UpstreamUnparseable,
            error.ReadFailed => return error.ReadFailed,
        };
        if (raw.len > max + 2) return error.UpstreamUnparseable;
        // CRLF, as the encoding requires; a bare LF is not a line ending here.
        if (raw.len < 2 or raw[raw.len - 2] != '\r') return error.UpstreamUnparseable;
        return raw[0 .. raw.len - 2];
    }

    pub const AllocError = Error || error{ OutOfMemory, StreamTooLong };

    /// The rest of the body in one piece; `error.StreamTooLong` past `limit`.
    pub fn readAlloc(r: *BodyReader, gpa: std.mem.Allocator, limit: usize) AllocError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = try r.read(&buf);
            if (n == 0) break;
            if (out.items.len + n > limit) return error.StreamTooLong;
            try out.appendSlice(gpa, buf[0..n]);
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Take over reading the body of `response` from std. Call it once, right
/// after the head arrived and before anything else reads from the
/// connection; everything wanted from `response.head` must have been copied
/// by then, since reading the body reuses the buffer the head lives in.
///
/// From here on std no longer knows where in the exchange the connection
/// is, so it is marked as not reusable until `release` says otherwise. (In
/// particular this keeps `Request.deinit` from "discarding the rest of the
/// body" with the very reader this module exists to avoid.)
pub fn takeBody(req: *http.Client.Request, response: *const http.Client.Response) error{UpstreamUnparseable}!BodyReader {
    disown(req);
    const framing = try ofHead(response.head.bytes, @backingInt(response.head.status));
    return .init(req.reader.in, framing);
}

/// Tell std not to touch the response body of `req` when it is torn down.
/// Safe to call at any time, any number of times.
pub fn disown(req: *http.Client.Request) void {
    if (req.reader.state == .received_head) req.reader.state = .closing;
}

/// The body was read through `body`: if that reached the end of the
/// message, the connection may carry another exchange.
pub fn release(req: *http.Client.Request, body: *const BodyReader) void {
    if (body.atBoundary() and req.reader.state == .closing) req.reader.state = .ready;
}

/// A header value that may be copied into a response of ours: no control
/// bytes (a line feed would start a header of the peer's choosing), not
/// empty, not absurdly long.
pub fn plainHeaderValue(value: []const u8, max_len: usize) bool {
    if (value.len == 0 or value.len > max_len) return false;
    for (value) |c| {
        if ((c < 0x20 and c != '\t') or c == 0x7f) return false;
    }
    return true;
}

const testing = std.testing;

fn readAll(body: []const u8, framing: Framing) (BodyReader.AllocError || error{TestExpectedEqual})![]u8 {
    var in: Io.Reader = .fixed(body);
    var r: BodyReader = .init(&in, framing);
    const out = try r.readAlloc(testing.allocator, 1 << 20);
    errdefer testing.allocator.free(out);
    // Once ended, it stays ended.
    var one: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try r.read(&one));
    return out;
}

fn expectBody(expected: []const u8, body: []const u8, framing: Framing) !void {
    const out = try readAll(body, framing);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "framing is decided strictly from the head" {
    const ok = "HTTP/1.1 200 OK\r\n";
    try testing.expectEqual(Framing{ .length = 12 }, try ofHead(ok ++ "Content-Length: 12\r\n\r\n", 200));
    try testing.expectEqual(Framing{ .length = 0 }, try ofHead(ok ++ "content-length:0\r\n\r\n", 200));
    try testing.expectEqual(Framing.chunked, try ofHead(ok ++ "Transfer-Encoding: Chunked\r\n\r\n", 200));
    try testing.expectEqual(Framing.until_close, try ofHead(ok ++ "Content-Type: text/plain\r\n\r\n", 200));
    // Two equal lengths are one length.
    try testing.expectEqual(Framing{ .length = 3 }, try ofHead(ok ++ "Content-Length: 3\r\ncontent-length: 3\r\n\r\n", 200));
    // No body whatever the headers say.
    try testing.expectEqual(Framing.none, try ofHead("HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\n", 204));
    try testing.expectEqual(Framing.none, try ofHead("HTTP/1.1 304 Not Modified\r\n\r\n", 304));

    for ([_][]const u8{
        // Both framings: which one the body follows is the peer's secret.
        "Content-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n",
        "Transfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n",
        "Content-Length: 5\r\nContent-Length: 6\r\n\r\n",
        "Content-Length: 5, 5\r\n\r\n",
        "Content-Length: -1\r\n\r\n",
        "Content-Length: 0x10\r\n\r\n",
        "Content-Length: \r\n\r\n",
        "Content-Length: 99999999999999999999\r\n\r\n",
        "Transfer-Encoding: gzip, chunked\r\n\r\n",
        "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
        "Transfer-Encoding: identity\r\n\r\n",
        "Content-Length: 5\r\n Transfer-Encoding: chunked\r\n\r\n",
        "NoColon\r\n\r\n",
    }) |headers| {
        const head = try std.mem.concat(testing.allocator, u8, &.{ ok, headers });
        defer testing.allocator.free(head);
        try testing.expectError(error.UpstreamUnparseable, ofHead(head, 200));
    }
}

test "a body with a length is read to exactly that length" {
    try expectBody("hello", "hello", .{ .length = 5 });
    // What follows belongs to the next exchange.
    try expectBody("hel", "hello", .{ .length = 3 });
    try expectBody("", "ignored", .{ .length = 0 });
    try expectBody("", "ignored", .none);
    // A body shorter than promised is an error, not an ending.
    try testing.expectError(error.UpstreamTruncated, readAll("hell", .{ .length = 5 }));
    try testing.expectError(error.UpstreamTruncated, readAll("", .{ .length = 1 }));
    try testing.expectError(error.UpstreamTruncated, readAll("abc", .{ .length = std.math.maxInt(u64) }));
}

test "a body without framing runs to the close" {
    try expectBody("anything at all", "anything at all", .until_close);
    try expectBody("", "", .until_close);
    var in: Io.Reader = .fixed("x");
    var r: BodyReader = .init(&in, .until_close);
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try r.read(&buf));
    try testing.expectEqual(@as(usize, 0), try r.read(&buf));
    // Its connection cannot carry another exchange.
    try testing.expect(!r.atBoundary());
}

test "chunked bodies are decoded" {
    try expectBody("hello world", "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", .chunked);
    try expectBody("", "0\r\n\r\n", .chunked);
    // Extensions and trailers are skipped; hex digits in either case.
    try expectBody("0123456789abcdef", "A;name=value\r\n0123456789\r\n06 ; x\r\nabcdef\r\n000\r\nX-Trailer: 1\r\nY: 2\r\n\r\n", .chunked);
    // What follows the terminating line belongs to the next exchange.
    {
        var in: Io.Reader = .fixed("1\r\na\r\n0\r\n\r\nHTTP/1.1 200 OK\r\n");
        var r: BodyReader = .init(&in, .chunked);
        var buf: [8]u8 = undefined;
        try testing.expectEqual(@as(usize, 1), try r.read(&buf));
        try testing.expectEqual(@as(usize, 0), try r.read(&buf));
        try testing.expect(r.atBoundary());
        try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", in.buffered());
    }
}

test "hostile chunked encodings are errors, never panics" {
    // The size that overflowed std's reader, and friends.
    for ([_][]const u8{
        "FFFFFFFFFFFFFFFF\r\nabc\r\n0\r\n\r\n",
        "FFFFFFFFFFFFFFFFF\r\nabc\r\n0\r\n\r\n",
        "fffffffffffffffffffffffffffffffffffffffff\r\n",
        "10000000001\r\n",
        "\r\nabc\r\n",
        "g\r\n",
        "-1\r\n",
        "0x5\r\nhello\r\n0\r\n\r\n",
        "5 5\r\nhello\r\n0\r\n\r\n",
        "5\nhello\n0\n\n", // bare line feeds
        "5\r\nhelloXX0\r\n\r\n", // no CRLF after the data
        "5\r\nhello\r\nX\r\n0\r\n\r\n",
    }) |body| {
        try testing.expectError(error.UpstreamUnparseable, readAll(body, .chunked));
    }
    // A line that never ends, and trailers that never end.
    {
        const long = try testing.allocator.alloc(u8, 4096);
        defer testing.allocator.free(long);
        @memset(long, '1');
        long[4094] = '\r';
        long[4095] = '\n';
        try testing.expectError(error.UpstreamUnparseable, readAll(long, .chunked));

        var many: std.ArrayList(u8) = .empty;
        defer many.deinit(testing.allocator);
        try many.appendSlice(testing.allocator, "0\r\n");
        for (0..2000) |_| try many.appendSlice(testing.allocator, "X-T: 1\r\n");
        try many.appendSlice(testing.allocator, "\r\n");
        try testing.expectError(error.UpstreamUnparseable, readAll(many.items, .chunked));
    }
    // Cut off anywhere: truncated, not complete.
    const whole = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
    for (0..whole.len) |cut| {
        try testing.expectError(error.UpstreamTruncated, readAll(whole[0..cut], .chunked));
    }
    // At most max_chunk_size is accepted as a size (and then it is truncated).
    try testing.expectError(error.UpstreamTruncated, readAll("10000000000\r\nabc", .chunked));
}

test "random bytes as a chunked body never panic" {
    var prng: std.Random.DefaultPrng = .init(0x0f0f);
    const random = prng.random();
    const alphabet = "0123456789abcdefABCDEF\r\n\r\n\r\n;x: ";
    var buf: [96]u8 = undefined;
    for (0..20_000) |_| {
        const len = random.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        if (readAll(buf[0..len], .chunked)) |out| testing.allocator.free(out) else |_| {}
    }
}

test "header values with control bytes are not relayed" {
    try testing.expect(plainHeaderValue("application/json; charset=utf-8", 256));
    try testing.expect(plainHeaderValue("text/event-stream", 256));
    try testing.expect(!plainHeaderValue("text/plain\nset-cookie: a=b", 256));
    try testing.expect(!plainHeaderValue("text/plain\rx", 256));
    try testing.expect(!plainHeaderValue("a\x00b", 256));
    try testing.expect(!plainHeaderValue("", 256));
    const long: [300]u8 = @splat('a');
    try testing.expect(!plainHeaderValue(&long, 256));
}
