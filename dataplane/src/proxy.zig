//! Request handling: auth, rate limits, routing, failover and streaming
//! passthrough.
//!
//! Failover rule: an upstream is abandoned (and the next target tried) only
//! *before* any response byte has been sent to the client, i.e. on connect /
//! send errors, timeouts waiting for headers, 429, and 5xx. Once streaming
//! starts we are committed.
//!
//! `/v1/jobs*` and `/v1/files/*` (async media jobs) are authenticated here and
//! handed to the control plane, which owns job state.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const balance = @import("balance.zig");
const config = @import("config.zig");
const control = @import("control.zig");
const logging = @import("logging.zig");
const quirks = @import("quirks.zig");
const translate = @import("translate.zig");
const usage_mod = @import("usage.zig");
const watchdog = @import("watchdog.zig");
const Usage = usage_mod.Usage;
const App = @import("main.zig").App;

const log = std.log.scoped(.proxy);

const max_request_body = 8 * 1024 * 1024;
const default_anthropic_version = "2023-06-01";
/// How long the control plane gets to answer a jobs/files request.
const control_timeout_ms = 30_000;
/// Cap on an upstream response that must be buffered to be translated.
const max_translated_body = 64 * 1024 * 1024;

pub fn handleConnection(app: *App, guard: *watchdog.Conn) void {
    // `guard` lets the watchdog cancel this task when the client (or, during
    // a stream, the upstream) stalls. It is freed by the watchdog once `done`
    // is set, so that must be the last thing this task does.
    defer guard.done.store(true, .release);
    // Counted by the accept loop before this task was spawned.
    defer _ = app.active_connections.fetchSub(1, .acq_rel);
    const stream = guard.stream;
    defer stream.close(app.io);

    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(app.io, &recv_buf);
    var stream_writer = stream.writer(app.io, &send_buf);
    var server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        // Between requests nothing is lost by closing: mark the connection
        // idle before looking at the shutdown flag, so that shutdown either
        // sees the mark or we see the flag.
        guard.idle.store(true, .release);
        if (app.shutting_down.load(.acquire)) return;
        guard.arm(app.io, app.client_timeout_ms);

        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                log.debug("receiveHead: {t}", .{err});
                return;
            },
        };
        guard.idle.store(false, .release);
        // The rest of the request (its body) gets a fresh allowance.
        guard.arm(app.io, app.client_timeout_ms);

        var acc: logging.Access = .{};
        const started = Io.Timestamp.now(app.io, .awake);
        const outcome = handleRequest(app, &request, guard, &acc);
        acc.latency_ms = started.durationTo(Io.Timestamp.now(app.io, .awake)).toMilliseconds();
        if (outcome) |_| {} else |err| {
            // The watchdog cancels the task; say what that meant.
            acc.aborted = if (!guard.timedOut()) err else if (acc.status == 0) error.ClientTimeout else error.StreamIdleTimeout;
            if (acc.status == 0 and guard.timedOut()) acc.status = 408;
        }
        const is_probe = acc.status == 200 and std.mem.eql(u8, acc.path.get(), "/healthz");
        logging.access(&acc, if (is_probe) .debug else .info);
        outcome catch return;
        guard.disarm();
    }
}

const ClientHeaders = struct {
    api_key: ?[]const u8 = null,
    anthropic_version: ?[]const u8 = null,
    anthropic_beta: ?[]const u8 = null,
    idempotency_key: ?[]const u8 = null,
};

