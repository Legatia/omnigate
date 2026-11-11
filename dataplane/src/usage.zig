//! Streaming token-usage extractor.
//!
//! Reads response bytes as they flow through the proxy (a JSON document or an
//! SSE stream of JSON documents, OpenAI or Anthropic shape) without buffering
//! them. It is a small JSON tokenizer that only tracks where it is: a number
//! counts as usage only at the places the protocols put usage,
//!
//!     usage.<field>                         chat completions, embeddings,
//!                                           Anthropic messages and message_delta
//!     usage.<details>.cached_tokens         OpenAI prompt cache
//!     message.usage.<field>                 Anthropic message_start
//!     response.usage.<field>                Responses API stream
//!     response.usage.<details>.cached_tokens
//!
//! and never anywhere else. An earlier version searched the raw bytes for
//! `"prompt_tokens":`, so text a client could get echoed into a response (a
//! tool schema, a tool's JSON arguments) could change its own bill. Strings
//! are skipped as strings here, and a key only matters at the exact path.
//!
//! Values are max-merged: Anthropic reports cumulative `output_tokens` in
//! `message_delta`, OpenAI reports one final `usage` object. Being a byte at
//! a time state machine, it does not care where network reads split the data.
//!
//! The scanner records what the provider said, in the provider's own terms.
//! The two protocols disagree about prompt caching, so `normalized` turns
//! that into one meaning for billing:
//!
//!   * OpenAI style (chat completions and the Responses API): the input
//!     count (`prompt_tokens` / `input_tokens`) INCLUDES tokens read from the
//!     cache, which are also given separately as `cached_tokens` inside
//!     `prompt_tokens_details` / `input_tokens_details`.
//!   * Anthropic style: `input_tokens` EXCLUDES the cache; reads are
//!     `cache_read_input_tokens` and writes `cache_creation_input_tokens`.

const std = @import("std");
const Kind = @import("config.zig").Kind;

/// No count is believed beyond this (about a trillion tokens), so nothing
/// derived from provider numbers can overflow.
pub const max_count: u64 = 1 << 40;

/// Bytes of request or response text taken as one token when a count has to
/// be estimated (see `estimated`). Four is the usual rule of thumb for
/// English; JSON framing makes real text denser than that, so for a request
/// body this errs on the high side.
pub const estimate_bytes_per_token = 4;

/// Tokens allowed for one non-text part of a request (an image, a document,
/// audio) when the input has to be estimated. Such a part is often a URL of
/// a few dozen bytes that the provider turns into hundreds or thousands of
/// tokens, so the size of the request says nothing about it.
pub const estimate_tokens_per_media_part = 1600;

/// A stand-in for the input token count of a request whose provider never
/// reported one: its size at four bytes a token (generous for JSON), plus an
/// allowance for every image, document or audio part it names. Deliberately
/// on the high side: it is only used when the real figure is lost, and the
/// provider charges for the request either way.
pub fn estimateInput(request_body: []const u8) u64 {
    const text: u64 = request_body.len / estimate_bytes_per_token;
    // The `type` values the two protocols use for parts that are not text.
    // (`image_url` also names the field next to it, so OpenAI images count
    // twice; that is in keeping with erring high.)
    var parts: u64 = 0;
    for ([_][]const u8{ "\"image_url\"", "\"image\"", "\"input_image\"", "\"document\"", "\"file\"", "\"input_file\"", "\"input_audio\"" }) |needle| {
        parts += std.mem.count(u8, request_body, needle);
    }
    return @min(max_count, text +| parts *| estimate_tokens_per_media_part);
}

/// Is `name` a field whose string value is generated text (as opposed to an
/// id, a role or a type)? Used only to size an estimate.
fn isContentKey(name: []const u8) bool {
    for ([_][]const u8{ "content", "text", "delta", "arguments", "partial_json", "thinking", "reasoning_content", "reasoning", "refusal" }) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    return false;
}

const Field = enum { input, output, cached, cache_read, cache_write };

const KeyId = enum {
    none,
    other,
    usage,
    message,
    response,
    prompt_tokens,
    input_tokens,
    completion_tokens,
    output_tokens,
    prompt_tokens_details,
    input_tokens_details,
    cached_tokens,
    cache_read_input_tokens,
    cache_creation_input_tokens,

    fn of(name: []const u8) KeyId {
        return std.meta.stringToEnum(KeyId, name) orelse .other;
    }

    fn tokenField(k: KeyId) ?Field {
        return switch (k) {
            .prompt_tokens, .input_tokens => .input,
            .completion_tokens, .output_tokens => .output,
            .cache_read_input_tokens => .cache_read,
            .cache_creation_input_tokens => .cache_write,
            else => null,
        };
    }

    fn isDetails(k: KeyId) bool {
        return k == .prompt_tokens_details or k == .input_tokens_details;
    }
};

/// Token counts with one meaning whatever the provider: `input_tokens` is the
/// input NOT served from a prompt cache; cache reads and writes are separate.
pub const Normalized = struct {
    input_tokens: u64 = 0,
    cached_input_tokens: u64 = 0,
    cache_write_input_tokens: u64 = 0,
    output_tokens: u64 = 0,
};

