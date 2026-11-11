//! Checks on bytes that come from the network, done before anything else
//! looks at them.
//!
//! A panic anywhere in this process ends every connection it is serving, so
//! the rule is that no input may reach code that asserts on its shape. Zig's
//! `std.http` parser accepts some heads that its own header iterator then
//! unwraps a null on, and its JSON serialiser indexes past a fixed stack on
//! deeply nested values. Everything here is plain scanning that cannot fail
//! in any way other than returning "no".

const std = @import("std");
const http = std.http;

/// Nesting allowed in a client's JSON body, and in JSON found inside strings
/// (tool-call arguments). Real requests stay in single digits.
pub const max_client_json_depth = 64;
/// Nesting allowed in an upstream's JSON. Looser, because translation wraps
/// what it reads in a few more levels; still far below the serialiser's 256.
pub const max_upstream_json_depth = 128;
/// Header lines accepted in one request head.
pub const max_request_headers = 100;
/// Members of any one object in JSON that is parsed into a value tree.
/// std's JSON object is a hash map with a fixed seed: N keys chosen to
/// collide cost N squared probes, so N is kept small wherever a tree is
/// built from bytes a peer chose.
pub const max_tree_members = 1024;

/// True when no array or object in `bytes` is nested deeper than `max`.
/// One pass, no allocation. It does not validate the JSON: it only makes sure
/// that whatever parses it later cannot be driven arbitrarily deep.
pub fn jsonDepthOk(bytes: []const u8, max: usize) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > max) return false;
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
    return true;
}

/// True when no object in `bytes` has more than `max` members. Like
/// `jsonDepthOk` it validates nothing and allocates nothing; it counts the
/// commas between an object's braces, which is one less than its members
/// in anything a JSON parser accepts. Nesting beyond its fixed stack is a
/// "no" (callers bound the depth first).
pub fn jsonMembersOk(bytes: []const u8, max: u32) bool {
    const levels = 257;
    // Commas seen so far at each open level; arrays are not counted.
    var commas: [levels]u32 = undefined;
    var is_object: [levels]bool = undefined;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                if (depth == levels) return false;
                commas[depth] = 0;
                is_object[depth] = c == '{';
                depth += 1;
            },
            '}', ']' => depth -|= 1,
            ',' => if (depth > 0 and is_object[depth - 1]) {
                commas[depth - 1] += 1;
                if (commas[depth - 1] >= max) return false;
            },
            else => {},
        }
    }
    return true;
}

/// Header lines of a raw HTTP head, without `std.http.HeaderIterator`'s
/// assumption that every line has a colon. Lines without one are skipped.
pub const HeaderIterator = struct {
    bytes: []const u8,
    index: usize,

    pub fn init(head: []const u8) HeaderIterator {
        // Skip the request or status line.
        const first_end = std.mem.find(u8, head, "\r\n") orelse head.len;
        return .{ .bytes = head, .index = @min(head.len, first_end + 2) };
    }

    pub fn next(it: *HeaderIterator) ?http.Header {
        while (it.index < it.bytes.len) {
            const rest = it.bytes[it.index..];
            const end = std.mem.find(u8, rest, "\r\n") orelse rest.len;
            const line = rest[0..end];
            it.index += @min(rest.len, end + 2);
            if (line.len == 0) return null; // end of head
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (colon == 0) continue;
            return .{ .name = line[0..colon], .value = std.mem.trim(u8, line[colon + 1 ..], " \t") };
        }
        return null;
    }
};

pub const HeadVerdict = union(enum) {
    ok,
    /// Not a request this server will touch; the text says why.
    bad: []const u8,
    /// A method that carries a body, with no `content-length` saying how
    /// long it is (chunked request bodies are not accepted).
    length_required,
    expectation_failed,
};

