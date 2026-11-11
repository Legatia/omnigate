//! Privacy mode in the data plane: what a provider is not shown.
//!
//! Three things happen to a private request before it goes upstream, all on
//! the client's own bytes and without a tree of them:
//!
//!   * `redactBody` replaces e-mail addresses, phone numbers, payment card
//!     numbers, IP addresses and common secret formats in the request's text
//!     with placeholders (`[EMAIL_1]`, `[SECRET_2]`), the same value always
//!     by the same placeholder, numbered in order of first appearance. The
//!     numbering depends only on the text, so the same conversation gives
//!     the same placeholders on its next turn (and a provider's prompt cache
//!     still matches).
//!   * `Restorer` puts the originals back into the answer on its way to the
//!     client: a whole JSON answer in one pass, an event stream event by
//!     event, where a placeholder may be cut in two by the provider's
//!     chunking (`"[EMA"` in one delta, `"IL_1]"` in the next).
//!   * `editTop` removes members from the top level of the request (the
//!     fields that name an end user) or adds one (`"store": false`).
//!
//! What this is: pattern matching on text. It finds the shapes listed in
//! `Class`; it does not find names, street addresses, or anything written in
//! a way the patterns do not expect, and the provider still reads everything
//! else. The map from placeholder to original lives in the request's arena
//! and is gone with it.
//!
//! Where text is: the string values under the keys `content`, `text`,
//! `input`, `prompt`, `system`, `instructions`, `output` and `arguments`
//! (and the strings of an array under one of them, and every string inside
//! an object under `input` or `arguments`, which is a tool call's
//! arguments). Model names, tool definitions, ids, URLs and base64 data are
//! under other keys and are left alone.
//!
//! Cost: every pass is one walk over its input. Each detector looks a
//! bounded distance from where it is triggered, or consumes what it looked
//! at, so a megabyte of `@`, of digits or of `[EMAIL_` costs a megabyte of
//! work; the tests hold the scanner to that by counting, not by timing.

const std = @import("std");
const jsonscan = @import("jsonscan.zig");

/// What can be redacted. The config and the header name these in lower case.
pub const Class = enum(u3) {
    email,
    phone,
    card,
    ip,
    secret,

    pub const count = 5;
    pub const all = [count]Class{ .email, .phone, .card, .ip, .secret };

    /// As written in a placeholder.
    pub fn label(c: Class) []const u8 {
        return switch (c) {
            .email => "EMAIL",
            .phone => "PHONE",
            .card => "CARD",
            .ip => "IP",
            .secret => "SECRET",
        };
    }

    /// As written in the config, and in the name of a counter.
    pub fn name(c: Class) []const u8 {
        return switch (c) {
            .email => "email",
            .phone => "phone",
            .card => "card",
            .ip => "ip",
            .secret => "secret",
        };
    }

    pub fn parse(text: []const u8) ?Class {
        for (all) |c| if (std.mem.eql(u8, text, c.name())) return c;
        return null;
    }

    pub fn index(c: Class) usize {
        return @backingInt(c);
    }
};

pub const ClassSet = struct {
    bits: u8 = 0,

    pub const none: ClassSet = .{};
    pub const every: ClassSet = .{ .bits = (1 << Class.count) - 1 };

    pub fn has(s: ClassSet, c: Class) bool {
        return s.bits & (@as(u8, 1) << @backingInt(c)) != 0;
    }

    pub fn add(s: *ClassSet, c: Class) void {
        s.bits |= @as(u8, 1) << @backingInt(c);
    }

    pub fn isEmpty(s: ClassSet) bool {
        return s.bits == 0;
    }

    pub fn with(a: ClassSet, b: ClassSet) ClassSet {
        return .{ .bits = a.bits | b.bits };
    }
};

/// `[SECRET_16384]`.
const max_placeholder_len = 14;
/// A token (a key, a JWT) longer than this is not one.
const max_token_len = 8 * 1024;
/// A private key block is taken up to this length.
const max_pem_len = 16 * 1024;

pub const Entry = struct {
    class: Class,
    /// The value as it stood in the request: the bytes between the quotes of
    /// a JSON string, escapes and all.
    original: []const u8,
    /// `original` was inside a JSON string that is itself JSON text (a tool
    /// call's `arguments`), so its backslashes are doubled. Only kept apart
    /// from the plain form when there is a backslash at all.
    level2: bool,
    has_backslash: bool,
};

/// Placeholder to original, for one request.
pub const Map = struct {
    /// Seeds the index, so that values chosen to collide in it cannot be
    /// chosen at all.
    seed: u64 = 0,
    entries: std.ArrayList(Entry) = .empty,
    /// Entry indices per class: the n-th of a class is `[LABEL_n]`.
    by_class: [Class.count]std.ArrayList(u32) = @splat(.empty),
    index: Index = .empty,
    /// Values replaced per class, repeats included. (Text of the client's
    /// that already looked like a placeholder is mapped too, but not
    /// counted: nothing was hidden.)
    hits: [Class.count]u32 = @splat(0),

    /// Distinct values in one request. More is refused, not left in clear.
    pub const max_entries = 16_384;

    const Index = std.HashMapUnmanaged([]const u8, u32, Ctx, 80);
    const Ctx = struct {
        seed: u64,
        pub fn hash(ctx: Ctx, key: []const u8) u64 {
            return std.hash.Wyhash.hash(ctx.seed, key);
        }
        pub fn eql(_: Ctx, a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    };

    pub fn isEmpty(m: *const Map) bool {
        return m.entries.items.len == 0;
    }

    pub fn total(m: *const Map) u64 {
        var n: u64 = 0;
        for (m.hits) |h| n += h;
        return n;
    }

    /// The number of `original` within its class, new or known.
    fn intern(m: *Map, gpa: std.mem.Allocator, class: Class, original: []const u8, level2: bool) error{ OutOfMemory, TooManyRedactions }!u32 {
        const ctx: Ctx = .{ .seed = m.seed };
        const has_backslash = std.mem.findScalar(u8, original, '\\') != null;
        const l2 = level2 and has_backslash;
        const known = m.index.getContext(original, ctx);
        if (known) |at| {
            const e = m.entries.items[at];
            if (e.class == class and e.level2 == l2) return m.numberOf(at);
        }
        if (m.entries.items.len >= max_entries) return error.TooManyRedactions;
        const at: u32 = @intCast(m.entries.items.len);
        try m.entries.append(gpa, .{ .class = class, .original = original, .level2 = l2, .has_backslash = has_backslash });
        try m.by_class[class.index()].append(gpa, at);
        if (known == null) try m.index.putContext(gpa, original, at, ctx);
        return @intCast(m.by_class[class.index()].items.len);
    }

    fn numberOf(m: *const Map, at: u32) u32 {
        const list = m.by_class[m.entries.items[at].class.index()].items;
        // Entries of a class are appended in order: a binary search finds it.
        var lo: usize = 0;
        var hi: usize = list.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (list[mid] < at) lo = mid + 1 else hi = mid;
        }
        return @intCast(lo + 1);
    }

    fn lookup(m: *const Map, class: Class, n: u32) ?*const Entry {
        const list = m.by_class[class.index()].items;
        if (n == 0 or n > list.len) return null;
        return &m.entries.items[list[n - 1]];
    }
};

// ---------------------------------------------------------------------------
// Finding values in text
// ---------------------------------------------------------------------------

const Match = struct {
    start: usize,
    end: usize,
    class: Class,
    /// Text of the client's that is already shaped like a placeholder.
    literal: bool = false,
};

/// Character classes as tables: the loops below run once per byte of a
/// request, and a table lookup costs the same in every build mode.
fn table(comptime ranges: []const [2]u8, comptime singles: []const u8) [256]bool {
    var t: [256]bool = @splat(false);
    for (ranges) |r| {
        for (@as(usize, r[0])..@as(usize, r[1]) + 1) |c| t[c] = true;
    }
    for (singles) |c| t[c] = true;
    return t;
}

