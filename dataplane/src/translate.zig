//! OpenAI chat completions <-> Anthropic messages translation.
//!
//! Pure functions over bytes: no network, no clock, no project imports. The
//! proxy calls these when a route's target speaks a different protocol than
//! the client:
//!
//!   translateRequest   client request body      -> upstream request body
//!   translateResponse  upstream response body   -> client response body
//!   StreamTranslator   upstream SSE byte stream -> client SSE byte stream
//!
//! Anything with no equivalent on the other side (penalties, logprobs, top_k,
//! thinking blocks, ...) is dropped rather than rejected. Content that cannot
//! be represented at all (audio parts, documents) is `error.Untranslatable`.

const std = @import("std");
const guard = @import("guard.zig");
const limits = @import("limits.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const json = std.json;
const Value = json.Value;
const ObjectMap = json.ObjectMap;
const Array = json.Array;

/// Anthropic requires `max_tokens`; used when an OpenAI client omits it.
const default_max_tokens = 4096;
/// Stands in for OpenAI's `response_format: {"type":"json_object"}`, which
/// Anthropic has no parameter for.
const json_object_instruction = "Respond with a single valid JSON object and nothing else: no prose, no code fences.";
/// Upper bound on one buffered SSE line / event.
const max_event_bytes = 4 * 1024 * 1024;
/// Upper bound on the memory for parsing one event into a tree. Real events
/// are a few hundred bytes; an upstream that sends megabytes of tiny values
/// in one event ends its stream instead of taking gigabytes.
const max_event_tree_bytes = 32 * 1024 * 1024;
/// Parse memory kept between events (the rest is returned after each).
const event_tree_retained_bytes = 256 * 1024;

pub const Direction = enum {
    /// Client speaks OpenAI chat completions; upstream is Anthropic messages.
    openai_to_anthropic,
    /// Client speaks Anthropic messages; upstream is OpenAI chat completions.
    anthropic_to_openai,
};

// ---------------------------------------------------------------------------
// Small JSON helpers
// ---------------------------------------------------------------------------

fn S(s: []const u8) Value {
    return .{ .string = s };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn getStr(o: ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getObj(o: ObjectMap, key: []const u8) ?ObjectMap {
    const v = o.get(key) orelse return null;
    return if (v == .object) v.object else null;
}

fn getArr(o: ObjectMap, key: []const u8) ?[]const Value {
    const v = o.get(key) orelse return null;
    return if (v == .array) v.array.items else null;
}

fn getBool(o: ObjectMap, key: []const u8) ?bool {
    const v = o.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn getInt(o: ObjectMap, key: []const u8) ?i64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e15) @intFromFloat(f) else null,
        else => null,
    };
}

/// A token count from a provider: never negative, and capped so that sums of
/// several of them, and the casts back to JSON integers, cannot overflow.
fn getCount(o: ObjectMap, key: []const u8) u64 {
    const i = getInt(o, key) orelse return 0;
    return if (i < 0) 0 else @min(@as(u64, @intCast(i)), max_token_count);
}

const max_token_count: u64 = 1 << 40;

fn isNumber(v: Value) bool {
    return v == .integer or v == .float or v == .number_string;
}

fn parseObject(a: Allocator, body: []const u8) error{ OutOfMemory, InvalidJson }!ObjectMap {
    // Everything parsed here is serialised again, and the serialiser indexes
    // past a fixed stack on values nested deeper than 256.
    if (!guard.jsonDepthOk(body, guard.max_upstream_json_depth)) return error.InvalidJson;
    // ... and the tree it is parsed into keeps each object in a hash map
    // with a fixed seed: keys chosen to collide cost the square of their
    // number, so that number is bounded first.
    if (!guard.jsonMembersOk(body, guard.max_tree_members)) return error.InvalidJson;
    const v = json.parseFromSliceLeaky(Value, a, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (v != .object) return error.InvalidJson;
    return v.object;
}

fn textBlock(a: Allocator, text: []const u8) !Value {
    var o: ObjectMap = .empty;
    try o.put(a, "type", S("text"));
    try o.put(a, "text", S(text));
    return .{ .object = o };
}

/// Text of a `content` value: a string, or the `text` parts of an array
/// (same `{"type":"text","text":...}` shape in both protocols).
fn joinText(a: Allocator, content: Value, sep: []const u8) ![]const u8 {
    switch (content) {
        .string => |s| return s,
        .array => |arr| {
            var buf: std.ArrayList(u8) = .empty;
            for (arr.items) |part| {
                const text = switch (part) {
                    .string => |s| s,
                    .object => |po| blk: {
                        const ty = getStr(po, "type") orelse "text";
                        if (!eql(ty, "text")) continue;
                        break :blk getStr(po, "text") orelse continue;
                    },
                    else => continue,
                };
                if (text.len == 0) continue;
                if (buf.items.len > 0) try buf.appendSlice(a, sep);
                try buf.appendSlice(a, text);
            }
            return buf.items;
        },
        else => return "",
    }
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

/// Client request body -> upstream request body, with "model" set to
/// `target_model`. `error.Untranslatable` when the request uses something that
/// cannot be represented; `error.InvalidJson` when it is not a JSON object.
pub fn translateRequest(arena: Allocator, dir: Direction, client_body: []const u8, target_model: []const u8) ![]u8 {
    const req = try parseObject(arena, client_body);
    const out = switch (dir) {
        .openai_to_anthropic => try requestOpenAiToAnthropic(arena, req, target_model),
        .anthropic_to_openai => try requestAnthropicToOpenAi(arena, req, target_model),
    };
    return json.Stringify.valueAlloc(arena, Value{ .object = out }, .{});
}

/// Anthropic turns under construction. Consecutive messages that map to the
/// same role are merged, so tool results land in one user turn.
const Turns = struct {
    a: Allocator,
    list: std.ArrayList(Turn) = .empty,

    const Turn = struct { role: []const u8, blocks: Array };

    /// Block list of the current turn for `role`, starting a new turn if the
    /// last one has a different role. Valid until the next call.
    fn turn(t: *Turns, role: []const u8) !*Array {
        if (t.list.items.len > 0) {
            const last = &t.list.items[t.list.items.len - 1];
            if (eql(last.role, role)) return &last.blocks;
        }
        try t.list.append(t.a, .{ .role = role, .blocks = Array.init(t.a) });
        return &t.list.items[t.list.items.len - 1].blocks;
    }

    fn toValue(t: *Turns) !Value {
        var arr = Array.init(t.a);
        for (t.list.items) |tn| {
            // Anthropic rejects turns with empty content.
            if (tn.blocks.items.len == 0) continue;
            var o: ObjectMap = .empty;
            try o.put(t.a, "role", S(tn.role));
            const only = tn.blocks.items[0];
            if (tn.blocks.items.len == 1 and eql(getStr(only.object, "type") orelse "", "text")) {
                try o.put(t.a, "content", S(getStr(only.object, "text") orelse ""));
            } else {
                try o.put(t.a, "content", .{ .array = tn.blocks });
            }
            try arr.append(.{ .object = o });
        }
        return .{ .array = arr };
    }
};

fn requestOpenAiToAnthropic(a: Allocator, req: ObjectMap, target_model: []const u8) !ObjectMap {
    var out: ObjectMap = .empty;
    try out.put(a, "model", S(target_model));

    const max_tokens: Value = blk: {
        if (req.get("max_completion_tokens")) |v| if (v == .integer) break :blk v;
        if (req.get("max_tokens")) |v| if (v == .integer) break :blk v;
        break :blk .{ .integer = default_max_tokens };
    };
    try out.put(a, "max_tokens", max_tokens);

    var system: std.ArrayList(u8) = .empty;
    var turns: Turns = .{ .a = a };

    const messages = getArr(req, "messages") orelse return error.Untranslatable;
    for (messages) |m| {
        if (m != .object) return error.Untranslatable;
        const role = getStr(m.object, "role") orelse return error.Untranslatable;
        const content: Value = m.object.get("content") orelse .null;

        if (eql(role, "system") or eql(role, "developer")) {
            const text = try joinText(a, content, "\n");
            if (text.len == 0) continue;
            if (system.items.len > 0) try system.appendSlice(a, "\n\n");
            try system.appendSlice(a, text);
        } else if (eql(role, "user")) {
            try openAiPartsToBlocks(a, content, try turns.turn("user"));
        } else if (eql(role, "assistant")) {
            const blocks = try turns.turn("assistant");
            try openAiPartsToBlocks(a, content, blocks);
            if (getArr(m.object, "tool_calls")) |calls| {
                for (calls) |c| {
                    if (c != .object) continue;
                    const f = getObj(c.object, "function") orelse continue;
                    var b: ObjectMap = .empty;
                    try b.put(a, "type", S("tool_use"));
                    try b.put(a, "id", S(getStr(c.object, "id") orelse return error.Untranslatable));
                    try b.put(a, "name", S(getStr(f, "name") orelse return error.Untranslatable));
                    try b.put(a, "input", try parseToolInput(a, getStr(f, "arguments") orelse ""));
                    try blocks.append(.{ .object = b });
                }
            }
        } else if (eql(role, "tool")) {
            var b: ObjectMap = .empty;
            try b.put(a, "type", S("tool_result"));
            try b.put(a, "tool_use_id", S(getStr(m.object, "tool_call_id") orelse return error.Untranslatable));
            try b.put(a, "content", S(try joinText(a, content, "\n")));
            try (try turns.turn("user")).append(.{ .object = b });
        } else {
            // Legacy `function` role and anything newer we do not know.
            return error.Untranslatable;
        }
    }

    // Structured output. A JSON schema maps onto Anthropic's structured
    // outputs; plain "JSON mode" has no equivalent there, so it becomes an
    // instruction.
    if (getObj(req, "response_format")) |rf| {
        const kind = getStr(rf, "type") orelse "";
        if (eql(kind, "json_schema")) {
            if (getObj(rf, "json_schema")) |js| if (js.get("schema")) |schema| if (schema == .object) {
                var format: ObjectMap = .empty;
                try format.put(a, "type", S("json_schema"));
                try format.put(a, "schema", schema);
                var output_config: ObjectMap = .empty;
                try output_config.put(a, "format", .{ .object = format });
                try out.put(a, "output_config", .{ .object = output_config });
            };
        } else if (eql(kind, "json_object")) {
            if (system.items.len > 0) try system.appendSlice(a, "\n\n");
            try system.appendSlice(a, json_object_instruction);
        }
    }

    if (system.items.len > 0) try out.put(a, "system", S(system.items));
    try out.put(a, "messages", try turns.toValue());

    if (req.get("temperature")) |v| {
        // OpenAI allows 0..2, Anthropic 0..1.
        const clamped: Value = switch (v) {
            .integer => |i| .{ .integer = std.math.clamp(i, 0, 1) },
            .float => |f| .{ .float = std.math.clamp(f, 0.0, 1.0) },
            else => .null,
        };
        if (clamped != .null) try out.put(a, "temperature", clamped);
    }
    if (req.get("top_p")) |v| if (isNumber(v)) try out.put(a, "top_p", v);
    if (req.get("stop")) |v| switch (v) {
        .string => |s| {
            var arr = Array.init(a);
            try arr.append(S(s));
            try out.put(a, "stop_sequences", .{ .array = arr });
        },
        .array => |arr| if (arr.items.len > 0) try out.put(a, "stop_sequences", v),
        else => {},
    };
    if (getBool(req, "stream")) |s| try out.put(a, "stream", .{ .bool = s });
    if (getStr(req, "user")) |u| {
        var meta: ObjectMap = .empty;
        try meta.put(a, "user_id", S(u));
        try out.put(a, "metadata", .{ .object = meta });
    }

    // --- tools ---
    var tools = Array.init(a);
    if (getArr(req, "tools")) |list| {
        for (list) |t| {
            if (t != .object) continue;
            if (!eql(getStr(t.object, "type") orelse "function", "function")) continue;
            const f = getObj(t.object, "function") orelse continue;
            const name = getStr(f, "name") orelse continue;
            var o: ObjectMap = .empty;
            try o.put(a, "name", S(name));
            if (getStr(f, "description")) |d| try o.put(a, "description", S(d));
            if (getObj(f, "parameters")) |p| {
                try o.put(a, "input_schema", .{ .object = p });
            } else {
                var schema: ObjectMap = .empty;
                try schema.put(a, "type", S("object"));
                try schema.put(a, "properties", .{ .object = .empty });
                try o.put(a, "input_schema", .{ .object = schema });
            }
            try tools.append(.{ .object = o });
        }
    }
    if (tools.items.len > 0) {
        try out.put(a, "tools", .{ .array = tools });

        var choice: ObjectMap = .empty;
        if (req.get("tool_choice")) |tc| switch (tc) {
            .string => |s| {
                if (eql(s, "auto")) try choice.put(a, "type", S("auto"));
                if (eql(s, "none")) try choice.put(a, "type", S("none"));
                if (eql(s, "required")) try choice.put(a, "type", S("any"));
            },
            .object => |tco| {
                if (getObj(tco, "function")) |f| if (getStr(f, "name")) |name| {
                    try choice.put(a, "type", S("tool"));
                    try choice.put(a, "name", S(name));
                };
            },
            else => {},
        };
        if (getBool(req, "parallel_tool_calls")) |p| if (!p) {
            if (choice.count() == 0) try choice.put(a, "type", S("auto"));
            if (!eql(getStr(choice, "type").?, "none")) try choice.put(a, "disable_parallel_tool_use", .{ .bool = true });
        };
        if (choice.count() > 0) try out.put(a, "tool_choice", .{ .object = choice });
    }

    return out;
}

/// OpenAI message content (string, null, or parts array) -> Anthropic blocks.
fn openAiPartsToBlocks(a: Allocator, content: Value, blocks: *Array) !void {
    switch (content) {
        .null => {},
        .string => |s| if (s.len > 0) try blocks.append(try textBlock(a, s)),
        .array => |parts| for (parts.items) |part| {
            if (part != .object) return error.Untranslatable;
            const ty = getStr(part.object, "type") orelse return error.Untranslatable;
            if (eql(ty, "text")) {
                const text = getStr(part.object, "text") orelse "";
                if (text.len > 0) try blocks.append(try textBlock(a, text));
            } else if (eql(ty, "refusal")) {
                const text = getStr(part.object, "refusal") orelse "";
                if (text.len > 0) try blocks.append(try textBlock(a, text));
            } else if (eql(ty, "image_url")) {
                const url = switch (part.object.get("image_url") orelse return error.Untranslatable) {
                    .string => |s| s,
                    .object => |io| getStr(io, "url") orelse return error.Untranslatable,
                    else => return error.Untranslatable,
                };
                try blocks.append(try imageBlockFromUrl(a, url));
            } else {
                // input_audio, file, ...
                return error.Untranslatable;
            }
        },
        else => return error.Untranslatable,
    }
}

fn imageBlockFromUrl(a: Allocator, url: []const u8) !Value {
    var source: ObjectMap = .empty;
    if (std.mem.cutPrefix(u8, url, "data:")) |rest| {
        // data:<media type>;base64,<data>
        const comma = std.mem.findScalar(u8, rest, ',') orelse return error.Untranslatable;
        const meta = rest[0..comma];
        const b64_marker = ";base64";
        if (!std.ascii.endsWithIgnoreCase(meta, b64_marker)) return error.Untranslatable;
        const media = meta[0 .. meta.len - b64_marker.len];
        try source.put(a, "type", S("base64"));
        try source.put(a, "media_type", S(if (media.len > 0) media else "image/png"));
        try source.put(a, "data", S(rest[comma + 1 ..]));
    } else if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
        try source.put(a, "type", S("url"));
        try source.put(a, "url", S(url));
    } else {
        return error.Untranslatable;
    }
    var o: ObjectMap = .empty;
    try o.put(a, "type", S("image"));
    try o.put(a, "source", .{ .object = source });
    return .{ .object = o };
}

/// OpenAI tool-call `arguments` (a JSON string) -> Anthropic `input` object.
/// Arguments that are not a JSON object are preserved under `_raw_arguments`
/// instead of failing the whole request.
fn parseToolInput(a: Allocator, arguments: []const u8) !Value {
    const trimmed = std.mem.trim(u8, arguments, " \t\r\n");
    if (trimmed.len == 0) return .{ .object = .empty };
    // JSON inside a string is not covered by the depth check on the body it
    // came in; too deep, and it is kept as the string it arrived as.
    const parsed: ?Value = if (!guard.jsonDepthOk(trimmed, guard.max_client_json_depth) or
        !guard.jsonMembersOk(trimmed, guard.max_tree_members))
        null
    else
        json.parseFromSliceLeaky(Value, a, trimmed, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
    if (parsed) |v| if (v == .object) return v;
    var o: ObjectMap = .empty;
    try o.put(a, "_raw_arguments", S(arguments));
    return .{ .object = o };
}

fn requestAnthropicToOpenAi(a: Allocator, req: ObjectMap, target_model: []const u8) !ObjectMap {
    var out: ObjectMap = .empty;
    try out.put(a, "model", S(target_model));

    var msgs = Array.init(a);
    if (req.get("system")) |sys| {
        const text = try joinText(a, sys, "\n\n");
        if (text.len > 0) {
            var o: ObjectMap = .empty;
            try o.put(a, "role", S("system"));
            try o.put(a, "content", S(text));
            try msgs.append(.{ .object = o });
        }
    }

    const messages = getArr(req, "messages") orelse return error.Untranslatable;
    for (messages) |m| {
        if (m != .object) return error.Untranslatable;
        const role = getStr(m.object, "role") orelse return error.Untranslatable;
        const content: Value = m.object.get("content") orelse .null;
        if (eql(role, "user")) {
            try anthropicUserToOpenAi(a, content, &msgs);
        } else if (eql(role, "assistant")) {
            try anthropicAssistantToOpenAi(a, content, &msgs);
        } else {
            return error.Untranslatable;
        }
    }
    try out.put(a, "messages", .{ .array = msgs });

    // `max_completion_tokens` is what current OpenAI models require; the older
    // `max_tokens` is rejected by them.
    if (req.get("max_tokens")) |v| if (v == .integer) try out.put(a, "max_completion_tokens", v);
    if (req.get("temperature")) |v| if (isNumber(v)) try out.put(a, "temperature", v);
    if (req.get("top_p")) |v| if (isNumber(v)) try out.put(a, "top_p", v);
    if (req.get("stop_sequences")) |v| if (v == .array and v.array.items.len > 0) try out.put(a, "stop", v);
    if (getBool(req, "stream")) |s| {
        try out.put(a, "stream", .{ .bool = s });
        if (s) {
            // Without this an OpenAI stream carries no token usage at all.
            var so: ObjectMap = .empty;
            try so.put(a, "include_usage", .{ .bool = true });
            try out.put(a, "stream_options", .{ .object = so });
        }
    }
    if (getObj(req, "metadata")) |meta| if (getStr(meta, "user_id")) |u| try out.put(a, "user", S(u));

    // Structured output: Anthropic's `output_config.format` is OpenAI's
    // `response_format` with a JSON schema (which OpenAI wants named).
    if (getObj(req, "output_config")) |oc| if (getObj(oc, "format")) |format| {
        if (eql(getStr(format, "type") orelse "", "json_schema")) if (format.get("schema")) |schema| if (schema == .object) {
            var js: ObjectMap = .empty;
            try js.put(a, "name", S("response"));
            try js.put(a, "schema", schema);
            try js.put(a, "strict", .{ .bool = true });
            var rf: ObjectMap = .empty;
            try rf.put(a, "type", S("json_schema"));
            try rf.put(a, "json_schema", .{ .object = js });
            try out.put(a, "response_format", .{ .object = rf });
        };
    };

    // --- tools ---
    var tools = Array.init(a);
    if (getArr(req, "tools")) |list| {
        for (list) |t| {
            if (t != .object) continue;
            // Server tools (web_search_*, computer_*, ...) have a versioned
            // `type` and no schema; there is nothing to map them to.
            if (getStr(t.object, "type")) |ty| if (!eql(ty, "custom")) continue;
            const name = getStr(t.object, "name") orelse continue;
            var f: ObjectMap = .empty;
            try f.put(a, "name", S(name));
            if (getStr(t.object, "description")) |d| try f.put(a, "description", S(d));
            if (getObj(t.object, "input_schema")) |schema| try f.put(a, "parameters", .{ .object = schema });
            var o: ObjectMap = .empty;
            try o.put(a, "type", S("function"));
            try o.put(a, "function", .{ .object = f });
            try tools.append(.{ .object = o });
        }
    }
    if (tools.items.len > 0) {
        try out.put(a, "tools", .{ .array = tools });
        if (getObj(req, "tool_choice")) |tc| {
            const ty = getStr(tc, "type") orelse "auto";
            if (eql(ty, "auto")) {
                try out.put(a, "tool_choice", S("auto"));
            } else if (eql(ty, "any")) {
                try out.put(a, "tool_choice", S("required"));
            } else if (eql(ty, "none")) {
                try out.put(a, "tool_choice", S("none"));
            } else if (eql(ty, "tool")) {
                var f: ObjectMap = .empty;
                try f.put(a, "name", S(getStr(tc, "name") orelse return error.Untranslatable));
                var o: ObjectMap = .empty;
                try o.put(a, "type", S("function"));
                try o.put(a, "function", .{ .object = f });
                try out.put(a, "tool_choice", .{ .object = o });
            }
            if (getBool(tc, "disable_parallel_tool_use")) |d| if (d) try out.put(a, "parallel_tool_calls", .{ .bool = false });
        }
    }

    return out;
}

fn anthropicUserToOpenAi(a: Allocator, content: Value, msgs: *Array) !void {
    switch (content) {
        .string => |s| {
            var o: ObjectMap = .empty;
            try o.put(a, "role", S("user"));
            try o.put(a, "content", S(s));
            try msgs.append(.{ .object = o });
        },
        .array => |blocks| {
            // Tool results become `tool` messages and must directly follow the
            // assistant turn that made the calls, so they go first.
            var parts = Array.init(a);
            for (blocks.items) |b| {
                if (b != .object) return error.Untranslatable;
                const ty = getStr(b.object, "type") orelse return error.Untranslatable;
                if (eql(ty, "tool_result")) {
                    var o: ObjectMap = .empty;
                    try o.put(a, "role", S("tool"));
                    try o.put(a, "tool_call_id", S(getStr(b.object, "tool_use_id") orelse return error.Untranslatable));
                    try o.put(a, "content", S(try joinText(a, b.object.get("content") orelse .null, "\n")));
                    try msgs.append(.{ .object = o });
                } else if (eql(ty, "text")) {
                    const text = getStr(b.object, "text") orelse "";
                    if (text.len > 0) try parts.append(try textBlock(a, text));
                } else if (eql(ty, "image")) {
                    const src = getObj(b.object, "source") orelse return error.Untranslatable;
                    const st = getStr(src, "type") orelse return error.Untranslatable;
                    const url = if (eql(st, "base64"))
                        try std.fmt.allocPrint(a, "data:{s};base64,{s}", .{
                            getStr(src, "media_type") orelse "image/png",
                            getStr(src, "data") orelse return error.Untranslatable,
                        })
                    else if (eql(st, "url"))
                        getStr(src, "url") orelse return error.Untranslatable
                    else
                        return error.Untranslatable;
                    var iu: ObjectMap = .empty;
                    try iu.put(a, "url", S(url));
                    var o: ObjectMap = .empty;
                    try o.put(a, "type", S("image_url"));
                    try o.put(a, "image_url", .{ .object = iu });
                    try parts.append(.{ .object = o });
                } else {
                    // document, search_result, ...
                    return error.Untranslatable;
                }
            }
            if (parts.items.len == 0) return;
            var o: ObjectMap = .empty;
            try o.put(a, "role", S("user"));
            const only = parts.items[0].object;
            if (parts.items.len == 1 and eql(getStr(only, "type").?, "text")) {
                try o.put(a, "content", S(getStr(only, "text").?));
            } else {
                try o.put(a, "content", .{ .array = parts });
            }
            try msgs.append(.{ .object = o });
        },
        .null => {},
        else => return error.Untranslatable,
    }
}

fn anthropicAssistantToOpenAi(a: Allocator, content: Value, msgs: *Array) !void {
    var text: std.ArrayList(u8) = .empty;
    var calls = Array.init(a);
    switch (content) {
        .string => |s| try text.appendSlice(a, s),
        .array => |blocks| for (blocks.items) |b| {
            if (b != .object) return error.Untranslatable;
            const ty = getStr(b.object, "type") orelse return error.Untranslatable;
            if (eql(ty, "text")) {
                try text.appendSlice(a, getStr(b.object, "text") orelse "");
            } else if (eql(ty, "tool_use")) {
                try calls.append(try toolCallFromToolUse(a, b.object));
            }
            // thinking, redacted_thinking, server tool blocks: no equivalent.
        },
        .null => {},
        else => return error.Untranslatable,
    }
    if (text.items.len == 0 and calls.items.len == 0) return;

    var o: ObjectMap = .empty;
    try o.put(a, "role", S("assistant"));
    try o.put(a, "content", if (text.items.len > 0) S(text.items) else .null);
    if (calls.items.len > 0) try o.put(a, "tool_calls", .{ .array = calls });
    try msgs.append(.{ .object = o });
}

fn toolCallFromToolUse(a: Allocator, block: ObjectMap) !Value {
    var f: ObjectMap = .empty;
    try f.put(a, "name", S(getStr(block, "name") orelse return error.Untranslatable));
    const input: Value = block.get("input") orelse .{ .object = .empty };
    try f.put(a, "arguments", S(try json.Stringify.valueAlloc(a, input, .{})));
    var o: ObjectMap = .empty;
    try o.put(a, "id", S(getStr(block, "id") orelse return error.Untranslatable));
    try o.put(a, "type", S("function"));
    try o.put(a, "function", .{ .object = f });
    return .{ .object = o };
}

// ---------------------------------------------------------------------------
// Stop reasons
// ---------------------------------------------------------------------------

/// Anthropic `stop_reason` -> OpenAI `finish_reason`.
fn finishFromStop(stop_reason: []const u8) []const u8 {
    if (eql(stop_reason, "max_tokens") or eql(stop_reason, "model_context_window_exceeded")) return "length";
    if (eql(stop_reason, "tool_use")) return "tool_calls";
    if (eql(stop_reason, "refusal")) return "content_filter";
    // end_turn, stop_sequence, pause_turn
    return "stop";
}

/// OpenAI `finish_reason` -> Anthropic `stop_reason`.
fn stopFromFinish(finish_reason: []const u8) []const u8 {
    if (eql(finish_reason, "length")) return "max_tokens";
    if (eql(finish_reason, "tool_calls") or eql(finish_reason, "function_call")) return "tool_use";
    if (eql(finish_reason, "content_filter")) return "refusal";
    return "end_turn";
}

// ---------------------------------------------------------------------------
// Non-streaming responses
// ---------------------------------------------------------------------------

/// Complete (non-streaming) upstream response body -> client-protocol body.
/// For `status >= 400` the error envelope is converted instead. `route_model`
/// is the model name the client asked for and should see.
///
/// OpenAI's `created` is 0 here because this module has no clock; use
/// `translateResponseAt` to supply one.
pub fn translateResponse(arena: Allocator, dir: Direction, status: u16, upstream_body: []const u8, route_model: []const u8) ![]u8 {
    return translateResponseAt(arena, dir, status, upstream_body, route_model, 0);
}

/// `translateResponse` with an explicit `created` (unix seconds) for
/// OpenAI-shaped output.
pub fn translateResponseAt(
    arena: Allocator,
    dir: Direction,
    status: u16,
    upstream_body: []const u8,
    route_model: []const u8,
    created: i64,
) ![]u8 {
    if (status >= 400) return translateError(arena, dir, status, upstream_body);
    const resp = try parseObject(arena, upstream_body);
    const out = switch (dir) {
        .openai_to_anthropic => try responseAnthropicToOpenAi(arena, resp, route_model, created),
        .anthropic_to_openai => try responseOpenAiToAnthropic(arena, resp, route_model),
    };
    return json.Stringify.valueAlloc(arena, Value{ .object = out }, .{});
}

fn responseAnthropicToOpenAi(a: Allocator, resp: ObjectMap, route_model: []const u8, created: i64) !ObjectMap {
    var text: std.ArrayList(u8) = .empty;
    var calls = Array.init(a);
    if (getArr(resp, "content")) |blocks| {
        for (blocks) |b| {
            if (b != .object) continue;
            const ty = getStr(b.object, "type") orelse continue;
            if (eql(ty, "text")) {
                try text.appendSlice(a, getStr(b.object, "text") orelse "");
            } else if (eql(ty, "tool_use")) {
                try calls.append(try toolCallFromToolUse(a, b.object));
            }
            // thinking / redacted_thinking are dropped for OpenAI clients.
        }
    }

    var message: ObjectMap = .empty;
    try message.put(a, "role", S("assistant"));
    try message.put(a, "content", if (text.items.len > 0 or calls.items.len == 0) S(text.items) else .null);
    if (calls.items.len > 0) try message.put(a, "tool_calls", .{ .array = calls });
    try message.put(a, "refusal", .null);

    var choice: ObjectMap = .empty;
    try choice.put(a, "index", .{ .integer = 0 });
    try choice.put(a, "message", .{ .object = message });
    try choice.put(a, "logprobs", .null);
    try choice.put(a, "finish_reason", S(finishFromStop(getStr(resp, "stop_reason") orelse "end_turn")));
    var choices = Array.init(a);
    try choices.append(.{ .object = choice });

    var out: ObjectMap = .empty;
    try out.put(a, "id", S(try std.fmt.allocPrint(a, "chatcmpl-{s}", .{getStr(resp, "id") orelse "omnigate"})));
    try out.put(a, "object", S("chat.completion"));
    try out.put(a, "created", .{ .integer = created });
    try out.put(a, "model", S(route_model));
    try out.put(a, "choices", .{ .array = choices });
    if (getObj(resp, "usage")) |u| {
        var t: Tokens = .{};
        t.readAnthropic(u);
        try out.put(a, "usage", try t.openAiValue(a));
    }
    return out;
}

fn responseOpenAiToAnthropic(a: Allocator, resp: ObjectMap, route_model: []const u8) !ObjectMap {
    var content = Array.init(a);
    var stop_reason: []const u8 = "end_turn";

    const choices = getArr(resp, "choices") orelse return error.InvalidJson;
    if (choices.len > 0 and choices[0] == .object) {
        const choice = choices[0].object;
        if (getStr(choice, "finish_reason")) |fr| stop_reason = stopFromFinish(fr);
        if (getObj(choice, "message")) |msg| {
            var text = try joinText(a, msg.get("content") orelse .null, "");
            if (text.len == 0) text = getStr(msg, "refusal") orelse "";
            if (text.len > 0) try content.append(try textBlock(a, text));
            if (getArr(msg, "tool_calls")) |calls| {
                for (calls) |c| {
                    if (c != .object) continue;
                    const f = getObj(c.object, "function") orelse continue;
                    var b: ObjectMap = .empty;
                    try b.put(a, "type", S("tool_use"));
                    try b.put(a, "id", S(getStr(c.object, "id") orelse "toolu_omnigate"));
                    try b.put(a, "name", S(getStr(f, "name") orelse ""));
                    try b.put(a, "input", try parseToolInput(a, getStr(f, "arguments") orelse ""));
                    try content.append(.{ .object = b });
                }
            }
        }
    }

    var out: ObjectMap = .empty;
    try out.put(a, "id", S(try std.fmt.allocPrint(a, "msg_{s}", .{getStr(resp, "id") orelse "omnigate"})));
    try out.put(a, "type", S("message"));
    try out.put(a, "role", S("assistant"));
    try out.put(a, "model", S(route_model));
    try out.put(a, "content", .{ .array = content });
    try out.put(a, "stop_reason", S(stop_reason));
    try out.put(a, "stop_sequence", .null);
    var t: Tokens = .{};
    if (getObj(resp, "usage")) |u| t.readOpenAi(u);
    try out.put(a, "usage", try t.anthropicValue(a));
    return out;
}

/// Token counts in Anthropic terms: `input` excludes cached tokens, whereas
/// OpenAI's `prompt_tokens` includes them. Values are max-merged because
/// streams report them more than once.
const Tokens = struct {
    input: u64 = 0,
    cache_creation: u64 = 0,
    cache_read: u64 = 0,
    output: u64 = 0,

    fn readAnthropic(t: *Tokens, u: ObjectMap) void {
        t.input = @max(t.input, getCount(u, "input_tokens"));
        t.cache_creation = @max(t.cache_creation, getCount(u, "cache_creation_input_tokens"));
        t.cache_read = @max(t.cache_read, getCount(u, "cache_read_input_tokens"));
        t.output = @max(t.output, getCount(u, "output_tokens"));
    }

    fn readOpenAi(t: *Tokens, u: ObjectMap) void {
        const total = getCount(u, "prompt_tokens");
        var cached: u64 = 0;
        if (getObj(u, "prompt_tokens_details")) |d| cached = @min(getCount(d, "cached_tokens"), total);
        t.cache_read = @max(t.cache_read, cached);
        t.input = @max(t.input, total - cached);
        t.output = @max(t.output, getCount(u, "completion_tokens"));
    }

    fn prompt(t: Tokens) u64 {
        return t.input + t.cache_creation + t.cache_read;
    }

    fn openAiValue(t: Tokens, a: Allocator) !Value {
        var o: ObjectMap = .empty;
        try o.put(a, "prompt_tokens", .{ .integer = @intCast(t.prompt()) });
        try o.put(a, "completion_tokens", .{ .integer = @intCast(t.output) });
        try o.put(a, "total_tokens", .{ .integer = @intCast(t.prompt() + t.output) });
        if (t.cache_read > 0) {
            var d: ObjectMap = .empty;
            try d.put(a, "cached_tokens", .{ .integer = @intCast(t.cache_read) });
            try o.put(a, "prompt_tokens_details", .{ .object = d });
        }
        return .{ .object = o };
    }

    fn anthropicValue(t: Tokens, a: Allocator) !Value {
        var o: ObjectMap = .empty;
        try o.put(a, "input_tokens", .{ .integer = @intCast(t.input) });
        try o.put(a, "output_tokens", .{ .integer = @intCast(t.output) });
        if (t.cache_read > 0) try o.put(a, "cache_read_input_tokens", .{ .integer = @intCast(t.cache_read) });
        return .{ .object = o };
    }
};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

fn openAiErrorType(status: u16) []const u8 {
    return switch (status) {
        401 => "authentication_error",
        403 => "permission_error",
        404 => "not_found_error",
        429 => "rate_limit_error",
        else => if (status >= 500) "server_error" else "invalid_request_error",
    };
}

fn anthropicErrorType(status: u16) []const u8 {
    return switch (status) {
        401 => "authentication_error",
        403 => "permission_error",
        404 => "not_found_error",
        413 => "request_too_large",
        429 => "rate_limit_error",
        503, 529 => "overloaded_error",
        else => if (status >= 500) "api_error" else "invalid_request_error",
    };
}

/// Upstream error body -> error envelope in the client's protocol. Bodies that
/// are not a recognisable envelope are used verbatim as the message.
pub fn translateError(arena: Allocator, dir: Direction, status: u16, upstream_body: []const u8) ![]u8 {
    var message: []const u8 = std.mem.trim(u8, upstream_body, " \t\r\n");
    var upstream_type: ?[]const u8 = null;

    if (parseObject(arena, upstream_body)) |o| {
        if (o.get("error")) |e| {
            switch (e) {
                .object => |eo| {
                    if (getStr(eo, "message")) |m| message = m;
                    upstream_type = getStr(eo, "type");
                },
                .string => |s| message = s,
                else => {},
            }
        } else if (getStr(o, "message")) |m| {
            message = m;
        }
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => {},
    }
    if (message.len == 0) message = try std.fmt.allocPrint(arena, "upstream returned HTTP {d}", .{status});
    // A body that is not text (compressed, binary, another encoding) cannot
    // be a JSON string; the serialiser would write it as an array of
    // numbers, which no client reads as a message.
    if (!std.unicode.utf8ValidateSlice(message)) {
        message = try std.fmt.allocPrint(arena, "upstream returned HTTP {d} with a body that is not valid text", .{status});
    }
    if (upstream_type) |t| if (!std.unicode.utf8ValidateSlice(t)) {
        upstream_type = null;
    };

    return switch (dir) {
        .openai_to_anthropic => json.Stringify.valueAlloc(arena, .{
            .@"error" = .{
                .message = message,
                .type = upstream_type orelse openAiErrorType(status),
                .param = @as(?[]const u8, null),
                .code = upstream_type,
            },
        }, .{}),
        .anthropic_to_openai => json.Stringify.valueAlloc(arena, .{
            .type = "error",
            .@"error" = .{ .type = anthropicErrorType(status), .message = message },
        }, .{}),
    };
}

// ---------------------------------------------------------------------------
// Streaming
// ---------------------------------------------------------------------------

pub const StreamOptions = struct {
    /// OpenAI clients only: emit the final usage chunk (the client sent
    /// `stream_options.include_usage`).
    include_usage: bool = false,
    /// OpenAI clients only: `created` (unix seconds) stamped on every chunk.
    created: i64 = 0,
};

/// Incremental SSE translation: upstream event stream in, client-protocol
/// event stream out.
///
/// Do not copy after the first `feed`: it owns a scratch arena (set up on
/// first use, because it points back into this struct). Memory held is
/// bounded by the largest single event, not by the length of the stream.
pub const StreamTranslator = struct {
    arena: Allocator,
    dir: Direction,
    route_model: []const u8,
    opts: StreamOptions,
    /// Per-event parse memory, reset after every event, and capped: what
    /// one event may cost is not for the upstream to decide.
    scratch: std.heap.ArenaAllocator = undefined,
    scratch_cap: limits.Capped = undefined,
    scratch_ready: bool = false,
    /// Partial line carried over between chunks.
    line: std.ArrayList(u8) = .empty,
    /// `data:` payload of the event being assembled.
    data: std.ArrayList(u8) = .empty,
    has_data: bool = false,

    id: []const u8 = "",
    /// The client has been sent the opening of the response.
    started: bool = false,
    /// The client has been sent the terminator (or an error); ignore the rest.
    done: bool = false,
    /// Stop / finish reason in the *client's* vocabulary, once known.
    stop: ?[]const u8 = null,
    tokens: Tokens = .{},

    // Anthropic upstream -> OpenAI client
    tool_calls: usize = 0,
    open_tool: ?usize = null,
    finish_sent: bool = false,

    // OpenAI upstream -> Anthropic client
    block: enum { none, text, tool } = .none,
    block_index: usize = 0,
    blocks_opened: usize = 0,
    upstream_tool_index: i64 = -1,
    upstream_tool_id: []const u8 = "",
    /// Holds `upstream_tool_id`. One buffer reused for every tool call, so a
    /// stream with many of them does not keep every id it ever saw.
    tool_id_buf: std.ArrayList(u8) = .empty,

    pub fn init(arena: Allocator, dir: Direction, route_model: []const u8, opts: StreamOptions) StreamTranslator {
        return .{
            .arena = arena,
            .dir = dir,
            .route_model = route_model,
            .opts = opts,
        };
    }

    /// Chunks may split SSE lines/events anywhere. Writes zero or more
    /// complete client events to `out`.
    pub fn feed(self: *StreamTranslator, chunk: []const u8, out: *Writer) !void {
        var rest = chunk;
        while (std.mem.findScalar(u8, rest, '\n')) |nl| {
            if (self.line.items.len == 0) {
                try self.handleLine(rest[0..nl], out);
            } else {
                try self.line.appendSlice(self.arena, rest[0..nl]);
                try self.handleLine(self.line.items, out);
                self.line.clearRetainingCapacity();
            }
            rest = rest[nl + 1 ..];
        }
        if (rest.len > 0) {
            if (self.line.items.len + rest.len > max_event_bytes) return error.EventTooLarge;
            try self.line.appendSlice(self.arena, rest);
        }
    }

    /// Upstream ended: flush anything pending and emit the protocol's
    /// terminator if not yet sent. A stream that stopped before the upstream
    /// reported a stop reason ends with an error event, not a fake success.
    pub fn finish(self: *StreamTranslator, out: *Writer) !void {
        if (self.line.items.len > 0) {
            try self.handleLine(self.line.items, out);
            self.line.clearRetainingCapacity();
        }
        if (self.has_data) try self.dispatch(out);
        if (self.done) return;

        const truncated = "upstream stream ended before completion";
        switch (self.dir) {
            .openai_to_anthropic => if (self.finish_sent) {
                try self.oaEnd(out);
            } else {
                try self.oaError(out, "api_error", truncated);
            },
            .anthropic_to_openai => if (self.stop != null) {
                try self.anFinalize(out);
            } else {
                try self.anError(out, "api_error", truncated);
            },
        }
    }

    fn handleLine(self: *StreamTranslator, raw: []const u8, out: *Writer) !void {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            if (self.has_data) try self.dispatch(out);
            return;
        }
        if (line[0] == ':') return; // comment / keep-alive

        const colon = std.mem.findScalar(u8, line, ':') orelse line.len;
        if (!eql(line[0..colon], "data")) return; // event:, id:, retry:
        var value = if (colon < line.len) line[colon + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (self.data.items.len + value.len + 1 > max_event_bytes) return error.EventTooLarge;
        if (self.has_data) try self.data.append(self.arena, '\n');
        try self.data.appendSlice(self.arena, value);
        self.has_data = true;
    }

    fn dispatch(self: *StreamTranslator, out: *Writer) !void {
        defer {
            self.data.clearRetainingCapacity();
            self.has_data = false;
            if (self.scratch_ready) _ = self.scratch.reset(.{ .retain_with_limit = event_tree_retained_bytes });
        }
        if (self.done) return;
        const payload = std.mem.trim(u8, self.data.items, " \t\r\n");
        if (payload.len == 0) return;
        switch (self.dir) {
            .openai_to_anthropic => try self.fromAnthropic(payload, out),
            .anthropic_to_openai => try self.fromOpenAi(payload, out),
        }
    }

    /// Parse one event payload; `null` for anything that is not a JSON object
    /// (skipped rather than aborting a live stream).
    fn parseEvent(self: *StreamTranslator, payload: []const u8) error{OutOfMemory}!?ObjectMap {
        if (!self.scratch_ready) {
            self.scratch_cap = .{ .child = self.arena, .left = max_event_tree_bytes };
            self.scratch = .init(self.scratch_cap.allocator());
            self.scratch_ready = true;
        }
        return parseObject(self.scratch.allocator(), payload) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson => null,
        };
    }

    // --- Anthropic upstream -> OpenAI client -------------------------------

    fn fromAnthropic(self: *StreamTranslator, payload: []const u8, out: *Writer) !void {
        const ev = try self.parseEvent(payload) orelse return;
        const ty = getStr(ev, "type") orelse return;

        if (eql(ty, "message_start")) {
            if (getObj(ev, "message")) |m| {
                if (getStr(m, "id")) |id| {
                    if (self.id.len == 0) self.id = try std.fmt.allocPrint(self.arena, "chatcmpl-{s}", .{id});
                }
                if (getObj(m, "usage")) |u| self.tokens.readAnthropic(u);
            }
            try self.oaStart(out);
        } else if (eql(ty, "content_block_start")) {
            const b = getObj(ev, "content_block") orelse return;
            const bt = getStr(b, "type") orelse return;
            self.open_tool = null;
            if (eql(bt, "tool_use")) {
                try self.oaStart(out);
                const idx = self.tool_calls;
                self.tool_calls += 1;
                self.open_tool = idx;
                try self.oaChunk(out, .{ .tool_calls = .{.{
                    .index = idx,
                    .id = getStr(b, "id") orelse "",
                    .type = "function",
                    .function = .{ .name = getStr(b, "name") orelse "", .arguments = "" },
                }} }, null);
            } else if (eql(bt, "text")) {
                const text = getStr(b, "text") orelse "";
                if (text.len > 0) {
                    try self.oaStart(out);
                    try self.oaChunk(out, .{ .content = text }, null);
                }
            }
        } else if (eql(ty, "content_block_delta")) {
            const d = getObj(ev, "delta") orelse return;
            const dt = getStr(d, "type") orelse return;
            if (eql(dt, "text_delta")) {
                const text = getStr(d, "text") orelse return;
                if (text.len == 0) return;
                try self.oaStart(out);
                try self.oaChunk(out, .{ .content = text }, null);
            } else if (eql(dt, "input_json_delta")) {
                const idx = self.open_tool orelse return;
                const partial = getStr(d, "partial_json") orelse return;
                if (partial.len == 0) return;
                try self.oaChunk(out, .{ .tool_calls = .{.{
                    .index = idx,
                    .function = .{ .arguments = partial },
                }} }, null);
            }
            // thinking_delta, signature_delta, citations_delta: dropped.
        } else if (eql(ty, "content_block_stop")) {
            self.open_tool = null;
        } else if (eql(ty, "message_delta")) {
            if (getObj(ev, "delta")) |d| {
                if (getStr(d, "stop_reason")) |r| self.stop = finishFromStop(r);
            }
            if (getObj(ev, "usage")) |u| self.tokens.readAnthropic(u);
            try self.oaFinishChunk(out);
        } else if (eql(ty, "message_stop")) {
            try self.oaEnd(out);
        } else if (eql(ty, "error")) {
            var kind: []const u8 = "api_error";
            var message: []const u8 = "upstream error";
            if (getObj(ev, "error")) |e| {
                if (getStr(e, "type")) |t| kind = t;
                if (getStr(e, "message")) |m| message = m;
            }
            try self.oaError(out, kind, message);
        }
        // ping and unknown event types: nothing to send.
    }

    fn oaId(self: *const StreamTranslator) []const u8 {
        return if (self.id.len > 0) self.id else "chatcmpl-omnigate";
    }

    fn oaChunk(self: *StreamTranslator, out: *Writer, delta: anytype, finish_reason: ?[]const u8) !void {
        try out.writeAll("data: ");
        try json.Stringify.value(.{
            .id = self.oaId(),
            .object = "chat.completion.chunk",
            .created = self.opts.created,
            .model = self.route_model,
            .choices = .{.{
                .index = @as(u32, 0),
                .delta = delta,
                .finish_reason = finish_reason,
            }},
        }, .{}, out);
        try out.writeAll("\n\n");
    }

    fn oaStart(self: *StreamTranslator, out: *Writer) !void {
        if (self.started) return;
        self.started = true;
        try self.oaChunk(out, .{ .role = "assistant", .content = "" }, null);
    }

    fn oaFinishChunk(self: *StreamTranslator, out: *Writer) !void {
        if (self.finish_sent) return;
        try self.oaStart(out);
        self.finish_sent = true;
        try self.oaChunk(out, Value{ .object = .empty }, self.stop orelse "stop");
    }

    fn oaEnd(self: *StreamTranslator, out: *Writer) !void {
        if (self.done) return;
        try self.oaFinishChunk(out);
        if (self.opts.include_usage) {
            const prompt_tokens = self.tokens.prompt();
            try out.writeAll("data: ");
            try json.Stringify.value(.{
                .id = self.oaId(),
                .object = "chat.completion.chunk",
                .created = self.opts.created,
                .model = self.route_model,
                .choices = @as([]const u32, &.{}),
                .usage = .{
                    .prompt_tokens = prompt_tokens,
                    .completion_tokens = self.tokens.output,
                    .total_tokens = prompt_tokens + self.tokens.output,
                    .prompt_tokens_details = .{ .cached_tokens = self.tokens.cache_read },
                },
            }, .{}, out);
            try out.writeAll("\n\n");
        }
        try out.writeAll("data: [DONE]\n\n");
        self.done = true;
    }

    fn oaError(self: *StreamTranslator, out: *Writer, kind: []const u8, message: []const u8) !void {
        try out.writeAll("data: ");
        try json.Stringify.value(.{
            .@"error" = .{ .message = message, .type = kind, .param = @as(?[]const u8, null), .code = kind },
        }, .{}, out);
        try out.writeAll("\n\n");
        self.done = true;
    }

    // --- OpenAI upstream -> Anthropic client -------------------------------

    fn fromOpenAi(self: *StreamTranslator, payload: []const u8, out: *Writer) !void {
        if (eql(payload, "[DONE]")) return self.anFinalize(out);
        const ev = try self.parseEvent(payload) orelse return;

        if (ev.get("error")) |e| {
            var message: []const u8 = "upstream error";
            switch (e) {
                .object => |eo| if (getStr(eo, "message")) |m| {
                    message = m;
                },
                .string => |s| message = s,
                .null => {},
                else => {},
            }
            if (e != .null) return self.anError(out, "api_error", message);
        }

        if (self.id.len == 0) {
            if (getStr(ev, "id")) |id| self.id = try std.fmt.allocPrint(self.arena, "msg_{s}", .{id});
        }
        if (getObj(ev, "usage")) |u| self.tokens.readOpenAi(u);

        const choices = getArr(ev, "choices") orelse return;
        if (choices.len == 0 or choices[0] != .object) return; // usage-only chunk
        const choice = choices[0].object;
        try self.anStart(out);

        if (getObj(choice, "delta")) |d| {
            const text = getStr(d, "content") orelse getStr(d, "refusal") orelse "";
            if (text.len > 0) try self.anText(out, text);
            if (getArr(d, "tool_calls")) |calls| {
                for (calls) |c| if (c == .object) try self.anToolDelta(out, c.object);
            }
        }
        // The usage chunk may still follow, so the message is closed at [DONE]
        // (or at `finish`), not here.
        if (getStr(choice, "finish_reason")) |fr| self.stop = stopFromFinish(fr);
    }

    fn anEvent(out: *Writer, name: []const u8, payload: anytype) !void {
        try out.print("event: {s}\ndata: ", .{name});
        try json.Stringify.value(payload, .{}, out);
        try out.writeAll("\n\n");
    }

    fn anStart(self: *StreamTranslator, out: *Writer) !void {
        if (self.started) return;
        self.started = true;
        try anEvent(out, "message_start", .{
            .type = "message_start",
            .message = .{
                .id = if (self.id.len > 0) self.id else "msg_omnigate",
                .type = "message",
                .role = "assistant",
                .model = self.route_model,
                .content = @as([]const u32, &.{}),
                .stop_reason = @as(?[]const u8, null),
                .stop_sequence = @as(?[]const u8, null),
                // OpenAI reports usage only at the end; the real numbers are
                // sent in message_delta.
                .usage = .{ .input_tokens = self.tokens.input, .output_tokens = @as(u64, 0) },
            },
        });
    }

    fn anOpenBlock(self: *StreamTranslator, out: *Writer, content_block: anytype) !void {
        try self.anCloseBlock(out);
        self.block_index = self.blocks_opened;
        self.blocks_opened += 1;
        try anEvent(out, "content_block_start", .{
            .type = "content_block_start",
            .index = self.block_index,
            .content_block = content_block,
        });
    }

    fn anCloseBlock(self: *StreamTranslator, out: *Writer) !void {
        if (self.block == .none) return;
        self.block = .none;
        try anEvent(out, "content_block_stop", .{ .type = "content_block_stop", .index = self.block_index });
    }

    fn anText(self: *StreamTranslator, out: *Writer, text: []const u8) !void {
        if (self.block != .text) {
            try self.anOpenBlock(out, .{ .type = "text", .text = "" });
            self.block = .text;
        }
        try anEvent(out, "content_block_delta", .{
            .type = "content_block_delta",
            .index = self.block_index,
            .delta = .{ .type = "text_delta", .text = text },
        });
    }

    fn anToolDelta(self: *StreamTranslator, out: *Writer, call: ObjectMap) !void {
        const index = getInt(call, "index") orelse 0;
        const id = getStr(call, "id") orelse "";
        const function = getObj(call, "function");

        // A new tool call starts when the index changes, or (for upstreams
        // that reuse index 0) when a different non-empty id shows up.
        const same = self.block == .tool and self.upstream_tool_index == index and
            (id.len == 0 or eql(id, self.upstream_tool_id));
        if (!same) {
            self.tool_id_buf.clearRetainingCapacity();
            if (id.len > 0) {
                try self.tool_id_buf.appendSlice(self.arena, id);
            } else {
                var generated: [40]u8 = undefined;
                try self.tool_id_buf.appendSlice(self.arena, std.fmt.bufPrint(&generated, "toolu_omnigate_{d}", .{self.blocks_opened}) catch unreachable);
            }
            const block_id = self.tool_id_buf.items;
            const name = if (function) |f| getStr(f, "name") orelse "" else "";
            try self.anOpenBlock(out, .{
                .type = "tool_use",
                .id = block_id,
                .name = name,
                .input = Value{ .object = .empty },
            });
            self.block = .tool;
            self.upstream_tool_index = index;
            self.upstream_tool_id = block_id;
        }

        const args = if (function) |f| getStr(f, "arguments") orelse "" else "";
        if (args.len == 0) return;
        try anEvent(out, "content_block_delta", .{
            .type = "content_block_delta",
            .index = self.block_index,
            .delta = .{ .type = "input_json_delta", .partial_json = args },
        });
    }

    fn anFinalize(self: *StreamTranslator, out: *Writer) !void {
        if (self.done) return;
        try self.anStart(out);
        try self.anCloseBlock(out);
        try anEvent(out, "message_delta", .{
            .type = "message_delta",
            .delta = .{ .stop_reason = self.stop orelse "end_turn", .stop_sequence = @as(?[]const u8, null) },
            .usage = .{
                .input_tokens = self.tokens.input,
                .output_tokens = self.tokens.output,
                .cache_read_input_tokens = self.tokens.cache_read,
            },
        });
        try anEvent(out, "message_stop", .{ .type = "message_stop" });
        self.done = true;
    }

    fn anError(self: *StreamTranslator, out: *Writer, kind: []const u8, message: []const u8) !void {
        try anEvent(out, "error", .{
            .type = "error",
            .@"error" = .{ .type = kind, .message = message },
        });
        self.done = true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Walk a parsed JSON value: strings index objects, integers index arrays.
fn at(v: Value, path: anytype) ?Value {
    var cur = v;
    inline for (path) |seg| {
        switch (@typeInfo(@TypeOf(seg))) {
            .comptime_int, .int => {
                if (cur != .array or seg >= cur.array.items.len) return null;
                cur = cur.array.items[seg];
            },
            else => {
                if (cur != .object) return null;
                cur = cur.object.get(seg) orelse return null;
            },
        }
    }
    return cur;
}

fn expectStrAt(v: Value, path: anytype, expected: []const u8) !void {
    const got = at(v, path) orelse return error.MissingPath;
    if (got != .string) return error.NotAString;
    try testing.expectEqualStrings(expected, got.string);
}

fn expectIntAt(v: Value, path: anytype, expected: i64) !void {
    const got = at(v, path) orelse return error.MissingPath;
    if (got != .integer) return error.NotAnInteger;
    try testing.expectEqual(expected, got.integer);
}

fn expectNumAt(v: Value, path: anytype, expected: f64) !void {
    const got = at(v, path) orelse return error.MissingPath;
    const n: f64 = switch (got) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return error.NotANumber,
    };
    try testing.expectEqual(expected, n);
}

fn expectLenAt(v: Value, path: anytype, expected: usize) !void {
    const got = at(v, path) orelse return error.MissingPath;
    if (got != .array) return error.NotAnArray;
    try testing.expectEqual(expected, got.array.items.len);
}

fn parseTest(a: Allocator, body: []const u8) !Value {
    return json.parseFromSliceLeaky(Value, a, body, .{});
}

fn requestTest(a: Allocator, dir: Direction, body: []const u8) !Value {
    return parseTest(a, try translateRequest(a, dir, body, "target-model"));
}

test "request: structured output maps both ways" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // OpenAI json_schema -> Anthropic output_config.format (name and strict are OpenAI-only).
    const to_anthropic = try requestTest(a, .openai_to_anthropic,
        \\{"model":"m","messages":[{"role":"user","content":"x"}],
        \\ "response_format":{"type":"json_schema","json_schema":{"name":"person","strict":true,
        \\   "schema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}}}
    );
    try expectStrAt(to_anthropic, .{ "output_config", "format", "type" }, "json_schema");
    try expectStrAt(to_anthropic, .{ "output_config", "format", "schema", "type" }, "object");
    try expectStrAt(to_anthropic, .{ "output_config", "format", "schema", "required", 0 }, "name");
    try testing.expect(at(to_anthropic, .{ "output_config", "format", "name" }) == null);
    try testing.expect(at(to_anthropic, .{"response_format"}) == null);
    try testing.expect(at(to_anthropic, .{"system"}) == null);

    // JSON mode has no Anthropic parameter: it becomes an instruction, after any system prompt.
    const json_mode = try requestTest(a, .openai_to_anthropic,
        \\{"model":"m","messages":[{"role":"system","content":"Be brief."},{"role":"user","content":"x"}],
        \\ "response_format":{"type":"json_object"}}
    );
    try expectStrAt(json_mode, .{"system"}, "Be brief.\n\n" ++ json_object_instruction);
    try testing.expect(at(json_mode, .{"output_config"}) == null);
    const json_mode_alone = try requestTest(a, .openai_to_anthropic,
        \\{"model":"m","messages":[{"role":"user","content":"x"}],"response_format":{"type":"json_object"}}
    );
    try expectStrAt(json_mode_alone, .{"system"}, json_object_instruction);

    // Plain text, or a schema that is not an object, changes nothing.
    const text_mode = try requestTest(a, .openai_to_anthropic,
        \\{"model":"m","messages":[{"role":"user","content":"x"}],"response_format":{"type":"text"}}
    );
    try testing.expect(at(text_mode, .{"output_config"}) == null);
    try testing.expect(at(text_mode, .{"system"}) == null);

    // Anthropic output_config.format -> OpenAI response_format, which needs a name.
    const to_openai = try requestTest(a, .anthropic_to_openai,
        \\{"model":"m","max_tokens":5,"messages":[{"role":"user","content":"x"}],
        \\ "output_config":{"effort":"low","format":{"type":"json_schema","schema":{"type":"object","properties":{}}}}}
    );
    try expectStrAt(to_openai, .{ "response_format", "type" }, "json_schema");
    try expectStrAt(to_openai, .{ "response_format", "json_schema", "name" }, "response");
    try expectStrAt(to_openai, .{ "response_format", "json_schema", "schema", "type" }, "object");
    try testing.expect(at(to_openai, .{ "response_format", "json_schema", "strict" }).?.bool);
    try testing.expect(at(to_openai, .{"output_config"}) == null);

    const no_format = try requestTest(a, .anthropic_to_openai,
        \\{"model":"m","max_tokens":5,"messages":[{"role":"user","content":"x"}],"output_config":{"effort":"low"}}
    );
    try testing.expect(at(no_format, .{"response_format"}) == null);
}

test "request openai->anthropic: system, turns and params" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const v = try requestTest(a, .openai_to_anthropic,
        \\{"model":"route","stream":true,"max_completion_tokens":300,"max_tokens":50,
        \\ "temperature":1.7,"top_p":0.9,"stop":"END","user":"u-1","n":1,"presence_penalty":0.5,
        \\ "messages":[
        \\  {"role":"system","content":"Be brief."},
        \\  {"role":"developer","content":[{"type":"text","text":"Use metric."}]},
        \\  {"role":"user","content":"Hi"},
        \\  {"role":"assistant","content":"Hello!"},
        \\  {"role":"user","content":[{"type":"text","text":"One"},{"type":"text","text":"Two"}]}
        \\ ]}
    );
    try expectStrAt(v, .{"model"}, "target-model");
    try expectStrAt(v, .{"system"}, "Be brief.\n\nUse metric.");
    try expectIntAt(v, .{"max_tokens"}, 300);
    try expectNumAt(v, .{"temperature"}, 1.0);
    try expectNumAt(v, .{"top_p"}, 0.9);
    try expectLenAt(v, .{"stop_sequences"}, 1);
    try expectStrAt(v, .{ "stop_sequences", 0 }, "END");
    try testing.expect(at(v, .{"stream"}).?.bool);
    try expectStrAt(v, .{ "metadata", "user_id" }, "u-1");
    try testing.expect(at(v, .{"n"}) == null);
    try testing.expect(at(v, .{"presence_penalty"}) == null);

    try expectLenAt(v, .{"messages"}, 3);
    try expectStrAt(v, .{ "messages", 0, "role" }, "user");
    try expectStrAt(v, .{ "messages", 0, "content" }, "Hi");
    try expectStrAt(v, .{ "messages", 1, "role" }, "assistant");
    try expectStrAt(v, .{ "messages", 1, "content" }, "Hello!");
    try expectLenAt(v, .{ "messages", 2, "content" }, 2);
    try expectStrAt(v, .{ "messages", 2, "content", 1, "text" }, "Two");
}

test "request openai->anthropic: max_tokens fallback and default" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const legacy = try requestTest(a, .openai_to_anthropic,
        \\{"model":"m","max_tokens":77,"stop":["a","b"],"messages":[{"role":"user","content":"x"}]}
    );
    try expectIntAt(legacy, .{"max_tokens"}, 77);
    try expectLenAt(legacy, .{"stop_sequences"}, 2);
    try testing.expect(at(legacy, .{"system"}) == null);
    try testing.expect(at(legacy, .{"stream"}) == null);

    const none = try requestTest(a, .openai_to_anthropic,
        \\{"model":"m","messages":[{"role":"user","content":"x"}]}
    );
    try expectIntAt(none, .{"max_tokens"}, default_max_tokens);
}

test "request openai->anthropic: tools, tool calls and tool results" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const v = try requestTest(a, .openai_to_anthropic,
        \\{"model":"m","parallel_tool_calls":false,
        \\ "tools":[
        \\  {"type":"function","function":{"name":"get_weather","description":"Weather","strict":true,
        \\    "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}},
        \\  {"type":"function","function":{"name":"now"}}
        \\ ],
        \\ "tool_choice":{"type":"function","function":{"name":"get_weather"}},
        \\ "messages":[
        \\  {"role":"user","content":"Weather in Paris and Rome?"},
        \\  {"role":"assistant","content":null,"tool_calls":[
        \\    {"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}},
        \\    {"id":"call_2","type":"function","function":{"name":"get_weather","arguments":""}}]},
        \\  {"role":"tool","tool_call_id":"call_1","content":"18C"},
        \\  {"role":"tool","tool_call_id":"call_2","content":[{"type":"text","text":"24C"}]},
        \\  {"role":"user","content":"Thanks"}
        \\ ]}
    );
    try expectLenAt(v, .{"tools"}, 2);
    try expectStrAt(v, .{ "tools", 0, "name" }, "get_weather");
    try expectStrAt(v, .{ "tools", 0, "description" }, "Weather");
    try expectStrAt(v, .{ "tools", 0, "input_schema", "properties", "city", "type" }, "string");
    try testing.expect(at(v, .{ "tools", 0, "strict" }) == null);
    try expectStrAt(v, .{ "tools", 1, "input_schema", "type" }, "object");
    try expectStrAt(v, .{ "tool_choice", "type" }, "tool");
    try expectStrAt(v, .{ "tool_choice", "name" }, "get_weather");
    try testing.expect(at(v, .{ "tool_choice", "disable_parallel_tool_use" }).?.bool);

    // user, assistant(tool_use x2), user(tool_result x2 + text): tool messages
    // and the following user message merge into one turn.
    try expectLenAt(v, .{"messages"}, 3);
    try expectLenAt(v, .{ "messages", 1, "content" }, 2);
    try expectStrAt(v, .{ "messages", 1, "content", 0, "type" }, "tool_use");
    try expectStrAt(v, .{ "messages", 1, "content", 0, "id" }, "call_1");
    try expectStrAt(v, .{ "messages", 1, "content", 0, "input", "city" }, "Paris");
    try testing.expectEqual(@as(usize, 0), at(v, .{ "messages", 1, "content", 1, "input" }).?.object.count());
    try expectStrAt(v, .{ "messages", 2, "role" }, "user");
    try expectLenAt(v, .{ "messages", 2, "content" }, 3);
    try expectStrAt(v, .{ "messages", 2, "content", 0, "type" }, "tool_result");
    try expectStrAt(v, .{ "messages", 2, "content", 0, "tool_use_id" }, "call_1");
    try expectStrAt(v, .{ "messages", 2, "content", 0, "content" }, "18C");
    try expectStrAt(v, .{ "messages", 2, "content", 1, "tool_use_id" }, "call_2");
    try expectStrAt(v, .{ "messages", 2, "content", 1, "content" }, "24C");
    try expectStrAt(v, .{ "messages", 2, "content", 2, "text" }, "Thanks");
}

test "request openai->anthropic: tool_choice strings" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cases = [_][2][]const u8{ .{ "auto", "auto" }, .{ "none", "none" }, .{ "required", "any" } };
    for (cases) |c| {
        const body = try std.fmt.allocPrint(a,
            \\{{"model":"m","tool_choice":"{s}","tools":[{{"type":"function","function":{{"name":"f"}}}}],
            \\ "messages":[{{"role":"user","content":"x"}}]}}
        , .{c[0]});
        const v = try requestTest(a, .openai_to_anthropic, body);
        try expectStrAt(v, .{ "tool_choice", "type" }, c[1]);
    }

    // tool_choice without tools is dropped.
    const v = try requestTest(a, .openai_to_anthropic,
        \\{"model":"m","tool_choice":"auto","messages":[{"role":"user","content":"x"}]}
    );
    try testing.expect(at(v, .{"tool_choice"}) == null);
    try testing.expect(at(v, .{"tools"}) == null);
}

test "request openai->anthropic: images" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const v = try requestTest(a, .openai_to_anthropic,
        \\{"model":"m","messages":[{"role":"user","content":[
        \\  {"type":"text","text":"What is this?"},
        \\  {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,/9j/4AAQ","detail":"high"}},
        \\  {"type":"image_url","image_url":{"url":"https://example.com/cat.png"}}
        \\ ]}]}
    );
    try expectLenAt(v, .{ "messages", 0, "content" }, 3);
    try expectStrAt(v, .{ "messages", 0, "content", 1, "type" }, "image");
    try expectStrAt(v, .{ "messages", 0, "content", 1, "source", "type" }, "base64");
    try expectStrAt(v, .{ "messages", 0, "content", 1, "source", "media_type" }, "image/jpeg");
    try expectStrAt(v, .{ "messages", 0, "content", 1, "source", "data" }, "/9j/4AAQ");
    try expectStrAt(v, .{ "messages", 0, "content", 2, "source", "type" }, "url");
    try expectStrAt(v, .{ "messages", 0, "content", 2, "source", "url" }, "https://example.com/cat.png");
}

test "request: untranslatable and invalid input" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectError(error.Untranslatable, translateRequest(a, .openai_to_anthropic,
        \\{"model":"m","messages":[{"role":"user","content":[{"type":"input_audio","input_audio":{"data":"AAAA","format":"wav"}}]}]}
    , "t"));
    try testing.expectError(error.Untranslatable, translateRequest(a, .openai_to_anthropic,
        \\{"model":"m","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"file:///etc/passwd"}}]}]}
    , "t"));
    try testing.expectError(error.Untranslatable, translateRequest(a, .openai_to_anthropic,
        \\{"model":"m"}
    , "t"));
    try testing.expectError(error.Untranslatable, translateRequest(a, .anthropic_to_openai,
        \\{"model":"m","max_tokens":5,"messages":[{"role":"user","content":[{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":"AAAA"}}]}]}
    , "t"));
    try testing.expectError(error.InvalidJson, translateRequest(a, .openai_to_anthropic, "not json", "t"));
    try testing.expectError(error.InvalidJson, translateRequest(a, .anthropic_to_openai, "[1,2]", "t"));
}

test "request anthropic->openai: system, turns and params" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const v = try requestTest(a, .anthropic_to_openai,
        \\{"model":"route","max_tokens":256,"stream":true,"temperature":0.3,"top_p":0.8,"top_k":40,
        \\ "stop_sequences":["STOP"],"metadata":{"user_id":"u-9"},
        \\ "thinking":{"type":"enabled","budget_tokens":1024},
        \\ "system":[{"type":"text","text":"A","cache_control":{"type":"ephemeral"}},{"type":"text","text":"B"}],
        \\ "messages":[
        \\  {"role":"user","content":"Hi"},
        \\  {"role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"s"},{"type":"text","text":"Hel"},{"type":"text","text":"lo"}]},
        \\  {"role":"user","content":[{"type":"text","text":"Bye"}]}
        \\ ]}
    );
    try expectStrAt(v, .{"model"}, "target-model");
    try expectIntAt(v, .{"max_completion_tokens"}, 256);
    try testing.expect(at(v, .{"max_tokens"}) == null);
    try testing.expect(at(v, .{"top_k"}) == null);
    try testing.expect(at(v, .{"thinking"}) == null);
    try expectNumAt(v, .{"temperature"}, 0.3);
    try expectStrAt(v, .{ "stop", 0 }, "STOP");
    try expectStrAt(v, .{"user"}, "u-9");
    try testing.expect(at(v, .{"stream"}).?.bool);
    try testing.expect(at(v, .{ "stream_options", "include_usage" }).?.bool);

    try expectLenAt(v, .{"messages"}, 4);
    try expectStrAt(v, .{ "messages", 0, "role" }, "system");
    try expectStrAt(v, .{ "messages", 0, "content" }, "A\n\nB");
    try expectStrAt(v, .{ "messages", 1, "content" }, "Hi");
    try expectStrAt(v, .{ "messages", 2, "role" }, "assistant");
    try expectStrAt(v, .{ "messages", 2, "content" }, "Hello");
    try expectStrAt(v, .{ "messages", 3, "content" }, "Bye");

    // Non-streaming requests must not carry stream_options.
    const plain = try requestTest(a, .anthropic_to_openai,
        \\{"model":"m","max_tokens":5,"system":"Sys","messages":[{"role":"user","content":"x"}]}
    );
    try testing.expect(at(plain, .{"stream_options"}) == null);
    try expectStrAt(plain, .{ "messages", 0, "content" }, "Sys");
}

test "request anthropic->openai: tools, tool_use and tool_result" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const v = try requestTest(a, .anthropic_to_openai,
        \\{"model":"m","max_tokens":100,
        \\ "tools":[
        \\  {"name":"get_weather","description":"Weather","input_schema":{"type":"object","properties":{"city":{"type":"string"}}}},
        \\  {"type":"web_search_20250305","name":"web_search"}
        \\ ],
        \\ "tool_choice":{"type":"any","disable_parallel_tool_use":true},
        \\ "messages":[
        \\  {"role":"user","content":"Weather?"},
        \\  {"role":"assistant","content":[
        \\    {"type":"text","text":"Checking."},
        \\    {"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"Paris"}}]},
        \\  {"role":"user","content":[
        \\    {"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"18C"}]},
        \\    {"type":"text","text":"And Rome?"}]}
        \\ ]}
    );
    try expectLenAt(v, .{"tools"}, 1);
    try expectStrAt(v, .{ "tools", 0, "type" }, "function");
    try expectStrAt(v, .{ "tools", 0, "function", "name" }, "get_weather");
    try expectStrAt(v, .{ "tools", 0, "function", "parameters", "properties", "city", "type" }, "string");
    try expectStrAt(v, .{"tool_choice"}, "required");
    try testing.expect(!at(v, .{"parallel_tool_calls"}).?.bool);

    try expectLenAt(v, .{"messages"}, 4);
    try expectStrAt(v, .{ "messages", 1, "content" }, "Checking.");
    try expectStrAt(v, .{ "messages", 1, "tool_calls", 0, "id" }, "toolu_1");
    try expectStrAt(v, .{ "messages", 1, "tool_calls", 0, "type" }, "function");
    try expectStrAt(v, .{ "messages", 1, "tool_calls", 0, "function", "name" }, "get_weather");
    const args = try parseTest(a, at(v, .{ "messages", 1, "tool_calls", 0, "function", "arguments" }).?.string);
    try expectStrAt(args, .{"city"}, "Paris");
    try expectStrAt(v, .{ "messages", 2, "role" }, "tool");
    try expectStrAt(v, .{ "messages", 2, "tool_call_id" }, "toolu_1");
    try expectStrAt(v, .{ "messages", 2, "content" }, "18C");
    try expectStrAt(v, .{ "messages", 3, "role" }, "user");
    try expectStrAt(v, .{ "messages", 3, "content" }, "And Rome?");

    // Named tool, and an assistant turn that is only a tool call.
    const named = try requestTest(a, .anthropic_to_openai,
        \\{"model":"m","max_tokens":1,"tools":[{"name":"f","input_schema":{"type":"object"}}],
        \\ "tool_choice":{"type":"tool","name":"f"},
        \\ "messages":[{"role":"user","content":"x"},
        \\  {"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"f","input":{}}]},
        \\  {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}]}
    );
    try expectStrAt(named, .{ "tool_choice", "function", "name" }, "f");
    try testing.expect(at(named, .{ "messages", 1, "content" }).? == .null);
    try expectStrAt(named, .{ "messages", 1, "tool_calls", 0, "function", "arguments" }, "{}");
    try expectLenAt(named, .{"messages"}, 3);
    try expectStrAt(named, .{ "messages", 2, "content" }, "ok");
}

test "request anthropic->openai: images" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const v = try requestTest(a, .anthropic_to_openai,
        \\{"model":"m","max_tokens":10,"messages":[{"role":"user","content":[
        \\  {"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0K"}},
        \\  {"type":"image","source":{"type":"url","url":"https://example.com/a.jpg"}},
        \\  {"type":"text","text":"Compare"}
        \\ ]}]}
    );
    try expectLenAt(v, .{ "messages", 0, "content" }, 3);
    try expectStrAt(v, .{ "messages", 0, "content", 0, "type" }, "image_url");
    try expectStrAt(v, .{ "messages", 0, "content", 0, "image_url", "url" }, "data:image/png;base64,iVBORw0K");
    try expectStrAt(v, .{ "messages", 0, "content", 1, "image_url", "url" }, "https://example.com/a.jpg");
    try expectStrAt(v, .{ "messages", 0, "content", 2, "text" }, "Compare");
}

test "request round trip keeps images and tool calls" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const original =
        \\{"model":"m","max_completion_tokens":64,"messages":[
        \\ {"role":"system","content":"S"},
        \\ {"role":"user","content":[{"type":"text","text":"Look"},{"type":"image_url","image_url":{"url":"data:image/webp;base64,UklGRg=="}}]},
        \\ {"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"f","arguments":"{\"n\":3}"}}]},
        \\ {"role":"tool","tool_call_id":"c1","content":"done"}],
        \\ "tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}]}
    ;
    const anthropic = try translateRequest(a, .openai_to_anthropic, original, "claude");
    const back = try parseTest(a, try translateRequest(a, .anthropic_to_openai, anthropic, "gpt"));
    try expectStrAt(back, .{"model"}, "gpt");
    try expectIntAt(back, .{"max_completion_tokens"}, 64);
    try expectStrAt(back, .{ "messages", 0, "content" }, "S");
    try expectStrAt(back, .{ "messages", 1, "content", 1, "image_url", "url" }, "data:image/webp;base64,UklGRg==");
    try expectStrAt(back, .{ "messages", 2, "tool_calls", 0, "function", "arguments" }, "{\"n\":3}");
    try expectStrAt(back, .{ "messages", 3, "role" }, "tool");
    try expectStrAt(back, .{ "messages", 3, "content" }, "done");
    try expectStrAt(back, .{ "tools", 0, "function", "name" }, "f");
}

test "response anthropic->openai" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const v = try parseTest(a, try translateResponseAt(a, .openai_to_anthropic, 200,
        \\{"id":"msg_01","type":"message","role":"assistant","model":"claude-real",
        \\ "content":[{"type":"thinking","thinking":"secret","signature":"sig"},
        \\            {"type":"text","text":"Let me check."},
        \\            {"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"Paris"}}],
        \\ "stop_reason":"tool_use","stop_sequence":null,
        \\ "usage":{"input_tokens":10,"cache_creation_input_tokens":2,"cache_read_input_tokens":30,"output_tokens":7}}
    , "route-model", 1700000000));
    try expectStrAt(v, .{"id"}, "chatcmpl-msg_01");
    try expectStrAt(v, .{"object"}, "chat.completion");
    try expectIntAt(v, .{"created"}, 1700000000);
    try expectStrAt(v, .{"model"}, "route-model");
    try expectLenAt(v, .{"choices"}, 1);
    try expectIntAt(v, .{ "choices", 0, "index" }, 0);
    try expectStrAt(v, .{ "choices", 0, "message", "role" }, "assistant");
    try expectStrAt(v, .{ "choices", 0, "message", "content" }, "Let me check.");
    try expectStrAt(v, .{ "choices", 0, "finish_reason" }, "tool_calls");
    try expectStrAt(v, .{ "choices", 0, "message", "tool_calls", 0, "id" }, "toolu_1");
    try expectStrAt(v, .{ "choices", 0, "message", "tool_calls", 0, "function", "name" }, "get_weather");
    try expectStrAt(v, .{ "choices", 0, "message", "tool_calls", 0, "function", "arguments" }, "{\"city\":\"Paris\"}");
    try expectIntAt(v, .{ "usage", "prompt_tokens" }, 42);
    try expectIntAt(v, .{ "usage", "completion_tokens" }, 7);
    try expectIntAt(v, .{ "usage", "total_tokens" }, 49);
    try expectIntAt(v, .{ "usage", "prompt_tokens_details", "cached_tokens" }, 30);

    // Text only, default `created`.
    const plain = try parseTest(a, try translateResponse(a, .openai_to_anthropic, 200,
        \\{"id":"msg_02","type":"message","role":"assistant","content":[{"type":"text","text":"Hi"}],
        \\ "stop_reason":"max_tokens","usage":{"input_tokens":3,"output_tokens":1}}
    , "r"));
    try expectStrAt(plain, .{ "choices", 0, "message", "content" }, "Hi");
    try expectStrAt(plain, .{ "choices", 0, "finish_reason" }, "length");
    try testing.expect(at(plain, .{ "choices", 0, "message", "tool_calls" }) == null);
    try expectIntAt(plain, .{"created"}, 0);

    // Only a tool call: content is null.
    const tool_only = try parseTest(a, try translateResponse(a, .openai_to_anthropic, 200,
        \\{"id":"m","content":[{"type":"tool_use","id":"t","name":"f","input":{}}],"stop_reason":"tool_use"}
    , "r"));
    try testing.expect(at(tool_only, .{ "choices", 0, "message", "content" }).? == .null);
}

test "response openai->anthropic" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const v = try parseTest(a, try translateResponse(a, .anthropic_to_openai, 200,
        \\{"id":"chatcmpl-9","object":"chat.completion","created":1700000000,"model":"gpt-real",
        \\ "choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":"Sure.",
        \\   "tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Rome\"}"}},
        \\                 {"id":"call_2","type":"function","function":{"name":"now","arguments":"not json"}}]}}],
        \\ "usage":{"prompt_tokens":50,"completion_tokens":9,"total_tokens":59,"prompt_tokens_details":{"cached_tokens":20}}}
    , "route-model"));
    try expectStrAt(v, .{"id"}, "msg_chatcmpl-9");
    try expectStrAt(v, .{"type"}, "message");
    try expectStrAt(v, .{"role"}, "assistant");
    try expectStrAt(v, .{"model"}, "route-model");
    try expectStrAt(v, .{"stop_reason"}, "tool_use");
    try testing.expect(at(v, .{"stop_sequence"}).? == .null);
    try expectLenAt(v, .{"content"}, 3);
    try expectStrAt(v, .{ "content", 0, "type" }, "text");
    try expectStrAt(v, .{ "content", 0, "text" }, "Sure.");
    try expectStrAt(v, .{ "content", 1, "type" }, "tool_use");
    try expectStrAt(v, .{ "content", 1, "id" }, "call_1");
    try expectStrAt(v, .{ "content", 1, "name" }, "get_weather");
    try expectStrAt(v, .{ "content", 1, "input", "city" }, "Rome");
    try expectStrAt(v, .{ "content", 2, "input", "_raw_arguments" }, "not json");
    try expectIntAt(v, .{ "usage", "input_tokens" }, 30);
    try expectIntAt(v, .{ "usage", "cache_read_input_tokens" }, 20);
    try expectIntAt(v, .{ "usage", "output_tokens" }, 9);

    const cases = [_][2][]const u8{
        .{ "stop", "end_turn" },
        .{ "length", "max_tokens" },
        .{ "content_filter", "refusal" },
        .{ "function_call", "tool_use" },
    };
    for (cases) |c| {
        const body = try std.fmt.allocPrint(a,
            \\{{"id":"x","choices":[{{"index":0,"finish_reason":"{s}","message":{{"role":"assistant","content":"ok"}}}}]}}
        , .{c[0]});
        const r = try parseTest(a, try translateResponse(a, .anthropic_to_openai, 200, body, "r"));
        try expectStrAt(r, .{"stop_reason"}, c[1]);
        try expectIntAt(r, .{ "usage", "input_tokens" }, 0);
    }

    try testing.expectError(error.InvalidJson, translateResponse(a, .anthropic_to_openai, 200, "<html>", "r"));
}

test "stop reason mapping" {
    try testing.expectEqualStrings("stop", finishFromStop("end_turn"));
    try testing.expectEqualStrings("stop", finishFromStop("stop_sequence"));
    try testing.expectEqualStrings("length", finishFromStop("max_tokens"));
    try testing.expectEqualStrings("tool_calls", finishFromStop("tool_use"));
    try testing.expectEqualStrings("content_filter", finishFromStop("refusal"));
    try testing.expectEqualStrings("end_turn", stopFromFinish("stop"));
    try testing.expectEqualStrings("max_tokens", stopFromFinish("length"));
    try testing.expectEqualStrings("tool_use", stopFromFinish("tool_calls"));
}

test "error envelopes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Anthropic upstream error, OpenAI client.
    const oa = try parseTest(a, try translateResponse(a, .openai_to_anthropic, 400,
        \\{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: too large"}}
    , "r"));
    try expectStrAt(oa, .{ "error", "message" }, "max_tokens: too large");
    try expectStrAt(oa, .{ "error", "type" }, "invalid_request_error");
    try expectStrAt(oa, .{ "error", "code" }, "invalid_request_error");
    try testing.expect(at(oa, .{ "error", "param" }).? == .null);

    // OpenAI upstream error, Anthropic client: type follows the status.
    const an = try parseTest(a, try translateResponse(a, .anthropic_to_openai, 429,
        \\{"error":{"message":"Rate limit reached","type":"requests","param":null,"code":"rate_limit_exceeded"}}
    , "r"));
    try expectStrAt(an, .{"type"}, "error");
    try expectStrAt(an, .{ "error", "type" }, "rate_limit_error");
    try expectStrAt(an, .{ "error", "message" }, "Rate limit reached");

    // Unparseable and empty bodies still produce a valid envelope.
    const html = try parseTest(a, try translateError(a, .anthropic_to_openai, 404, "<html>nope</html>\n"));
    try expectStrAt(html, .{ "error", "type" }, "not_found_error");
    try expectStrAt(html, .{ "error", "message" }, "<html>nope</html>");
    const empty = try parseTest(a, try translateError(a, .openai_to_anthropic, 503, ""));
    try expectStrAt(empty, .{ "error", "type" }, "server_error");
    try expectStrAt(empty, .{ "error", "message" }, "upstream returned HTTP 503");

    // A body that is not text used to come out as an array of numbers.
    for ([_]Direction{ .openai_to_anthropic, .anthropic_to_openai }) |dir| {
        const binary = try parseTest(a, try translateError(a, dir, 502, "\x1f\x8b\x08\x00\xff\xfe gzip, probably"));
        try expectStrAt(binary, .{ "error", "message" }, "upstream returned HTTP 502 with a body that is not valid text");
    }
    try testing.expect(at(empty, .{ "error", "code" }).? == .null);
    const str = try parseTest(a, try translateError(a, .anthropic_to_openai, 500, "{\"error\":\"boom\"}"));
    try expectStrAt(str, .{ "error", "type" }, "api_error");
    try expectStrAt(str, .{ "error", "message" }, "boom");
}

// --- streaming test support -------------------------------------------------

/// Run a translator over `input` cut into `step`-byte chunks.
fn runStream(a: Allocator, dir: Direction, opts: StreamOptions, input: []const u8, step: usize) ![]u8 {
    var out: Writer.Allocating = .init(a);
    var t: StreamTranslator = .init(a, dir, "route-model", opts);
    var i: usize = 0;
    while (i < input.len) : (i += step) {
        try t.feed(input[i..@min(i + step, input.len)], &out.writer);
    }
    try t.finish(&out.writer);
    // A second finish must be a no-op.
    try t.finish(&out.writer);
    return out.written();
}

/// Same output no matter how the input is chunked; returns that output.
fn runStreamAllSplits(a: Allocator, dir: Direction, opts: StreamOptions, input: []const u8) ![]u8 {
    const whole = try runStream(a, dir, opts, input, input.len);
    for ([_]usize{ 1, 2, 3, 7, 13, 64, 257 }) |step| {
        const split = try runStream(a, dir, opts, input, step);
        try testing.expectEqualStrings(whole, split);
    }
    return whole;
}

const SseEvent = struct { name: []const u8, data: []const u8 };

fn parseSse(a: Allocator, text: []const u8) ![]SseEvent {
    var events: std.ArrayList(SseEvent) = .empty;
    // Every event must be terminated by a blank line.
    try testing.expect(text.len == 0 or std.mem.endsWith(u8, text, "\n\n"));
    var it = std.mem.splitSequence(u8, text, "\n\n");
    while (it.next()) |block| {
        if (block.len == 0) continue;
        var ev: SseEvent = .{ .name = "", .data = "" };
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |l| {
            if (std.mem.cutPrefix(u8, l, "event: ")) |n| ev.name = n;
            if (std.mem.cutPrefix(u8, l, "data: ")) |d| ev.data = d;
        }
        try events.append(a, ev);
    }
    return events.items;
}

const OpenAiStream = struct {
    text: []const u8,
    role_chunks: usize,
    finish_reason: ?[]const u8,
    tool_ids: [4][]const u8,
    tool_names: [4][]const u8,
    tool_args: [4][]const u8,
    tools: usize,
    usage: ?Value,
    done: bool,
    errors: usize,
};

/// Reassemble an OpenAI chunk stream the way an SDK would.
fn readOpenAiStream(a: Allocator, text: []const u8) !OpenAiStream {
    var content: std.ArrayList(u8) = .empty;
    var args: [4]std.ArrayList(u8) = @splat(.empty);
    var r: OpenAiStream = .{
        .text = "",
        .role_chunks = 0,
        .finish_reason = null,
        .tool_ids = @splat(""),
        .tool_names = @splat(""),
        .tool_args = @splat(""),
        .tools = 0,
        .usage = null,
        .done = false,
        .errors = 0,
    };
    for (try parseSse(a, text)) |ev| {
        try testing.expectEqualStrings("", ev.name);
        try testing.expect(!r.done); // nothing after [DONE]
        if (eql(ev.data, "[DONE]")) {
            r.done = true;
            continue;
        }
        const v = try parseTest(a, ev.data);
        if (at(v, .{"error"}) != null) {
            r.errors += 1;
            continue;
        }
        try expectStrAt(v, .{"object"}, "chat.completion.chunk");
        try expectStrAt(v, .{"model"}, "route-model");
        try testing.expect(at(v, .{"id"}).?.string.len > 0);
        if (at(v, .{"usage"})) |u| {
            try expectLenAt(v, .{"choices"}, 0);
            r.usage = u;
            continue;
        }
        try expectLenAt(v, .{"choices"}, 1);
        const delta = at(v, .{ "choices", 0, "delta" }).?;
        if (at(delta, .{"role"})) |role| {
            try testing.expectEqualStrings("assistant", role.string);
            // The role chunk must come before any content.
            try testing.expectEqual(@as(usize, 0), content.items.len);
            r.role_chunks += 1;
        }
        if (at(delta, .{"content"})) |c| try content.appendSlice(a, c.string);
        if (at(delta, .{"tool_calls"})) |calls| {
            for (calls.array.items) |c| {
                const idx: usize = @intCast(at(c, .{"index"}).?.integer);
                r.tools = @max(r.tools, idx + 1);
                if (at(c, .{"id"})) |id| r.tool_ids[idx] = id.string;
                if (at(c, .{ "function", "name" })) |n| r.tool_names[idx] = n.string;
                if (at(c, .{ "function", "arguments" })) |s| try args[idx].appendSlice(a, s.string);
            }
        }
        const fr = at(v, .{ "choices", 0, "finish_reason" }).?;
        if (fr == .string) {
            try testing.expect(r.finish_reason == null);
            r.finish_reason = fr.string;
        }
    }
    r.text = content.items;
    for (0..4) |i| r.tool_args[i] = args[i].items;
    return r;
}

const AnthropicStream = struct {
    text: []const u8,
    stop_reason: ?[]const u8,
    tool_ids: [4][]const u8,
    tool_names: [4][]const u8,
    tool_args: [4][]const u8,
    tools: usize,
    blocks: usize,
    message_id: []const u8,
    input_tokens: i64,
    output_tokens: i64,
    stopped: bool,
    errors: usize,
};

/// Reassemble an Anthropic event stream, checking the event grammar:
/// message_start, (block start, deltas, block stop)*, message_delta,
/// message_stop, with block indexes counting up from 0.
fn readAnthropicStream(a: Allocator, text: []const u8) !AnthropicStream {
    var content: std.ArrayList(u8) = .empty;
    var args: [4]std.ArrayList(u8) = @splat(.empty);
    var r: AnthropicStream = .{
        .text = "",
        .stop_reason = null,
        .tool_ids = @splat(""),
        .tool_names = @splat(""),
        .tool_args = @splat(""),
        .tools = 0,
        .blocks = 0,
        .message_id = "",
        .input_tokens = 0,
        .output_tokens = 0,
        .stopped = false,
        .errors = 0,
    };
    var started = false;
    var open: ?i64 = null;
    var open_tool: ?usize = null;
    var delta_seen = false;

    for (try parseSse(a, text)) |ev| {
        const v = try parseTest(a, ev.data);
        const ty = at(v, .{"type"}).?.string;
        try testing.expectEqualStrings(ty, ev.name); // event: line matches data.type
        try testing.expect(!r.stopped and r.errors == 0); // nothing after the end

        if (eql(ty, "error")) {
            try testing.expect(at(v, .{ "error", "message" }).?.string.len > 0);
            r.errors += 1;
        } else if (eql(ty, "message_start")) {
            try testing.expect(!started);
            started = true;
            r.message_id = at(v, .{ "message", "id" }).?.string;
            try expectStrAt(v, .{ "message", "role" }, "assistant");
            try expectStrAt(v, .{ "message", "model" }, "route-model");
            try expectLenAt(v, .{ "message", "content" }, 0);
        } else if (eql(ty, "content_block_start")) {
            try testing.expect(started and open == null and !delta_seen);
            const idx = at(v, .{"index"}).?.integer;
            try testing.expectEqual(@as(i64, @intCast(r.blocks)), idx);
            open = idx;
            r.blocks += 1;
            const bt = at(v, .{ "content_block", "type" }).?.string;
            if (eql(bt, "tool_use")) {
                open_tool = r.tools;
                r.tool_ids[r.tools] = at(v, .{ "content_block", "id" }).?.string;
                r.tool_names[r.tools] = at(v, .{ "content_block", "name" }).?.string;
                try testing.expectEqual(@as(usize, 0), at(v, .{ "content_block", "input" }).?.object.count());
                r.tools += 1;
            } else {
                try testing.expectEqualStrings("text", bt);
                open_tool = null;
            }
        } else if (eql(ty, "content_block_delta")) {
            try testing.expectEqual(open.?, at(v, .{"index"}).?.integer);
            const dt = at(v, .{ "delta", "type" }).?.string;
            if (eql(dt, "text_delta")) {
                try testing.expect(open_tool == null);
                try content.appendSlice(a, at(v, .{ "delta", "text" }).?.string);
            } else {
                try testing.expectEqualStrings("input_json_delta", dt);
                try args[open_tool.?].appendSlice(a, at(v, .{ "delta", "partial_json" }).?.string);
            }
        } else if (eql(ty, "content_block_stop")) {
            try testing.expectEqual(open.?, at(v, .{"index"}).?.integer);
            open = null;
        } else if (eql(ty, "message_delta")) {
            try testing.expect(started and open == null and !delta_seen);
            delta_seen = true;
            r.stop_reason = at(v, .{ "delta", "stop_reason" }).?.string;
            r.input_tokens = at(v, .{ "usage", "input_tokens" }).?.integer;
            r.output_tokens = at(v, .{ "usage", "output_tokens" }).?.integer;
        } else if (eql(ty, "message_stop")) {
            try testing.expect(delta_seen);
            r.stopped = true;
        } else {
            return error.UnexpectedEvent;
        }
    }
    r.text = content.items;
    for (0..4) |i| r.tool_args[i] = args[i].items;
    return r;
}

const anthropic_stream =
    \\event: message_start
    \\data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-real","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":25,"cache_read_input_tokens":5,"output_tokens":1}}}
    \\
    \\event: content_block_start
    \\data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private"}}
    \\
    \\event: content_block_stop
    \\data: {"type":"content_block_stop","index":0}
    \\
    \\event: content_block_start
    \\data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
    \\
    \\: keep-alive comment
    \\
    \\event: ping
    \\data: {"type":"ping"}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":", wörld \"q\"\n — data: [DONE] 🙂"}}
    \\
    \\event: content_block_stop
    \\data: {"type":"content_block_stop","index":1}
    \\
    \\event: content_block_start
    \\data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01","name":"get_weather","input":{}}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":""}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":" \"Paris\"}"}}
    \\
    \\event: content_block_stop
    \\data: {"type":"content_block_stop","index":2}
    \\
    \\event: content_block_start
    \\data: {"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_02","name":"now","input":{}}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{}"}}
    \\
    \\event: content_block_stop
    \\data: {"type":"content_block_stop","index":3}
    \\
    \\event: message_delta
    \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":42}}
    \\
    \\event: message_stop
    \\data: {"type":"message_stop"}
    \\
    \\
