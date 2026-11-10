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

Three commits (97cf396, fde530c, 3a0b147) fix what an independent review
of the code found in November 2026. Everything was found by reading the
code and small proofs of concept; **nothing is known to have been
exploited.** The full advisories, one per class, are in
[SECURITY.md](SECURITY.md#past-advisories).

**What to do, for everyone who ran an earlier commit:**

1. Update **both** processes to 3a0b147 or later. The fixes are on both
   sides.
2. If the control plane's port, or the dashboard's host name behind the
   Compose proxy, could be reached by anyone you do not trust: set a new
   admin token, delete managed gateway keys you did not create, rotate the
   gateway keys that were created or rotated in that time, and look in the
   audit log for key actions with `"auth": "none"`.
3. Compose users: split `.env` into `.env.control` and `.env.dataplane`
   (Compose will not start without them), and make sure the admin token is
   at least 16 characters long. See
   [docs/deployment.md](docs/deployment.md#coming-from-a-commit-before-3a0b147).
4. If you bill or budget from the ledger and hand gateway keys to parties
   you do not fully trust, compare the period before the update with your
   providers' invoices.

**What was wrong:**

- **Authentication bypass on the control plane (97cf396).** A request whose
  first path segment was percent-encoded (`/%61dmin/keys`,
  `/%69nternal/config`, `/%6Detrics`) skipped the admin-token,
  internal-token and CSRF checks and still reached its handler, because the
  checks looked at the path as sent while the router matched the decoded
  one.
  - *Who was affected:* anyone whose control plane, or dashboard host name,
    was reachable by someone they do not trust. Such a caller needed no
    credential to use the whole admin API (including creating, rotating and
    deleting gateway keys), to read `/metrics`, and to use `/internal/*`.
    The admin token, the internal token and provider keys were not
    revealed.
  - *The fix:* a path with any encoded character is refused with 400 before
    routing; an unknown first path segment is a 404 at the check; and
    credentials are checked before the body is parsed.
- **Remote crashes of the data plane (fde530c).** A header line without a
  colon, or a `POST` without a length, ended the gateway process with one
  unauthenticated request; JSON nested 256 levels deep did the same with a
  valid key. One process serves every connection, so each crash dropped
  every request in flight.
  - *Who was affected:* every deployment; the data plane is the public
    port. Nothing was disclosed.
  - *The fix:* request heads and JSON nesting are validated before any code
    that asserts on their shape; a panic, should one still happen, logs one
    line and exits with status 70.
- **Request smuggling into the internal API (fde530c).** The data plane
  pasted the client's request target into the URL of its call to the
  control plane and copied `Idempotency-Key` unchecked. A request line or
  header value with bare line feeds could carry a second request, or extra
  headers, which the gateway then sent to `/internal/*` with its own
  internal token.
  - *Who was affected:* deployments whose data plane was reachable by
    parties they do not trust. The path the regression test replays uses a
    valid gateway key; assume the keyless one (signed file URLs) was open
    too. Usage events could have been written under any key.
  - *The fix:* strict request heads, one canonical spelling per path, a
    small character set for query strings and copied headers, and a URL
    built from parsed parts.
- **Billing evasion (fde530c, 3a0b147).** A client that disconnected
  mid-stream was billed only what had been metered, usually nothing for an
  OpenAI-style stream. The usage scanner matched token-count keys anywhere
  in a response, including in text a client could get echoed. Media jobs
  were priced from the client's own `duration` and text fields, a negative
  duration lowered the price, and `POST /v1/jobs/` (with a trailing slash)
  created jobs without being rate limited.
  - *Who was affected:* operators who give gateway keys to parties they do
    not fully trust. A key holder could use provider capacity the ledger
    did not record.
  - *The fix:* abandoned streams are billed (real figures within
    `OMNIGATE_ABORT_DRAIN_MS`, an estimate otherwise); usage is read only
    from real usage objects; media cost follows what the adapter sent, with
    every part clamped at zero; job creation is rate-limited and capped in
    the control plane.
- **Server-side request forgery through provider outputs (3a0b147).** The
  control plane downloaded job outputs from whatever URL a provider's
  answer named, following redirects, with no check on the address. A
  steered answer could make it fetch an internal address and store the
  response as a downloadable job output. The private-address list used for
  webhooks also missed several IPv6 forms and special-purpose ranges.
  - *Who was affected:* deployments with media routes whose control plane
    can reach internal HTTP services, where job creators or a provider are
    not fully trusted.
  - *The fix:* output URLs go through the same guard as webhook URLs
    (resolve once, check every address, connect to the checked address),
    redirects are followed one checked hop at a time, at most five, and the
    list of refused ranges follows the IANA registries.
- **Other hardening from the same review (fde530c, 3a0b147).** Stored
  outputs are served as downloads with `nosniff` and a sandboxing
  `Content-Security-Policy` instead of inline with a provider-declared
  type; wrong admin bearer tokens are throttled; a short admin token stops
  the start; each container gets only its own secrets; a release build
  refuses to start without `OMNIGATE_CONFIG` instead of using the
  development config; learned provider quirks are per gateway key; log
  lines escape control bytes; the control plane speaks HTTP/1.1 only.

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
- `OMNIGATE_ABORT_DRAIN_MS` (5 s): after a client disconnects mid-response
  the data plane keeps reading the upstream this long, and at most 8 MiB,
  for the provider's final usage. `0` bills an estimate at once.
- Usage events carry `"estimated": true` when their token counts are an
  estimate, and the text access log marks such a line `usage=estimated`.
- Exit status 70 after a panic, with one log line (`error(panic): ...`), so
  a supervisor can tell it from a clean stop and from a startup error.

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
- `media.max_open_jobs` (100) and a per-key `max_open_jobs`: the number of
  unfinished media jobs a key may have at once. One more answers 429
  `too_many_open_jobs`. Settable in the config file and through
  `/admin/keys`; listings show the limit in force.
- `media.max_input_bytes` (1 MiB): the largest `input` and `metadata` of a
  job together; more answers 413.
- Job creation is rate-limited in the control plane as well, with the
  key's `rpm` in fixed one-minute windows (429 `rate_limit_exceeded`).
- `OMNIGATE_TRUST_FORWARDED`: count failed logins and wrong admin tokens
  per address in `X-Forwarded-For` instead of per connection, for a control
  plane that is only reachable through a proxy.
- Wrong admin bearer tokens are throttled: 20 from one address within a
  minute, then 429 `too_many_attempts` for that address until the minute
  is over.

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
- `tools/malformed_test.py`: a hostile-input suite. It replays the requests
  that used to crash the data plane or slip past a check, plus a few
  hundred generated (seeded) malformed request heads, asks `/healthz`
  after every one, and checks that a client which hangs up mid-stream is
  still billed. By default it starts its own stack through the end-to-end
  harness; `--gateway` points it at a running one, `--thorough` runs many
  more generated cases. CI runs it in a job of its own.
- `tools/check.py`: runs every check a change should pass (builds, unit
  tests, `zig fmt --check`, `mix format --check-formatted`, the importer
  tests, the end-to-end, SDK and hostile-input suites) with one command and
  a summary; `--quick` for unit tests and formatting only.
- `-Dstrip=true` for the data-plane build, used by `dataplane/Dockerfile`:
  the binary leaves its debug information out.
- An `x-request-id` header on every response of the control plane. A data
  plane relaying a client's request sends its own id along, so one id
  follows the request through both processes and is the `request_id` of a
  500 from either.
- `GET /admin/overview`: each recent request has its `id` and an
  `estimated` flag.
- `tools/container_test.py` also sends requests byte for byte through the
  TLS proxy: odd spellings of `/admin` and `/internal` paths, malformed and
  oversized requests to both hosts, the admin allow-list (a second proxy on
  port 18444), and that the data-plane container holds no admin token.
- `OMNIGATE_ADMIN_ALLOW` for the Compose proxy: CIDR ranges that may reach
  the dashboard host; everyone else gets 403. Open by default.
- `.env.control.example` and `.env.dataplane.example`, and
  `stop_grace_period` for both services in `compose.yaml`.
- `docs/security.md`, an operator's hardening guide, and one advisory per
  class of fixed vulnerability in `SECURITY.md`.

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
  The mapping is in `docs/api.md`.
- **One error shape everywhere.** Errors the control plane raises (for the
  jobs API and file downloads, and on its own port for the admin API,
  `/metrics` and `/internal/*`) have the same OpenAI-style envelope:
  `{"error": {"message", "type", "param", "code"}}`, with the reason in
  `error.code` and an OpenAI-style category in `error.type`. They used to
  be `{"error": {"type": "<reason>", "message"}}`. A client of the jobs API
  or a script against the admin API that read the reason from `error.type`
  must read `error.code`.
- When no target of a route succeeded and any of them answered 429, the
  client gets 429 `upstream_rate_limited` with the longest `retry-after`
  those targets sent. It used to get 502 `all_upstreams_failed` (and, for
  a few commits, 429 only when the last target tried was the rate-limited
  one).
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
- **Compose: secrets are split per container.** `compose.yaml` reads
  `.env.control` and `.env.dataplane` instead of giving one `.env` to both
  containers; `.env` now holds only the host names and
  `OMNIGATE_ADMIN_ALLOW`. An existing deployment must create the two files
  before it will start. Compose also sets `OMNIGATE_TRUST_FORWARDED=1` for
  the control plane.
- **An admin token shorter than 16 characters stops the control plane from
  starting.** It used to log a warning.
- **A release build of the control plane refuses to start without
  `OMNIGATE_CONFIG`.** Only development and test builds fall back to
  `config/omnigate.dev.json`.
- **The gateway refuses requests it used to accept.** A path must be in one
  canonical form (no percent-encoding, no trailing slash, no empty or dot
  segments) and a query string may only use a small character set, or the
  answer is 400 `invalid_request`. A malformed or ambiguous request head is
  400, a body without a length 411, an `Expect` other than `100-continue`
  417, a head over 16 KiB 431. JSON nested deeper than 64 levels is 400
  `invalid_json`. `Idempotency-Key`, `anthropic-version` and
  `anthropic-beta` values are limited to plain characters.
- **A response that ends early is billed.** A client that disconnects
  mid-stream is billed the provider's real usage when it arrives within
  `OMNIGATE_ABORT_DRAIN_MS`, and otherwise an estimate; so is a stream cut
  off by the idle timeout or by the upstream before its final usage.
  Earlier commits billed only what had been metered up to that point.
- **Media job cost is computed from what the adapter sent to the
  provider.** Per-character prices count the text fields the adapter
  forwards (for the adapters that forward the whole input: `prompt`, `text`
  and `input` added together), per-second prices the larger of `duration`
  and `seconds`, and only for the adapters that send a duration. A job with
  a negative or non-numeric duration or count is refused with 400, and a
  negative media price stops the config from loading.
- `retention.ledger_ids_days` defaults to 14 instead of keeping
  duplicate-detection ids for ever; an explicit `0` keeps the old
  behaviour.
- Stored outputs are served as attachments, with
  `x-content-type-options: nosniff` and a sandboxing
  `content-security-policy`, and with their stored content type only when
  it is on a short list of media types (`application/octet-stream`
  otherwise).
- The data plane passes on six headers of a control-plane answer by name:
  `content-disposition`, `x-content-type-options`,
  `content-security-policy` and `cache-control` on a stored file,
  `location` on the redirect to a bucket-stored file, and `retry-after` on
  a 429. It used to pass on none of them, so the redirect had no target and
  a job-creation 429 from the control plane no `Retry-After`.
- Numeric environment variables are read strictly in both processes:
  digits only for the data plane's settings, a well-formed number in range
  for `OMNIGATE_CONTROL_PORT` and `OMNIGATE_AUDIT_MAX_MB`. A bad value
  stops the process at startup with a message that names the variable; it
  used to be half-read, or replaced by a default without a word. A variable
  that is set but empty counts as unset.
- The data plane refuses a job request body over 8,000,000 bytes itself,
  with the answer the control plane would give, instead of sending it
  across first.
- `x-request-id` and `request-id` never disagree: when a provider sent
  only one of the two, that id goes into both.
- `retention.ledger_days` also takes effect on an installation that records
  nothing after a restart: the sweep writes the second snapshot generation
  itself instead of waiting for one.
- A managed key shadowed by a config-file key of the same name is listed
  in the dashboard and in `GET /admin/overview`, with the state `shadowed`.
- The control image's health check has a start period of 120 seconds
  instead of 20, for a first start that replays a large ledger.
- The outbound `user-agent` of both processes carries the version from
  `dataplane/build.zig.zon` and `control/mix.exs` (`omnigate/0.1.0`,
  `omnigate-webhooks/0.1.0`) instead of a hand-written `0.1`.
- Provider output downloads resolve the host once, refuse non-public
  addresses and connect to the checked address, like webhooks; redirects
  are followed by the control plane itself, at most five.
  `media.webhooks.allow_private` now governs these downloads too.
- `jobs.jsonl`: a job's later changes are appended as patch lines with only
  the changed fields, instead of full copies of the job. Older files are
  read as before; older code cannot read the new lines.
- Learned provider quirks (refused sampling parameters, thought
  signatures) are remembered per gateway key, not shared across keys.
- The usage scanner reads token counts only from usage objects at the
  places the protocols define, not from matching text anywhere in a
  response.
- `POST /login` and `POST /logout` accept a body of at most 4,096 bytes,
  and the control plane's listener speaks HTTP/1.1 only.
- The data plane's text log escapes control bytes in client-supplied text
  and never logs a query string.
- CI has a seventh job, `hostile`, for `tools/malformed_test.py`, and the
  container test uses a second local port (18444).

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
- A client that was refused before its request body had been read (a bad
  key on a `POST`, for example) could see a reset connection instead of the
  answer. The data plane now finishes its side, reads and discards what
  the client is still sending for a short time, and then closes.
- A connection whose answer said `connection: close` was held open until
  the client timeout. It is closed at once.
- A client that requested a large stored file and then stopped reading
  held its connection for ever; the stream idle timeout now covers the
  gateway's own answers and file downloads.