const alnum = [_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' } };
const word_chars = table(&alnum, "_");
const token_chars = table(&alnum, "_-");
const email_local_chars = table(&alnum, "._%+-");
const domain_chars = table(&alnum, ".-");
const hex_chars = table(&.{ .{ 'a', 'f' }, .{ 'A', 'F' }, .{ '0', '9' } }, "");
const ipv6_chars = table(&.{ .{ 'a', 'f' }, .{ 'A', 'F' }, .{ '0', '9' } }, ":.");

fn isWord(c: u8) bool {
    return word_chars[c];
}

fn isTokenChar(c: u8) bool {
    return token_chars[c];
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

const Placeholder = struct { class: Class, n: u32, len: usize };

/// `[LABEL_n]` at `at`, n written without a leading zero.
fn parsePlaceholder(t: []const u8, at: usize) ?Placeholder {
    if (at >= t.len or t[at] != '[') return null;
    // The shortest is `[IP_1]`; every label starts with a capital letter.
    if (at + 6 > t.len or t[at + 1] < 'A' or t[at + 1] > 'Z') return null;
    for (Class.all) |c| {
        const l = c.label();
        const digits_at = at + 1 + l.len + 1;
        if (digits_at >= t.len) continue;
        if (!std.mem.eql(u8, t[at + 1 ..][0..l.len], l) or t[at + 1 + l.len] != '_') continue;
        var i = digits_at;
        var n: u32 = 0;
        while (i < t.len and isDigit(t[i]) and i - digits_at < 5) : (i += 1) n = n * 10 + (t[i] - '0');
        if (i == digits_at or t[digits_at] == '0' or i >= t.len or t[i] != ']') return null;
        return .{ .class = c, .n = n, .len = i + 1 - at };
    }
    return null;
}

/// Is `s` the beginning of a placeholder that has not ended yet?
fn isPlaceholderPrefix(s: []const u8, classes_with_entries: ClassSet) bool {
    if (s.len == 0 or s[0] != '[') return false;
    for (Class.all) |c| {
        if (!classes_with_entries.has(c)) continue;
        const l = c.label();
        var full: [10]u8 = undefined;
        full[0] = '[';
        @memcpy(full[1..][0..l.len], l);
        full[1 + l.len] = '_';
        const head = full[0 .. l.len + 2];
        if (s.len <= head.len) {
            if (std.mem.startsWith(u8, head, s)) return true;
            continue;
        }
        if (!std.mem.startsWith(u8, s, head)) continue;
        const digits = s[head.len..];
        if (digits.len > 5 or digits[0] == '0') return false;
        for (digits) |d| if (!isDigit(d)) return false;
        return true;
    }
    return false;
}

fn luhn(digits: []const u8) bool {
    var sum: u32 = 0;
    var double = false;
    var i = digits.len;
    while (i > 0) {
        i -= 1;
        var d: u32 = digits[i];
        if (double) {
            d *= 2;
            if (d > 9) d -= 9;
        }
        sum += d;
        double = !double;
    }
    return sum % 10 == 0;
}

/// One pass over a piece of text (the inside of a JSON string, escapes
/// included), yielding what it finds from left to right.
const Scanner = struct {
    t: []const u8,
    enabled: ClassSet,
    i: usize = 0,
    /// Just past the most recent escape sequence the cursor stepped over:
    /// what follows an escape is the start of a word, whatever letter the
    /// escape ended in.
    esc_end: usize = std.math.maxInt(usize),
    /// The next e-mail address at or after the cursor, found ahead by its
    /// `@` (an address is recognised from the middle).
    email: ?Match = null,
    at_from: usize = 0,
    /// Bytes examined beyond the cursor's own steps. Bounded by a constant
    /// times the text's length; the tests check that.
    work: u64 = 0,

    /// What a byte can start. Most bytes start nothing, and the cursor steps
    /// over them without asking any detector.
    const Start = enum(u8) { nothing, letter, digit, other, escape };
    const starts: [256]Start = blk: {
        var t: [256]Start = @splat(.nothing);
        for ('a'..'z' + 1) |c| t[c] = .letter;
        for ('A'..'Z' + 1) |c| t[c] = .letter;
        for ('0'..'9' + 1) |c| t[c] = .digit;
        for ("[+(:-") |c| t[c] = .other;
        t['\\'] = .escape;
        break :blk t;
    };

    fn next(sc: *Scanner) ?Match {
        const t = sc.t;
        const emails = sc.enabled.has(.email);
        while (sc.i < t.len) {
            if (emails) {
                // (Only when the one found ahead has been used up, or passed.)
                if (sc.email == null and sc.at_from < t.len) sc.primeEmail();
                if (sc.email) |m| {
                    if (m.start == sc.i) {
                        sc.i = m.end;
                        sc.email = null;
                        return m;
                    }
                    if (m.start < sc.i) sc.email = null;
                }
            }
            const c = t[sc.i];
            const start = starts[c];
            if (start == .nothing) {
                sc.i += 1;
                continue;
            }
            if (start == .escape) {
                sc.i = @min(t.len, sc.i + @as(usize, if (sc.i + 1 < t.len and t[sc.i + 1] == 'u') 6 else 2));
                sc.esc_end = sc.i;
                continue;
            }
            const prev: u8 = if (sc.i == 0 or sc.i == sc.esc_end) ' ' else t[sc.i - 1];
            // Inside a word nothing starts: the common case for a letter.
            if (start != .other and isWord(prev)) {
                sc.i += 1;
                continue;
            }
            const cand: ?Match = switch (c) {
                '[' => sc.literal(),
                '0'...'9' => if (isWord(prev) or prev == '.' or prev == ':') null else sc.fromDigit(),
                '+' => if (isWord(prev) or prev == '+') null else sc.one(.phone, sc.phoneIntl()),
                '(' => if (isWord(prev)) null else sc.one(.phone, sc.phoneNanp()),
                ':' => if (isWord(prev) or prev == ':' or prev == '.') null else sc.one(.ip, sc.ipv6()),
                '-' => if (prev == '-') null else sc.one(.secret, sc.pem()),
                'A'...'Z', 'a'...'z' => if (isTokenChar(prev)) null else sc.fromLetter(prev),
                else => null,
            };
            if (cand) |m| {
                // An address the match would cut into wins: it is found
                // from its `@`, the match from its first character.
                const cut = if (sc.email) |e| m.end > e.start else false;
                if (!cut) {
                    sc.i = m.end;
                    return m;
                }
            }
            sc.i += 1;
        }
        return null;
    }

    fn one(sc: *Scanner, class: Class, end: ?Match) ?Match {
        const m = end orelse return null;
        if (!sc.enabled.has(class)) return null;
        return m;
    }

    fn span(sc: *Scanner, class: Class, end: ?usize) ?Match {
        const e = end orelse return null;
        return .{ .start = sc.i, .end = e, .class = class };
    }

    fn fromDigit(sc: *Scanner) ?Match {
        if (sc.enabled.has(.ip)) if (sc.span(.ip, sc.ipv4(sc.i))) |m| return m;
        if (sc.enabled.has(.card)) if (sc.span(.card, sc.card())) |m| return m;
        if (sc.enabled.has(.phone)) {
            if (sc.phoneNanp()) |m| return m;
            if (sc.span(.phone, sc.phoneTrunk())) |m| return m;
        }
        if (sc.enabled.has(.ip)) if (sc.ipv6()) |m| return m;
        return null;
    }

    fn fromLetter(sc: *Scanner, prev: u8) ?Match {
        const c = sc.t[sc.i];
        if (sc.enabled.has(.secret)) {
            if (secret_firsts[c]) if (sc.span(.secret, sc.secretToken())) |m| return m;
            if (c == 'b' or c == 'B') if (sc.bearer()) |m| return m;
            if (c == 'a' or c == 'A') if (sc.awsSecret()) |m| return m;
        }
        if (sc.enabled.has(.ip) and hex_chars[c] and prev != ':' and prev != '.') return sc.ipv6();
        return null;
    }

    // -- e-mail -------------------------------------------------------------

    fn primeEmail(sc: *Scanner) void {
        if (sc.email != null) return;
        const t = sc.t;
        var from = @max(sc.at_from, sc.i);
        const began = from;
        while (from < t.len) {
            // (A plain loop: where every other byte is an `@`, a search
            // call per `@` costs more than the bytes it skips.)
            if (t[from] != '@') {
                from += 1;
                continue;
            }
            const at = from;
            from += 1;
            // Cheapest test first: an address has something before its `@`.
            if (at == sc.i or !email_local_chars[t[at - 1]]) continue;
            if (sc.emailAround(at)) |m| {
                sc.email = m;
                sc.at_from = from;
                sc.work += from - began;
                return;
            }
        }
        sc.work += t.len - @min(t.len, began);
        sc.at_from = t.len;
    }

    fn emailAround(sc: *Scanner, at: usize) ?Match {
        const t = sc.t;
        const floor = sc.i;
        var s = at;
        while (s > floor and at - s < 65 and email_local_chars[t[s - 1]]) s -= 1;
        sc.work += at - s;
        // A local part longer than any real one: not an address.
        if (at - s >= 65) return null;
        // Stopped at a backslash: if that starts an escape, the escape's
        // letters are not part of the address (`\nbob@...`).
        if (s > floor and t[s - 1] == '\\') {
            var run: usize = 0;
            while (s - run > floor and t[s - 1 - run] == '\\') run += 1;
            sc.work += run;
            if (run % 2 == 1) s = @min(at, s + @as(usize, if (s < at and t[s] == 'u') 5 else 1));
        }
        while (s < at and t[s] == '.') s += 1;
        if (s == at) return null;

        // The domain first: it is what most strays lack.
        var e = at + 1;
        while (e < t.len and e - at <= 255 and domain_chars[t[e]]) e += 1;
        sc.work += e - at;
        if (e - at < 5) return null;
        while (e > at + 1 and (t[e - 1] == '.' or t[e - 1] == '-')) e -= 1;
        const domain = t[at + 1 .. e];
        if (domain.len < 4 or !std.ascii.isAlphanumeric(domain[0])) return null;
        const dot = std.mem.findScalarLast(u8, domain, '.') orelse return null;
        const tld = domain[dot + 1 ..];
        if (dot == 0 or domain[dot - 1] == '.' or tld.len < 2 or tld.len > 24) return null;
        for (tld) |c| if (!std.ascii.isAlphabetic(c)) return null;
        return .{ .start = s, .end = e, .class = .email };
    }

    // -- placeholders the client wrote itself ---------------------------------

    fn literal(sc: *Scanner) ?Match {
        const p = parsePlaceholder(sc.t, sc.i) orelse return null;
        if (!sc.enabled.has(p.class)) return null;
        return .{ .start = sc.i, .end = sc.i + p.len, .class = p.class, .literal = true };
    }

    // -- IP addresses ---------------------------------------------------------

    fn ipv4(sc: *Scanner, start: usize) ?usize {
        const t = sc.t;
        var i = start;
        var octet: usize = 0;
        while (octet < 4) : (octet += 1) {
            if (octet > 0) {
                if (i >= t.len or t[i] != '.') return null;
                i += 1;
            }
            var v: u32 = 0;
            var digits: usize = 0;
            while (i < t.len and isDigit(t[i]) and digits < 4) : (i += 1) {
                v = v * 10 + (t[i] - '0');
                digits += 1;
            }
            if (digits == 0 or digits > 3 or v > 255) return null;
        }
        if (i < t.len) {
            if (isWord(t[i])) return null;
            if (t[i] == '.' and i + 1 < t.len and isDigit(t[i + 1])) return null;
        }
        return i;
    }

    fn ipv6(sc: *Scanner) ?Match {
        const t = sc.t;
        const start = sc.i;
        var e = start;
        while (e < t.len and e - start <= 45 and ipv6_chars[t[e]]) e += 1;
        sc.work += e - start;
        if (e - start > 45 or e - start < 3) return null;
        if (e < t.len and isWord(t[e])) return null;
        // A full stop or a colon after it belongs to the sentence.
        if (e > start and t[e - 1] == '.') e -= 1;
        if (e - start >= 3 and t[e - 1] == ':' and t[e - 2] != ':') e -= 1;
        if (!validIpv6(t[start..e])) return null;
        return .{ .start = start, .end = e, .class = .ip };
    }

    // -- payment cards --------------------------------------------------------

    /// 13 to 19 digits that pass the Luhn check and start like a card (2-6),
    /// written together or in groups of four or more (4-4-4-4, 4-6-5).
    fn card(sc: *Scanner) ?usize {
        const t = sc.t;
        const start = sc.i;
        if (t[start] < '2' or t[start] > '6') return null;
        var digits: [19]u8 = undefined;
        var n: usize = 0;
        var i = start;
        var group: usize = 0;
        var groups: usize = 0;
        var shape_ok = true;
        // Places the number could end: (position, digits so far).
        var ends: [8][2]usize = undefined;
        var n_ends: usize = 0;
        var overflow = false;
        while (i < t.len) {
            const c = t[i];
            if (isDigit(c)) {
                if (n == digits.len) {
                    overflow = true;
                    break;
                }
                digits[n] = c - '0';
                n += 1;
                group += 1;
                i += 1;
            } else if ((c == ' ' or c == '-') and group > 0 and i + 1 < t.len and isDigit(t[i + 1])) {
                // Written together: the number ends here.
                if (groups == 0 and group >= 13) break;
                if ((groups == 0 and group != 4) or group < 4) shape_ok = false;
                if (!shape_ok) break;
                if (n >= 13 and n_ends < ends.len) {
                    ends[n_ends] = .{ i, n };
                    n_ends += 1;
                }
                groups += 1;
                group = 0;
                i += 1;
            } else break;
        }
        sc.work += i - start;
        if (!overflow and shape_ok and n >= 13 and !(i < t.len and isWord(t[i])) and n_ends < ends.len) {
            ends[n_ends] = .{ i, n };
            n_ends += 1;
        }
        while (n_ends > 0) {
            n_ends -= 1;
            const end = ends[n_ends];
            if (luhn(digits[0..end[1]])) return end[0];
        }
        return null;
    }

    // -- phone numbers --------------------------------------------------------

    fn isSep(c: u8) bool {
        return c == ' ' or c == '-' or c == '.';
    }

    fn digitsAt(t: []const u8, i: usize, n: usize) bool {
        if (i + n > t.len) return false;
        for (t[i .. i + n]) |c| if (!isDigit(c)) return false;
        return true;
    }

    /// `+` and 8 to 15 digits, with single spaces, dashes, dots or
    /// parentheses between groups.
    fn phoneIntl(sc: *Scanner) ?Match {
        const t = sc.t;
        const start = sc.i;
        var i = start + 1;
        if (i >= t.len or t[i] < '1' or t[i] > '9') return null;
        var digits: usize = 0;
        var last = i;
        var seps: usize = 0;
        while (i < t.len and i - start < 28) {
            const c = t[i];
            if (isDigit(c)) {
                digits += 1;
                if (digits > 15) return null;
                i += 1;
                last = i;
                seps = 0;
            } else if ((isSep(c) or c == '(' or c == ')') and seps < 2) {
                seps += 1;
                i += 1;
            } else break;
        }
        sc.work += i - start;
        if (digits < 8) return null;
        if (last < t.len and isDigit(t[last])) return null;
        return .{ .start = start, .end = last, .class = .phone };
    }

    /// North American shapes: `(555) 123-4567`, `555-123-4567`,
    /// `555.123.4567`, `555 123 4567`, each optionally after `1` and a
    /// separator.
    fn phoneNanp(sc: *Scanner) ?Match {
        const t = sc.t;
        const start = sc.i;
        var i = start;
        if (t[i] == '1' and i + 2 < t.len and isSep(t[i + 1]) and (isDigit(t[i + 2]) or t[i + 2] == '(')) i += 2;
        if (i < t.len and t[i] == '(') {
            if (!digitsAt(t, i + 1, 3) or i + 4 >= t.len or t[i + 4] != ')') return null;
            i += 5;
            if (i < t.len and t[i] == ' ') i += 1;
        } else {
            if (!digitsAt(t, i, 3) or i + 3 >= t.len or !isSep(t[i + 3])) return null;
            i += 4;
        }
        if (!digitsAt(t, i, 3) or i + 3 >= t.len or !isSep(t[i + 3])) return null;
        i += 4;
        if (!digitsAt(t, i, 4)) return null;
        i += 4;
        if (i < t.len) {
            if (isWord(t[i])) return null;
            if ((t[i] == '-' or t[i] == '.') and i + 1 < t.len and isDigit(t[i + 1])) return null;
        }
        return .{ .start = start, .end = i, .class = .phone };
    }

    /// National numbers written with a leading 0 and separators:
    /// `020 7946 0958`, `01 23 45 67 89`, `030 1234 5678`.
    fn phoneTrunk(sc: *Scanner) ?usize {
        const t = sc.t;
        const start = sc.i;
        if (t[start] != '0') return null;
        var i = start;
        var digits: usize = 0;
        var group: usize = 0;
        var groups: usize = 0;
        while (i < t.len and i - start < 24) {
            const c = t[i];
            if (isDigit(c)) {
                digits += 1;
                group += 1;
                if (digits > 11 or group > 8) return null;
                i += 1;
            } else if (isSep(c) and i + 1 < t.len and isDigit(t[i + 1])) {
                if (group < 2 or (groups == 0 and group > 5)) return null;
                groups += 1;
                group = 0;
                i += 1;
            } else break;
        }
        sc.work += i - start;
        if (digits < 9 or groups < 1 or group < 2) return null;
        if (i < t.len and isWord(t[i])) return null;
        return i;
    }

    // -- secrets --------------------------------------------------------------

    const Prefix = struct { text: []const u8, min: usize };
    const prefixes = [_]Prefix{
        .{ .text = "sk-", .min = 20 },     .{ .text = "sk_", .min = 20 },         .{ .text = "rk_live_", .min = 16 },
        .{ .text = "xai-", .min = 20 },    .{ .text = "r8_", .min = 20 },         .{ .text = "ghp_", .min = 20 },
        .{ .text = "gho_", .min = 20 },    .{ .text = "ghu_", .min = 20 },        .{ .text = "ghs_", .min = 20 },
        .{ .text = "ghr_", .min = 20 },    .{ .text = "github_pat_", .min = 20 }, .{ .text = "glpat-", .min = 16 },
        .{ .text = "hf_", .min = 20 },     .{ .text = "og-", .min = 20 },         .{ .text = "whsec_", .min = 16 },
        .{ .text = "xoxb-", .min = 10 },   .{ .text = "xoxa-", .min = 10 },       .{ .text = "xoxp-", .min = 10 },
        .{ .text = "xoxr-", .min = 10 },   .{ .text = "xoxs-", .min = 10 },       .{ .text = "AIza", .min = 30 },
        .{ .text = "npm_", .min = 30 },    .{ .text = "pypi-", .min = 30 },       .{ .text = "cfat_", .min = 20 },
        .{ .text = "gsk_", .min = 20 },    .{ .text = "pplx-", .min = 20 },       .{ .text = "shpat_", .min = 20 },
        .{ .text = "dop_v1_", .min = 20 },
    };

    /// The letters a token `secretToken` knows can start with.
    const secret_firsts: [256]bool = blk: {
        var t: [256]bool = @splat(false);
        for (prefixes) |p| t[p.text[0]] = true;
        // AKIA / ASIA / AIza, and a JWT's `eyJ`.
        t['A'] = true;
        t['e'] = true;
        break :blk t;
    };

    /// A provider key by its prefix, an AWS access key id, or a JWT.
    fn secretToken(sc: *Scanner) ?usize {
        const t = sc.t;
        const start = sc.i;
        const rest = t[start..];
        // AWS access key ids: AKIA/ASIA and 16 capitals or digits.
        if (rest.len >= 20 and (std.mem.startsWith(u8, rest, "AKIA") or std.mem.startsWith(u8, rest, "ASIA"))) {
            var ok = true;
            for (rest[4..20]) |c| {
                if (!(std.ascii.isUpper(c) or isDigit(c))) ok = false;
            }
            if (ok and !(rest.len > 20 and isTokenChar(rest[20]))) return start + 20;
        }
        if (std.mem.startsWith(u8, rest, "eyJ")) return sc.jwt();
        for (prefixes) |p| {
            if (rest[0] != p.text[0] or !std.mem.startsWith(u8, rest, p.text)) continue;
            var e = start + p.text.len;
            var digits: usize = 0;
            var upper: usize = 0;
            while (e < t.len and e - start <= max_token_len and isTokenChar(t[e])) : (e += 1) {
                if (isDigit(t[e])) digits += 1;
                if (std.ascii.isUpper(t[e])) upper += 1;
            }
            sc.work += e - start;
            const len = e - start - p.text.len;
            if (e - start > max_token_len or len < p.min) return null;
            // Random characters, not words joined by dashes: `sk-learn-...`
            // has no capital and few digits.
            if (digits < 2 or (upper == 0 and digits < 6)) return null;
            return e;
        }
        return null;
    }

    fn tokenRun(sc: *Scanner, from: usize, min: usize) ?usize {
        const t = sc.t;
        var e = from;
        while (e < t.len and e - from <= max_token_len and isTokenChar(t[e])) e += 1;
        sc.work += e - from;
        if (e - from < min or e - from > max_token_len) return null;
        return e;
    }

    /// Three base64url segments, the first starting `eyJ` (a JSON object).
    fn jwt(sc: *Scanner) ?usize {
        const t = sc.t;
        var e = sc.tokenRun(sc.i, 10) orelse return null;
        if (e >= t.len or t[e] != '.') return null;
        e = sc.tokenRun(e + 1, 8) orelse return null;
        if (e >= t.len or t[e] != '.') return null;
        return sc.tokenRun(e + 1, 4);
    }

    /// The token after `Bearer `.
    fn bearer(sc: *Scanner) ?Match {
        const t = sc.t;
        const word = "bearer ";
        if (sc.i + word.len > t.len or !std.ascii.eqlIgnoreCase(t[sc.i..][0..word.len], word)) return null;
        const from = sc.i + word.len;
        var e = from;
        var digits: usize = 0;
        while (e < t.len and e - from <= max_token_len) : (e += 1) {
            const c = t[e];
            if (!(isTokenChar(c) or c == '.' or c == '~' or c == '+' or c == '/' or c == '=')) break;
            if (isDigit(c)) digits += 1;
        }
        sc.work += e - from;
        if (e - from < 20 or e - from > max_token_len or digits == 0) return null;
        return .{ .start = from, .end = e, .class = .secret };
    }

    /// The 40 characters after `aws_secret_access_key` and its `=` or `:`.
    fn awsSecret(sc: *Scanner) ?Match {
        const t = sc.t;
        const word = "aws_secret_access_key";
        if (sc.i + word.len > t.len or !std.ascii.eqlIgnoreCase(t[sc.i..][0..word.len], word)) return null;
        var i = sc.i + word.len;
        var skipped: usize = 0;
        while (i < t.len and skipped < 8) : (skipped += 1) {
            if (t[i] == ' ' or t[i] == '=' or t[i] == ':' or t[i] == '\'') {
                i += 1;
            } else if (t[i] == '\\' and i + 1 < t.len and t[i + 1] == '"') {
                i += 2;
            } else break;
        }
        if (i == sc.i + word.len or i + 40 > t.len) return null;
        var digits: usize = 0;
        var upper: usize = 0;
        for (t[i .. i + 40]) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '+')) return null;
            if (isDigit(c)) digits += 1;
            if (std.ascii.isUpper(c)) upper += 1;
        }
        if (digits == 0 or upper == 0) return null;
        if (i + 40 < t.len and (std.ascii.isAlphanumeric(t[i + 40]) or t[i + 40] == '/' or t[i + 40] == '+' or t[i + 40] == '=')) return null;
        return .{ .start = i, .end = i + 40, .class = .secret };
    }

    /// `-----BEGIN ... PRIVATE KEY-----`, the base64 after it, and the END
    /// line if it is there (a key that was cut off is still a key).
    fn pem(sc: *Scanner) ?Match {
        const t = sc.t;
        const start = sc.i;
        const begin = "-----BEGIN ";
        const tail = "PRIVATE KEY-----";
        if (!std.mem.startsWith(u8, t[start..], begin)) return null;
        const window = t[start..@min(t.len, start + 64)];
        const head_end = (std.mem.find(u8, window, tail) orelse return null) + tail.len;
        var e = start + head_end;
        while (e < t.len and e - start < max_pem_len) {
            const c = t[e];
            if (std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=' or c == ' ') {
                e += 1;
            } else if (c == '\\' and e + 1 < t.len and (t[e + 1] == 'n' or t[e + 1] == 'r' or t[e + 1] == '\\')) {
                e += 2;
            } else break;
        }
        sc.work += e - start;
        const end = "-----END ";
        if (std.mem.startsWith(u8, t[e..], end)) {
            const closing = t[e..@min(t.len, e + 64)];
            if (std.mem.find(u8, closing, tail)) |at| e += at + tail.len;
        }
        return .{ .start = start, .end = e, .class = .secret };
    }
};