pub const Usage = struct {
    /// As reported: OpenAI includes cached tokens here, Anthropic does not.
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    /// OpenAI style `cached_tokens`.
    cached_tokens: u64 = 0,
    /// Anthropic style.
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
    /// The provider's closing figures were seen: a top-level `usage` with an
    /// output count (a whole JSON answer, OpenAI's last stream chunk,
    /// Anthropic's `message_delta`), or the Responses API's `response.usage`.
    final_seen: bool = false,
    /// Bytes fed, and SSE `data:` lines among them.
    bytes: u64 = 0,
    events: u64 = 0,
    /// Bytes of generated text seen: string values of the fields that carry
    /// it (`isContentKey`), at any depth. For estimates only.
    content_bytes: u64 = 0,

    // --- where the reader is -------------------------------------------
    framing: enum { unknown, json, sse } = .unknown,
    line: enum { start, data, skip } = .start,
    prefix: u8 = 0,
    state: enum { idle, key, string, number } = .idle,
    escaped: bool = false,
    /// Open arrays and objects. Only the first `tracked` levels are described.
    depth: u32 = 0,
    is_object: [tracked]bool = @splat(false),
    want_key: [tracked]bool = @splat(false),
    keys: [tracked]KeyId = @splat(.none),
    key_buf: [32]u8 = undefined,
    key_len: u8 = 0,
    key_plain: bool = true,
    number: u64 = 0,
    number_plain: bool = true,
    number_field: ?Field = null,
    number_final: bool = false,
    // The start of the string being read or last read, to recognise it as a
    // content key when a colon follows.
    recent: [20]u8 = undefined,
    recent_len: u8 = 0,
    recent_plain: bool = true,
    /// The last token was a string (so a colon now makes it a key).
    after_string: bool = false,
    /// The value that comes next belongs to a content key.
    value_is_content: bool = false,
    /// Inside a string that is such a value.
    counting: bool = false,

    const tracked = 4;

    /// The counts in gateway terms. `kind` is the protocol of the UPSTREAM
    /// that produced the bytes, which for a translated request is not the
    /// protocol the client speaks.
    pub fn normalized(u: *const Usage, kind: Kind) Normalized {
        return switch (kind) {
            .openai => .{
                // Never negative, whatever a provider reports.
                .input_tokens = u.input_tokens -| u.cached_tokens,
                .cached_input_tokens = @min(u.cached_tokens, u.input_tokens),
                .output_tokens = u.output_tokens,
            },
            .anthropic => .{
                .input_tokens = u.input_tokens,
                .cached_input_tokens = u.cache_read_input_tokens,
                .cache_write_input_tokens = u.cache_creation_input_tokens,
                .output_tokens = u.output_tokens,
            },
        };
    }

    /// What to bill for a response that was cut off before its closing usage
    /// arrived (the client left, or the upstream died, mid-stream). The
    /// provider still charges the operator for what it generated, so billing
    /// nothing would make every aborted stream free.
    ///
    /// Never less than what was actually metered. Missing input is
    /// `input_estimate` (see `estimateInput`). Missing output is taken from
    /// what came back, whichever is larger: one token per SSE event, or the
    /// generated text at four bytes a token (providers that send several
    /// tokens per event would otherwise be billed at a fraction); for
    /// anything that was not a stream, the body size.
    pub fn estimated(u: *const Usage, kind: Kind, input_estimate: u64) Normalized {
        var n = u.normalized(kind);
        const input_known = n.input_tokens + n.cached_input_tokens + n.cache_write_input_tokens;
        if (input_known == 0) n.input_tokens = @min(max_count, input_estimate);
        const produced = if (u.framing == .sse)
            @max(u.events, u.content_bytes / estimate_bytes_per_token)
        else
            u.bytes / estimate_bytes_per_token;
        n.output_tokens = @min(max_count, @max(n.output_tokens, produced));
        return n;
    }

    pub fn feed(u: *Usage, chunk: []const u8) void {
        u.bytes +|= chunk.len;
        for (chunk) |c| {
            switch (u.framing) {
                .json => u.jsonByte(c),
                .sse => u.sseByte(c),
                .unknown => {
                    if (std.ascii.isWhitespace(c)) continue;
                    // A JSON document starts with a brace; an event stream
                    // with a field name or a comment.
                    if (c == '{' or c == '[') {
                        u.framing = .json;
                        u.jsonByte(c);
                    } else {
                        u.framing = .sse;
                        u.sseByte(c);
                    }
                },
            }
        }
    }

    /// SSE: only what follows `data:` on a line is JSON; every such line is a
    /// document of its own.
    fn sseByte(u: *Usage, c: u8) void {
        switch (u.line) {
            .start => {
                const want = "data:";
                if (c == want[u.prefix]) {
                    u.prefix += 1;
                    if (u.prefix == want.len) {
                        u.prefix = 0;
                        u.line = .data;
                        u.events +|= 1;
                        u.resetDocument();
                    }
                } else {
                    u.prefix = 0;
                    if (c != '\n') u.line = .skip;
                }
            },
            .data => {
                // The line break ends a number that ran up to it.
                u.jsonByte(c);
                if (c == '\n') u.line = .start;
            },
            .skip => if (c == '\n') {
                u.line = .start;
            },
        }
    }

    fn resetDocument(u: *Usage) void {
        u.state = .idle;
        u.escaped = false;
        u.depth = 0;
        u.after_string = false;
        u.value_is_content = false;
        u.counting = false;
    }

    fn jsonByte(u: *Usage, c: u8) void {
        switch (u.state) {
            .key, .string => {
                if (u.escaped or c != '"') {
                    if (u.counting) u.content_bytes +|= 1;
                    if (u.escaped or c == '\\' or u.recent_len == u.recent.len) {
                        u.recent_plain = false;
                    } else {
                        u.recent[u.recent_len] = c;
                        u.recent_len += 1;
                    }
                }
                if (u.escaped) {
                    u.escaped = false;
                    // None of the names we look for needs an escape.
                    u.key_plain = false;
                } else if (c == '\\') {
                    u.escaped = true;
                } else if (c == '"') {
                    if (u.state == .key) {
                        u.keys[u.depth - 1] = if (u.key_plain) KeyId.of(u.key_buf[0..u.key_len]) else .other;
                    }
                    u.state = .idle;
                    u.counting = false;
                    u.after_string = true;
                } else if (u.state == .key) {
                    if (u.key_len < u.key_buf.len) {
                        u.key_buf[u.key_len] = c;
                        u.key_len += 1;
                    } else {
                        u.key_plain = false;
                    }
                }
                return;
            },
            .number => {
                if (std.ascii.isDigit(c)) {
                    u.number = @min(max_count, u.number *| 10 +| (c - '0'));
                    return;
                }
                if (c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-') {
                    // Not a plain non-negative integer: not a token count.
                    u.number_plain = false;
                    return;
                }
                u.commitNumber();
                u.state = .idle;
                // Fall through: this byte ends the number and means something itself.
            },
            .idle => {},
        }

        // For the estimate: which string values are generated text. Unlike
        // the usage fields this is not tied to a path, so it works at any
        // depth (tool-call arguments sit seven levels down).
        switch (c) {
            '"' => {
                u.counting = u.value_is_content;
                u.value_is_content = false;
                u.after_string = false;
                u.recent_len = 0;
                u.recent_plain = true;
            },
            ':' => {
                u.value_is_content = u.after_string and u.recent_plain and isContentKey(u.recent[0..u.recent_len]);
                u.after_string = false;
            },
            ' ', '\t', '\r', '\n' => {},
            else => {
                u.after_string = false;
                u.value_is_content = false;
            },
        }

        const level: ?usize = if (u.depth >= 1 and u.depth <= tracked) u.depth - 1 else null;
        switch (c) {
            '"' => {
                if (level != null and u.is_object[level.?] and u.want_key[level.?]) {
                    u.state = .key;
                    u.key_len = 0;
                    u.key_plain = true;
                } else {
                    u.state = .string;
                }
            },
            ':' => if (level) |l| {
                u.want_key[l] = false;
            },
            ',' => if (level) |l| {
                if (u.is_object[l]) {
                    u.want_key[l] = true;
                    u.keys[l] = .none;
                }
            },
            '{', '[' => {
                u.depth +|= 1;
                if (u.depth <= tracked) {
                    u.is_object[u.depth - 1] = c == '{';
                    u.want_key[u.depth - 1] = c == '{';
                    u.keys[u.depth - 1] = .none;
                }
            },
            '}', ']' => u.depth -|= 1,
            '0'...'9', '-' => {
                u.state = .number;
                u.number = if (c == '-') 0 else c - '0';
                u.number_plain = c != '-';
                u.number_field = u.fieldHere();
            },
            else => {},
        }
    }

    /// Which count a number starting here is, if this is one of the places
    /// usage lives. Sets `number_final` for the provider's closing figures.
    fn fieldHere(u: *Usage) ?Field {
        u.number_final = false;
        if (u.depth < 2 or u.depth > tracked) return null;
        for (u.is_object[0..u.depth]) |is_obj| if (!is_obj) return null;
        const k = u.keys;
        switch (u.depth) {
            2 => {
                if (k[0] != .usage) return null;
                const f = k[1].tokenField() orelse return null;
                u.number_final = f == .output;
                return f;
            },
            3 => {
                if (k[0] == .usage and k[1].isDetails() and k[2] == .cached_tokens) return .cached;
                if ((k[0] == .message or k[0] == .response) and k[1] == .usage) {
                    const f = k[2].tokenField() orelse return null;
                    u.number_final = k[0] == .response and f == .output;
                    return f;
                }
                return null;
            },
            4 => {
                if ((k[0] == .message or k[0] == .response) and k[1] == .usage and k[2].isDetails() and k[3] == .cached_tokens) return .cached;
                return null;
            },
            else => return null,
        }
    }

    fn commitNumber(u: *Usage) void {
        const field = u.number_field orelse return;
        if (!u.number_plain) return;
        const n = u.number;
        switch (field) {
            .input => u.input_tokens = @max(u.input_tokens, n),
            .output => u.output_tokens = @max(u.output_tokens, n),
            .cached => u.cached_tokens = @max(u.cached_tokens, n),
            .cache_read => u.cache_read_input_tokens = @max(u.cache_read_input_tokens, n),
            .cache_write => u.cache_creation_input_tokens = @max(u.cache_creation_input_tokens, n),
        }
        if (u.number_final) u.final_seen = true;
    }
};

