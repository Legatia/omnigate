//! The gateway's own error answers, in the shape the client's protocol uses.
//!
//! A client built on the OpenAI or the Anthropic SDK should not be able to
//! tell an error raised by the gateway from one raised by the provider, so
//! the envelope and the `type` follow the protocol the endpoint speaks:
//!
//!   OpenAI     {"error":{"message","type","param":null,"code"}}
//!   Anthropic  {"type":"error","error":{"type","message","code"},"request_id"}
//!
//! `code` is always the gateway's own reason (`model_not_found`,
//! `budget_exceeded`, ...): the same string the request is counted under in
//! the control plane's metrics, and the stable thing to match on. `type` is
//! the provider's broader category.

const std = @import("std");
const Io = std.Io;

pub const Protocol = enum { openai, anthropic };

/// One upstream that was tried for a request, and how that went.
pub const Attempt = struct {
    upstream: []const u8,
    outcome: []const u8,
};

pub const Types = struct {
    openai: []const u8,
    anthropic: []const u8,
};

/// The provider-style error categories for a gateway reason. Reasons not
/// listed fall back on the status code.
pub fn typesFor(reason: []const u8, status: u16) Types {
    const eql = std.mem.eql;
    const table = [_]struct { []const u8, Types }{
        .{ "missing_api_key", .{ .openai = "invalid_request_error", .anthropic = "authentication_error" } },
        .{ "invalid_api_key", .{ .openai = "invalid_request_error", .anthropic = "authentication_error" } },
        .{ "budget_exceeded", .{ .openai = "insufficient_quota", .anthropic = "billing_error" } },
        .{ "rate_limit_exceeded", .{ .openai = "rate_limit_error", .anthropic = "rate_limit_error" } },
        .{ "upstream_rate_limited", .{ .openai = "rate_limit_error", .anthropic = "rate_limit_error" } },
        .{ "model_not_allowed", .{ .openai = "permission_error", .anthropic = "permission_error" } },
        .{ "model_not_found", .{ .openai = "invalid_request_error", .anthropic = "not_found_error" } },
        .{ "not_found", .{ .openai = "invalid_request_error", .anthropic = "not_found_error" } },
        .{ "payload_too_large", .{ .openai = "invalid_request_error", .anthropic = "request_too_large" } },
        .{ "overloaded", .{ .openai = "server_error", .anthropic = "overloaded_error" } },
    };
    for (table) |row| if (eql(u8, row[0], reason)) return row[1];
    return switch (status) {
        401 => .{ .openai = "invalid_request_error", .anthropic = "authentication_error" },
        403 => .{ .openai = "permission_error", .anthropic = "permission_error" },
        404 => .{ .openai = "invalid_request_error", .anthropic = "not_found_error" },
        429 => .{ .openai = "rate_limit_error", .anthropic = "rate_limit_error" },
        400...400, 405...428 => .{ .openai = "invalid_request_error", .anthropic = "invalid_request_error" },
        else => .{ .openai = "server_error", .anthropic = "api_error" },
    };
}

pub const Info = struct {
    status: u16,
    /// The gateway's reason; becomes `code`.
    reason: []const u8,
    message: []const u8,
    request_id: []const u8 = "",
    /// Listed in the error when the request reached the failover loop.
    attempts: ?[]const Attempt = null,
};

/// Write the error body for `protocol`.
pub fn write(w: *Io.Writer, protocol: Protocol, e: Info) Io.Writer.Error!void {
    const types = typesFor(e.reason, e.status);
    switch (protocol) {
        .openai => {
            try w.writeAll("{\"error\":{\"message\":");
            try string(w, e.message);
            try w.writeAll(",\"type\":");
            try string(w, types.openai);
            try w.writeAll(",\"param\":null,\"code\":");
            try string(w, e.reason);
            try attemptsField(w, e.attempts);
            try w.writeAll("}}");
        },
        .anthropic => {
            try w.writeAll("{\"type\":\"error\",\"error\":{\"type\":");
            try string(w, types.anthropic);
            try w.writeAll(",\"message\":");
            try string(w, e.message);
            try w.writeAll(",\"code\":");
            try string(w, e.reason);
            try attemptsField(w, e.attempts);
            try w.writeAll("}");
            if (e.request_id.len > 0) {
                try w.writeAll(",\"request_id\":");
                try string(w, e.request_id);
            }
            try w.writeAll("}");
        },
    }
}

fn attemptsField(w: *Io.Writer, attempts: ?[]const Attempt) Io.Writer.Error!void {
    const list = attempts orelse return;
    try w.writeAll(",\"attempts\":");
    std.json.Stringify.value(list, .{}, w) catch return error.WriteFailed;
}

