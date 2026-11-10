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
const guard = @import("guard.zig");

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

/// From the control plane (job and file responses) these reach the client:
/// how a stored file must be treated by a browser, where it lives when it is
/// in a bucket (`location` on a 302), and when to retry. The request ids are
/// not in the list: the gateway sets its own, which the control plane echoes.
const control_exact = [_][]const u8{
    "content-disposition",
    "x-content-type-options",
    "content-security-policy",
    "cache-control",
    "retry-after",
    "location",
};

/// A presigned bucket URL in `location` is long.
pub const max_control_value_len = 4096;

pub fn passesFromControl(name: []const u8) bool {
    for (control_exact) |e| if (std.ascii.eqlIgnoreCase(name, e)) return true;
    return false;
}

/// The headers of `head_bytes` (a raw response head) that may be relayed,
/// copied into `arena` because the head is invalidated once the body is read.
pub fn collect(arena: std.mem.Allocator, head_bytes: []const u8) ![]const http.Header {
    return collectWith(arena, head_bytes, passes, max_value_len);
}

/// The same for a response head from the control plane.
pub fn collectFromControl(arena: std.mem.Allocator, head_bytes: []const u8) ![]const http.Header {
    return collectWith(arena, head_bytes, passesFromControl, max_control_value_len);
}

/// The ids to put in `x-request-id` and `request-id`. A provider's own id is
/// preferred (a support ticket can quote it); when it sent only one of the
/// two headers that id goes in both, so the two never disagree; without
/// either, both carry the gateway's id.
pub fn requestIds(relayed: []const http.Header, own: []const u8) struct { x_request_id: []const u8, request_id: []const u8 } {
    const x = find(relayed, "x-request-id");
    const r = find(relayed, "request-id");
    return .{ .x_request_id = x orelse r orelse own, .request_id = r orelse x orelse own };
}

/// Of two `retry-after` values, the one that waits longer. Values that are
/// not a plain number of seconds (an HTTP date) lose to ones that are.
pub fn longerRetryAfter(a: ?[]const u8, b: ?[]const u8) ?[]const u8 {
    const av = a orelse return b;
    const bv = b orelse return a;
    const an = std.fmt.parseInt(u64, std.mem.trim(u8, av, " "), 10) catch return bv;
    const bn = std.fmt.parseInt(u64, std.mem.trim(u8, bv, " "), 10) catch return av;
    return if (bn > an) bv else av;
}

fn collectWith(arena: std.mem.Allocator, head_bytes: []const u8, comptime pass: fn ([]const u8) bool, comptime max_len: usize) ![]const http.Header {
    var out: std.ArrayList(http.Header) = .empty;
    // Not `std.http.HeaderIterator`: it unwraps a null on a line without a
    // colon, and this head comes from the network.
    var it = guard.HeaderIterator.init(head_bytes);
    while (it.next()) |h| {
        if (out.items.len >= max_headers) break;
        if (!pass(h.name)) continue;
        if (h.value.len == 0 or h.value.len > max_len) continue;
        // Nothing with a control byte in it (a bare CR or LF above all) is relayed.
        if (hasControl(h.value) or hasControl(h.name)) continue;
        try out.append(arena, .{ .name = try arena.dupe(u8, h.name), .value = try arena.dupe(u8, h.value) });
    }
    return out.items;
}

fn hasControl(text: []const u8) bool {
    for (text) |c| if (c < 0x20 or c == 0x7f) return true;
    return false;
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

test "a malformed upstream head is skipped over, not trusted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A line without a colon, a truncated head, and control bytes in a value.
    const got = try collect(arena, "HTTP/1.1 200 OK\r\nX\r\nretry-after: 7\r\nx-request-id: a\x01b\r\nx-ratelimit-reset: 1\rs\r\nrequest-id: ok");
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("7", find(got, "retry-after").?);
    try testing.expectEqualStrings("ok", find(got, "request-id").?);
    try testing.expect(find(got, "x-request-id") == null);

    for ([_][]const u8{ "", "X", "HTTP/1.1 200 OK\r\nX\r\n", "\r\n\r\n", "HTTP/1.1 200 OK\r\n:\r\n: \r\n" }) |head| {
        try testing.expectEqual(@as(usize, 0), (try collect(arena, head)).len);
    }
}