/// Removes the usage-only chunk from an OpenAI chat stream.
///
/// The gateway asks every OpenAI stream for usage so it can meter the call.
/// A client that did not ask for it must not see the extra chunk: it has an
/// empty `choices` array, and code written as `chunk.choices[0]` breaks on it.
/// Works on whole SSE events, so an event split across reads is held back
/// until its blank line arrives.
pub const UsageChunkFilter = struct {
    pending: std.ArrayList(u8) = .empty,
    /// How much of `pending` has been searched for the end of an event
    /// without finding one. The search resumes there: looking through all of
    /// a long unfinished event again on every read made the cost of a stream
    /// quadratic in the size of its events (a megabyte per byte received).
    searched: usize = 0,
    /// Bytes examined in search of event ends, in total. Linear in what was
    /// fed, whatever the sizes it arrived in; the tests hold it to that.
    work: u64 = 0,

    /// An event this large is not a usage chunk; stop holding bytes back.
    const max_pending = 1024 * 1024;

    pub fn deinit(f: *UsageChunkFilter, gpa: std.mem.Allocator) void {
        f.pending.deinit(gpa);
    }

    pub fn feed(f: *UsageChunkFilter, gpa: std.mem.Allocator, chunk: []const u8, out: *std.Io.Writer) !void {
        try f.pending.appendSlice(gpa, chunk);
        const items = f.pending.items;
        var start: usize = 0;
        while (f.eventEnd(items, start)) |end| {
            const event = items[start..end];
            if (!isUsageOnly(event)) try out.writeAll(event);
            start = end;
            f.searched = end;
        }
        // No event ends in what is left: none of it is looked at again.
        f.searched = items.len;
        if (items.len - start > max_pending) {
            try out.writeAll(items[start..]);
            start = items.len;
        }
        if (start == 0) return;
        const rest = items.len - start;
        std.mem.copyForwards(u8, items[0..rest], items[start..]);
        f.pending.shrinkRetainingCapacity(rest);
        f.searched -= start;
    }

    /// The upstream ended: pass on whatever is left.
    pub fn finish(f: *UsageChunkFilter, out: *std.Io.Writer) !void {
        if (f.pending.items.len > 0 and !isUsageOnly(f.pending.items)) try out.writeAll(f.pending.items);
        f.pending.clearRetainingCapacity();
        f.searched = 0;
    }

    /// Where the first complete SSE event of `bytes[start..]` ends (after
    /// its blank line: `\n\n` or `\r\n\r\n`, whichever comes first). One
    /// pass, starting where the last search stopped.
    fn eventEnd(f: *UsageChunkFilter, bytes: []const u8, start: usize) ?usize {
        // A terminator may straddle the mark by up to three bytes.
        var i = @max(start, f.searched -| 3);
        while (std.mem.findScalarPos(u8, bytes, i, '\n')) |lf| {
            f.work += lf + 1 - i;
            if (lf + 1 < bytes.len and bytes[lf + 1] == '\n') return lf + 2;
            if (lf > start and bytes[lf - 1] == '\r' and lf + 2 < bytes.len and bytes[lf + 1] == '\r' and bytes[lf + 2] == '\n') return lf + 3;
            i = lf + 1;
        }
        f.work += bytes.len - @min(bytes.len, i);
        return null;
    }

    fn isUsageOnly(event: []const u8) bool {
        // Inside a JSON string these quotes would be escaped, so a plain match
        // can only be the chunk's own keys.
        if (std.mem.find(u8, event, "\"usage\"") == null) return false;
        return std.mem.find(u8, event, "\"choices\":[]") != null or
            std.mem.find(u8, event, "\"choices\": []") != null;
    }
};

