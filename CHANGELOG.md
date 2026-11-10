# Changelog

All notable changes to omnigate are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). There are no
tagged releases yet; everything so far is under "Unreleased".

When a release is cut, the "Unreleased" section is renamed to
`## [<version>] - <date>` and a new, empty "Unreleased" section is started
above it. The release workflow publishes the section whose heading starts
with `## [<version>]` as the release notes, so keep that heading format;
see [docs/releasing.md](docs/releasing.md).

Which features have been checked against real providers, and which have
only met a mock, is tracked in the README's
[What has been verified](README.md#what-has-been-verified) section and in
`docs/`, rather than here.

## [Unreleased]

### Security

- **Authentication bypass on the control plane, fixed in commit 97cf396.**
  A request whose first path segment was percent-encoded (`/%61dmin/keys`,
  `/%69nternal/config`, `/%6Detrics`) skipped the admin-token, internal-token
  and CSRF checks and still reached its handler, because the checks looked
  at the path as sent while the router matched the decoded one.
  - **Who was affected:** anyone running an earlier commit with the control
    plane's port, or the dashboard's host name behind the Compose proxy,
    reachable by someone they do not trust. Such a caller needed no
    credential to use the whole admin API (including creating, rotating and
    deleting gateway keys), to read `/metrics`, and to use `/internal/*`
    (the config snapshot with key hashes, usage intake, the jobs API as any
    key). The admin token, the internal token and provider keys were not
    revealed. A control plane reachable only from a trusted network was not
    exposed.
  - **What to do:** update the control plane; delete managed keys you did
    not create and rotate the ones created or rotated while it was exposed;
    look in the audit log for key actions with `"auth": "none"`, which only
    this bypass could produce. The full advisory is in
    [SECURITY.md](SECURITY.md#past-advisories).
  - **The fix:** a request path with any encoded character is refused with
    400 before routing; an unknown first path segment is a 404 at the check
    instead of being passed on; credentials are checked before the body is
    parsed. Found by an independent review of the code.

### Added

**Text gateway (data plane)**

- OpenAI- and Anthropic-compatible streaming proxy with gateway-key
  authentication, model routing, failover on connection errors, 429 and 5xx,
  and token metering from the response stream.
- `POST /v1/chat/completions` and `POST /v1/messages`, plus
  `/v1/embeddings`, `/v1/responses`, `/v1/completions` and
  `/v1/messages/count_tokens` as same-protocol passthrough; `GET /v1/models`
  and `GET /healthz`.
- Translation between OpenAI chat completions and Anthropic messages:
  requests, responses, server-sent events, tools and images.
- At-least-once usage delivery: events are queued, appended to an on-disk
  spool and sent in batches with backoff, so calls made during a
  control-plane outage are still billed.
- Timeouts on waiting for upstream response headers, global or per upstream
  (`timeout_ms`), with cancellation; one retry on a fresh connection before
  failing over.
- Per-key requests-per-minute limits (`rpm`), answered with 429 and
  `Retry-After`.
- Upstream cooldowns: an upstream that keeps failing is tried last for a
  while.
- The last config is cached on disk, so a data plane restarted during a
  control-plane outage still serves.
- When a client did not ask for the OpenAI usage chunk on a stream, the
  gateway asks for it to meter the call and hides it from the client.
- `v1_path` on upstreams, for OpenAI-compatible providers that do not serve
  the API under `/v1` (Gemini uses `/v1beta/openai`).
- Route strategies: `failover` (default), `round_robin` and `weighted` with
  a per-target `weight`. The other targets remain as failover, and cooling
  upstreams still go last.
- Per-key model limits (`models`): anything else is a 403
  `model_not_allowed`.
- Client timeout (`OMNIGATE_CLIENT_TIMEOUT_MS`, 30 s): a client that does
  not finish sending its request, or leaves a keep-alive connection idle,
  is disconnected.
- Stream idle timeout (`OMNIGATE_STREAM_IDLE_TIMEOUT_MS`, 5 min): a response
  that stops moving is cut off, and what was metered up to then is billed.
- Connection cap (`OMNIGATE_MAX_CONNECTIONS`, 4096): further connections get
  an immediate 503 `overloaded` with `retry-after`.
- Graceful shutdown on SIGINT and SIGTERM (Ctrl-C and Ctrl-Break on
  Windows): requests in flight get `OMNIGATE_SHUTDOWN_GRACE_MS` (10 s) to
  finish, and queued usage is delivered before exit.
- Access log: one line per request with key name, route, upstream,
  attempts, tokens, latency and request id. `OMNIGATE_LOG_LEVEL` sets the
  level, and `OMNIGATE_LOG_FORMAT=json` writes every log line as one JSON
  object.
- Response cache, opt-in per route with `cache_ttl_s`: an identical
  non-streaming request from the same gateway key is answered from memory.
  Bounded by `OMNIGATE_CACHE_MAX_MB` (64); responses carry
  `x-omnigate-cache: hit` or `miss`; hits are counted but not billed.
- Provider response headers for the caller are passed on by allowlist:
  `retry-after`, `x-ratelimit-*`, `anthropic-ratelimit-*`, the provider's
  request id and a few more. A final 502 carries the last upstream's
  `retry-after`.
- Prompt-cache accounting: usage events separate uncached input, cache
  reads and cache writes, normalised by the upstream's protocol (OpenAI
  counts cached tokens inside its input figure, Anthropic beside it).
- Requests refused before routing (bad key, rate limit, disallowed model,
  timeouts, the connection cap and so on) are counted per key name and
  reason and reported to the control plane.
- `GET /v1/models` also lists the media job models the key may use.
- `GET /v1/models/{id}`. Model objects carry `created`, and a client that
  sends an `anthropic-version` header gets the model list and model objects
  in Anthropic's shape.
- `x-request-id` and `request-id` on every response except `GET /healthz`
  and the immediate 503 at the connection cap: the provider's own value
  when it sent one, the gateway's request id otherwise.
- Structured output through translation: OpenAI's `response_format` with a
  JSON schema becomes Anthropic's `output_config.format` and the reverse;
  `{"type": "json_object"}` becomes an instruction in the system prompt.
  Covered against the mock providers; the Anthropic side has not been
  verified against the live API.

**Control plane**

- Config file with hot reload, a durable JSONL usage ledger replayed at
  start, per-key budgets, and a minimal dashboard.
- The ledger deduplicates on event id and records event time, so a resent
  batch never bills twice.
- Async media jobs behind one API (`/v1/jobs`, `/v1/files`): failover across
  providers, outputs re-hosted to local disk or an S3-compatible bucket
  (SigV4), signed and retried webhooks, idempotency keys, output caching,
  restart-safe job state, and job costs in the same ledger and budgets as
  tokens.
- Media adapters: Replicate-style predictions, fal-style queues,
  OpenAI-style images, ElevenLabs-style text to speech, Gemini's native API
  for image and speech models (raw PCM speech is stored as WAV), xAI video,
  and Gemini's Interactions API for its video-capable "omni" models.
- Dashboard login and admin API protected by one admin token
  (`OMNIGATE_ADMIN_TOKEN`): a bearer token on `/admin/*`, and the dashboard
  password, exchanged for a signed session cookie (`HttpOnly`,
  `SameSite=Strict`, 12 hours). A random token is generated and logged at
  start if none is set. Five failed logins lock an address out for a minute.
- `OMNIGATE_CONTROL_BIND` to listen beyond localhost, with a warning that
  the listener is plain HTTP.
- `GET /healthz` on the control plane, without credentials.
- `OMNIGATE_MEDIA_DIR` for the local output directory.
- Per-key model limits applied to media jobs.
- `retention` config: finished jobs and their local files are removed after
  `jobs_days`, ledger duplicate-detection ids after `ledger_ids_days`. Off
  by default.
- `GET /metrics` in Prometheus text format, behind the admin token.
- Managed gateway keys: create, change, disable, rotate and delete keys
  through `/admin/keys` or the dashboard, without editing the config. A new
  key is shown once and stored only as a hash, in `OMNIGATE_KEYS`
  (`data/keys.json`). Keys in the config file keep working and are
  read-only for the API. A rotated key keeps its spend, budget and jobs.
- New dashboard: totals for today and overall, spend against budget per
  key, key management, recent requests and media jobs, refused requests,
  admin activity and a read-only configuration view. It updates live from
  `GET /admin/overview` and loads no external assets.
- CSRF protection for changes made with a dashboard session; requests with
  the bearer token are exempt.
- Budget periods: `budget_period` on a key is `total` (default), `monthly`
  or `daily` (UTC). A monthly or daily key unblocks by itself when the
  period turns.
- Prices for prompt-cache tokens per text target:
  `price_cached_in_per_mtok` and `price_cache_write_per_mtok`, both
  defaulting to the input price.
- Admin audit log (`OMNIGATE_AUDIT_LOG`, `data/audit.jsonl`): key changes,
  sign-ins and sign-outs, shown in the dashboard and at `GET /admin/audit`.
- `disabled` on a key in the config file.
- Metrics: `omnigate_key_cached_input_tokens_total`,
  `omnigate_key_cache_write_input_tokens_total`,
  `omnigate_key_cached_responses_total`, `omnigate_key_period_cost_usd` and
  `omnigate_rejected_requests_total{key, reason}`.
- Retention also deletes a removed job's objects from an S3-compatible
  bucket (`retention.delete_bucket_objects`, on by default; only acts when
  `jobs_days` is set).
- Ledger snapshots: the control plane writes a checksummed snapshot of its
  totals and loads it at start, replaying only the events written after it
  (1,000,000 events: 10.7 s before, 0.75 s after). A damaged snapshot is
  ignored in favour of the previous one, or of a full replay.
- Ledger segments: the event log is split into numbered files by size and
  at the turn of the UTC day, and `retention.ledger_days` deletes old ones
  while lifetime and period totals stay exact. An existing `ledger.jsonl`
  needs no migration.
- The job log is compacted while the control plane runs, not only at start
  and after a retention sweep.
- `GET /readyz` on the control plane: 200 when the config is loaded, the
  job store is running and the ledger is loaded and writable, 503 with a
  reason otherwise. No credentials.
- The audit log is rotated by size (`OMNIGATE_AUDIT_MAX_MB`, 50; three older
  files are kept; `0` turns rotation off).

**Packaging and tools**

- Container images for both processes (the data plane as a static binary on
  an empty base image, the control plane as an Elixir release on Alpine;
  both non-root), a `compose.yaml` and a Caddy configuration that terminates
  TLS for two host names and hides `/internal/*`.
- `tools/container_test.py`: builds the images and checks them through the
  TLS proxy; `--compose` tests `compose.yaml` itself.
- `tools/e2e.py`: starts the whole stack against mock providers and checks
  it end to end.
- `tools/mock_upstream.py` and `tools/mock_media.py`: mock text and media
  providers, an S3-compatible object store and a webhook receiver.
- `tools/bench.py`: measures the latency the gateway adds on localhost.
- `tools/import_litellm.py`: converts a LiteLLM proxy config; maps OpenAI,
  Anthropic, Gemini, Groq, Mistral, DeepSeek, OpenRouter, Together,
  Fireworks, xAI and Perplexity entries.
- Documentation under `docs/`, `CONTRIBUTING.md`, `SECURITY.md`, this
  changelog, and a CI workflow (`.github/workflows/ci.yml`).
- `tools/load_test.py`: a load and soak test with well-behaved and hostile
  clients (stalled, silent, disconnecting, oversized, malformed).
- `tools/sdk_compat.py`: runs the official OpenAI and Anthropic Python SDKs
  through the gateway against the mock providers (sync, async, streaming,
  errors, both translation directions). Needs `pip install openai anthropic`.
- `tools/mock_upstream.py`: a fifth mock on port 9005 that stalls
  mid-stream, and `MOCK_PORT_OFFSET` to run a second copy on other ports.
- CI: an `sdk` job that runs `tools/sdk_compat.py`, and a formatting check
  (`mix format --check-formatted`) in the control-plane job.
- Release workflow (`.github/workflows/release.yml`): pushing a tag `v*`
  builds data-plane binaries for five targets, pushes multi-architecture
  images of both planes to GHCR and creates a GitHub release with this
  changelog's section as notes. Described in `docs/releasing.md`.
- `docs/admin.md` (dashboard, key lifecycle, budgets, audit log, CSRF) and
  a section on using the official SDKs in `docs/api.md`.
- `tools/sdk_compat.py` also checks what an SDK user would notice: request
  ids, error codes and envelopes, the model endpoints, a provider's 429,
  structured output through translation. It no longer has a list of
  tolerated gaps; every case must pass.
- `tools/mock_upstream.py`: models that always answer 429 with
  `retry-after`, that send a provider request id, and answers that follow a
  requested JSON schema.

### Changed

- The dashboard and the `/admin` API now require the admin token. They were
  previously open to anyone who could reach the control plane's port.
- `GET /v1/models` lists only the routes the calling key may use.
- For text endpoints the request body is now read before the rate-limit
  check, so that a disallowed model is a 403 rather than a 429. A key over
  its limit therefore still costs one body read.
- The placeholder webhook secret in the dev config is written without the
  `whsec_` prefix (same key bytes), and test placeholders are assembled at
  compile time, so secret scanners no longer flag them.
- `config/omnigate.json`, the operator's own config, is ignored by git.
- A key over its budget is refused only where it would start new work (text
  requests and `POST /v1/jobs`). It keeps access to its model list, its
  jobs and files, and can cancel a job. Previously it got 402 everywhere.
- Both processes refuse to start without `OMNIGATE_INTERNAL_TOKEN`, and an
  empty value counts as not set. The control plane used to start without it
  and then refuse every data-plane request.
- A text upstream whose `kind` is not `openai` or `anthropic` is refused
  when the config is loaded. It used to be passed on to data planes, which
  could not parse the snapshot.
- In usage events, the ledger and metrics, `input_tokens` now means input
  that was **not** served from the provider's prompt cache. For
  OpenAI-style upstreams, which count cached tokens inside their input
  figure, cached tokens moved to `cached_input_tokens`. Cost is unchanged
  unless a cache price is configured.
- `GET /admin/usage` returns more fields per key (source, state, budget
  period, cache token counts) and includes managed keys.
- Webhook delivery resolves the target host once per attempt, checks the
  addresses and connects to the checked address. This closes DNS rebinding
  between the check and the call.
- Optimized data-plane builds use the multi-threaded allocator instead of
  the standard library's checking allocator, which cut memory for 100,000
  queued usage events from 427 MiB to 77 MiB.
- The control plane's code is formatted with `mix format` at a line length
  of 160, and CI enforces it.
- The retention log line also reports the bucket objects removed, and the
  ledger segments.
- **Gateway errors are provider-shaped, and the gateway's reason moved from
  `error.type` to `error.code`.** On OpenAI-style endpoints the error is
  `{"error": {"message", "type", "param", "code"}}`; on Anthropic-style
  endpoints it is `{"type": "error", "error": {"type", "message", "code"},
  "request_id"}`. `type` is now the provider's category
  (`invalid_request_error`, `rate_limit_error`, `not_found_error`, ...). A
  client that matched on `error.type` must match on `error.code` instead.
  Errors the control plane raises for the jobs API, and on its own port,
  keep the reason in `error.type`. The mapping is in `docs/api.md`.
- When every target of a route failed and the last one tried answered 429,
  the client gets 429 `upstream_rate_limited` with that upstream's
  `retry-after`. It used to get 502 `all_upstreams_failed`.
- An endpoint that none of a route's upstreams can serve (embeddings on a
  route with only Anthropic-style upstreams, for example) answers 400
  `endpoint_not_supported`, and a request that no target can be sent
  because it cannot be translated answers 400 `untranslatable_request`.
  Both used to be 502s, and neither is written to the ledger any more;
  they are counted as refused requests.