fn validIpv6(s: []const u8) bool {
    if (s.len < 3) return false;
    var groups: usize = 0;
    var double_colon = false;
    var has_digit = false;
    var i: usize = 0;
    // An IPv4 tail counts as two groups.
    var body = s;
    if (std.mem.findScalar(u8, s, '.') != null) {
        const colon = std.mem.findScalarLast(u8, s, ':') orelse return false;
        var probe: Scanner = .{ .t = s, .enabled = .every };
        const v4_end = probe.ipv4(colon + 1) orelse return false;
        if (v4_end != s.len) return false;
        groups += 2;
        has_digit = true;
        body = s[0 .. colon + 1];
        // "…:1.2.3.4": the colon stays only when it is half of a "::".
        if (body.len >= 2 and body[body.len - 2] != ':') body = body[0 .. body.len - 1];
    }
    if (body.len == 0) return false;
    if (body[0] == ':' and (body.len < 2 or body[1] != ':')) return false;
    while (i < body.len) {
        if (body[i] == ':') {
            if (i + 1 < body.len and body[i + 1] == ':') {
                if (double_colon) return false;
                double_colon = true;
                i += 2;
                continue;
            }
            // A single colon separates two groups: it needs one on each side.
            if (i == 0 or i + 1 == body.len) return false;
            i += 1;
            if (body[i] == ':') return false;
            continue;
        }
        var len: usize = 0;
        while (i < body.len and hex_chars[body[i]]) : (i += 1) {
            if (isDigit(body[i])) has_digit = true;
            len += 1;
        }
        if (len == 0 or len > 4) return false;
        groups += 1;
    }
    if (std.mem.count(u8, s, ":") < 2) return false;
    if (double_colon) {
        if (groups > 7 or groups == 0) return false;
    } else if (groups != 8) return false;
    return has_digit or groups >= 3;
}