test "usage chunk filter: the work is linear however the stream is cut up" {
    const gpa = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});

    // One event of nearly the size the filter will hold back, a byte at a
    // time: this used to search the whole of it again for every byte.
    {
        var f: UsageChunkFilter = .{};
        defer f.deinit(gpa);
        const total: usize = 900 * 1024;
        for (0..total) |_| try f.feed(gpa, "x", &discard.writer);
        try std.testing.expect(f.work <= 8 * total);
        try std.testing.expectEqual(total, f.pending.items.len);
    }
    // Many small events in one read: each used to be found by searching to
    // the end of the read twice.
    {
        var f: UsageChunkFilter = .{};
        defer f.deinit(gpa);
        const events = 20_000;
        const text = try gpa.alloc(u8, events * 9);
        defer gpa.free(text);
        for (0..events) |i| @memcpy(text[i * 9 ..][0..9], "data: 1\n\n");
        try f.feed(gpa, text, &discard.writer);
        try std.testing.expect(f.work <= 8 * text.len);
        try std.testing.expectEqual(@as(usize, 0), f.pending.items.len);
    }
}

test "usage chunk filter: same output at every split, both line endings" {
    const gpa = std.testing.allocator;
    const stream =
        "data: {\"choices\":[{\"delta\":{\"content\":\"a\\n\\nb\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"c\"}}],\"usage\":null}\r\n\r\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2}}\r\n\r\n" ++
        ": comment\r\n\r\n" ++
        "data: {\"choices\": [],\"usage\":{\"prompt_tokens\":1}}\n\n" ++
        "data: [DONE]\n\n" ++ "data: unfinished";
    const expected =
        "data: {\"choices\":[{\"delta\":{\"content\":\"a\\n\\nb\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"c\"}}],\"usage\":null}\r\n\r\n" ++
        ": comment\r\n\r\n" ++
        "data: [DONE]\n\n" ++ "data: unfinished";
    for ([_]usize{ stream.len, 1, 2, 3, 4, 5, 7, 11, 64 }) |step| {
        var f: UsageChunkFilter = .{};
        defer f.deinit(gpa);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var i: usize = 0;
        while (i < stream.len) : (i += step) try f.feed(gpa, stream[i..@min(stream.len, i + step)], &out.writer);
        try f.finish(&out.writer);
        try std.testing.expectEqualStrings(expected, out.written());
    }
}

