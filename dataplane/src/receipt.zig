//! What the control plane needs to check a provider's signature on one
//! answer (docs/attestation.md, "A receipt for each answer"): the SHA-256 of
//! the request body exactly as it was sent to the upstream, the SHA-256 of
//! the response body exactly as it arrived (every byte, before anything is
//! parsed, translated or restored), and the id the provider gave the
//! completion. Only these leave the data plane; no content does.
//!
//! Used only for a target on an attested upstream whose verdict holds.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The start of a response is kept to find the completion's id in; an id
/// that has not appeared by then is not looked for further.
pub const prefix_max = 8 * 1024;

/// The longest id passed on. It ends up in the path of a request the
/// control plane makes, so it is also limited to `idChar` characters.
pub const id_max = 200;

/// As reported with the usage event (JSON field names).
pub const Report = struct {
    request_sha256: []const u8,
    response_sha256: []const u8,
    /// Null when the answer named no id this module could read.
    completion_id: ?[]const u8,
};

pub const Evidence = struct {
    request: [32]u8 = @splat(0),
    response: Sha256 = .init(.{}),
    prefix: [prefix_max]u8 = undefined,
    prefix_len: usize = 0,

    /// A new exchange: forget what an earlier attempt left, take the hash
    /// of the request body as sent.
    pub fn begin(e: *Evidence, request_body: []const u8) void {
        Sha256.hash(request_body, &e.request, .{});
        e.response = .init(.{});
        e.prefix_len = 0;
    }

    /// The next bytes of the response body, in the order they arrived.
    pub fn feed(e: *Evidence, bytes: []const u8) void {
        e.response.update(bytes);
        const room = prefix_max - e.prefix_len;
        const n = @min(room, bytes.len);
        @memcpy(e.prefix[e.prefix_len..][0..n], bytes[0..n]);
        e.prefix_len += n;
    }

    /// The response has ended. (Call once: it finishes the hash.)
    pub fn report(e: *Evidence, arena: std.mem.Allocator) !Report {
        var digest: [32]u8 = undefined;
        e.response.final(&digest);
        const id = completionId(e.prefix[0..e.prefix_len]);
        return .{
            .request_sha256 = try arena.dupe(u8, &std.fmt.bytesToHex(e.request, .lower)),
            .response_sha256 = try arena.dupe(u8, &std.fmt.bytesToHex(digest, .lower)),
            .completion_id = if (id) |v| try arena.dupe(u8, v) else null,
        };
    }
};

fn idChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == ':';
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > id_max) return false;
    for (id) |c| if (!idChar(c)) return false;
    return true;
}

/// The id of the completion a response body is about, from the start of
/// that body: the top-level `"id"` of a JSON document (`chatcmpl-...`,
/// `resp_...`), or of the first event of an event stream that has one; for
/// the Responses API's events, the `"id"` inside their `"response"`.
/// Null when there is none, or it is not a plain token.
pub fn completionId(prefix: []const u8) ?[]const u8 {
    const start = std.mem.trimStart(u8, prefix, " \t\r\n");
    if (start.len > 0 and start[0] == '{') return idInObject(start);
    // An event stream: the first `data:` line whose JSON names an id.
    var lines = std.mem.splitScalar(u8, prefix, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trimStart(u8, line["data:".len..], " ");
        if (data.len == 0 or data[0] != '{') continue;
        if (idInObject(data)) |id| return id;
    }
    return null;
}

/// `"id"` at the top of a JSON object, or inside its top-level `"response"`
/// object. Reads as far as the bytes go: the document may be cut off.
fn idInObject(s: []const u8) ?[]const u8 {
    var stack: [32]u8 = undefined;
    var depth: usize = 0;
    // The last thing seen: '{', '[', ',', ':', 'k' (a key) or 'v' (a value).
    var prev: u8 = 0;
    var key: []const u8 = "";
    // The depth of the `response` object's members, 0 when not inside it.
    var response_depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            ' ', '\t', '\r', '\n' => i += 1,
            '{', '[' => {
                if (depth == stack.len) return null;
                if (c == '{' and prev == ':' and depth == 1 and std.mem.eql(u8, key, "response")) response_depth = 2;
                stack[depth] = c;
                depth += 1;
                prev = c;
                key = "";
                i += 1;
            },
            '}', ']' => {
                if (depth == 0) return null;
                if (response_depth == depth) response_depth = 0;
                depth -= 1;
                if (depth == 0) return null;
                prev = 'v';
                i += 1;
            },
            '"' => {
                const from = i + 1;
                var j = from;
                var escaped = false;
                while (j < s.len and s[j] != '"') {
                    if (s[j] == '\\') {
                        escaped = true;
                        j += 1;
                    }
                    j += 1;
                }
                if (j >= s.len) return null;
                const text = s[from..j];
                i = j + 1;
                if (depth == 0) return null;
                const wanted_depth = depth == 1 or depth == response_depth;
                if (stack[depth - 1] == '{' and (prev == '{' or prev == ',')) {
                    key = if (wanted_depth and !escaped) text else "";
                    prev = 'k';
                } else {
                    if (prev == ':' and wanted_depth and std.mem.eql(u8, key, "id")) {
                        return if (!escaped and validId(text)) text else null;
                    }
                    prev = 'v';
                }
            },
            ':' => {
                prev = ':';
                i += 1;
            },
            ',' => {
                prev = ',';
                i += 1;
            },
            else => {
                prev = 'v';
                i += 1;
            },
        }
    }
    return null;
}

const testing = std.testing;