fn isTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// Decide whether a request head, as received, is safe to hand to the rest
/// of the server. `has_body` is whether the method carries a body.
///
/// Strict on purpose: anything two HTTP implementations could read
/// differently (bare line feeds, a header without a colon, two lengths, a
/// length together with chunked encoding, a body on a GET) is refused, since
/// that disagreement is what request smuggling is made of.
pub fn checkRequestHead(head: []const u8, has_body: bool) HeadVerdict {
    if (!std.mem.endsWith(u8, head, "\r\n\r\n")) return .{ .bad = "malformed request head" };
    const lines = head[0 .. head.len - 4];

    var content_length: ?u64 = null;
    var chunked = false;
    var count: usize = 0;
    var first = true;
    var it = std.mem.splitSequence(u8, lines, "\r\n");
    while (it.next()) |line| {
        // After splitting on CRLF, a CR or LF left over is a bare one.
        for (line) |c| {
            if (c == '\r' or c == '\n' or c == 0) return .{ .bad = "malformed request head" };
        }
        if (first) {
            first = false;
            // METHOD SP origin-form SP HTTP/1.x, with exactly two spaces.
            const sp1 = std.mem.findScalar(u8, line, ' ') orelse return .{ .bad = "malformed request line" };
            const sp2 = std.mem.findScalarLast(u8, line, ' ') orelse return .{ .bad = "malformed request line" };
            if (sp1 == 0 or sp2 <= sp1 + 1) return .{ .bad = "malformed request line" };
            const target = line[sp1 + 1 .. sp2];
            if (target[0] != '/') return .{ .bad = "the request target must be a path" };
            for (target) |c| {
                // Visible ASCII only: no spaces, no control bytes, nothing above.
                if (c <= 0x20 or c >= 0x7f) return .{ .bad = "the request target contains forbidden characters" };
            }
            for (line[0..sp1]) |c| if (!isTokenChar(c)) return .{ .bad = "malformed request line" };
            if (!std.mem.startsWith(u8, line[sp2 + 1 ..], "HTTP/1.")) return .{ .bad = "malformed request line" };
            continue;
        }

        count += 1;
        if (count > max_request_headers) return .{ .bad = "too many headers" };
        const colon = std.mem.findScalar(u8, line, ':') orelse return .{ .bad = "malformed header line" };
        if (colon == 0) return .{ .bad = "malformed header line" };
        const name = line[0..colon];
        for (name) |c| if (!isTokenChar(c)) return .{ .bad = "malformed header name" };
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        for (value) |c| {
            if ((c < 0x20 and c != '\t') or c == 0x7f) return .{ .bad = "a header value contains control characters" };
        }

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (value.len == 0 or value.len > 19) return .{ .bad = "invalid content-length" };
            for (value) |c| if (!std.ascii.isDigit(c)) return .{ .bad = "invalid content-length" };
            const n = std.fmt.parseInt(u64, value, 10) catch return .{ .bad = "invalid content-length" };
            if (content_length) |seen| {
                if (seen != n) return .{ .bad = "conflicting content-length headers" };
            }
            content_length = n;
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            // std answers nothing at all for any other expectation.
            if (!std.ascii.eqlIgnoreCase(value, "100-continue")) return .expectation_failed;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (chunked or !std.ascii.eqlIgnoreCase(value, "chunked")) return .{ .bad = "unsupported transfer-encoding" };
            chunked = true;
        }
    }
    if (first) return .{ .bad = "malformed request head" };

    if (chunked and content_length != null) return .{ .bad = "both content-length and transfer-encoding" };
    if (!has_body) {
        // A body nobody reads would be taken for the next request.
        if (chunked or (content_length orelse 0) != 0) return .{ .bad = "this method does not take a body" };
        return .ok;
    }
    // A chunked request body would be decoded by std's chunked reader,
    // which overflows on a chunk size that does not fit its integer. Every
    // client the gateway is for sends a length; ask the others to.
    if (content_length == null) return .length_required;
    return .ok;
}

/// One spelling per path: no empty, `.` or `..` segments, no trailing slash,
/// nothing percent-encoded, no backslash. The gateway decides what a request
/// is from its path and then forwards that path; with a single canonical
/// form the two can never disagree (`/v1/jobs/` used to be forwarded as a job
/// creation without being rate limited as one).
pub fn canonicalPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    if (path.len == 1) return true;
    if (path[path.len - 1] == '/') return false;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~', ':', '@' => {},
            else => return false,
        };
    }
    return true;
}