test "openai non-streaming usage" {
    var u: Usage = .{};
    u.feed("{\"id\":\"x\",\"usage\":{\"prompt_tokens\": 12,\"completion_tokens\":34,\"total_tokens\":46}}");
    try std.testing.expectEqual(@as(u64, 12), u.input_tokens);
    try std.testing.expectEqual(@as(u64, 34), u.output_tokens);
}

test "anthropic sse usage with cache fields" {
    var u: Usage = .{};
    u.feed("event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":25,\"cache_read_input_tokens\":999,\"output_tokens\":1}}}\n\n");
    u.feed("event: message_delta\ndata: {\"usage\":{\"output_tokens\":15}}\n\n");
    try std.testing.expectEqual(@as(u64, 25), u.input_tokens);
    try std.testing.expectEqual(@as(u64, 15), u.output_tokens);
}

/// Feed `text` in pieces of `step` bytes, as a network would deliver it.
fn feedSplit(u: *Usage, text: []const u8, step: usize) void {
    var i: usize = 0;
    while (i < text.len) : (i += step) u.feed(text[i..@min(text.len, i + step)]);
}

fn expectNormalized(expected: Normalized, text: []const u8, kind: Kind) !void {
    // Whole, and split at every awkward size: the result must not depend on it.
    for ([_]usize{ text.len, 1, 2, 3, 5, 7, 13, 31, 64 }) |step| {
        var u: Usage = .{};
        feedSplit(&u, text, step);
        try std.testing.expectEqual(expected, u.normalized(kind));
    }
}

test "openai chat usage: cached tokens are part of prompt_tokens" {
    const body =
        \\{"id":"c","choices":[],"usage":{"prompt_tokens":2006,"completion_tokens":300,"total_tokens":2306,
        \\"prompt_tokens_details":{"cached_tokens":1920,"audio_tokens":0},
        \\"completion_tokens_details":{"reasoning_tokens":64,"audio_tokens":0,"accepted_prediction_tokens":0}}}
    ;
    try expectNormalized(.{ .input_tokens = 86, .cached_input_tokens = 1920, .output_tokens = 300 }, body, .openai);
}

test "openai chat stream: the usage arrives in the last chunk" {
    const stream =
        "data: {\"id\":\"c\",\"choices\":[{\"delta\":{\"content\":\"cached_tokens\"}}],\"usage\":null}\n\n" ++
        "data: {\"id\":\"c\",\"choices\":[],\"usage\":{\"prompt_tokens\":191,\"completion_tokens\":1,\"total_tokens\":192," ++
        "\"prompt_tokens_details\":{\"text_tokens\":191,\"audio_tokens\":0,\"image_tokens\":0,\"cached_tokens\":128}}}\n\n" ++
        "data: [DONE]\n\n";
    try expectNormalized(.{ .input_tokens = 63, .cached_input_tokens = 128, .output_tokens = 1 }, stream, .openai);
}

test "openai responses api usage: cached tokens are part of input_tokens" {
    const body =
        \\{"object":"response","usage":{"input_tokens":328,"input_tokens_details":{"cached_tokens":200},
        \\"output_tokens":52,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":380}}
    ;
    try expectNormalized(.{ .input_tokens = 128, .cached_input_tokens = 200, .output_tokens = 52 }, body, .openai);
}

test "openai usage without cache details is unchanged" {
    try expectNormalized(.{ .input_tokens = 11, .output_tokens = 6 }, "{\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":6,\"total_tokens\":17}}", .openai);
}

test "anthropic usage: cache reads and writes come on top of input_tokens" {
    const body =
        \\{"type":"message","usage":{"input_tokens":21,"cache_creation_input_tokens":188086,"cache_read_input_tokens":4500,
        \\"cache_creation":{"ephemeral_5m_input_tokens":188086,"ephemeral_1h_input_tokens":0},"output_tokens":393}}
    ;
    try expectNormalized(.{ .input_tokens = 21, .cached_input_tokens = 4500, .cache_write_input_tokens = 188086, .output_tokens = 393 }, body, .anthropic);
}

test "anthropic stream: message_start has the input side, message_delta the final output" {
    const stream =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":25," ++
        "\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":999,\"output_tokens\":1}}}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":15}}\n\n";
    try expectNormalized(.{ .input_tokens = 25, .cached_input_tokens = 999, .output_tokens = 15 }, stream, .anthropic);
}

