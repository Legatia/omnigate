//! A look at a client's JSON request body without building a tree of it.
//!
//! The gateway needs three things from a request: which `model` it names,
//! whether it is a `stream`, and what `stream_options` it carries. Parsing
//! megabytes of client JSON into a value tree for that costs hundreds of
//! megabytes and, with keys chosen to collide in the tree's hash map, seconds
//! of CPU, before the request has been judged by any limit. So the body is
//! walked once, in place, with no allocation; the three values are located by
//! byte offset, and a same-protocol request is forwarded as the client's own
//! bytes with the model name spliced (see `rewrite`).
//!
//! Because the gateway then acts on one reading of the body while the
//! provider parses it again, the two readings must not be able to differ on
//! the fields the gateway acts on:
//!
//!   * the walker accepts only standard JSON structure (it is not lenient
//!     where a real parser is strict), so anything a provider would accept is
//!     read the same way here;
//!   * `model`, `stream` and `stream_options` may each appear once at the top
//!     level; a duplicate is refused, since parsers disagree on which wins;
//!   * a top-level key that only spells one of those names through escapes
//!     (`"mod\u0065l"`) is refused for the same reason;
//!   * so is a key that is one of those names to a parser that matches field
//!     names without regard to case (Go's encoding/json does, and takes the
//!     last match): `"Model"`, `"STREAM"`, and the letters Unicode folds onto
//!     ASCII ones (`"ſtream"`). The same holds for `include_usage` inside
//!     `stream_options`;
//!   * `stream` and `stream_options.include_usage` must be `true`, `false`
//!     or `null`: servers that coerce types read `"true"` or `1` as true
//!     where this module would read false.
//!
//! The same pass enforces the bounds that keep later, tree-building steps
//! (translation, the response cache) cheap: nesting depth, members per
//! object and key length.

const std = @import("std");

pub const Span = struct { start: usize, end: usize };

pub const Bounds = struct {
    max_depth: usize = 64,
    /// Members of any single object. Bounds the cost of hash-colliding keys
    /// wherever the body is later parsed into a tree.
    max_members: u32 = 65_536,
    max_key_len: usize = 8 * 1024,
};

pub const Top = struct {
    /// The `model` value with its quotes, as it stands in the body.
    model: ?Span = null,
    /// `"stream": true`. Anything else, or absent, is false.
    stream: bool = false,
    /// The whole `stream_options` value.
    stream_options: ?Span = null,
    /// `stream_options.include_usage`, when it could be read plainly.
    include_usage: bool = false,
    /// False when `stream_options` is not an object this module can splice
    /// safely (not an object, or `include_usage` duplicated or escaped): the
    /// caller then goes through a real parser to change it.
    stream_options_plain: bool = true,
    /// Offset of the brace that closes the top-level object.
    close: usize = 0,
    /// The largest number of members in any one object.
    max_members: u32 = 0,
};

pub const Error = error{
    /// Not well-formed JSON, or not an object at the top.
    InvalidJson,
    TooDeep,
    TooManyMembers,
    KeyTooLong,
    /// `model`, `stream` or `stream_options` given twice.
    DuplicateField,
    /// One of those names written with escapes.
    EscapedFieldName,
    /// One of those names (or `include_usage` in `stream_options`) in another
    /// letter case, or with letters that case folding maps onto its own.
    AmbiguousFieldName,
    /// `stream` or `stream_options.include_usage` that is not a boolean.
    InvalidFieldType,
};

const Name = enum { model, stream, stream_options, include_usage, other };

fn nameOf(text: []const u8) Name {
    if (std.mem.eql(u8, text, "model")) return .model;
    if (std.mem.eql(u8, text, "stream")) return .stream;
    if (std.mem.eql(u8, text, "stream_options")) return .stream_options;
    if (std.mem.eql(u8, text, "include_usage")) return .include_usage;
    return .other;
}

