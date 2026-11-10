//! Config snapshot pushed by the Elixir control plane.
//!
//! The data plane never sees provider secrets in this document: each upstream
//! names an environment variable (`api_key_env`) that is read locally. Gateway
//! keys arrive only as SHA-256 hex digests.

const std = @import("std");
const Io = std.Io;

pub const Kind = enum { openai, anthropic };

pub const Upstream = struct {
    name: []const u8,
    kind: Kind,
    base_url: []const u8,
    api_key_env: []const u8,
    /// Max time to wait for response headers; 0 uses the gateway default.
    timeout_ms: u32 = 0,
    /// Where this provider serves the API if not under `/v1`: the leading
    /// `/v1` of the client's path is replaced by this. Gemini's
    /// OpenAI-compatible endpoint, for example, is `/v1beta/openai`.
    v1_path: ?[]const u8 = null,
};

/// The client's path as an upstream spells it.
pub fn upstreamPath(arena: std.mem.Allocator, v1_path: ?[]const u8, path: []const u8) ![]const u8 {
    const prefix = v1_path orelse return path;
    if (!std.mem.startsWith(u8, path, "/v1/")) return path;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ std.mem.trimEnd(u8, prefix, "/"), path["/v1".len..] });
}

test "upstreamPath replaces only a leading /v1" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("/v1/chat/completions", try upstreamPath(arena, null, "/v1/chat/completions"));
    try std.testing.expectEqualStrings("/v1beta/openai/chat/completions", try upstreamPath(arena, "/v1beta/openai", "/v1/chat/completions"));
    try std.testing.expectEqualStrings("/v1beta/openai/embeddings", try upstreamPath(arena, "/v1beta/openai/", "/v1/embeddings"));
    // A provider with the API at its root.
    try std.testing.expectEqualStrings("/chat/completions", try upstreamPath(arena, "", "/v1/chat/completions"));
    try std.testing.expectEqualStrings("/healthz", try upstreamPath(arena, "/x", "/healthz"));
}

pub const Target = struct {
    upstream: []const u8,
    model: []const u8,
    /// Share of first attempts under the `weighted` strategy. 0 means never
    /// first, but still used as a fallback. Other strategies ignore it.
    weight: u32 = 1,
};

pub const Route = struct {
    model: []const u8,
    targets: []const Target,
    /// "failover" (default), "round_robin" or "weighted"; see balance.zig.
    /// Kept as text so that a name this build does not know degrades to
    /// failover instead of making the whole snapshot unparseable.
    strategy: ?[]const u8 = null,
    /// Seconds a successful non-streaming answer may be reused for an
    /// identical request from the same key; 0 = no caching. See cache.zig.
    cache_ttl_s: u32 = 0,
};

pub const Key = struct {
    key_sha256: []const u8,
    name: []const u8,
    blocked: bool = false,
    /// Requests per minute; 0 means unlimited.
    rpm: u32 = 0,
    /// Route models this key may use; null means all of them.
    models: ?[]const []const u8 = null,

    pub fn allows(key: *const Key, route_model: []const u8) bool {
        const allowed = key.models orelse return true;
        for (allowed) |m| if (std.mem.eql(u8, m, route_model)) return true;
        return false;
    }
};

test "key model limits: null allows everything, a list only its members" {
    const open: Key = .{ .key_sha256 = "h", .name = "open" };
    try std.testing.expect(open.allows("anything"));

    const limited: Key = .{ .key_sha256 = "h", .name = "limited", .models = &.{ "chat", "claude" } };
    try std.testing.expect(limited.allows("chat"));
    try std.testing.expect(limited.allows("claude"));
    try std.testing.expect(!limited.allows("Chat"));
    try std.testing.expect(!limited.allows("chat-2"));

    // An empty list is a key that may use no model at all.
    const none: Key = .{ .key_sha256 = "h", .name = "none", .models = &.{} };
    try std.testing.expect(!none.allows("chat"));
}