/// A query string that is safe to put into a request to the control plane
/// unchanged: plain `key=value&...` characters only.
pub fn safeQuery(query: []const u8) bool {
    if (query.len > 2048) return false;
    for (query) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~', '=', '&', '+', ',', ':' => {},
        else => return false,
    };
    return true;
}

/// An opaque token a client chose (an idempotency key): any visible ASCII,
/// which covers UUIDs, base64 and the separators people put in such keys,
/// and nothing that could end a header line or be read as two values.
pub fn visibleToken(value: []const u8, max_len: usize) bool {
    if (value.len == 0 or value.len > max_len) return false;
    for (value) |c| if (c <= 0x20 or c >= 0x7f) return false;
    return true;
}

/// A header value the gateway is willing to copy into a request of its own:
/// letters, digits and `extra`, at most `max_len` long.
pub fn safeHeaderValue(value: []const u8, extra: []const u8, max_len: usize) bool {
    if (value.len == 0 or value.len > max_len) return false;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (std.mem.findScalar(u8, extra, c) == null) return false;
    }
    return true;
}

const testing = std.testing;

test "json depth is bounded without being fooled by strings" {
    try testing.expect(jsonDepthOk("{\"a\":[1,{\"b\":[]}]}", 4));
    try testing.expect(!jsonDepthOk("{\"a\":[1,{\"b\":[]}]}", 3));
    // Brackets inside strings, escaped quotes included, are not nesting.
    try testing.expect(jsonDepthOk("{\"a\":\"[[[[[[\\\"[[[[\"}", 1));
    try testing.expect(jsonDepthOk("", 0));
    // Unbalanced closers cannot underflow.
    try testing.expect(jsonDepthOk("]]]}}}[", 1));

    var deep: [600]u8 = undefined;
    @memset(deep[0..300], '[');
    @memset(deep[300..], ']');
    try testing.expect(!jsonDepthOk(&deep, max_upstream_json_depth));
    try testing.expect(jsonDepthOk(deep[236..364], max_client_json_depth));
    try testing.expect(!jsonDepthOk(deep[235..365], max_client_json_depth));
}

test "members per object are bounded without building anything" {
    try testing.expect(jsonMembersOk("{\"a\":1,\"b\":2,\"c\":3}", 3));
    try testing.expect(!jsonMembersOk("{\"a\":1,\"b\":2,\"c\":3}", 2));
    // Each object on its own account; arrays are not objects.
    try testing.expect(jsonMembersOk("{\"a\":{\"x\":1,\"y\":2},\"b\":[1,2,3,4,5,6,7,8],\"c\":{\"x\":1,\"y\":2}}", 3));
    try testing.expect(!jsonMembersOk("{\"a\":[{\"x\":1,\"y\":2,\"z\":3}]}", 2));
    // Commas inside strings are text.
    try testing.expect(jsonMembersOk("{\"a\":\",,,,,,\\\",,,,\"}", 1));
    try testing.expect(jsonMembersOk("", 1));
    try testing.expect(jsonMembersOk("]]}},,,", 1));
    // Deeper than its stack is a no, not an overrun.
    var deep: [600]u8 = undefined;
    @memset(deep[0..300], '[');
    @memset(deep[300..], ']');
    try testing.expect(!jsonMembersOk(&deep, 1000));
    try testing.expect(jsonMembersOk(deep[44..556], 1000));
}

test "well-formed heads pass" {
    try testing.expectEqual(HeadVerdict.ok, checkRequestHead("GET /healthz HTTP/1.1\r\nHost: a\r\n\r\n", false));
    try testing.expectEqual(HeadVerdict.ok, checkRequestHead("GET / HTTP/1.1\r\n\r\n", false));
    try testing.expectEqual(HeadVerdict.ok, checkRequestHead("POST /v1/chat/completions HTTP/1.1\r\nHost: a\r\nContent-Length: 12\r\nAuthorization: Bearer x y\r\n\r\n", true));
    try testing.expectEqual(HeadVerdict.ok, checkRequestHead("GET /a?b=c HTTP/1.1\r\nContent-Length: 0\r\nX-Empty:\r\n\r\n", false));
    // Two equal lengths are one length.
    try testing.expectEqual(HeadVerdict.ok, checkRequestHead("POST / HTTP/1.1\r\nContent-Length: 3\r\ncontent-length: 3\r\n\r\n", true));
}