// ---------------------------------------------------------------------------
// The request
// ---------------------------------------------------------------------------

pub const RedactError = error{ OutOfMemory, TooManyRedactions, InvalidJson };

const KeyKind = enum {
    none,
    /// Text when its value is a string, or an array of strings.
    text,
    /// The same, and every string inside when its value is an object
    /// (Anthropic's `tool_use.input`).
    text_deep,
    /// `arguments`: a string that is JSON text, or an object.
    args,
};

fn keyKind(raw: []const u8) KeyKind {
    const eql = std.mem.eql;
    if (eql(u8, raw, "content") or eql(u8, raw, "text") or eql(u8, raw, "prompt") or eql(u8, raw, "system") or
        eql(u8, raw, "instructions") or eql(u8, raw, "output")) return .text;
    if (eql(u8, raw, "input")) return .text_deep;
    if (eql(u8, raw, "arguments")) return .args;
    return .none;
}

/// Index of the quote that closes the string whose contents start at `from`.
fn stringEnd(t: []const u8, from: usize) ?usize {
    var i = from;
    while (i < t.len) : (i += 1) {
        switch (t[i]) {
            '"' => return i,
            '\\' => i += 1,
            else => {},
        }
    }
    return null;
}

fn skipWs(t: []const u8, from: usize) usize {
    var i = from;
    while (i < t.len and (t[i] == ' ' or t[i] == '\t' or t[i] == '\r' or t[i] == '\n')) i += 1;
    return i;
}

/// `body` (a JSON object that `jsonscan.scan` accepted) with the values of
/// the `enabled` classes in its text replaced by placeholders, which are
/// recorded in `map`. Returns `body` itself when nothing was found.
pub fn redactBody(gpa: std.mem.Allocator, body: []const u8, enabled: ClassSet, map: *Map) RedactError![]const u8 {
    if (enabled.isEmpty()) return body;
    const Treat = enum { normal, text_array, deep };
    var treat: [130]Treat = undefined;
    var is_object: [130]bool = undefined;
    var depth: usize = 0;
    var key: KeyKind = .none;

    var out: std.ArrayList(u8) = .empty;
    var copied: usize = 0;

    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        switch (c) {
            '{', '[' => {
                if (depth >= treat.len) return error.InvalidJson;
                const parent: Treat = if (depth == 0) .normal else treat[depth - 1];
                const in_object = depth > 0 and is_object[depth - 1];
                treat[depth] = if (parent == .deep)
                    .deep
                else if (in_object)
                    (if (c == '[' and key != .none) Treat.text_array else if (c == '{' and (key == .text_deep or key == .args)) Treat.deep else Treat.normal)
                else if (parent == .text_array and c == '[')
                    .text_array
                else
                    .normal;
                is_object[depth] = c == '{';
                depth += 1;
                key = .none;
                i += 1;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
                key = .none;
                i += 1;
            },
            '"' => {
                const s = i + 1;
                const e = stringEnd(body, s) orelse return error.InvalidJson;
                i = e + 1;
                const after = skipWs(body, i);
                if (depth > 0 and is_object[depth - 1] and after < body.len and body[after] == ':') {
                    key = keyKind(body[s..e]);
                    i = after + 1;
                    continue;
                }
                const frame: Treat = if (depth == 0) .normal else treat[depth - 1];
                const in_object = depth > 0 and is_object[depth - 1];
                const wanted = frame == .deep or (if (in_object) key != .none else frame == .text_array);
                const level2 = in_object and frame != .deep and key == .args;
                key = .none;
                if (!wanted or e == s) continue;

                var sc: Scanner = .{ .t = body[s..e], .enabled = enabled };
                while (sc.next()) |m| {
                    const original = body[s + m.start .. s + m.end];
                    const n = try map.intern(gpa, m.class, original, level2);
                    if (!m.literal) map.hits[m.class.index()] +|= 1;
                    if (out.capacity == 0) try out.ensureTotalCapacity(gpa, body.len + 256);
                    try out.appendSlice(gpa, body[copied .. s + m.start]);
                    var buf: [max_placeholder_len + 2]u8 = undefined;
                    try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "[{s}_{d}]", .{ m.class.label(), n }) catch unreachable);
                    copied = s + m.end;
                }
            },
            else => i += 1,
        }
    }
    if (out.capacity == 0) return body;
    try out.appendSlice(gpa, body[copied..]);
    return out.items;
}