fn handleRequest(app: *App, request: *http.Server.Request, guard: *watchdog.Conn, acc: *logging.Access) !void {
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const method = request.head.method;
    const target = try arena.dupe(u8, request.head.target);
    const path = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
    const query = if (path.len < target.len) target[path.len + 1 ..] else "";
    acc.method = @tagName(method);
    acc.path.set(path);
    // Nothing more to wait for from a request without a body.
    if (!method.requestHasBody()) guard.disarm();

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
        } else if (std.ascii.eqlIgnoreCase(h.name, "idempotency-key")) {
            hdrs.idempotency_key = try arena.dupe(u8, h.value);
        }
    }

    if (method == .GET and std.mem.eql(u8, path, "/healthz")) {
        acc.status = 200;
        return request.respond("ok\n", .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
    }

    const snapshot = app.store.get(app.io) orelse
        return respondError(acc, request, .service_unavailable, "gateway_not_ready", "no config from control plane yet");

    const is_files = std.mem.startsWith(u8, path, "/v1/files/");
    const is_jobs = std.mem.eql(u8, path, "/v1/jobs") or std.mem.startsWith(u8, path, "/v1/jobs/");

    // A signed output URL carries its own proof; the control plane checks it.
    if (is_files and method == .GET and hdrs.api_key == null and hasQueryParam(query, "sig")) {
        return forwardToControl(app, acc, arena, request, method, target, null, hdrs, null);
    }

    // --- authentication -------------------------------------------------
    const presented = hdrs.api_key orelse
        return respondError(acc, request, .unauthorized, "missing_api_key", "send Authorization: Bearer <key> or x-api-key");
    const key_hash = config.sha256Hex(presented);
    const key = snapshot.findKey(&key_hash) orelse
        return respondError(acc, request, .unauthorized, "invalid_api_key", "unknown gateway key");
    acc.key.set(key.name);
    if (key.blocked)
        return respondError(acc, request, .payment_required, "budget_exceeded", "this key has exhausted its budget");

    if (method == .GET and std.mem.eql(u8, path, "/v1/models")) {
        return respondModels(acc, arena, request, snapshot, key);
    }

    const endpoint: ?Endpoint = if (method == .POST) Endpoint.forPath(path) else null;
    const is_job_create = method == .POST and std.mem.eql(u8, path, "/v1/jobs");

    // --- async media jobs: owned by the control plane ---------------------
    // (which also applies the key's model limits to them)
    if (is_jobs or is_files) {
        if (method != .GET and method != .POST)
            return respondError(acc, request, .method_not_allowed, "method_not_allowed", "use GET or POST");
        // Only requests that start work count against the rate limit;
        // polling a job does not.
        if (is_job_create) {
            if (rateLimited(app, &key_hash, key)) |secs| return respondRateLimited(acc, request, secs);
        }
        const job_body: ?[]u8 = if (method == .POST)
            (try readBody(arena, request, guard)) orelse
                return respondError(acc, request, .payload_too_large, "payload_too_large", "request body exceeds 8 MiB")
        else
            null;
        return forwardToControl(app, acc, arena, request, method, target, job_body, hdrs, &key_hash);
    }

    const ep = endpoint orelse
        return respondError(acc, request, .not_found, "not_found", "unsupported endpoint");
    const kind = ep.kind;

    // --- body -------------------------------------------------------------
    const body = (try readBody(arena, request, guard)) orelse
        return respondError(acc, request, .payload_too_large, "payload_too_large", "request body exceeds 8 MiB");

    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return respondError(acc, request, .bad_request, "invalid_json", "request body is not valid JSON");
    if (parsed.value != .object)
        return respondError(acc, request, .bad_request, "invalid_json", "request body must be a JSON object");
    const obj = &parsed.value.object;

    const model_val = obj.get("model") orelse
        return respondError(acc, request, .bad_request, "missing_model", "request has no \"model\" field");
    if (model_val != .string)
        return respondError(acc, request, .bad_request, "missing_model", "\"model\" must be a string");
    const route_model = try arena.dupe(u8, model_val.string);
    acc.model.set(route_model);
    const is_stream = if (obj.get("stream")) |s| s == .bool and s.bool else false;

    // --- model limits -------------------------------------------------------
    // Checked before the rate limit, so a refused model costs the key nothing,
    // and before the route lookup, so the answer does not reveal which other
    // models exist.
    if (!key.allows(route_model))
        return respondError(acc, request, .forbidden, "model_not_allowed", "this key may not use this model");

    // --- rate limit ---------------------------------------------------------
    if (ep.metered) {
        if (rateLimited(app, &key_hash, key)) |secs| return respondRateLimited(acc, request, secs);
    }

    const route = snapshot.findRoute(route_model) orelse
        return respondError(acc, request, .not_found, "model_not_found", "no route for this model");

    // OpenAI only reports usage on streams when asked to. If the client did
    // not ask, we do (to meter the call) and hide the extra chunk from it.
    const client_wants_usage = blk: {
        const so = obj.get("stream_options") orelse break :blk false;
        if (so != .object) break :blk false;
        const iu = so.object.get("include_usage") orelse break :blk false;
        break :blk iu == .bool and iu.bool;
    };
    var injected_usage = false;
    if (ep.inject_stream_usage and is_stream and !client_wants_usage) {
        var so: std.json.ObjectMap = if (obj.get("stream_options")) |v| (if (v == .object) v.object else .empty) else .empty;
        try so.put(arena, "include_usage", .{ .bool = true });
        try obj.put(arena, "stream_options", .{ .object = so });
        injected_usage = true;
    }

    // --- failover loop ----------------------------------------------------
    const started = Io.Timestamp.now(app.io, .awake);
    var attempts: std.ArrayList(Attempt) = .empty;
    var usage: Usage = .{};

    // One id per client request: returned in `x-omnigate-request-id` and used
    // as the usage event id the ledger dedups on.
    var raw_id: [16]u8 = undefined;
    app.io.random(&raw_id);
    const req_id = std.fmt.bytesToHex(raw_id, .lower);
    acc.request_id.set(&req_id);

    // The order to try the targets in: the route's strategy picks who goes
    // first (see balance.zig); upstreams that are cooling down after repeated
    // failures go last whatever the strategy, as a last resort.
    const now_ms = Io.Timestamp.now(app.io, .awake).toMilliseconds();
    const cooling = try arena.alloc(bool, route.targets.len);
    for (route.targets, cooling) |*t, *c| c.* = app.health.isCooling(app.io, t.upstream, now_ms);

    const strategy = balance.parseStrategy(route.strategy);
    const counter: u64 = if (strategy == .round_robin) app.balancer.next(app.gpa, app.io, route.model) else 0;
    var random: u64 = 0;
    if (strategy == .weighted) {
        var bytes: [8]u8 = undefined;
        app.io.random(&bytes);
        random = std.mem.readInt(u64, &bytes, .little);
    }
    const order = try arena.alloc(usize, route.targets.len);
    balance.order(order, route.targets, cooling, strategy, counter, random);

    var tried: u32 = 0;
    for (order) |target_index| {
        const t = &route.targets[target_index];
        const up = snapshot.findUpstream(t.upstream) orelse {
            try attempts.append(arena, .{ .upstream = t.upstream, .outcome = "unknown_upstream" });
            continue;
        };
        // The upstream may speak the other protocol: translate both ways.
        const xlate: ?Translation = if (up.kind == kind)
            null
        else if (ep.translatable)
            .{
                .dir = switch (kind) {
                    .openai => .openai_to_anthropic,
                    .anthropic => .anthropic_to_openai,
                },
                .route_model = route_model,
                .stream = is_stream,
                .include_usage = client_wants_usage,
            }
        else {
            try attempts.append(arena, .{ .upstream = up.name, .outcome = "protocol_mismatch" });
            continue;
        };

        var out_body: []u8 = if (xlate) |x|
            translate.translateRequest(arena, x.dir, body, t.model) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try attempts.append(arena, .{ .upstream = up.name, .outcome = "untranslatable_request" });
                    continue;
                },
            }
        else blk: {
            try obj.put(arena, "model", .{ .string = t.model });
            break :blk try std.json.Stringify.valueAlloc(arena, parsed.value, .{});
        };
        const upstream_path: []const u8 = if (xlate == null) path else switch (up.kind) {
            .openai => "/v1/chat/completions",
            .anthropic => "/v1/messages",
        };
        var mode: ForwardMode = if (xlate) |x|
            .{ .translate = x }
        else if (injected_usage)
            .hide_usage_chunk
        else
            .passthrough;

        // A model already known to reject sampling parameters (see quirks.zig)
        // gets the translated request without them from the start.
        if (mode == .translate and app.quirks.rejectsSampling(app.io, up.name, t.model)) {
            if (try quirks.stripSampling(arena, out_body)) |stripped| out_body = stripped;
            mode.translate.sampling_stripped = true;
        }
        if (mode == .translate and app.quirks.needsThoughtSignature(app.io, up.name, t.model)) {
            if (try quirks.addThoughtSignatures(arena, out_body)) |signed| out_body = signed;
            mode.translate.signatures_added = true;
        }

        tried += 1;
        var committed = false;
        var maybe_result: ?ForwardResult = null;
        var tries: u8 = 0;
        while (tries < 2) : (tries += 1) {
            if (forward(app, arena, request, guard, up, upstream_path, out_body, hdrs, &usage, &req_id, &committed, mode, tried)) |r| {
                if (r == .drop_sampling) {
                    // The model refused temperature/top_p/top_k, which a client
                    // of the other protocol could not have known. Remember it
                    // and send the same request once more without them.
                    app.quirks.noteRejectsSampling(app.gpa, app.io, up.name, t.model);
                    mode.translate.sampling_stripped = true;
                    if (try quirks.stripSampling(arena, out_body)) |stripped| {
                        log.info("{s}/{s} rejects sampling parameters; retrying without them", .{ up.name, t.model });
                        out_body = stripped;
                    }
                    tries = 0;
                    continue;
                }
                if (r == .add_thought_signature) {
                    // The model wants a signature on earlier tool calls that the
                    // client's protocol cannot carry. Remember it and resend
                    // with the placeholder the provider documents for this.
                    app.quirks.noteNeedsThoughtSignature(app.gpa, app.io, up.name, t.model);
                    mode.translate.signatures_added = true;
                    if (try quirks.addThoughtSignatures(arena, out_body)) |signed| {
                        log.info("{s}/{s} requires thought signatures on tool calls; retrying with placeholders", .{ up.name, t.model });
                        out_body = signed;
                    }
                    tries = 0;
                    continue;
                }
                maybe_result = r;
                break;
            } else |err| {
                if (committed) {
                    // The client already has part of the response; all we can
                    // do is bill what was metered and drop the connection.
                    try attempts.append(arena, .{ .upstream = up.name, .outcome = "stream_aborted" });
                    acc.status = 499;
                    acc.upstream.set(up.name);
                    acc.attempts = tried;
                    acc.input_tokens = usage.input_tokens;
                    acc.output_tokens = usage.output_tokens;
                    if (ep.metered) report(app, arena, .{
                        .id = &req_id,
                        .key_sha256 = &key_hash,
                        .route_model = route_model,
                        .upstream = up.name,
                        .target_model = t.model,
                        .status = 499,
                        .stream = is_stream,
                        .input_tokens = usage.input_tokens,
                        .output_tokens = usage.output_tokens,
                        .latency_ms = started.durationTo(Io.Timestamp.now(app.io, .awake)).toMilliseconds(),
                        .attempts = attempts.items,
                    });
                    return err;
                }
                // A pooled keep-alive connection may have been closed by the
                // upstream while idle: try once more before giving up on it.
                if (tries == 0 and worthRetrying(err)) {
                    log.debug("upstream {s}: {t}, retrying on a fresh connection", .{ up.name, err });
                    continue;
                }
                try attempts.append(arena, .{ .upstream = up.name, .outcome = @errorName(err) });
                log.warn("upstream {s} failed: {t}", .{ up.name, err });
                noteFailure(app, up.name);
                break;
            }
        }
        const result = maybe_result orelse continue;
        switch (result) {
            .retry => |status| {
                const outcome = try std.fmt.allocPrint(arena, "http_{d}", .{@backingInt(status)});
                try attempts.append(arena, .{ .upstream = up.name, .outcome = outcome });
                log.warn("upstream {s} returned {d}, failing over", .{ up.name, @backingInt(status) });
                noteFailure(app, up.name);
            },
            // Handled inside the loop above; they never escape it.
            .drop_sampling, .add_thought_signature => unreachable,
            .done => |status| {
                app.health.recordSuccess(app.io, up.name);
                acc.status = @backingInt(status);
                acc.upstream.set(up.name);
                acc.attempts = tried;
                acc.input_tokens = usage.input_tokens;
                acc.output_tokens = usage.output_tokens;
                try attempts.append(arena, .{ .upstream = up.name, .outcome = "ok" });
                if (ep.metered) report(app, arena, .{
                    .id = &req_id,
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

    if (ep.metered) report(app, arena, .{
        .id = &req_id,
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
    acc.status = 502;
    acc.attempts = tried;
    const detail = try std.json.Stringify.valueAlloc(arena, .{
        .@"error" = .{
            .type = "all_upstreams_failed",
            .message = "every target for this model failed",
            .attempts = attempts.items,
        },
    }, .{});
    try request.respond(detail, .{
        .status = .bad_gateway,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-omnigate-request-id", .value = &req_id },
        },
    });
}

/// Seconds to wait if this key is over its requests-per-minute limit, else
/// null. Counts the request against the limit when it is allowed.
fn rateLimited(app: *App, key_hash: *const [64]u8, key: *const config.Key) ?u32 {
    const now_ms = Io.Timestamp.now(app.io, .awake).toMilliseconds();
    return switch (app.limiter.check(app.gpa, app.io, key_hash, key.rpm, now_ms)) {
        .allowed => null,
        .retry_after_s => |secs| secs,
    };
}

fn noteFailure(app: *App, upstream: []const u8) void {
    const now_ms = Io.Timestamp.now(app.io, .awake).toMilliseconds();
    if (app.health.recordFailure(app.gpa, app.io, upstream, now_ms)) {
        log.warn("upstream {s} keeps failing; trying it last for the next {d} ms", .{ upstream, app.health.cooldown_ms });
    }
}

/// Read the whole request body; null when it exceeds `max_request_body`.
/// The client timeout armed on `guard` covers the read and ends with it.
fn readBody(arena: std.mem.Allocator, request: *http.Server.Request, guard: *watchdog.Conn) !?[]u8 {
    defer guard.disarm();
    var body_buf: [8 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buf);
    return body_reader.allocRemaining(arena, .limited(max_request_body)) catch |err| switch (err) {
        error.StreamTooLong => return null,
        else => return if (guard.timedOut()) error.ClientTimeout else err,
    };
}

fn hasQueryParam(query: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const key = pair[0 .. std.mem.findScalar(u8, pair, '=') orelse pair.len];
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

/// A provider-shaped endpoint the gateway routes by the body's "model".
const Endpoint = struct {
    /// The protocol the client is speaking.
    kind: config.Kind,
    /// Can be served by an upstream of the other protocol via translation.
    translatable: bool = false,
    /// OpenAI streams only report token usage when asked to.
    inject_stream_usage: bool = false,
    /// Counts against rate limits and is written to the usage ledger.
    metered: bool = true,

    fn forPath(path: []const u8) ?Endpoint {
        const eql = std.mem.eql;
        if (eql(u8, path, "/v1/chat/completions")) return .{ .kind = .openai, .translatable = true, .inject_stream_usage = true };
        if (eql(u8, path, "/v1/messages")) return .{ .kind = .anthropic, .translatable = true };
        if (eql(u8, path, "/v1/completions")) return .{ .kind = .openai, .inject_stream_usage = true };
        if (eql(u8, path, "/v1/embeddings")) return .{ .kind = .openai };
        if (eql(u8, path, "/v1/responses")) return .{ .kind = .openai };
        // Free at the provider, and its `input_tokens` answer is not usage.
        if (eql(u8, path, "/v1/messages/count_tokens")) return .{ .kind = .anthropic, .metered = false };
        return null;
    }
};

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
    /// Unique per client request; the ledger dedups on it.
    id: []const u8,
    /// Filled in by `report`.
    ts_ms: i64 = 0,
};

/// Queue a usage event. Returns immediately: delivery (batching, retries, the
/// on-disk spool) is the reporter's job, so requests never wait on the
/// control plane.
fn report(app: *App, arena: std.mem.Allocator, r: UsageReport) void {
    var event = r;
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
    /// A translated request was refused (400) because of a sampling
    /// parameter. Nothing was sent to the client; retry without them.
    drop_sampling,
    /// A translated request was refused (400) for lacking thought signatures
    /// on tool calls. Nothing was sent to the client; retry with placeholders.
    add_thought_signature,
};

fn isRetryable(status: http.Status) bool {
    const code = @backingInt(status);
    return code == 429 or code >= 500;
}

/// One outbound HTTP exchange up to the response head. The request lives
/// here (stable address) because the response keeps a pointer to it.
const UpstreamCall = struct {
    client: *http.Client,
    method: http.Method,
    uri: std.Uri,
    options: http.Client.RequestOptions,
    body: ?[]u8,
    req: http.Client.Request = undefined,
    req_live: bool = false,

    fn deinit(call: *UpstreamCall) void {
        if (call.req_live) call.req.deinit();
        call.req_live = false;
    }

    /// Connect, send the request and wait for the response head.
    fn open(call: *UpstreamCall) anyerror!http.Client.Response {
        call.req = try call.client.request(call.method, call.uri, call.options);
        call.req_live = true;
        if (call.body) |b| {
            try call.req.sendBodyComplete(b);
        } else {
            try call.req.sendBodiless();
        }
        return call.req.receiveHead(&.{});
    }

    /// `open`, but give up with `error.UpstreamTimeout` after `timeout_ms`
    /// (0 = wait forever). The exchange runs as its own task so that it can
    /// be canceled while blocked on the network.
    fn openWithTimeout(call: *UpstreamCall, io: Io, timeout_ms: u32) anyerror!http.Client.Response {
        if (timeout_ms == 0) return call.open();

        const Race = union(enum) {
            head: anyerror!http.Client.Response,
            timer: Io.Cancelable!void,
        };
        var results: [2]Race = undefined;
        var race: Io.Select(Race) = .init(io, &results);

        // No spare concurrency: better an untimed request than a failed one.
        race.concurrent(.head, open, .{call}) catch return call.open();
        race.concurrent(.timer, sleepMs, .{ io, timeout_ms }) catch {};

        const first = race.await() catch |err| {
            race.cancelDiscard();
            return err;
        };
        switch (first) {
            .head => |result| {
                race.cancelDiscard();
                return result;
            },
            .timer => {
                // Cancel the exchange. It may have finished in the meantime;
                // if it did, use the response rather than throw it away.
                var late: ?http.Client.Response = null;
                while (race.cancel()) |leftover| switch (leftover) {
                    .head => |result| {
                        if (result) |response| {
                            late = response;
                        } else |_| {}
                    },
                    .timer => {},
                };
                return late orelse error.UpstreamTimeout;
            },
        }
    }
};

fn sleepMs(io: Io, ms: u32) Io.Cancelable!void {
    return io.sleep(.fromMilliseconds(ms), .awake);
}

const Translation = struct {
    dir: translate.Direction,
    /// The model name the client asked for and should see in the answer.
    route_model: []const u8,
    stream: bool,
    /// OpenAI clients: did they ask for the final usage chunk?
    include_usage: bool,
    /// Sampling parameters have already been removed from the request.
    sampling_stripped: bool = false,
    /// Placeholder thought signatures have already been added to the request.
    signatures_added: bool = false,
};

/// What to do with the upstream's response body on its way to the client.
const ForwardMode = union(enum) {
    passthrough,
    /// Same protocol, but drop the usage-only SSE chunk we asked for ourselves.
    hide_usage_chunk,
    translate: Translation,
};

/// Errors after which the same upstream deserves one more try.
fn worthRetrying(err: anyerror) bool {
    return switch (err) {
        error.UpstreamTimeout,
        error.StreamIdleTimeout,
        error.UpstreamUnparseable,
        error.ConnectionRefused,
        error.OutOfMemory,
        error.Canceled,
        => false,
        else => true,
    };
}

fn forward(
    app: *App,
    arena: std.mem.Allocator,
    request: *http.Server.Request,
    /// The connection's deadline (see watchdog.zig).
    guard: *watchdog.Conn,
    up: *const config.Upstream,
    path: []const u8,
    out_body: []u8,
    hdrs: ClientHeaders,
    usage: *Usage,
    req_id: []const u8,
    /// Set once the first response byte is on its way to the client.
    committed: *bool,
    mode: ForwardMode,
    /// How many upstreams this request has been sent to, this one included.
    attempt_no: u32,
) !ForwardResult {
    const base = std.mem.trimEnd(u8, up.base_url, "/");
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, try config.upstreamPath(arena, up.v1_path, path) });
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

    var call: UpstreamCall = .{
        .client = app.client,
        .method = .POST,
        .uri = uri,
        .options = .{
            .headers = headers,
            // Zig 0.17's http.Client never writes `privileged_headers`, so secrets
            // go in `extra_headers`. Safe because redirects are not followed.
            .extra_headers = extra.items,
            .redirect_behavior = .unhandled,
        },
        .body = out_body,
    };
    defer call.deinit();

    const timeout_ms = if (up.timeout_ms != 0) up.timeout_ms else app.upstream_timeout_ms;
    var response = try call.openWithTimeout(app.io, timeout_ms);

    // From here on bytes have to keep moving: if the upstream goes silent, or
    // the client stops reading, for the idle timeout, the watchdog cancels
    // this task and the read or write below fails.
    guard.arm(app.io, app.stream_idle_timeout_ms);
    defer guard.disarm();

    const status = response.head.status;
    if (isRetryable(status)) return .{ .retry = status };

    // Copy what we need from the head before the body reader invalidates it.
    const content_type = try arena.dupe(u8, response.head.content_type orelse "application/json");
    const content_length = response.head.content_length;
    const is_sse = std.ascii.startsWithIgnoreCase(content_type, "text/event-stream");

    var transfer_buf: [64]u8 = undefined;
    const upstream_body = response.reader(&transfer_buf);
    var chunk: [16 * 1024]u8 = undefined;

    var attempt_buf: [12]u8 = undefined;
    const common_headers = [_]http.Header{
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = "x-omnigate-upstream", .value = up.name },
        .{ .name = "x-omnigate-attempts", .value = std.fmt.bufPrint(&attempt_buf, "{d}", .{attempt_no}) catch unreachable },
        .{ .name = "x-omnigate-request-id", .value = req_id },
    };

    // --- translated, not a stream: buffer, convert, answer in one piece -----
    if (mode == .translate and !is_sse) {
        const x = mode.translate;
        const raw = upstream_body.allocRemaining(arena, .limited(max_translated_body)) catch |err| switch (err) {
            error.ReadFailed => return if (guard.timedOut()) error.StreamIdleTimeout else (response.bodyErr() orelse error.ReadFailed),
            error.StreamTooLong => return error.UpstreamUnparseable,
            else => |e| return e,
        };
        if (@backingInt(status) == 400 and !x.sampling_stripped and quirks.mentionsSampling(raw)) return .drop_sampling;
        if (@backingInt(status) == 400 and !x.signatures_added and x.dir == .anthropic_to_openai and
            quirks.mentionsThoughtSignature(raw)) return .add_thought_signature;
        usage.feed(raw);
        const now_s = @divTrunc(Io.Timestamp.now(app.io, .real).toMilliseconds(), 1000);
        const converted = translate.translateResponseAt(arena, x.dir, @backingInt(status), raw, x.route_model, now_s) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // Not the shape its protocol promises: treat like a failed upstream.
            else => return error.UpstreamUnparseable,
        };
        committed.* = true;
        try request.respond(converted, .{
            .status = status,
            .extra_headers = &(.{http.Header{ .name = "content-type", .value = "application/json" }} ++ common_headers),
        });
        return .{ .done = status };
    }

    committed.* = true;
    var resp_buf: [8 * 1024]u8 = undefined;
    var body_writer = try request.respondStreaming(&resp_buf, .{
        // Only an untouched body keeps the upstream's length.
        .content_length = if (mode == .passthrough) content_length else null,
        .respond_options = .{
            .status = status,
            .extra_headers = &(.{http.Header{ .name = "content-type", .value = content_type }} ++ common_headers),
        },
    });

    var translator: ?translate.StreamTranslator = if (mode == .translate) blk: {
        const x = mode.translate;
        break :blk .init(arena, x.dir, x.route_model, .{
            .include_usage = x.include_usage,
            .created = @divTrunc(Io.Timestamp.now(app.io, .real).toMilliseconds(), 1000),
        });
    } else null;
    var usage_filter: usage_mod.UsageChunkFilter = .{};
    defer usage_filter.deinit(arena);

    while (true) {
        var vec = [_][]u8{&chunk};
        const n = upstream_body.readVec(&vec) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return if (guard.timedOut()) error.StreamIdleTimeout else (response.bodyErr() orelse error.ReadFailed),
        };
        if (n == 0) continue;
        usage.feed(chunk[0..n]);
        if (translator) |*tr| {
            try tr.feed(chunk[0..n], &body_writer.writer);
        } else if (mode == .hide_usage_chunk and is_sse) {
            try usage_filter.feed(arena, chunk[0..n], &body_writer.writer);
        } else {
            try body_writer.writer.writeAll(chunk[0..n]);
        }
        // Flush per chunk so SSE tokens reach the client immediately: first
        // our body buffer into the HTTP framing, then the framing to the socket
        // (`BodyWriter.flush` alone only does the second half).
        try body_writer.writer.flush();
        try body_writer.flush();
        guard.arm(app.io, app.stream_idle_timeout_ms);
    }
    if (translator) |*tr| try tr.finish(&body_writer.writer);
    if (mode == .hide_usage_chunk and is_sse) try usage_filter.finish(&body_writer.writer);
    try body_writer.end();
    return .{ .done = status };
}