test "snapshots parse with and without the newer optional fields" {
    const gpa = std.testing.allocator;

    var old = try parse(gpa,
        \\{"version":"v1","keys":[{"key_sha256":"aa","name":"k"}],
        \\ "upstreams":[{"name":"u","kind":"openai","base_url":"http://x","api_key_env":"K"}],
        \\ "routes":[{"model":"m","targets":[{"upstream":"u","model":"real"}]}]}
    );
    defer old.deinit();
    try std.testing.expectEqual(@as(?[]const []const u8, null), old.value.keys[0].models);
    try std.testing.expectEqual(@as(?[]const u8, null), old.value.routes[0].strategy);
    try std.testing.expectEqual(@as(u32, 1), old.value.routes[0].targets[0].weight);
    try std.testing.expectEqual(@as(u32, 0), old.value.routes[0].cache_ttl_s);
    try std.testing.expectEqual(@as(?[]const []const u8, null), old.value.media_models);

    var new = try parse(gpa,
        \\{"version":"v2","keys":[{"key_sha256":"aa","name":"k","models":["m"]},{"key_sha256":"bb","name":"all","models":null}],
        \\ "upstreams":[{"name":"u","kind":"openai","base_url":"http://x","api_key_env":"K"}],
        \\ "routes":[{"model":"m","strategy":"weighted","targets":[{"upstream":"u","model":"a","weight":3},{"upstream":"u","model":"b","weight":0}]},
        \\           {"model":"n","strategy":"something_new","targets":[]}]}
    );
    defer new.deinit();
    try std.testing.expect(new.value.keys[0].allows("m") and !new.value.keys[0].allows("n"));
    try std.testing.expect(new.value.keys[1].allows("n"));
    try std.testing.expectEqualStrings("weighted", new.value.routes[0].strategy.?);
    try std.testing.expectEqual(@as(u32, 3), new.value.routes[0].targets[0].weight);
    try std.testing.expectEqual(@as(u32, 0), new.value.routes[0].targets[1].weight);
    try std.testing.expectEqualStrings("something_new", new.value.routes[1].strategy.?);

    var newer = try parse(gpa,
        \\{"version":"v3","keys":[],"upstreams":[],"media_models":["image","video"],
        \\ "routes":[{"model":"m","cache_ttl_s":600,"targets":[]}]}
    );
    defer newer.deinit();
    try std.testing.expectEqual(@as(u32, 600), newer.value.routes[0].cache_ttl_s);
    try std.testing.expectEqual(@as(usize, 2), newer.value.media_models.?.len);
    try std.testing.expectEqualStrings("video", newer.value.media_models.?[1]);
}

pub const Snapshot = struct {
    version: []const u8,
    keys: []const Key,
    upstreams: []const Upstream,
    routes: []const Route,
    /// Names of the media job models the control plane serves. The data plane
    /// does not route them; it only lists them in `GET /v1/models`.
    media_models: ?[]const []const u8 = null,

    pub fn findRoute(s: *const Snapshot, model: []const u8) ?*const Route {
        for (s.routes) |*r| if (std.mem.eql(u8, r.model, model)) return r;
        return null;
    }

    pub fn findUpstream(s: *const Snapshot, name: []const u8) ?*const Upstream {
        for (s.upstreams) |*u| if (std.mem.eql(u8, u.name, name)) return u;
        return null;
    }

    pub fn findKey(s: *const Snapshot, sha256_hex: []const u8) ?*const Key {
        for (s.keys) |*k| if (std.mem.eql(u8, k.key_sha256, sha256_hex)) return k;
        return null;
    }
};

pub const Parsed = std.json.Parsed(Snapshot);

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Parsed {
    return std.json.parseFromSlice(Snapshot, gpa, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Holds the active snapshot. Snapshots are immutable once installed; old ones
/// are retired (kept alive) because in-flight requests may still point at them.
/// They are reclaimed at shutdown. Config changes are rare, so this is cheap.
pub const Store = struct {
    mutex: Io.Mutex = .init,
    current: ?*Parsed = null,
    retired: std.ArrayList(*Parsed) = .empty,

    pub fn get(store: *Store, io: Io) ?*const Snapshot {
        store.mutex.lockUncancelable(io);
        defer store.mutex.unlock(io);
        const p = store.current orelse return null;
        return &p.value;
    }

    pub fn currentVersion(store: *Store, io: Io) ?[]const u8 {
        const snap = store.get(io) orelse return null;
        return snap.version;
    }

    /// Takes ownership of `parsed` (heap-allocated with `gpa`).
    pub fn install(store: *Store, io: Io, gpa: std.mem.Allocator, parsed: *Parsed) !void {
        store.mutex.lockUncancelable(io);
        defer store.mutex.unlock(io);
        if (store.current) |old| try store.retired.append(gpa, old);
        store.current = parsed;
    }

    pub fn deinit(store: *Store, gpa: std.mem.Allocator) void {
        for (store.retired.items) |p| {
            p.deinit();
            gpa.destroy(p);
        }
        store.retired.deinit(gpa);
        if (store.current) |p| {
            p.deinit();
            gpa.destroy(p);
        }
    }
};

/// Lowercase hex SHA-256, matching Elixir's `Base.encode16(hash, case: :lower)`.
pub fn sha256Hex(input: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "parse snapshot and lookups" {
    const json =
        \\{"version":"v1","keys":[{"key_sha256":"abc","name":"dev","blocked":false}],
        \\ "upstreams":[{"name":"a","kind":"openai","base_url":"http://x","api_key_env":"K"}],
        \\ "routes":[{"model":"m","targets":[{"upstream":"a","model":"real-m"}]}],
        \\ "extra":"ignored"}
    ;
    var parsed = try parse(std.testing.allocator, json);
    defer parsed.deinit();
    const s = &parsed.value;
    try std.testing.expect(s.findRoute("m") != null);
    try std.testing.expect(s.findRoute("nope") == null);
    try std.testing.expectEqual(Kind.openai, s.findUpstream("a").?.kind);
    try std.testing.expect(s.findKey("abc") != null);
}

test "sha256 hex" {
    const h = sha256Hex("abc");
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &h,
    );
}