;

test "stream anthropic upstream -> openai client" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const out = try runStreamAllSplits(a, .openai_to_anthropic, .{ .include_usage = true, .created = 1700000000 }, anthropic_stream);
    const r = try readOpenAiStream(a, out);
    try testing.expectEqual(@as(usize, 1), r.role_chunks);
    try testing.expectEqualStrings("Hello, wörld \"q\"\n — data: [DONE] 🙂", r.text);
    try testing.expect(std.mem.find(u8, out, "private") == null); // thinking dropped
    try testing.expectEqual(@as(usize, 2), r.tools);
    try testing.expectEqualStrings("toolu_01", r.tool_ids[0]);
    try testing.expectEqualStrings("get_weather", r.tool_names[0]);
    try testing.expectEqualStrings("{\"city\": \"Paris\"}", r.tool_args[0]);
    try testing.expectEqualStrings("toolu_02", r.tool_ids[1]);
    try testing.expectEqualStrings("now", r.tool_names[1]);
    try testing.expectEqualStrings("{}", r.tool_args[1]);
    try testing.expectEqualStrings("tool_calls", r.finish_reason.?);
    try testing.expect(r.done);
    try testing.expectEqual(@as(usize, 0), r.errors);
    try expectIntAt(r.usage.?, .{"prompt_tokens"}, 30);
    try expectIntAt(r.usage.?, .{"completion_tokens"}, 42);
    try expectIntAt(r.usage.?, .{"total_tokens"}, 72);
    try expectIntAt(r.usage.?, .{ "prompt_tokens_details", "cached_tokens" }, 5);

    // First event carries the id and `created`.
    const first = try parseTest(a, (try parseSse(a, out))[0].data);
    try expectStrAt(first, .{"id"}, "chatcmpl-msg_01");
    try expectIntAt(first, .{"created"}, 1700000000);

    // Without include_usage there is no usage chunk; everything else matches.
    const quiet = try readOpenAiStream(a, try runStreamAllSplits(a, .openai_to_anthropic, .{}, anthropic_stream));
    try testing.expect(quiet.usage == null);
    try testing.expectEqualStrings(r.text, quiet.text);
    try testing.expect(quiet.done);

    // CRLF line endings produce byte-identical output.
    const crlf = try std.mem.replaceOwned(u8, a, anthropic_stream, "\n", "\r\n");
    const out_crlf = try runStreamAllSplits(a, .openai_to_anthropic, .{ .include_usage = true, .created = 1700000000 }, crlf);
    try testing.expectEqualStrings(out, out_crlf);
}