test "control-plane headers: file handling, redirects and retry hints pass; nothing else" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const filler: [900]u8 = @splat('a');
    const long_url = try std.fmt.allocPrint(arena, "https://bucket.example/{s}?X-Amz-Signature=abc", .{&filler});
    const head = try std.fmt.allocPrint(arena, "HTTP/1.1 302 Found\r\n" ++
        "content-type: application/json\r\n" ++
        "Location: {s}\r\n" ++
        "Content-Disposition: attachment; filename=\"out-0.png\"\r\n" ++
        "x-content-type-options: nosniff\r\n" ++
        "content-security-policy: sandbox; default-src 'none'\r\n" ++
        "cache-control: private, max-age=0\r\n" ++
        "retry-after: 10\r\n" ++
        "set-cookie: omnigate_session=secret\r\n" ++
        "x-request-id: from-the-control-plane\r\n" ++
        "server: Bandit\r\n" ++
        "content-length: 0\r\n\r\n", .{long_url});
    const kept = try collectFromControl(arena, head);
    try testing.expectEqual(@as(usize, 6), kept.len);
    try testing.expectEqualStrings(long_url, find(kept, "location").?);
    try testing.expectEqualStrings("nosniff", find(kept, "X-Content-Type-Options").?);
    try testing.expect(find(kept, "set-cookie") == null);
    try testing.expect(find(kept, "x-request-id") == null);
    try testing.expect(find(kept, "server") == null);
    // The provider allowlist is a different list.
    try testing.expect(!passes("location") and !passes("content-disposition"));
    try testing.expect(!passesFromControl("x-ratelimit-remaining-requests"));
}

test "request ids: the provider's, one for both when it sent only one, else ours" {
    const both = [_]http.Header{ .{ .name = "x-request-id", .value = "x1" }, .{ .name = "Request-Id", .value = "r1" } };
    const only_x = [_]http.Header{.{ .name = "X-Request-Id", .value = "x1" }};
    const only_r = [_]http.Header{.{ .name = "request-id", .value = "r1" }};

    var ids = requestIds(&both, "own");
    try testing.expectEqualStrings("x1", ids.x_request_id);
    try testing.expectEqualStrings("r1", ids.request_id);
    ids = requestIds(&only_x, "own");
    try testing.expectEqualStrings("x1", ids.x_request_id);
    try testing.expectEqualStrings("x1", ids.request_id);
    ids = requestIds(&only_r, "own");
    try testing.expectEqualStrings("r1", ids.x_request_id);
    try testing.expectEqualStrings("r1", ids.request_id);
    ids = requestIds(&.{}, "own");
    try testing.expectEqualStrings("own", ids.x_request_id);
    try testing.expectEqualStrings("own", ids.request_id);
}

test "the longer of two retry-after values" {
    try testing.expectEqualStrings("30", longerRetryAfter("7", "30").?);
    try testing.expectEqualStrings("30", longerRetryAfter("30", "7").?);
    try testing.expectEqualStrings("7", longerRetryAfter(null, "7").?);
    try testing.expectEqualStrings("7", longerRetryAfter("7", null).?);
    try testing.expect(longerRetryAfter(null, null) == null);
    // A date cannot be compared; the number wins either way round.
    try testing.expectEqualStrings("5", longerRetryAfter("Wed, 21 Oct 2026 07:28:00 GMT", "5").?);
    try testing.expectEqualStrings("5", longerRetryAfter("5", "Wed, 21 Oct 2026 07:28:00 GMT").?);
}