/// Where the value that starts at `from` ends, in JSON that is well formed.
fn valueEnd(t: []const u8, from: usize) ?usize {
    if (from >= t.len) return null;
    switch (t[from]) {
        '"' => return (stringEnd(t, from + 1) orelse return null) + 1,
        '{', '[' => {
            var depth: usize = 0;
            var i = from;
            while (i < t.len) {
                switch (t[i]) {
                    '"' => i = stringEnd(t, i + 1) orelse return null,
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        depth -= 1;
                        if (depth == 0) return i + 1;
                    },
                    else => {},
                }
                i += 1;
            }
            return null;
        },
        else => {
            var i = from;
            while (i < t.len) : (i += 1) switch (t[i]) {
                ',', '}', ']', ' ', '\t', '\r', '\n' => break,
                else => {},
            };
            return if (i == from) null else i;
        },
    }
}

/// `body` (one JSON object) without the top-level members whose name is one
/// of `drop` to any parser (see `jsonscan.folds`), and with `append` (a
/// complete member, `"store":false`) added. Null when that changes nothing.
pub fn editTop(gpa: std.mem.Allocator, body: []const u8, drop: []const []const u8, append: []const u8) error{ OutOfMemory, InvalidJson }!?[]u8 {
    const open = skipWs(body, 0);
    if (open >= body.len or body[open] != '{') return error.InvalidJson;
    var kept: std.ArrayList([2]usize) = .empty;
    defer kept.deinit(gpa);
    var dropped = false;
    var i = skipWs(body, open + 1);
    var close: usize = undefined;
    if (i < body.len and body[i] == '}') {
        close = i;
    } else while (true) {
        if (i >= body.len or body[i] != '"') return error.InvalidJson;
        const key_end = stringEnd(body, i + 1) orelse return error.InvalidJson;
        const raw = body[i + 1 .. key_end];
        var j = skipWs(body, key_end + 1);
        if (j >= body.len or body[j] != ':') return error.InvalidJson;
        j = skipWs(body, j + 1);
        const value_end = valueEnd(body, j) orelse return error.InvalidJson;
        var gone = false;
        for (drop) |name| {
            if (jsonscan.folds(raw, name)) gone = true;
        }
        if (gone) dropped = true else try kept.append(gpa, .{ i, value_end });
        i = skipWs(body, value_end);
        if (i >= body.len) return error.InvalidJson;
        if (body[i] == '}') {
            close = i;
            break;
        }
        if (body[i] != ',') return error.InvalidJson;
        i = skipWs(body, i + 1);
    }
    if (!dropped and append.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, body.len + append.len + 1);
    out.appendSliceAssumeCapacity(body[0 .. open + 1]);
    for (kept.items, 0..) |member, n| {
        if (n > 0) out.appendAssumeCapacity(',');
        out.appendSliceAssumeCapacity(body[member[0]..member[1]]);
    }
    if (append.len > 0) {
        if (kept.items.len > 0) out.appendAssumeCapacity(',');
        out.appendSliceAssumeCapacity(append);
    }
    out.appendSliceAssumeCapacity(body[close..]);
    return try out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// The answer
// ---------------------------------------------------------------------------

/// The keys whose string value is a piece of generated text that continues
/// in the next event of a stream.
const DeltaKey = enum { none, content, text, arguments, partial_json, delta, thinking, reasoning_content, reasoning, refusal };

fn deltaKey(raw: []const u8) DeltaKey {
    const eql = std.mem.eql;
    if (eql(u8, raw, "content")) return .content;
    if (eql(u8, raw, "text")) return .text;
    if (eql(u8, raw, "arguments")) return .arguments;
    if (eql(u8, raw, "partial_json")) return .partial_json;
    if (eql(u8, raw, "delta")) return .delta;
    if (eql(u8, raw, "thinking")) return .thinking;
    if (eql(u8, raw, "reasoning_content")) return .reasoning_content;
    if (eql(u8, raw, "reasoning")) return .reasoning;
    if (eql(u8, raw, "refusal")) return .refusal;
    return .none;
}

/// Keys that say which of several interleaved pieces of text an event
/// continues (a choice, a content block, a tool call).
fn isPositionKey(raw: []const u8) bool {
    const eql = std.mem.eql;
    return eql(u8, raw, "index") or eql(u8, raw, "output_index") or eql(u8, raw, "content_index") or eql(u8, raw, "item_id");
}

pub const Restorer = struct {
    map: *const Map,
    /// Bytes the originals may add to one answer. A client can make a model
    /// repeat a placeholder; past this they are left as they are.
    budget: usize = 32 * 1024 * 1024,
    /// Placeholders replaced so far.
    restored: u64 = 0,
    classes: ClassSet = .none,

    // -- event streams --
    /// Bytes of a line that has not ended yet.
    pending: std.ArrayList(u8) = .empty,
    searched: usize = 0,
    /// An event that ends in what may be the first half of a placeholder,
    /// already restored, with any lines that came after it; it waits for
    /// the next event, which may bring the second half.
    held: std.ArrayList(u8) = .empty,
    held_tail: ?Tail = null,
    scratch: std.ArrayList(u8) = .empty,
    merged: std.ArrayList(u8) = .empty,
    /// Bytes examined looking for line ends; linear in what was fed.
    work: u64 = 0,

    /// A line longer than this is passed on as it is.
    const max_line = 4 * 1024 * 1024;
    /// Lines that follow a held event are held with it up to this.
    const max_held = 64 * 1024;

    const Tail = struct { key: DeltaKey, sig: u64, start: usize, end: usize };

    const Info = struct {
        ok: bool = true,
        sig: u64 = 0,
        /// Strings under a `DeltaKey` that end in a possible half placeholder.
        tails: u32 = 0,
        tail: ?Tail = null,
        /// Where the first string under the wanted key starts, in the input.
        target: ?usize = null,
    };

    pub fn init(map: *const Map) Restorer {
        var classes: ClassSet = .none;
        for (Class.all) |c| {
            if (map.by_class[c.index()].items.len > 0) classes.add(c);
        }
        return .{ .map = map, .classes = classes };
    }

    /// A whole answer (JSON, or whatever an upstream sent instead) with the
    /// originals back in place. Returns `doc` itself when nothing changed.
    pub fn restoreDoc(r: *Restorer, gpa: std.mem.Allocator, doc: []const u8) error{OutOfMemory}![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const before = r.restored;
        const info = try r.pass(gpa, doc, &out, .none);
        if (!info.ok) {
            out.clearRetainingCapacity();
            try r.restoreText(gpa, &out, doc, false);
        }
        return if (r.restored == before) doc else out.items;
    }

    /// The next bytes of an event stream; what can be passed on goes to `out`.
    pub fn feed(r: *Restorer, gpa: std.mem.Allocator, chunk: []const u8, out: *std.Io.Writer) !void {
        try r.pending.appendSlice(gpa, chunk);
        var start: usize = 0;
        while (true) {
            const from = @max(start, r.searched);
            const lf = std.mem.findScalarPos(u8, r.pending.items, from, '\n') orelse {
                r.work += r.pending.items.len - @min(r.pending.items.len, from);
                break;
            };
            r.work += lf + 1 - from;
            // (`line` gets a slice of `pending`, which is not touched until
            // the line has been dealt with.)
            try r.line(gpa, r.pending.items[start .. lf + 1], out);
            start = lf + 1;
            r.searched = start;
        }
        r.searched = r.pending.items.len;
        if (r.pending.items.len - start > max_line) {
            try r.release(out);
            try out.writeAll(r.pending.items[start..]);
            start = r.pending.items.len;
        }
        if (start == 0) return;
        const rest = r.pending.items.len - start;
        std.mem.copyForwards(u8, r.pending.items[0..rest], r.pending.items[start..]);
        r.pending.shrinkRetainingCapacity(rest);
        r.searched -= start;
    }

    /// The stream ended: pass on what was held.
    pub fn finish(r: *Restorer, gpa: std.mem.Allocator, out: *std.Io.Writer) !void {
        if (r.pending.items.len > 0) {
            const last = try gpa.dupe(u8, r.pending.items);
            defer gpa.free(last);
            r.pending.clearRetainingCapacity();
            r.searched = 0;
            try r.line(gpa, last, out);
        }
        try r.release(out);
    }

    fn release(r: *Restorer, out: *std.Io.Writer) !void {
        if (r.held.items.len > 0) try out.writeAll(r.held.items);
        r.held.clearRetainingCapacity();
        r.held_tail = null;
    }

    fn line(r: *Restorer, gpa: std.mem.Allocator, text: []const u8, out: *std.Io.Writer) !void {
        // `data: {...}` and its line end; anything else passes.
        const json_span: ?[2]usize = span: {
            if (!std.mem.startsWith(u8, text, "data:")) break :span null;
            var s: usize = 5;
            if (s < text.len and text[s] == ' ') s += 1;
            var e = text.len;
            while (e > s and (text[e - 1] == '\n' or text[e - 1] == '\r')) e -= 1;
            if (e <= s or text[s] != '{') break :span null;
            break :span .{ s, e };
        };
        const at = json_span orelse {
            if (r.held_tail != null and r.held.items.len + text.len <= max_held) {
                try r.held.appendSlice(gpa, text);
            } else {
                try r.release(out);
                try out.writeAll(text);
            }
            return;
        };
        var json = text[at[0]..at[1]];

        if (r.held_tail) |tail| {
            // Does this event go on where the held one stopped?
            const info = try r.pass(gpa, json, null, tail.key);
            if (info.ok and info.sig == tail.sig and info.target != null) {
                const t = info.target.?;
                r.merged.clearRetainingCapacity();
                try r.merged.appendSlice(gpa, json[0..t]);
                try r.merged.appendSlice(gpa, r.held.items[tail.start..tail.end]);
                try r.merged.appendSlice(gpa, json[t..]);
                json = r.merged.items;
                try out.writeAll(r.held.items[0..tail.start]);
                try out.writeAll(r.held.items[tail.end..]);
                r.held.clearRetainingCapacity();
                r.held_tail = null;
            } else try r.release(out);
        }

        r.scratch.clearRetainingCapacity();
        try r.scratch.appendSlice(gpa, text[0..at[0]]);
        var info = try r.pass(gpa, json, &r.scratch, .none);
        if (!info.ok) {
            r.scratch.shrinkRetainingCapacity(at[0]);
            try r.restoreText(gpa, &r.scratch, json, false);
        }
        try r.scratch.appendSlice(gpa, text[at[1]..]);
        if (info.ok and info.tails == 1) if (info.tail) |tail| {
            _ = &info;
            std.mem.swap(std.ArrayList(u8), &r.held, &r.scratch);
            r.held_tail = tail;
            return;
        };
        try out.writeAll(r.scratch.items);
    }

    /// One walk over a JSON document: every string value goes to `out` with
    /// its placeholders replaced (when `out` is given), and what `feed`
    /// needs to know about the document is collected.
    fn pass(r: *Restorer, gpa: std.mem.Allocator, doc: []const u8, out: ?*std.ArrayList(u8), want: DeltaKey) error{OutOfMemory}!Info {
        var info: Info = .{};
        var i: usize = 0;
        var copied: usize = 0;
        var key: DeltaKey = .none;
        var position_next = false;
        while (std.mem.findScalarPos(u8, doc, i, '"')) |q| {
            const s = q + 1;
            const e = stringEnd(doc, s) orelse {
                info.ok = false;
                return info;
            };
            i = e + 1;
            var j = skipWs(doc, i);
            if (j < doc.len and doc[j] == ':') {
                const raw = doc[s..e];
                key = deltaKey(raw);
                j = skipWs(doc, j + 1);
                if (isPositionKey(raw) and j < doc.len) {
                    if (doc[j] == '"') {
                        position_next = true;
                    } else if (doc[j] != '{' and doc[j] != '[') {
                        const end = valueEnd(doc, j) orelse doc.len;
                        info.sig = info.sig *% 0x9E3779B97F4A7C15 +% std.hash.Wyhash.hash(r.map.seed, doc[j..end]);
                    }
                }
                i = j;
                continue;
            }
            const k = key;
            key = .none;
            const content = doc[s..e];
            if (position_next) {
                position_next = false;
                info.sig = info.sig *% 0x9E3779B97F4A7C15 +% std.hash.Wyhash.hash(r.map.seed, content);
            }
            if (want != .none and k == want and info.target == null) info.target = s;
            if (out) |o| {
                try o.appendSlice(gpa, doc[copied..s]);
                try r.restoreText(gpa, o, content, k == .arguments or k == .partial_json);
                copied = e;
            }
            if (k != .none) {
                const tail = r.partialTail(content);
                if (tail > 0) {
                    info.tails += 1;
                    if (out) |o| info.tail = .{ .key = k, .sig = 0, .start = o.items.len - tail, .end = o.items.len };
                }
            }
        }
        if (out) |o| try o.appendSlice(gpa, doc[copied..]);
        if (info.tail) |*t| t.sig = info.sig;
        return info;
    }

    /// `text` to `out` with every placeholder this request made replaced by
    /// its original, written for where it lands: `level2` inside a string
    /// that is itself JSON text.
    fn restoreText(r: *Restorer, gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, level2: bool) error{OutOfMemory}!void {
        var i: usize = 0;
        var copied: usize = 0;
        while (std.mem.findScalarPos(u8, text, i, '[')) |p| {
            i = p + 1;
            const ph = parsePlaceholder(text, p) orelse continue;
            const entry = r.map.lookup(ph.class, ph.n) orelse continue;
            if (entry.original.len > r.budget) continue;
            r.budget -= entry.original.len;
            r.restored += 1;
            try out.appendSlice(gpa, text[copied..p]);
            try writeOriginal(gpa, out, entry, level2);
            copied = p + ph.len;
            i = copied;
        }
        try out.appendSlice(gpa, text[copied..]);
    }

    /// How many bytes at the end of `content` could be the start of a
    /// placeholder of this request; 0 when none.
    fn partialTail(r: *const Restorer, content: []const u8) usize {
        var k: usize = 1;
        while (k < max_placeholder_len and k <= content.len) : (k += 1) {
            const c = content[content.len - k];
            if (c == '[') return if (isPlaceholderPrefix(content[content.len - k ..], r.classes)) k else 0;
            if (!(std.ascii.isUpper(c) or isDigit(c) or c == '_')) return 0;
        }
        return 0;
    }
};

fn writeOriginal(gpa: std.mem.Allocator, out: *std.ArrayList(u8), entry: *const Entry, level2: bool) error{OutOfMemory}!void {
    const text = entry.original;
    if (!entry.has_backslash or entry.level2 == level2) return out.appendSlice(gpa, text);
    if (level2) {
        // Into JSON-in-a-string: every backslash once more.
        for (text) |c| {
            if (c == '\\') try out.append(gpa, '\\');
            try out.append(gpa, c);
        }
    } else {
        // Out of it: each doubled backslash once.
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == '\\') i += 1;
            try out.append(gpa, text[i]);
        }
    }
}