const Walker = struct {
    s: []const u8,
    i: usize = 0,
    bounds: Bounds,
    max_members: u32 = 0,

    const Str = struct { start: usize, end: usize, escaped: bool };

    fn ws(w: *Walker) void {
        while (w.i < w.s.len) : (w.i += 1) switch (w.s[w.i]) {
            ' ', '\t', '\r', '\n' => {},
            else => return,
        };
    }

    fn peek(w: *Walker) Error!u8 {
        if (w.i >= w.s.len) return error.InvalidJson;
        return w.s[w.i];
    }

    /// At an opening quote. Returns the contents' span; leaves `i` after the
    /// closing quote.
    fn string(w: *Walker) Error!Str {
        if (w.i >= w.s.len or w.s[w.i] != '"') return error.InvalidJson;
        w.i += 1;
        const start = w.i;
        var escaped = false;
        while (w.i < w.s.len) {
            const c = w.s[w.i];
            if (c == '"') {
                w.i += 1;
                return .{ .start = start, .end = w.i - 1, .escaped = escaped };
            }
            if (c < 0x20) return error.InvalidJson;
            if (c == '\\') {
                escaped = true;
                if (w.i + 1 >= w.s.len) return error.InvalidJson;
                switch (w.s[w.i + 1]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => w.i += 2,
                    'u' => {
                        if (w.i + 6 > w.s.len) return error.InvalidJson;
                        for (w.s[w.i + 2 .. w.i + 6]) |h| if (!std.ascii.isHex(h)) return error.InvalidJson;
                        w.i += 6;
                    },
                    else => return error.InvalidJson,
                }
                continue;
            }
            w.i += 1;
        }
        return error.InvalidJson;
    }

    fn number(w: *Walker) Error!void {
        const s = w.s;
        if (w.i < s.len and s[w.i] == '-') w.i += 1;
        if (w.i >= s.len) return error.InvalidJson;
        if (s[w.i] == '0') {
            w.i += 1;
        } else if (s[w.i] >= '1' and s[w.i] <= '9') {
            while (w.i < s.len and std.ascii.isDigit(s[w.i])) w.i += 1;
        } else return error.InvalidJson;
        if (w.i < s.len and s[w.i] == '.') {
            w.i += 1;
            const from = w.i;
            while (w.i < s.len and std.ascii.isDigit(s[w.i])) w.i += 1;
            if (w.i == from) return error.InvalidJson;
        }
        if (w.i < s.len and (s[w.i] == 'e' or s[w.i] == 'E')) {
            w.i += 1;
            if (w.i < s.len and (s[w.i] == '+' or s[w.i] == '-')) w.i += 1;
            const from = w.i;
            while (w.i < s.len and std.ascii.isDigit(s[w.i])) w.i += 1;
            if (w.i == from) return error.InvalidJson;
        }
    }

    fn literal(w: *Walker, comptime word: []const u8) Error!void {
        if (!std.mem.startsWith(u8, w.s[w.i..], word)) return error.InvalidJson;
        w.i += word.len;
    }

    /// Skip one complete value starting at `i` (after whitespace), nested to
    /// at most `depth_left` more levels.
    fn value(w: *Walker, depth_left: usize) Error!void {
        // Iterative: an explicit stack of "is this level an object" and its
        // member count, so hostile nesting cannot use the call stack.
        var is_object: [128]bool = undefined;
        var members: [128]u32 = undefined;
        var depth: usize = 0;
        const max = @min(depth_left, is_object.len);

        // What the walker expects next.
        var expect: enum { value, key_or_close, key, elem_or_close, after } = .value;
        while (true) {
            w.ws();
            switch (expect) {
                .value, .elem_or_close => {
                    const c = try w.peek();
                    if (expect == .elem_or_close and c == ']') {
                        w.i += 1;
                        depth -= 1;
                        expect = .after;
                        continue;
                    }
                    switch (c) {
                        '{', '[' => {
                            if (depth >= max) return error.TooDeep;
                            is_object[depth] = c == '{';
                            members[depth] = 0;
                            depth += 1;
                            w.i += 1;
                            expect = if (c == '{') .key_or_close else .elem_or_close;
                            continue;
                        },
                        '"' => _ = try w.string(),
                        '-', '0'...'9' => try w.number(),
                        't' => try w.literal("true"),
                        'f' => try w.literal("false"),
                        'n' => try w.literal("null"),
                        else => return error.InvalidJson,
                    }
                    expect = .after;
                },
                .key_or_close, .key => {
                    const c = try w.peek();
                    if (expect == .key_or_close and c == '}') {
                        w.i += 1;
                        depth -= 1;
                        expect = .after;
                        continue;
                    }
                    if (c != '"') return error.InvalidJson;
                    const k = try w.string();
                    if (k.end - k.start > w.bounds.max_key_len) return error.KeyTooLong;
                    members[depth - 1] += 1;
                    if (members[depth - 1] > w.bounds.max_members) return error.TooManyMembers;
                    w.max_members = @max(w.max_members, members[depth - 1]);
                    w.ws();
                    if (try w.peek() != ':') return error.InvalidJson;
                    w.i += 1;
                    expect = .value;
                },
                .after => {
                    if (depth == 0) return;
                    const c = try w.peek();
                    if (c == ',') {
                        w.i += 1;
                        expect = if (is_object[depth - 1]) .key else .value;
                    } else if ((c == '}' and is_object[depth - 1]) or (c == ']' and !is_object[depth - 1])) {
                        w.i += 1;
                        depth -= 1;
                    } else return error.InvalidJson;
                },
            }
        }
    }
};

