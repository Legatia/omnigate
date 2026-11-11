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
//!
//! What a request may cost before it is judged: the key's concurrency cap,
//! its rate limit and the request-memory budget are all consulted before a
//! byte of the body is read (limits.zig); the body is then walked in place
//! for the three fields the gateway acts on, without building a tree of it
//! (jsonscan.zig), and a same-protocol request goes upstream as the client's
//! own bytes with the model name spliced. A tree is built only where one is
//! needed (translation, the response cache, rewriting an existing
//! `stream_options`), inside an allocator capped at a multiple of the body.
//!
//! What an upstream may do to us: its response body is framed and read by
//! framing.zig, never by std, and the client's response is framed by us,
//! never with a length the upstream claimed.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const balance = @import("balance.zig");
const cache = @import("cache.zig");
const config = @import("config.zig");
const control = @import("control.zig");
const errors = @import("errors.zig");
const framing = @import("framing.zig");
const guard_mod = @import("guard.zig");
const headers_mod = @import("headers.zig");
const jsonscan = @import("jsonscan.zig");
const limits = @import("limits.zig");
const models = @import("models.zig");
const logging = @import("logging.zig");
const quirks = @import("quirks.zig");
const redact = @import("redact.zig");
const translate = @import("translate.zig");
const usage_mod = @import("usage.zig");
const watchdog = @import("watchdog.zig");
const Usage = usage_mod.Usage;
const App = @import("main.zig").App;

const main = @import("main.zig");
const log = std.log.scoped(.proxy);

const max_request_body = 8 * 1024 * 1024;
/// Job requests are parsed by the control plane, whose limit is this (see
/// `@max_body_bytes` in its router): a body it would refuse is refused here,
/// with the same answer, instead of being sent across first.
const max_job_body = 8_000_000;
const default_anthropic_version = "2023-06-01";
/// How long the control plane gets to answer a jobs/files request.
const control_timeout_ms = 30_000;
/// Cap on an upstream response that must be buffered to be translated.
const max_translated_body = 16 * 1024 * 1024;
/// An answer that is not a stream and no longer than this is buffered and
/// sent with its real length; anything else goes out chunked.
const small_body_max = 64 * 1024;
/// A relayed `content-type` longer than this is not one.
const max_content_type_len = 256;
/// How long, and how much, to keep reading from a client after answering it
/// early and before closing (see `lingerClose`).
const linger_ms = 2_000;
const max_linger_bytes = 16 * 1024 * 1024;

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

    // Set when the connection is being closed by us right after an answer.
    // (Declared after `defer stream.close`, so this runs before the close.)
    var linger = false;
    defer if (linger) lingerClose(app, guard, stream, &stream_reader.interface);

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
                // std refused the head before any of it could be looked at.
                // Say so (best effort) instead of just hanging up.
                const answer: ?[]const u8 = switch (err) {
                    error.HttpHeadersInvalid => "HTTP/1.1 400 Bad Request\r\nconnection: close\r\ncontent-length: 0\r\n\r\n",
                    error.HttpHeadersOversize => "HTTP/1.1 431 Request Header Fields Too Large\r\nconnection: close\r\ncontent-length: 0\r\n\r\n",
                    else => null,
                };
                if (answer) |bytes| {
                    app.counters.count(app.gpa, app.io, "-", "invalid_request");
                    stream_writer.interface.writeAll(bytes) catch return;
                    stream_writer.interface.flush() catch return;
                    linger = true;
                }
                return;
            },
        };
        guard.idle.store(false, .release);
        // The rest of the request (its body) gets a fresh allowance.
        guard.arm(app.io, app.client_timeout_ms);

        // Before anything reads the head: std accepts some heads that its own
        // header iterator and body handling then assert on, and an assert in
        // one connection's task ends the process for all of them.
        const head_check = guard_mod.checkRequestHead(request.head_buffer, request.head.method.requestHasBody());
        if (head_check != .ok) {
            linger = true;
            switch (head_check) {
                .ok => unreachable, // checked on the line above
                .bad => |why| return refuseHead(app, &request, .bad_request, "invalid_request", why),
                .length_required => return refuseHead(app, &request, .length_required, "invalid_request", "a request with a body needs a content-length (chunked request bodies are not accepted)"),
                .expectation_failed => return refuseHead(app, &request, .expectation_failed, "invalid_request", "the only supported expectation is 100-continue"),
            }
        }
        // The check above took `100-continue` in any letter case, as the
        // header is defined. std compares it byte for byte and, when it
        // differs, fails every attempt to answer: the client got nothing.
        // Give std the one spelling it knows.
        if (request.head.expect != null) request.head.expect = "100-continue";

        var acc: logging.Access = .{};
        const started = Io.Timestamp.now(app.io, .awake);
        const outcome = handleRequest(app, &request, guard, &acc);
        acc.latency_ms = started.durationTo(Io.Timestamp.now(app.io, .awake)).toMilliseconds();
        if (outcome) |_| {} else |err| {
            // The watchdog cancels the task; say what that meant.
            acc.aborted = if (err == error.ClientDisconnected or err == error.ClientStalled or !guard.timedOut()) err else if (acc.status == 0) error.ClientTimeout else error.StreamIdleTimeout;
            if (acc.status == 0 and guard.timedOut()) acc.status = 408;
        }
        // Requests the gateway refused itself never become usage events;
        // count them so the control plane can still show them.
        if (acc.rejected) |reason| {
            app.counters.count(app.gpa, app.io, acc.key.get(), reason);
        } else if (acc.status == 408) {
            app.counters.count(app.gpa, app.io, acc.key.get(), "client_timeout");
        }
        const is_probe = acc.status == 200 and std.mem.eql(u8, acc.path.get(), "/healthz");
        logging.access(&acc, if (is_probe) .debug else .info);
        outcome catch return;
        // The watchdog cancelled this task and is waiting for it to end
        // (`Future.cancel` returns only then, and only the first blocking
        // call after it fails): whatever was answered, stop here.
        if (guard.timedOut()) return;
        guard.disarm();
        // The answer said `connection: close` (the client asked for it, or the
        // request was not fully read): close now, not at the next timeout.
        if (server.reader.state == .closing) {
            linger = true;
            return;
        }
    }
}

/// Close politely after answering a request that was not read to its end
/// (a refusal sent ahead of the body, typically a bad key on a POST).
///
/// Closing a socket that still has unread input makes the kernel send a
/// reset, and a reset can overtake the answer: the client then reports a
/// broken connection instead of the 401 it was sent. So: finish our side,
/// then read and drop what the client is still sending until it closes,
/// for a short, bounded time and amount. The watchdog ends the wait.
fn lingerClose(app: *App, guard: *watchdog.Conn, stream: anytype, reader: *Io.Reader) void {
    stream.shutdown(app.io, .send) catch return;
    guard.arm(app.io, linger_ms);
    var total: usize = 0;
    while (total < max_linger_bytes) {
        const n = reader.discard(.limited(64 * 1024)) catch return; // closed, reset, or time is up
        if (n == 0) return;
        total += n;
    }
}

/// Answer a request whose head was refused, and close: nothing about the
/// rest of the connection can be trusted. The answer is a fixed, small
/// OpenAI-shaped error; the request was never parsed far enough to know more.
fn refuseHead(app: *App, request: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8) void {
    app.counters.count(app.gpa, app.io, "-", code);
    log.debug("refused a request head: {s}", .{message});
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    errors.write(&w, .openai, .{ .status = @backingInt(status), .reason = code, .message = message, .request_id = "" }) catch {};
    // No body will be read, so there is nothing to say "continue" to; and with
    // any other expectation still set, std would refuse to answer at all.
    request.head.expect = null;
    request.respond(w.buffered(), .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    }) catch {};
}

/// May the connection be reused after answering now? Only when nothing of
/// this request is left unread: a body the server never consumed would be
/// parsed as the next request, which behind a proxy that pools connections
/// is another client's request.
fn reusable(request: *http.Server.Request) bool {
    return switch (request.server.reader.state) {
        .ready => true,
        .received_head => !request.head.method.requestHasBody(),
        else => false,
    };
}

const ClientHeaders = struct {
    api_key: ?[]const u8 = null,
    anthropic_version: ?[]const u8 = null,
    anthropic_beta: ?[]const u8 = null,
    idempotency_key: ?[]const u8 = null,
    /// `x-omnigate-privacy`, as sent.
    privacy: ?[]const u8 = null,
    privacy_repeated: bool = false,
    /// `x-omnigate-dry-run`, as sent.
    dry_run: ?[]const u8 = null,
    dry_run_repeated: bool = false,
};

/// What privacy mode does to one request: the key's setting, plus whatever
/// the request's own header added (it can add, never take away).
const Privacy = struct {
    /// Nothing of the request or the answer is kept here: no response cache.
    no_store: bool = false,
    /// Classes of values replaced by placeholders before the provider.
    redact: redact.ClassSet = .none,
    /// Fields that name an end user are removed.
    unlink: bool = false,
    /// Only targets whose attestation holds are used.
    attested: bool = false,

    fn of(key: *const config.Key, header: redact.Request) Privacy {
        var p: Privacy = .{ .no_store = header.no_store, .unlink = header.unlink, .attested = header.attested };
        if (header.redact) p.redact = .every;
        if (key.privacy) |k| {
            p.no_store = p.no_store or k.no_store;
            p.unlink = p.unlink or k.unlink;
            p.attested = p.attested or k.attested;
            for (k.redact) |name| {
                if (redact.Class.parse(name)) |c| p.redact.add(c);
            }
        }
        return p;
    }

    /// For the `x-omnigate-privacy` response header: what was applied.
    fn note(p: Privacy) ?[]const u8 {
        const r = !p.redact.isEmpty();
        if (p.no_store and r and p.unlink) return "no-store, redact, unlink";
        if (p.no_store and r) return "no-store, redact";
        if (p.no_store and p.unlink) return "no-store, unlink";
        if (r and p.unlink) return "redact, unlink";
        if (p.no_store) return "no-store";
        if (r) return "redact";
        if (p.unlink) return "unlink";
        return null;
    }
};

/// Request fields that name an end user to a provider, or tie one request to
/// another, by the protocol the client speaks (checked against both
/// providers' API references in November 2026):
///
///   * OpenAI: `user` (deprecated), `safety_identifier`, `prompt_cache_key`,
///     and `metadata` (free-form tags, kept with a stored completion);
///   * Anthropic: `metadata` (its one field is `user_id`) and `diagnostics`
///     (its `previous_message_id` names the client's previous response).
///
/// Fields a request needs in order to work at all are not on the list, even
/// where they link requests (`previous_response_id`, `conversation`,
/// Anthropic's `container`): removing them would change what was asked for.
const linking_fields_openai = [_][]const u8{ "user", "safety_identifier", "prompt_cache_key", "metadata" };
const linking_fields_anthropic = [_][]const u8{ "metadata", "diagnostics" };

/// Counter names for redactions, by class (see counters.zig).
const redaction_counters = [redact.Class.count][]const u8{ "redacted_email", "redacted_phone", "redacted_card", "redacted_ip", "redacted_secret" };