fn hex(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

test "the hashes are of the exact bytes, however the response was cut up" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const request = "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}";
    const response = "{\"id\":\"chatcmpl-abc123\",\"object\":\"chat.completion\",\"choices\":[]}\n";

    var whole: Evidence = .{};
    whole.begin(request);
    whole.feed(response);
    const a = try whole.report(arena);
    try testing.expectEqualStrings(&hex(request), a.request_sha256);
    try testing.expectEqualStrings(&hex(response), a.response_sha256);
    try testing.expectEqualStrings("chatcmpl-abc123", a.completion_id.?);

    // Byte by byte, as a slow stream delivers it: the same hash and id.
    var pieces: Evidence = .{};
    pieces.begin(request);
    for (response) |c| pieces.feed(&.{c});
    const b = try pieces.report(arena);
    try testing.expectEqualStrings(a.response_sha256, b.response_sha256);
    try testing.expectEqualStrings("chatcmpl-abc123", b.completion_id.?);

    // One byte more or less is another hash (the trailing newline counts).
    var other: Evidence = .{};
    other.begin(request);
    other.feed(response[0 .. response.len - 1]);
    const c = try other.report(arena);
    try testing.expect(!std.mem.eql(u8, a.response_sha256, c.response_sha256));
}

test "a second attempt starts from nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var e: Evidence = .{};
    e.begin("first request");
    e.feed("{\"id\":\"one\"} and a lot more that the second attempt never saw");
    e.begin("second request");
    e.feed("{\"id\":\"two\"}");
    const r = try e.report(arena);
    try testing.expectEqualStrings(&hex("second request"), r.request_sha256);
    try testing.expectEqualStrings(&hex("{\"id\":\"two\"}"), r.response_sha256);
    try testing.expectEqualStrings("two", r.completion_id.?);
}

test "a stream is hashed with its framing, and its id is the first event's" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stream = ": keep-alive\n\ndata: {\"id\":\"chatcmpl-s1\",\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-s1\",\"choices\":[{\"delta\":{\"content\":\"b\"}}]}\n\ndata: [DONE]\n\n";
    var e: Evidence = .{};
    e.begin("{}");
    var rest: []const u8 = stream;
    while (rest.len > 0) {
        const n = @min(rest.len, 7);
        e.feed(rest[0..n]);
        rest = rest[n..];
    }
    const r = try e.report(arena);
    try testing.expectEqualStrings(&hex(stream), r.response_sha256);
    try testing.expectEqualStrings("chatcmpl-s1", r.completion_id.?);

    // A long body is hashed to its end although only its start is kept.
    var long: Evidence = .{};
    long.begin("{}");
    var sha: Sha256 = .init(.{});
    const head = "{\"id\":\"resp_long\",\"output\":\"";
    long.feed(head);
    sha.update(head);
    var n: usize = 0;
    while (n < 3000) : (n += 1) {
        long.feed("0123456789");
        sha.update("0123456789");
    }
    long.feed("\"}");
    sha.update("\"}");
    var d: [32]u8 = undefined;
    sha.final(&d);
    const lr = try long.report(arena);
    try testing.expectEqualStrings(&std.fmt.bytesToHex(d, .lower), lr.response_sha256);
    try testing.expectEqualStrings("resp_long", lr.completion_id.?);
}

test "completion ids: where they are read from and what is refused" {
    try testing.expectEqualStrings("chatcmpl-1", completionId("{\"object\":\"x\",\"usage\":{\"id\":\"inner\"},\"id\":\"chatcmpl-1\"}").?);
    try testing.expectEqualStrings("resp_9", completionId(" \n{\"id\":\"resp_9\"").?);
    // The Responses API's events carry the id inside `response`.
    try testing.expectEqualStrings("resp_7", completionId("event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"object\":\"response\",\"id\":\"resp_7\"}}\n\n").?);
    // An id in a nested object, an array element or a key is not the completion's.
    try testing.expectEqual(@as(?[]const u8, null), completionId("{\"choices\":[{\"id\":\"no\"}],\"meta\":{\"id\":\"no\"}}"));
    try testing.expectEqual(@as(?[]const u8, null), completionId("{\"a\":[\"id\",\"x\"],\"b\":{\"x\":{\"id\":\"deep\"}}}"));
    try testing.expectEqual(@as(?[]const u8, null), completionId("{\"response\":{\"x\":{\"id\":\"deep\"}}}"));
    // Not a string, escaped, with characters that do not belong in a path, too long, cut off.
    try testing.expectEqual(@as(?[]const u8, null), completionId("{\"id\":42}"));
    try testing.expectEqual(@as(?[]const u8, null), completionId("{\"id\":\"a\\u002fb\"}"));
    try testing.expectEqual(@as(?[]const u8, null), completionId("{\"id\":\"../x\"}"));
    try testing.expectEqual(@as(?[]const u8, null), completionId("{\"id\":\"a b\"}"));
    try testing.expectEqual(@as(?[]const u8, null), completionId("{\"id\":\"" ++ &@as([201]u8, @splat('a')) ++ "\"}"));
    try testing.expectEqual(@as(?[]const u8, null), completionId("{\"id\":\"cut"));
    try testing.expectEqual(@as(?[]const u8, null), completionId(""));
    try testing.expectEqual(@as(?[]const u8, null), completionId("data: [DONE]\n\n"));
    try testing.expectEqual(@as(?[]const u8, null), completionId("[{\"id\":\"x\"}]"));
    // Deeper than the scanner follows: given up on, not misread.
    try testing.expectEqual(@as(?[]const u8, null), completionId("{\"a\":" ++ &@as([40]u8, @splat('[')) ++ &@as([40]u8, @splat(']')) ++ ",\"id\":\"late\"}"));
}