// ---------------------------------------------------------------------------
// The request header
// ---------------------------------------------------------------------------

/// What `x-omnigate-privacy` asks for. The header can only add protections
/// for one request; it has no way to say "less".
pub const Request = struct {
    no_store: bool = false,
    redact: bool = false,
    unlink: bool = false,

    /// `on` (or `true`, `1`): everything. Otherwise a comma-separated list
    /// of `no-store`, `redact`, `unlink`. Null for anything else.
    pub fn parse(value: []const u8) ?Request {
        const v = std.mem.trim(u8, value, " \t");
        if (v.len == 0 or v.len > 64) return null;
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(v, "on") or eq(v, "true") or eq(v, "1")) return .{ .no_store = true, .redact = true, .unlink = true };
        var out: Request = .{};
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |part| {
            const p = std.mem.trim(u8, part, " \t");
            if (eq(p, "no-store") or eq(p, "no_store")) {
                out.no_store = true;
            } else if (eq(p, "redact")) {
                out.redact = true;
            } else if (eq(p, "unlink")) {
                out.unlink = true;
            } else return null;
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn found(arena: std.mem.Allocator, text: []const u8, enabled: ClassSet) ![]const u8 {
    var sc: Scanner = .{ .t = text, .enabled = enabled };
    var out: std.ArrayList(u8) = .empty;
    while (sc.next()) |m| {
        if (out.items.len > 0) try out.append(arena, '|');
        try out.appendSlice(arena, m.class.name());
        try out.append(arena, ':');
        try out.appendSlice(arena, text[m.start..m.end]);
    }
    return out.items;
}

test "finds addresses, numbers and secrets, and leaves look-alikes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const all: ClassSet = .every;

    const cases = [_][2][]const u8{
        .{ "write to bob.smith+tag@example.co.uk today", "email:bob.smith+tag@example.co.uk" },
        .{ "a@b.com, c@d.org.", "email:a@b.com|email:c@d.org" },
        .{ "line\\nbob@example.com", "email:bob@example.com" },
        .{ "tab\\u0009eve@example.com", "email:eve@example.com" },
        .{ "back\\\\nslash@example.com", "email:nslash@example.com" },
        .{ "not@anaddress and @handle and a@b and x@y.z1", "" },
        .{ "call +1 (555) 123-4567 now", "phone:+1 (555) 123-4567" },
        .{ "call (555) 123-4567 or 555-123-4567 or 555.123.4567 or 1-555-123-4567", "phone:(555) 123-4567|phone:555-123-4567|phone:555.123.4567|phone:1-555-123-4567" },
        .{ "+44 20 7946 0958 and 020 7946 0958 and 01 23 45 67 89", "phone:+44 20 7946 0958|phone:020 7946 0958|phone:01 23 45 67 89" },
        .{ "2024-01-15 10:30:45 and 01.02.2024 and 5551234567 and 12:30", "" },
        .{ "card 4111 1111 1111 1111 exp", "card:4111 1111 1111 1111" },
        .{ "card 4111111111111111, amex 3782-822463-10005", "card:4111111111111111|card:3782-822463-10005" },
        .{ "4111111111111112 and 1700000000000 and 1234567890123456", "" },
        .{ "4111 1111 1111 1111 2024", "card:4111 1111 1111 1111" },
        .{ "host 192.168.1.10:8080 and 10.0.0.1.", "ip:192.168.1.10|ip:10.0.0.1" },
        .{ "999.1.1.1 and 1.2.3 and 1.2.3.4.5 and v1.2.3.4x", "" },
        .{ "from 2001:db8::1 and ::1 and fe80::1ff:fe23:4567:890a.", "ip:2001:db8::1|ip:::1|ip:fe80::1ff:fe23:4567:890a" },
        .{ "::ffff:192.168.0.1 ok", "ip:::ffff:192.168.0.1" },
        .{ "12:30:45 and aa:bb:cc:dd:ee:ff and std::vector and a::b and ::", "" },
        .{ "key sk-proj-Abc123Def456Ghi789Jkl012 end", "secret:sk-proj-Abc123Def456Ghi789Jkl012" },
        .{ "sk-learn-is-a-python-library-for-ml and sk-short1", "" },
        // (These three are written in pieces so that a secret scanner does
        // not take this file for a leak: AWS's documented example key pair,
        // a made-up GitHub token, a made-up key block.)
        .{ "AKIA" ++ "IOSFODNN7EXAMPLE and ghp" ++ "_Abcdefghij0123456789Abcdefghij012345", "secret:AKIA" ++ "IOSFODNN7EXAMPLE|secret:ghp" ++ "_Abcdefghij0123456789Abcdefghij012345" },
        .{ "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U.", "secret:eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U" },
        .{ "Authorization: Bearer abcdefghij0123456789xyz", "secret:abcdefghij0123456789xyz" },
        .{ "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG" ++ "/bPxRfiCYEXAMPLEKEY", "secret:wJalrXUtnFEMI/K7MDENG" ++ "/bPxRfiCYEXAMPLEKEY" },
        .{ "-----BEGIN RSA PRIVATE " ++ "KEY-----\\nMIIEow==\\n-----END RSA PRIVATE " ++ "KEY-----\\nafter", "secret:-----BEGIN RSA PRIVATE " ++ "KEY-----\\nMIIEow==\\n-----END RSA PRIVATE " ++ "KEY-----" },
        .{ "-----BEGIN PUBLIC KEY-----\\nMIIB\\n-----END PUBLIC KEY-----", "" },
        .{ "already [EMAIL_3] and [IP_12] but [EMAIL_03] [EMAIL_] [NAME_1] [EMAIL_1", "email:[EMAIL_3]|ip:[IP_12]" },
        .{ "5551234567@example.com", "email:5551234567@example.com" },
    };
    for (cases) |case| try testing.expectEqualStrings(case[1], try found(a, case[0], all));

    // Only the classes that are switched on.
    var some: ClassSet = .none;
    some.add(.email);
    try testing.expectEqualStrings("email:a@b.com", try found(a, "a@b.com 10.0.0.1 [IP_1] sk-proj-Abc123Def456Ghi789Jkl012", some));
    try testing.expectEqualStrings("", try found(a, "a@b.com 10.0.0.1", .none));
}

test "redacts text and tool arguments, not names, ids, urls or data" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var map: Map = .{ .seed = 7 };
    const body =
        \\{"model":"a@b.com","user":"u@x.com","messages":[{"role":"system","content":"mail a@b.com"},
        \\{"role":"user","name":"n@x.com","content":[{"type":"text","text":"again a@b.com and c@d.com"},{"type":"image_url","image_url":{"url":"data:image/png;base64,4111111111111111"}}]},
        \\{"role":"assistant","tool_calls":[{"id":"call_1@x.com","function":{"name":"send","arguments":"{\"to\":\"c@d.com\",\"ip\":\"10.0.0.1\"}"}}]},
        \\{"role":"tool","tool_call_id":"t","content":"sent to c@d.com"}],
        \\"tools":[{"type":"function","function":{"name":"send","description":"mail to x@y.com"}}]}
    ;
    const out = try redactBody(a, body, .every, &map);
    const expected =
        \\{"model":"a@b.com","user":"u@x.com","messages":[{"role":"system","content":"mail [EMAIL_1]"},
        \\{"role":"user","name":"n@x.com","content":[{"type":"text","text":"again [EMAIL_1] and [EMAIL_2]"},{"type":"image_url","image_url":{"url":"data:image/png;base64,4111111111111111"}}]},
        \\{"role":"assistant","tool_calls":[{"id":"call_1@x.com","function":{"name":"send","arguments":"{\"to\":\"[EMAIL_2]\",\"ip\":\"[IP_1]\"}"}}]},
        \\{"role":"tool","tool_call_id":"t","content":"sent to [EMAIL_2]"}],
        \\"tools":[{"type":"function","function":{"name":"send","description":"mail to x@y.com"}}]}
    ;
    try testing.expectEqualStrings(expected, out);
    try testing.expectEqual(@as(u32, 5), map.hits[Class.email.index()]);
    try testing.expectEqual(@as(u32, 1), map.hits[Class.ip.index()]);
    try testing.expectEqual(@as(usize, 3), map.entries.items.len);
    // Still one JSON object, with the same model.
    const top = try jsonscan.scan(out, .{});
    try testing.expectEqualStrings("\"a@b.com\"", out[top.model.?.start..top.model.?.end]);

    // Anthropic's shapes: system as blocks, tool_use input as an object,
    // tool_result content, and a base64 source that is not text.
    var m2: Map = .{};
    const anthropic =
        \\{"model":"m","system":[{"type":"text","text":"ops: ops@x.io"}],"messages":[{"role":"user","content":[{"type":"text","text":"hi"},
        \\{"type":"image","source":{"type":"base64","media_type":"image/png","data":"ops@x.io"}}]},
        \\{"role":"assistant","content":[{"type":"tool_use","id":"tu","name":"f","input":{"to":"ops@x.io","n":[{"deep":"10.1.1.1"}]}}]},
        \\{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu","content":[{"type":"text","text":"ok ops@x.io"}]}]}],"metadata":{"user_id":"ops@x.io"}}
    ;
    const out2 = try redactBody(a, anthropic, .every, &m2);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out2, "[EMAIL_1]"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out2, "[IP_1]"));
    try testing.expect(std.mem.find(u8, out2, "\"data\":\"ops@x.io\"") != null);
    try testing.expect(std.mem.find(u8, out2, "\"user_id\":\"ops@x.io\"") != null);

    // Other endpoints: a prompt, an input string, an array of inputs.
    var m3: Map = .{};
    try testing.expectEqualStrings("{\"model\":\"m\",\"prompt\":\"to [EMAIL_1]\"}", try redactBody(a, "{\"model\":\"m\",\"prompt\":\"to a@b.com\"}", .every, &m3));
    try testing.expectEqualStrings("{\"input\":[\"[EMAIL_1]\",\"[EMAIL_2]\"],\"instructions\":\"cc [EMAIL_2]\"}", try redactBody(a, "{\"input\":[\"a@b.com\",\"x@y.org\"],\"instructions\":\"cc x@y.org\"}", .every, &m3));

    // Nothing found: the same slice comes back.
    var m4: Map = .{};
    const plain = "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}";
    try testing.expectEqual(plain.ptr, (try redactBody(a, plain, .every, &m4)).ptr);
    try testing.expect(m4.isEmpty());

    // The same text gives the same placeholders again (a provider's prompt
    // cache sees the same prefix on the next turn).
    var m5: Map = .{ .seed = 99 };
    try testing.expectEqualStrings(expected, try redactBody(a, body, .every, &m5));
}

test "what the client wrote like a placeholder comes back as it wrote it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var map: Map = .{};
    const body = "{\"messages\":[{\"role\":\"user\",\"content\":\"literal [EMAIL_1] then real z@z.com\"}]}";
    const out = try redactBody(a, body, .every, &map);
    try testing.expectEqualStrings("{\"messages\":[{\"role\":\"user\",\"content\":\"literal [EMAIL_1] then real [EMAIL_2]\"}]}", out);
    try testing.expectEqual(@as(u32, 1), map.hits[Class.email.index()]);
    var r: Restorer = .init(&map);
    try testing.expectEqualStrings("{\"content\":\"z@z.com and [EMAIL_1] and [EMAIL_3]\"}", try r.restoreDoc(a, "{\"content\":\"[EMAIL_2] and [EMAIL_1] and [EMAIL_3]\"}"));
}