/// What a key is to a parser that ignores case: its raw bytes, escapes
/// decoded and every character folded (ASCII letters to lower case, and the
/// few other characters Unicode case folding maps onto ASCII letters).
/// `.other` when that spells none of the names this module cares about.
fn foldedName(raw: []const u8) Name {
    // "stream_options" is the longest name: 14 characters. (The two
    // ligatures below are one character for two, hence the spare byte.)
    var buf: [15]u8 = undefined;
    return nameOf(foldInto(raw, &buf) orelse return .other);
}

/// Does `raw` (a key as it stands between its quotes) spell `name` (lower
/// case ASCII) to a parser that ignores case? True for the exact spelling
/// too. For callers that remove a member by name (privacy mode): what is
/// removed here must be everything a provider could read as that member.
pub fn folds(raw: []const u8, name: []const u8) bool {
    var buf: [40]u8 = undefined;
    std.debug.assert(name.len < buf.len);
    const folded = foldInto(raw, buf[0 .. name.len + 1]) orelse return false;
    return std.mem.eql(u8, folded, name);
}

/// `raw` folded into `buf`; null when it does not fit or holds a character
/// that folds onto nothing in ASCII.
fn foldInto(raw: []const u8, buf: []u8) ?[]const u8 {
    // Each character takes at most six bytes escaped.
    if (raw.len > buf.len * 6) return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        var cp: u21 = raw[i];
        if (cp == '\\') {
            // Only \uXXXX can spell a letter or an underscore.
            if (i + 6 > raw.len or raw[i + 1] != 'u') return null;
            cp = std.fmt.parseInt(u16, raw[i + 2 .. i + 6], 16) catch return null;
            i += 6;
        } else if (cp < 0x80) {
            i += 1;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(raw[i]) catch return null;
            if (i + len > raw.len) return null;
            cp = std.unicode.utf8Decode(raw[i..][0..len]) catch return null;
            i += len;
        }
        var one: [1]u8 = undefined;
        const folded: []const u8 = switch (cp) {
            0...0x7f => ascii: {
                one[0] = std.ascii.toLower(@intCast(cp));
                break :ascii &one;
            },
            0x017f => "s", // LATIN SMALL LETTER LONG S
            0x212a => "k", // KELVIN SIGN
            0xfb05, 0xfb06 => "st", // the ligatures "long s t" and "st"
            // Fullwidth forms are not case variants, but a parser that
            // normalises would read them as the letters.
            0xff21...0xff3a => wide: {
                one[0] = @as(u8, @intCast(cp - 0xff21)) + 'a';
                break :wide &one;
            },
            0xff41...0xff5a => wide: {
                one[0] = @as(u8, @intCast(cp - 0xff41)) + 'a';
                break :wide &one;
            },
            0xff3f => "_",
            else => return null,
        };
        if (n + folded.len > buf.len) return null;
        @memcpy(buf[n..][0..folded.len], folded);
        n += folded.len;
    }
    return buf[0..n];
}

/// `true`, `false` or `null` (which every parser reads as "not set").
fn flagValue(text: []const u8) Error!bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "null")) return false;
    return error.InvalidFieldType;
}