/// Hand a `/v1/jobs*` or `/v1/files/*` request to the control plane at
/// `/internal<target>` and stream its answer back unchanged. `key_sha256` is
/// null only for signed file URLs, which the control plane verifies itself.
fn forwardToControl(
    app: *App,
    acc: *logging.Access,
    arena: std.mem.Allocator,
    request: *http.Server.Request,
    method: http.Method,
    target: []const u8,
    body: ?[]u8,
    hdrs: ClientHeaders,
    key_sha256: ?[]const u8,
) !void {
    const base = std.mem.trimEnd(u8, app.control_url, "/");
    const url = try std.fmt.allocPrint(arena, "{s}/internal{s}", .{ base, target });
    const uri = std.Uri.parse(url) catch
        return respondError(acc, request, .bad_request, "invalid_request", "malformed request path");

    var extra: std.ArrayList(http.Header) = .empty;
    try extra.append(arena, .{ .name = control.internal_header, .value = app.internal_token });
    if (key_sha256) |k| try extra.append(arena, .{ .name = "x-omnigate-key-sha256", .value = k });
    if (hdrs.idempotency_key) |k| try extra.append(arena, .{ .name = "idempotency-key", .value = k });

    var call: UpstreamCall = .{
        .client = app.client,
        .method = method,
        .uri = uri,
        .options = .{
            // No pooling: a restarted control plane must not leave a dead socket.
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{
                // The jobs API is JSON-only, whatever the client labelled it.
                .content_type = if (body != null) .{ .override = "application/json" } else .default,
                .accept_encoding = .{ .override = "identity" },
                .user_agent = .{ .override = "omnigate/0.1" },
            },
            .extra_headers = extra.items,
        },
        .body = body,
    };
    defer call.deinit();

    var response = call.openWithTimeout(app.io, control_timeout_ms) catch |err| {
        log.warn("control plane request {s} failed: {t}", .{ target, err });
        return respondError(acc, request, .service_unavailable, "control_plane_unavailable", "media jobs need the control plane, which is not reachable");
    };

    const status = response.head.status;
    acc.status = @backingInt(status);
    const content_type = try arena.dupe(u8, response.head.content_type orelse "application/json");
    const content_length = response.head.content_length;

    var resp_buf: [8 * 1024]u8 = undefined;
    var body_writer = try request.respondStreaming(&resp_buf, .{
        .content_length = content_length,
        .respond_options = .{
            .status = status,
            .extra_headers = &.{.{ .name = "content-type", .value = content_type }},
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
        try body_writer.writer.writeAll(chunk[0..n]);
        try body_writer.writer.flush();
        try body_writer.flush();
    }
    try body_writer.end();
}

fn respondRateLimited(acc: *logging.Access, request: *http.Server.Request, retry_after_s: u32) !void {
    acc.status = 429;
    var num: [16]u8 = undefined;
    const secs = std.fmt.bufPrint(&num, "{d}", .{retry_after_s}) catch unreachable;
    try request.respond(
        \\{"error":{"type":"rate_limit_exceeded","message":"this key is over its requests-per-minute limit"}}
    , .{
        .status = .too_many_requests,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "retry-after", .value = secs },
        },
    });
}

fn respondError(acc: *logging.Access, request: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8) !void {
    acc.status = @backingInt(status);
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    std.json.Stringify.value(.{ .@"error" = .{ .type = code, .message = message } }, .{}, &w) catch {};
    try request.respond(w.buffered(), .{
        .status = status,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

/// The routes this key may use.
fn respondModels(acc: *logging.Access, arena: std.mem.Allocator, request: *http.Server.Request, snapshot: *const config.Snapshot, key: *const config.Key) !void {
    acc.status = 200;
    const Model = struct { id: []const u8, object: []const u8 = "model", owned_by: []const u8 = "omnigate" };
    var models: std.ArrayList(Model) = .empty;
    for (snapshot.routes) |r| {
        if (key.allows(r.model)) try models.append(arena, .{ .id = r.model });
    }
    const json = try std.json.Stringify.valueAlloc(arena, .{ .object = "list", .data = models.items }, .{});
    try request.respond(json, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}