test "stream anthropic upstream -> openai client: errors and truncation" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Mid-stream error event.
    const with_error =
        \\event: message_start
        \\data: {"type":"message_start","message":{"id":"msg_e","usage":{"input_tokens":1,"output_tokens":0}}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"par"}}
        \\
        \\event: error
        \\data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"IGNORED"}}
        \\
        \\
    ;
    const out = try runStreamAllSplits(a, .openai_to_anthropic, .{ .include_usage = true }, with_error);
    const r = try readOpenAiStream(a, out);
    try testing.expectEqualStrings("par", r.text);
    try testing.expectEqual(@as(usize, 1), r.errors);
    try testing.expect(!r.done and r.finish_reason == null and r.usage == null);
    try testing.expect(std.mem.find(u8, out, "overloaded_error") != null);

    // Upstream cut off before message_delta: an error, not a clean finish.
    const cut = with_error[0..std.mem.find(u8, with_error, "event: error").?];
    const r_cut = try readOpenAiStream(a, try runStreamAllSplits(a, .openai_to_anthropic, .{}, cut));
    try testing.expectEqualStrings("par", r_cut.text);
    try testing.expectEqual(@as(usize, 1), r_cut.errors);
    try testing.expect(!r_cut.done);

    // Cut off after message_delta but before message_stop: complete normally,
    // even when the last line has no trailing newline.
    const tail =
        \\event: message_start
        \\data: {"type":"message_start","message":{"id":"msg_t","usage":{"input_tokens":4,"output_tokens":0}}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}
        \\
        \\event: message_delta
        \\data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}
    ;
    const r_tail = try readOpenAiStream(a, try runStreamAllSplits(a, .openai_to_anthropic, .{ .include_usage = true }, tail));
    try testing.expectEqualStrings("ok", r_tail.text);
    try testing.expectEqualStrings("stop", r_tail.finish_reason.?);
    try testing.expect(r_tail.done);
    try expectIntAt(r_tail.usage.?, .{"total_tokens"}, 6);

    // Empty upstream body.
    const r_empty = try readOpenAiStream(a, try runStream(a, .openai_to_anthropic, .{}, "", 1));
    try testing.expectEqual(@as(usize, 1), r_empty.errors);
}