test "heads the std parser accepts but must not be iterated are refused" {
    // These two used to kill the process.
    try testing.expect(checkRequestHead("GET / HTTP/1.1\r\nX\r\n", false) == .bad);
    try testing.expect(checkRequestHead("GET /healthz HTTP/1.1\r\nHost: a\r\nX\r\n", false) == .bad);
    try testing.expectEqual(HeadVerdict.expectation_failed, checkRequestHead("POST / HTTP/1.1\r\nContent-Length: 3\r\nExpect: a-miracle\r\n\r\n", true));
    try testing.expectEqual(HeadVerdict.ok, checkRequestHead("POST / HTTP/1.1\r\nContent-Length: 3\r\nExpect: 100-Continue\r\n\r\n", true));
    try testing.expectEqual(HeadVerdict.length_required, checkRequestHead("POST / HTTP/1.1\r\n\r\n", true));
    try testing.expectEqual(HeadVerdict.length_required, checkRequestHead("PUT /x HTTP/1.1\r\nHost: a\r\n\r\n", true));
    // A chunked request body: its decoder is std's, which a chunk size of
    // sixteen F's overflows. Asked for a length instead, in any spelling.
    try testing.expectEqual(HeadVerdict.length_required, checkRequestHead("POST /v1/jobs HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", true));
    try testing.expectEqual(HeadVerdict.length_required, checkRequestHead("POST /v1/chat/completions HTTP/1.1\r\nHost: a\r\ntransfer-encoding: CHUNKED\r\n\r\n", true));
    try testing.expect(checkRequestHead("POST / HTTP/1.1\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n", true) == .bad);

    for ([_][]const u8{
        "",
        "\r\n\r\n",
        "GET / HTTP/1.1\r\nNoColon\r\n\r\n",
        "GET / HTTP/1.1\r\n: empty-name\r\n\r\n",
        "GET / HTTP/1.1\r\nBad Name: x\r\n\r\n",
        "GET / HTTP/1.1\r\n folded: x\r\n\r\n",
        "GET / HTTP/1.1\r\nA: b\nC: d\r\n\r\n", // bare LF
        "GET / HTTP/1.1\r\nA: b\rC: d\r\n\r\n", // bare CR
        "GET / HTTP/1.1\r\nA: b\x00\r\n\r\n",
        "GET / HTTP/1.1\r\nA: \x01\r\n\r\n",
        "GET /a b HTTP/1.1\r\n\r\n", // space in target
        "GET /a\tb HTTP/1.1\r\n\r\n",
        "GET /a\x7f HTTP/1.1\r\n\r\n",
        "GET /\xc3\xa9 HTTP/1.1\r\n\r\n",
        "GET http://evil/ HTTP/1.1\r\n\r\n", // absolute form
        "GET * HTTP/1.1\r\n\r\n",
        "GET  HTTP/1.1\r\n\r\n",
        "GET /\r\n\r\n",
        "G(T / HTTP/1.1\r\n\r\n",
        "GET / FTP/1.1\r\n\r\n",
        // A smuggled second request in the request line's position.
        "POST /v1/jobs?a=1 HTTP/1.1\nhost: c\ncontent-length: 0\n\nPOST /internal/usage/batch HTTP/1.1\r\n\r\n",
    }) |head| {
        try testing.expect(checkRequestHead(head, false) == .bad);
        try testing.expect(checkRequestHead(head, true) == .bad);
    }
}

