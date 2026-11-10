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

## Errors

Errors produced by the gateway itself have one shape, whichever protocol the
client speaks:

```json
{"error": {"type": "invalid_api_key", "message": "unknown gateway key"}}
```

| Status | `error.type` | When |
|---|---|---|
| 400 | `invalid_json` | The body is not a JSON object. |
| 400 | `missing_model` | No `"model"` string in the body. |
| 401 | `missing_api_key` | No key was sent. |
| 401 | `invalid_api_key` | The key is not in the config. |
| 402 | `budget_exceeded` | The key has spent its budget. |
| 403 | `model_not_allowed` | The key's `models` list does not include this model. |
| 404 | `not_found` | The path is not an endpoint the gateway serves. |
| 404 | `model_not_found` | No route has this name. |
| 405 | `method_not_allowed` | A method other than GET or POST on `/v1/jobs*` or `/v1/files/*`. |
| 413 | `payload_too_large` | The request body exceeds 8 MiB. |
| 429 | `rate_limit_exceeded` | The key is over its `rpm`. The response has a `Retry-After` header in seconds. |
| 502 | `all_upstreams_failed` | Every target of the route failed. The error also has `attempts`. |
| 503 | `gateway_not_ready` | The data plane has no config yet (the control plane has never answered and there is no cached config). |
| 503 | `control_plane_unavailable` | A jobs or files request could not reach the control plane. |