const openai_stream =
    \\data: {"id":"chatcmpl-77","object":"chat.completion.chunk","created":1700000000,"model":"gpt-real","choices":[{"index":0,"delta":{"role":"assistant","content":"","refusal":null},"logprobs":null,"finish_reason":null}],"usage":null}
    \\
    \\data: {"id":"chatcmpl-77","object":"chat.completion.chunk","created":1700000000,"model":"gpt-real","choices":[{"index":0,"delta":{"content":"Let me "},"finish_reason":null}],"usage":null}
    \\
    \\: OPENROUTER PROCESSING
    \\
    \\data: {"id":"chatcmpl-77","object":"chat.completion.chunk","created":1700000000,"model":"gpt-real","choices":[{"index":0,"delta":{"content":"chéck \"both\"\n🙂"},"finish_reason":null}],"usage":null}
    \\
    \\data: {"id":"chatcmpl-77","object":"chat.completion.chunk","created":1700000000,"model":"gpt-real","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}],"usage":null}
    \\
    \\data: {"id":"chatcmpl-77","object":"chat.completion.chunk","created":1700000000,"model":"gpt-real","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]},"finish_reason":null}],"usage":null}
    \\
    \\data: {"id":"chatcmpl-77","object":"chat.completion.chunk","created":1700000000,"model":"gpt-real","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Paris\"}"}}]},"finish_reason":null}],"usage":null}
    \\
    \\data: {"id":"chatcmpl-77","object":"chat.completion.chunk","created":1700000000,"model":"gpt-real","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"now","arguments":"{}"}}]},"finish_reason":null}],"usage":null}
    \\
    \\data: {"id":"chatcmpl-77","object":"chat.completion.chunk","created":1700000000,"model":"gpt-real","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":null}
    \\
    \\data: {"id":"chatcmpl-77","object":"chat.completion.chunk","created":1700000000,"model":"gpt-real","choices":[],"usage":{"prompt_tokens":60,"completion_tokens":21,"total_tokens":81,"prompt_tokens_details":{"cached_tokens":10}}}
    \\
    \\data: [DONE]
    \\
    \\
;

test "stream openai upstream -> anthropic client" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const out = try runStreamAllSplits(a, .anthropic_to_openai, .{}, openai_stream);
    const r = try readAnthropicStream(a, out);
    try testing.expectEqualStrings("msg_chatcmpl-77", r.message_id);
    try testing.expectEqualStrings("Let me chéck \"both\"\n🙂", r.text);
    try testing.expectEqual(@as(usize, 3), r.blocks);
    try testing.expectEqual(@as(usize, 2), r.tools);
    try testing.expectEqualStrings("call_a", r.tool_ids[0]);
    try testing.expectEqualStrings("get_weather", r.tool_names[0]);
    try testing.expectEqualStrings("{\"city\":\"Paris\"}", r.tool_args[0]);
    try testing.expectEqualStrings("call_b", r.tool_ids[1]);
    try testing.expectEqualStrings("now", r.tool_names[1]);
    try testing.expectEqualStrings("{}", r.tool_args[1]);
    try testing.expectEqualStrings("tool_use", r.stop_reason.?);
    try testing.expectEqual(@as(i64, 50), r.input_tokens); // 60 prompt - 10 cached
    try testing.expectEqual(@as(i64, 21), r.output_tokens);
    try testing.expect(r.stopped);
    try testing.expectEqual(@as(usize, 0), r.errors);

    const crlf = try std.mem.replaceOwned(u8, a, openai_stream, "\n", "\r\n");
    try testing.expectEqualStrings(out, try runStreamAllSplits(a, .anthropic_to_openai, .{}, crlf));
}

