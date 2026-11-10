//! Request handling: auth, routing, failover and streaming passthrough.
//!
//! Failover rule: an upstream is abandoned (and the next target tried) only
//! *before* any response byte has been sent to the client, i.e. on connect /
//! send errors, 429, and 5xx. Once streaming starts we are committed.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const config = @import("config.zig");
const control = @import("control.zig");
const Usage = @import("usage.zig").Usage;
const App = @import("main.zig").App;

const log = std.log.scoped(.proxy);

const max_request_body = 8 * 1024 * 1024;
const default_anthropic_version = "2023-06-01";

pub fn handleConnection(app: *App, stream: Io.net.Stream) void {
    defer stream.close(app.io);

    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(app.io, &recv_buf);
    var stream_writer = stream.writer(app.io, &send_buf);
    var server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                log.debug("receiveHead: {t}", .{err});
                return;
            },
        };
        handleRequest(app, &request) catch |err| {
            log.warn("request aborted: {t}", .{err});
            return;
        };
    }
}

const ClientHeaders = struct {
    api_key: ?[]const u8 = null,
    anthropic_version: ?[]const u8 = null,
    anthropic_beta: ?[]const u8 = null,
};

fn handleRequest(app: *App, request: *http.Server.Request) !void {
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const method = request.head.method;
    const target = try arena.dupe(u8, request.head.target);
    const path = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];

    // Header strings are invalidated once the body reader is created; copy now.
    var hdrs: ClientHeaders = .{};
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            const v = std.mem.trim(u8, h.value, " ");
            const prefix = "Bearer ";
            if (v.len > prefix.len and std.ascii.eqlIgnoreCase(v[0..prefix.len], prefix)) {
                hdrs.api_key = try arena.dupe(u8, v[prefix.len..]);
            }
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-api-key")) {
            hdrs.api_key = try arena.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "anthropic-version")) {
            hdrs.anthropic_version = try arena.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "anthropic-beta")) {
            hdrs.anthropic_beta = try arena.dupe(u8, h.value);
        }
    }

    if (method == .GET and std.mem.eql(u8, path, "/healthz")) {
        return request.respond("ok\n", .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
    }

    const snapshot = app.store.get(app.io) orelse
        return respondError(request, .service_unavailable, "gateway_not_ready", "no config from control plane yet");

    // --- authentication -------------------------------------------------
    const presented = hdrs.api_key orelse
        return respondError(request, .unauthorized, "missing_api_key", "send Authorization: Bearer <key> or x-api-key");
    const key_hash = config.sha256Hex(presented);
    const key = snapshot.findKey(&key_hash) orelse
        return respondError(request, .unauthorized, "invalid_api_key", "unknown gateway key");
    if (key.blocked)
        return respondError(request, .payment_required, "budget_exceeded", "this key has exhausted its budget");

    if (method == .GET and std.mem.eql(u8, path, "/v1/models")) {
        return respondModels(arena, request, snapshot);
    }

    const kind: config.Kind = if (method == .POST and std.mem.eql(u8, path, "/v1/chat/completions"))
        .openai
    else if (method == .POST and std.mem.eql(u8, path, "/v1/messages"))
        .anthropic
    else
        return respondError(request, .not_found, "not_found", "unsupported endpoint");

    // --- body -------------------------------------------------------------
    var body_buf: [8 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buf);
    const body = body_reader.allocRemaining(arena, .limited(max_request_body)) catch |err| switch (err) {
        error.StreamTooLong => return respondError(request, .payload_too_large, "payload_too_large", "request body exceeds 8 MiB"),
        else => return err,
    };

    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return respondError(request, .bad_request, "invalid_json", "request body is not valid JSON");
    if (parsed.value != .object)
        return respondError(request, .bad_request, "invalid_json", "request body must be a JSON object");
    const obj = &parsed.value.object;

    const model_val = obj.get("model") orelse
        return respondError(request, .bad_request, "missing_model", "request has no \"model\" field");
    if (model_val != .string)
        return respondError(request, .bad_request, "missing_model", "\"model\" must be a string");
    const route_model = try arena.dupe(u8, model_val.string);
    const is_stream = if (obj.get("stream")) |s| s == .bool and s.bool else false;

    const route = snapshot.findRoute(route_model) orelse
        return respondError(request, .not_found, "model_not_found", "no route for this model");

    // OpenAI only reports usage on streams when asked to.
    if (kind == .openai and is_stream and obj.get("stream_options") == null) {
        var so: std.json.ObjectMap = .empty;
        try so.put(arena, "include_usage", .{ .bool = true });
        try obj.put(arena, "stream_options", .{ .object = so });
    }

    // --- failover loop ----------------------------------------------------
    const started = Io.Timestamp.now(app.io, .awake);
    var attempts: std.ArrayList(Attempt) = .empty;
    var usage: Usage = .{};

    for (route.targets) |t| {
        const up = snapshot.findUpstream(t.upstream) orelse {
            try attempts.append(arena, .{ .upstream = t.upstream, .outcome = "unknown_upstream" });
            continue;
        };
        if (up.kind != kind) {
            // TODO: OpenAI <-> Anthropic request/response translation.
            try attempts.append(arena, .{ .upstream = up.name, .outcome = "protocol_mismatch" });
            continue;
        }

        try obj.put(arena, "model", .{ .string = t.model });
        const out_body = try std.json.Stringify.valueAlloc(arena, parsed.value, .{});

        const result = forward(app, arena, request, up, path, out_body, hdrs, &usage) catch |err| {
            try attempts.append(arena, .{ .upstream = up.name, .outcome = @errorName(err) });
            log.warn("upstream {s} failed: {t}", .{ up.name, err });
            continue;
        };
        switch (result) {
            .retry => |status| {
                const outcome = try std.fmt.allocPrint(arena, "http_{d}", .{@backingInt(status)});
                try attempts.append(arena, .{ .upstream = up.name, .outcome = outcome });
                log.warn("upstream {s} returned {d}, failing over", .{ up.name, @backingInt(status) });
            },
            .done => |status| {
                try attempts.append(arena, .{ .upstream = up.name, .outcome = "ok" });
                report(app, arena, .{
                    .key_sha256 = &key_hash,
                    .route_model = route_model,
                    .upstream = up.name,
                    .target_model = t.model,
                    .status = @backingInt(status),
                    .stream = is_stream,
                    .input_tokens = usage.input_tokens,
                    .output_tokens = usage.output_tokens,
                    .latency_ms = started.durationTo(Io.Timestamp.now(app.io, .awake)).toMilliseconds(),
                    .attempts = attempts.items,
                });
                return;
            },
        }
    }

    report(app, arena, .{
        .key_sha256 = &key_hash,
        .route_model = route_model,
        .upstream = null,
        .target_model = null,
        .status = 502,
        .stream = is_stream,
        .input_tokens = 0,
        .output_tokens = 0,
        .latency_ms = started.durationTo(Io.Timestamp.now(app.io, .awake)).toMilliseconds(),
        .attempts = attempts.items,
    });
    const detail = try std.json.Stringify.valueAlloc(arena, .{
        .@"error" = .{
            .type = "all_upstreams_failed",
            .message = "every target for this model failed",
            .attempts = attempts.items,
        },
    }, .{});
    try request.respond(detail, .{
        .status = .bad_gateway,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

const Attempt = struct {
    upstream: []const u8,
    outcome: []const u8,
};

const UsageReport = struct {
    key_sha256: []const u8,
    route_model: []const u8,
    upstream: ?[]const u8,
    target_model: ?[]const u8,
    status: u16,
    stream: bool,
    input_tokens: u64,
    output_tokens: u64,
    latency_ms: i64,
    attempts: []const Attempt,
    /// Filled in by `report`.
    id: []const u8 = "",
    ts_ms: i64 = 0,
};

/// Queue a usage event. Returns immediately: delivery (batching, retries, the
/// on-disk spool) is the reporter's job, so requests never wait on the
/// control plane.
fn report(app: *App, arena: std.mem.Allocator, r: UsageReport) void {
    // Unique id: delivery is at-least-once and the ledger dedups on it.
    var raw: [16]u8 = undefined;
    app.io.random(&raw);
    const id = std.fmt.bytesToHex(raw, .lower);

    var event = r;
    event.id = &id;
    // When the request finished here, not when the event reaches the ledger.
    event.ts_ms = Io.Timestamp.now(app.io, .real).toMilliseconds();

    const json = std.json.Stringify.valueAlloc(arena, event, .{}) catch return;
    app.reporter.enqueue(json);
}

const ForwardResult = union(enum) {
    /// Upstream answered with a retryable status before we committed.
    retry: http.Status,
    /// Response fully streamed to the client.
    done: http.Status,
};

fn isRetryable(status: http.Status) bool {
    const code = @backingInt(status);
    return code == 429 or code >= 500;
}

fn forward(
    app: *App,
    arena: std.mem.Allocator,
    request: *http.Server.Request,
    up: *const config.Upstream,
    path: []const u8,
    out_body: []u8,
    hdrs: ClientHeaders,
    usage: *Usage,
) !ForwardResult {
    const base = std.mem.trimEnd(u8, up.base_url, "/");
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, path });
    const uri = try std.Uri.parse(url);
    const secret = app.env.get(up.api_key_env) orelse "";

    var extra: std.ArrayList(http.Header) = .empty;
    var headers: http.Client.Request.Headers = .{
        .content_type = .{ .override = "application/json" },
        // Keep bodies uncompressed so they can be streamed and metered as-is.
        .accept_encoding = .{ .override = "identity" },
        .user_agent = .{ .override = "omnigate/0.1" },
    };
    switch (up.kind) {
        .openai => {
            headers.authorization = .{ .override = try std.fmt.allocPrint(arena, "Bearer {s}", .{secret}) };
        },
        .anthropic => {
            headers.authorization = .omit;
            try extra.append(arena, .{ .name = "x-api-key", .value = secret });
            try extra.append(arena, .{
                .name = "anthropic-version",
                .value = hdrs.anthropic_version orelse default_anthropic_version,
            });
            if (hdrs.anthropic_beta) |b| try extra.append(arena, .{ .name = "anthropic-beta", .value = b });
        },
    }

    var req = try app.client.request(.POST, uri, .{
        .headers = headers,
        // Zig 0.17's http.Client never writes `privileged_headers`, so secrets
        // go in `extra_headers`. Safe because redirects are not followed.
        .extra_headers = extra.items,
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = out_body.len };
    try req.sendBodyComplete(out_body);
    var response = try req.receiveHead(&.{});

    const status = response.head.status;
    if (isRetryable(status)) return .{ .retry = status };

    // Committed: copy what we need from the head before it is invalidated.
    const content_type = try arena.dupe(u8, response.head.content_type orelse "application/json");

    var resp_buf: [8 * 1024]u8 = undefined;
    var body_writer = try request.respondStreaming(&resp_buf, .{
        .respond_options = .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = content_type },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "x-omnigate-upstream", .value = up.name },
            },
        },
    });

    var transfer_buf: [64]u8 = undefined;
    const upstream_body = response.reader(&transfer_buf);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        var vec = [_][]u8{&chunk};
        const n = upstream_body.readVec(&vec) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        };
        if (n == 0) continue;
        usage.feed(chunk[0..n]);
        try body_writer.writer.writeAll(chunk[0..n]);
        // Flush per chunk so SSE tokens reach the client immediately.
        try body_writer.flush();
    }
    try body_writer.end();
    return .{ .done = status };
}

fn respondError(request: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    std.json.Stringify.value(.{ .@"error" = .{ .type = code, .message = message } }, .{}, &w) catch {};
    try request.respond(w.buffered(), .{
        .status = status,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn respondModels(arena: std.mem.Allocator, request: *http.Server.Request, snapshot: *const config.Snapshot) !void {
    const Model = struct { id: []const u8, object: []const u8 = "model", owned_by: []const u8 = "omnigate" };
    var models: std.ArrayList(Model) = .empty;
    for (snapshot.routes) |r| try models.append(arena, .{ .id = r.model });
    const json = try std.json.Stringify.valueAlloc(arena, .{ .object = "list", .data = models.items }, .{});
    try request.respond(json, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}
