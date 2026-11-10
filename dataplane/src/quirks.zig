//! What the gateway has learned about individual upstream models.
//!
//! Two things so far, both about requests the gateway translated, where the
//! client speaks the other protocol and cannot be expected to know the rule:
//!
//!   * The model rejects sampling parameters (`temperature`, `top_p`,
//!     `top_k`). Current Claude models and OpenAI's reasoning models answer
//!     400 when they are set. The proxy retries without them.
//!   * The model insists on a "thought signature" on earlier tool calls
//!     (Gemini 3 and later, through Google's OpenAI-compatible API). An
//!     Anthropic-style client has nowhere to carry one, so the proxy retries
//!     with the placeholder Google documents for calls it did not sign.
//!
//! Either way it is recorded here, so later requests skip the failed round
//! trip.
//!
//! In memory only; relearned after a restart at the cost of one extra request
//! per model.

const std = @import("std");
const Io = std.Io;

pub const sampling_params = [_][]const u8{ "temperature", "top_p", "top_k" };

pub const Quirks = struct {
    mutex: Io.Mutex = .init,
    /// Keys are owned "<quirk>\n<upstream>\n<model>" strings.
    learned: std.StringHashMapUnmanaged(void) = .empty,

    const Quirk = enum { no_sampling, thought_signature };

    pub fn deinit(q: *Quirks, gpa: std.mem.Allocator) void {
        var it = q.learned.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        q.learned.deinit(gpa);
    }

    pub fn rejectsSampling(q: *Quirks, io: Io, upstream: []const u8, model: []const u8) bool {
        return q.has(io, .no_sampling, upstream, model);
    }

    pub fn noteRejectsSampling(q: *Quirks, gpa: std.mem.Allocator, io: Io, upstream: []const u8, model: []const u8) void {
        q.note(gpa, io, .no_sampling, upstream, model);
    }

    pub fn needsThoughtSignature(q: *Quirks, io: Io, upstream: []const u8, model: []const u8) bool {
        return q.has(io, .thought_signature, upstream, model);
    }

    pub fn noteNeedsThoughtSignature(q: *Quirks, gpa: std.mem.Allocator, io: Io, upstream: []const u8, model: []const u8) void {
        q.note(gpa, io, .thought_signature, upstream, model);
    }

    fn has(q: *Quirks, io: Io, quirk: Quirk, upstream: []const u8, model: []const u8) bool {
        var buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{t}\n{s}\n{s}", .{ quirk, upstream, model }) catch return false;
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        return q.learned.contains(key);
    }

    fn note(q: *Quirks, gpa: std.mem.Allocator, io: Io, quirk: Quirk, upstream: []const u8, model: []const u8) void {
        const key = std.fmt.allocPrint(gpa, "{t}\n{s}\n{s}", .{ quirk, upstream, model }) catch return;
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        if (q.learned.contains(key)) return gpa.free(key);
        q.learned.put(gpa, key, {}) catch gpa.free(key);
    }
};

/// Google's documented stand-in for tool calls that carry no signature of
/// their own (history written by another model or another client).
pub const placeholder_thought_signature = "skip_thought_signature_validator";

/// Does a provider's 400 body ask for thought signatures?
pub fn mentionsThoughtSignature(error_body: []const u8) bool {
    return std.mem.find(u8, error_body, "thought_signature") != null;
}

/// An OpenAI-style request with the placeholder signature on every assistant
/// tool call that has none. Returns null when nothing needed adding.
pub fn addThoughtSignatures(arena: std.mem.Allocator, body: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    if (parsed.value != .object) return null;
    const messages = parsed.value.object.getPtr("messages") orelse return null;
    if (messages.* != .array) return null;

    var added = false;
    for (messages.array.items) |*message| {
        if (message.* != .object) continue;
        const calls = message.object.getPtr("tool_calls") orelse continue;
        if (calls.* != .array) continue;
        for (calls.array.items) |*tool_call| {
            if (tool_call.* != .object or tool_call.object.contains("extra_content")) continue;
            var google: std.json.ObjectMap = .empty;
            try google.put(arena, "thought_signature", .{ .string = placeholder_thought_signature });
            var extra: std.json.ObjectMap = .empty;
            try extra.put(arena, "google", .{ .object = google });
            try tool_call.object.put(arena, "extra_content", .{ .object = extra });
            added = true;
        }
    }
    if (!added) return null;
    return try std.json.Stringify.valueAlloc(arena, parsed.value, .{});
}