test "stream openai upstream -> anthropic client: edge cases" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // No [DONE], usage on the finish chunk, last line unterminated.
    const no_done =
        \\data: {"id":"c1","choices":[{"index":0,"delta":{"role":"assistant","content":"Hi"},"finish_reason":null}]}
        \\
        \\data: {"id":"c1","choices":[{"index":0,"delta":{"content":" there"},"finish_reason":null}]}
        \\
        \\data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"length"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}
    ;
    const r = try readAnthropicStream(a, try runStreamAllSplits(a, .anthropic_to_openai, .{}, no_done));
    try testing.expectEqualStrings("Hi there", r.text);
    try testing.expectEqualStrings("max_tokens", r.stop_reason.?);
    try testing.expectEqual(@as(i64, 3), r.input_tokens);
    try testing.expectEqual(@as(i64, 2), r.output_tokens);
    try testing.expect(r.stopped);

    // Truncated before any finish_reason: error event.
    const cut = no_done[0..std.mem.find(u8, no_done, "data: {\"id\":\"c1\",\"choices\":[{\"index\":0,\"delta\":{}").?];
    const r_cut = try readAnthropicStream(a, try runStreamAllSplits(a, .anthropic_to_openai, .{}, cut));
    try testing.expectEqualStrings("Hi there", r_cut.text);
    try testing.expectEqual(@as(usize, 1), r_cut.errors);
    try testing.expect(!r_cut.stopped);

    // Error object mid-stream.
    const with_error =
        \\data: {"id":"c2","choices":[{"index":0,"delta":{"content":"a"},"finish_reason":null}]}
        \\
        \\data: {"error":{"message":"The server had an error","type":"server_error"}}
        \\
        \\data: [DONE]
        \\
        \\
    ;
    const out_err = try runStreamAllSplits(a, .anthropic_to_openai, .{}, with_error);
    const r_err = try readAnthropicStream(a, out_err);
    try testing.expectEqual(@as(usize, 1), r_err.errors);
    try testing.expect(!r_err.stopped);
    try testing.expect(std.mem.find(u8, out_err, "The server had an error") != null);

    // Upstreams that reuse index 0 for every tool call are told apart by id;
    // text after a tool call opens a fresh text block.
    const same_index =
        \\data: {"id":"c3","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"t1","function":{"name":"f","arguments":"{\"a\":1}"}}]}}]}
        \\
        \\data: {"id":"c3","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"t2","function":{"name":"g","arguments":"{\"b\":2}"}}]}}]}
        \\
        \\data: {"id":"c3","choices":[{"index":0,"delta":{"content":"after"}}]}
        \\
        \\data: {"id":"c3","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        \\
        \\data: [DONE]
        \\
        \\
    ;
    const r_same = try readAnthropicStream(a, try runStreamAllSplits(a, .anthropic_to_openai, .{}, same_index));
    try testing.expectEqual(@as(usize, 2), r_same.tools);
    try testing.expectEqual(@as(usize, 3), r_same.blocks);
    try testing.expectEqualStrings("t2", r_same.tool_ids[1]);
    try testing.expectEqualStrings("{\"a\":1}", r_same.tool_args[0]);
    try testing.expectEqualStrings("{\"b\":2}", r_same.tool_args[1]);
    try testing.expectEqualStrings("after", r_same.text);
    try testing.expectEqualStrings("end_turn", r_same.stop_reason.?);

    // [DONE] with no chunks at all still yields a well-formed empty message.
    const r_done = try readAnthropicStream(a, try runStream(a, .anthropic_to_openai, .{}, "data: [DONE]\n\n", 5));
    try testing.expect(r_done.stopped);
    try testing.expectEqual(@as(usize, 0), r_done.blocks);

    // Empty upstream body.
    const r_empty = try readAnthropicStream(a, try runStream(a, .anthropic_to_openai, .{}, "", 1));
    try testing.expectEqual(@as(usize, 1), r_empty.errors);
}