/// Does this upstream keep what it is sent unless told `"store": false`?
/// Only OpenAI itself documents the flag (chat completions and responses);
/// other servers that speak its protocol are not sent a field they may
/// refuse.
fn takesStoreFlag(up: *const config.Upstream, path: []const u8) bool {
    if (up.kind != .openai) return false;
    if (!std.mem.eql(u8, path, "/v1/chat/completions") and !std.mem.eql(u8, path, "/v1/responses")) return false;
    // The operator may say so either way (a proxy in front of OpenAI, or a
    // compatible server that is known to take the flag).
    if (up.privacy_store_flag) |flag| return flag;
    const after_scheme = if (std.mem.find(u8, up.base_url, "://")) |at| up.base_url[at + 3 ..] else up.base_url;
    const host = after_scheme[0 .. std.mem.findAny(u8, after_scheme, "/:?") orelse after_scheme.len];
    return std.ascii.eqlIgnoreCase(host, "api.openai.com");
}

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

    // One id per client request. It is on every response as
    // `x-omnigate-request-id`, and as `x-request-id` / `request-id` (what the
    // OpenAI and Anthropic SDKs read) unless the provider supplied its own;
    // it is also the usage event id the ledger dedups on.
    var raw_id: [16]u8 = undefined;
    app.io.random(&raw_id);
    const req_id = std.fmt.bytesToHex(raw_id, .lower);
    acc.request_id.set(&req_id);
    // A request without a body is complete. From here the deadline is on our
    // answer reaching the client: a client that takes none of it for the
    // stall timeout is given up on, whether the answer is a provider's or
    // one of our own (an error, the model list, a cache hit). It is lifted
    // while waiting for an upstream, which has its own timeout, and set
    // again by `readBody` for a request that has a body. (A refusal sent
    // before the body was read is under the client timeout armed with the
    // head.)
    if (!method.requestHasBody()) guard.arm(app.io, app.client_stall_timeout_ms);

    // Header strings are invalidated once the body reader is created; copy now.
    var hdrs: ClientHeaders = .{};
    var it = guard_mod.HeaderIterator.init(request.head_buffer);
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
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-omnigate-privacy")) {
            // Sent twice, there is no telling which one a reader would take.
            if (hdrs.privacy != null) hdrs.privacy_repeated = true;
            hdrs.privacy = try arena.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-omnigate-dry-run")) {
            if (hdrs.dry_run != null) hdrs.dry_run_repeated = true;
            hdrs.dry_run = try arena.dupe(u8, h.value);
        }
    }

    // Which protocol this client speaks, for the shape of errors and of the
    // model list: Anthropic's on its own endpoints, and on the shared
    // `/v1/models` when the request carries Anthropic's version header.
    acc.anthropic = std.mem.startsWith(u8, path, "/v1/messages") or
        (hdrs.anthropic_version != null and std.mem.startsWith(u8, path, "/v1/models"));

    if (method == .GET and std.mem.eql(u8, path, "/healthz")) {
        acc.status = 200;
        return request.respond("ok\n", .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
    }

    // One spelling per path, so that what a request is taken for here and
    // what is forwarded can never differ; and nothing a client sent is copied
    // into a request of ours unless it is plain.
    if (!guard_mod.canonicalPath(path))
        return respondError(acc, request, .bad_request, "invalid_request", "the request path is not in canonical form");
    if (!guard_mod.safeQuery(query))
        return respondError(acc, request, .bad_request, "invalid_request", "the query string contains unsupported characters");
    if (hdrs.anthropic_version) |v| if (!guard_mod.safeHeaderValue(v, "-._", 32))
        return respondError(acc, request, .bad_request, "invalid_request", "invalid anthropic-version header");
    if (hdrs.anthropic_beta) |v| if (!guard_mod.safeHeaderValue(v, "-._, ", 512))
        return respondError(acc, request, .bad_request, "invalid_request", "invalid anthropic-beta header");
    // The privacy header can only switch protections on. Anything it does
    // not spell exactly is refused: a request that asked for privacy and
    // mistyped it must not go out without.
    if (hdrs.privacy_repeated)
        return respondError(acc, request, .bad_request, "invalid_request", "x-omnigate-privacy was sent more than once");
    const privacy_request: redact.Request = if (hdrs.privacy) |v|
        redact.Request.parse(v) orelse
            return respondError(acc, request, .bad_request, "invalid_request", "invalid x-omnigate-privacy header: use \"on\", or a comma-separated list of no-store, redact, unlink, attested (it can only switch protections on)")
    else
        .{};
    // A dry run sends nothing anywhere. One kind exists; a value that is not
    // it is refused, because a request meant to stay here must not be sent
    // on for a spelling mistake.
    if (hdrs.dry_run_repeated)
        return respondError(acc, request, .bad_request, "invalid_request", "x-omnigate-dry-run was sent more than once");
    const dry_run_privacy = if (hdrs.dry_run) |v| blk: {
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t"), "privacy"))
            return respondError(acc, request, .bad_request, "invalid_request", "invalid x-omnigate-dry-run header: the one value is \"privacy\"");
        break :blk true;
    } else false;
    // `idempotency-key` is looked at where it is used: on job requests,
    // below. Elsewhere it is not forwarded, so what it contains is the
    // client's business (SDKs send one of their own on every call).

    const snapshot = app.store.get(app.io) orelse
        return respondError(acc, request, .service_unavailable, "gateway_not_ready", "no config from control plane yet");

    const is_files = std.mem.startsWith(u8, path, "/v1/files/");
    const is_jobs = std.mem.eql(u8, path, "/v1/jobs") or std.mem.startsWith(u8, path, "/v1/jobs/");

    // A signed output URL carries its own proof; the control plane checks it.
    if (is_files and method == .GET and hdrs.api_key == null and hasQueryParam(query, "sig")) {
        return forwardToControl(app, acc, arena, request, guard, method, path, query, null, null, null, false);
    }

    // --- authentication -------------------------------------------------
    const presented = hdrs.api_key orelse
        return respondError(acc, request, .unauthorized, "missing_api_key", "send Authorization: Bearer <key> or x-api-key");
    const key_hash = config.sha256Hex(presented);
    const key = snapshot.findKey(&key_hash) orelse
        return respondError(acc, request, .unauthorized, "invalid_api_key", "unknown gateway key");
    acc.key.set(key.name);

    const endpoint: ?Endpoint = if (method == .POST) Endpoint.forPath(path) else null;
    const is_job_create = method == .POST and std.mem.eql(u8, path, "/v1/jobs");

    // A key over its budget may not start anything new. It keeps access to
    // what it already has: the model list, the state and files of its jobs,
    // and cancelling a job (which only saves money).
    if (key.blocked and (endpoint != null or is_job_create))
        return respondError(acc, request, .payment_required, "budget_exceeded", "this key has exhausted its budget");

    if (method == .GET and std.mem.eql(u8, path, "/v1/models")) {
        return respondModels(app, acc, arena, request, snapshot, key, null);
    }
    if (method == .GET and std.mem.startsWith(u8, path, "/v1/models/")) {
        return respondModels(app, acc, arena, request, snapshot, key, path["/v1/models/".len..]);
    }

    // --- async media jobs: owned by the control plane ---------------------
    // (which also applies the key's model limits to them)
    if (is_jobs or is_files) {
        if (method != .GET and method != .POST)
            return respondError(acc, request, .method_not_allowed, "method_not_allowed", "use GET or POST");
        // Forwarded to the control plane as a header, so nothing in it may
        // be able to end one: visible ASCII, which is what UUIDs, base64
        // and every other key a client is likely to generate are made of.
        if (hdrs.idempotency_key) |v| if (!guard_mod.visibleToken(v, 255))
            return respondError(acc, request, .bad_request, "invalid_request", "invalid idempotency-key header: use up to 255 visible ASCII characters, without spaces");
        // Before the body is read: how many requests this key has in flight
        // and how much memory they hold, then its rate limit.
        var hold: Hold = .{};
        defer hold.release(app, &key_hash);
        if (method == .POST) {
            if (!try admit(app, acc, request, &key_hash, key, max_job_body, &hold)) return;
        }
        // Only requests that start work count against the rate limit;
        // polling a job does not.
        if (is_job_create) {
            if (rateLimited(app, &key_hash, key)) |secs| return respondRateLimited(acc, request, secs);
        }
        const job_body: ?[]u8 = if (method == .POST)
            (try readBody(app, arena, request, guard, max_job_body)) orelse
                return respondError(acc, request, .payload_too_large, "payload_too_large", "the request body is larger than the jobs API accepts (8,000,000 bytes)")
        else
            null;
        if (job_body) |b| if (!guard_mod.jsonDepthOk(b, guard_mod.max_client_json_depth))
            return respondError(acc, request, .bad_request, "invalid_json", "request body is nested too deeply");
        if (dry_run_privacy)
            return respondError(acc, request, .bad_request, "invalid_request", "x-omnigate-dry-run is for text endpoints; a media job has no body that is rewritten");
        // No media provider proves what it runs on, so a job that may only
        // go to an attested one cannot go anywhere.
        if (is_job_create and (privacy_request.attested or (key.privacy != null and key.privacy.?.attested)))
            return respondError(acc, request, .service_unavailable, "attestation_unverified", "this request may only go to an attested provider, and no media provider is attested");
        // (The key's own setting is the control plane's to apply; the
        // header's wish for this one job is passed on.)
        return forwardToControl(app, acc, arena, request, guard, method, path, query, job_body, hdrs.idempotency_key, &key_hash, is_job_create and privacy_request.no_store);
    }

    const ep = endpoint orelse
        return respondError(acc, request, .not_found, "not_found", "unsupported endpoint");
    const kind = ep.kind;

    // --- limits, before the body is read ------------------------------------
    // Nothing a request costs comes before these: the key's requests in
    // flight and the memory they hold (limits.zig), then its rate limit. A
    // request refused by its model limits or for being malformed has
    // therefore been counted against the rate limit; that is the price of
    // not reading eight megabytes to find out.
    var hold: Hold = .{};
    defer hold.release(app, &key_hash);
    if (!try admit(app, acc, request, &key_hash, key, max_request_body, &hold)) return;
    if (ep.metered) {
        if (rateLimited(app, &key_hash, key)) |secs| return respondRateLimited(acc, request, secs);
    }

    // --- body -------------------------------------------------------------
    const client_body = (try readBody(app, arena, request, guard, max_request_body)) orelse
        return respondError(acc, request, .payload_too_large, "payload_too_large", "request body exceeds 8 MiB");

    // Bounded nesting, before anything parses it: the serialiser this body
    // may go through again indexes past a fixed stack beyond 256 levels.
    if (!guard_mod.jsonDepthOk(client_body, guard_mod.max_client_json_depth))
        return respondError(acc, request, .bad_request, "invalid_json", "request body is nested too deeply");

    // One pass over the body, in place, nothing allocated: is it JSON, what
    // model does it name, is it a stream (jsonscan.zig).
    const client_top = jsonscan.scan(client_body, .{ .max_depth = guard_mod.max_client_json_depth }) catch |err| {
        const first = std.mem.findNone(u8, client_body, " \t\r\n");
        return switch (err) {
            error.InvalidJson => if (first != null and client_body[first.?] != '{' and std.json.validate(arena, client_body) catch false)
                respondError(acc, request, .bad_request, "invalid_json", "request body must be a JSON object")
            else
                respondError(acc, request, .bad_request, "invalid_json", "request body is not valid JSON"),
            error.TooDeep => respondError(acc, request, .bad_request, "invalid_json", "request body is nested too deeply"),
            error.TooManyMembers => respondError(acc, request, .bad_request, "invalid_request", "a JSON object in the request body has too many members"),
            error.KeyTooLong => respondError(acc, request, .bad_request, "invalid_request", "a key in the request body is too long"),
            error.DuplicateField => respondError(acc, request, .bad_request, "invalid_request", "\"model\", \"stream\" and \"stream_options\" may each appear only once"),
            error.EscapedFieldName => respondError(acc, request, .bad_request, "invalid_request", "\"model\", \"stream\" and \"stream_options\" must be spelled without escapes"),
            error.AmbiguousFieldName => respondError(acc, request, .bad_request, "invalid_request", "\"model\", \"stream\", \"stream_options\" and \"include_usage\" must be spelled exactly so, in lower case"),
            error.InvalidFieldType => respondError(acc, request, .bad_request, "invalid_request", "\"stream\" and \"stream_options.include_usage\" must be true or false"),
        };
    };

    const model_span = client_top.model orelse
        return respondError(acc, request, .bad_request, "missing_model", "request has no \"model\" field");
    const model_text = client_body[model_span.start..model_span.end];
    if (model_text.len < 2 or model_text[0] != '"')
        return respondError(acc, request, .bad_request, "missing_model", "\"model\" must be a string");
    const route_model: []const u8 = if (std.mem.findScalar(u8, model_text, '\\') == null)
        model_text[1 .. model_text.len - 1]
    else
        // Written with escapes (a slash as `\/`, say): decode this one string.
        std.json.parseFromSliceLeaky([]const u8, arena, model_text, .{}) catch
            return respondError(acc, request, .bad_request, "missing_model", "\"model\" is not a valid string");
    acc.model.set(route_model);
    const is_stream = client_top.stream;

    // --- model limits -------------------------------------------------------
    // Before the route lookup, so the answer does not reveal which other
    // models exist.
    if (!key.allows(route_model))
        return respondError(acc, request, .forbidden, "model_not_allowed", "this key may not use this model");

    const route = snapshot.findRoute(route_model) orelse
        return respondError(acc, request, .not_found, "model_not_found", "no route for this model");

    // --- privacy mode -------------------------------------------------------
    // What the provider is not shown (redact.zig): the fields that name an
    // end user are taken out, and addresses, numbers and secrets in the text
    // are replaced by placeholders, which `forward` turns back in the answer.
    // Everything from here on works on the result as if the client had sent
    // it; the map lives in this request's arena and nowhere else.
    const privacy: Privacy = .of(key, privacy_request);
    var body: []const u8 = client_body;
    var top = client_top;
    var redactions: redact.Map = .{};
    var redact_reserved: u64 = 0;
    defer if (redact_reserved != 0) app.gate.releaseTree(app.io, &key_hash, redact_reserved);
    if (privacy.unlink) {
        const linking: []const []const u8 = switch (kind) {
            .openai => &linking_fields_openai,
            .anthropic => &linking_fields_anthropic,
        };
        if (redact.editTop(arena, body, linking, "") catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidJson => return respondError(acc, request, .bad_request, "invalid_json", "request body is not valid JSON"),
        }) |edited| body = edited;
    }
    if (!privacy.redact.isEmpty() and ep.redact) {
        // The copy with placeholders in it is held next to the original.
        const reserve: u64 = 2 * @as(u64, body.len);
        switch (app.gate.reserveTree(app.io, &key_hash, reserve)) {
            .ok => redact_reserved = reserve,
            .key_share => return respondTreeRefusal(acc, request, .key_share),
            .budget, .concurrency => return respondTreeRefusal(acc, request, .budget),
        }
        var seed: [8]u8 = undefined;
        app.io.random(&seed);
        redactions.seed = std.mem.readInt(u64, &seed, .little);
        // Looking through megabytes takes a moment, and that moment is ours:
        // the deadline for a client that does not take its answer (armed when
        // the body had been read) does not run meanwhile.
        guard.disarm();
        const redacted = redact.redactBody(arena, body, privacy.redact, &redactions);
        guard.arm(app.io, app.client_stall_timeout_ms);
        body = redacted catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidJson => return respondError(acc, request, .bad_request, "invalid_json", "request body is not valid JSON"),
            error.TooManyRedactions => return respondError(acc, request, .bad_request, "too_many_redactions", "this request holds more distinct values to redact than one request may (16384); send less text at once"),
        };
        for (redact.Class.all) |c| {
            const hits = redactions.hits[c.index()];
            if (hits != 0) app.counters.countN(app.gpa, app.io, key.name, redaction_counters[c.index()], hits);
        }
    }
    if (body.ptr != client_body.ptr) {
        // Only string contents and whole members changed: still one object.
        top = jsonscan.scan(body, .{ .max_depth = guard_mod.max_client_json_depth }) catch
            return respondError(acc, request, .bad_request, "invalid_json", "request body is not valid JSON");
        if (top.model == null) return respondError(acc, request, .bad_request, "missing_model", "request has no \"model\" field");
    }
    var restorer: redact.Restorer = .init(&redactions);

    // --- dry run ------------------------------------------------------------
    // `x-omnigate-dry-run: privacy`: answer with the request as privacy mode
    // left it, which is what a provider would be sent (before the model name
    // is replaced by the target's), and send nothing. It went through the
    // same code as a request that is forwarded, up to this line.
    if (dry_run_privacy) {
        var out: Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.writeAll("{\"object\":\"omnigate.privacy_dry_run\",\"sent_upstream\":false,\"protections\":");
        try std.json.Stringify.value(privacy.note() orelse "", .{}, w);
        try w.print(",\"attested_only\":{},\"replaced\":{{", .{privacy.attested});
        for (redact.Class.all, 0..) |c, i| {
            if (i != 0) try w.writeByte(',');
            try w.print("\"{s}\":{d}", .{ c.name(), redactions.hits[c.index()] });
        }
        try w.writeAll("},\"body\":");
        try std.json.Stringify.value(body, .{}, w);
        try w.writeByte('}');
        acc.status = 200;
        var dry_headers: std.ArrayList(http.Header) = .empty;
        try dry_headers.appendSlice(arena, &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "x-omnigate-dry-run", .value = "privacy" },
            .{ .name = "x-omnigate-request-id", .value = &req_id },
            .{ .name = "x-request-id", .value = &req_id },
            .{ .name = "request-id", .value = &req_id },
        });
        if (privacy.note()) |note| try dry_headers.append(arena, .{ .name = "x-omnigate-privacy", .value = note });
        return request.respond(out.written(), .{ .status = .ok, .keep_alive = reusable(request), .extra_headers = dry_headers.items });
    }

    const started = Io.Timestamp.now(app.io, .awake);

    // --- response cache -----------------------------------------------------
    // Only for routes that ask for it, and never for streams. The lookup comes
    // after authentication, model limits, the budget and the rate limit, so a
    // cached answer is subject to all of them.
    var extras: ForwardExtras = .{
        .key_hash = &key_hash,
        .privacy_note = privacy.note(),
        // Only an endpoint that answers with text has anything to put back.
        .restorer = if (ep.restore and !redactions.isEmpty()) &restorer else null,
    };
    // An exchange `forward` handed back and nobody took over is closed here.
    defer if (extras.parked) |*left| left.req.deinit();
    var capture: Capture = .{ .limit = app.cache.maxEntryBytes() };
    var cache_key: ?cache.Key = null;
    // Never for a private request: a "no-store" request leaves nothing
    // behind, and an answer that was written around placeholders belongs to
    // the request that made them.
    // Nor for one that may only be answered by an attested provider: the
    // cache does not know who wrote what it holds.
    const cacheable = ep.metered and !is_stream and app.cache.max_bytes > 0 and !privacy.no_store and privacy.redact.isEmpty() and !privacy.attested;
    const cache_ttl_ms: i64 = if (cacheable) @as(i64, route.cache_ttl_s) * 1000 else 0;
    // The key is the request in canonical form, which takes a tree of it. A
    // body too costly to parse (see `cacheKeyFor`) is simply not cached.
    if (cache_ttl_ms > 0) if (cacheKeyFor(app, route_model, path, &key_hash, body, top)) |ck| {
        const cached = app.cache.get(app.io, arena, &ck, started.toMilliseconds());
        // (The stored content type was checked when it was stored; checked
        // again, because it is about to be a header line.)
        if (cached) |hit| if (framing.plainHeaderValue(hit.content_type, max_content_type_len)) {
            acc.status = hit.status;
            acc.cache_hit = true;
            // Counted, not billed: no tokens, and marked as served from cache.
            report(app, arena, .{
                .id = &req_id,
                .key_sha256 = &key_hash,
                .route_model = route_model,
                .upstream = null,
                .target_model = null,
                .status = hit.status,
                .stream = false,
                .input_tokens = 0,
                .output_tokens = 0,
                .latency_ms = started.durationTo(Io.Timestamp.now(app.io, .awake)).toMilliseconds(),
                .attempts = &.{},
                .cached = true,
            });
            return request.respond(hit.body, .{
                .status = @fromBackingInt(@intCast(hit.status)),
                .keep_alive = reusable(request),
                .extra_headers = &.{
                    .{ .name = "content-type", .value = hit.content_type },
                    .{ .name = "x-omnigate-cache", .value = "hit" },
                    .{ .name = "x-omnigate-request-id", .value = &req_id },
                    .{ .name = "x-request-id", .value = &req_id },
                    .{ .name = "request-id", .value = &req_id },
                },
            });
        };
        cache_key = ck;
        extras.cache_note = "miss";
        extras.capture = &capture;
    };

    // OpenAI only reports usage on streams when asked to. If the client did
    // not ask, we do (to meter the call) and hide the extra chunk from it.
    const client_wants_usage = top.stream_options != null and top.stream_options_plain and top.include_usage;
    const injected_usage = ep.inject_stream_usage and is_stream and !client_wants_usage;
    // What goes upstream when no translation is needed: the client's own
    // bytes, with the model name replaced per target (and, when usage has to
    // be asked for and the client sent no `stream_options` at all, that
    // member added). Only a request that already carries `stream_options`
    // without the flag needs it rewritten, which takes a tree.
    var plain_body: []const u8 = body;
    var plain_top = top;
    if (injected_usage and top.stream_options != null) {
        if (top.max_members > guard_mod.max_tree_members) return respondTreeRefusal(acc, request, .too_complex);
        var refusal: ?TreeRefusal = null;
        const rewritten = try inTree(app, arena, &key_hash, body.len, &refusal, requestUsage, .{body});
        if (refusal != null) return respondTreeRefusal(acc, request, refusal);
        plain_body = rewritten orelse
            return respondError(acc, request, .bad_request, "invalid_json", "request body is not valid JSON");
        plain_top = jsonscan.scan(plain_body, .{ .max_depth = guard_mod.max_client_json_depth + 1 }) catch
            return respondError(acc, request, .bad_request, "invalid_json", "request body is not valid JSON");
        // (It was there before the rewrite; `jsonscan.rewrite` relies on it.)
        if (plain_top.model == null)
            return respondError(acc, request, .bad_request, "missing_model", "request has no \"model\" field");
    }
    const add_usage_member = injected_usage and plain_top.stream_options == null;

    // --- failover loop ----------------------------------------------------
    var attempts: std.ArrayList(Attempt) = .empty;
    var usage: Usage = .{};
    // `retry-after` of the most recent upstream answer that made us fail
    // over, to pass on if that turns out to have been the last attempt.
    var last_retry_after: ?[]const u8 = null;
    // Status of the last attempt, when it got an HTTP answer at all.
    var last_status: ?u16 = null;
    // Did any target answer 429, and the longest wait any of them asked for.
    var any_rate_limited = false;
    var longest_retry_after: ?[]const u8 = null;

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
    // Targets passed over because their attestation does not hold, or
    // because the request wanted an attested one and they are not.
    var unattested: u32 = 0;
    for (order) |target_index| {
        const t = &route.targets[target_index];
        const up = snapshot.findUpstream(t.upstream) orelse {
            try attempts.append(arena, .{ .upstream = t.upstream, .outcome = "unknown_upstream" });
            continue;
        };
        // An upstream that has to prove what it runs on is only used while
        // that proof holds; a request that asked for such an upstream is
        // sent to no other. Either way the target is passed over like one
        // that is down, and what is left decides.
        if (t.attestation) |verdict| {
            if (!verdict.holds(control.syncedAgoMs(app))) {
                try attempts.append(arena, .{ .upstream = up.name, .outcome = "attestation_unverified" });
                unattested += 1;
                continue;
            }
            extras.attestation_note = try std.fmt.allocPrint(arena, "verified; tcb={s}; since={d}", .{
                if (verdict.tcb) |tcb| (if (framing.plainHeaderValue(tcb, 64)) tcb else "unknown") else "unknown",
                verdict.since,
            });
        } else {
            if (privacy.attested) {
                try attempts.append(arena, .{ .upstream = up.name, .outcome = "not_attested" });
                unattested += 1;
                continue;
            }
            extras.attestation_note = null;
        }
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

        var refusal: ?TreeRefusal = null;
        var out_body: []u8 = if (xlate) |x| translated: {
            // The other protocol: the one place a tree of the request is
            // unavoidable. Bounded in members per object (hash collisions)
            // and in memory (a multiple of the body), see limits.zig.
            if (top.max_members > guard_mod.max_tree_members) return respondTreeRefusal(acc, request, .too_complex);
            const converted = try inTree(app, arena, &key_hash, body.len, &refusal, translate.translateRequest, .{ x.dir, body, t.model });
            if (refusal != null) return respondTreeRefusal(acc, request, refusal);
            break :translated converted orelse {
                try attempts.append(arena, .{ .upstream = up.name, .outcome = "untranslatable_request" });
                continue;
            };
        } else try jsonscan.rewrite(arena, plain_body, plain_top, try std.json.Stringify.valueAlloc(arena, t.model, .{}), add_usage_member);
        const upstream_path: []const u8 = if (xlate == null) path else switch (up.kind) {
            .openai => "/v1/chat/completions",
            .anthropic => "/v1/messages",
        };
        // A private request tells a provider that would otherwise keep the
        // exchange not to (`"store": false`), whatever the client said.
        if (privacy.no_store and takesStoreFlag(up, upstream_path)) {
            const drop: []const []const u8 = if (std.mem.eql(u8, upstream_path, "/v1/chat/completions")) &.{ "store", "metadata" } else &.{"store"};
            if (redact.editTop(arena, out_body, drop, "\"store\":false") catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.InvalidJson => null,
            }) |edited| out_body = edited;
        }
        var mode: ForwardMode = if (xlate) |x|
            .{ .translate = x }
        else if (injected_usage)
            .hide_usage_chunk
        else
            .passthrough;

        // A model already known to reject sampling parameters (see quirks.zig)
        // gets the translated request without them from the start.
        if (mode == .translate and app.quirks.rejectsSampling(app.io, &key_hash, up.name, t.model)) {
            if (try inTree(app, arena, &key_hash, out_body.len, &refusal, quirks.stripSampling, .{out_body})) |stripped| out_body = stripped;
            mode.translate.sampling_stripped = true;
        }
        if (mode == .translate and app.quirks.needsThoughtSignature(app.io, &key_hash, up.name, t.model)) {
            if (try inTree(app, arena, &key_hash, out_body.len, &refusal, quirks.addThoughtSignatures, .{out_body})) |signed| out_body = signed;
            mode.translate.signatures_added = true;
        }
        if (refusal != null) return respondTreeRefusal(acc, request, refusal);

        tried += 1;
        var committed = false;
        var maybe_result: ?ForwardResult = null;
        var tries: u8 = 0;
        while (tries < 2) : (tries += 1) {
            extras.retry_after = null;
            if (forward(app, arena, request, guard, up, upstream_path, out_body, hdrs, &usage, &req_id, &committed, mode, tried, &extras)) |r| {
                if (r == .drop_sampling) {
                    // The model refused temperature/top_p/top_k, which a client
                    // of the other protocol could not have known. Remember it
                    // and send the same request once more without them.
                    app.quirks.noteRejectsSampling(app.gpa, app.io, &key_hash, up.name, t.model);
                    mode.translate.sampling_stripped = true;
                    if (try inTree(app, arena, &key_hash, out_body.len, &refusal, quirks.stripSampling, .{out_body})) |stripped| {
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
                    app.quirks.noteNeedsThoughtSignature(app.gpa, app.io, &key_hash, up.name, t.model);
                    mode.translate.signatures_added = true;
                    if (try inTree(app, arena, &key_hash, out_body.len, &refusal, quirks.addThoughtSignatures, .{out_body})) |signed| {
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
                    // The provider's closing usage may never have arrived
                    // (OpenAI sends it last). The provider still charges for
                    // what it generated, so bill an estimate rather than
                    // nothing; never less than what was metered.
                    const estimated = !usage.final_seen;
                    const input_estimate = usage_mod.estimateInput(body);
                    const used = if (estimated) usage.estimated(up.kind, input_estimate) else usage.normalized(up.kind);
                    acc.status = 499;
                    acc.upstream.set(up.name);
                    acc.attempts = tried;
                    acc.estimated = estimated;
                    acc.input_tokens = used.input_tokens;
                    acc.cached_input_tokens = used.cached_input_tokens +| used.cache_write_input_tokens;
                    acc.output_tokens = used.output_tokens;
                    const event: UsageReport = .{
                        .id = &req_id,
                        .key_sha256 = &key_hash,
                        .route_model = route_model,
                        .upstream = up.name,
                        .target_model = t.model,
                        .status = 499,
                        .stream = is_stream,
                        .input_tokens = used.input_tokens,
                        .cached_input_tokens = used.cached_input_tokens,
                        .cache_write_input_tokens = used.cache_write_input_tokens,
                        .output_tokens = used.output_tokens,
                        .estimated = estimated,
                        .latency_ms = started.durationTo(Io.Timestamp.now(app.io, .awake)).toMilliseconds(),
                        .attempts = attempts.items,
                    };
                    // It was the client that went (or stopped reading) and
                    // the upstream is still answering: its answer is read to
                    // the end in the background, and what that finds is what
                    // gets billed (see `Drains`). The request's place in the
                    // key's allowance goes with it.
                    if (extras.parked) |taken| {
                        var parked = taken;
                        extras.parked = null;
                        if (ep.metered and startDrain(app, &parked, &usage, up.kind, input_estimate, event, &key_hash, hold, started)) {
                            hold.held = false;
                            return err;
                        }
                        parked.req.deinit();
                    }
                    if (ep.metered) report(app, arena, event);
                    return err;
                }
                // The watchdog cancelled this task (shutdown; nothing else
                // arms it while an upstream is awaited). It waits for the
                // task to end, and no later call here could be interrupted:
                // do not start on another upstream.
                if (guard.timedOut()) return err;
                // A pooled keep-alive connection may have been closed by the
                // upstream while idle: try once more before giving up on it.
                if (tries == 0 and worthRetrying(err)) {
                    log.debug("upstream {s}: {t}, retrying on a fresh connection", .{ up.name, err });
                    continue;
                }
                try attempts.append(arena, .{ .upstream = up.name, .outcome = @errorName(err) });
                log.warn("upstream {s} failed: {t}", .{ up.name, err });
                noteFailure(app, up.name);
                last_retry_after = null;
                last_status = null;
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
                last_retry_after = extras.retry_after;
                last_status = @backingInt(status);
                if (last_status.? == 429) {
                    any_rate_limited = true;
                    longest_retry_after = headers_mod.longerRetryAfter(longest_retry_after, extras.retry_after);
                }
            },
            // Handled inside the loop above; they never escape it.
            .drop_sampling, .add_thought_signature => unreachable,
            .done => |status| {
                app.health.recordSuccess(app.io, up.name);
                // An event stream that ended without the provider's closing
                // figures: the upstream ignored `stream_options` (many
                // OpenAI-compatible servers do), or streamed although this
                // module read the request as not a stream. The provider
                // charges all the same, so what came back is billed as an
                // estimate, as for a stream that was cut off: never nothing.
                const estimated = ep.metered and usage.framing == .sse and !usage.final_seen and
                    @backingInt(status) >= 200 and @backingInt(status) < 300;
                const used = if (estimated) usage.estimated(up.kind, usage_mod.estimateInput(body)) else usage.normalized(up.kind);
                acc.status = @backingInt(status);
                acc.upstream.set(up.name);
                acc.attempts = tried;
                acc.estimated = estimated;
                acc.input_tokens = used.input_tokens;
                acc.cached_input_tokens = used.cached_input_tokens +| used.cache_write_input_tokens;
                acc.output_tokens = used.output_tokens;
                try attempts.append(arena, .{ .upstream = up.name, .outcome = "ok" });
                // A whole successful answer for a route that caches: keep it.
                if (cache_key) |*ck| {
                    const code = @backingInt(status);
                    if (capture.complete and code >= 200 and code < 300) {
                        const now = Io.Timestamp.now(app.io, .awake).toMilliseconds();
                        app.cache.put(app.io, ck, code, capture.content_type, capture.body.items, cache_ttl_ms, now);
                    }
                }
                if (ep.metered) report(app, arena, .{
                    .id = &req_id,
                    .key_sha256 = &key_hash,
                    .route_model = route_model,
                    .upstream = up.name,
                    .target_model = t.model,
                    .status = @backingInt(status),
                    .stream = is_stream,
                    .input_tokens = used.input_tokens,
                    .cached_input_tokens = used.cached_input_tokens,
                    .cache_write_input_tokens = used.cache_write_input_tokens,
                    .output_tokens = used.output_tokens,
                    .estimated = estimated,
                    .latency_ms = started.durationTo(Io.Timestamp.now(app.io, .awake)).toMilliseconds(),
                    .attempts = attempts.items,
                });
                return;
            },
        }
    }

    // Nothing was sent because every target that could have taken the
    // request lacks a verified attestation. Nothing is wrong with the
    // request, and it must not go anywhere else: "not now".
    if (tried == 0 and unattested > 0) {
        acc.attempts = 0;
        return respondError(acc, request, .service_unavailable, "attestation_unverified", if (privacy.attested)
            "this request may only go to an attested provider, and no target of this model has a verified attestation right now"
        else
            "the providers of this model must prove what they run on, and none has a verified attestation right now");
    }

    // Nothing was sent upstream because no target can serve this request at
    // all. That is a fault of the request, not an outage: say so with a 400.
    if (tried == 0 and attempts.items.len > 0) {
        var all_mismatch = true;
        var all_unservable = true;
        for (attempts.items) |a| {
            const mismatch = std.mem.eql(u8, a.outcome, "protocol_mismatch");
            if (!mismatch) all_mismatch = false;
            if (!mismatch and !std.mem.eql(u8, a.outcome, "untranslatable_request")) all_unservable = false;
        }
        if (all_mismatch) return respondError(acc, request, .bad_request, "endpoint_not_supported", "this endpoint is not available for this model: its providers speak the other protocol, and only chat completions and messages are translated");
        if (all_unservable) return respondError(acc, request, .bad_request, "untranslatable_request", "this request uses a feature that cannot be translated for this model's provider");
    }

    // Nothing succeeded. If any target said 429, so do we, with the longest
    // `retry-after` any of them gave, so that SDKs back off as they would at
    // the provider: a later target that was merely down does not make the
    // rate limit go away. Anything else is a 502.
    const rate_limited = any_rate_limited;
    if (rate_limited) last_retry_after = longest_retry_after;
    const final_status: u16 = if (rate_limited) 429 else 502;
    if (ep.metered) report(app, arena, .{
        .id = &req_id,
        .key_sha256 = &key_hash,
        .route_model = route_model,
        .upstream = null,
        .target_model = null,
        .status = final_status,
        .stream = is_stream,
        .input_tokens = 0,
        .output_tokens = 0,
        .latency_ms = started.durationTo(Io.Timestamp.now(app.io, .awake)).toMilliseconds(),
        .attempts = attempts.items,
    });
    acc.status = final_status;
    acc.attempts = tried;
    var detail: Io.Writer.Allocating = .init(arena);
    try errors.write(&detail.writer, protocolOf(acc), .{
        .status = final_status,
        .reason = if (rate_limited) "upstream_rate_limited" else "all_upstreams_failed",
        .message = if (rate_limited) "the provider is rate limiting this model; retry shortly" else "every target for this model failed",
        .request_id = &req_id,
        .attempts = attempts.items,
    });
    var failed_headers: std.ArrayList(http.Header) = .empty;
    try failed_headers.appendSlice(arena, &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-omnigate-request-id", .value = &req_id },
        .{ .name = "x-request-id", .value = &req_id },
        .{ .name = "request-id", .value = &req_id },
    });
    // If the last upstream that answered said when to come back, say so too.
    if (last_retry_after) |v| try failed_headers.append(arena, .{ .name = "retry-after", .value = v });
    try request.respond(detail.written(), .{
        .status = if (rate_limited) .too_many_requests else .bad_gateway,
        .keep_alive = reusable(request),
        .extra_headers = failed_headers.items,
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

/// A request's place in its key's allowance of concurrent requests and
/// request memory (limits.zig), from `admit` until it is released.
const Hold = struct {
    held: bool = false,
    bytes: u64 = 0,

    fn release(h: *Hold, app: *App, key_hash: *const [64]u8) void {
        if (h.held) app.gate.leave(app.io, key_hash, h.bytes);
        h.held = false;
    }
};

/// Count this request against its key's concurrency cap and the memory
/// budget, before its body is read. False when it was refused (and
/// answered): 429 for the key's own limits, 503 when the gateway as a whole
/// is holding all it may.
fn admit(
    app: *App,
    acc: *logging.Access,
    request: *http.Server.Request,
    key_hash: *const [64]u8,
    key: *const config.Key,
    body_limit: u64,
    hold: *Hold,
) !bool {
    // A body is held twice while its request is forwarded: as received and
    // as sent on. (One longer than the limit is refused unread, below.)
    const declared = request.head.content_length orelse 0;
    const bytes = 2 * @min(declared, body_limit);
    switch (app.gate.enter(app.gpa, app.io, key_hash, key.max_concurrent, bytes)) {
        .ok => {
            hold.* = .{ .held = true, .bytes = bytes };
            return true;
        },
        .concurrency => try respondRetryLater(acc, request, .too_many_requests, "concurrency_limit_exceeded", "this key has too many requests in flight; retry when some have finished"),
        .key_share => try respondRetryLater(acc, request, .too_many_requests, "request_memory_exceeded", "the requests this key has in flight are too large together; retry when some have finished"),
        .budget => try respondRetryLater(acc, request, .service_unavailable, "overloaded", "the gateway is holding as many requests as it has memory for; retry shortly"),
    }
    return false;
}

/// Why a step that needs a JSON value tree was not carried out.
const TreeRefusal = enum {
    /// The tree would pass its cap: the text is too expensive for its size.
    too_complex,
    /// The key has its share of the tree budget reserved already.
    key_share,
    /// The tree budget as a whole is reserved.
    budget,
};

/// Run `f(allocator, args...)`, a step that parses JSON into a value tree,
/// inside an arena capped by the size of the text (`limits.treeCap`), with
/// that cap reserved against the tree budget for as long as the tree lives;
/// its result is copied into `arena` and the tree is gone when this returns.
/// Null with `refusal` set when a limit stopped it; null without when `f`
/// itself said no (or failed on the JSON).
fn inTree(
    app: *App,
    arena: std.mem.Allocator,
    key_hash: *const [64]u8,
    text_len: usize,
    refusal: *?TreeRefusal,
    comptime f: anytype,
    args: anytype,
) error{OutOfMemory}!?[]u8 {
    if (refusal.* != null) return null;
    const cap = limits.treeCap(text_len);
    switch (app.gate.reserveTree(app.io, key_hash, cap)) {
        .ok => {},
        .key_share => {
            refusal.* = .key_share;
            return null;
        },
        .budget, .concurrency => {
            refusal.* = .budget;
            return null;
        },
    }
    defer app.gate.releaseTree(app.io, key_hash, cap);
    var tree: limits.Tree = undefined;
    tree.init(app.gpa, cap);
    defer tree.deinit();
    // Both `![]u8` and `!?[]u8` are accepted.
    const out: ?[]u8 = @call(.auto, f, .{tree.allocator()} ++ args) catch |err| switch (err) {
        error.OutOfMemory => {
            if (!tree.refused()) return error.OutOfMemory;
            refusal.* = .too_complex;
            return null;
        },
        else => return null,
    };
    return if (out) |bytes| try arena.dupe(u8, bytes) else null;
}

/// `body` with `stream_options.include_usage` set, for a request that
/// already has a `stream_options` (one without is spliced, see jsonscan).
fn requestUsage(a: std.mem.Allocator, body: []const u8) ![]u8 {
    var value = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    if (value != .object) return error.InvalidJson;
    var so: std.json.ObjectMap = if (value.object.get("stream_options")) |v| (if (v == .object) v.object else .empty) else .empty;
    try so.put(a, "include_usage", .{ .bool = true });
    try value.object.put(a, "stream_options", .{ .object = so });
    return std.json.Stringify.valueAlloc(a, value, .{});
}

/// The response-cache key of a request, or null when the request is not
/// worth the tree its canonical form takes (too many members in one object,
/// or more memory than its cap): such a request is served, just not cached.
fn cacheKeyFor(app: *App, route_model: []const u8, path: []const u8, key_hash: *const [64]u8, body: []const u8, top: jsonscan.Top) ?cache.Key {
    if (top.max_members > guard_mod.max_tree_members) return null;
    const cap = limits.treeCap(body.len);
    if (app.gate.reserveTree(app.io, key_hash, cap) != .ok) return null;
    defer app.gate.releaseTree(app.io, key_hash, cap);
    var tree: limits.Tree = undefined;
    tree.init(app.gpa, cap);
    defer tree.deinit();
    const a = tree.allocator();
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return null;
    return cache.keyFor(a, route_model, path, key_hash, value) catch null;
}

/// Answer a request whose conversion was stopped by a cap in limits.zig.
fn respondTreeRefusal(acc: *logging.Access, request: *http.Server.Request, refusal: ?TreeRefusal) !void {
    return switch (refusal orelse .too_complex) {
        .too_complex => respondError(acc, request, .bad_request, "request_too_complex", "the request body is too complex to convert for this model's provider: an object with more than 1024 members, or far more values than its size suggests"),
        .key_share => respondRetryLater(acc, request, .too_many_requests, "request_memory_exceeded", "this key is converting as many large requests as it may at once; retry shortly"),
        .budget => respondRetryLater(acc, request, .service_unavailable, "overloaded", "the gateway is converting as many requests as it has memory for; retry shortly"),
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
/// What follows is an answer: the deadline from here on is the one for a
/// client that does not take it (also when the answer is "too large").
fn readBody(app: *App, arena: std.mem.Allocator, request: *http.Server.Request, guard: *watchdog.Conn, limit: usize) !?[]u8 {
    defer guard.arm(app.io, app.client_stall_timeout_ms);
    // A length that is already too long is refused without reading any of it.
    if (request.head.content_length) |declared| if (declared > limit) return null;
    var body_buf: [8 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buf);
    return body_reader.allocRemaining(arena, .limited(limit)) catch |err| switch (err) {
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
    /// Its request carries text that privacy mode looks through ...
    redact: bool = true,
    /// ... and its answer carries text the placeholders may come back in.
    restore: bool = true,

    fn forPath(path: []const u8) ?Endpoint {
        const eql = std.mem.eql;
        if (eql(u8, path, "/v1/chat/completions")) return .{ .kind = .openai, .translatable = true, .inject_stream_usage = true };
        if (eql(u8, path, "/v1/messages")) return .{ .kind = .anthropic, .translatable = true };
        if (eql(u8, path, "/v1/completions")) return .{ .kind = .openai, .inject_stream_usage = true };
        if (eql(u8, path, "/v1/embeddings")) return .{ .kind = .openai, .restore = false };
        if (eql(u8, path, "/v1/responses")) return .{ .kind = .openai };
        // Free at the provider, and its `input_tokens` answer is not usage.
        if (eql(u8, path, "/v1/messages/count_tokens")) return .{ .kind = .anthropic, .metered = false, .restore = false };
        return null;
    }
};

const Attempt = errors.Attempt;

const UsageReport = struct {
    key_sha256: []const u8,
    route_model: []const u8,
    upstream: ?[]const u8,
    target_model: ?[]const u8,
    status: u16,
    stream: bool,
    /// Input NOT served from the provider's prompt cache (see usage.zig).
    input_tokens: u64,
    /// Input read from the provider's prompt cache.
    cached_input_tokens: u64 = 0,
    /// Input written to the provider's prompt cache (Anthropic bills these).
    cache_write_input_tokens: u64 = 0,
    output_tokens: u64,
    /// Answered from the gateway's response cache: counted, not billed.
    cached: bool = false,
    /// The counts are an estimate: the response was cut off before the
    /// provider's own figures arrived (see `Usage.estimated`).
    estimated: bool = false,
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

/// A copy of a whole non-streaming answer, for the response cache.
const Capture = struct {
    /// Larger answers are not worth keeping; stop copying past this.
    limit: usize,
    body: std.ArrayList(u8) = .empty,
    content_type: []const u8 = "",
    overflow: bool = false,
    /// Set once the complete answer is in `body`.
    complete: bool = false,

    fn reset(c: *Capture) void {
        c.body.clearRetainingCapacity();
        c.overflow = false;
        c.complete = false;
    }

    fn add(c: *Capture, arena: std.mem.Allocator, bytes: []const u8) void {
        if (c.overflow) return;
        if (c.body.items.len + bytes.len > c.limit) {
            c.overflow = true;
            c.body.clearRetainingCapacity();
            return;
        }
        c.body.appendSlice(arena, bytes) catch {
            c.overflow = true;
        };
    }
};

/// Further inputs and outputs of `forward`.
const ForwardExtras = struct {
    /// Whose request this is (for the tree budget, see `inTree`).
    key_hash: *const [64]u8,
    /// Where to copy a non-streaming answer for the response cache.
    capture: ?*Capture = null,
    /// Value for `x-omnigate-cache` on the response ("miss"), if any.
    cache_note: ?[]const u8 = null,
    /// Value for `x-omnigate-privacy` on the response: what was applied.
    privacy_note: ?[]const u8 = null,
    /// Value for `x-omnigate-attestation` on the response, when the target
    /// that answers is on an attested upstream whose verdict holds.
    attestation_note: ?[]const u8 = null,
    /// Puts back what privacy mode replaced in the request; null when
    /// nothing was replaced.
    restorer: ?*redact.Restorer = null,
    /// Out: the upstream's `retry-after` when it answered with a status we
    /// fail over on.
    retry_after: ?[]const u8 = null,
    /// Out: set when `forward` failed because the client went away (or
    /// stopped reading) while the upstream was still answering. The open
    /// exchange is handed to the caller, who owns it from then on.
    parked: ?Parked = null,
};

/// An upstream exchange whose response body is still being read.
const Parked = struct {
    req: http.Client.Request,
    body: framing.BodyReader,
};

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
    /// The response head arrived. Until then std has no idea that anything
    /// went wrong on the connection: a write that failed half way, a write
    /// that was cancelled by the timeout, a head that never came all leave
    /// its reader in the state "ready for the next exchange", and a request
    /// torn down in that state hands its socket back to the pool.
    head_received: bool = false,

    fn deinit(call: *UpstreamCall) void {
        if (call.req_live) {
            // Closed unless proven reusable: see `framing.finish`.
            framing.finish(&call.req, call.head_received);
        }
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
        const response = try call.req.receiveHead(&.{});
        call.head_received = true;
        return response;
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

/// The start of a response body, read before any of it is passed on: up to
/// `limit` bytes, or all of it when it is shorter.
///
/// A peer that sends its head and then goes silent has to be timed here
/// too, and not by the watchdog: the watchdog cancels the connection's
/// task, which is the end of that task (it cannot be interrupted a second
/// time, and the watchdog waits for it), while at this point the request
/// can still be sent to another upstream. So the read runs as a task of
/// its own next to a timer, the way `openWithTimeout` waits for the head,
/// and only that task is cancelled.
const Buffered = struct {
    body: *framing.BodyReader,
    /// Only touched by the reading task while `read` waits for it.
    arena: std.mem.Allocator,
    /// Reading stops once more than this has arrived.
    limit: usize,
    bytes: std.ArrayList(u8) = .empty,
    /// The body ended within `limit`.
    ended: bool = false,
    /// Counts the reads that returned something: how the waiting side tells
    /// a slow body from a silent one.
    progress: std.atomic.Value(u32) = .init(0),

    const Error = framing.BodyReader.Error || error{OutOfMemory};

    fn run(b: *Buffered) Error!void {
        var chunk: [16 * 1024]u8 = undefined;
        while (b.bytes.items.len <= b.limit) {
            const n = try b.body.read(&chunk);
            if (n == 0) {
                b.ended = true;
                return;
            }
            try b.bytes.appendSlice(b.arena, chunk[0..n]);
            _ = b.progress.fetchAdd(1, .release);
        }
    }

    /// `run`, given up on with `error.StreamIdleTimeout` when nothing
    /// arrives for `idle_ms` (0 = wait for ever). A body that keeps
    /// arriving is never cut off; one that stops is noticed after between
    /// one and two times `idle_ms`.
    fn read(b: *Buffered, io: Io, idle_ms: u32) (Error || error{StreamIdleTimeout} || Io.Cancelable)!void {
        if (idle_ms == 0) return b.run();
        // The usual case for a short answer: it arrived with its head and
        // is already in the connection's buffer. Reading it cannot block,
        // so it needs neither a task of its own nor a timer.
        if (b.body.remaining()) |left| {
            if (left <= b.body.in.bufferedLen()) return b.run();
        }

        const Race = union(enum) {
            body: Error!void,
            timer: Io.Cancelable!void,
        };
        var results: [2]Race = undefined;
        var race: Io.Select(Race) = .init(io, &results);

        // No spare concurrency: better an untimed read than a failed one.
        race.concurrent(.body, run, .{b}) catch return b.run();
        var seen: u32 = 0;
        while (true) {
            race.concurrent(.timer, sleepMs, .{ io, idle_ms }) catch {};
            const first = race.await() catch |err| {
                race.cancelDiscard();
                return err;
            };
            switch (first) {
                .body => |result| {
                    race.cancelDiscard();
                    return result;
                },
                .timer => {
                    const now = b.progress.load(.acquire);
                    if (now != seen) {
                        seen = now;
                        continue;
                    }
                    // Silent for a whole interval. Cancel the read; if it
                    // finished in the meantime, use what it read.
                    var finished = false;
                    while (race.cancel()) |leftover| switch (leftover) {
                        .body => |result| {
                            if (result) |_| {
                                finished = true;
                            } else |_| {}
                        },
                        .timer => {},
                    };
                    if (finished) return;
                    return error.StreamIdleTimeout;
                },
            }
        }
    }
};

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
        error.UpstreamTruncated,
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
    extras: *ForwardExtras,
) !ForwardResult {
    if (extras.capture) |c| c.reset();
    extras.parked = null;
    // A fresh reader for this attempt's response.
    usage.* = .{};
    // While waiting for the upstream its own timeout applies, not the
    // deadline on our answer; that comes back when this returns (whatever
    // the caller does next ends in an answer to the client).
    guard.disarm();
    defer guard.arm(app.io, app.client_stall_timeout_ms);
    const base = std.mem.trimEnd(u8, up.base_url, "/");
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, try config.upstreamPath(arena, up.v1_path, path) });
    const uri = try std.Uri.parse(url);
    const secret = app.env.get(up.api_key_env) orelse "";

    var extra: std.ArrayList(http.Header) = .empty;
    var headers: http.Client.Request.Headers = .{
        .content_type = .{ .override = "application/json" },
        // Keep bodies uncompressed so they can be streamed and metered as-is.
        .accept_encoding = .{ .override = "identity" },
        .user_agent = .{ .override = main.user_agent },
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

    // From here on bytes have to keep moving. As long as nothing has been
    // passed on, an upstream that goes silent is timed by `Buffered.read`
    // (a timer, as for the head): the request can then still go to the next
    // upstream, which a task cancelled by the watchdog could not do. Once
    // the answer is being relayed the watchdog's deadline is set before
    // every read (the idle timeout) and every write (the shorter client
    // stall timeout), and it cancels this task when one passes.

    const status = response.head.status;
    // A final answer is 200 or above. (std has dealt with `100 Continue`;
    // any other 1xx here is not an answer, and std asserts if asked to send
    // a 100 as one.)
    if (@backingInt(status) < 200) return error.UpstreamUnparseable;
    // Copy what we need from the head before the body reader invalidates it:
    // first the provider headers that are meant for the caller (headers.zig).
    const relayed = try headers_mod.collect(arena, response.head.bytes);
    if (isRetryable(status)) {
        extras.retry_after = headers_mod.find(relayed, "retry-after");
        return .{ .retry = status };
    }

    const content_type = try relayedContentType(arena, response.head.content_type);
    const is_sse = std.ascii.startsWithIgnoreCase(content_type, "text/event-stream");

    // The body is framed and read by framing.zig from here on, never by
    // std: a head with two framings is refused, a chunk size is bounded, and
    // a body that ends before its promised length is an error, not an end.
    // (Everything wanted from the head has been copied: reading the body
    // reuses its buffer.)
    var upstream_body = framing.takeBody(&call.req, &response) catch return error.UpstreamUnparseable;
    var chunk: [16 * 1024]u8 = undefined;

    // Response headers: ours, then the provider's that passed the allowlist.
    // Slot 0 is the content type, which depends on the branch taken below.
    var attempt_buf: [12]u8 = undefined;
    const ids = headers_mod.requestIds(relayed, req_id);
    var out_headers: std.ArrayList(http.Header) = .empty;
    try out_headers.appendSlice(arena, &.{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = "x-omnigate-upstream", .value = up.name },
        .{ .name = "x-omnigate-attempts", .value = std.fmt.bufPrint(&attempt_buf, "{d}", .{attempt_no}) catch unreachable },
        .{ .name = "x-omnigate-request-id", .value = req_id },
        // The ids the OpenAI and the Anthropic SDK read (see `requestIds`).
        .{ .name = "x-request-id", .value = ids.x_request_id },
        .{ .name = "request-id", .value = ids.request_id },
    });
    if (extras.cache_note) |note| try out_headers.append(arena, .{ .name = "x-omnigate-cache", .value = note });
    if (extras.privacy_note) |note| try out_headers.append(arena, .{ .name = "x-omnigate-privacy", .value = note });
    if (extras.attestation_note) |note| try out_headers.append(arena, .{ .name = "x-omnigate-attestation", .value = note });
    for (relayed) |h| {
        // Already set above.
        if (std.ascii.eqlIgnoreCase(h.name, "x-request-id") or std.ascii.eqlIgnoreCase(h.name, "request-id")) continue;
        try out_headers.append(arena, h);
    }

    // --- translated, not a stream: buffer, convert, answer in one piece -----
    if (mode == .translate and !is_sse) {
        const x = mode.translate;
        var whole: Buffered = .{ .body = &upstream_body, .arena = arena, .limit = max_translated_body };
        try whole.read(app.io, app.stream_idle_timeout_ms);
        if (!whole.ended) return error.UpstreamUnparseable;
        const raw = whole.bytes.items;
        framing.release(&call.req, &upstream_body);
        // Translation re-serialises this; refuse what the serialiser cannot take.
        if (!guard_mod.jsonDepthOk(raw, guard_mod.max_upstream_json_depth)) return error.UpstreamUnparseable;
        if (@backingInt(status) == 400 and !x.sampling_stripped and quirks.mentionsSampling(raw)) return .drop_sampling;
        if (@backingInt(status) == 400 and !x.signatures_added and x.dir == .anthropic_to_openai and
            quirks.mentionsThoughtSignature(raw)) return .add_thought_signature;
        usage.feed(raw);
        const now_s = @divTrunc(Io.Timestamp.now(app.io, .real).toMilliseconds(), 1000);
        // A tree of the upstream's answer, capped like one of a request: an
        // answer that needs more is not the shape its protocol promises.
        var refusal: ?TreeRefusal = null;
        const converted = (try inTree(app, arena, extras.key_hash, raw.len, &refusal, translate.translateResponseAt, .{ x.dir, @backingInt(status), raw, x.route_model, now_s })) orelse
            return error.UpstreamUnparseable;
        if (extras.capture) |c| {
            c.add(arena, converted);
            c.content_type = "application/json";
            c.complete = !c.overflow;
        }
        const restored = if (extras.restorer) |r| try r.restoreDoc(arena, converted) else converted;
        committed.* = true;
        out_headers.items[0].value = "application/json";
        guard.arm(app.io, app.client_stall_timeout_ms);
        try request.respond(restored, .{ .status = status, .keep_alive = reusable(request), .extra_headers = out_headers.items });
        return .{ .done = status };
    }

    // --- not a stream: a small answer is buffered and sent with its length ---
    // The length is counted here, not taken from the upstream. If the body
    // is cut short there is still time to fail over: nothing has been sent.
    var head_start: []const u8 = "";
    if (!is_sse) {
        // An answer that has placeholders to turn back is read whole, however
        // long: they cannot be found in half a document.
        var start: Buffered = .{ .body = &upstream_body, .arena = arena, .limit = if (extras.restorer != null) max_translated_body else small_body_max };
        try start.read(app.io, app.stream_idle_timeout_ms);
        const small = start.bytes.items;
        if (!start.ended and extras.restorer != null) return error.UpstreamUnparseable;
        if (start.ended) {
            framing.release(&call.req, &upstream_body);
            usage.feed(small);
            if (extras.capture) |c| {
                c.add(arena, small);
                c.content_type = content_type;
                c.complete = !c.overflow;
            }
            // An error that is not in the shape its protocol promises (some
            // providers answer a bad key on an "OpenAI-compatible" endpoint
            // with an array, or with `error` as a string) is put into that
            // shape, with the provider's own words: a client's SDK reads
            // nothing else. One that is well-formed is relayed as it came.
            var answer: []const u8 = small;
            if (@backingInt(status) >= 400) {
                var refusal: ?TreeRefusal = null;
                const shape: translate.ErrorShape = switch (up.kind) {
                    .openai => .openai,
                    .anthropic => .anthropic,
                };
                if (try inTree(app, arena, extras.key_hash, small.len, &refusal, translate.wrapError, .{ shape, @backingInt(status), small })) |wrapped| {
                    answer = wrapped;
                    out_headers.items[0].value = "application/json";
                }
            }
            if (extras.restorer) |r| answer = try r.restoreDoc(arena, answer);
            committed.* = true;
            guard.arm(app.io, app.client_stall_timeout_ms);
            try request.respond(answer, .{ .status = status, .keep_alive = reusable(request), .extra_headers = out_headers.items });
            return .{ .done = status };
        }
        head_start = small;
    }

    // --- a stream, or a long answer: chunked ----------------------------------
    // Never with a length: what the upstream declared is a claim, and std
    // asserts when a response ends with a different number of bytes than its
    // own head promised. If the upstream fails part way, the client's
    // connection is dropped without the closing chunk, which is how a
    // chunked response says "this was cut short".
    committed.* = true;
    var resp_buf: [8 * 1024]u8 = undefined;
    var body_writer = try request.respondStreaming(&resp_buf, .{
        .respond_options = .{
            .status = status,
            .extra_headers = out_headers.items,
        },
    });
    // Only a whole, unmodified, non-streaming body is worth remembering.
    const capturing: ?*Capture = if (!is_sse) extras.capture else null;

    var translator: ?translate.StreamTranslator = if (mode == .translate) blk: {
        const x = mode.translate;
        break :blk .init(arena, x.dir, x.route_model, .{
            .include_usage = x.include_usage,
            .created = @divTrunc(Io.Timestamp.now(app.io, .real).toMilliseconds(), 1000),
        });
    } else null;
    var usage_filter: usage_mod.UsageChunkFilter = .{};
    defer usage_filter.deinit(arena);
    // With placeholders to turn back, the stages above write into `staged`,
    // and the restorer passes on what it can (redact.zig): it is the last
    // thing between the stream and the client.
    var staged: Io.Writer.Allocating = .init(arena);
    const sink: *Io.Writer = if (extras.restorer != null) &staged.writer else &body_writer.writer;

    var pending: []const u8 = head_start;
    while (true) {
        const data: []const u8 = if (pending.len > 0) first: {
            const d = pending;
            pending = "";
            break :first d;
        } else next: {
            guard.arm(app.io, app.stream_idle_timeout_ms);
            const n = upstream_body.read(&chunk) catch |err| return upstreamReadError(err, guard);
            if (n == 0) break;
            break :next chunk[0..n];
        };
        usage.feed(data);
        // A client that is connected but takes nothing gets the stall
        // timeout, not the (much longer) one for a silent upstream.
        guard.arm(app.io, app.client_stall_timeout_ms);
        const sent: anyerror!void = sent: {
            if (translator) |*tr| {
                tr.feed(data, sink) catch |e| break :sent e;
            } else if (mode == .hide_usage_chunk and is_sse) {
                usage_filter.feed(arena, data, sink) catch |e| break :sent e;
            } else {
                if (capturing) |c| c.add(arena, data);
                sink.writeAll(data) catch |e| break :sent e;
            }
            if (extras.restorer) |r| {
                r.feed(arena, staged.written(), &body_writer.writer) catch |e| break :sent e;
                staged.clearRetainingCapacity();
            }
            // Flush per chunk so SSE tokens reach the client immediately: first
            // our body buffer into the HTTP framing, then the framing to the socket
            // (`BodyWriter.flush` alone only does the second half).
            body_writer.writer.flush() catch |e| break :sent e;
            body_writer.flush() catch |e| break :sent e;
        };
        sent catch |err| {
            if (err == error.OutOfMemory or err == error.EventTooLarge) return err;
            // Nothing more can reach the client: it hung up, or it stopped
            // reading and the watchdog cancelled the write. The upstream is
            // still answering, and the usage that says what this cost
            // usually comes last. Unless the figures are already in (or
            // draining is off), hand the open exchange to the caller, who
            // has it read to its end in the background.
            const stalled = guard.timedOut();
            if (!usage.final_seen and app.abort_drain_ms != 0) {
                extras.parked = .{ .req = call.req, .body = upstream_body };
                call.req_live = false;
            }
            return if (stalled) error.ClientStalled else error.ClientDisconnected;
        };
    }
    framing.release(&call.req, &upstream_body);
    guard.arm(app.io, app.client_stall_timeout_ms);
    if (translator) |*tr| try tr.finish(sink);
    if (mode == .hide_usage_chunk and is_sse) try usage_filter.finish(sink);
    if (extras.restorer) |r| {
        try r.feed(arena, staged.written(), &body_writer.writer);
        try r.finish(arena, &body_writer.writer);
    }
    try body_writer.end();
    if (capturing) |c| {
        c.content_type = content_type;
        c.complete = !c.overflow;
    }
    return .{ .done = status };
}

/// What a failed read of an upstream's body means for the request.
fn upstreamReadError(err: framing.BodyReader.Error, guard: *const watchdog.Conn) anyerror {
    return switch (err) {
        // The watchdog cancelled the read: the upstream went silent.
        error.ReadFailed => if (guard.timedOut()) error.StreamIdleTimeout else error.ReadFailed,
        error.UpstreamTruncated => error.UpstreamTruncated,
        error.UpstreamUnparseable => error.UpstreamUnparseable,
    };
}

/// The `content-type` to put on our response for one an upstream (or the
/// control plane) sent: the same rule as for every other relayed header,
/// nothing with a control byte in it. std's head parser splits lines on CRLF
/// only, so a value can arrive here with a bare line feed inside, which
/// written out again would start a header line of the peer's choosing.
fn relayedContentType(arena: std.mem.Allocator, value: ?[]const u8) ![]const u8 {
    const raw = value orelse return "application/json";
    if (!framing.plainHeaderValue(raw, max_content_type_len)) return error.UpstreamUnparseable;
    return arena.dupe(u8, raw);
}

// ---------------------------------------------------------------------------
// Reading on after the client has gone
// ---------------------------------------------------------------------------

/// Upstream answers that are being read to their end without a client.
///
/// When a client hangs up (or stops reading) in the middle of a stream, the
/// provider goes on generating and charges for it, and the usage that says
/// how much arrives at the very end. So the open exchange is taken off the
/// client's connection, which is finished with, and read on by a task of its
/// own: to the provider's closing usage, or the end of the answer, or until
/// OMNIGATE_ABORT_DRAIN_MS or OMNIGATE_ABORT_DRAIN_MAX_MB is reached. Only
/// then is the upstream connection closed (which is what makes a provider
/// stop), and the request is billed: the provider's figures if they came, an
/// estimate marked as one if they did not.
///
/// Each of these still counts against its key's concurrency cap, so leaving
/// and coming back is not a way around it.
pub const Drains = struct {
    group: Io.Group = .init,
    /// Guards `group` (adding to it and stopping it) and `stopping`.
    mutex: Io.Mutex = .init,
    stopping: bool = false,
    active: std.atomic.Value(u32) = .init(0),

    /// More than this at once are not read on: they are billed by estimate
    /// at once, as with draining switched off.
    pub const max_active = 256;

    /// At shutdown: cancel what is running (each bills what it has) and wait.
    pub fn stop(d: *Drains, io: Io) void {
        d.mutex.lockUncancelable(io);
        d.stopping = true;
        d.mutex.unlock(io);
        d.group.cancel(io);
    }
};

const DrainJob = struct {
    app: *App,
    /// Owns the strings in `event`.
    arena: std.heap.ArenaAllocator,
    req: http.Client.Request,
    body: framing.BodyReader,
    usage: Usage,
    kind: config.Kind,
    input_estimate: u64,
    event: UsageReport,
    key_hash: [64]u8,
    hold: Hold,
    started: Io.Timestamp,
    drained: u64 = 0,

    fn destroy(job: *DrainJob) void {
        const app = job.app;
        // Not at a message boundary (or it would have been released): closes.
        job.req.deinit();
        job.hold.release(app, &job.key_hash);
        job.arena.deinit();
        app.gpa.destroy(job);
        _ = app.drains.active.fetchSub(1, .acq_rel);
    }
};

/// Take over `parked` and read it to its end in the background; `event` is
/// what would be billed now, and is billed with the final figures then.
/// False when that was not possible: nothing was taken, and the caller
/// bills `event` itself.
fn startDrain(
    app: *App,
    parked: *Parked,
    usage: *const Usage,
    kind: config.Kind,
    input_estimate: u64,
    event: UsageReport,
    key_hash: *const [64]u8,
    hold: Hold,
    started: Io.Timestamp,
) bool {
    const d = app.drains;
    if (d.active.fetchAdd(1, .acq_rel) >= Drains.max_active) {
        _ = d.active.fetchSub(1, .acq_rel);
        return false;
    }
    const job = app.gpa.create(DrainJob) catch {
        _ = d.active.fetchSub(1, .acq_rel);
        return false;
    };
    job.* = .{
        .app = app,
        .arena = .init(app.gpa),
        .req = parked.req,
        .body = parked.body,
        .usage = usage.*,
        .kind = kind,
        .input_estimate = input_estimate,
        .event = event,
        .key_hash = key_hash.*,
        .hold = hold,
        .started = started,
    };
    const started_ok = ok: {
        // The event's strings belong to the request that is about to end.
        const a = job.arena.allocator();
        job.event.id = a.dupe(u8, event.id) catch break :ok false;
        job.event.key_sha256 = &job.key_hash;
        job.event.route_model = a.dupe(u8, event.route_model) catch break :ok false;
        job.event.upstream = if (event.upstream) |u| a.dupe(u8, u) catch break :ok false else null;
        job.event.target_model = if (event.target_model) |m| a.dupe(u8, m) catch break :ok false else null;
        const attempts = a.alloc(Attempt, event.attempts.len) catch break :ok false;
        for (attempts, event.attempts) |*to, from| {
            to.* = from;
            to.upstream = a.dupe(u8, from.upstream) catch break :ok false;
            to.outcome = a.dupe(u8, from.outcome) catch break :ok false;
        }
        job.event.attempts = attempts;

        d.mutex.lockUncancelable(app.io);
        defer d.mutex.unlock(app.io);
        if (d.stopping) break :ok false;
        d.group.concurrent(app.io, drainTask, .{job}) catch break :ok false;
        break :ok true;
    };
    if (!started_ok) {
        // Give everything back except the exchange and the hold, which are
        // still the caller's.
        job.arena.deinit();
        app.gpa.destroy(job);
        _ = d.active.fetchSub(1, .acq_rel);
        return false;
    }
    return true;
}

fn drainTask(job: *DrainJob) Io.Cancelable!void {
    const app = job.app;
    defer job.destroy();

    // The reading runs as a task of its own so that it can be cancelled
    // while blocked: by the timer here, or by shutdown through this task.
    const Race = union(enum) { read: void, timer: Io.Cancelable!void };
    var results: [2]Race = undefined;
    var race: Io.Select(Race) = .init(app.io, &results);
    if (race.concurrent(.read, drainRead, .{job})) |_| {
        // Without a timer there is no bound on how long this may take, so
        // without one (no spare concurrency) the reading is stopped at once.
        if (race.concurrent(.timer, sleepMs, .{ app.io, app.abort_drain_ms })) |_| {
            _ = race.await() catch {};
        } else |_| {}
        race.cancelDiscard();
    } else |_| {
        // No spare concurrency: bill what is known.
    }

    const estimated = !job.usage.final_seen;
    const used = if (estimated) job.usage.estimated(job.kind, job.input_estimate) else job.usage.normalized(job.kind);
    job.event.input_tokens = used.input_tokens;
    job.event.cached_input_tokens = used.cached_input_tokens;
    job.event.cache_write_input_tokens = used.cache_write_input_tokens;
    job.event.output_tokens = used.output_tokens;
    job.event.estimated = estimated;
    job.event.latency_ms = job.started.durationTo(Io.Timestamp.now(app.io, .awake)).toMilliseconds();
    if (job.body.atBoundary()) framing.release(&job.req, &job.body);
    log.info("request {s}: read {d} more bytes from {s} after the client left; billing {s} usage (in={d} out={d})", .{
        job.event.id,                                     job.drained,       job.event.upstream orelse "-",
        if (estimated) "ESTIMATED" else "the provider's", used.input_tokens, used.output_tokens,
    });
    report(app, job.arena.allocator(), job.event);
}

/// Read the rest of the upstream's answer, metering it, until its closing
/// usage has been seen, it ends, it fails, or the byte cap is reached.
fn drainRead(job: *DrainJob) void {
    var chunk: [16 * 1024]u8 = undefined;
    while (!job.usage.final_seen and job.drained <= job.app.abort_drain_max_bytes) {
        const n = job.body.read(&chunk) catch return;
        if (n == 0) return;
        job.usage.feed(chunk[0..n]);
        job.drained += n;
    }
}

/// Hand a `/v1/jobs*` or `/v1/files/*` request to the control plane at
/// `/internal<target>` and stream its answer back unchanged. `key_sha256` is
/// null only for signed file URLs, which the control plane verifies itself.
fn forwardToControl(
    app: *App,
    acc: *logging.Access,
    arena: std.mem.Allocator,
    request: *http.Server.Request,
    guard: *watchdog.Conn,
    method: http.Method,
    /// Canonical (see `guard.canonicalPath`) ...
    path: []const u8,
    /// ... and plain (see `guard.safeQuery`): both were checked by the caller.
    query: []const u8,
    body: ?[]u8,
    /// Checked by the caller (`guard.visibleToken`).
    idempotency_key: ?[]const u8,
    key_sha256: ?[]const u8,
    /// The request asked (`x-omnigate-privacy`) for nothing of it to be kept.
    private: bool,
) !void {
    // The control plane's address comes from our own configuration; the
    // client contributes a path and a query that were validated character by
    // character, and they are set as components, never spliced into a string
    // that is parsed again.
    const base = std.mem.trimEnd(u8, app.control_url, "/");
    var uri = std.Uri.parse(base) catch
        return respondError(acc, request, .service_unavailable, "control_plane_unavailable", "the control plane address is not a valid URL");
    if (!guard_mod.canonicalPath(path) or !guard_mod.safeQuery(query))
        return respondError(acc, request, .bad_request, "invalid_request", "malformed request path");
    const base_path = switch (uri.path) {
        .raw => |p| p,
        .percent_encoded => |p| p,
    };
    uri.path = .{ .percent_encoded = try std.fmt.allocPrint(arena, "{s}/internal{s}", .{ std.mem.trimEnd(u8, base_path, "/"), path }) };
    uri.query = if (query.len > 0) .{ .percent_encoded = query } else null;
    uri.fragment = null;

    var extra: std.ArrayList(http.Header) = .empty;
    try extra.append(arena, .{ .name = control.internal_header, .value = app.internal_token });
    if (key_sha256) |k| try extra.append(arena, .{ .name = "x-omnigate-key-sha256", .value = k });
    if (idempotency_key) |k| if (guard_mod.visibleToken(k, 255)) try extra.append(arena, .{ .name = "idempotency-key", .value = k });
    if (private) try extra.append(arena, .{ .name = "x-omnigate-privacy", .value = "no-store" });
    // Our id for this request, so that the control plane's log lines (and
    // the `request_id` in a 500 from it) match what the client was given.
    try extra.append(arena, .{ .name = "x-omnigate-request-id", .value = acc.request_id.get() });

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
                .user_agent = .{ .override = main.user_agent },
            },
            .extra_headers = extra.items,
        },
        .body = body,
    };
    defer call.deinit();

    // The control plane has its own timeout; our answer's deadline resumes after.
    guard.disarm();
    var response = call.openWithTimeout(app.io, control_timeout_ms) catch |err| {
        guard.arm(app.io, app.client_stall_timeout_ms);
        // The path only: a signed URL's query is a credential.
        log.warn("control plane request {s} failed: {t}", .{ path, err });
        return respondError(acc, request, .service_unavailable, "control_plane_unavailable", "media jobs need the control plane, which is not reachable");
    };
    // An answer of our own may follow at once (the checks below).
    guard.arm(app.io, app.client_stall_timeout_ms);

    const status = response.head.status;
    // The control plane is ours, but what answers on its address is a
    // network peer like any other: same rules as for an upstream.
    const malformed = "the control plane sent an answer the gateway could not read";
    if (@backingInt(status) < 200) return respondError(acc, request, .bad_gateway, "control_plane_unavailable", malformed);
    const content_type = relayedContentType(arena, response.head.content_type) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return respondError(acc, request, .bad_gateway, "control_plane_unavailable", malformed),
    };

    // What the control plane says about the answer that the client needs:
    // how a stored file is to be handled, where a bucket-stored one is, when
    // to retry (headers.zig has the list).
    const relayed = try headers_mod.collectFromControl(arena, response.head.bytes);
    var control_body = framing.takeBody(&call.req, &response) catch
        return respondError(acc, request, .bad_gateway, "control_plane_unavailable", malformed);

    const request_id = acc.request_id.get();
    var out_headers: std.ArrayList(http.Header) = .empty;
    try out_headers.appendSlice(arena, &.{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "x-omnigate-request-id", .value = request_id },
        .{ .name = "x-request-id", .value = request_id },
        .{ .name = "request-id", .value = request_id },
    });
    try out_headers.appendSlice(arena, relayed);

    // Most answers are short (a job, an error, a small file): up to 64 KiB
    // are buffered, counted, and sent with their real length (never the one
    // the peer declared). A cut-short one is a 502 instead of half an
    // answer, and so is one that stops arriving: that is timed here, not by
    // the watchdog (see `Buffered`).
    guard.disarm();
    var start: Buffered = .{ .body = &control_body, .arena = arena, .limit = small_body_max };
    const first_read = start.read(app.io, app.stream_idle_timeout_ms);
    guard.arm(app.io, app.client_stall_timeout_ms);
    first_read catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |e| return e,
        else => {
            log.warn("control plane answer to {s} could not be read: {t}", .{ path, err });
            return respondError(acc, request, .bad_gateway, "control_plane_unavailable", malformed);
        },
    };
    const small = start.bytes.items;
    acc.status = @backingInt(status);
    if (start.ended) {
        return request.respond(small, .{ .status = status, .keep_alive = reusable(request), .extra_headers = out_headers.items });
    }

    // Longer (a file, a long list of jobs): streamed. With the length the
    // control plane declared when it gave one, so that a download has a
    // size and a client can tell a whole file from a cut one; the body
    // reader delivers exactly that many bytes or fails, and then the
    // connection is dropped short of them. Without a declared length:
    // chunked, and dropped without the closing chunk on a failure.
    var left_to_send: ?u64 = control_body.remaining();
    var chunk: [16 * 1024]u8 = undefined;
    var resp_buf: [8 * 1024]u8 = undefined;
    var body_writer = try request.respondStreaming(&resp_buf, .{
        .content_length = if (left_to_send) |left| small.len + left else null,
        .respond_options = .{
            .status = status,
            .extra_headers = out_headers.items,
        },
    });
    var pending: []const u8 = small;
    var from_pending = true;
    while (true) {
        const data: []const u8 = if (pending.len > 0) first: {
            const d = pending;
            pending = "";
            break :first d;
        } else next: {
            from_pending = false;
            guard.arm(app.io, app.stream_idle_timeout_ms);
            const n = control_body.read(&chunk) catch |err| return upstreamReadError(err, guard);
            if (n == 0) break;
            break :next chunk[0..n];
        };
        // Never more than the head of our answer promised (std asserts on
        // that); the reader's own count makes this unreachable.
        if (!from_pending) if (left_to_send) |*left| {
            if (data.len > left.*) return error.UpstreamUnparseable;
            left.* -= data.len;
        };
        // A client that asks for a large file and then stops reading must
        // not hold this connection for ever.
        guard.arm(app.io, app.client_stall_timeout_ms);
        try body_writer.writer.writeAll(data);
        try body_writer.writer.flush();
        try body_writer.flush();
    }
    // ... and never fewer: ending short of the promised length is an assert
    // in std, and a lie to the client.
    if (left_to_send) |left| if (left != 0) return error.UpstreamTruncated;
    guard.arm(app.io, app.client_stall_timeout_ms);
    try body_writer.end();
}

