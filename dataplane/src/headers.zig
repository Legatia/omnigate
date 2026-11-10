//! Which provider response headers reach the client.
//!
//! Most of what an upstream sends in its response head is about the hop
//! between the gateway and the provider (framing, connection handling,
//! cookies, the provider's CDN) and must not be relayed. A few headers are
//! meant for the caller and useful to it: how long to wait before retrying,
//! how much rate limit is left, and the provider's request id for support
//! tickets. Those are passed on, by allowlist, under their original names
//! (also for translated responses: a client that asked in the OpenAI format
//! still gets `anthropic-ratelimit-*` as Anthropic sent them).

const std = @import("std");
const http = std.http;

/// Passed when the name matches exactly (case-insensitive).
const exact = [_][]const u8{
    "retry-after",
    "retry-after-ms",
    "x-should-retry",
    "x-request-id",
    "request-id",
    "openai-processing-ms",
    "openai-version",
};

/// Passed when the name starts with one of these (case-insensitive).
const prefixes = [_][]const u8{
    "x-ratelimit-",
    "anthropic-ratelimit-",
};

/// Bounds on what one response may relay.
pub const max_headers = 32;
pub const max_value_len = 512;

pub fn passes(name: []const u8) bool {
    for (exact) |e| if (std.ascii.eqlIgnoreCase(name, e)) return true;
    for (prefixes) |p| if (std.ascii.startsWithIgnoreCase(name, p)) return true;
    return false;
}

/// The headers of `head_bytes` (a raw response head) that may be relayed,
/// copied into `arena` because the head is invalidated once the body is read.
pub fn collect(arena: std.mem.Allocator, head_bytes: []const u8) ![]const http.Header {
    var out: std.ArrayList(http.Header) = .empty;
    var it = http.HeaderIterator.init(head_bytes);
    while (it.next()) |h| {
        if (out.items.len >= max_headers) break;
        if (!passes(h.name)) continue;
        if (h.value.len == 0 or h.value.len > max_value_len) continue;
        // The parser splits on CRLF, but a bare CR or LF must never be relayed.
        if (std.mem.findAny(u8, h.value, "\r\n") != null) continue;
        try out.append(arena, .{ .name = try arena.dupe(u8, h.name), .value = try arena.dupe(u8, h.value) });
    }
    return out.items;
}

pub fn find(list: []const http.Header, name: []const u8) ?[]const u8 {
    for (list) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

const testing = std.testing;

test "client-relevant headers pass, hop-by-hop and sensitive ones do not" {
    for ([_][]const u8{
        "retry-after",                            "Retry-After",                      "retry-after-ms",
        "x-request-id",                           "request-id",                       "openai-processing-ms",
        "x-ratelimit-limit-requests",             "X-RateLimit-Remaining-Tokens",     "x-ratelimit-reset-tokens",
        "anthropic-ratelimit-requests-remaining", "anthropic-ratelimit-tokens-reset", "x-should-retry",
    }) |name| try testing.expect(passes(name));

    for ([_][]const u8{
        "connection",                  "keep-alive",         "transfer-encoding",         "content-length",
        "content-encoding",            "content-type",       "te",                        "trailer",
        "upgrade",                     "proxy-authenticate", "proxy-authorization",       "authorization",
        "www-authenticate",            "set-cookie",         "cookie",                    "x-api-key",
        "openai-organization",         "openai-project",     "anthropic-organization-id", "cf-ray",
        "server",                      "date",               "via",                       "strict-transport-security",
        "access-control-allow-origin", "x-ratelimit",        "ratelimit-x",               "",
    }) |name| try testing.expect(!passes(name));
}

test "collect keeps only allowed headers, with their names and values" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const head = "HTTP/1.1 429 Too Many Requests\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Retry-After: 7\r\n" ++
        "Set-Cookie: session=secret\r\n" ++
        "x-ratelimit-remaining-requests: 0\r\n" ++
        "anthropic-ratelimit-tokens-reset: 2026-11-10T12:00:00Z\r\n" ++
        "request-id: req_123\r\n" ++
        "x-request-id:\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n";
    const kept = try collect(arena, head);
    try testing.expectEqual(@as(usize, 4), kept.len);
    try testing.expectEqualStrings("Retry-After", kept[0].name);
    try testing.expectEqualStrings("7", kept[0].value);
    try testing.expectEqualStrings("0", find(kept, "X-RateLimit-Remaining-Requests").?);
    try testing.expectEqualStrings("2026-11-10T12:00:00Z", find(kept, "anthropic-ratelimit-tokens-reset").?);
    try testing.expectEqualStrings("req_123", find(kept, "request-id").?);
    try testing.expectEqual(@as(?[]const u8, null), find(kept, "set-cookie"));
    // An empty value is not relayed.
    try testing.expectEqual(@as(?[]const u8, null), find(kept, "x-request-id"));
}

test "oversized values and a flood of headers are bounded" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var head: std.ArrayList(u8) = .empty;
    try head.appendSlice(arena, "HTTP/1.1 200 OK\r\n");
    try head.appendSlice(arena, "x-ratelimit-huge: ");
    try head.appendNTimes(arena, 'a', max_value_len + 1);
    try head.appendSlice(arena, "\r\n");
    for (0..max_headers + 10) |i| {
        try head.print(arena, "x-ratelimit-n{d}: {d}\r\n", .{ i, i });
    }
    try head.appendSlice(arena, "\r\n");

    const kept = try collect(arena, head.items);
    try testing.expectEqual(@as(usize, max_headers), kept.len);
    try testing.expectEqual(@as(?[]const u8, null), find(kept, "x-ratelimit-huge"));
}