test "stream: streamed and non-streamed translations agree" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The Anthropic stream above, as the equivalent complete message.
    const full = try parseTest(a, try translateResponse(a, .openai_to_anthropic, 200,
        \\{"id":"msg_01","content":[{"type":"text","text":"Hello, wörld \"q\"\n — data: [DONE] 🙂"},
        \\ {"type":"tool_use","id":"toolu_01","name":"get_weather","input":{"city":"Paris"}},
        \\ {"type":"tool_use","id":"toolu_02","name":"now","input":{}}],
        \\ "stop_reason":"tool_use","usage":{"input_tokens":25,"cache_read_input_tokens":5,"output_tokens":42}}
    , "route-model"));
    const streamed = try readOpenAiStream(a, try runStream(a, .openai_to_anthropic, .{ .include_usage = true }, anthropic_stream, 11));
    try expectStrAt(full, .{ "choices", 0, "message", "content" }, streamed.text);
    try expectStrAt(full, .{ "choices", 0, "finish_reason" }, streamed.finish_reason.?);
    try expectStrAt(full, .{ "choices", 0, "message", "tool_calls", 1, "id" }, streamed.tool_ids[1]);
    try expectIntAt(full, .{ "usage", "total_tokens" }, at(streamed.usage.?, .{"total_tokens"}).?.integer);
}