fn protocolOf(acc: *const logging.Access) errors.Protocol {
    return if (acc.anthropic) .anthropic else .openai;
}

fn respondRateLimited(acc: *logging.Access, request: *http.Server.Request, retry_after_s: u32) !void {
    acc.status = 429;
    acc.rejected = "rate_limit_exceeded";
    var num: [16]u8 = undefined;
    const secs = std.fmt.bufPrint(&num, "{d}", .{retry_after_s}) catch unreachable;
    const id = acc.request_id.get();
    var buf: [768]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    errors.write(&w, protocolOf(acc), .{
        .status = 429,
        .reason = "rate_limit_exceeded",
        .message = "this key is over its requests-per-minute limit",
        .request_id = id,
    }) catch {};
    try request.respond(w.buffered(), .{
        .status = .too_many_requests,
        .keep_alive = reusable(request),
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "retry-after", .value = secs },
            .{ .name = "x-omnigate-request-id", .value = id },
            .{ .name = "x-request-id", .value = id },
            .{ .name = "request-id", .value = id },
        },
    });
}

/// A refusal that is about load, not about the request: 429 or 503 with
/// `retry-after: 1`, so that SDKs back off and try again by themselves.
fn respondRetryLater(acc: *logging.Access, request: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8) !void {
    acc.status = @backingInt(status);
    acc.rejected = code;
    const id = acc.request_id.get();
    var buf: [768]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    errors.write(&w, protocolOf(acc), .{ .status = @backingInt(status), .reason = code, .message = message, .request_id = id }) catch {};
    try request.respond(w.buffered(), .{
        .status = status,
        .keep_alive = reusable(request),
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "retry-after", .value = "1" },
            .{ .name = "x-omnigate-request-id", .value = id },
            .{ .name = "x-request-id", .value = id },
            .{ .name = "request-id", .value = id },
        },
    });
}

