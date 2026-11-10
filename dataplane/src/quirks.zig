//! What the gateway has learned about individual upstream models.
//!
//! Today that is one thing: whether a model rejects sampling parameters
//! (`temperature`, `top_p`, `top_k`). Current Claude models and OpenAI's
//! reasoning models answer 400 when they are set, and a client speaking the
//! *other* protocol cannot be expected to know that. When a translated
//! request is rejected for that reason the proxy retries without them and
//! records it here, so later requests skip the failed round trip.
//!
//! In memory only; relearned after a restart at the cost of one extra request
//! per model.

const std = @import("std");
const Io = std.Io;

pub const sampling_params = [_][]const u8{ "temperature", "top_p", "top_k" };

pub const Quirks = struct {
    mutex: Io.Mutex = .init,
    /// Keys are owned "upstream\nmodel" strings.
    no_sampling: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(q: *Quirks, gpa: std.mem.Allocator) void {
        var it = q.no_sampling.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        q.no_sampling.deinit(gpa);
    }

    pub fn rejectsSampling(q: *Quirks, io: Io, upstream: []const u8, model: []const u8) bool {
        var buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}\n{s}", .{ upstream, model }) catch return false;
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        return q.no_sampling.contains(key);
    }

    pub fn noteRejectsSampling(q: *Quirks, gpa: std.mem.Allocator, io: Io, upstream: []const u8, model: []const u8) void {
        const key = std.fmt.allocPrint(gpa, "{s}\n{s}", .{ upstream, model }) catch return;
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        if (q.no_sampling.contains(key)) return gpa.free(key);
        q.no_sampling.put(gpa, key, {}) catch gpa.free(key);
    }
};

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
}
