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