test "stream: oversized event is rejected, memory stays bounded per event" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var out: Writer.Allocating = .init(a);
    var t: StreamTranslator = .init(a, .openai_to_anthropic, "m", .{});
    const junk = try a.alloc(u8, 1024 * 1024);
    @memset(junk, 'x');
    var failed = false;
    for (0..8) |_| {
        t.feed(junk, &out.writer) catch |err| {
            try testing.expectEqual(error.EventTooLarge, err);
            failed = true;
            break;
        };
    }
    try testing.expect(failed);
}

// --- nothing a peer sends may panic ------------------------------------------
//
// Every byte translated here comes from a client or a provider, and a panic
// ends the whole process. These tests take well-formed samples and replace
// parts of them with values of the wrong type, missing keys, absurd numbers
// and deep nesting, many thousands of times. Errors are fine; a panic fails
// the test run.

fn fuzzJunk(a: Allocator, random: std.Random, depth: usize) Allocator.Error!Value {
    return switch (random.uintLessThan(u8, 16)) {
        0 => .null,
        1 => .{ .bool = random.boolean() },
        2 => .{ .integer = 0 },
        3 => .{ .integer = -1 },
        4 => .{ .integer = std.math.maxInt(i64) },
        5 => .{ .integer = std.math.minInt(i64) },
        6 => .{ .float = 1e300 },
        7 => .{ .float = -0.5 },
        8 => S(""),
        9 => S(([_][]const u8{ "text", "tool_use", "tool_result", "function", "image_url", "assistant", "user", "tool", "stop", "end_turn", "data:;base64,", "{\"a\":[" })[random.uintLessThan(usize, 12)]),
        10 => .{ .array = Array.init(a) },
        11 => .{ .object = .empty },
        12 => .{ .number_string = "123456789012345678901234567890" },
        else => blk: {
            if (depth > 3) break :blk .null;
            if (random.boolean()) {
                var arr = Array.init(a);
                for (0..random.uintLessThan(usize, 3)) |_| try arr.append(try fuzzJunk(a, random, depth + 1));
                break :blk .{ .array = arr };
            }
            var o: ObjectMap = .empty;
            for ([_][]const u8{ "type", "text", "id", "index", "function", "content", "usage", "delta" }) |k| {
                if (random.boolean()) try o.put(a, k, try fuzzJunk(a, random, depth + 1));
            }
            break :blk .{ .object = o };
        },
    };
}

