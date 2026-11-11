# Architecture

omnigate is two processes with a narrow interface between them.

```
 apps ──▶ dataplane (Zig) ──────────▶ LLM providers (OpenAI-style, Anthropic-style)
            ▲   │  │
     config │   │  └─ /v1/jobs, /v1/files ─┐
            │   ▼ usage events             ▼
          control (Elixir) ── ledger · budgets · jobs · webhooks ──▶ media providers
                                                     └──▶ your bucket (S3 API) or local disk
```

- [The two planes](#the-two-planes)
- [The interface between them](#the-interface-between-them)
- [A text request](#a-text-request)
- [Usage: spool and ledger](#usage-spool-and-ledger)
- [A media job](#a-media-job)
- [State on disk](#state-on-disk)
- [Why it is built this way](#why-it-is-built-this-way)

## The two planes

| | Data plane (`dataplane/`, Zig 0.17) | Control plane (`control/`, Elixir 1.20 / OTP 29) |
|---|---|---|
| Audience | Applications. The public port. | Operators and data planes. A private port. |
| Owns | Validating request heads, paths and bodies before anything else reads them; authenticating gateway keys, the per-key concurrency cap and the memory budgets for request bodies and JSON trees, rate limits, routing, load balancing, failover, cooldowns, protocol translation, streaming, framing every response it relays, counting tokens, the response cache, client and stream timeouts, the connection cap, the access log | The config file, managed keys, prices, the usage ledger, budgets and their periods, media jobs (and their own rate, open-job and per-day limits), output storage, webhooks, dashboard, admin API, audit log, metrics, retention |
| Credentials it holds | The internal token and text provider keys (from its environment). Nothing else: in the Compose deployment its container is given no admin token, media key, webhook secret or bucket credential | The internal token, the admin token, media provider keys, bucket credentials, webhook secrets |
| State | In memory, plus two files: the usage spool and a cache of the last config | Files: the ledger (segments, snapshots and per-day files of duplicate-detection ids), the job log and its directory of large job inputs, the keys file, the audit log, stored outputs |
| Dependencies | The Zig standard library | Two direct Hex packages (Bandit, Plug). Outbound HTTP is the control plane's own HTTP/1.1 client on `:gen_tcp` and `:ssl` (`http.ex`); until commit d79406b it was OTP's `httpc` |
| If it stops | Applications get no answers | Text traffic continues; jobs answer 503; usage waits in the spool |

Text requests never pass through the control plane. Job and file requests
do: the data plane authenticates the key and forwards them.

**Inside the control plane**, the processes that hold state (the audit
log, the keys, the ledger, the job store, the job tasks, the webhook
scheduler and retention) run as one group under their own supervisor, and
that supervisor is watched by a guard (`guard.ex`) instead of sitting
directly under the application's. The config store and the HTTP listener
sit next to the guard. When the group's supervisor gives up (four crashes
inside five seconds), the guard starts the group again after a pause: half
a second at first, doubling up to thirty seconds while it keeps failing,
and half a second again once the group has stayed up for a minute. The
listener is not touched. While the group is down `/healthz` answers 200,
`/readyz` answers 503 with the reason, and a request that needs the missing
piece gets an error instead of an answer made from half-loaded state
(`GET /internal/config`: `503 not_ready`). Only at the first start is it
different: if the group
cannot start at all, the control plane does not start. Until commit d79406b
everything sat under one supervisor, so four crashes of any store inside
five seconds stopped the listener too.

## The interface between them

All of it is HTTP from the data plane to the control plane, under
`/internal/*`, authenticated with the shared internal token in the
`x-omnigate-internal` header.

| Call | Direction | Purpose |
|---|---|---|
| `GET /internal/config` | pull, every `OMNIGATE_POLL_MS` | The config snapshot. Answered `503 not_ready` while the ledger is not loaded; the data plane then keeps the config it has. |
| `POST /internal/usage/batch` | push, every `OMNIGATE_FLUSH_MS` when there is something to send | Usage events. At-least-once, spooled to disk. |
| `POST /internal/counters` | push, every `OMNIGATE_FLUSH_MS` when there is something to send | Counts of requests the data plane refused before routing, by key name and reason. Best effort, memory only. |
| `/internal/v1/jobs*`, `/internal/v1/files/*` | per client request | The jobs API, forwarded. The data plane names the authenticated key in `x-omnigate-key-sha256`. |

**What a client can make the data plane say to the control plane** is
narrow on purpose, because that call carries the internal token. The
address comes from the data plane's own configuration. Of the client's
request, a path and a query string go into it, both validated character by
character (one canonical spelling, no percent-encoding, a small character
set) and set as separate components of the URL instead of being spliced
into a string that is parsed again; one header, `Idempotency-Key`, which
must be 1 to 255 visible ASCII characters without spaces; and the body of a
`POST`, at most 8,000,000 bytes and nested at most 64 levels, sent on as
JSON whatever the client labelled it. (Until commit e4e30e4 the header was
restricted to letters, digits and `-._:`, and was checked on every
endpoint; it is now looked at only on job and file requests, the only ones
that forward it.) The data plane also sends its own id for the request
(`x-omnigate-request-id`), which the control plane uses in its log and
echoes, so one id follows a request through both processes. Of the control
plane's answer, the data plane relays the status, the content type, the
body and six headers by name: the four that say how a stored file is to be
treated (`content-disposition`, `x-content-type-options`,
`content-security-policy`, `cache-control`), `location` (where a
bucket-stored file lives) and `retry-after`. Nothing else, cookies and
server headers included. The length is not relayed: the data plane reads
the control plane's answer with the same bounded reader as a provider's
(`framing.zig`) and frames its own. An answer of at most 64 KiB is buffered
and sent with a length the data plane counted. A longer one (a file, or a
long job answer) is streamed: with the length the control plane declared
when it gave one, which the reader then holds it to byte for byte (so a
file download has its `content-length`), otherwise chunked. An answer whose head or framing cannot be
read, or that is cut short within those first 64 KiB, becomes a 502
`control_plane_unavailable`; one cut short later drops the client's
connection without the closing chunk.

**The snapshot** is the data plane's whole view of the configuration:

- keys as SHA-256 hashes with `name`, `rpm`, `models` and a `blocked` flag.
  File keys and managed keys are merged into one list before this point, so
  the data plane cannot tell them apart; a disabled key is left out;
- text upstreams, with the *name* of the environment variable holding each
  provider key;
- text routes with `strategy`, `cache_ttl_s` and each target's `upstream`,
  `model`, `weight`;
- `media_models`, the names of the media routes, used only to list them in
  `GET /v1/models`;
- a `version`, a hash of all of the above. It changes whenever anything the
  data plane sees changes, including a key flipping to blocked.

There are no budgets, prices or secrets in it, and nothing about media
beyond those names. Each key carries its `max_concurrent` (since the
close-out commit, the one after 55a294d): `0` for a key without one, to
which `OMNIGATE_MAX_CONCURRENT_PER_KEY` applies. The data
plane installs a snapshot only when its version differs from the one in
force, and writes it to the config cache file so that it can start from it
when the control plane is down.

Budgets reach the data plane only as the `blocked` flag: the control plane
compares each key's recorded spend in its current budget period with its
budget every time it builds the snapshot, which is on every poll. That is
also how a monthly or daily key unblocks: the first snapshot built after
the period turns no longer has the flag. Creating, changing, rotating or
deleting a managed key travels the same way, as a changed key list in the
next snapshot. Spend is read from the ledger, so while the ledger is
starting or restarting there is nothing to compare with, and "nothing
spent" would unblock every key. The control plane answers the poll with
`503 not_ready` (`retry-after: 1`) instead, and the data plane keeps the
snapshot it has: a blocked key stays blocked.

## A text request

1. **Accept.** A connection beyond `OMNIGATE_MAX_CONNECTIONS` is answered
   503 at once. Otherwise the connection gets a task and a deadline: a
   watchdog task cancels it if the client does not deliver a request within
   `OMNIGATE_CLIENT_TIMEOUT_MS`.
2. **Validate the head.** Before anything else reads it, the raw request
   head is checked by plain scanning (`guard.zig`): every header line has a
   name and a colon, there are no bare line feeds or control bytes, the
   target is a plain path, and the body's framing is unambiguous: a method
   that has a body carries one `Content-Length`, and a method that has none
   carries no body. A chunked request body is answered 411 like a missing
   length (until commit e4e30e4 it was accepted), and a length together
   with chunked encoding 400. A head that fails is answered 400, 411 or 417
   and the connection is closed. The path must then be in its one canonical
   form and the query string plain, or the answer is 400; the same goes for
   an `anthropic-version` or `anthropic-beta` header with anything but
   plain characters in it. Without a config snapshot the answer is 503
   `gateway_not_ready`.
3. **Authenticate.** The key from `Authorization: Bearer` or `x-api-key` is
   hashed and looked up in the snapshot. Unknown: 401. Blocked: 402 for
   anything that starts new work (reading the model list, jobs and files
   stays allowed). A request that is not for one of the text endpoints, the
   model list or the jobs API is answered 404 here.
4. **Admit.** Before any of the body is read, the request is counted
   against its key (`limits.zig`): the requests the key has in flight
   (`OMNIGATE_MAX_CONCURRENT_PER_KEY`, 512) and the memory budget for
   request bodies (`OMNIGATE_REQUEST_MEMORY_MB`, 1024), against which the
   declared length counts twice, as received and as sent on. One key may
   hold a quarter of that budget. Over the key's own limits the answer is
   429 `concurrency_limit_exceeded` or `request_memory_exceeded`; when the
   whole budget is in use it is 503 `overloaded`; each with
   `retry-after: 1`. The place is given back when the request ends.
5. **Rate limit.** The per-key token bucket is charged (not for
   `count_tokens`, which is not metered). Over it: 429
   `rate_limit_exceeded`. A request that is refused in a later step for its
   body or its model has therefore used up one request of the key's `rpm`;
   that is the price of not reading eight megabytes to find out. Until
   commit e4e30e4 the body was read and the model checked before the rate
   limit.
6. **Read the body.** A declared length over 8 MiB is answered 413 without
   any of the body being read. Otherwise the body is read, within the
   client timeout.
7. **Scan.** The body may nest at most 64 levels (400 `invalid_json`). It
   is then walked once, in place, without building a tree and without
   allocating (`jsonscan.zig`). It must be one JSON object; no object in it
   may have more than 65,536 members and no key may be longer than 8 KiB;
   and `model`, `stream` and `stream_options` may each appear once at the
   top level, spelled without escapes (400 `invalid_request`), because the
   provider parses the body again and the two readings must not differ on
   the fields the gateway acts on. The walk finds where the `model` value
   and `stream_options` are and whether `stream` is `true`. `model` must be
   a string; it names a route.
8. **Model limits, then the route.** A key restricted to a list of models
   gets 403 for anything else. A model that no route has is a 404.
9. **Response cache.** If the route has `cache_ttl_s` and the request is
   not a stream, the request is hashed together with the route name, the
   path and the key's hash, and looked up in an in-memory cache. A hit is
   answered from memory and reported as a usage event with no tokens,
   marked `cached`; nothing below happens. The hash is taken over the
   request in canonical form, which needs a tree of it (see step 11); a
   request whose tree is refused there is served, just not cached.
10. **Order the targets.** The route's strategy picks who goes first
    (`failover`: config order; `round_robin`: rotating; `weighted`: random
    by weight). Targets whose upstream is cooling down go last.
11. **Forward.** For each target in order: build the body to send; send it
    with the provider key from the environment; wait for the response head
    up to the timeout.
    - Same protocol: the body is the client's own bytes with the `model`
      value replaced by the target's model id at the place the scan found.
      For an OpenAI-style stream whose client did not ask for usage,
      `"stream_options":{"include_usage":true}` is added the same way. No
      tree is built.
    - A tree is built only where one is needed: to translate the request
      for an upstream that speaks the other protocol, for the
      response-cache key, for the two provider quirk fixes below, and to
      rewrite a `stream_options` the client sent without `include_usage`.
      Each tree is built in an arena capped at 128 times the text plus 1
      MiB, at most 96 MiB, and the cap is first reserved against
      `OMNIGATE_PARSE_MEMORY_MB` (1024), of which one key may reserve
      half. A body with more than 1,024 members in one object is not
      parsed into a tree at all. A request stopped by the member bound or
      the cap gets 400 `request_too_complex`; by the key's share, 429
      `request_memory_exceeded`; by the whole budget, 503 `overloaded`.
    - Connection error: one retry on a fresh connection, then next target.
    - Timeout, 429 or 5xx: next target, and a failure is noted for
      cooldowns.
    - A response the gateway cannot frame (a length together with chunked
      encoding, two different lengths, a transfer coding other than
      `chunked`), or a short answer that ends before the length its head
      declared: next target, as long as nothing has been sent to the
      client.
    - Anything else: this is the answer.
12. **Relay.** The upstream's response body is read by the data plane's own
    reader (`framing.zig`), not the standard library's: every chunk size is
    bounded, and a body that ends before its declared length or its last
    chunk is an error, not an end. The client's response is framed by the
    data plane and never carries a length the upstream declared.
    - An answer that is not an event stream and is at most 64 KiB is
      buffered and sent with a length the data plane counted. Until it has
      been read to its end nothing is sent, so a cut-off one still fails
      over. A translated answer that is not a stream is buffered whole (at
      most 16 MiB), converted in a tree capped like a request's, and sent
      the same way. While it is being buffered, a silent upstream is timed
      by a timer next to the read (as the wait for the head is), not by
      the watchdog: after `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` without a byte
      only the read is cancelled, the attempt fails with
      `StreamIdleTimeout`, and the request goes on to the next target on
      the same, intact task.
    - A buffered answer with a status of 400 or above that is not its
      protocol's error envelope (an array, `error` as a string, plain
      text) is put into that envelope, with the provider's message and
      code; a well-formed one is relayed byte for byte.
    - Everything else, an event stream or a longer answer, is sent chunked
      and flushed chunk by chunk. If the upstream speaks the other protocol
      the stream is translated event by event, each event in parse memory
      capped at 32 MiB. From the first byte on there is no more failover:
      if the upstream breaks off or sends less than it declared, the
      client's connection is dropped without the closing chunk, and the
      call is reported with status 499.
    - On the way through, a small JSON reader picks the token counts out of
      the bytes without buffering the body (see
      [below](#reading-usage-from-the-stream)).
    - The response head carries the gateway's own headers and the provider
      headers on a fixed allowlist (retry hints, rate-limit counters,
      request ids).
13. **Deadlines while relaying.** The watchdog cancels a connection's task
    when its deadline passes, and that is the end of the task: it waits
    for it, and nothing in the task can be interrupted a second time. So
    it is only armed where ending is the right outcome: while a client
    sends its request, while an answer is written to the client (the
    gateway's own answers included: the client stall timeout, once the
    request has been read), and while a response is being relayed. It is
    not armed while an upstream is awaited before anything was sent; those
    waits have timers of their own (steps 11 and 12).
    The connection's deadline is set anew
    before each read and each write. Before a read from the upstream it is
    `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` (5 minutes): if the upstream goes
    silent for that long in the middle of a response the watchdog cancels
    the task, both sides are closed, and the call is reported with status
    499. Before a write to the client it is
    `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` (30 seconds): a client that stays
    connected but takes nothing for that long is given up on. When the
    client stalls like that, or disconnects, in the middle of a response
    whose closing usage has not arrived, the client's connection is
    finished with and the open exchange with the upstream is handed to a
    background task. That task reads on to the provider's closing usage or
    the end of the answer, for at most `OMNIGATE_ABORT_DRAIN_MS` (2
    minutes) and `OMNIGATE_ABORT_DRAIN_MAX_MB` (64) more megabytes, then
    closes the upstream connection and reports the call with status 499:
    the provider's figures if they came, an estimate otherwise. At most 256
    answers are read on like this at once; beyond that, and with
    `OMNIGATE_ABORT_DRAIN_MS=0`, the estimate is billed at once. Until its
    reading ends, such a request keeps its place from step 4, so hanging up
    and coming back is not a way around the concurrency cap. (Until commit
    e4e30e4 the stream idle timeout covered both directions, and the
    client's own connection waited up to five seconds for the closing
    usage.) See [Operations](operations.md#streams-that-end-early).
14. **Report.** One usage event is queued. The request does not wait for it
    to be delivered. A complete, successful, non-streaming answer on a
    route with `cache_ttl_s` is also put in the response cache.
15. **Log.** One access-log line is written for the request.

If every target fails, the client gets the list of attempts in a 429
`upstream_rate_limited` when any of them answered 429 (with the longest
`retry-after` those sent), and in a 502 `all_upstreams_failed` otherwise. A
usage event with that status and no tokens is recorded.

A job or file request goes through steps 1 to 3 and is then handed to the
control plane. (A file request with a signed URL and no key skips step 3;
the control plane checks the signature.) A `POST` among them is admitted as
in step 4, with the jobs API's body limit of 8,000,000 bytes, and
`POST /v1/jobs` is charged against the rate limit as in step 5, before its
body is read.

**Errors and ids.** Every answer the data plane produces carries the
request id as `x-omnigate-request-id`, and as `x-request-id` and
`request-id` (the provider's own values when it sent them). The exceptions
are `GET /healthz`, the immediate `503 overloaded` at the connection cap,
and the refusal of a malformed request head in step 2, which is sent
before the request is given an id. The gateway's own errors are written in
the shape of the client's protocol, with the provider's category in
`error.type` and the gateway's reason in `error.code`; the table is in
[API](api.md#errors). The control
plane writes its errors in the same OpenAI-style envelope, from a copy of
the same category table (`errors.ex`), so a client of the jobs API cannot
tell which process refused it.

A request that is refused in steps 1 to 8, one that a tree limit stops in
step 11, and one that no target of the route can be sent at all
(`endpoint_not_supported`, `untranslatable_request`) produce no usage event.
They are counted per key name and reason instead, and the counts are sent
to the control plane on the same interval as usage.

**Stopping.** On SIGTERM or SIGINT the accept loop ends, idle connections
are cancelled, requests in flight get `OMNIGATE_SHUTDOWN_GRACE_MS` to
finish, the answers still being read for clients that left are stopped
(each bills what it has, by estimate if the closing usage has not come),
and queued usage is delivered once more before the process exits.

Two provider quirks are handled for translated requests only, because a
client speaking the other protocol cannot know them: models that reject
sampling parameters, and models that demand a thought signature on earlier
tool calls. The first refusal is retried with the fix, and the fix is
remembered in memory per gateway key, upstream and model. Per key, because
the evidence is a provider's error text, and a client can make a provider
echo text of its choosing: in a shared table one key could switch sampling
parameters off for everyone using that model. Scoped to the key that
provoked it, the worst a client can do is change its own requests. The
table holds at most 20,000 entries; beyond that nothing more is remembered
and each such request pays for its own retry.

### Reading usage from the stream

The token counts that become the bill are read by a byte-at-a-time JSON
tokenizer (`usage.zig`) that tracks where it is in the document. A number
counts only at the places the protocols put usage: `usage.<field>`,
`usage.<details>.cached_tokens`, Anthropic's `message.usage.<field>`, and
the Responses API's `response.usage.<field>`. Strings are skipped as
strings. An earlier version searched the raw bytes for `"prompt_tokens":`
and the like, so text that a client could get echoed into a response (a
tool schema, a tool call's arguments) could change that client's own bill.

- Values are max-merged, so Anthropic's cumulative `output_tokens` and
  OpenAI's single final `usage` object both come out right, and the reader
  does not care where network reads split the data.
- No count above 2^40 is believed, and sums saturate, so no number a
  provider sends can overflow anything.
- The reader also notes whether the provider's **closing** figures were
  seen (a top-level `usage` with an output count, or `response.usage`),
  and counts bytes, server-sent events, and the bytes of generated text
  (the string values of fields such as `content`, `text`, `delta` and
  `arguments`, at any depth). When a response ends early without the
  closing figures, the usage event carries an estimate instead and is
  marked `estimated`. The estimate is never less than what was metered.
  Missing input (no input count of any kind was seen) is taken as the
  request body's bytes divided by 4, plus 1,600 tokens for every image,
  document, file or audio part the request names (counted by the part type
  strings in the body, so an OpenAI-style `image_url` part counts twice).
  Output is, for an event stream, the largest of what was metered, one
  token per event, and the generated text's bytes divided by 4; for an
  answer that was not an event stream, the larger of what was metered and
  its bytes divided by 4. Until commit e4e30e4 the estimate knew neither
  the media parts nor the generated text. See
  [Operations](operations.md#streams-that-end-early).

### When input is hostile

A panic anywhere in the data plane ends every connection it is serving, so
the rule is that no input may reach code that asserts on its shape.

- Request heads and JSON nesting are checked by code that cannot fail in
  any way other than returning "no" (`guard.zig`), before the standard
  library's parser, header iterator or JSON serialiser see them. The
  client's JSON may nest 64 levels, an upstream's 128; the serialiser's own
  limit is 256.
- Nothing a single client sends decides how much memory the process uses
  (`limits.zig`, `jsonscan.zig`). The concurrency cap and the request-memory
  budget are consulted before a body is read; the body is then scanned in
  place; and a JSON tree, which can be hundreds of times the size of its
  text, is built only inside an arena with a cap that was reserved against
  a budget first. A body with more than 1,024 members in one object is not
  parsed into a tree, because the standard library's JSON object is a hash
  map with a fixed seed and keys chosen to collide cost the square of
  their number.
- An upstream is a network peer like any other, and so is whatever answers
  on the control plane's address. Their response bodies are framed and
  read by the data plane's own code (`framing.zig`), never by the standard
  library's readers: a head with both a length and chunked encoding is
  refused, a chunk size must fit (16 hex digits at most, and no chunk over
  2^40 bytes), chunk-size lines and trailers are bounded, and a body that
  ends early is an error. The client's response is framed by the data
  plane, so no length an upstream claimed reaches code that asserts on it.
  A relayed `content-type` with a control byte in it, or longer than 256
  bytes, is refused.
- Text from a client or a provider that goes into a log line has its
  control bytes escaped.
- After answering a request whose body it did not read, the data plane
  closes the connection instead of reusing it (the unread body would be
  parsed as the next request), and reads and discards what the client is
  still sending for up to two seconds first, so the client sees the answer
  and not a reset.
- If a panic happens anyway, an optimized build logs one line and exits
  with status 70, which a supervisor can tell from a clean stop (0), a
  startup error (1) and an unknown command-line argument (2). Usage events
  are appended to the spool as they are queued, so they survive the
  restart.

`tools/malformed_test.py` (which also plays a hostile upstream and a
hostile control plane), the unit tests in `framing.zig`, `jsonscan.zig` and
`limits.zig`, and the fuzz tests in `translate.zig` and `usage.zig`
exercise this; none of it has faced real hostile traffic.

## Usage: spool and ledger

**On the data plane**, each usage event is appended to an in-memory queue
and to the spool file. A background task sends the oldest events in batches
of up to 500, and removes them only after the control plane has acknowledged
the batch. Failures back off up to 10 seconds. The spool file is reloaded
at startup, so events survive both a control-plane outage and a data-plane
restart. After a crash the spool can hold events that were already
delivered; they are sent again.

- **Bounds.** The queue holds at most 100,000 events and at most 128 MiB.
  Beyond that the oldest are kept and new events are dropped, counted and
  logged as an error. Oldest, because a batch in flight is acknowledged by
  count from the front, and because a queue that shed from the front would
  turn one long outage into the silent loss of everything before it.
- **The file follows what is undelivered.** It is emptied when the queue
  drains completely, and rewritten to hold only the pending events once
  the delivered ones at its front take more than 1 MiB and more than the
  pending ones. Until commit e4e30e4 it shrank only when the queue was
  empty.
- **A spool of any size does not stop a start.** The file is read in
  pieces; a torn or damaged line is dropped; and if it holds more than the
  queue may, the front of it is loaded, the rest is discarded with an
  error in the log, and the data plane starts.

**On the control plane**, a batch is appended to the ledger's active
segment (`ledger.jsonl`) and synced to disk before it is acknowledged, then
folded into per-key totals in memory. Every event carries the request id as its
`id`, and an event whose id was already recorded is skipped. That is what
makes at-least-once delivery bill exactly once, for as long as the id is
remembered: `retention.ledger_ids_days`, 3 days by default (see
[below](#ledger-files-segments-and-snapshots)). An event that cannot be
recorded (missing or mistyped fields, a token count that is negative or
above 10^12) is dropped and counted in
`omnigate_ledger_invalid_events_total`; text in an event that is not valid
UTF-8 is repaired, not a reason to drop it.

A text usage event as the data plane sends it:

| Field | Meaning |
|---|---|
| `id` | The request id (also `x-omnigate-request-id`). |
| `key_sha256` | Which gateway key. |
| `route_model` | The model name the client used. |
| `upstream`, `target_model` | Which target answered; null when all failed. |
| `status` | HTTP status sent to the client; 499 for a response that broke off mid-way (the client left or stalled, the upstream went silent or cut it short); 502 when all targets failed, or 429 when any of them was rate limited. |
| `stream` | Whether the request was streamed. |
| `input_tokens` | Input tokens that were not served from the provider's prompt cache. |
| `cached_input_tokens` | Input tokens read from the provider's prompt cache. |
| `cache_write_input_tokens` | Input tokens written to the provider's prompt cache. |
| `output_tokens` | Output tokens. |
| `cached` | `true` when the answer came from the gateway's own response cache; such an event has no upstream and no tokens. |
| `estimated` | `true` when the token counts are an estimate, because the response ended before the provider's closing usage arrived. Kept in the ledger line; it does not change how the event is priced. |
| `latency_ms` | From the start of the failover loop to the end of the response; for an abandoned stream that was read on in the background, to the end of that reading. |
| `attempts` | Each upstream tried and its outcome. |
| `ts_ms` | When the request finished on the data plane (for an abandoned stream, when the reading-on ended and the event was written). |

The token counts are read from the response in the provider's own terms and
then normalised by the protocol of the upstream that answered: an
OpenAI-style input count includes cached tokens, so they are subtracted; an
Anthropic-style one does not, so its cache reads and writes are taken as
reported. Whatever the provider, `input_tokens` in the ledger means
"uncached input".

The control plane adds `cost_usd` (the four counts times the target's four
prices at the time of recording; zero for a `cached` event and for one
with no upstream), `ts` (from `ts_ms`) and `received_at`. An event for a
route or target the config does not have is recorded at $0, counted in
`omnigate_ledger_unpriced_events_total` and logged once per route and
target. Media jobs are written to the same ledger by the control plane
itself, with `"kind": "media"`, the job id as `id`, and the job's own
`cost_usd`.

Besides the per-key totals, the ledger keeps each key's spend per UTC month
and per UTC day, keyed by the event's own time. That is what a monthly or
daily budget is compared with. Rows of periods long past are dropped from
memory (the segments keep the events for as long as they are kept), and
totals for the current UTC day feed the dashboard's "today" figures.

Totals are kept per key **hash**. A managed key that has been rotated has
several hashes; the control plane adds them up wherever it shows a key.

Known limits, from the README: spool appends are not fsynced, so a power
loss can drop the last few events; the spool holds at most 100,000
undelivered events (128 MiB), beyond which the oldest are kept and new
ones dropped; the ledger lives on a single control-plane node.

### Ledger files: segments and snapshots

The ledger is not one file that is replayed from the beginning at every
start. It is a set of files next to each other, named after
`OMNIGATE_LEDGER` (`ledger.jsonl` by default):

| File | What it is |
|---|---|
| `ledger.jsonl` | The **active segment**: one JSON event per line, appended and synced before a batch is acknowledged. |
| `ledger.000001.jsonl`, `ledger.000002.jsonl`, ... | **Sealed segments**: older events, in order. The active segment's number is one more than the highest sealed number. |
| `ledger.snapshot` | Everything a replay of the covered events would have produced, except the duplicate-detection ids: the totals per key, per UTC day and per budget period, and the short list of recent requests. It records the position it covers, a segment number and a byte offset, and for each day's id file how long that file was. Version 2 since commit d79406b. |
| `ledger.snapshot.prev` | The snapshot before that one, kept as a spare. |
| `ledger.snapshot.tmp` | A snapshot being written. Never read. |
| `ledger.ids.2026-11-10`, ... | The **duplicate-detection ids** of the events recorded on that UTC day: 16 bytes per id, appended, never rewritten. One file per day on which usage was recorded. |

- **Sealing.** The active segment is renamed to its numbered name, and a
  new empty one started, when it reaches 64 MiB, and at the first
  five-minute check after the UTC day it was written in has ended.
- **Snapshots** are written every 50,000 events, every five minutes when
  anything was recorded since the last one, after a segment is sealed, after
  a start that had to replay events (or found no usable snapshot, or
  converted an old one), after `retention.ledger_ids_days` dropped a day
  of ids, and at a clean stop when anything was recorded since the last
  one. A snapshot is a magic line, a SHA-256 of the payload, and the
  payload (Erlang's external term format). It is written to the `.tmp`
  name and synced; then the current snapshot is renamed to `.prev` and the
  new one into place. Its size follows the number of keys, not the number
  of requests, so writing it does not stall recording; the commit that
  moved the ids out of it (d79406b) records the pause at 1,000,000 ids
  going from 1.6 s to 12 ms.
- **Duplicate-detection ids.** An id is remembered as 118 bits of its
  SHA-256, not as its own bytes: ids are whatever the sender made them, job
  ids included. That is 16 bytes in the day's file and one row in that
  day's table in memory, about 61 MiB of memory per million ids by the
  code's own figure. The day is the UTC day on which the event was
  recorded. A batch appends its ids to the day's file without a sync of
  its own; a snapshot syncs the file and records its length.
- **Start.** The control plane loads the newest snapshot that passes every
  check (the magic line and the checksum match, the contents decode, and the
  ledger bytes it covers are still there and are the same bytes) and replays
  only the events written after it. If the newest one fails a check the
  spare is used; if both fail, every segment is replayed. Each id file is
  cut back to the length the snapshot recorded, and a file the snapshot
  does not know is removed: the ids beyond that point belong to events
  after the snapshot, which are replayed and add their ids again. With no
  usable snapshot the id files are discarded and rebuilt from the events
  on disk. Either way the ids in memory after a start are exactly those of
  the events that were counted, so the replay skips an event whose id is
  already there (a snapshot and its offset that disagree, a batch written
  twice) instead of counting it a second time, and logs how many it
  skipped. The commit that introduced snapshots records 1,000,000 events
  loading in 0.75 s instead of 10.7 s.
- **Not readable until loaded.** The ledger's tables are filled under
  private names and get the names that readers use only when the snapshot
  is loaded and the later events are replayed. Until then a read fails
  instead of answering from a half-filled table: "this key has spent
  nothing" must never be an artefact of a restart. That is why
  `GET /internal/config` answers `503 not_ready` during that time.
- **Nothing to migrate.** An installation that only ever had `ledger.jsonl`
  is simply at segment 1, still active. Its first start with this code
  replays the file once and writes the first snapshot. A version 1
  snapshot, which held the ids themselves (written before commit d79406b),
  is read once: the ids are written out into per-day files, by the day
  each was recorded, and a version 2 snapshot is written at once. The
  reverse does not hold: code from before d79406b ignores a version 2
  snapshot ([Upgrading](upgrading.md#going-back)).
- **Deleting old segments.** `retention.ledger_days` deletes sealed
  segments whose last write is older than the cutoff. A segment is deleted
  only when both snapshot generations cover it, and the newest sealed
  segment is never deleted (the numbering is read from the file names).
  After a restart only the snapshot the process started from is vouched
  for, so the sweep first writes a new one, which makes the validated one
  the spare, and then deletes. Lifetime and period totals are
  unaffected, because the snapshots carry what the deleted segments
  contributed.
- **The consequence.** Once segments have been deleted, the two snapshots
  hold the only copy of those totals. If both were lost or damaged, the next
  start would rebuild the totals from the segments that remain and log an
  error saying that spend recorded before them is lost. Without
  `ledger_days` the segments are complete, and losing the snapshots costs
  start-up time only.
- **`retention.ledger_ids_days`** (3 by default; 14 until commit d79406b)
  forgets duplicate-detection ids by whole UTC days: the table and the file
  of every day that ended at or before the cutoff are deleted, with no scan
  of a large table and no rewrite of a large file. An id is therefore kept
  for at least that many days and at most a day longer. It touches neither
  totals nor segments. An event that is resent after its id was forgotten
  is counted a second time, so the setting must stay above the longest time
  a data plane may hold undelivered usage. An explicit `0` keeps the ids
  for ever. The id files belong to the snapshot that records their
  lengths: a ledger restored from a backup without them keeps its totals
  but has forgotten which events it already counted.

Each step is safe to crash in. A torn last line of the active segment is
cut off at the next start (its batch was never acknowledged, so the data
plane sends it again). A crash while a snapshot is being installed leaves
either the old one or the spare usable. A crash between the two halves of
sealing leaves no active file, which a start treats as an empty one. An id
file is cut back at the next start to the length the snapshot recorded, in
whole records, so a torn or unsynced tail cannot shift what follows it. The
unit tests in `control/test/ledger_snapshot_test.exs` exercise the segment
and snapshot states, and `control/test/wave6_test.exs` the id files; none
of this has run in production.

## A media job

```
queued ──▶ running ──▶ succeeded
              │──────▶ failed
              └──────▶ canceled
```

1. **Create.** The control plane checks the key's budget (for its current
   period), its model list and its requests-per-minute limit. The limit is
   counted here as well as in the data plane, with the same token bucket,
   number for number (a burst of up to `rpm`, refilled at `rpm` per
   minute; until commit d79406b the control plane counted in fixed
   one-minute windows). A request that repeats an idempotency key this
   gateway key already used creates nothing and is not counted. Then it
   finds the media route and validates the request:
   - `input` and `metadata` are objects, together no larger than
     `media.max_input_bytes`;
   - if the route has `allowed_input`, `input` has no field outside it;
   - a duration or a count is not negative, and a duration may be written
     `5`, `"5"` or `"5s"`; on a route with a target priced per second the
     job must name a duration unless that target has `default_seconds`,
     and may not exceed its `max_seconds`;
   - a field that has `price_multipliers` carries one of the listed values;
   - the webhook URL and the idempotency key are acceptable.

   An `input` over 8 KiB as JSON is written, synced, to a file of its own
   (`<jobs log>.inputs/<job id>.json`) before the job that points at it
   exists; the job record then only says so, and a job that is not created
   leaves no file behind. The job is then written to the job log. With an
   idempotency key already used by this gateway key, the existing job is
   returned instead. Otherwise the job store refuses the job if the key
   already has `max_open_jobs` unfinished ones (429 `too_many_open_jobs`)
   or has already created `max_jobs_per_day` jobs this UTC day (429
   `too_many_jobs_today`; 10,000 unless the key or `media.max_jobs_per_day`
   says otherwise). Those checks and the insert happen in one step inside
   the store, so two requests cannot both take the last slot. A job that
   cannot be written to disk is refused with 503 `storage_unavailable`.
2. **Cache.** If caching applies and an identical job succeeded earlier
   (and is fresh enough), its stored outputs are shared with the new job,
   which finishes at once at no cost.
3. **Run.** A task takes the route's targets in order. Before each submit
   it records which target it is trying. An adapter either answers with the
   outputs directly (one-call providers) or returns a provider job id, which
   is written to the job log *before* polling starts.
4. **Poll.** Every `media.poll_interval_ms` the adapter asks the provider.
   A target that exceeds the route's `timeout_s`, reports a failure, or has
   five transient polling errors in a row is abandoned and the next target
   is tried. Every answer a provider (or the bucket) gives is read through
   a cap by the control plane's own HTTP client (`http.ex`): 4 MiB for an
   API answer, and for an answer that carries the media inline four thirds
   of `media.max_output_bytes` plus 64 KiB, at most 256 MiB. A longer
   answer is an error and the connection is closed. What a provider says
   about a failure is made one line of valid UTF-8 (`text.ex`) before it
   is logged or stored in the job.
5. **Re-host.** Each output is downloaded (or decoded, for inline results),
   hashed, and moved into the configured storage: a local directory, or an
   S3-compatible bucket by SigV4-signed PUT. A download is aborted once it
   passes `media.max_output_bytes`. An output URL comes out of a
   provider's answer, so it is treated like a webhook URL: the host is
   resolved once, every address is checked against the private-address
   rule, and the connection goes to the checked address. Redirects are
   followed by the control plane itself, one hop at a time with the same
   check on each, and at most five of them. A storage failure fails the job
   without trying another provider, since the next one would hit the same
   storage.
6. **Finish.** The job moves to a final status exactly once. Its cost is
   computed from what the adapter that delivered sent to the provider (each
   adapter reports the characters and seconds in its own request; see
   [Configuration](configuration.md#mediaroutes)), with every part of the
   price at least zero. On a target priced per second, the seconds are
   what the adapter sent, or the target's `default_seconds` when the
   request named none, and never less than its `min_seconds`; the whole
   price is then multiplied by the factors the route's `price_multipliers`
   give for the input's values. The cost goes to the ledger (the job id is
   the event id, so repeating this after a crash is harmless), and the
   job's webhook, if any, is armed. If the ledger cannot be reached at
   that moment (it is restarting), the job keeps a mark that its cost is
   still owed, and a check that runs once a minute records it.
7. **Webhook.** Delivery attempts are scheduled by a small process that
   keeps the timers and a queue; each delivery runs in a task of its own.
   The state of each delivery is stored in the job, so retries continue
   after a restart. An attempt is written to the job before the request is
   sent, so a delivery cut short by a crash or a restart has used up its
   attempt, and a receiver gets at most `max_attempts` requests per job
   however deliveries end. At most `media.webhooks.max_concurrent` (16)
   deliveries run at once, and at most `max_concurrent_per_key` (4) for
   the jobs of one gateway key; the rest wait their turn, fairly across
   keys. For each attempt the target host is resolved once, the
   addresses are checked against the private-address rule, and the
   connection goes to the address that was checked. Only the status of the
   receiver's answer matters: at most 16 KiB of its body are read, and a
   redirect is a failed delivery, not followed. The same once-a-minute
   check re-arms a delivery whose timer was lost.

**Restart safety.** At startup the control plane replays the job log and
resumes every unfinished job. A job with a recorded provider id goes
straight back to polling; it is never submitted, and paid for, a second
time. Finished jobs whose ledger event or webhook was cut off by the crash
get them now. The README names the remaining window: a crash between a
provider accepting a job and its id reaching disk, or during a synchronous
provider call, resubmits that job. An input file without a job in the log
is removed at startup. The job store can also restart on its own while the
control plane keeps running (see [The two planes](#the-two-planes)): a
running job then waits for it, up to about half a minute, instead of
failing. The store itself does not stop over what it is handed: text that
is not valid UTF-8 is repaired before it is stored, and a change that
cannot be written is an error for its caller, with the job unchanged.

**Serving a stored file.** The bytes and their declared type came from a
provider. The control plane serves them as a download
(`content-disposition: attachment`), with `nosniff` and a sandboxing
`Content-Security-Policy`, and keeps the declared type only when it is one
of a short list of image, video and audio types (and JSON); anything else
goes out as `application/octet-stream`. The data plane passes those
headers on to the client.

**Adapters** are small modules implementing `submit` and `billable`, and
optionally `poll` and `cancel`. There are seven: `replicate`, `fal`, `openai_images`,
`elevenlabs`, `gemini`, `gemini_interactions`, `xai_video`. See
[Providers](providers.md#media-providers).

## State on disk

| File | Process | Written | Purpose |
|---|---|---|---|
| The config file | control (read only) | by you | File keys, upstreams, routes, media, retention. |
| `ledger.jsonl` | control | Appended and synced per batch. Renamed to the next numbered name when it is sealed (at 64 MiB, or after the UTC day turns); never rewritten. | The ledger's active segment: the newest usage events. |
| `ledger.000001.jsonl`, ... | control | Never written again once sealed. Deleted by `retention.ledger_days`, if set. | Sealed ledger segments: the older usage events. |
| `ledger.snapshot`, `ledger.snapshot.prev` | control | Replaced (temp file, sync, two renames) every 50,000 events, every five minutes while there is something new, after sealing, after `retention.ledger_ids_days` dropped a day of ids, and at a clean stop. | The ledger's totals and period spend up to a recorded position, so a start replays only what came after, and the length each day's id file had at that position. It no longer holds the duplicate-detection ids themselves (version 2, since commit d79406b). Once segments have been deleted, the only copy of their totals. Its checksum catches accidents and is not a signature, so the decoded contents are also checked row by row before any of it is used; a file that does not look exactly like a snapshot is ignored. |
| `ledger.ids.YYYY-MM-DD` | control | One file per UTC day on which usage was recorded. 16 bytes are appended per recorded event id; the file is synced when a snapshot records its length, and never rewritten. Cut back at a start to the length the snapshot recorded. Whole days are deleted by `retention.ledger_ids_days` (3 by default). | The duplicate-detection ids, so that an event sent twice is counted once. Belongs to the snapshot that records its length: back it up with the rest of the ledger. |
| `jobs.jsonl` | control | A new job appends its full snapshot; each later change appends a short patch line with only the fields that changed, so a job's input is written once. Every line is synced before the change is visible. Rewritten compacted (one full line per job) at a start that finds more lines than jobs, after a retention sweep that removed jobs, and while running (checked once a minute) once the lines appended since the last compaction exceed both 5,000 and twice the number of jobs. | Job state. A job whose input is over 8 KiB has `"input": null` and `"input_file": true` here. |
| `jobs.jsonl.inputs/<job id>.json` | control | Written once, synced, before the job that points at it is created. Deleted with the job by retention; a file without a job is removed at a start. | The `input` of a job when it is over 8 KiB as JSON, kept out of the job record and out of memory. Belongs to `jobs.jsonl`: back them up together. |
| `keys.json` | control | Replaced whole on every key change (temp file, sync, rename). | Managed keys: name, SHA-256 of the current secret and of earlier ones, budget and period, rate limit, models, the limits on unfinished jobs and on jobs per day, disabled flag, and the webhook secret (in clear text) if set. Never a key itself. |
| `audit.jsonl`, `audit.jsonl.1` to `.3` | control | One line appended and synced per admin action. Failed and throttled sign-ins, which anyone can cause, are not one line each: the first from an address in a minute is a line, the rest are counted and written as one summary line with `repeats` when the minute is over, or when the control plane is stopped cleanly. When the file would pass `OMNIGATE_AUDIT_MAX_MB` (50) it is renamed to `.1`, the older files move up, and the fourth falls off. | Who changed which key, and sign-ins. Every text field is made single-line, valid UTF-8 before it is written. |
| The media directory | control | One directory per job. | Locally stored outputs. |
| `omnigate-usage.spool` | data | Appended per usage event (not synced). Emptied when the queue drains; rewritten to hold only the undelivered events once the delivered ones at its front take more than 1 MiB and more than the undelivered ones. | Undelivered usage events, at most 100,000 and 128 MiB of them. |
| `omnigate-config.cache.json` | data | Rewritten (temp file, then rename) when a new snapshot is installed. | Start without the control plane. Holds key hashes and routes, never secrets. |

File names are the defaults; each has an environment variable
([Configuration](configuration.md#environment-variables)).

There is no database and no message broker. In memory only, and starting
fresh after a restart:

- data plane: rate-limit buckets, the per-key counts of requests in flight
  and memory held, cooldowns, round-robin counters, learned model quirks,
  the response cache, and refusal counts not yet reported;
- control plane: the refusal counts it has received, the failed-login and
  wrong-token counters, the token buckets for creating and for listing
  jobs, the two counters behind `omnigate_ledger_invalid_events_total` and
  `omnigate_ledger_unpriced_events_total`, and the counts of failed
  sign-ins not yet written to the audit log as a summary line. The short
  lists of recent requests and audit entries that the dashboard shows are
  also held in memory, but both come back after a restart: the request
  list from the ledger's snapshot and segments, the audit list from the
  live audit file. So do the duplicate-detection ids (from their files),
  each key's count of jobs created today (from the job log), and the
  webhook timers (from the jobs).

Dashboard sessions are not state at all: the cookie is signed with a key
derived from the admin token and carries its own expiry.

## Why it is built this way

The reasons below are the ones stated in the code and the README.

- **The public path must not depend on the control plane.** "A control-plane
  outage must never take the gateway down" is the rule in the data plane's
  control client. Hence the pulled snapshot, the config cache, and usage
  delivery that never blocks a request.
- **Bill once, even through outages.** Usage delivery is at-least-once with
  a spool on one side and id-based deduplication on the other, instead of a
  synchronous write per request.
- **Secrets stay where they are used.** The snapshot carries key hashes and
  variable names. Text provider keys exist only in the data plane's
  environment, media and bucket credentials only in the control plane's.
  The Compose deployment enforces that with one environment file per
  container, so the process that faces the internet never holds the admin
  token.
- **Never trust a URL someone else chose.** A webhook URL comes from a
  client and an output URL from a provider. Both go through one module
  (`net_guard.ex`) that resolves the host once, refuses anything that is
  not a public unicast address (loopback, private, link-local, carrier NAT,
  documentation and benchmarking ranges, multicast, and the IPv6 forms that
  carry an IPv4 address inside), and hands back the address to connect to.
- **A limit that guards paid work is enforced where the work starts.** The
  data plane rate-limits job creation, but only for the path it recognises
  as one; the control plane counts again in the handler that creates the
  job, with the same token bucket, and caps unfinished jobs and jobs per
  day per key there.
- **What a request may cost is settled before it is read.** The key's
  concurrency cap, the memory budgets and the rate limit all come before
  the body, the body is scanned in place, and a tree is built only where
  one is needed and only under a cap. The price is that a request refused
  for its model or its JSON has already used one request of the key's
  rate limit. Until commit e4e30e4 it was the other way round: the body
  was read and parsed into a tree first, a refused model cost nothing, and
  nothing bounded what the requests of one key could make the process hold
  and parse at once.
- **A peer's claims about its own response are not passed on.** The data
  plane reads every upstream and control-plane body with its own bounded
  framing and frames what it sends itself; the control plane reads every
  outbound response through a cap chosen by the caller, with its own
  HTTP client. The price on the data plane's side is that a provider's
  answer over 64 KiB goes out chunked. (So did file downloads, until the
  close-out commit: the control plane's declared length is passed on
  again, enforced by the same reader.)
- **Bill what the provider was asked for.** A media job's price follows the
  request the adapter built, not labels in the client's input, and a
  per-second price always has seconds to apply to (the request's, or the
  target's default, never below its minimum); an abandoned stream is
  billed, by the provider's figures when they can still be read and by an
  estimate otherwise, and reading on for those figures happens in the
  background, for up to two minutes, so that the figures are the
  provider's far more often; and token counts are read only from where the
  protocols put them.
- **Three audiences, three credentials.** Applications use gateway keys,
  data planes use the internal token, operators use the admin token, and
  none works in another's place.
- **Keys are stored as hashes.** A managed key is generated by the control
  plane, shown once and kept only as its SHA-256, like a file key written
  with `key_sha256`. A lost key is replaced by rotation, not recovered.
- **A cache must not leak across tenants.** The response cache makes the
  gateway key part of the identity of a request, and sits behind
  authentication, the budget, model limits and the rate limit.
- **Refusals are worth seeing but not worth a disk write.** Requests the
  gateway turns away are counted in memory and reported best effort, while
  anything that costs money goes through the spool and the ledger.
- **A slow or silent peer must not hold a thread for ever.** The data plane
  uses one thread per connection, so every wait on a client or an upstream
  has a deadline, enforced by one watchdog task that cancels the
  connection's task (which also works on Windows, where shutting a socket
  down from another thread does not wake a blocked read). A client that
  reads nothing has a deadline of its own, much shorter than the one for a
  silent upstream, and the reading that goes on for billing after a client
  has left is taken off the client's connection, bounded in time, in bytes
  and in number, and still counted against the key.
- **No extra services to run.** State is files on disk, loaded at start.
  The README's comparison table lists this as a deliberate difference.
- **Start-up time must not grow with history.** A ledger that is replayed
  from its first event gets slower to start every day. Snapshots bound the
  replay to what was written since the last one, and segments let old
  history be deleted without touching the totals.
- **An SDK should not be able to tell the gateway from the provider.** So
  the gateway's own errors, its model list and its request-id headers follow
  the protocol of the endpoint the client called.
- **The control plane refuses what it does not recognise.** Its guards and
  its router must see the same path, so a path with an encoded character is
  refused outright, an unknown first segment is a 404 at the guard, and
  credentials are checked before a body is parsed. A body is read at all
  only for a caller who has authenticated and for the sign-in form (at
  most 4,096 bytes); anyone else's is left unread and the connection is
  closed after the answer. Wrong credentials are counted per address and
  locked out for a minute after too many, wherever the admin token is
  accepted, the dashboard and the sign-in page included; the
  listener speaks HTTP/1.1 only, since every protocol left on is one more
  parser in front of the authentication.
- **One spelling per path on the public port too.** The data plane decides
  what a request is from its path and then forwards that path. With a
  single canonical form the two can never disagree.
- **A crash must be visible and survivable.** One process serves every
  connection, so input is validated before anything can assert on it, and
  the last line of defence is a panic handler that logs and exits with a
  status a supervisor can act on. In the control plane, text from outside
  is made valid UTF-8 before it is stored or encoded, the stores answer an
  error instead of stopping, and if one of them crashes repeatedly anyway,
  the group of stores is restarted with a growing pause while the listener
  keeps answering. Until commit d79406b they shared one supervisor with
  the listener, and one bad input sent four times was an outage.
- **Duplicate detection is working memory, not history.** The ids that make
  delivery exactly-once live outside the snapshot, in one small file per
  day, and are forgotten a day at a time after `retention.ledger_ids_days`
  (3). The price is stated: an event resent after its id was forgotten is
  counted twice, so the window must outlast the longest time a data plane
  holds undelivered usage.
- **Small dependency surface.** The data plane uses only the Zig standard
  library, the control plane has two direct Hex packages (its outbound
  HTTP client is its own code on OTP's sockets), the tools use only
  the Python standard library. The one exception is deliberate and
  optional: `tools/sdk_compat.py` needs the official OpenAI and Anthropic
  SDKs, because testing them is its purpose.
- **Provider output URLs expire.** So outputs are copied into storage the
  operator controls and jobs hand out the operator's URLs.
- **Paying a provider twice is worse than a slow restart.** So the provider
  job id is persisted before polling, and a resumed job polls instead of
  resubmitting.

What this design does not give you yet: cluster-wide budgets and rate
limits (both are per process or per node), and latency- or cost-aware
routing. The response cache, the refusal counts, the per-key concurrency
cap and the memory budgets are likewise per data-plane process, not
shared.