/// What a key's raw bytes (which contain escapes) decode to, when that could
/// be one of the names this module cares about; `.other` otherwise.
fn escapedName(raw: []const u8) Name {
    // "stream_options" is the longest; each of its 14 characters takes at
    // most six bytes escaped.
    if (raw.len > 14 * 6) return .other;
    var buf: [14 * 6]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        var c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            if (raw[i + 1] == 'u' and i + 6 <= raw.len) {
                const cp = std.fmt.parseInt(u16, raw[i + 2 .. i + 6], 16) catch return .other;
                // The names are ASCII; any other code point cannot spell them.
                if (cp > 0x7f) return .other;
                c = @intCast(cp);
                i += 6;
            } else {
                c = switch (raw[i + 1]) {
                    '"', '\\', '/' => raw[i + 1],
                    else => return .other,
                };
                i += 2;
            }
        } else i += 1;
        buf[n] = c;
        n += 1;
    }
    return nameOf(buf[0..n]);
}

/// Walk `body`, which must be one JSON object, and report what the gateway
/// needs from it. Nothing is allocated.
pub fn scan(body: []const u8, bounds: Bounds) Error!Top {
    var w: Walker = .{ .s = body, .bounds = bounds };
    var top: Top = .{};
    if (bounds.max_depth == 0) return error.TooDeep;

    w.ws();
    if (w.i >= body.len or body[w.i] != '{') return error.InvalidJson;
    w.i += 1;
    var members: u32 = 0;
    var seen_stream = false;
    var first = true;
    while (true) {
        w.ws();
        const c = try w.peek();
        if (c == '}' and first) break;
        if (c != '"') return error.InvalidJson;
        first = false;
        const k = try w.string();
        if (k.end - k.start > bounds.max_key_len) return error.KeyTooLong;
        members += 1;
        if (members > bounds.max_members) return error.TooManyMembers;
        const raw = body[k.start..k.end];
        const name: Name = if (k.escaped) blk: {
            if (escapedName(raw) != .other) return error.EscapedFieldName;
            switch (foldedName(raw)) {
                .model, .stream, .stream_options => return error.AmbiguousFieldName,
                .include_usage, .other => {},
            }
            break :blk .other;
        } else blk: {
            const exact = nameOf(raw);
            if (exact == .other or exact == .include_usage) switch (foldedName(raw)) {
                .model, .stream, .stream_options => return error.AmbiguousFieldName,
                .include_usage, .other => {},
            };
            break :blk exact;
        };

        w.ws();
        if (try w.peek() != ':') return error.InvalidJson;
        w.i += 1;
        w.ws();
        const vstart = w.i;
        try w.value(bounds.max_depth - 1);
        const span: Span = .{ .start = vstart, .end = w.i };
        switch (name) {
            .model => {
                if (top.model != null) return error.DuplicateField;
                top.model = span;
            },
            .stream => {
                if (seen_stream) return error.DuplicateField;
                seen_stream = true;
                top.stream = try flagValue(body[span.start..span.end]);
            },
            .stream_options => {
                if (top.stream_options != null) return error.DuplicateField;
                top.stream_options = span;
            },
            .include_usage, .other => {},
        }

        w.ws();
        const after = try w.peek();
        if (after == ',') {
            w.i += 1;
            // A comma must be followed by another member.
            w.ws();
            if (try w.peek() != '"') return error.InvalidJson;
            continue;
        }
        if (after != '}') return error.InvalidJson;
        break;
    }
    top.close = w.i;
    w.i += 1;
    w.ws();
    if (w.i != body.len) return error.InvalidJson;
    top.max_members = @max(w.max_members, members);

    if (top.stream_options) |so| try readStreamOptions(body[so.start..so.end], &top);
    return top;
}

/// `include_usage` inside a `stream_options` value that has already been
/// walked once (so it is well-formed).
fn readStreamOptions(text: []const u8, top: *Top) Error!void {
    var w: Walker = .{ .s = text, .bounds = .{} };
    if (text.len == 0 or text[0] != '{') {
        top.stream_options_plain = false;
        return;
    }
    w.i = 1;
    var seen = false;
    while (true) {
        w.ws();
        if ((w.peek() catch return) == '}') return;
        const k = w.string() catch return;
        const raw = text[k.start..k.end];
        const is_flag = if (k.escaped) escapedName(raw) == .include_usage else nameOf(raw) == .include_usage;
        // `Include_Usage`: the flag to a parser that ignores case, and not
        // to this one.
        if (!is_flag and foldedName(raw) == .include_usage) return error.AmbiguousFieldName;
        w.ws();
        w.i += 1; // the colon
        w.ws();
        const vstart = w.i;
        w.value(64) catch return;
        if (is_flag) {
            if (seen or k.escaped) {
                top.stream_options_plain = false;
                top.include_usage = false;
                return;
            }
            seen = true;
            top.include_usage = try flagValue(text[vstart..w.i]);
        }
        w.ws();
        if ((w.peek() catch return) == ',') w.i += 1;
    }
}