test "a translated request is normalised by the upstream that answered" {
    // An OpenAI client served by an Anthropic upstream: the bytes metered are
    // Anthropic's, so its cache fields count and nothing is subtracted.
    var u: Usage = .{};
    u.feed("{\"usage\":{\"input_tokens\":10,\"cache_read_input_tokens\":90,\"output_tokens\":5}}");
    try std.testing.expectEqual(Normalized{ .input_tokens = 10, .cached_input_tokens = 90, .output_tokens = 5 }, u.normalized(.anthropic));

    // An Anthropic client served by an OpenAI upstream.
    var v: Usage = .{};
    v.feed("{\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":5,\"prompt_tokens_details\":{\"cached_tokens\":90}}}");
    try std.testing.expectEqual(Normalized{ .input_tokens = 10, .cached_input_tokens = 90, .output_tokens = 5 }, v.normalized(.openai));
}

test "a provider that reports more cached than prompt tokens cannot make input negative" {
    var u: Usage = .{};
    u.feed("{\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":1,\"prompt_tokens_details\":{\"cached_tokens\":9}}}");
    try std.testing.expectEqual(Normalized{ .input_tokens = 0, .cached_input_tokens = 5, .output_tokens = 1 }, u.normalized(.openai));
}

test "key and number split across chunks" {
    var u: Usage = .{};
    u.feed("data: {\"usage\":{\"prompt_to");
    u.feed("kens\":12");
    u.feed("34,\"completion_tokens\":5}}");
    try std.testing.expectEqual(@as(u64, 1234), u.input_tokens);
    try std.testing.expectEqual(@as(u64, 5), u.output_tokens);
}

test "usage filter drops only the usage-only chunk, however the stream is split" {
    const gpa = std.testing.allocator;
    const stream =
        "data: {\"id\":\"c\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"}}]}\n\n" ++
        "data: {\"id\":\"c\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"say \\\"choices\\\":[] and \\\"usage\\\"\"}}]}\n\n" ++
        "data: {\"id\":\"c\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":null}\n\n" ++
        "data: {\"id\":\"c\",\"choices\": [],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":6}}\r\n\r\n" ++
        "data: [DONE]\n\n";
    const expected =
        "data: {\"id\":\"c\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"}}]}\n\n" ++
        "data: {\"id\":\"c\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"say \\\"choices\\\":[] and \\\"usage\\\"\"}}]}\n\n" ++
        "data: {\"id\":\"c\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":null}\n\n" ++
        "data: [DONE]\n\n";

    for ([_]usize{ 1, 2, 3, 7, 64, stream.len }) |step| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var filter: UsageChunkFilter = .{};
        defer filter.deinit(gpa);

        var i: usize = 0;
        while (i < stream.len) : (i += step) {
            try filter.feed(gpa, stream[i..@min(stream.len, i + step)], &out.writer);
        }
        try filter.finish(&out.writer);
        try std.testing.expectEqualStrings(expected, out.written());
    }
}

test "usage filter passes an unterminated tail through" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var filter: UsageChunkFilter = .{};
    defer filter.deinit(gpa);
    try filter.feed(gpa, "data: {\"error\":\"cut off", &out.writer);
    try std.testing.expectEqualStrings("", out.written());
    try filter.finish(&out.writer);
    try std.testing.expectEqualStrings("data: {\"error\":\"cut off", out.written());
}