- On the control plane, a body that is not JSON (400 `invalid_json`), a
  body that is too large (413 `payload_too_large`) and an unexpected
  exception (500 `internal_error`, with a `request_id` that is also in the
  log) all answer with the JSON error object.
- A config-file key with the name of a managed key now shadows it: the
  file key is used, the managed key is left out, a warning is logged, and
  `GET /admin/keys` lists the managed key with `"state": "shadowed"`.
  Previously both were in the key list under one name.
- The control plane refuses a request path that contains a percent-encoded
  character with 400, answers an unknown first path segment with 404 before
  authentication, and checks credentials before parsing the body (see
  Security above). `/admin/keys/{name}` therefore has exactly one spelling.
- The control image's health check calls `/readyz` instead of `/healthz`.
- CI installs pinned versions of the two SDKs (`openai` 3.49.0,
  `anthropic` 2.8.0) for the `sdk` job instead of the latest ones, so that
  a new SDK release cannot fail CI without a change in the repository.
- The README was rewritten as a shorter landing page: the environment
  table and the config field lists now live only in
  `docs/configuration.md`, and it no longer states counts of test checks.

### Fixed

- Streamed responses were not flushed per chunk, so streams arrived in one
  burst.
- An error after the response had started no longer triggers failover.
- Translated requests that a model refuses because of sampling parameters
  (`temperature`, `top_p`, `top_k`) are retried without them, and the model
  is remembered. Found against the real OpenAI and Anthropic APIs: current
  Claude models answer 400 to parameters that OpenAI clients send routinely.
- Translated requests that Gemini 3 and later refuse for lacking a "thought
  signature" on earlier tool calls are retried with the placeholder Google
  documents, and the model is remembered. Found against the real Gemini API.
- A client that connected and sent nothing, or stopped half-way through a
  request, held a thread for ever. Found with the load test.
- Data-plane memory crept upwards under load, because usage events were
  allocated on request threads and freed on the flush thread. The queue is
  now one reused buffer. Found with the load test.
- As PID 1 in a container the data plane ignored SIGTERM, so `docker stop`
  waited for its kill timeout. It now drains and exits with status 0.