/// The request to send upstream: the client's own bytes with the `model`
/// value replaced by `model_json` (a complete JSON string, quotes included),
/// and, when `ask_for_usage`, `"stream_options":{"include_usage":true}`
/// added. `top` must come from `scan(body, ...)`, must have a `model`, and
/// for `ask_for_usage` must have no `stream_options` of its own.
pub fn rewrite(gpa: std.mem.Allocator, body: []const u8, top: Top, model_json: []const u8, ask_for_usage: bool) ![]u8 {
    const model = top.model.?;
    std.debug.assert(!ask_for_usage or top.stream_options == null);
    const addition: []const u8 = if (ask_for_usage) ",\"stream_options\":{\"include_usage\":true}" else "";
    const out = try gpa.alloc(u8, body.len - (model.end - model.start) + model_json.len + addition.len);
    var n: usize = 0;
    for ([_][]const u8{
        body[0..model.start],
        model_json,
        body[model.end..top.close],
        addition,
        body[top.close..],
    }) |part| {
        @memcpy(out[n..][0..part.len], part);
        n += part.len;
    }
    return out;
}

const testing = std.testing;

test "finds model, stream and stream_options without a tree" {
    const body =
        \\ {"messages":[{"role":"user","content":"say \"model\": {\"x\"} "}], "model" : "gpt-4o",
        \\  "stream": true, "stream_options": {"include_usage": true, "other": [1,2]}, "n": 1.5e3 }
    ;
    const top = try scan(body, .{});
    try testing.expectEqualStrings("\"gpt-4o\"", body[top.model.?.start..top.model.?.end]);
    try testing.expect(top.stream);
    try testing.expect(top.include_usage);
    try testing.expect(top.stream_options_plain);
    try testing.expectEqual(@as(u8, '}'), body[top.close]);
    try testing.expectEqual(@as(u32, 5), top.max_members);

    const quiet = try scan("{\"model\":\"m\",\"stream\":null}", .{});
    try testing.expect(!quiet.stream);
    try testing.expect(quiet.stream_options == null);
    try testing.expect((try scan("{}", .{})).model == null);
}

test "refuses what a provider's parser could read differently" {
    // Two models: which one counts depends on the parser.
    try testing.expectError(error.DuplicateField, scan("{\"model\":\"a\",\"model\":\"b\"}", .{}));
    try testing.expectError(error.DuplicateField, scan("{\"stream\":false,\"model\":\"a\",\"stream\":true}", .{}));
    try testing.expectError(error.DuplicateField, scan("{\"model\":\"a\",\"stream_options\":{},\"stream_options\":{}}", .{}));
    // A second model hidden behind escapes.
    try testing.expectError(error.EscapedFieldName, scan("{\"model\":\"a\",\"mod\\u0065l\":\"b\"}", .{}));
    try testing.expectError(error.EscapedFieldName, scan("{\"\\u0073tream\":true,\"model\":\"a\"}", .{}));
    // An escaped key that spells nothing of ours is the client's business.
    _ = try scan("{\"model\":\"a\",\"a\\/b\":1,\"caf\\u00e9\":2}", .{});
    // Nested, the names mean nothing.
    _ = try scan("{\"model\":\"a\",\"x\":{\"model\":\"b\",\"model\":\"c\"}}", .{});
}