fn string(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    std.json.Stringify.value(s, .{}, w) catch return error.WriteFailed;
}

const testing = std.testing;

fn render(buf: []u8, protocol: Protocol, e: Info) ![]const u8 {
    var w: Io.Writer = .fixed(buf);
    try write(&w, protocol, e);
    return w.buffered();
}

test "OpenAI shape: message, type, param and the gateway reason as code" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\{"error":{"message":"no route for this model","type":"invalid_request_error","param":null,"code":"model_not_found"}}
    , try render(&buf, .openai, .{ .status = 404, .reason = "model_not_found", .message = "no route for this model", .request_id = "abc" }));
    try testing.expectEqualStrings(
        \\{"error":{"message":"over budget","type":"insufficient_quota","param":null,"code":"budget_exceeded"}}
    , try render(&buf, .openai, .{ .status = 402, .reason = "budget_exceeded", .message = "over budget" }));
}

test "Anthropic shape: envelope, Anthropic type names, request id" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\{"type":"error","error":{"type":"not_found_error","message":"no route for this model","code":"model_not_found"},"request_id":"abc"}
    , try render(&buf, .anthropic, .{ .status = 404, .reason = "model_not_found", .message = "no route for this model", .request_id = "abc" }));
    try testing.expectEqualStrings(
        \\{"type":"error","error":{"type":"authentication_error","message":"m","code":"invalid_api_key"}}
    , try render(&buf, .anthropic, .{ .status = 401, .reason = "invalid_api_key", .message = "m" }));
}

test "every reason the gateway uses has the right category in both protocols" {
    const cases = [_]struct { []const u8, u16, []const u8, []const u8 }{
        .{ "missing_api_key", 401, "invalid_request_error", "authentication_error" },
        .{ "invalid_api_key", 401, "invalid_request_error", "authentication_error" },
        .{ "budget_exceeded", 402, "insufficient_quota", "billing_error" },
        .{ "model_not_allowed", 403, "permission_error", "permission_error" },
        .{ "model_not_found", 404, "invalid_request_error", "not_found_error" },
        .{ "not_found", 404, "invalid_request_error", "not_found_error" },
        .{ "method_not_allowed", 405, "invalid_request_error", "invalid_request_error" },
        .{ "payload_too_large", 413, "invalid_request_error", "request_too_large" },
        .{ "invalid_json", 400, "invalid_request_error", "invalid_request_error" },
        .{ "missing_model", 400, "invalid_request_error", "invalid_request_error" },
        .{ "invalid_request", 400, "invalid_request_error", "invalid_request_error" },
        .{ "endpoint_not_supported", 400, "invalid_request_error", "invalid_request_error" },
        .{ "untranslatable_request", 400, "invalid_request_error", "invalid_request_error" },
        .{ "rate_limit_exceeded", 429, "rate_limit_error", "rate_limit_error" },
        .{ "upstream_rate_limited", 429, "rate_limit_error", "rate_limit_error" },
        .{ "all_upstreams_failed", 502, "server_error", "api_error" },
        .{ "gateway_not_ready", 503, "server_error", "api_error" },
        .{ "control_plane_unavailable", 503, "server_error", "api_error" },
        .{ "overloaded", 503, "server_error", "overloaded_error" },
    };
    for (cases) |c| {
        const t = typesFor(c[0], c[1]);
        try testing.expectEqualStrings(c[2], t.openai);
        try testing.expectEqualStrings(c[3], t.anthropic);
    }
}

test "attempts are listed, and strings are escaped" {
    var buf: [512]u8 = undefined;
    const attempts = [_]Attempt{ .{ .upstream = "a", .outcome = "http_429" }, .{ .upstream = "b", .outcome = "ConnectionRefused" } };
    try testing.expectEqualStrings(
        \\{"error":{"message":"every target for this model failed","type":"server_error","param":null,"code":"all_upstreams_failed","attempts":[{"upstream":"a","outcome":"http_429"},{"upstream":"b","outcome":"ConnectionRefused"}]}}
    , try render(&buf, .openai, .{ .status = 502, .reason = "all_upstreams_failed", .message = "every target for this model failed", .attempts = &attempts }));
    try testing.expectEqualStrings(
        \\{"type":"error","error":{"type":"rate_limit_error","message":"say \"hi\"","code":"upstream_rate_limited","attempts":[{"upstream":"a","outcome":"http_429"}]},"request_id":"r"}
    , try render(&buf, .anthropic, .{ .status = 429, .reason = "upstream_rate_limited", .message = "say \"hi\"", .request_id = "r", .attempts = attempts[0..1] }));
}