test "too many distinct values are refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "{\"prompt\":\"");
    for (0..Map.max_entries + 1) |n| try text.print(a, "u{d}@x.io ", .{n});
    try text.appendSlice(a, "\"}");
    var map: Map = .{};
    try testing.expectError(error.TooManyRedactions, redactBody(a, text.items, .every, &map));
}

test "restores a whole answer, at both levels of escaping" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var map: Map = .{};
    const body =
        \\{"messages":[{"role":"user","content":"a@b.com 10.0.0.1 -----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"}]}
    ;
    const sent = try redactBody(a, body, .every, &map);
    try testing.expectEqualStrings("{\"messages\":[{\"role\":\"user\",\"content\":\"[EMAIL_1] [IP_1] [SECRET_1]\"}]}", sent);

    var r: Restorer = .init(&map);
    const answer =
        \\{"id":"x","choices":[{"message":{"content":"mail [EMAIL_1] at [IP_1], key [SECRET_1], unknown [EMAIL_9]","tool_calls":[{"function":{"name":"f","arguments":"{\"to\":\"[EMAIL_1]\",\"key\":\"[SECRET_1]\"}"}}]}}]}
    ;
    const expected =
        \\{"id":"x","choices":[{"message":{"content":"mail a@b.com at 10.0.0.1, key -----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----, unknown [EMAIL_9]","tool_calls":[{"function":{"name":"f","arguments":"{\"to\":\"a@b.com\",\"key\":\"-----BEGIN PRIVATE KEY-----\\nAAAA\\n-----END PRIVATE KEY-----\"}"}}]}}]}
    ;
    const restored = try r.restoreDoc(a, answer);
    try testing.expectEqualStrings(expected, restored);
    // Both are still JSON, and the inner arguments too.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, restored, .{});
    const args = parsed.object.get("choices").?.array.items[0].object.get("message").?.object.get("tool_calls").?.array.items[0].object.get("function").?.object.get("arguments").?.string;
    const inner = try std.json.parseFromSliceLeaky(std.json.Value, a, args, .{});
    try testing.expectEqualStrings("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----", inner.object.get("key").?.string);

    // Not JSON at all (an HTML error page): replaced as plain text.
    var r2: Restorer = .init(&map);
    try testing.expectEqualStrings("<p>bad \"a@b.com</p>", try r2.restoreDoc(a, "<p>bad \"[EMAIL_1]</p>"));
    // Nothing to do: the same slice.
    const same = "{\"content\":\"nothing here [x]\"}";
    try testing.expectEqual(same.ptr, (try r2.restoreDoc(a, same)).ptr);

    // The budget: past it placeholders stay.
    var r3: Restorer = .init(&map);
    r3.budget = 10;
    try testing.expectEqualStrings("{\"content\":\"a@b.com [EMAIL_1] [IP_1]\"}", try r3.restoreDoc(a, "{\"content\":\"[EMAIL_1] [EMAIL_1] [IP_1]\"}"));
}