test "a field name in another letter case is refused, as is a flag that is not a boolean" {
    // Go's encoding/json matches field names case-insensitively and lets the
    // last match win: to it every one of these names a model, or a stream.
    const ambiguous = [_][]const u8{
        "{\"model\":\"a\",\"Model\":\"b\"}",
        "{\"model\":\"a\",\"MODEL\":\"b\"}",
        "{\"Model\":\"b\"}",
        "{\"model\":\"a\",\"Stream\":true}",
        "{\"model\":\"a\",\"\xc5\xbftream\":true}", // long s
        "{\"model\":\"a\",\"\\u017ftream\":true}", // the same, escaped
        "{\"model\":\"a\",\"\xef\xac\x86ream\":true}", // the st ligature
        "{\"model\":\"a\",\"\xef\xac\x85ream_options\":{}}",
        "{\"model\":\"a\",\"Stream_Options\":{\"include_usage\":false}}",
        "{\"model\":\"a\",\"stream\":true,\"stream_options\":{\"Include_Usage\":false}}",
        "{\"model\":\"a\",\"stream_options\":{\"include_usage\":true,\"INCLUDE_USAGE\":false}}",
        "{\"model\":\"a\",\"stream_options\":{\"include_u\xc5\xbfage\":false}}",
        "{\"model\":\"a\",\"\xef\xbd\x8dodel\":\"b\"}", // fullwidth m
    };
    for (ambiguous) |b| try testing.expectError(error.AmbiguousFieldName, scan(b, .{}));
    // An ASCII letter written as an escape was refused before, and still is.
    try testing.expectError(error.EscapedFieldName, scan("{\"model\":\"a\",\"\\u006dodel\":\"b\"}", .{}));
    try testing.expectError(error.AmbiguousFieldName, scan("{\"model\":\"a\",\"\\u004dodel\":\"b\"}", .{}));

    const mistyped = [_][]const u8{
        "{\"model\":\"a\",\"stream\":\"true\"}",
        "{\"model\":\"a\",\"stream\":1}",
        "{\"model\":\"a\",\"stream\":[true]}",
        "{\"model\":\"a\",\"stream\":{}}",
        "{\"model\":\"a\",\"stream\":true,\"stream_options\":{\"include_usage\":\"false\"}}",
        "{\"model\":\"a\",\"stream_options\":{\"include_usage\":0}}",
    };
    for (mistyped) |b| try testing.expectError(error.InvalidFieldType, scan(b, .{}));

    // Other keys may be spelled however the client likes, at any depth.
    const fine = try scan("{\"model\":\"a\",\"Models\":1,\"streams\":2,\"x\":{\"Model\":\"b\",\"Stream\":\"yes\"},\"include_Usage\":3,\"stream\":false,\"stream_options\":{\"include_usage\":null,\"Other\":1}}", .{});
    try testing.expect(!fine.stream and !fine.include_usage and fine.stream_options_plain);

    // The same folding, for callers that match a name of their own.
    try testing.expect(folds("user", "user") and folds("User", "user") and folds("u\xc5\xbfer", "user") and folds("\\u0055ser", "user"));
    try testing.expect(folds("prompt_cache_\xe2\x84\xaaey", "prompt_cache_key"));
    try testing.expect(!folds("users", "user") and !folds("use", "user") and !folds("", "user") and !folds("us\\ner", "user"));
}

test "stream_options that cannot be spliced safely are flagged, not guessed" {
    const dup = try scan("{\"model\":\"a\",\"stream_options\":{\"include_usage\":false,\"include_usage\":true}}", .{});
    try testing.expect(!dup.stream_options_plain and !dup.include_usage);
    const esc = try scan("{\"model\":\"a\",\"stream_options\":{\"include_us\\u0061ge\":true}}", .{});
    try testing.expect(!esc.stream_options_plain and !esc.include_usage);
    const not_object = try scan("{\"model\":\"a\",\"stream_options\":null}", .{});
    try testing.expect(!not_object.stream_options_plain);
    const off = try scan("{\"model\":\"a\",\"stream_options\":{\"include_usage\":false}}", .{});
    try testing.expect(off.stream_options_plain and !off.include_usage);
}