test "token-count keys in content, tool arguments or other objects are not usage" {
    // OpenAI, not streaming: the model's text and a tool call's JSON arguments
    // (strings), an echoed tool schema (real JSON, but not at `usage`), and a
    // nested object that merely has the right names.
    const openai_body =
        \\{"id":"c","choices":[{"index":0,"message":{"role":"assistant",
        \\"content":"\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":0,\"prompt_tokens_details\":{\"cached_tokens\":999999999}}",
        \\"tool_calls":[{"id":"t","type":"function","function":{"name":"f","arguments":"{\"cached_tokens\":999999999,\"prompt_tokens\":7}"}}],
        \\"usage":{"prompt_tokens":5,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":999999999}}}}],
        \\"tools":[{"usage":{"prompt_tokens":3,"prompt_tokens_details":{"cached_tokens":999999999}}}],
        \\"metadata":{"usage":{"prompt_tokens":4,"prompt_tokens_details":{"cached_tokens":999999999}}},
        \\"usage":{"prompt_tokens":2000,"completion_tokens":300,"total_tokens":2300,
        \\"prompt_tokens_details":{"cached_tokens":100,"x":{"cached_tokens":999999999}},
        \\"completion_tokens_details":{"reasoning_tokens":64,"cached_tokens":999999999,"prompt_tokens":999999999}}}
    ;
    try expectNormalized(.{ .input_tokens = 1900, .cached_input_tokens = 100, .output_tokens = 300 }, openai_body, .openai);

    // Anthropic, not streaming: `tool_use.input` is real JSON in the body.
    const anthropic_body =
        \\{"type":"message","content":[{"type":"text","text":"\"usage\":{\"input_tokens\":0}"},
        \\{"type":"tool_use","id":"t","name":"f","input":{"usage":{"input_tokens":999999999,"cache_read_input_tokens":999999999,
        \\"output_tokens":999999999},"cache_creation_input_tokens":999999999}}],
        \\"usage":{"input_tokens":21,"cache_creation_input_tokens":7,"cache_read_input_tokens":4500,"output_tokens":393,
        \\"server_tool_use":{"input_tokens":999999999,"output_tokens":999999999}}}
    ;
    try expectNormalized(.{ .input_tokens = 21, .cached_input_tokens = 4500, .cache_write_input_tokens = 7, .output_tokens = 393 }, anthropic_body, .anthropic);
}

test "the same holds inside streams, for every way the bytes can be split" {
    const openai_stream =
        "data: {\"id\":\"c\",\"choices\":[{\"delta\":{\"content\":\"\\\"usage\\\":{\\\"completion_tokens\\\":999999999}\"}}],\"usage\":null}\n\n" ++
        "data: {\"id\":\"c\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"cached_tokens\\\":999999999}\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c\",\"choices\":[{\"usage\":{\"prompt_tokens\":999999999,\"completion_tokens\":999999999}}]}\r\n\r\n" ++
        ": usage: {\"usage\":{\"prompt_tokens\":999999999}}\n\n" ++
        "event: usage\ndata: {\"id\":\"c\",\"choices\":[],\"usage\":{\"prompt_tokens\":191,\"completion_tokens\":7,\"total_tokens\":198," ++
        "\"prompt_tokens_details\":{\"cached_tokens\":128}}}\n\n" ++
        "data: [DONE]\n\n";
    try expectNormalized(.{ .input_tokens = 63, .cached_input_tokens = 128, .output_tokens = 7 }, openai_stream, .openai);

    const anthropic_stream =
        "event: message_start\r\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":25," ++
        "\"cache_creation_input_tokens\":3,\"cache_read_input_tokens\":999,\"output_tokens\":1}}}\r\n\r\n" ++
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"input\":{\"usage\":{\"output_tokens\":999999999}}}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"usage\\\":{\\\"input_tokens\\\":999999999}}\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"usage\":{\"output_tokens\":999999999},\"message\":{\"usage\":{\"input_tokens\":999999999}}}}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":15}}\n\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";
    try expectNormalized(.{ .input_tokens = 25, .cached_input_tokens = 999, .cache_write_input_tokens = 3, .output_tokens = 15 }, anthropic_stream, .anthropic);

    // The Responses API reports usage inside `response` on its last event.
    const responses_stream =
        "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"\\\"usage\\\":{\\\"output_tokens\\\":999999999}\"}\n\n" ++
        "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"usage\":{\"output_tokens\":999999999}}]," ++
        "\"usage\":{\"input_tokens\":328,\"input_tokens_details\":{\"cached_tokens\":200},\"output_tokens\":52}}}\n\n";
    try expectNormalized(.{ .input_tokens = 128, .cached_input_tokens = 200, .output_tokens = 52 }, responses_stream, .openai);
}

test "only plain non-negative integers count, and absurd ones are capped" {
    var u: Usage = .{};
    u.feed("{\"usage\":{\"prompt_tokens\":-5,\"completion_tokens\":1.5e9,\"input_tokens\":\"12\",\"output_tokens\":true}}");
    try std.testing.expectEqual(Normalized{}, u.normalized(.openai));

    var big: Usage = .{};
    big.feed("{\"usage\":{\"input_tokens\":18446744073709551616,\"cache_read_input_tokens\":99999999999999999999999999," ++
        "\"cache_creation_input_tokens\":18446744073709551615,\"output_tokens\":18446744073709551615}}");
    const n = big.normalized(.anthropic);
    try std.testing.expectEqual(max_count, n.input_tokens);
    try std.testing.expectEqual(max_count, n.cached_input_tokens);
    try std.testing.expectEqual(max_count, n.cache_write_input_tokens);
    try std.testing.expectEqual(max_count, n.output_tokens);
    // Sums of these cannot overflow.
    _ = n.input_tokens + n.cached_input_tokens + n.cache_write_input_tokens + n.output_tokens;
}

test "arbitrary bytes never upset the reader" {
    var prng: std.Random.DefaultPrng = .init(0x0519);
    const random = prng.random();
    const alphabet = "{}[]\":,\\0123456789-.eE \r\ndata:usage_tokensprompt_cached";
    var buf: [512]u8 = undefined;
    for (0..4000) |_| {
        var u: Usage = .{};
        const len = random.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = if (random.boolean()) alphabet[random.uintLessThan(usize, alphabet.len)] else random.int(u8);
        feedSplit(&u, buf[0..len], 1 + random.uintLessThan(usize, 40));
        _ = u.normalized(.openai);
        _ = u.estimated(.anthropic, estimateInput(buf[0..len]));
    }
}

test "a cut-off stream is billed by estimate, never below what was metered" {
    // OpenAI: nothing metered before the last chunk, which never came.
    var u: Usage = .{};
    for (0..40) |_| u.feed("data: {\"id\":\"c\",\"choices\":[{\"delta\":{\"content\":\"word\"}}]}\n\n");
    try std.testing.expect(!u.final_seen);
    try std.testing.expectEqual(Normalized{}, u.normalized(.openai));
    try std.testing.expectEqual(Normalized{ .input_tokens = 250, .output_tokens = 40 }, u.estimated(.openai, 250));

    // Anthropic: the input side is known from message_start and is kept.
    var a: Usage = .{};
    a.feed("event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":25,\"cache_read_input_tokens\":999,\"output_tokens\":1}}}\n\n");
    for (0..9) |_| a.feed("event: content_block_delta\ndata: {\"delta\":{\"text\":\"word\"}}\n\n");
    try std.testing.expect(!a.final_seen);
    try std.testing.expectEqual(Normalized{ .input_tokens = 25, .cached_input_tokens = 999, .output_tokens = 10 }, a.estimated(.anthropic, 25_000));

    // Once the closing figures arrive they are final, and an estimate adds nothing below them.
    a.feed("event: message_delta\ndata: {\"usage\":{\"output_tokens\":500}}\n\n");
    try std.testing.expect(a.final_seen);
    try std.testing.expectEqual(@as(u64, 500), a.estimated(.anthropic, 0).output_tokens);

    var whole: Usage = .{};
    whole.feed("{\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":6}}");
    try std.testing.expect(whole.final_seen);
}

test "an estimate is floored by the text that came back, not only by the event count" {
    // A provider that sends a paragraph per event: 3 events, 1200 bytes of text.
    const paragraph: [400]u8 = @splat('w');
    var u: Usage = .{};
    for (0..3) |_| {
        u.feed("data: {\"id\":\"chatcmpl-0123456789\",\"model\":\"some-long-model-name\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"");
        u.feed(&paragraph);
        u.feed("\"}}]}\n\n");
    }
    try std.testing.expectEqual(@as(u64, 3), u.events);
    // Only the content counts: not the id, the model name or the keys.
    try std.testing.expectEqual(@as(u64, 1200), u.content_bytes);
    try std.testing.expectEqual(@as(u64, 300), u.estimated(.openai, 0).output_tokens);

    // The other shapes generated text arrives in, however the bytes are split.
    const shapes = [_]struct { []const u8, u64 }{
        .{ "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"twelve bytes\"}}\n\n", 12 },
        .{ "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\":\"}}\n\n", 10 },
        .{ "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hmm\"}}\n\n", 3 },
        .{ "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"1234567\"}}]}}]}\n\n", 7 },
        .{ "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"delta\":\"abcd\"}\n\n", 4 },
        .{ "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"abcde\",\"content\":null}}]}\n\n", 5 },
        // Not text: a role, a type that happens to be called text, an empty
        // array of content, a key that merely contains the word.
        .{ "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":\"stop\"}]}\n\n", 0 },
        .{ "data: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\"}}\n\n", 0 },
        .{ "data: {\"message\":{\"content\":[],\"content_type\":\"x\",\"my_text\":\"nope\"}}\n\n", 0 },
        // A string that is a value of nothing (an array element) after a content key.
        .{ "data: {\"content\":[\"not counted\"],\"text\":7}\n\n", 0 },
    };
    for (shapes) |shape| {
        for ([_]usize{ 1, 2, 3, 7, 1000 }) |piece| {
            var s: Usage = .{};
            feedSplit(&s, shape[0], piece);
            try std.testing.expectEqual(shape[1], s.content_bytes);
        }
    }
}

test "the input estimate allows for parts that are not text" {
    try std.testing.expectEqual(@as(u64, 250), estimateInput(&@as([1000]u8, @splat('x'))));
    // An image by URL: a few dozen bytes that the provider counts as many tokens.
    const openai = "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"https://x/y.png\"}}]}]}";
    try std.testing.expect(estimateInput(openai) >= 2 * estimate_tokens_per_media_part);
    const anthropic = "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"url\",\"url\":\"https://x/y.png\"}},{\"type\":\"document\",\"source\":{\"type\":\"url\",\"url\":\"https://x/y.pdf\"}}]}]}";
    try std.testing.expectEqual(anthropic.len / 4 + 2 * estimate_tokens_per_media_part, estimateInput(anthropic));
    // Plain text mentioning images is just text.
    const prose = "{\"content\":\"an image of a document: file it\"}";
    try std.testing.expectEqual(@as(u64, prose.len / 4), estimateInput(prose));
    try std.testing.expectEqual(@as(u64, 0), estimateInput(""));
}