test "ambiguous body framing is refused" {
    for ([_][]const u8{
        "POST / HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: xchunked\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: +3\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 3 3\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 0x10\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length:\r\n\r\n",
    }) |head| try testing.expect(checkRequestHead(head, true) == .bad);

    // A body on a method that has none would be read as the next request.
    try testing.expect(checkRequestHead("GET /healthz HTTP/1.1\r\nContent-Length: 40\r\n\r\n", false) == .bad);
    try testing.expect(checkRequestHead("GET /healthz HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", false) == .bad);

    var many: std.Io.Writer.Allocating = .init(testing.allocator);
    defer many.deinit();
    try many.writer.writeAll("GET / HTTP/1.1\r\n");
    for (0..max_request_headers + 1) |i| try many.writer.print("x-{d}: 1\r\n", .{i});
    try many.writer.writeAll("\r\n");
    try testing.expect(checkRequestHead(many.written(), false) == .bad);
}

test "header iterator never assumes a colon" {
    var it = HeaderIterator.init("HTTP/1.1 200 OK\r\nA: 1\r\nnocolon\r\n: x\r\nB:  two \r\nC:\r\n\r\nbody: no\r\n");
    try testing.expectEqualStrings("1", it.next().?.value);
    const b = it.next().?;
    try testing.expectEqualStrings("B", b.name);
    try testing.expectEqualStrings("two", b.value);
    try testing.expectEqualStrings("", it.next().?.value);
    try testing.expect(it.next() == null);

    // Truncated and degenerate heads.
    for ([_][]const u8{ "", "X", "GET / HTTP/1.1\r\nX\r\n", "GET / HTTP/1.1\r\nX", "\r\n", "a\r\nb" }) |head| {
        var bad = HeaderIterator.init(head);
        while (bad.next()) |_| {}
    }
}

test "one canonical spelling per path" {
    for ([_][]const u8{ "/", "/healthz", "/v1/jobs", "/v1/jobs/job_abc123/cancel", "/v1/files/job_1/out-0.png", "/v1/models/gpt-4.1_mini:free@x~1" }) |p|
        try testing.expect(canonicalPath(p));
    for ([_][]const u8{
        "",            "v1/jobs",     "/v1/jobs/",    "//v1/jobs",  "/v1//jobs",
        "/v1/./jobs",  "/v1/../jobs", "/v1/jobs/..",  "/v1/jobs/.", "/%76%31/jobs",
        "/v1/jobs%2f", "/v1\\jobs",   "/v1/jobs;a=b", "/v1/jobs?x", "/v1/jo bs",
    }) |p| try testing.expect(!canonicalPath(p));
}

test "queries and copied header values are plain" {
    try testing.expect(safeQuery(""));
    try testing.expect(safeQuery("exp=1794328324&sig=118b5c035ee0e041"));
    try testing.expect(safeQuery("limit=20"));
    for ([_][]const u8{ "a=1 HTTP/1.1", "a=%0d%0a", "a=b#c", "a=\"", "a=<b>", "a=b/c", "x=\\" }) |q| try testing.expect(!safeQuery(q));

    // Idempotency keys as real clients write them.
    for ([_][]const u8{ "order-A17:retry.2", "3f2b8c1e-9d4a-4b7e-8f6a-1c2d3e4f5a6b", "dGhpcyBpcyBhIGtleQ==", "a+b/c=", "job_42|attempt#3", "{\"k\":1}" }) |k| {
        try testing.expect(visibleToken(k, 255));
    }
    for ([_][]const u8{ "", "a b", "a\tb", "a\r\nx-omnigate-internal: t", "a\nb", "a\x00b", "a\x7fb", "caf\xc3\xa9" }) |k| {
        try testing.expect(!visibleToken(k, 255));
    }
    const long_key: [256]u8 = @splat('k');
    try testing.expect(visibleToken(long_key[0..255], 255));
    try testing.expect(!visibleToken(&long_key, 255));

    try testing.expect(safeHeaderValue("2023-06-01", "-.", 32));
    try testing.expect(safeHeaderValue("tools-2024-04-04,prompt-caching-2024-07-31", "-._, ", 512));
    try testing.expect(safeHeaderValue("order-A17:retry.2", "-._:", 255));
    try testing.expect(!safeHeaderValue("", "-", 32));
    try testing.expect(!safeHeaderValue("a\r\nx-omnigate-internal: t", "-._: ", 255));
    try testing.expect(!safeHeaderValue("a\nb", "-", 32));
    try testing.expect(!safeHeaderValue("toolong", "-", 3));
}