/// Does a provider's 400 body complain about a sampling parameter?
pub fn mentionsSampling(error_body: []const u8) bool {
    for (sampling_params) |name| {
        if (std.mem.find(u8, error_body, name) != null) return true;
    }
    return false;
}

/// The same JSON request without sampling parameters. Returns null when
/// there were none to remove (retrying would change nothing).
pub fn stripSampling(arena: std.mem.Allocator, body: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    if (parsed.value != .object) return null;
    var removed = false;
    for (sampling_params) |name| {
        if (parsed.value.object.orderedRemove(name)) removed = true;
    }
    if (!removed) return null;
    return try std.json.Stringify.valueAlloc(arena, parsed.value, .{});
}

test "strips only sampling parameters" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = (try stripSampling(arena,
        \\{"model":"m","temperature":0.2,"max_tokens":5,"top_p":0.9,"messages":[{"role":"user","content":"temperature"}]}
    )).?;
    try std.testing.expectEqualStrings(
        \\{"model":"m","max_tokens":5,"messages":[{"role":"user","content":"temperature"}]}
    , out);

    try std.testing.expectEqual(@as(?[]u8, null), try stripSampling(arena, "{\"model\":\"m\"}"));
}

test "recognises provider complaints about sampling parameters" {
    try std.testing.expect(mentionsSampling("{\"error\":{\"message\":\"`temperature` is deprecated for this model.\"}}"));
    try std.testing.expect(mentionsSampling("Unsupported parameter: 'top_p' is not supported with this model."));
    try std.testing.expect(!mentionsSampling("{\"error\":{\"message\":\"max_tokens is too large\"}}"));
}

test "adds a placeholder signature to unsigned tool calls only" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = (try addThoughtSignatures(arena,
        \\{"model":"m","messages":[{"role":"user","content":"hi"},{"role":"assistant","tool_calls":[{"id":"a","type":"function","function":{"name":"f","arguments":"{}"}},{"id":"b","extra_content":{"google":{"thought_signature":"real"}}}]},{"role":"tool","tool_call_id":"a","content":"1"}]}
    )).?;
    try std.testing.expect(std.mem.find(u8, out, "\"id\":\"a\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"},\"extra_content\":{\"google\":{\"thought_signature\":\"skip_thought_signature_validator\"}}") != null);
    // A call that already has a signature keeps it.
    try std.testing.expect(std.mem.find(u8, out, "\"thought_signature\":\"real\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, placeholder_thought_signature));

    try std.testing.expectEqual(@as(?[]u8, null), try addThoughtSignatures(arena, "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"));
    try std.testing.expect(mentionsThoughtSignature("Function call is missing a thought_signature in functionCall parts."));
}

test "remembers per upstream and model" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var q: Quirks = .{};
    defer q.deinit(gpa);

    try std.testing.expect(!q.rejectsSampling(io, "anthropic", "claude-x"));
    q.noteRejectsSampling(gpa, io, "anthropic", "claude-x");
    q.noteRejectsSampling(gpa, io, "anthropic", "claude-x");
    try std.testing.expect(q.rejectsSampling(io, "anthropic", "claude-x"));
    try std.testing.expect(!q.rejectsSampling(io, "anthropic", "claude-y"));
    try std.testing.expect(!q.rejectsSampling(io, "other", "claude-x"));

    // Different quirks of the same model are independent.
    try std.testing.expect(!q.needsThoughtSignature(io, "anthropic", "claude-x"));
    q.noteNeedsThoughtSignature(gpa, io, "google", "gemini-x");
    try std.testing.expect(q.needsThoughtSignature(io, "google", "gemini-x"));
    try std.testing.expect(!q.rejectsSampling(io, "google", "gemini-x"));
}
