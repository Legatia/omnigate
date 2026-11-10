# Changelog

All notable changes to omnigate are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). There are no
tagged releases yet; everything so far is under "Unreleased".

Which features have been checked against real providers, and which have
only met a mock, is tracked in the README's
[Known gaps](README.md#known-gaps) section rather than here.

## [Unreleased]

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