test "only standard JSON is accepted" {
    const bad = [_][]const u8{
        "",                    "[]",                      "\"model\"",          "{",
        "{\"a\":1,}",          "{\"a\" 1}",               "{\"a\":}",           "{a:1}",
        "{'a':1}",             "{\"a\":01}",              "{\"a\":1.}",         "{\"a\":.5}",
        "{\"a\":+1}",          "{\"a\":1e}",              "{\"a\":tru}",        "{\"a\":\"\\x\"}",
        "{\"a\":\"\\u12g4\"}", "{\"a\":\"line\nbreak\"}", "{\"a\":[1,]}",       "{\"a\":[1 2]}",
        "{\"a\":{\"b\":1]}",   "{\"a\":1} x",             "{\"a\":1}{\"b\":2}", "{\"a\":\"unterminated}",
        "{\"a\":1,\"b\"}",     "{\"a\":[}",               "{,}",                "{\"a\":1 /* c */}",
    };
    for (bad) |b| try testing.expectError(error.InvalidJson, scan(b, .{}));

    const good = [_][]const u8{
        "{}",                                           " { } \n",
        "{\"a\":-0.5e-3,\"b\":[],\"c\":{},\"d\":null}", "{\"a\":[[[\"x\",true,false]]],\"b\":\"\\u00e9\\n\\\"\"}",
        "{\"a\":0,\"b\":10,\"c\":1E+2}",
    };
    for (good) |g| _ = try scan(g, .{});
}

test "bounds on depth, members and key length" {
    try testing.expectError(error.TooDeep, scan("{\"a\":[[[1]]]}", .{ .max_depth = 3 }));
    _ = try scan("{\"a\":[[[1]]]}", .{ .max_depth = 4 });
    try testing.expectError(error.TooManyMembers, scan("{\"a\":1,\"b\":2,\"c\":3}", .{ .max_members = 2 }));
    try testing.expectError(error.TooManyMembers, scan("{\"x\":{\"a\":1,\"b\":2,\"c\":3}}", .{ .max_members = 2 }));
    try testing.expectError(error.KeyTooLong, scan("{\"abcdef\":1}", .{ .max_key_len = 5 }));
    try testing.expectError(error.KeyTooLong, scan("{\"x\":{\"abcdef\":1}}", .{ .max_key_len = 5 }));

    // Hostile nesting never reaches the call stack or the walker's own arrays.
    var deep: [600]u8 = undefined;
    @memset(deep[0..300], '[');
    @memset(deep[300..], ']');
    var buf: [700]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"a\":{s}}}", .{deep});
    try testing.expectError(error.TooDeep, scan(body, .{ .max_depth = 1000 }));
}

test "rewrite splices the model and can ask for usage" {
    const gpa = testing.allocator;
    const body = " {\"messages\":[],\"model\":\"route\",\"stream\":true}\n";
    const top = try scan(body, .{});
    const plain = try rewrite(gpa, body, top, "\"real-model\"", false);
    defer gpa.free(plain);
    try testing.expectEqualStrings(" {\"messages\":[],\"model\":\"real-model\",\"stream\":true}\n", plain);
    const asked = try rewrite(gpa, body, top, "\"m\"", true);
    defer gpa.free(asked);
    try testing.expectEqualStrings(" {\"messages\":[],\"model\":\"m\",\"stream\":true,\"stream_options\":{\"include_usage\":true}}\n", asked);
    // What comes out is still one object with one model.
    const again = try scan(asked, .{});
    try testing.expect(again.include_usage and again.stream);
}

test "agrees with std's parser on random documents" {
    // Whatever std.json accepts as an object without duplicate keys, the
    // walker accepts too, and whatever the walker accepts, std accepts.
    var prng: std.Random.DefaultPrng = .init(0x6a736f6e);
    const random = prng.random();
    const gpa = testing.allocator;
    const alphabet = "{}[]\":,\\ \n0123456789.eE-+truefalsnu/abmodel";
    var buf: [48]u8 = undefined;
    var both: usize = 0;
    for (0..40_000) |_| {
        const n = random.intRangeAtMost(usize, 2, buf.len);
        buf[0] = '{';
        for (buf[1..n]) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        const text = buf[0..n];
        const ours = scan(text, .{}) catch null;
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{ .duplicate_field_behavior = .use_last });
        if (parsed) |p| {
            defer p.deinit();
            if (ours == null) {
                // The only documents std takes and the walker refuses are the
                // ones with a duplicated or escaped field of ours.
                const dup = scan(text, .{});
                try testing.expect(dup == error.DuplicateField or dup == error.EscapedFieldName or
                    dup == error.AmbiguousFieldName or dup == error.InvalidFieldType);
            } else both += 1;
        } else |_| {
            try testing.expect(ours == null);
        }
    }
    try testing.expect(both > 0);
}