fn fuzzMutate(a: Allocator, random: std.Random, v: Value, depth: usize) Allocator.Error!Value {
    if (random.uintLessThan(u8, 100) < 9) return fuzzJunk(a, random, depth);
    switch (v) {
        .object => |o| {
            var out: ObjectMap = .empty;
            var it = o.iterator();
            while (it.next()) |e| {
                if (random.uintLessThan(u8, 100) < 4) continue; // key missing
                try out.put(a, e.key_ptr.*, try fuzzMutate(a, random, e.value_ptr.*, depth + 1));
            }
            return .{ .object = out };
        },
        .array => |arr| {
            var out = Array.init(a);
            for (arr.items) |item| {
                const roll = random.uintLessThan(u8, 100);
                if (roll < 4) continue;
                try out.append(try fuzzMutate(a, random, item, depth + 1));
                if (roll > 96) try out.append(try fuzzMutate(a, random, item, depth + 1)); // repeated
            }
            return .{ .array = out };
        },
        else => return v,
    }
}

const fuzz_openai_request =
    \\{"model":"m","max_tokens":50,"temperature":0.2,"top_p":0.9,"stop":["x"],"stream":true,"stream_options":{"include_usage":true},
    \\"response_format":{"type":"json_schema","json_schema":{"name":"n","schema":{"type":"object","properties":{"a":{"type":"string"}}}}},
    \\"messages":[{"role":"system","content":"be brief"},{"role":"user","content":[{"type":"text","text":"hi"},
    \\{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]},
    \\{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"f","arguments":"{\"city\":\"Paris\"}"}}]},
    \\{"role":"tool","tool_call_id":"c1","content":"21C"}],
    \\"tools":[{"type":"function","function":{"name":"f","description":"d","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}],
    \\"tool_choice":{"type":"function","function":{"name":"f"}},"parallel_tool_calls":false,"user":"u"}
;
const fuzz_anthropic_request =
    \\{"model":"m","max_tokens":50,"temperature":0.2,"stop_sequences":["x"],"stream":true,"system":[{"type":"text","text":"be brief"}],
    \\"output_config":{"format":{"type":"json_schema","schema":{"type":"object"}}},"metadata":{"user_id":"u"},
    \\"messages":[{"role":"user","content":[{"type":"text","text":"hi"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]},
    \\{"role":"assistant","content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"t1","name":"f","input":{"city":"Paris"}}]},
    \\{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"21C"}]}]}],
    \\"tools":[{"name":"f","description":"d","input_schema":{"type":"object","properties":{"city":{"type":"string"}}}}],
    \\"tool_choice":{"type":"tool","name":"f","disable_parallel_tool_use":true}}
;
const fuzz_openai_response =
    \\{"id":"chatcmpl-1","object":"chat.completion","created":1,"model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"hello",
    \\"tool_calls":[{"id":"c1","type":"function","function":{"name":"f","arguments":"{\"city\":\"Paris\"}"}}]},"finish_reason":"tool_calls"}],
    \\"usage":{"prompt_tokens":11,"completion_tokens":6,"total_tokens":17,"prompt_tokens_details":{"cached_tokens":3}}}
;
const fuzz_anthropic_response =
    \\{"id":"msg_1","type":"message","role":"assistant","model":"m","content":[{"type":"thinking","thinking":"..."},{"type":"text","text":"hello"},
    \\{"type":"tool_use","id":"t1","name":"f","input":{"city":"Paris"}}],"stop_reason":"tool_use","stop_sequence":null,
    \\"usage":{"input_tokens":11,"output_tokens":6,"cache_read_input_tokens":3,"cache_creation_input_tokens":2}}
;
const fuzz_error_bodies = [_][]const u8{
    \\{"error":{"message":"bad","type":"invalid_request_error","param":"x","code":"c"}}
    ,
    \\{"type":"error","error":{"type":"overloaded_error","message":"busy"},"request_id":"r"}
    ,
};

fn fuzzOnce(a: Allocator, random: std.Random, sample: []const u8) ![]u8 {
    const v = try json.parseFromSliceLeaky(Value, a, sample, .{});
    return json.Stringify.valueAlloc(a, try fuzzMutate(a, random, v, 0), .{});
}

test "a stream with many tool calls does not keep every id it saw" {
    // The translator's long-lived memory, with room for a few ids but not
    // for thousands: before the fix each tool call left its id behind.
    const backing = try testing.allocator.alloc(u8, 512 * 1024);
    defer testing.allocator.free(backing);
    var fixed: std.heap.FixedBufferAllocator = .init(backing);
    var t: StreamTranslator = .init(fixed.allocator(), .anthropic_to_openai, "route-model", .{});

    var sink_buf: [4096]u8 = undefined;
    var sink: Writer.Discarding = .init(&sink_buf);
    var event_buf: [512]u8 = undefined;
    const long_id: [200]u8 = @splat('i');
    for (0..20_000) |i| {
        const event = try std.fmt.bufPrint(&event_buf, "data: {{\"id\":\"c\",\"choices\":[{{\"index\":0,\"delta\":{{\"tool_calls\":[{{\"index\":{d},\"id\":\"{s}{d}\",\"function\":{{\"name\":\"f\",\"arguments\":\"{{}}\"}}}}]}}}}]}}\n\n", .{ i, &long_id, i });
        try t.feed(event, &sink.writer);
    }
    try testing.expect(std.mem.endsWith(u8, t.upstream_tool_id, "19999"));
}

test "objects with too many members are not parsed into a tree" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var big: std.ArrayList(u8) = .empty;
    try big.appendSlice(a, "{\"model\":\"m\",\"max_tokens\":5,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"metadata\":{");
    for (0..guard.max_tree_members + 1) |i| {
        if (i > 0) try big.append(a, ',');
        try big.print(a, "\"k{d}\":1", .{i});
    }
    try big.appendSlice(a, "}}");
    try testing.expectError(error.InvalidJson, translateRequest(a, .anthropic_to_openai, big.items, "real"));
    try testing.expectError(error.InvalidJson, translateRequest(a, .openai_to_anthropic, big.items, "real"));

    // Hidden in a tool call's arguments string, it is kept as the string it
    // came as instead of being parsed.
    var args: std.ArrayList(u8) = .empty;
    try args.append(a, '{');
    for (0..guard.max_tree_members + 1) |i| {
        if (i > 0) try args.append(a, ',');
        try args.print(a, "\"k{d}\":1", .{i});
    }
    try args.append(a, '}');
    const input = try parseToolInput(a, args.items);
    try testing.expect(input.object.get("_raw_arguments") != null);
    try testing.expectEqual(@as(usize, 1), input.object.count());
}

test "keys chosen to collide in the JSON object's hash map never reach it" {
    // The review's attack: std's JSON object is a hash map with a fixed seed
    // (Wyhash, seed 0), so keys that share their low hash bits make every
    // insertion walk all the earlier ones. Its input, generated the same way.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const count = 6000;
    var keys: std.ArrayList(u8) = .empty;
    var found: usize = 0;
    var n: u64 = 0;
    while (found < count) : (n += 1) {
        var key: [10]u8 = undefined;
        var x = n;
        for (&key) |*c| {
            c.* = 'a' + @as(u8, @intCast(x & 15));
            x >>= 4;
        }
        const h: u32 = @truncate(std.hash.Wyhash.hash(0, &key));
        if (h & 0x3ff != 0) continue;
        if (found > 0) try keys.append(a, ',');
        try keys.print(a, "\"{s}\":0", .{&key});
        found += 1;
    }

    // As a client request: refused before a tree is built ...
    const request = try std.fmt.allocPrint(a, "{{\"model\":\"m\",\"max_tokens\":5,\"messages\":[{{\"role\":\"user\",\"content\":\"x\"}}],\"x\":{{{s}}}}}", .{keys.items});
    try testing.expect(!guard.jsonMembersOk(request, guard.max_tree_members));
    try testing.expectError(error.InvalidJson, translateRequest(a, .openai_to_anthropic, request, "tm"));
    try testing.expectError(error.InvalidJson, translateRequest(a, .anthropic_to_openai, request, "tm"));
    // ... as an upstream's answer ...
    const answer = try std.fmt.allocPrint(a, "{{\"id\":\"c\",\"choices\":[],\"x\":{{{s}}}}}", .{keys.items});
    try testing.expectError(error.InvalidJson, translateResponse(a, .anthropic_to_openai, 200, answer, "route"));
    // ... and as one event of an upstream's stream, which is skipped.
    const event = try std.fmt.allocPrint(a, "data: {{\"type\":\"ping\",\"x\":{{{s}}}}}\n\n", .{keys.items});
    var sink_buf: [1024]u8 = undefined;
    var sink: Writer.Discarding = .init(&sink_buf);
    var t: StreamTranslator = .init(a, .openai_to_anthropic, "route", .{});
    try t.feed(event, &sink.writer);
    try testing.expect(!t.started);
}

test "one event of an upstream's stream cannot take more than its cap to parse" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Two megabytes of zeros in one event: a tree of it is 180 MiB.
    var event: std.ArrayList(u8) = .empty;
    try event.appendSlice(a, "data: {\"type\":\"ping\",\"x\":[0");
    for (0..1024 * 1024) |_| try event.appendSlice(a, ",0");
    try event.appendSlice(a, "]}");
    try event.append(a, 10);
    try event.append(a, 10);

    var sink_buf: [1024]u8 = undefined;
    var sink: Writer.Discarding = .init(&sink_buf);
    var t: StreamTranslator = .init(a, .openai_to_anthropic, "route", .{});
    try testing.expectError(error.OutOfMemory, t.feed(event.items, &sink.writer));
    try testing.expect(t.scratch_cap.refused);
    try testing.expect(t.scratch_cap.held <= max_event_tree_bytes);

    // An ordinary stream is unaffected, and gives its parse memory back.
    var ok: StreamTranslator = .init(a, .openai_to_anthropic, "route", .{});
    try ok.feed("data: {\"type\":\"ping\"}", &sink.writer);
    try ok.feed(&.{ 10, 10 }, &sink.writer);
    try testing.expect(!ok.scratch_cap.refused);
    try testing.expect(ok.scratch_cap.held <= event_tree_retained_bytes);
}

test "fuzz: malformed requests and responses are errors, never panics" {
    var prng: std.Random.DefaultPrng = .init(0x6a756e6b);
    const random = prng.random();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    for (0..6000) |i| {
        _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();

        const o_req = try fuzzOnce(a, random, fuzz_openai_request);
        _ = translateRequest(a, .openai_to_anthropic, o_req, "target") catch {};
        const a_req = try fuzzOnce(a, random, fuzz_anthropic_request);
        _ = translateRequest(a, .anthropic_to_openai, a_req, "target") catch {};

        // Responses come from the upstream, i.e. in the OTHER protocol.
        const status: u16 = ([_]u16{ 200, 200, 200, 400, 429, 500 })[i % 6];
        const a_resp = try fuzzOnce(a, random, fuzz_anthropic_response);
        _ = translateResponseAt(a, .openai_to_anthropic, status, a_resp, "route", 1) catch {};
        const o_resp = try fuzzOnce(a, random, fuzz_openai_response);
        _ = translateResponseAt(a, .anthropic_to_openai, status, o_resp, "route", 1) catch {};

        const err_body = try fuzzOnce(a, random, fuzz_error_bodies[i % 2]);
        _ = translateError(a, .openai_to_anthropic, status, err_body) catch {};
        _ = translateError(a, .anthropic_to_openai, status, err_body) catch {};
        // And things that are not JSON at all.
        _ = translateResponseAt(a, .openai_to_anthropic, status, o_req[0 .. o_req.len / 2], "route", 1) catch {};
        _ = translateRequest(a, .anthropic_to_openai, "[1,2,3]", "target") catch {};
    }
}

/// Rewrite every `data:` line of an SSE stream with a mutated JSON payload.
fn fuzzStream(a: Allocator, random: std.Random, stream: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, stream, '\n');
    while (lines.next()) |line| {
        const roll = random.uintLessThan(u8, 100);
        if (roll < 2) continue; // a line lost
        if (std.mem.startsWith(u8, line, "data: {") and roll < 70) {
            const mutated = fuzzOnce(a, random, line["data: ".len..]) catch line["data: ".len..];
            try out.appendSlice(a, "data: ");
            try out.appendSlice(a, mutated);
        } else if (roll > 97) {
            try out.appendSlice(a, "data: {\"type\":");
        } else {
            try out.appendSlice(a, line);
        }
        try out.append(a, '\n');
    }
    // Sometimes the stream just stops.
    if (random.uintLessThan(u8, 100) < 15) out.shrinkRetainingCapacity(random.uintLessThan(usize, out.items.len + 1));
    return out.items;
}

test "fuzz: malformed event streams are errors, never panics" {
    var prng: std.Random.DefaultPrng = .init(0x73747265);
    const random = prng.random();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    for (0..3000) |i| {
        _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();
        const from_anthropic = i % 2 == 0;
        const text = try fuzzStream(a, random, if (from_anthropic) anthropic_stream else openai_stream);

        var out: Writer.Allocating = .init(a);
        var tr = StreamTranslator.init(a, if (from_anthropic) .openai_to_anthropic else .anthropic_to_openai, "route", .{ .include_usage = random.boolean(), .created = 1 });
        const step = 1 + random.uintLessThan(usize, 200);
        var pos: usize = 0;
        var failed = false;
        while (pos < text.len) : (pos += step) {
            tr.feed(text[pos..@min(text.len, pos + step)], &out.writer) catch {
                failed = true;
                break;
            };
        }
        if (!failed) tr.finish(&out.writer) catch {};
    }
}

test "deeply nested JSON is refused before it can reach the serialiser" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // 300 levels: beyond what std.json.Stringify can represent.
    var deep: std.ArrayList(u8) = .empty;
    try deep.appendSlice(a, "{\"model\":\"m\",\"max_tokens\":5,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"x\":");
    try deep.appendNTimes(a, '[', 300);
    try deep.appendNTimes(a, ']', 300);
    try deep.append(a, '}');
    try testing.expectError(error.InvalidJson, translateRequest(a, .anthropic_to_openai, deep.items, "t"));
    try testing.expectError(error.InvalidJson, translateRequest(a, .openai_to_anthropic, deep.items, "t"));
    try testing.expectError(error.InvalidJson, translateResponseAt(a, .openai_to_anthropic, 200, deep.items, "r", 1));

    // Tool-call arguments are JSON inside a string: too deep, they stay a string.
    var args: std.ArrayList(u8) = .empty;
    try args.appendNTimes(a, '[', 300);
    try args.appendNTimes(a, ']', 300);
    const body = try json.Stringify.valueAlloc(a, .{
        .model = "m",
        .messages = .{.{ .role = "assistant", .tool_calls = .{.{ .id = "c", .type = "function", .function = .{ .name = "f", .arguments = args.items } }} }},
    }, .{});
    const translated = try translateRequest(a, .openai_to_anthropic, body, "t");
    try testing.expect(std.mem.find(u8, translated, "_raw_arguments") != null);

    // Token counts are capped, so absurd ones cannot overflow sums or casts.
    const huge = "{\"type\":\"message\",\"content\":[{\"type\":\"text\",\"text\":\"x\"}],\"stop_reason\":\"end_turn\"," ++
        "\"usage\":{\"input_tokens\":9223372036854775807,\"output_tokens\":9223372036854775807," ++
        "\"cache_read_input_tokens\":9223372036854775807,\"cache_creation_input_tokens\":9223372036854775807}}";
    _ = try translateResponseAt(a, .openai_to_anthropic, 200, huge, "r", 1);
}
