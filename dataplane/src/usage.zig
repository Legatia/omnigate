//! Streaming token-usage extractor.
//!
//! Scans response bytes as they flow through the proxy (JSON or SSE, OpenAI or
//! Anthropic shape) without buffering or parsing the whole body. Keys may be
//! split across network chunks, so a small tail of the previous chunk is kept.
//! Values are max-merged: Anthropic reports cumulative `output_tokens` in
//! `message_delta`, OpenAI reports one final `usage` object.

const std = @import("std");

const Field = enum { input, output };

const Pattern = struct { needle: []const u8, field: Field };

const patterns = [_]Pattern{
    .{ .needle = "\"prompt_tokens\":", .field = .input },
    .{ .needle = "\"input_tokens\":", .field = .input },
    .{ .needle = "\"completion_tokens\":", .field = .output },
    .{ .needle = "\"output_tokens\":", .field = .output },
};

const tail_cap = 48;

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    tail: [tail_cap]u8 = undefined,
    tail_len: usize = 0,

    pub fn feed(u: *Usage, chunk: []const u8) void {
        if (chunk.len == 0) return;

        // Region spanning the previous tail and the start of this chunk.
        if (u.tail_len > 0) {
            var joined: [tail_cap * 2]u8 = undefined;
            const head_len = @min(chunk.len, tail_cap);
            @memcpy(joined[0..u.tail_len], u.tail[0..u.tail_len]);
            @memcpy(joined[u.tail_len..][0..head_len], chunk[0..head_len]);
            u.scan(joined[0 .. u.tail_len + head_len]);
        }
        u.scan(chunk);

        // Keep the last `tail_cap` bytes of (tail ++ chunk).
        if (chunk.len >= tail_cap) {
            @memcpy(u.tail[0..tail_cap], chunk[chunk.len - tail_cap ..]);
            u.tail_len = tail_cap;
        } else {
            const keep_old = @min(u.tail_len, tail_cap - chunk.len);
            std.mem.copyForwards(u8, u.tail[0..keep_old], u.tail[u.tail_len - keep_old .. u.tail_len]);
            @memcpy(u.tail[keep_old..][0..chunk.len], chunk);
            u.tail_len = keep_old + chunk.len;
        }
    }

    fn scan(u: *Usage, buf: []const u8) void {
        for (patterns) |p| {
            var pos: usize = 0;
            while (std.mem.findPos(u8, buf, pos, p.needle)) |idx| {
                pos = idx + p.needle.len;
                var i = pos;
                while (i < buf.len and (buf[i] == ' ' or buf[i] == '\t')) i += 1;
                const start = i;
                while (i < buf.len and std.ascii.isDigit(buf[i])) i += 1;
                // A number that runs to the end of the buffer may be truncated;
                // it will be seen whole in the joined region next time.
                if (i == start) continue;
                const n = std.fmt.parseInt(u64, buf[start..i], 10) catch continue;
                switch (p.field) {
                    .input => u.input_tokens = @max(u.input_tokens, n),
                    .output => u.output_tokens = @max(u.output_tokens, n),
                }
            }
        }
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

    /// An event this large is not a usage chunk; stop holding bytes back.
    const max_pending = 1024 * 1024;

    pub fn deinit(f: *UsageChunkFilter, gpa: std.mem.Allocator) void {
        f.pending.deinit(gpa);
    }

    pub fn feed(f: *UsageChunkFilter, gpa: std.mem.Allocator, chunk: []const u8, out: *std.Io.Writer) !void {
        try f.pending.appendSlice(gpa, chunk);
        var start: usize = 0;
        while (eventEnd(f.pending.items[start..])) |len| {
            const event = f.pending.items[start .. start + len];
            if (!isUsageOnly(event)) try out.writeAll(event);
            start += len;
        }
        if (f.pending.items.len - start > max_pending) {
            try out.writeAll(f.pending.items[start..]);
            start = f.pending.items.len;
        }
        const rest = f.pending.items.len - start;
        std.mem.copyForwards(u8, f.pending.items[0..rest], f.pending.items[start..]);
        f.pending.shrinkRetainingCapacity(rest);
    }

    /// The upstream ended: pass on whatever is left.
    pub fn finish(f: *UsageChunkFilter, out: *std.Io.Writer) !void {
        if (f.pending.items.len > 0 and !isUsageOnly(f.pending.items)) try out.writeAll(f.pending.items);
        f.pending.clearRetainingCapacity();
    }

    /// Length of the first complete SSE event (through its blank line).
    fn eventEnd(bytes: []const u8) ?usize {
        const lf = std.mem.find(u8, bytes, "\n\n");
        const crlf = std.mem.find(u8, bytes, "\r\n\r\n");
        if (lf) |a| {
            if (crlf) |b| return if (b < a) b + 4 else a + 2;
            return a + 2;
        }
        return if (crlf) |b| b + 4 else null;
    }

    fn isUsageOnly(event: []const u8) bool {
        // Inside a JSON string these quotes would be escaped, so a plain match
        // can only be the chunk's own keys.
        if (std.mem.find(u8, event, "\"usage\"") == null) return false;
        return std.mem.find(u8, event, "\"choices\":[]") != null or
            std.mem.find(u8, event, "\"choices\": []") != null;
    }
};

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