/// Answer with the gateway's own error, in the client's protocol (see
/// errors.zig). `code` must be a string literal: it is the reason this
/// request is counted under, and it is what the client sees as `code`.
fn respondError(acc: *logging.Access, request: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8) !void {
    acc.status = @backingInt(status);
    acc.rejected = code;
    const id = acc.request_id.get();
    var buf: [768]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    errors.write(&w, protocolOf(acc), .{ .status = @backingInt(status), .reason = code, .message = message, .request_id = id }) catch {};
    try request.respond(w.buffered(), .{
        .status = status,
        .keep_alive = reusable(request),
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-omnigate-request-id", .value = id },
            .{ .name = "x-request-id", .value = id },
            .{ .name = "request-id", .value = id },
        },
    });
}

/// The models this key may use, or one of them (`one`), in the list shape of
/// the client's protocol (see models.zig).
fn respondModels(
    app: *App,
    acc: *logging.Access,
    arena: std.mem.Allocator,
    request: *http.Server.Request,
    snapshot: *const config.Snapshot,
    key: *const config.Key,
    one: ?[]const u8,
) !void {
    var ids: std.ArrayList([]const u8) = .empty;
    for (snapshot.routes) |r| {
        if (key.allows(r.model)) try ids.append(arena, r.model);
    }
    // Media job models are served by the control plane (POST /v1/jobs); they
    // are listed so that clients can discover them.
    for (snapshot.media_models orelse &.{}) |name| {
        if (!key.allows(name) or snapshot.findRoute(name) != null) continue;
        try ids.append(arena, name);
    }

    const protocol = protocolOf(acc);
    var out: Io.Writer.Allocating = .init(arena);
    if (one) |id| {
        const known = for (ids.items) |m| {
            if (std.mem.eql(u8, m, id)) break true;
        } else false;
        // One answer for a model that does not exist and for one this key may
        // not use, so the reply does not reveal which other models exist.
        if (!known) return respondError(acc, request, .not_found, "model_not_found", "no such model");
        try models.writeOne(&out.writer, protocol, id, app.started_unix_s);
    } else {
        try models.writeList(&out.writer, protocol, ids.items, app.started_unix_s);
    }

    acc.status = 200;
    const request_id = acc.request_id.get();
    try request.respond(out.written(), .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-omnigate-request-id", .value = request_id },
            .{ .name = "x-request-id", .value = request_id },
            .{ .name = "request-id", .value = request_id },
        },
    });
}