fn streamThrough(a: std.mem.Allocator, map: *const Map, stream: []const u8, step: usize) ![]const u8 {
    var r: Restorer = .init(map);
    var out: std.Io.Writer.Allocating = .init(a);
    var i: usize = 0;
    while (i < stream.len) : (i += step) try r.feed(a, stream[i..@min(stream.len, i + step)], &out.writer);
    try r.finish(a, &out.writer);
    return out.written();
}

/// The text a client would put together from the strings under `key`.
fn joined(a: std.mem.Allocator, stream: []const u8, key: []const u8) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, stream, '\n');
    const needle = try std.fmt.allocPrint(a, "\"{s}\":\"", .{key});
    while (lines.next()) |l| {
        var from: usize = 0;
        while (std.mem.findPos(u8, l, from, needle)) |at| {
            const s = at + needle.len;
            const e = stringEnd(l, s) orelse break;
            try text.appendSlice(a, l[s..e]);
            from = e;
        }
    }
    return text.items;
}

test "a stream: a placeholder cut anywhere, by events or by reads, is put back" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var map: Map = .{};
    _ = try redactBody(a, "{\"prompt\":\"bob@example.com and 10.20.30.40\"}", .every, &map);

    const said = "Write to [EMAIL_1] from [IP_1], not [EMAIL_7] or [x].";
    const want = "Write to bob@example.com from 10.20.30.40, not [EMAIL_7] or [x].";
    // Every way of cutting the text into two deltas, and into single bytes.
    var cut: usize = 0;
    while (cut <= said.len + 1) : (cut += 1) {
        var stream: std.ArrayList(u8) = .empty;
        if (cut <= said.len) {
            try stream.print(a, "data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":\"{s}\"}}}}]}}\n\n", .{said[0..cut]});
            try stream.print(a, "data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"{s}\"}}}}]}}\n\n", .{said[cut..]});
        } else for (said) |c| {
            try stream.print(a, "data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"{c}\"}}}}]}}\n\n", .{c});
        }
        try stream.appendSlice(a, "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n");
        for ([_]usize{ stream.items.len, 1, 7, 64 }) |step| {
            const got = try streamThrough(a, &map, stream.items, step);
            try testing.expectEqualStrings(want, try joined(a, got, "content"));
            // The events are still events, in order, and the stream still ends.
            try testing.expect(std.mem.endsWith(u8, got, "\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"));
            try testing.expectEqual(std.mem.count(u8, stream.items, "\n\n"), std.mem.count(u8, got, "\n\n"));
        }
    }
}

test "a stream: Anthropic events, tool arguments, and what is not a continuation" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var map: Map = .{};
    _ = try redactBody(a, "{\"prompt\":\"bob@example.com and 10.20.30.40\"}", .every, &map);

    const anthropic =
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"to [EMA\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"IL_1] ok\"}}\n\n" ++
        "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"ip\\\": \\\"[IP\"}}\r\n\r\n" ++
        "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"_1]\\\"}\"}}\r\n\r\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";
    for ([_]usize{ anthropic.len, 1, 5, 33 }) |step| {
        const got = try streamThrough(a, &map, anthropic, step);
        try testing.expectEqualStrings("to bob@example.com ok", try joined(a, got, "text"));
        try testing.expectEqualStrings("{\\\"ip\\\": \\\"10.20.30.40\\\"}", try joined(a, got, "partial_json"));
        // Nothing was reordered: each event line is still followed by its data.
        try testing.expectEqual(@as(usize, 6), std.mem.count(u8, got, "event: "));
        try testing.expect(std.mem.find(u8, got, "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n") != null);
    }

    // The other half never comes (the block ends, another index goes on, the
    // stream stops): the held text is passed on as it was, in its place.
    const broken =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"see [EMAIL_\"}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":1,\"delta\":{\"content\":\"1] other choice\"}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"tail [IP_\"}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"end [EM\"}}]}\n\n";
    for ([_]usize{ broken.len, 1, 9 }) |step| {
        try testing.expectEqualStrings(broken, try streamThrough(a, &map, broken, step));
    }

    // Comments and lines that are not JSON pass, also behind a held event.
    const mixed = ": keep-alive\n\ndata: {\"delta\":\"x [IP\"}\n\n: ping\n\ndata: {\"delta\":\"_1] y\"}\n\ndata: [DONE]\n\nnot a line";
    const got = try streamThrough(a, &map, mixed, 3);
    try testing.expectEqualStrings(": keep-alive\n\ndata: {\"delta\":\"x \"}\n\n: ping\n\ndata: {\"delta\":\"10.20.30.40 y\"}\n\ndata: [DONE]\n\nnot a line", got);
}

test "editTop drops members by any spelling and appends one" {
    const gpa = testing.allocator;
    const drop = [_][]const u8{ "user", "metadata", "store" };
    const out = (try editTop(gpa, " {\"model\":\"m\", \"User\":\"u1\",\"messages\":[{\"user\":\"kept\"}],\"metadata\":{\"user_id\":\"x\",\"a\":[1,{\"b\":\"}\"}]},\"u\\u0073er\":\"u2\", \"store\" : true }\n", &drop, "\"store\":false")).?;
    defer gpa.free(out);
    try testing.expectEqualStrings(" {\"model\":\"m\",\"messages\":[{\"user\":\"kept\"}],\"store\":false}\n", out);
    _ = try jsonscan.scan(out, .{});

    try testing.expectEqual(@as(?[]u8, null), try editTop(gpa, "{\"model\":\"m\"}", &drop, ""));
    const only = (try editTop(gpa, "{\"user\":\"x\"}", &drop, "")).?;
    defer gpa.free(only);
    try testing.expectEqualStrings("{}", only);
    const added = (try editTop(gpa, "{}", &.{}, "\"store\":false")).?;
    defer gpa.free(added);
    try testing.expectEqualStrings("{\"store\":false}", added);
    try testing.expectError(error.InvalidJson, editTop(gpa, "[1]", &drop, ""));
    try testing.expectError(error.InvalidJson, editTop(gpa, "{\"a\":", &drop, ""));
}

test "the header only ever asks for more" {
    try testing.expectEqual(Request{ .no_store = true, .redact = true, .unlink = true }, Request.parse("on").?);
    try testing.expectEqual(Request{ .no_store = true, .redact = true, .unlink = true }, Request.parse(" TRUE ").?);
    try testing.expectEqual(Request{ .redact = true }, Request.parse("redact").?);
    try testing.expectEqual(Request{ .no_store = true, .unlink = true }, Request.parse("no-store, unlink").?);
    const long: [65]u8 = @splat('x');
    for ([_][]const u8{ "", "off", "false", "0", "none", "redact,off", "redact;unlink", &long }) |bad| {
        try testing.expectEqual(@as(?Request, null), Request.parse(bad));
    }
}

test "hostile text costs what its length costs" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const size = 1024 * 1024;
    const patterns = [_][]const u8{
        "@",                  "1",                           "[EMAIL_",   "a@",
        "1 ",                 "a:",                          "+",         "sk-",
        "eyJa.",              "-----BEGIN PRIVATE KEY-----", "\\",        "(555) 123-456",
        "4111 1111 1111 111", "a.b@c",                       "::",        "Bearer ",
        "0 1",                "[",                           "\\\\a@b.c", "1.2.3.",
    };
    for (patterns) |p| {
        const text = try a.alloc(u8, size - size % p.len);
        var i: usize = 0;
        while (i < text.len) : (i += p.len) @memcpy(text[i..][0..p.len], p);
        var sc: Scanner = .{ .t = text, .enabled = .every };
        var matches: usize = 0;
        while (sc.next()) |_| matches += 1;
        // Looked at ahead of the cursor: a small multiple of the text.
        testing.expect(sc.work <= 64 * @as(u64, text.len)) catch |err| {
            std.debug.print("pattern {s}: work {d} for {d} bytes\n", .{ p, sc.work, text.len });
            return err;
        };
    }

    // The same for the answer's side: a megabyte of half placeholders in
    // one event, and in a great many, a byte at a time.
    var map: Map = .{};
    _ = try redactBody(a, "{\"prompt\":\"bob@example.com\"}", .every, &map);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    {
        var r: Restorer = .init(&map);
        var fed: usize = 0;
        try r.feed(a, "data: {\"content\":\"", &discard.writer);
        while (fed < 512 * 1024) : (fed += 7) try r.feed(a, "[EMAIL_", &discard.writer);
        try r.feed(a, "\"}\n\n", &discard.writer);
        try r.finish(a, &discard.writer);
        try testing.expect(r.work <= 8 * (fed + 64));
    }
    {
        var r: Restorer = .init(&map);
        const event = "data: {\"index\":0,\"content\":\"[EMAIL_\"}\n\n";
        var fed: usize = 0;
        while (fed < 256 * 1024) : (fed += event.len) {
            for (event) |c| try r.feed(a, &.{c}, &discard.writer);
        }
        try r.finish(a, &discard.writer);
        try testing.expect(r.work <= 8 * fed);
        try testing.expect(r.held.capacity <= 4096 and r.pending.capacity <= 4096);
    }
}
