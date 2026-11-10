//! `GET /v1/models` and `GET /v1/models/{id}` in the shape the client's SDK
//! expects: OpenAI's list (`object`, `created`, `owned_by`) or Anthropic's
//! (`type`, `display_name`, `created_at`, paging fields).
//!
//! A gateway model is a route, not a provider model, so there is no real
//! creation date: every model reports the time this gateway process started.

const std = @import("std");
const Io = std.Io;
const errors = @import("errors.zig");

pub const Protocol = errors.Protocol;

/// `2026-11-10T17:59:00Z` for a Unix time in seconds (clamped at 1970).
pub fn rfc3339(buf: *[20]u8, unix_s: i64) []const u8 {
    const secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, unix_s)) };
    const year_day = secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = secs.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u8, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// One model object.
pub fn writeOne(w: *Io.Writer, protocol: Protocol, id: []const u8, created_s: i64) Io.Writer.Error!void {
    switch (protocol) {
        .openai => {
            try w.writeAll("{\"id\":");
            try string(w, id);
            try w.print(",\"object\":\"model\",\"created\":{d},\"owned_by\":\"omnigate\"}}", .{@max(0, created_s)});
        },
        .anthropic => {
            var buf: [20]u8 = undefined;
            try w.writeAll("{\"type\":\"model\",\"id\":");
            try string(w, id);
            try w.writeAll(",\"display_name\":");
            try string(w, id);
            try w.print(",\"created_at\":\"{s}\"}}", .{rfc3339(&buf, created_s)});
        },
    }
}

/// The whole list. It is never paged: a gateway has few routes.
pub fn writeList(w: *Io.Writer, protocol: Protocol, ids: []const []const u8, created_s: i64) Io.Writer.Error!void {
    try w.writeAll(switch (protocol) {
        .openai => "{\"object\":\"list\",\"data\":[",
        .anthropic => "{\"data\":[",
    });
    for (ids, 0..) |id, i| {
        if (i > 0) try w.writeAll(",");
        try writeOne(w, protocol, id, created_s);
    }
    try w.writeAll("]");
    if (protocol == .anthropic) {
        try w.writeAll(",\"has_more\":false,\"first_id\":");
        if (ids.len > 0) try string(w, ids[0]) else try w.writeAll("null");
        try w.writeAll(",\"last_id\":");
        if (ids.len > 0) try string(w, ids[ids.len - 1]) else try w.writeAll("null");
    }
    try w.writeAll("}");
}

fn string(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    std.json.Stringify.value(s, .{}, w) catch return error.WriteFailed;
}

const testing = std.testing;

test "rfc3339" {
    var buf: [20]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", rfc3339(&buf, 0));
    try testing.expectEqualStrings("2026-11-10T17:59:00Z", rfc3339(&buf, 1794333540));
    try testing.expectEqualStrings("2024-02-29T23:59:59Z", rfc3339(&buf, 1709251199));
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", rfc3339(&buf, -5));
}

test "OpenAI list and item" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeList(&w, .openai, &.{ "chat", "say \"hi\"" }, 1700000000);
    try testing.expectEqualStrings(
        \\{"object":"list","data":[{"id":"chat","object":"model","created":1700000000,"owned_by":"omnigate"},{"id":"say \"hi\"","object":"model","created":1700000000,"owned_by":"omnigate"}]}
    , w.buffered());
    // It is valid JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1700000000), parsed.value.object.get("data").?.array.items[0].object.get("created").?.integer);
}

test "Anthropic list, item and the empty list" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeList(&w, .anthropic, &.{ "claude", "direct" }, 1794333540);
    try testing.expectEqualStrings(
        \\{"data":[{"type":"model","id":"claude","display_name":"claude","created_at":"2026-11-10T17:59:00Z"},{"type":"model","id":"direct","display_name":"direct","created_at":"2026-11-10T17:59:00Z"}],"has_more":false,"first_id":"claude","last_id":"direct"}
    , w.buffered());

    w = .fixed(&buf);
    try writeList(&w, .anthropic, &.{}, 0);
    try testing.expectEqualStrings(
        \\{"data":[],"has_more":false,"first_id":null,"last_id":null}
    , w.buffered());

    w = .fixed(&buf);
    try writeOne(&w, .anthropic, "claude", 0);
    try testing.expectEqualStrings(
        \\{"type":"model","id":"claude","display_name":"claude","created_at":"1970-01-01T00:00:00Z"}
    , w.buffered());
}