The jobs API adds a few of its own; they are listed [below](#job-errors).

A 502 looks like this:

```json
{
  "error": {
    "type": "all_upstreams_failed",
    "message": "every target for this model failed",
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

**Provider errors are not rewritten.** When a provider answers with a status
that is not 429 or 5xx (a 400 for a bad parameter, a 401 for a bad provider
key), the gateway passes that status and body to the client. If the request
was translated, the error body is converted to the client's protocol. A 429
or 5xx from a provider triggers failover instead; the client only sees it as
part of a 502 when every target fails.

The gateway checks a request in this order: config present, key present and
known, budget, endpoint, body size, JSON, `model`, model limits, rate limit,
route.

## Text endpoints

| Method and path | Protocol | Translated to the other protocol | Metered |
|---|---|---|---|
| `POST /v1/chat/completions` | OpenAI | yes | yes |
| `POST /v1/messages` | Anthropic | yes | yes |
| `POST /v1/completions` | OpenAI | no | yes |
| `POST /v1/embeddings` | OpenAI | no | yes |
| `POST /v1/responses` | OpenAI | no | yes |
| `POST /v1/messages/count_tokens` | Anthropic | no | no |
| `GET /v1/models` | | | no |
| `GET /healthz` | | | no |

"Metered" means the call counts against the key's rate limit and is written
to the usage ledger. `count_tokens` does neither.

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

Other request headers are not forwarded to the provider.

### Response

The provider's response, streamed as it arrives, with these headers added:

| Header | Meaning |
|---|---|
| `x-omnigate-upstream` | Name of the upstream that answered. |
| `x-omnigate-attempts` | How many upstreams the request was sent to, this one included. |
| `x-omnigate-request-id` | Id of this request; also the id of its usage event in the ledger. |

A 502 `all_upstreams_failed` carries only `x-omnigate-request-id`.

Of the provider's own response headers only `content-type` is kept (and
`content-length`, when the body is passed through untouched). Provider
headers such as rate-limit counters or request ids do not reach the client.
The gateway also sets `cache-control: no-cache`.

### Streaming

Set `"stream": true` as the provider's protocol defines. Chunks are flushed
to the client as they arrive.

For `/v1/chat/completions` and `/v1/completions`, OpenAI-style providers
report token usage on a stream only when asked. If the client did not set
`stream_options.include_usage`, the gateway sets it to meter the call and
removes the extra usage chunk from what the client receives.

Failover happens only before the first byte of a response reaches the
client. If a stream breaks after that, the connection is closed and what was
metered so far is recorded (with status 499 in the ledger).

### Translation

`/v1/chat/completions` and `/v1/messages` can be served by an upstream of the
other protocol, including streaming, tools and images. The response carries
the route name in `model`, in the client's protocol.

- Fields with no equivalent on the other side are dropped, not rejected:
  thinking blocks, cache control, `response_format`, penalties and similar.
- Audio and file parts cannot be translated. A target that would need them
  is skipped with the outcome `untranslatable_request`.
- When a translated request is refused because the model rejects
  `temperature`, `top_p` or `top_k`, the gateway retries without them and
  remembers that for the model. The same applies to models that demand a
  thought signature on earlier tool calls (Gemini 3 and later). Requests in
  the provider's own protocol are not touched and get the provider's error.

The README lists what has not been verified here: images in translated
requests, long conversations, large payloads, and the official OpenAI and
Anthropic SDKs as clients (the checks used plain HTTP).

### `GET /v1/models`

Lists the text routes the key may use. Media routes are not in this list.

```json
{
  "object": "list",
  "data": [
    {"id": "demo-chat", "object": "model", "owned_by": "omnigate"},
    {"id": "demo-claude", "object": "model", "owned_by": "omnigate"}
  ]
}
```

### `GET /healthz`

Answers `200` with the body `ok` and needs no key. It says the process is
up; it does not say that a config has been loaded.

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

Only `POST /v1/jobs` counts against the key's rate limit. A key sees only its
own jobs; another key's job id answers 404.

### Create a job

Request body:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `model` | string | yes | Name of a media route. |
| `input` | object | yes | Passed to the provider adapter. What goes in it depends on the adapter; see [Providers](providers.md#media-providers). |
| `webhook_url` | string | no | Where to POST the result. See [Webhooks](#webhooks). |
| `metadata` | object | no | Stored with the job and returned unchanged. |
| `cache` | boolean | no | `true` allows reuse of a stored output; `false` forbids it. See [Caching](#caching). |

Optional header: `Idempotency-Key` (1 to 255 bytes).

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
| `outputs[]` | One entry per stored file: `url`, `content_type`, `bytes`, `sha256`. The URL is generated fresh on every fetch. |
| `error` | `null`, or `{"type", "message"}` for a failed job. |
| `cost_usd` | The configured price of the target that delivered. `0` until the job succeeds, and for failed, canceled and cached jobs. |
| `cached` | `true` when the outputs were reused from an earlier identical job. |
| `upstream`, `target_model` | Which target delivered. |
| `attempts[]` | Each target tried, with its `outcome` (`ok`, `cache_hit`, `timeout`, `no_outputs`, or the reason it failed). |
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

### Cancel a job

```bash
curl -X POST http://127.0.0.1:8080/v1/jobs/job_5f0c2a9e4b7d81c3a6e2f490/cancel -H "Authorization: Bearer og-unlimited-key"
```

Returns the job. An unfinished job becomes `canceled` and is not billed; the
gateway also asks the provider to cancel, on a best-effort basis, for the
adapters that have a cancel call (Replicate-style and fal-style). A job that
had already finished is returned unchanged. The README notes that
cancellation at a real provider has not been verified.

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

### Job errors

In addition to the [general errors](#errors):

| Status | `error.type` | When |
|---|---|---|
| 400 | `missing_model` | `"model"` is not a string. |
| 400 | `invalid_request` | `input` is missing or not an object; `metadata` is not an object; the `Idempotency-Key` is empty or longer than 255 bytes. |
| 400 | `webhook_not_configured` | `webhook_url` was given but no signing secret is configured for this key. |
| 400 | `invalid_webhook_url` | The URL is not http(s), has no host, contains credentials, does not resolve, or resolves to a private or loopback address. |
| 403 | `model_not_allowed` | The key's `models` list does not include this model. |
| 404 | `model_not_found` | No media route has this name. |
| 404 | `job_not_found` | No such job for this key. |
| 409 | `idempotency_conflict` | The `Idempotency-Key` was already used with a different request. |

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

The file is served with its stored `content-type`,
`x-content-type-options: nosniff` and `cache-control: private, max-age=3600`.

**Bucket storage.** `outputs[].url` is a presigned GET URL on your bucket
(or a plain `public_base_url` URL, if you configured one), not a gateway
URL. A request to the gateway's `/v1/files/...` path for such an output
answers `302` with that URL in `Location`.

| Status | `error.type` | When |
|---|---|---|
| 401 | `missing_api_key` | Neither a key nor a signature was sent. |
| 403 | `invalid_signature` | The signature does not match. |
| 403 | `url_expired` | The signature is valid but `exp` has passed. |
| 404 | `file_not_found` | No such file, or the job belongs to another key. |

## Webhooks

Pass `webhook_url` when creating a job and the gateway POSTs the result
there when the job reaches a final status (`succeeded`, `failed` or
`canceled`). A signing secret must be configured for the key; see
[Configuration](configuration.md#mediawebhooks).

The request follows [Standard Webhooks](https://www.standardwebhooks.com/):

```
POST <webhook_url>
content-type: application/json
user-agent: omnigate-webhooks/0.1
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

Everything in this section is on the control plane's port and uses the
**admin token**, not a gateway key.

### `GET /healthz`

`200` with the body `ok`. No authentication.

### `GET /admin/usage`

Per-key totals from the ledger.

```bash
curl http://127.0.0.1:4000/admin/usage -H "Authorization: Bearer dev-admin-token-change-me"
```

```json
{
  "keys": [
    {
      "name": "dev",
      "budget_usd": 0.01,
      "blocked": true,
      "requests": 4,
      "errors": 0,
      "input_tokens": 36,
      "output_tokens": 24,
      "jobs": 0,
      "cost_usd": 0.0108
    }
  ]
}
```

(Numbers are illustrative.) `requests` counts text calls and media jobs;
`jobs` counts the media jobs among them; `errors` counts ledger events with a
status of 400 or above, which includes failed and canceled jobs.

Without a valid token or session the answer is `401`:

```json
{"error": {"type": "unauthorized", "message": "send Authorization: Bearer <admin token>"}}
```

### `GET /metrics`

Prometheus text format (version 0.0.4), behind the same admin token:

```bash
curl http://127.0.0.1:4000/metrics -H "Authorization: Bearer dev-admin-token-change-me"
```

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `omnigate_build_info` | gauge | `version` | Always 1. |
| `omnigate_uptime_seconds` | gauge | | Seconds since the control plane started. |
| `omnigate_config_reloads_total` | counter | | Config file reloads applied since start. |
| `omnigate_config_last_reload_timestamp_seconds` | gauge | | Unix time the config was last loaded. |
| `omnigate_key_requests_total` | counter | `key` | Requests and media jobs recorded in the ledger. |
| `omnigate_key_errors_total` | counter | `key` | Recorded requests that ended with status 400 or above. |
| `omnigate_key_input_tokens_total` | counter | `key` | Input tokens billed. |
| `omnigate_key_output_tokens_total` | counter | `key` | Output tokens billed. |
| `omnigate_key_jobs_total` | counter | `key` | Media jobs recorded in the ledger. |
| `omnigate_key_cost_usd_total` | counter | `key` | Spend in US dollars. |
| `omnigate_key_budget_usd` | gauge | `key` | Budget, for keys that have one. |
| `omnigate_key_blocked` | gauge | `key` | 1 when the key has spent its budget and is refused, else 0. |
| `omnigate_jobs` | gauge | `status` | Media jobs currently in the job store, by status. |
| `omnigate_webhooks` | gauge | `state` | Webhook deliveries of the jobs currently in the job store, by state. |
| `omnigate_ledger_events_total` | counter | | Usage events in the ledger. |
| `omnigate_ledger_dedup_ids` | gauge | | Event ids held in memory to reject resent events. |

The `key` label is the key's configured `name`, never its hash. See
[Operations](operations.md#metrics) for a scrape config and caveats.

### Dashboard and sessions

| Method and path | Purpose |
|---|---|
| `GET /` | The dashboard (read-only): keys, recent requests, recent media jobs. Redirects to `/login` without a session. |
| `GET /login` | The sign-in form. |
| `POST /login` | Form field `password` = the admin token. Sets the `omnigate_session` cookie (12 hours, `HttpOnly`, `SameSite=Strict`) and redirects to `/`. A wrong token answers 401; after five failures from one address, 429 for a minute. |
| `POST /logout` | Clears the cookie. |

A valid session cookie is accepted wherever the admin token is, so
`/admin/usage` and `/metrics` also work in a signed-in browser.

### `/internal/*`

Used by data planes only, with the internal token in the
`x-omnigate-internal` header: `GET /internal/config`,
`POST /internal/usage/batch`, and the jobs and files API under
`/internal/v1/`. It is not a public interface. The Compose proxy answers 404
for these paths from outside.
