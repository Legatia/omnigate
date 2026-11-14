# API reference

Two HTTP surfaces:

- The **gateway** (data plane, port 8080 by default) is what applications
  call: text endpoints, the jobs API and file downloads.
- The **control plane** (port 4000 by default) is for operators: dashboard,
  admin API, metrics. Applications never talk to it.

Contents:

- [Authentication](#authentication)
- [Errors](#errors)
- [Text endpoints](#text-endpoints)
- [Using the official SDKs](#using-the-official-sdks)
- [Jobs API](#jobs-api)
- [File URLs](#file-urls)
- [Webhooks](#webhooks)
- [Control plane: admin API, metrics, dashboard](#control-plane)

The examples use the keys and routes of `config/omnigate.dev.json` (see the
[Quickstart](quickstart.md)).

## Authentication

Send a gateway key in either header:

```
Authorization: Bearer og-unlimited-key
```

```
x-api-key: og-unlimited-key
```

Every gateway endpoint needs a key except `GET /healthz` and a file URL that
carries a valid signature.

A key that has been disabled, deleted or rotated away is answered like a
key that never existed: `401 invalid_api_key`.

## Errors

### Shape

Errors the gateway raises itself are written in the shape of the protocol
the client is speaking, so that a program built on the OpenAI or the
Anthropic SDK handles them like the provider's own. A provider's own
errors are passed on, and put into that shape when they are not in it:
see [Provider errors](#provider-errors).

On OpenAI-style endpoints, and on everything that is not listed under
Anthropic below (the jobs API included):

```json
{"error": {"message": "unknown gateway key", "type": "invalid_request_error", "param": null, "code": "invalid_api_key"}}
```

On Anthropic-style endpoints (`/v1/messages`, `/v1/messages/count_tokens`,
and `/v1/models` when the request carries an `anthropic-version` header):

```json
{"type": "error", "error": {"type": "authentication_error", "message": "unknown gateway key", "code": "invalid_api_key"}, "request_id": "0123456789abcdef0123456789abcdef"}
```

- **`error.code` is the gateway's own reason**, the same string in both
  shapes. It is the stable thing to match on, and the `reason` label the
  request is counted under in
  [`omnigate_rejected_requests_total`](#get-metrics).
- **`error.type` is the provider's broader category** for that reason, from
  the table below. It differs between the two protocols.
- `param` is always `null`. `request_id` (Anthropic shape) is the request's
  `x-omnigate-request-id`.

Earlier commits put the reason in `error.type` and used one shape for both
protocols. A client that matched on `error.type` must now match on
`error.code`.

**One shape, whichever process refuses.** The jobs API and file downloads
are answered by the control plane, and so is everything on its own port
(the admin API, `/metrics`, `/internal/*`). Its errors have the same
OpenAI-style envelope as the data plane's:

```json
{"error": {"message": "no such job", "type": "invalid_request_error", "param": null, "code": "job_not_found"}}
```

The reason is in `error.code` and the category in `error.type`, taken from
the same table as the OpenAI column below (reasons that are not in it get
their category from the status). A client of `/v1/jobs` therefore cannot
tell, and need not care, which of the two processes said no. The control
plane always answers in the OpenAI shape; the jobs API has no Anthropic
form. Until commit 10bc009 the control plane used a shape of its own,
`{"error": {"type": "<reason>", "message": "..."}}`: a client that read a
job error's reason from `error.type` must read `error.code` now.

### Reasons

| Status | `error.code` | OpenAI `error.type` | Anthropic `error.type` | When |
|---|---|---|---|---|
| 400 | `invalid_json` | `invalid_request_error` | `invalid_request_error` | The body is not a JSON object, or its arrays and objects are nested deeper than 64 levels. |
| 400 | `missing_model` | `invalid_request_error` | `invalid_request_error` | No `"model"` string in the body. |
| 400 | `invalid_request` | `invalid_request_error` | `invalid_request_error` | The request head is malformed or ambiguous, the path is not in canonical form, the query string has characters outside the allowed set, an `anthropic-version` or `anthropic-beta` header (or, on a job request, `Idempotency-Key`) has a value the gateway will not forward, or the JSON body has an object with more than 65,536 members, a key longer than 8 KiB, `model`, `stream` or `stream_options` twice, spelled with escapes or in another letter case (`"Model"`, `"STREAM"`; `include_usage` inside `stream_options` likewise), or a `stream` or `stream_options.include_usage` that is not `true`, `false` or `null`. See [Request heads, paths and queries](#request-heads-paths-and-queries). |
| 400 | `request_too_complex` | `invalid_request_error` | `invalid_request_error` | The request has to be parsed into a tree (to translate it for a provider of the other protocol, or to rewrite its `stream_options`) and is too costly for that: an object with more than 1,024 members, or far more values than its size suggests. The same body is accepted on a route that needs no such step. See [Limits on what one request and one key may hold](#limits-on-what-one-request-and-one-key-may-hold). |
| 400 | `too_many_redactions` | `invalid_request_error` | `invalid_request_error` | A request of a key that redacts ([privacy mode](privacy.md#redaction)) holds more than 16,384 distinct values to replace. It is refused rather than sent on with some of them in clear. |
| 400 | `endpoint_not_supported` | `invalid_request_error` | `invalid_request_error` | The route exists, but every one of its upstreams speaks the other protocol and this endpoint is not translated (only chat completions and messages are). Nothing was sent to a provider. |
| 400 | `untranslatable_request` | `invalid_request_error` | `invalid_request_error` | No target could be sent the request: it would have to be translated and uses something that cannot be (audio or file parts). Nothing was sent to a provider. |
| 401 | `missing_api_key` | `invalid_request_error` | `authentication_error` | No key was sent. |
| 401 | `invalid_api_key` | `invalid_request_error` | `authentication_error` | The key is not known: never configured, deleted, disabled, shadowed by a config-file key of the same name, or replaced by a rotation. |
| 402 | `budget_exceeded` | `insufficient_quota` | `billing_error` | The key has spent its budget for the current period and the request would start new work (a text request, or `POST /v1/jobs`). Reading is still allowed; see [below](#what-an-over-budget-key-can-still-do). |
| 403 | `model_not_allowed` | `permission_error` | `permission_error` | The key's `models` list does not include this model. |
| 404 | `not_found` | `invalid_request_error` | `not_found_error` | The path is not an endpoint the gateway serves. |
| 404 | `model_not_found` | `invalid_request_error` | `not_found_error` | No route has this name; or, on `GET /v1/models/{id}`, the model does not exist or the key may not use it. |
| 405 | `method_not_allowed` | `invalid_request_error` | `invalid_request_error` | A method other than GET or POST on `/v1/jobs*`, `/v1/files/*` or `/v1/payments*`. |
| 411 | `invalid_request` | `invalid_request_error` | (always the OpenAI shape) | A `POST`, `PUT` or `PATCH` without a `Content-Length`. A chunked request body (`Transfer-Encoding: chunked`) is not accepted and gets this answer too. |
| 413 | `payload_too_large` | `invalid_request_error` | `request_too_large` | The request body exceeds 8 MiB; for `POST /v1/jobs`, 8,000,000 bytes (the size the control plane's parser reads). A declared length over the limit is refused without reading any of the body. |
| 417 | `invalid_request` | `invalid_request_error` | (always the OpenAI shape) | An `Expect` header other than `100-continue`. |
| 429 | `concurrency_limit_exceeded` | `rate_limit_error` | `rate_limit_error` | The key already has its `max_concurrent`, or without one `OMNIGATE_MAX_CONCURRENT_PER_KEY` (512), requests in flight. Answered before the body is read, with `retry-after: 1`. |
| 429 | `request_memory_exceeded` | `rate_limit_error` | `rate_limit_error` | The requests the key has in flight are too large together (its share of `OMNIGATE_REQUEST_MEMORY_MB`), or it is converting as many large requests at once as it may (its share of `OMNIGATE_PARSE_MEMORY_MB`). With `retry-after: 1`. |
| 429 | `rate_limit_exceeded` | `rate_limit_error` | `rate_limit_error` | The key is over its `rpm`. The response has a `Retry-After` header in seconds. |
| 429 | `upstream_rate_limited` | `rate_limit_error` | `rate_limit_error` | No target succeeded and at least one answered 429. The error has `attempts`, and the response carries the longest `retry-after` any of the rate-limited targets sent. |
| 431 | none | | | The request head is larger than 16 KiB. The answer has no body. |
| 502 | `all_upstreams_failed` | `server_error` | `api_error` | Every target failed and none of them answered 429. The error has `attempts`. |
| 503 | `gateway_not_ready` | `server_error` | `api_error` | The data plane has no config yet (the control plane has never answered and there is no cached config). |
| 503 | `attestation_unverified` | `server_error` | `api_error` | No target could be sent the request because of [attestation](attestation.md): every target of the model is on an attested upstream whose evidence is not verified right now, or the request may only go to attested providers ([privacy mode](privacy.md#attested-providers-only)'s `attested`) and no target qualifies. Also the answer to `POST /v1/jobs` with `attested`. Nothing was sent to a provider. |
| 503 | `control_plane_unavailable` | `server_error` | `api_error` | A jobs, files, payments or receipt request could not reach the control plane. |
| 503 | `overloaded` | `server_error` | `overloaded_error` | Two cases, both with `retry-after: 1`. (1) The data plane is already serving `OMNIGATE_MAX_CONNECTIONS` connections: sent at once, without reading the request, with `connection: close`; because the request was not read, this answer is always in the OpenAI shape and has no request id. (2) The gateway as a whole is holding as many request bodies, or converting as many requests, as its memory budgets allow (`OMNIGATE_REQUEST_MEMORY_MB`, `OMNIGATE_PARSE_MEMORY_MB`): an ordinary answer for this one request, in the client's protocol, with a request id. |

The mapping is `typesFor` in `dataplane/src/errors.zig`. A reason that is
not in that function's table gets its category from the status alone: 401,
403, 404 and 429 as in the rows above, 400 and 405 to 428
`invalid_request_error`, anything else `server_error` / `api_error`. That
is how `concurrency_limit_exceeded`, `request_memory_exceeded` and
`request_too_complex` get theirs (the unit test there that lists the
reasons covers these three since the close-out commit).

### Provider errors

A provider's answer with a status of 400 or above that is not retried
(429 and 5xx fail over, see [below](#when-every-target-fails)) reaches the
client with the provider's status. What its body looks like:

- **Already the protocol's error envelope: passed on byte for byte.** For
  an OpenAI-style upstream that is an object with an `error` object that
  has a `message`; for an Anthropic-style one, `"type": "error"` with an
  `error` object that has a `type` and a `message`.
- **Anything else is put into that envelope** (since the close-out commit,
  the one after 55a294d; before, it was passed on as it came, and an SDK
  showed the raw text or could not read it). The message is the provider's
  own words, `code` is the provider's when it gave one, and the
  `content-type` becomes `application/json`. `type` follows the status: in
  the OpenAI shape 401 `authentication_error`, 403 `permission_error`, 404
  `not_found_error`, 429 `rate_limit_error`, 5xx `server_error`, anything
  else `invalid_request_error` (a `type` the provider put in its `error`
  object is kept instead); in the Anthropic shape the same names, with
  413 `request_too_large` and 5xx `api_error`. Real examples, both from "OpenAI-compatible"
  endpoints answering a bad provider key:

  | The provider sent | The client gets |
  |---|---|
  | `[{"error": {"code": 400, "message": "API key not valid. ...", "status": "INVALID_ARGUMENT"}}]` (Google: an array) | `{"error": {"message": "API key not valid. ...", "type": "invalid_request_error", "param": null, "code": "INVALID_ARGUMENT"}}` |
  | `{"code": "Client specified an invalid argument", "error": "Incorrect API key provided: ..."}` (xAI: `error` is a string) | `{"error": {"message": "Incorrect API key provided: ...", "type": "invalid_request_error", "param": null, "code": "Client specified an invalid argument"}}` |

  The message is looked for in `error.message`, `error` (a string),
  `message` and `detail`, in an object or in the first element of an
  array; a body with none of them, or one that is not JSON (a proxy's HTML
  page), becomes the message as text, and an empty or non-text body
  becomes `upstream returned HTTP <status>`. `code` is a string `code`,
  else a string `status`, else a numeric `code` in digits, else `null`
  (left out in the Anthropic shape).
- When the request was [translated](#translation), the error is converted
  to the client's protocol, as before, and reads the same shapes.
- Not covered: an error body over 64 KiB, or one sent as an event stream,
  is relayed as it comes.

`tools/sdk_compat.py` checks this with both SDKs against the mock
providers, which send the two bodies above; the bodies themselves were
seen from the real services, the wrapping has only met the mock.

**The jobs API has more reasons.** The ones above are raised by the data
plane. The control plane, which owns the jobs, adds `job_not_found`,
`idempotency_conflict` and the others [listed below](#job-errors), in the
same shape.

There is no 408. A client that takes longer than
`OMNIGATE_CLIENT_TIMEOUT_MS` to send its request, or leaves a keep-alive
connection idle that long, has its connection closed without a response.

### Request heads, paths and queries

The gateway is strict about the bytes of a request before it looks at what
the request asks for. Anything two HTTP implementations could read
differently is refused, because that disagreement is what request smuggling
is made of, and nothing a client sends is copied into a request of the
gateway's own unless it is plain. Ordinary requests, and the ones the
official SDKs send in `tools/sdk_compat.py`, are not expected to run into
these rules; a hand-built request, or a client with unusual header values,
can.

**The head.** Checked first, before the key. A refusal at this stage is
always in the OpenAI shape, has no request-id headers, is counted as a
[refused request](operations.md#refused-requests) under the key `-` and the
reason `invalid_request`, leaves no access-log line, and closes the
connection.

| Answer | When |
|---|---|
| `400 invalid_request` | A header line without a colon or with an empty name; a character in a header name that is not a token character; a control character in a header value; a bare CR or LF; a NUL byte; more than 100 header lines; a request line that is not `METHOD /path HTTP/1.x`; a request target that does not start with `/`, or contains a space, a control character or a byte outside ASCII; a `Content-Length` that is not a plain decimal number; two `Content-Length` headers with different values; `Content-Length` together with `Transfer-Encoding`; a `Transfer-Encoding` other than exactly `chunked`; a body (a length above 0, or chunked) on a method that has none, such as `GET`. |
| `411 invalid_request` | A method that carries a body (`POST`, `PUT`, `PATCH`) without a `Content-Length`, also when it says `Transfer-Encoding: chunked`: chunked request bodies are not accepted. (Until commit e4e30e4 they were.) |
| `417 invalid_request` | An `Expect` header other than `100-continue`. |
| `400` with no body | A head the HTTP parser itself rejects. |
| `431` with no body | A head larger than 16 KiB. |

**The path** must be in its one canonical form, on every endpoint except
`GET /healthz`: it starts with `/`, has no trailing slash, no empty segment
(`//`), no `.` or `..` segment, and every segment consists only of letters,
digits and `-` `.` `_` `~` `:` `@`. A percent sign is not in that set, so
**a percent-encoded path is refused**, as are a backslash and a `;`.
`/v1/jobs/` is not `/v1/jobs`: it answers `400`, where earlier commits
forwarded it as a job creation that the rate limit did not count.

**The query string** may be at most 2,048 characters of letters, digits and
`-` `.` `_` `~` `=` `&` `+` `,` `:`. A `%`, a `/`, a space or a quote
answers `400`. The signed file URLs the gateway hands out, and `limit=N` on
the job list, fit.

**Forwarded headers.** Three request headers are copied into requests the
gateway makes, and each must be plain or the request answers `400`:

| Header | Checked | Allowed |
|---|---|---|
| `anthropic-version` | Whenever present, on every endpoint | Up to 32 letters, digits, `-`, `.` and `_`. |
| `anthropic-beta` | Whenever present, on every endpoint | Up to 512 letters, digits, `-`, `.`, `_`, commas and spaces. |
| `Idempotency-Key` | On `/v1/jobs*` and `/v1/files/*` only, where it is used | 1 to 255 visible ASCII characters (`!` to `~`), no spaces. UUIDs, base64 (`+`, `/`, `=`) and separators such as `:` `|` `#` all fit. |

On every other endpoint an `Idempotency-Key` is neither forwarded nor
looked at, so the keys the official SDKs attach to their calls pass
whatever they contain. (Until commit e4e30e4 the header was checked on
every endpoint, against a narrower set: letters, digits, `-`, `.`, `_` and
`:`.)

**The body** of a text request is walked once, in place, before anything
else is done with it, and must stay inside these bounds:

| Bound | Answer |
|---|---|
| Arrays and objects nested at most 64 levels deep | `400 invalid_json` |
| At most 65,536 members in any one object | `400 invalid_request` |
| No object key longer than 8 KiB | `400 invalid_request` |
| `model`, `stream` and `stream_options` at most once each at the top level, spelled without escapes (`"mod\u0065l"` is refused) | `400 invalid_request` |

The last rule exists because the gateway acts on those three fields and
then, for a provider of the same protocol, forwards the client's own bytes
with only the model name replaced: the provider parses the body again, and
the two readings must not be able to differ. A job request body is checked
for nesting depth only; the control plane parses it.

JSON inside a tool call's `arguments` string that is nested deeper than 64
levels is not refused: in a translated request it is handled like arguments
that are not a JSON object, and travels on as a string instead of being
parsed.

### Limits on what one request and one key may hold

Before a request body is read, the data plane checks what the key already
has in flight. Each refusal is an ordinary answer in the client's protocol
with `retry-after: 1`, so an SDK backs off and tries again by itself:

| Limit | Default | Over it |
|---|---|---|
| Requests of one key in flight | the key's `max_concurrent`, else `OMNIGATE_MAX_CONCURRENT_PER_KEY`, 512 | `429 concurrency_limit_exceeded` |
| Request bodies of one key in flight, by declared length, each counted twice | a quarter of `OMNIGATE_REQUEST_MEMORY_MB` (256 MiB of 1,024) | `429 request_memory_exceeded` |
| Request bodies of all keys in flight | `OMNIGATE_REQUEST_MEMORY_MB`, 1,024 | `503 overloaded` |

They apply to every text endpoint and to every `POST` on the jobs API, and
come before the rate limit: a request refused here has not used up a
rate-limit token. A stream whose client has gone but whose upstream answer
is still being read for billing ([Streaming](#streaming)) keeps its place
until that is finished, so hanging up and coming back is not a way around
the cap.

A same-protocol request is forwarded without ever being parsed into a
tree. A tree is built only where one is needed: translation to the other
protocol, the response cache's key, the fixes for provider quirks, and
rewriting a `stream_options` the client sent without `include_usage`. Those
steps have limits of their own:

| Limit | Over it |
|---|---|
| At most 1,024 members in any one object of a body that is parsed into a tree | `400 request_too_complex` (for the response cache: the request is served, just not cached) |
| One tree may take 128 times its text plus 1 MiB, at most 96 MiB | `400 request_too_complex` |
| Trees one key has reserved at once: half of `OMNIGATE_PARSE_MEMORY_MB` | `429 request_memory_exceeded` |
| Trees reserved at once by all keys: `OMNIGATE_PARSE_MEMORY_MB`, 1,024 | `503 overloaded` |

An ordinary request is nowhere near these: measured on real request shapes
a translation needs 10 to 70 times its text. The 1,024-member bound is the
one a legitimate request could meet (a tool schema with more than 1,024
properties in one object, say), and only on a route that translates.

When the gateway answers before it has read a request's body (a bad key on
a `POST`, for example), the response says `connection: close`, and the
gateway reads and discards what the client is still sending for a short
time before it closes, so the client sees the answer rather than a reset
connection. The unread body is never parsed as a second request.

`tools/malformed_test.py` sends these cases, and a few hundred generated
variations, at a running gateway; see
[Operations](operations.md#hostile-input-testing).

### When every target fails

```json
{
  "error": {
    "message": "every target for this model failed",
    "type": "server_error",
    "param": null,
    "code": "all_upstreams_failed",
    "attempts": [
      {"upstream": "mock-flaky", "outcome": "http_503"},
      {"upstream": "mock-ok", "outcome": "ConnectionRefused"}
    ]
  }
}
```

`outcome` is `ok`, `http_<status>`, `unknown_upstream`, `protocol_mismatch`,
`untranslatable_request`, `stream_aborted`, or the name of the network error
(`UpstreamTimeout`, `ConnectionRefused` and so on).

The answer depends on whether **any target answered 429**:

- At least one did: the client gets `429 upstream_rate_limited`, so that an
  SDK backs off as it would at the provider. The response carries the
  longest `retry-after` that any of the rate-limited targets sent (a value
  in plain seconds wins over an HTTP date, which cannot be compared).
- None did (only 5xx answers, timeouts, connection errors): `502
  all_upstreams_failed`. If the last target that answered sent a
  `retry-after` header, the 502 carries it.

A route whose first target is rate limited and whose second target is down
therefore answers 429: a later target that was merely down does not make
the rate limit go away. (Until commit 10bc009 only the last target tried
decided, and that route answered 502.) On a metered endpoint both answers
are written to the ledger as a request with that status and no tokens.

**Provider errors are not rewritten.** When a provider answers with a status
that is not 429 or 5xx (a 400 for a bad parameter, a 401 for a bad provider
key), the gateway passes that status and body to the client. If the request
was translated, the error body is converted to the client's protocol. A 429
or 5xx from a provider triggers failover instead; the client sees the
outcome only when every target has failed, as described above.

The gateway checks a text request in this order: the request head, the
path, the query string and the forwarded headers
([above](#request-heads-paths-and-queries)), config present, key present
and known, budget, endpoint, the key's concurrency cap and the
request-memory budget, the rate limit, the declared body size, and only
then is the body read: nesting depth, JSON and its bounds, `model`, model
limits, route, and the response cache if the route has one.

**The rate limit is charged before the body is read.** A request that is
then refused for its size, its JSON, its model or the key's model list has
used up one request of the key's `rpm`. (Until commit e4e30e4 the body was
read first, so that a disallowed model cost nothing; the price was that a
key could make the gateway read and parse megabytes before any limit was
consulted.)

### What an over-budget key can still do

A key that has spent its budget may not start anything new, but keeps
access to what it already has:

| Request | Over budget |
|---|---|
| Text endpoints (`POST /v1/chat/completions` and the others) | `402 budget_exceeded` |
| `POST /v1/jobs` | `402 budget_exceeded` |
| `GET /v1/models` | allowed |
| `GET /v1/jobs`, `GET /v1/jobs/{id}` | allowed |
| `POST /v1/jobs/{id}/cancel` | allowed (cancelling only saves money) |
| `GET /v1/files/...` | allowed |
| `/v1/payments*` (where [payments](payments.md) are configured) | allowed: paying is how the key gets credit again |

## Text endpoints

| Method and path | Protocol | Translated to the other protocol | Metered |
|---|---|---|---|
| `POST /v1/chat/completions` | OpenAI | yes | yes |
| `POST /v1/messages` | Anthropic | yes | yes |
| `POST /v1/completions` | OpenAI | no | yes |
| `POST /v1/embeddings` | OpenAI | no | yes |
| `POST /v1/responses` | OpenAI | no | yes |
| `POST /v1/messages/count_tokens` | Anthropic | no | no |
| `GET /v1/models`, `GET /v1/models/{id}` | either, by the request's headers | | no |
| `GET /healthz` | | | no |

"Metered" means the call counts against the key's rate limit and is written
to the usage ledger. `count_tokens` does neither.

An endpoint that is not translated can only be served by an upstream of its
own protocol. On a route that has none (embeddings on a route whose targets
are all Anthropic-style, `count_tokens` on a route whose targets are all
OpenAI-style) the answer is `400 endpoint_not_supported`; earlier commits
answered 502 there.

### Request

The body is the provider's own format with one difference: `"model"` is the
name of a route in your config. The gateway replaces it with the target's
model id and forwards the rest unchanged (or translated, see below). The
body must be JSON and at most 8 MiB.

```bash
curl http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer og-unlimited-key" -d '{"model":"demo-chat","messages":[{"role":"user","content":"hi"}]}'
```

```bash
curl http://127.0.0.1:8080/v1/messages -H "x-api-key: og-unlimited-key" -d '{"model":"demo-claude","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}'
```

Request headers the gateway acts on:

| Header | Use |
|---|---|
| `Authorization` / `x-api-key` | The gateway key. Never forwarded. |
| `anthropic-version` | Forwarded to `anthropic` upstreams. Defaults to `2023-06-01` when absent. |
| `anthropic-beta` | Forwarded to `anthropic` upstreams. |
| `Idempotency-Key` | Jobs API only. |
| `x-omnigate-privacy` | Switches parts of [privacy mode](privacy.md#the-request-header) on for this one request: `on` (`no-store`, `redact` and `unlink`), or a comma-separated list of `no-store`, `redact`, `unlink`, `attested`. It can only add to the key's setting; any other value, or the header sent twice, answers `400 invalid_request`. Never forwarded. |
| `x-omnigate-dry-run` | `privacy`: answer with the request as privacy mode left it (`{"object": "omnigate.privacy_dry_run", "sent_upstream": false, "body": "...", ...}`) and send nothing to any provider. Any other value, or the header twice, answers `400 invalid_request`. See [Seeing what a provider would be sent](attestation.md#seeing-what-a-provider-would-be-sent). Never forwarded. |
| `x-omnigate-tag` | The caller's own label for the request (a tenant, a run, an end user's id in its system): 1 to 64 letters, digits, `.`, `_`, `:` or `-`. Recorded with the request's usage and shown in the [usage feed](building-on-omnigate.md#reading-usage); never sent to a provider, in no metric. Also taken on `POST /v1/jobs`. Anything else, or the header sent twice, is `400 invalid_request`. |

Other request headers are not forwarded to the provider. The values of
the first three are restricted to plain characters; see
[Request heads, paths and queries](#request-heads-paths-and-queries). A
request body needs a `Content-Length`: chunked request bodies answer `411`.

### Response

The provider's response, with these headers added:

| Header | Meaning |
|---|---|
| `x-omnigate-upstream` | Name of the upstream that answered. |
| `x-omnigate-attempts` | How many upstreams the request was sent to, this one included. |
| `x-omnigate-request-id` | Id of this request (32 hex characters); also the id of its usage event in the ledger. |
| `x-request-id`, `request-id` | The request id where the OpenAI and the Anthropic SDK look for it. The provider's own id is preferred, so that a support ticket can quote it: when the provider sent both headers each keeps its value, when it sent only one of them that id goes into both, and when it sent neither both carry the gateway's id (the value of `x-omnigate-request-id`). |
| `x-omnigate-cache` | Only on routes with `cache_ttl_s`, for non-streaming requests: `hit` or `miss`. See [Response cache](#response-cache). |
| `x-omnigate-privacy` | Only when a part of [privacy mode](privacy.md) applied to the request (from the key or from the request header): the parts, in the order `no-store, redact, unlink`. (`attested` is not listed here; the next header answers it.) |
| `x-omnigate-attestation` | Only when the upstream that answered is an [attested upstream](attestation.md): `verified; tcb=<platform status>; since=<unix seconds>`. It says the provider's attestation was verified, and recently, when the request was sent; it is not a signature over this response. |

**Request ids are on every answer the gateway produces, with three
exceptions**: provider responses, the gateway's own errors, the model
endpoints, cache hits, and the jobs and files API all have them. On those
that involve no provider, all three headers carry the gateway's id. The
exceptions are `GET /healthz`, the `503 overloaded` that is sent without
reading the request, and a request whose head was refused (the `400`,
`411`, `417` and `431` of
[Request heads, paths and queries](#request-heads-paths-and-queries)).

A `429 upstream_rate_limited` or `502 all_upstreams_failed` carries the
three id headers, and `retry-after` when an upstream sent one
([When every target fails](#when-every-target-fails) says whose).

**Framing.** The gateway reads a provider's response body with its own
bounded reader and frames its answer to the client itself; a length the
provider declared is never passed on.

- An answer that is not an event stream and is at most 64 KiB is read to
  its end, then sent in one piece with a `content-length` the gateway
  counted. If the provider cuts it short, or sends its head and then
  nothing for `OMNIGATE_STREAM_IDLE_TIMEOUT_MS`, nothing has been sent
  yet, and the request fails over like any other failed attempt
  (`UpstreamTruncated`, `StreamIdleTimeout`).
- An event stream, and any longer answer, is sent with
  `transfer-encoding: chunked` as it arrives. If the provider breaks off
  part way, or sends a body shorter than the length it declared, the
  gateway **drops the client's connection without the closing chunk**. An
  HTTP client reports that as an incomplete or broken response, which is
  what it was. The call is recorded with status 499.
- A provider response whose head is ambiguous about its length (both a
  length and chunked encoding, two different lengths, a transfer coding
  other than `chunked`) or whose chunk sizes do not parse is treated as a
  failed attempt (`UpstreamUnparseable`), and the next target is tried.

**Provider headers.** The provider's `content-type` is kept (a value with
a control byte in it, or longer than 256 bytes, fails the attempt), and the
gateway sets `cache-control: no-cache`. Beyond that, a fixed allowlist of
provider response headers is passed to the client under their original
names:

| Passed on | Examples |
|---|---|
| `retry-after`, `retry-after-ms`, `x-should-retry` | How long to wait before retrying. |
| `x-request-id`, `request-id` | The provider's request id, for support tickets. When the provider sends none, the gateway fills in its own (see above). |
| `openai-processing-ms`, `openai-version` | |
| every header starting with `x-ratelimit-` | `x-ratelimit-remaining-requests`, `x-ratelimit-reset-tokens` |
| every header starting with `anthropic-ratelimit-` | `anthropic-ratelimit-tokens-remaining` |

- Names are matched without regard to case. Everything else is dropped:
  connection and framing headers, cookies, the provider's organization and
  project headers, CDN headers.
- A translated response keeps the upstream's names: a client that asked in
  the OpenAI format and was served by an Anthropic upstream gets
  `anthropic-ratelimit-*` headers, not `x-ratelimit-*`.
- At most 32 headers are passed per response, and a header with an empty
  value or a value longer than 512 bytes is dropped.
- These headers describe the provider's limits for **your provider key**,
  shared by every gateway key that uses the upstream. They are not the
  gateway key's own `rpm` limit.

The allowlist is covered by unit tests, and the SDK suite checks the
request-id headers and `retry-after` end to end against the mock providers.
The rate-limit headers are not exercised end to end, and none of this has
been checked against a real provider.

### Streaming

Set `"stream": true` as the provider's protocol defines. Chunks are flushed
to the client as they arrive.

For `/v1/chat/completions` and `/v1/completions`, OpenAI-style providers
report token usage on a stream only when asked. If the client did not set
`stream_options.include_usage`, the gateway sets it to meter the call and
removes the extra usage chunk from what the client receives.

Failover happens only before the first byte of a response reaches the
client. If a stream breaks after that, the client's connection is dropped
(without the closing chunk, see [Framing](#response)) and the call is
recorded with status 499 in the ledger.

Two timeouts watch a response in progress:

- **The upstream goes silent.** When it sends nothing for
  `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` (five minutes by default), the gateway
  closes both sides and records the call with status 499.
- **The client stops reading.** When a client stays connected but takes
  none of a relayed response for `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` (30
  seconds by default), the gateway gives up on it. From then on it is
  handled like a client that hung up.

**A response that ends early is still billed.** Hanging up on a stream does
not make it free: the provider charges for what it generated.

- When the client disconnects or stalls, the client's connection is
  finished with, and the gateway **keeps reading the upstream in the
  background**: until the provider's closing usage figures, or the end of
  the answer, or for at most `OMNIGATE_ABORT_DRAIN_MS` (two minutes by
  default) and `OMNIGATE_ABORT_DRAIN_MAX_MB` (64) more megabytes. If the
  figures arrive, the call is billed exactly those. Only then is the
  upstream connection closed, which is what makes a provider stop
  generating.
- Whenever a response on a metered endpoint ends without those closing
  figures (they did not arrive within those bounds, the upstream went
  silent or broke off, more than 256 such answers were already being read
  on, or the gateway was stopped), the call is billed an **estimate**, and
  its usage event is marked `"estimated": true`. The estimate is never
  below what was actually metered.
- The same goes for an event stream that reaches its proper end without
  the provider ever reporting usage: some OpenAI-compatible servers ignore
  `stream_options.include_usage`. Such a call is billed the estimate, not
  nothing.
  - Input that was not reported is taken as the request body's size in
    bytes divided by 4, plus 1,600 tokens for every image, document, file
    or audio part the request names.
  - Output that was not reported is, for an event stream, the larger of
    one token per event received and the generated text received (the
    string values of `content`, `text`, `delta`, `arguments`,
    `partial_json`, `thinking`, `reasoning_content`, `reasoning` and
    `refusal`) divided by 4; for anything else, the response's bytes
    divided by 4.
- The estimate errs on the high side for the request and is rough for the
  response. It exists so that an abandoned stream costs something close to
  what the provider charged, not so that the two agree.

How to see which calls were estimated is in
[Operations](operations.md#streams-that-end-early).

### Response cache

A route with `cache_ttl_s` answers repeated identical requests from the data
plane's memory; see [Configuration](configuration.md#response-cache) for
what "identical" means and what bounds the cache. From the client's side:

- Only non-streaming requests take part. The first one is forwarded and
  comes back with `x-omnigate-cache: miss` next to the usual headers.
- A repeat within the TTL, from the same gateway key, comes back with the
  stored status, `content-type` and body, and these headers only:
  `x-omnigate-cache: hit` and a new request id (in `x-omnigate-request-id`,
  `x-request-id` and `request-id`). There is no `x-omnigate-upstream` or
  `x-omnigate-attempts`, because no upstream was called, and no provider
  headers.
- A hit is byte for byte the stored answer, including the provider's
  response id and token usage figures from the original call. The gateway
  bills it as zero tokens and zero cost.
- Only complete 2xx answers are stored. Errors are never cached.
- Translated answers are cached too, in the client's protocol.
- A request under [privacy mode](privacy.md)'s `no_store` or `redact` (from
  the key or from `x-omnigate-privacy`) takes no part: it is neither
  answered from the cache nor stored in it, and carries no
  `x-omnigate-cache` header.

```bash
curl -i http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer <gateway key>" -d '{"model":"<a route with cache_ttl_s>","messages":[{"role":"user","content":"hi"}]}'
```

(The dev config has no cached text route; add `"cache_ttl_s": 60` to one of
its routes to try this.)

### Translation

`/v1/chat/completions` and `/v1/messages` can be served by an upstream of the
other protocol, including streaming, tools and images. The response carries
the route name in `model`, in the client's protocol.

- Fields with no equivalent on the other side are dropped, not rejected:
  thinking blocks, cache control, penalties, log probabilities and similar.
- **Structured output is translated.**
  - OpenAI client, Anthropic-style upstream: `response_format` of type
    `json_schema` becomes `output_config.format` with the same schema (the
    OpenAI-only `name` and `strict` are dropped). `{"type": "json_object"}`
    has no Anthropic parameter, so it becomes one sentence appended to the
    system prompt asking for a single JSON object and nothing else.
  - Anthropic client, OpenAI-style upstream: `output_config.format` of type
    `json_schema` becomes `response_format` with the schema under the name
    `response` and `"strict": true`. Other members of `output_config` are
    dropped.
  - Both directions are covered by unit tests and by the SDK suite against
    the mock providers. **The Anthropic side has not been verified against
    the live Anthropic API**: neither that `output_config.format` is
    accepted as the gateway sends it, nor how the OpenAI side treats a
    schema written for Anthropic under `strict`.
- Audio and file parts cannot be translated. A target that would need them
  is skipped with the outcome `untranslatable_request`; if no target is
  left that could be sent the request, the answer is
  `400 untranslatable_request`.
- When a translated request is refused because the model rejects
  `temperature`, `top_p` or `top_k`, the gateway retries without them and
  remembers that for the model, for the gateway key that ran into it (not
  for other keys, so one client cannot change how another's requests are
  sent). The same applies to models that demand a thought signature on
  earlier tool calls (Gemini 3 and later). Requests in the provider's own
  protocol are not touched and get the provider's error
  ([Provider errors](#provider-errors)).

The README lists what has not been verified against real providers here:
images in translated requests, long conversations, large payloads and
structured output. The checks against real providers used plain HTTP;
`tools/sdk_compat.py` drives the official SDKs through the gateway in both
translation directions, against the mock providers only. See
[Using the official SDKs](#using-the-official-sdks).

### `GET /v1/models` and `GET /v1/models/{id}`

`GET /v1/models` lists the routes the key may use: the text routes first,
then the media routes (the models of the [jobs API](#jobs-api)). A key with
a `models` list sees only the names on it. The list does not say which kind
a model is, or which protocol its upstreams speak; a media model is used
with `POST /v1/jobs`, not with the text endpoints. A key over its budget
can still call both endpoints.

The answer has the shape of the client's protocol. By default that is
OpenAI's:

```json
{
  "object": "list",
  "data": [
    {"id": "demo-chat", "object": "model", "created": 1794312000, "owned_by": "omnigate"},
    {"id": "demo-claude", "object": "model", "created": 1794312000, "owned_by": "omnigate"},
    {"id": "demo-image", "object": "model", "created": 1794312000, "owned_by": "omnigate"}
  ]
}
```

A request that carries an `anthropic-version` header (the Anthropic SDK
always sends one) gets Anthropic's:

```json
{
  "data": [
    {"type": "model", "id": "demo-chat", "display_name": "demo-chat", "created_at": "2026-11-10T12:00:00Z"},
    {"type": "model", "id": "demo-claude", "display_name": "demo-claude", "created_at": "2026-11-10T12:00:00Z"},
    {"type": "model", "id": "demo-image", "display_name": "demo-image", "created_at": "2026-11-10T12:00:00Z"}
  ],
  "has_more": false,
  "first_id": "demo-chat",
  "last_id": "demo-image"
}
```

(Shortened: the dev config has more routes. The times are made up.)

- A gateway model is a route, not a provider model, so it has no real
  creation date: `created` / `created_at` is the time this data-plane
  process started, the same for every model. `display_name` repeats the id.
- The list is never paged. `has_more` is always `false`, and query
  parameters such as `limit` or `after_id` are ignored.
- `GET /v1/models/{id}` returns one object of the list. A model that does
  not exist and a model the key may not use get the same answer,
  `404 model_not_found`, so the reply does not reveal which other models
  exist. Errors from both endpoints are in the same protocol's shape as the
  list would have been.
- The id is part of the path, so it falls under the
  [path rule](#request-heads-paths-and-queries): a route whose name has a
  character outside letters, digits and `-` `.` `_` `~` `:` `@` (a space or
  a `+`, say) is listed and can be used in a request body, but
  `GET /v1/models/{id}` answers `400 invalid_request` for it. A `/` in a
  name is fine.

### `GET /healthz`

Answers `200` with the body `ok` and needs no key. It says the process is
up; it does not say that a config has been loaded.

## Using the official SDKs

The OpenAI and Anthropic SDKs work against the gateway by changing two
things: the base URL and the API key (a **gateway key**, not a provider
key). `"model"` is a route name from your config.

`tools/sdk_compat.py` runs the official Python SDKs through the gateway
against the mock providers: both SDKs against both kinds of upstream, sync
and async, streaming and not, tools, embeddings, the Responses API, the
exception classes each SDK raises, and the details an SDK user would notice
if the gateway differed from the real APIs (request ids, error codes and
envelopes, the model endpoints, a provider's 429, structured output through
translation). It is the basis for this section. Every case must pass; there
is no list of tolerated gaps any more. It has not been run against real
providers, and only the Python SDKs are covered.

The suite was written against `openai` 3.49.0 and `anthropic` 2.8.0, which
is what CI installs (`.github/workflows/ci.yml` pins them). The snippets
below use the quickstart's key and routes. Install the SDKs yourself
(`pip install openai anthropic`); the repository does not depend on them.

**OpenAI SDK.** The base URL ends in `/v1`:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="og-unlimited-key")

reply = client.chat.completions.create(
    model="demo-chat",
    messages=[{"role": "user", "content": "hi"}],
)
print(reply.choices[0].message.content)
```

**Anthropic SDK.** The base URL is the gateway's address without `/v1`
(the SDK adds `/v1/messages` itself):

```python
from anthropic import Anthropic

client = Anthropic(base_url="http://127.0.0.1:8080", api_key="og-unlimited-key")

message = client.messages.create(
    model="demo-claude",
    max_tokens=64,
    messages=[{"role": "user", "content": "hi"}],
)
print(message.content[0].text)
```

Either SDK can use either kind of route: `model="demo-claude"` with the
OpenAI SDK, or `model="demo-direct"` with the Anthropic SDK, goes through
[translation](#translation).

Things to know:

- **Environment variables.** Both SDKs read `OPENAI_*` / `ANTHROPIC_*`
  variables (API key, base URL) when an argument is not given. Pass
  `base_url` and `api_key` explicitly, or make sure your shell does not hold
  a provider key that would be sent to the gateway instead.
- **Either header works.** The Anthropic SDK sends the key as `x-api-key`;
  built with `auth_token=` instead of `api_key=` it sends
  `Authorization: Bearer`, which the gateway accepts as well.
- **Retries.** The SDKs retry 429 and 5xx answers by themselves. The
  gateway's own `429 rate_limit_exceeded` carries `Retry-After`, and so
  does a provider's 429 that reaches the client as
  `429 upstream_rate_limited` when the provider sent one. Set
  `max_retries=0` on the client if you want to see such answers instead of
  waiting through them.
- **Errors.** Gateway errors arrive as the SDK's usual classes by status:
  400 `BadRequestError`, 401 `AuthenticationError`, 403
  `PermissionDeniedError`, 404 `NotFoundError`, 429 `RateLimitError`, 502
  `InternalServerError`. With the OpenAI SDK, `exc.code` is the gateway's
  reason (`model_not_found`, `rate_limit_exceeded`, ...) and `exc.type` the
  category. With the Anthropic SDK, `exc.type` is Anthropic's category
  (`not_found_error`, `rate_limit_error`, ...) and the reason is
  `exc.body["error"]["code"]`. See [Errors](#errors).
- **Request ids.** `_request_id` on a response and `request_id` on an
  exception are set: to the provider's id when the provider sent one, to
  the gateway's otherwise.
- **Models.** `models.list()` and `models.retrieve(id)` work in each SDK's
  own shape.
- **Structured output.** With the OpenAI SDK, `response_format` with a JSON
  schema, and `chat.completions.parse()` with a pydantic model, work on a
  route served by an Anthropic-style upstream; with the Anthropic SDK,
  `output_config.format` works on a route served by an OpenAI-style
  upstream. Against the mocks only; see [Translation](#translation).
- **Gateway headers.** `with_raw_response` exposes `x-omnigate-request-id`,
  `x-omnigate-upstream` and `x-omnigate-attempts`.

Differences from the real APIs that an SDK user can still see:

| Where | What differs |
|---|---|
| `created` / `created_at` of a model | The time the gateway process started, the same for every model. |
| `display_name` of a model (Anthropic SDK) | The route name. |
| Paging of `models.list()` | There is one page; paging parameters are ignored. |
| The error body on Anthropic-style endpoints | `error` has one member more than `type` and `message`: `code`, the gateway's reason. |
| Endpoints the gateway does not serve (files, batches, audio, images and so on) | `404 not_found`. Media goes through the [jobs API](#jobs-api), which the SDKs do not know. |
| Request paths, query strings and JSON bodies | Stricter than the providers: no percent-encoding, a small character set, at most 64 levels of nesting, bounded object sizes, no duplicate `model` ([above](#request-heads-paths-and-queries)). Neither SDK sends anything else in the cases the suite covers. |
| Request bodies | Must carry a `Content-Length`; a chunked request body answers `411`. Both SDKs send a length for JSON bodies. |
| A response cut short by the provider | The connection is dropped mid-body instead of ending cleanly; the SDKs raise a connection error. |
| Load refusals | `429 concurrency_limit_exceeded`, `429 request_memory_exceeded` and `503 overloaded` carry `retry-after: 1`; the SDKs retry them like any 429 or 503. |

## Jobs API

One async API in front of image, video and speech providers. The data plane
authenticates the key and hands these requests to the control plane, so they
need the control plane to be reachable.

```
POST /v1/jobs                 create a job
GET  /v1/jobs/{id}            fetch one job
GET  /v1/jobs?limit=N         this key's jobs, newest first
POST /v1/jobs/{id}/cancel     cancel a job
```

Only `POST /v1/jobs` counts against the key's rate limit (listing has an
allowance of its own, below). A key sees only its own jobs; another key's
job id answers 404. A managed key keeps its jobs when its secret is rotated
([Admin](admin.md#rotate)).

Creating jobs is limited in these ways:

- **The data plane's limits for any request with a body.** The key's
  concurrency cap and the request-memory budget
  ([above](#limits-on-what-one-request-and-one-key-may-hold)) apply to
  every `POST` on the jobs API.
- **The key's `rpm`, twice.** The data plane charges its token bucket, as
  for a text request. The control plane then counts the creation again by
  itself, with the same token bucket (a burst of up to `rpm`, refilled at
  `rpm` per minute), so that the limit on work that costs money does not
  depend on the data plane recognising the request. Either can answer
  `429 rate_limit_exceeded`. A request that repeats an `Idempotency-Key`
  the key already used creates nothing and is not counted by the control
  plane (the data plane still counts it).
- **Unfinished jobs per key.** A key may have at most `max_open_jobs` jobs
  that are queued or running (100 unless the key or `media.max_open_jobs`
  says otherwise; `0` means no limit). One more answers
  `429 too_many_open_jobs`. A job that was canceled while its provider call
  was in flight counts until that call is over
  ([Cancel a job](#cancel-a-job)). Jobs made under the key's earlier secrets count
  too, and a replay by `Idempotency-Key` is never refused for this.
- **Jobs per day per key.** A key may create at most `max_jobs_per_day`
  jobs per UTC day (10,000 unless the key or `media.max_jobs_per_day` says
  otherwise; `0` means no limit), whatever became of them. One more answers
  `429 too_many_jobs_today`; the count starts again at midnight UTC, and
  `Retry-After` counts down to it. Jobs made under the key's earlier
  secrets count too.
- **Size.** `input` and `metadata` together may be at most
  `media.max_input_bytes` (1 MiB by default) as JSON, and `metadata` alone
  at most 16 KiB; more answers `413 payload_too_large`. A `webhook_url`
  may be at most 2,048 bytes.
- **What the route accepts.** A route can list the `input` fields it
  takes (`allowed_input`), the values a field may have
  (`price_multipliers`) and a longest duration (`max_seconds`); see
  [Create a job](#create-a-job).

**Listing is rate-limited too.** `GET /v1/jobs` has a bucket of its own in
the control plane, so listing never uses up the allowance for creating
jobs: the key's `rpm` when it has one, 600 per minute otherwise. Over it
the answer is `429 rate_limit_exceeded` ("this key is listing jobs too
often"). Fetching one job by id is not limited.

Every one of these 429 answers carries `Retry-After`: the data plane's own,
and the control plane's, which the data plane passes on: the seconds until
the next request fits for the rate limits; 10 for `too_many_open_jobs`;
and for `too_many_jobs_today` the seconds until midnight UTC, when the
count starts again, but at most 3,600 (until the close-out commit it was
10 there as well).

A key over its budget cannot create a job (`402 budget_exceeded`) but can
still fetch, list and cancel its jobs and download their files.

### Create a job

Request body:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `model` | string | yes | Name of a media route. |
| `input` | object | yes | Passed to the provider adapter. What goes in it depends on the adapter; see [Providers](providers.md#media-providers). |
| `webhook_url` | string | no | Where to POST the result; at most 2,048 bytes. See [Webhooks](#webhooks). |
| `metadata` | object | no | Stored with the job and returned unchanged. At most 16 KiB as JSON. A list of jobs leaves out metadata over 1 KiB (`"metadata": null, "metadata_omitted": true`); the job itself always shows it. |
| `cache` | boolean | no | `true` allows reuse of a stored output; `false` forbids it. See [Caching](#caching). |

Optional headers: `Idempotency-Key` (1 to 255 visible ASCII characters,
without spaces), and `x-omnigate-privacy: no-store` (or `on`), which makes
this one job private: its `input` and `metadata` are kept out of the job log
and erased when the job ends, and its outputs are deleted a day later
([Privacy mode](privacy.md#no-retention)). Every job of a key whose privacy
mode has `no_store` is private without the header.

Some members of `input` are checked whatever the adapter, because they feed
the price. Anything else than what this list allows answers
`400 invalid_request`:

- `duration` and `seconds` must be a number of seconds, 0 or more: a
  number, a string that is one, or a number followed by `s` (`5`, `"5"`,
  `"5s"`).
- `n`, `num_outputs` and `num_images` must be a whole number of 0 or more.
- **On a route priced per second**, a job must name a duration above 0
  unless the operator configured a default for the route's targets
  (`default_seconds`), and may not ask for more than a target's
  `max_seconds`.
- **On a route with `allowed_input`**, `input` may only have the listed
  fields. The error names the fields that are not allowed and the ones
  that are.
- **On a route with `price_multipliers`**, a field that has factors may
  only carry one of the listed values. The error lists them.
- **On a route whose price has `variants`**, the request must be one of
  the priced combinations (a resolution, with or without audio, and so
  on). The error names the fields and lists the combinations that have a
  price.

The last four are the operator's settings
([Configuration](configuration.md#mediaroutes)); a route that sets none of
them accepts what it accepted before.

```bash
curl -i http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer og-unlimited-key" -H "Idempotency-Key: order-A-17" -d '{"model":"demo-image","input":{"prompt":"a lighthouse at dusk"},"metadata":{"order":"A-17"}}'
```

Response, `202 Accepted`:

```json
{
  "object": "job",
  "id": "job_5f0c2a9e4b7d81c3a6e2f490",
  "status": "queued",
  "model": "demo-image",
  "input": {"prompt": "a lighthouse at dusk"},
  "metadata": {"order": "A-17"},
  "outputs": [],
  "error": null,
  "cost_usd": 0.0,
  "cached": false,
  "upstream": null,
  "target_model": null,
  "attempts": [],
  "webhook": null,
  "created_at": "2026-11-10T12:00:00.000Z",
  "updated_at": "2026-11-10T12:00:00.000Z",
  "started_at": null,
  "finished_at": null
}
```

(The id and times in these examples are made up, as are the file size and the numbers in later examples; the shape is what the code returns.)

### Fetch a job

```bash
curl http://127.0.0.1:8080/v1/jobs/job_5f0c2a9e4b7d81c3a6e2f490 -H "Authorization: Bearer og-unlimited-key"
```

A finished job on the dev config, where the first target fails and the
second delivers:

```json
{
  "object": "job",
  "id": "job_5f0c2a9e4b7d81c3a6e2f490",
  "status": "succeeded",
  "model": "demo-image",
  "input": {"prompt": "a lighthouse at dusk"},
  "metadata": {"order": "A-17"},
  "outputs": [
    {
      "url": "http://127.0.0.1:8080/v1/files/job_5f0c2a9e4b7d81c3a6e2f490/out-0.png?exp=1794315603&sig=<hex>",
      "content_type": "image/png",
      "bytes": 68,
      "sha256": "<hex sha-256 of the file>"
    }
  ],
  "error": null,
  "cost_usd": 0.003,
  "cached": false,
  "upstream": "mock-replicate",
  "target_model": "mock/image",
  "attempts": [
    {"upstream": "mock-replicate-broken", "outcome": "provider_failed: <the provider's reason>"},
    {"upstream": "mock-replicate", "outcome": "ok"}
  ],
  "webhook": null,
  "created_at": "2026-11-10T12:00:00.000Z",
  "updated_at": "2026-11-10T12:00:03.412Z",
  "started_at": "2026-11-10T12:00:00.004Z",
  "finished_at": "2026-11-10T12:00:03.410Z"
}
```

Fields:

| Field | Meaning |
|---|---|
| `status` | `queued`, `running`, `succeeded`, `failed` or `canceled`. The last three are final. |
| `outputs[]` | One entry per stored file: `url`, `content_type`, `bytes`, `sha256`. The URL is generated fresh on every fetch. For a key with [`encrypt_to`](privacy.md#encrypted-outputs) the file is an age file: `content_type` is `application/octet-stream`, `bytes` and `sha256` describe the encrypted file, and the entry also has `"encryption": "age"`, `plaintext_content_type`, `plaintext_bytes` and `plaintext_sha256`; the file name ends in `.age`. |
| `private` | Present and `true` for a private job ([privacy mode](privacy.md#no-retention)). |
| `input_erased` | Present and `true` once a private job has ended: `input` and `metadata` are then `null`, here, in lists and in the webhook. |
| `outputs_expired` | Present and `true` once a private job's outputs have been deleted (`retention.private_outputs_hours` after it finished); `outputs` is then empty. |
| `error` | `null`, or `{"type", "message"}` for a failed job. |
| `cost_usd` | The configured price of the target that delivered, applied to what its adapter sent to the provider ([Configuration](configuration.md#mediaroutes)). `0` until the job succeeds, and for failed and cached jobs. A canceled job costs `0` unless the provider completed the call all the same ([Cancel a job](#cancel-a-job)). |
| `cached` | `true` when the outputs were reused from an earlier identical job. |
| `upstream`, `target_model` | Which target delivered. |
| `attempts[]` | Each target tried, with its `outcome` (`ok`, `cache_hit`, `timeout`, `no_outputs`, or the reason it failed). For a private job the reason is cut down to its kind (`http_400`, `provider_failed`): a provider's own words can quote the request. |
| `webhook` | `null`, or the delivery state: `url`, `status`, `attempts`, `last_status`, `last_error`, `next_attempt_at`, `delivered_at`. |

`error.type` of a failed job:

| Type | Meaning |
|---|---|
| `all_targets_failed` | Every target of the route failed; `attempts` says why. |
| `storage_error` | A provider produced outputs but they could not be stored. No other target is tried. |
| `route_removed` | The route was removed from the config while the job was unfinished. |
| `internal_error` | The gateway failed while running the job. |

### List jobs

```bash
curl "http://127.0.0.1:8080/v1/jobs?limit=5" -H "Authorization: Bearer og-unlimited-key"
```

```json
{"object": "list", "data": [ { "object": "job", "id": "job_..." } ]}
```

`limit` is between 1 and 100 and defaults to 20. Jobs are ordered newest
first.

A list leaves large inputs out: a job whose `input` is over 8 KiB as JSON
is listed with `"input": null` and `"input_omitted": true`. Fetch the job
by its id to get the input. (One response can therefore not be made of a
hundred megabyte-sized inputs.) Listing is rate-limited; see
[above](#jobs-api).

### Cancel a job

```bash
curl -X POST http://127.0.0.1:8080/v1/jobs/job_5f0c2a9e4b7d81c3a6e2f490/cancel -H "Authorization: Bearer og-unlimited-key"
```

Returns the job. An unfinished job becomes `canceled` at once; a job that
had already finished is returned unchanged. The README notes that
cancellation at a real provider has not been verified.

Whether a canceled job costs anything depends on what the provider did:

| When the cancel arrives | What happens | `cost_usd` |
|---|---|---|
| Before any provider was asked (the job was `queued`, or between two targets) | Nothing more | `0` |
| The provider has the job and can be told to stop (Replicate-style, fal-style; Sume while the job is still queued there) | It is told, and asked once more how the job ended | `0`, or the route's price if it had already finished |
| The provider cannot be told to stop (xAI video, Gemini's Interactions API; Sume once generation has started), or answers a request with the result (images, speech) | The call runs on at the provider; the gateway waits for its end (at most the route's `timeout_s`), fetches nothing and keeps nothing | The route's price if the call completed; `0` if it failed or timed out |
| While the outputs are being fetched and stored | What was stored is deleted | The route's price |

Until that is known the job, though `canceled`, has `cost_usd` `0`, still
counts towards the key's `max_open_jobs`, and its webhook is held back;
the webhook is sent with the final cost. In the ledger a canceled job has
status 499, and its attempts end with `completed_after_cancel` when it was
billed. Canceling is therefore not a way to have a provider work for
nothing.

### Idempotency

With an `Idempotency-Key` header, a second `POST /v1/jobs` from the same
gateway key with the same key value returns the existing job with status
`200` instead of creating another. If the body differs (`model`, `input`,
`metadata`, `webhook_url` or `cache`), the answer is `409`
`idempotency_conflict`.

Idempotency keys are remembered for as long as the job is. If
[retention](operations.md#retention) removes the job, the key can be used
again.

### Caching

A job may reuse the stored outputs of an earlier, identical, successful job
instead of calling a provider. "Identical" means the same route name and the
same `input` (key order does not matter).

- A request with `"cache": true` allows reuse on any route.
- A route with `cache_ttl_s` allows reuse by default, for outputs at most
  that many seconds old. A request with `"cache": false` opts out.
- With `"cache": true` on a route that has no `cache_ttl_s`, a stored output
  of any age can be reused.

A cache hit answers `202` like any other create, but the job is already
`succeeded`, with `"cached": true`, `"cost_usd": 0.0` and one attempt whose
outcome is `cache_hit`.

From the README: the cache is shared across gateway keys, and two identical
cacheable jobs submitted at the same moment both run.

Two kinds of job stay out of it, in both directions: a private job
([privacy mode](privacy.md#no-retention), `no_store`), and a job of a key
with `encrypt_to`, whose stored output only that key's owner can read.
`"cache": true` changes nothing for them.

### Job errors

In addition to the [general errors](#errors), which the data plane raises,
the control plane raises the ones below. They have the same OpenAI-style
shape, with the reason in `error.code` (see [Shape](#shape)), and the same
`x-request-id` as any other answer. `budget_exceeded`,
`rate_limit_exceeded`, `invalid_request`, `invalid_json` and
`payload_too_large` can come from either side; for jobs,
`model_not_allowed` and `model_not_found` come from the control plane.

| Status | `error.code` | When |
|---|---|---|
| 400 | `missing_model` | `"model"` is not a string. |
| 400 | `invalid_json` | The body is not valid JSON. |
| 400 | `invalid_request` | `input` is missing or not an object; `metadata` is not an object; `input.duration` or `input.seconds` is negative or not a duration; `input.n`, `input.num_outputs` or `input.num_images` is not a whole number of 0 or more; the route is priced per second and the job names no duration (and the route has no default), or more than the route's `max_seconds`; `input` has a field the route's `allowed_input` does not list, or a value the route's `price_multipliers` do not list, or is a combination the route's price `variants` do not cover; the `Idempotency-Key` is empty, longer than 255 bytes or not printable text; or the request path contains a percent-encoded character (job ids and file names never need one). The data plane refuses most odd paths and idempotency keys before the control plane sees them. |
| 401 | `invalid_api_key` | The control plane no longer knows the key the data plane accepted: it was deleted, disabled or rotated within the last poll interval. |
| 413 | `payload_too_large` | `input` and `metadata` together are larger than `media.max_input_bytes` (1 MiB by default); `metadata` alone is larger than 16 KiB; or the whole body is larger than 8,000,000 bytes, the limit of the control plane's JSON parser, which the data plane applies to job requests itself so that both give the same answer. |
| 429 | `rate_limit_exceeded` | Create: the control plane's own count of the key's `rpm` (a token bucket, like the data plane's) is used up. List: the key is listing jobs too often (its `rpm`, or 600 per minute when it has none). |
| 429 | `too_many_open_jobs` | Create only: the key already has its limit of unfinished jobs. Wait for some to finish, or cancel some. |
| 429 | `too_many_jobs_today` | Create only: the key already created its limit of jobs this UTC day (`max_jobs_per_day`). The count starts again at midnight UTC; `Retry-After` is the seconds until then, at most 3,600. |
| 503 | `storage_unavailable` | Create only: the job could not be written to the job store (its disk, most likely). Nothing was created; try again shortly. |
| 500 | `internal_error` | The control plane failed while handling the request. The error carries a `request_id` that is also in the control plane's log, and is the id in the response's `x-omnigate-request-id`; nothing else about the failure is disclosed. |
| 400 | `webhook_not_configured` | `webhook_url` was given but no signing secret is configured for this key. |
| 400 | `invalid_webhook_url` | The URL is not http(s), is longer than 2,048 bytes, has no host, contains credentials, does not resolve, or resolves to an address that is not public (private, loopback, link-local; for IPv6, anything outside `2000::/3`). |
| 402 | `budget_exceeded` | Create only: the key has spent its budget for the current period. The control plane checks this itself, without waiting for the data plane's next config poll. |
| 403 | `model_not_allowed` | The key's `models` list does not include this model. |
| 404 | `model_not_found` | No media route has this name. |
| 404 | `job_not_found` | No such job for this key. |
| 409 | `idempotency_conflict` | The `Idempotency-Key` was already used with a different request. |

## Receipts

```
GET /v1/attestations/{request id}
```

Only on a gateway with an [attested upstream](attestation.md). The receipt
of one answer that came from such an upstream: the provider's signature
over the exact request and response bytes, and whether it verified against
the attestation checked before the request. `{request id}` is the
`x-omnigate-request-id` of the response. The fields, an example and what a
receipt does and does not prove are in
[A receipt for each answer](attestation.md#a-receipt-for-each-answer).

| Status | `error.code` | When |
|---|---|---|
| 200 | | The receipt. `verdict` is `verified`, `not_verified` (with `reason` and `reason_code`) or, for the second or so the check takes, `pending`. |
| 404 | `receipt_not_found` | No receipt under this id: the answer did not come from an attested upstream, was an error, was cut off or came from the cache; the receipt is not made yet (ask again in a moment); it is older than `retention.receipts_days`; or it belongs to another key. |
| 401 | `missing_api_key`, `invalid_api_key` | As everywhere. |
| 405 | `method_not_allowed` | Anything but `GET`. |

Only the key that made the request (across its rotations) can read it.
`tools/verify_receipt.py` checks one offline.

## Payments

Only on a gateway whose config has a `payments` section; everywhere else
these paths answer `404 not_found`. The holder of a prepaid key buys credit
with them, also when the key's credit is spent. The whole of it (the flow,
the states, the errors, what is checked and what is trusted) is in
[Payments](payments.md#the-api).

| Method and path | Purpose |
|---|---|
| `GET /v1/payments/assets` | What can be paid with; `?chain=` and `?symbol=` narrow it. Also `provider` and `refund_address` (whether a payment needs `refund_to`). |
| `POST /v1/payments/quote` | `{"amount_usd", "asset", "refund_to"}`: what a payment would take, without starting one. |
| `POST /v1/payments` | The same body: start a payment. `201` with the deposit address, the amount to send and the deadline. |
| `GET /v1/payments/{id}` | The payment: `awaiting_deposit`, `processing`, `settled` (with `credited_usd`), `refunded`, `failed` or `expired`. |
| `GET /v1/payments` | The key's payments, newest first, and under `"credits"` what is left on the key. |
| `GET /topup` | Not an API: the [top-up page](payments.md#the-top-up-page), which does the calls above for a person. Served without a key. |
| `POST /v1/payments/{id}/tx` | `{"tx_hash"}`: optional hint to the provider. |

Their errors use the gateway's error shape; the codes are
`invalid_request`, `payment_quote_refused` (400), `payment_not_found` (404),
`not_prepaid`, `payment_closed` (409), `too_many_open_payments`,
`rate_limited` (429), `payment_provider_error` (502) and
`payment_provider_unavailable` (503). `POST` requests count against the
key's `rpm`.

## File URLs

```
GET /v1/files/{job id}/{name}?exp=<unix seconds>&sig=<hex>
```

Job outputs are copied into storage you control as soon as the job finishes,
so the URL in a job keeps working after the provider's own link expires.

**Local storage.** `outputs[].url` points at the gateway
(`<media.public_base_url>/v1/files/...`) and carries an expiry and an
HMAC-SHA256 signature. Anyone holding the URL can download the file until it
expires (`media.storage.url_ttl_s`, one hour by default); no gateway key is
needed. Fetch the job again to get a fresh URL.

The same path without the query string works for the gateway key that owns
the job:

```bash
curl -O http://127.0.0.1:8080/v1/files/job_5f0c2a9e4b7d81c3a6e2f490/out-0.png -H "Authorization: Bearer og-unlimited-key"
```

**How a stored file is served.** The bytes, and the type they were
declared with, came from a provider, so they are never served as something
a browser would render as a page on the gateway's origin.

- **Content type.** The stored type is kept only when it is one of
  `image/png`, `image/jpeg`, `image/webp`, `image/gif`, `video/mp4`,
  `video/webm`, `video/quicktime`, `audio/mpeg`, `audio/wav`,
  `audio/x-wav`, `audio/ogg`, `audio/flac`, `audio/pcm` or
  `application/json`. Anything else (`text/html`, `image/svg+xml`, XML,
  unknown types) is served as `application/octet-stream`. The job object
  still reports the stored type in `outputs[].content_type`.
- **Download, not display.** The control plane sends the file with
  `content-disposition: attachment; filename="<name>"`,
  `x-content-type-options: nosniff`,
  `content-security-policy: sandbox; default-src 'none'` and
  `cache-control: private, max-age=3600`.
- **What reaches the client.** The data plane passes these four headers
  on, with the status, content type and body, so a client gets them from
  the gateway itself, with or without a proxy in front. (For a short
  while, between commits 3a0b147 and 10bc009, it did not, and the included
  proxy added them; that rule is gone from `deploy/Caddyfile`.)
- **Framing.** A file is sent with its `content-length`, whatever its
  size, so a client can show progress and can tell a whole file from a cut
  one; the size is also in the job (`outputs[].bytes`), with the SHA-256
  to check the result against. (Between commit e4e30e4 and the close-out
  commit a file over 64 KiB was sent with `transfer-encoding: chunked` and
  no length.) If the download breaks off inside the gateway, the
  connection is dropped short of that length. A client that stops reading
  for `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` (30 seconds) is disconnected.

To show an output in a web page, fetch it and use it from your own origin
(or use bucket storage); do not point a page at the gateway URL and expect
it to render inline.

**Bucket storage.** `outputs[].url` is a presigned GET URL on your bucket
(or a plain `public_base_url` URL, if you configured one), not a gateway
URL. A request to the gateway's `/v1/files/...` path for such an output
answers `302` with that URL in `Location`. (Earlier commits dropped the
`Location` header on the way through the data plane.)

| Status | Reason | When |
|---|---|---|
| 401 | `missing_api_key` | Neither a key nor a signature was sent. |
| 403 | `invalid_signature` | The signature does not match. |
| 403 | `url_expired` | The signature is valid but `exp` has passed. |
| 404 | `file_not_found` | No such file, or the job belongs to another key. |

`missing_api_key` is raised by the data plane when the request has neither
a key nor a `sig` parameter. The others, and `missing_api_key` for a URL
with `sig` but no `exp`, are raised by the control plane. Both use the same
shape, with the reason in `error.code`.

## Webhooks

Pass `webhook_url` when creating a job and the gateway POSTs the result
there when the job reaches a final status (`succeeded`, `failed` or
`canceled`). A signing secret must be configured for the key; see
[Configuration](configuration.md#mediawebhooks).

The request follows [Standard Webhooks](https://www.standardwebhooks.com/):

```
POST <webhook_url>
content-type: application/json
user-agent: omnigate-webhooks/0.1.0
webhook-id: msg_job_5f0c2a9e4b7d81c3a6e2f490
webhook-timestamp: 1794312003
webhook-signature: v1,<base64 HMAC-SHA256>
```

```json
{
  "type": "job.succeeded",
  "timestamp": "2026-11-10T12:00:03.415Z",
  "data": { "object": "job", "id": "job_5f0c2a9e4b7d81c3a6e2f490", "status": "succeeded" }
}
```

`type` is `job.` followed by the status. `data` is the same job object that
`GET /v1/jobs/{id}` returns.

### Delivery and retries

- Any 2xx answer counts as delivered. Anything else, a redirect included, is
  a failed attempt.
- **Only the status of the receiver's answer is used.** At most 16 KiB of
  its body are read, then the connection is closed; a receiver cannot make
  the control plane hold a large answer.
- **An attempt is recorded before its request is sent.** A delivery that a
  crash or a restart cuts short has therefore used up its attempt, and a
  receiver gets at most `max_attempts` requests per job whatever happens.
- **Deliveries are capped.** At most `media.webhooks.max_concurrent` (16)
  run at once, and at most `max_concurrent_per_key` (4) for the jobs of one
  gateway key. The rest wait their turn, fairly across keys, so a delivery
  can start later than its schedule says when many are due at once.
- The host name is resolved once per attempt. Every address it resolves to
  is checked against the private-address rule, and the connection is then
  made to the address that was checked (with the host name still used for
  the `Host` header and the TLS certificate), so a DNS answer that changes
  between the check and the call cannot redirect a delivery inwards.
- Failed attempts are retried after the delays in
  `media.webhooks.retry_schedule_ms`, up to `max_attempts` deliveries in
  total. After that the webhook's `status` is `failed`.
- `webhook-id` is the same on every retry of a job; `webhook-timestamp` is
  the time of that attempt. Use `webhook-id` to ignore a delivery you have
  already processed.
- Delivery state is stored with the job and survives a control-plane
  restart. It is visible as `webhook` in the job object: `status` is
  `waiting` (job not finished), `pending`, `retrying`, `delivered` or
  `failed`.

### Verifying the signature

The signature is the base64 HMAC-SHA256 of
`<webhook-id>.<webhook-timestamp>.<raw body>`, prefixed with `v1,`. If the
secret starts with `whsec_`, the key is the base64-decoded remainder;
otherwise the secret's bytes are used as they are.

Verify against the raw request body, before parsing it:

```python
import base64
import hashlib
import hmac
import time


def signing_key(secret: str) -> bytes:
    if secret.startswith("whsec_"):
        try:
            return base64.b64decode(secret[len("whsec_"):], validate=True)
        except ValueError:
            pass
    return secret.encode()


def verify(secret: str, headers, body: bytes, tolerance_s: int = 300) -> bool:
    """headers: a mapping with lower-case names. body: the raw bytes received."""
    msg_id = headers.get("webhook-id", "")
    timestamp = headers.get("webhook-timestamp", "")
    signatures = headers.get("webhook-signature", "")

    # Refuse old or future-dated deliveries, so a captured one cannot be replayed later.
    if not timestamp.isdigit() or abs(time.time() - int(timestamp)) > tolerance_s:
        return False

    signed = f"{msg_id}.{timestamp}.".encode() + body
    digest = hmac.new(signing_key(secret), signed, hashlib.sha256).digest()
    expected = "v1," + base64.b64encode(digest).decode()

    # The header may hold several space-separated signatures.
    return any(hmac.compare_digest(expected, s) for s in signatures.split(" "))
```

The five-minute tolerance is the receiver's choice (it is what the mock
receiver in `tools/mock_media.py` uses); the gateway does not depend on it.

## Control plane

Everything in this section is on the control plane's port. Apart from the
two probes and the sign-in form it needs the **admin token** (or, for
`/internal/*`, the internal token), never a gateway key.

### `GET /healthz` and `GET /readyz`

`GET /healthz` answers `200` with the body `ok`. It says the process
answers.

`GET /readyz` says it can do its job: `200` with `{"status": "ready"}` when
the config is loaded, the job store is running, and the ledger is loaded
and its file is writable. Otherwise it answers `503` with
`{"status": "not_ready", "reason": "..."}`, naming the first thing that is
not ready. The container image's health check calls it.

Neither needs authentication. While the control plane is starting, the port
is not open yet (the ledger is loaded before the listener starts), so a
probe gets a refused connection rather than a 503.

Once it is up, the listener stays up even if the ledger, the job store,
the keys or the audit log have to restart: those run as a group of their
own, which is restarted (with a pause that grows from half a second to
thirty) without touching the listener. During such a restart `/healthz`
still answers `200`, `/readyz` answers `503` with the reason, and
`GET /internal/config` answers `503 not_ready`, so data planes keep the
config they have and no key is unblocked by a ledger that has not loaded
its totals yet. Other requests that need the missing piece fail instead of
being answered from half-loaded state.

### Errors and request paths

Control-plane errors have the same shape as the gateway's OpenAI-style
errors: the reason in `error.code`, a broader category in `error.type`:

```json
{"error": {"message": "send Authorization: Bearer <admin token>", "type": "invalid_request_error", "param": null, "code": "unauthorized"}}
```

(Until commit 10bc009 the control plane's errors were
`{"error": {"type": "<reason>", "message": "..."}}`. A script that matched
on `error.type` must match on `error.code`.) Every response from the
control plane, errors included, carries an `x-request-id` header: the
gateway's id for a request that the data plane relayed, a fresh one
otherwise. Besides the errors of each endpoint, any request can get:

| Status | `error.code` | When |
|---|---|---|
| 400 | `invalid_request` | The request path contains a percent-encoded character (any `%`), a backslash, a NUL byte, or a `.` or `..` segment. No route needs one: key names, job ids and file names are all plain. Also: a body that is not valid UTF-8. |
| 400 | `invalid_json` | A body that is not valid JSON. |
| 401 | `unauthorized` | `/admin/*` or `/metrics` without the admin token or a session; `/internal/*` without the internal token. |
| 404 | `not_found` | No such endpoint. |
| 413 | `payload_too_large` | A body larger than 8,000,000 bytes. On `POST /login`, the only endpoint that takes a body without a credential, and on `POST /logout` from a signed-in browser: a body declared larger than 4,096 bytes, or sent with chunked encoding instead of a declared length. |
| 429 | `too_many_attempts` | `/admin/*`, `/metrics`, the dashboard page (`/`) and `GET /login`: this address has sent 20 wrong admin tokens within a minute. Every bearer token from it is refused until that minute is over, the right one included; the answer has `retry-after: 60`. See [Admin](admin.md#two-ways-in). |
| 503 | `not_ready` | `GET /internal/config` while the ledger is starting or restarting, with `retry-after: 1`. |
| 500 | `internal_error` | An unexpected failure. The error has a `request_id` (the same value as the `x-request-id` header) that is also in the control plane's log line for it; the cause is only in the log. |

The admin API adds reasons of its own: `key_not_found` (404), `key_exists`
(409), `read_only_key` (409) and, for a change from a browser session
without the CSRF token, `csrf_failed` (403). They are described in
[Admin](admin.md).

A request is handled in this order: the path check above, then the
credential for the path's first segment, then the body, then the CSRF
check, then the endpoint.

- **Unknown paths are denied, not passed on.** A first path segment the
  control plane does not serve is answered `404` at the guard. Under
  `/admin` and `/internal` an unknown path answers `401` without the right
  credential and `404` with it.
- **A body is read only for a caller who has authenticated, and for the
  sign-in form.** `/admin/*` and `/internal/*` bodies are parsed after the
  credential check. `POST /login` (and `POST /logout` from a signed-in
  browser) may carry at most 4,096 bytes, by declared length. Nobody
  else's body is read at all: a body on `POST /healthz`, on a `GET`, on
  `DELETE /login` or on an unknown path is left unread, the request gets
  the answer its path deserves, and the response says `connection: close`
  so that the unread bytes are never taken for a next request.
- **Wrong credentials are counted, wherever the token is accepted.** Five
  failed logins, or 20 wrong bearer tokens, from one address within a
  minute lock that address out of that way in until the minute is over.
  The bearer count covers `/admin/*`, `/metrics`, the dashboard page (`/`)
  and `/login`, which also accept the token; until commit d79406b the last
  two compared it outside the throttle. A locked-out address gets
  `429 too_many_attempts` on the first three and on `GET /login` (which
  showed the form with `200` until the close-out commit). A request with no `Authorization`
  header at all is not a guess and is not counted, and a signed-in browser
  session is not affected by a bearer lockout.
- **HTTP/1.1 only.** The control plane's listener has HTTP/2 and WebSocket
  upgrades switched off; nothing it serves needs them.
- The path check is the fix for an authentication bypass in earlier
  commits, where `/%61dmin/keys` reached the admin API without a token; see
  [SECURITY.md](../SECURITY.md#past-advisories).

### Admin API

| Method and path | Purpose |
|---|---|
| `GET /admin/keys` | Every gateway key, from the config file and managed, with its usage. |
| `POST /admin/keys` | Create a managed key. The answer is the only one that contains the key itself. |
| `PATCH /admin/keys/{name}` | Change a managed key's budget, period, rate limit, models, open-job limit, jobs-per-day limit, webhook secret or disabled flag. |
| `POST /admin/keys/{name}/rotate` | Give a managed key a new secret. |
| `POST /admin/keys/{name}/topup` | Add `amount_usd` to a managed key's total budget, once per `reference` (a payment id): the same call again adds nothing. Optional `source`. |
| `GET /admin/topups?key=NAME&limit=N` | Applied top-ups and bonuses, newest first ([Prepaid credit](credits.md#seeing-it)). |
| `GET /admin/payments?limit=N` | [Payments](payments.md#for-operators) taken for credit, newest first; empty unless payments are configured. |
| `DELETE /admin/keys/{name}` | Delete a managed key. |
| `GET /admin/events?after=CURSOR&limit=N&key=NAME` | The usage feed: every recorded text request and media job, oldest first, with a cursor to continue from. No content. See [Building on omnigate](building-on-omnigate.md#reading-usage). |
| `GET /admin/usage` | The same document as `GET /admin/keys`. |
| `GET /admin/overview` | Everything the dashboard shows, as JSON. |
| `GET /admin/audit?limit=N` | The newest entries of the admin audit log. |
| `GET /admin/attestations` | Every (upstream, model) on an [attested upstream](attestation.md#looking-at-it-the-admin-api-metrics-logs): the verdict, when it was reached, the evidence. |
| `POST /admin/attestations/verify` | Check one of them now, with a new nonce: `{"upstream": "...", "model": "..."}`. |
| `GET /admin/receipts?limit=N`, `GET /admin/receipts/{request id}` | [Receipts](attestation.md#a-receipt-for-each-answer) of answers from attested upstreams, newest first (50 unless `limit`, at most 500), each with the name of the key that made the request, and `counts` by verdict; or one of them. |
| `GET /admin/private-chat/state`, `POST /admin/private-chat/send` | The feed and the send action of the dashboard's [Private chat page](attestation.md#the-private-chat-page) (`GET /private-chat`). The page's own interface rather than a versioned one. |

Request bodies, answers, error types and `curl` examples for all of these
are in [Admin](admin.md). In short:

```bash
curl http://127.0.0.1:4000/admin/keys -H "Authorization: Bearer dev-admin-token-change-me"
```

```json
{
  "keys": [
    {
      "name": "dev",
      "source": "file",
      "created_at": null,
      "budget_usd": 0.01,
      "budget_period": "total",
      "period_spend_usd": 0.0108,
      "period_resets_at": null,
      "rpm": 0,
      "max_concurrent": 0,
      "models": null,
      "max_open_jobs": 100,
      "max_jobs_per_day": 10000,
      "disabled": false,
      "blocked": true,
      "state": "blocked",
      "shadowed": false,
      "has_webhook_secret": false,
      "requests": 4,
      "errors": 0,
      "input_tokens": 36,
      "cached_input_tokens": 0,
      "cache_write_input_tokens": 0,
      "output_tokens": 24,
      "cached_responses": 0,
      "jobs": 0,
      "cost_usd": 0.0108
    }
  ]
}
```

(Numbers are illustrative.)

| Field | Meaning |
|---|---|
| `source` | `file` (written in the config file, read-only here) or `managed` (created through this API). |
| `state` | `active`, `blocked` (budget spent for the current period), `disabled`, or `shadowed`. `blocked`, `disabled` and `shadowed` are also given as booleans. |
| `shadowed` | `true` for a managed key that is out of use because the config file defines a key with the same name. Such a key is listed after all the others, here, in `GET /admin/overview` and in the dashboard; its secret answers `401` until one of the two is removed. See [Admin](admin.md#gateway-keys-two-sources). |
| `budget_period`, `period_spend_usd`, `period_resets_at` | What the budget covers, the spend that counts against it, and when that starts over (`null` for a total budget). |
| `max_concurrent` | The key's own cap on requests in flight at once per data-plane process; `0` when it has none and the data plane's `OMNIGATE_MAX_CONCURRENT_PER_KEY` applies. |
| `max_open_jobs` | The limit on unfinished media jobs in force for the key: its own setting, or `media.max_open_jobs` when it has none. `0` means no limit. |
| `max_jobs_per_day` | The limit on media jobs created per UTC day in force for the key: its own setting, or `media.max_jobs_per_day` when it has none. `0` means no limit. |
| `requests` | Text calls and media jobs recorded in the ledger. `jobs` counts the media jobs among them. |
| `errors` | Ledger events with a status of 400 or above, which includes failed and canceled jobs. |
| `input_tokens` | Input tokens that were not served from a provider's prompt cache. |
| `cached_input_tokens`, `cache_write_input_tokens` | Input tokens read from, and written to, a provider's prompt cache. |
| `cached_responses` | Requests answered from the gateway's own [response cache](#response-cache). |
| `cost_usd` | Total spend. |

A key that was rotated keeps one row: usage recorded under its earlier
secrets is included.

Without a valid token or session the answer is `401`, with a
`WWW-Authenticate: Bearer` header:

```json
{"error": {"message": "send Authorization: Bearer <admin token>", "type": "invalid_request_error", "param": null, "code": "unauthorized"}}
```

After 20 wrong tokens from one address within a minute, the answer to any
bearer token from that address is `429 too_many_attempts` with
`retry-after: 60`, until the minute is over.

A change (`POST`, `PATCH`, `DELETE`) authenticated by a session cookie
instead of the bearer token must also carry the session's CSRF token, or
the answer is `403 csrf_failed`. Requests with the bearer token need
nothing extra. See [Admin](admin.md#csrf-scripts-and-browsers).

### `GET /metrics`

Prometheus text format (version 0.0.4), behind the same admin token:

```bash
curl http://127.0.0.1:4000/metrics -H "Authorization: Bearer dev-admin-token-change-me"
```

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `omnigate_build_info` | gauge | `version` | Always 1. The version is the control plane's (`control/mix.exs`). |
| `omnigate_uptime_seconds` | gauge | | Seconds since the control plane started. |
| `omnigate_config_reloads_total` | counter | | Config file reloads applied since start. |
| `omnigate_config_last_reload_timestamp_seconds` | gauge | | Unix time the config was last loaded. |
| `omnigate_key_requests_total` | counter | `key` | Requests and media jobs recorded in the ledger. |
| `omnigate_key_errors_total` | counter | `key` | Recorded requests that ended with status 400 or above. |
| `omnigate_key_input_tokens_total` | counter | `key` | Input tokens that were not served from a provider's prompt cache. |
| `omnigate_key_cached_input_tokens_total` | counter | `key` | Input tokens read from a provider's prompt cache. |
| `omnigate_key_cache_write_input_tokens_total` | counter | `key` | Input tokens written to a provider's prompt cache. |
| `omnigate_key_output_tokens_total` | counter | `key` | Output tokens. |
| `omnigate_key_cached_responses_total` | counter | `key` | Requests answered from the data plane's response cache. |
| `omnigate_key_jobs_total` | counter | `key` | Media jobs recorded in the ledger. |
| `omnigate_key_cost_usd_total` | counter | `key` | Spend in US dollars, over the whole ledger: what the providers cost. |
| `omnigate_key_credits_burned_usd_total` | counter | `key` | Credit burned: the spend times the key's [burn multiplier](credits.md#the-burn-multiplier). Equal to the spend at a multiplier of 1, and for every key that is not prepaid. |
| `omnigate_payments` | gauge | `status` | [Payments](payments.md) held, by status. No series unless payments are configured and one was started. |
| `omnigate_payments_credited_usd` | gauge | | US dollars credited to keys from the payments held. |
| `omnigate_key_budget_usd` | gauge | `key` | Budget, for keys that have one. |
| `omnigate_key_period_cost_usd` | gauge | `key` | Spend in the key's current budget period: this month, this day, or everything for a total budget. |
| `omnigate_key_blocked` | gauge | `key` | 1 when the key has spent its budget for the current period and is refused, else 0. |
| `omnigate_data_planes` | gauge | | Data planes that reported their rate-limit counts in the last 30 seconds. A data plane with `OMNIGATE_LIMIT_SYNC_MS=0`, or older than this metric, is not counted. |
| `omnigate_rejected_requests_total` | counter | `key`, `reason` | Requests data planes refused before routing, since this control plane started. `reason` is the `error.code` the client got; `key` is the key's name, or `-` when the request had no usable key. |
| `omnigate_redactions_total` | counter | `key`, `class` | Values [privacy mode](privacy.md#redaction) replaced by placeholders before a provider saw them, since this control plane started. `class` is `email`, `phone`, `card`, `ip` or `secret`. Counts only. |
| `omnigate_key_private` | gauge | `key` | 1 when the key has any part of privacy mode switched on, else 0. |
| `omnigate_attestation_verified` | gauge | `upstream`, `model` | 1 while the [attestation](attestation.md) of an upstream's model is verified and recent enough, else 0 (its targets are then not used). No series without attested upstreams. |
| `omnigate_attestation_age_seconds` | gauge | `upstream`, `model` | Seconds since that attestation last verified; absent until it has. |
| `omnigate_attestation_checks_total` | counter | `outcome` | Attestation checks since this control plane started: `ok`, `failed` (the evidence did not hold), `unavailable` (it could not be fetched). |
| `omnigate_receipts` | gauge | `verdict` | [Receipts](attestation.md#a-receipt-for-each-answer) held for answers from attested upstreams: `verified`, `not_verified`, `pending`. All 0 without an attested upstream. |
| `omnigate_jobs` | gauge | `status` | Media jobs currently in the job store, by status. |
| `omnigate_webhooks` | gauge | `state` | Webhook deliveries of the jobs currently in the job store, by state. |
| `omnigate_ledger_events_total` | counter | | Usage events in the ledger. |
| `omnigate_ledger_dedup_ids` | gauge | | Event ids held in memory to reject resent events (about 61 MiB per million). |
| `omnigate_ledger_invalid_events_total` | counter | | Usage events dropped because they were malformed, since this control plane started. |
| `omnigate_ledger_unpriced_events_total` | counter | | Usage events recorded at $0 because the config has no such route or target, and media jobs that succeeded on a target with no price, since this control plane started. |

The `key` label is the key's `name`, never its hash, and covers both file
and managed keys. See [Operations](operations.md#metrics) for a scrape
config and caveats.

### Dashboard and sessions

| Method and path | Purpose |
|---|---|
| `GET /` | The dashboard: totals, keys (with create, disable, rotate and delete for managed keys), recent requests and media jobs, refused requests, admin activity, and a read-only view of the configuration. Redirects to `/login` without a session. See [Admin](admin.md#the-dashboard). |
| `GET /login` | The sign-in form. With a bearer token from an address that is locked out for wrong tokens: `429 too_many_attempts`, as on `/`. |
| `POST /login` | Form field `password` = the admin token. Sets the `omnigate_session` cookie (12 hours, `HttpOnly`, `SameSite=Strict`) and redirects to `/`. A wrong token answers 401; after five failures from one address, 429 for a minute. The body may be at most 4,096 bytes, declared in `Content-Length` (413 otherwise). Failed and throttled attempts are aggregated in the audit log: at most two lines per address, outcome and minute ([Admin](admin.md#the-audit-log)). |
| `POST /logout` | Clears the cookie. From a session it needs the CSRF token, which the dashboard's sign-out button sends. |

A valid session cookie is accepted wherever the admin token is, so
`/admin/*` and `/metrics` also work in a signed-in browser (reads without
anything extra, changes with the CSRF token).

The dashboard and login pages are sent with a `Content-Security-Policy`
that allows nothing from other origins, `X-Frame-Options: DENY`,
`Referrer-Policy: no-referrer` and `Cache-Control: no-store`.

### `/internal/*`

Used by data planes only, with the internal token in the
`x-omnigate-internal` header: `GET /internal/config` (which answers
`503 not_ready` while the ledger is starting),
`POST /internal/usage/batch` (answered with how many events were
`accepted`, were `duplicates` or were `invalid`),
`POST /internal/counters` (counts of refused
requests), `POST /internal/limits/sync` (what a data plane allowed its
rate-limited keys, answered with what the others allowed), and the jobs and files API under `/internal/v1/`. It is not a
public interface. The Compose proxy answers 404 for these paths from
outside, and the control plane itself refuses any percent-encoded spelling
of them. The data plane builds the address of such a call from its own
configuration and sets the client's path and query, which it has validated
character by character, as separate components; a client cannot make it
call anything but `/internal/v1/jobs*` and `/internal/v1/files/*`.
