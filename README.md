# omnigate

[![CI](https://github.com/Legatia/omnigate/actions/workflows/ci.yml/badge.svg)](https://github.com/Legatia/omnigate/actions/workflows/ci.yml)

A self-hostable AI gateway in two small processes. It fronts OpenAI- and
Anthropic-style text APIs and wraps image, video and speech providers in one
async job API.

**Status: the text gateway and the OpenAI image, ElevenLabs speech,
Replicate, Gemini (image, speech, video) and xAI video adapters have been
checked against the real APIs, and bucket storage against Cloudflare R2
(November 2026). The fal adapter has only met a mock, and nothing has run
under production load.** See [Known gaps](#known-gaps).

```
 apps ──▶ dataplane (Zig) ──────────▶ LLM providers (OpenAI-style, Anthropic-style)
            ▲   │  │
     config │   │  └─ /v1/jobs, /v1/files ─┐
            │   ▼ usage events             ▼
          control (Elixir) ── ledger · budgets · jobs · webhooks ──▶ media providers
                                                     └──▶ your bucket (S3 API) or local disk
```

| Part | Language | Job |
|---|---|---|
| `dataplane/` | Zig 0.17 | The public port. Authenticates keys, rate-limits, routes, fails over, translates protocols, streams, meters tokens |
| `control/` | Elixir 1.20 / OTP 29 | Config, prices, budgets, the usage ledger, media jobs, output storage, webhooks, dashboard |
| `config/` | JSON | Keys, upstreams, routes, media section |
| `tools/` | Python (stdlib) | Mock providers, end-to-end test, container test, benchmark, LiteLLM config importer |
| `compose.yaml`, `deploy/` | Docker | Both images plus a Caddy proxy for TLS |

## What it does

### Text gateway

- `POST /v1/chat/completions` and `POST /v1/messages`, streaming and non-streaming. Also `/v1/embeddings`, `/v1/responses`, `/v1/completions` and `/v1/messages/count_tokens` as same-protocol passthrough. `GET /v1/models`, `GET /healthz`.
- **Protocol translation.** An OpenAI client can use a route served by an Anthropic upstream and the reverse, including streaming, tools and images. A route can mix both kinds as failover targets.
- **OpenAI-compatible providers at any path.** Gemini, Groq, Mistral, OpenRouter and others speak the OpenAI protocol; an upstream's `v1_path` covers the ones that do not serve it under `/v1` (Gemini uses `/v1beta/openai`).
- **Provider quirks handled for translated requests.** Current Claude models refuse `temperature` and `top_p`; Gemini 3 and later demand a "thought signature" on earlier tool calls. A client speaking the other protocol cannot know either rule, so when a translated request is refused for one of them the gateway retries with the fix and remembers it for that model.
- **Failover** to the next target on connection errors, timeouts, 429 and 5xx, before any byte reaches the client. One retry on a fresh connection first, in case a pooled connection went stale.
- **Timeouts.** Max wait for response headers, global or per upstream.
- **Cooldowns.** An upstream that fails five times in a row is tried last for 30 seconds, so a dead provider costs one timeout, not one per request.
- **Load balancing.** A route tries its targets in order by default; set `strategy` to `round_robin` to rotate the starting target, or `weighted` to pick it in proportion to each target's `weight`. The other targets remain as failover either way.
- **Per-key model limits.** A key can be restricted to a list of models (`models`); anything else is a 403, and its model list shows only what it may use. The same list applies to media jobs.
- **Rate limits** per key (requests per minute), answered with 429 and `Retry-After`.
- **Budgets** per key: the control plane marks an overspent key blocked and the data plane answers 402.
- **Usage metering** from the response stream without buffering it. If the client did not ask for the OpenAI usage chunk, the gateway asks for it anyway and hides it from the client.
- **Usage that survives outages.** Events are spooled to disk on the data plane, sent in batches with retries, and deduplicated by request id in the ledger, so a call is billed once even if the control plane was down when it happened.
- **Keeps serving without the control plane**, including after a data-plane restart (last config is cached on disk).
- **Holds up under hostile clients.** Idle connections, half-sent requests and stalled streams are cut off by timeouts; connections are capped; on a stop signal the gateway finishes in-flight requests, delivers queued usage and exits cleanly.
- **Access log.** One line per request with key name, route, upstream, attempts, tokens and latency; `OMNIGATE_LOG_FORMAT=json` for log shippers.
- Response headers: `x-omnigate-upstream`, `x-omnigate-attempts`, `x-omnigate-request-id`.

### Control plane access

- **Dashboard login.** The dashboard asks for the admin token once and then uses a signed session cookie (12 hours, `HttpOnly`, `SameSite=Strict`).
- **Admin API.** `/admin/*` takes the same token as `Authorization: Bearer`.
- **Never open by default.** If `OMNIGATE_ADMIN_TOKEN` is not set, a random one is generated at startup and written to the log.
- **Guessing is slowed.** Five failed logins from one address lock that address out for a minute.
- **Key management.** Create, rotate, disable and delete gateway keys from the dashboard or the admin API (`/admin/keys`), with budget, rate limit and model limits per key. A new key is shown once and stored only as a hash. Data planes pick changes up within seconds. Keys in the config file keep working and are read-only there.
- **Dashboard.** Spend against budget per key, today and total figures, recent requests and media jobs, and a read-only view of the configuration without secrets. It updates live, works without external assets, and protects changes with CSRF tokens.
- **Metrics.** `GET /metrics` serves Prometheus text format behind the admin token: per-key requests, errors, tokens, jobs, cost, budget and blocked state; media jobs by status; webhook deliveries by state; ledger size; config reloads; uptime.
- **Retention.** With a `retention` section in the config, finished jobs and their locally stored files are removed after `jobs_days`, and the ledger's duplicate-detection ids after `ledger_ids_days`. Off by default: nothing is deleted unless you set it.
- **Separate credentials.** Gateway keys, the data planes' internal token and the admin token do not work in each other's place.

### Media jobs

One API for providers that each have a different one:

```
POST /v1/jobs            {model, input, webhook_url?, metadata?, cache?}   -> 202 + job
GET  /v1/jobs/{id}       status: queued | running | succeeded | failed | canceled
GET  /v1/jobs?limit=N    this key's jobs, newest first
POST /v1/jobs/{id}/cancel
GET  /v1/files/{job}/{name}?exp=&sig=    re-hosted output (signed URL, or the owning key)
```

- **Adapters** for seven provider shapes: Replicate-style predictions, fal-style queues, OpenAI-style synchronous images, ElevenLabs-style text-to-speech, Gemini's native API for its image and speech models (raw PCM speech is stored as a playable WAV), Gemini's Interactions API for its video-capable "omni" models, and xAI's video API.
- **Failover across providers.** Targets are tried in order; a failed submit, a provider-side failure or a timeout moves on.
- **Output custody.** Each output is downloaded and stored in a local directory or in your own S3-compatible bucket (SigV4). Job results carry your URLs, signed, not the provider's expiring ones.
- **Webhooks that are signed and retried.** [Standard Webhooks](https://www.standardwebhooks.com/) headers, HMAC-SHA256, a backoff schedule, delivery state on the job. Deliveries survive a restart.
- **Idempotency.** `Idempotency-Key` returns the existing job; reuse with a different body is a 409.
- **Restart-safe.** Job state is on disk. A job already accepted by a provider resumes polling after a control-plane restart; it is not submitted again.
- **Caching.** With `cache: true` or a route `cache_ttl_s`, an identical request reuses the stored output: no provider call, no charge.
- **One ledger.** Per-job, per-output, per-second and per-character prices land in the same ledger and budgets as tokens.

## Documentation

Guides live in [`docs/`](docs/README.md): [quickstart](docs/quickstart.md),
[configuration](docs/configuration.md), [API](docs/api.md),
[providers](docs/providers.md), [deployment](docs/deployment.md),
[operations](docs/operations.md), [architecture](docs/architecture.md) and
[migrating from LiteLLM](docs/migrating-from-litellm.md).

## Try it

Prerequisites: Zig 0.17, Erlang/OTP 29 with Elixir 1.20, Python 3.9+.

```bash
cd dataplane && zig build
```

```bash
python tools/e2e.py
```

The end-to-end test starts the mock providers, the control plane and the
gateway on their own ports with state in a temp directory, runs its checks
(failover, timeouts, streaming, translation, rate limits, budgets, an outage
with a gateway restart, media jobs with failover, webhooks, cache, a
control-plane restart mid-job, bucket storage) and exits non-zero if any fail.
It currently runs 110 checks.

### Run the pieces by hand

On Windows, Erlang and Elixir are installed but not on `PATH`. In PowerShell, per session:

```powershell
$env:Path = 'C:\Program Files\Erlang OTP\bin;C:\Program Files\Elixir\bin;' + $env:Path
```

Four terminals, from the repo root:

```powershell
python tools/mock_upstream.py
```

```powershell
python tools/mock_media.py
```

```powershell
cd control; $env:OMNIGATE_INTERNAL_TOKEN='dev-internal-token'; $env:OMNIGATE_ADMIN_TOKEN='dev-admin-token-change-me'; $env:MOCK_API_KEY='mock-secret'; mix run --no-halt
```

```powershell
cd dataplane; $env:OMNIGATE_INTERNAL_TOKEN='dev-internal-token'; $env:MOCK_API_KEY='mock-secret'; .\zig-out\bin\omnigate-dp.exe
```

Then, for example:

```bash
curl -N http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer og-unlimited-key" -d '{"model":"demo-chat","stream":true,"messages":[{"role":"user","content":"hi"}]}'
```

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer og-unlimited-key" -d '{"model":"demo-image","input":{"prompt":"a lighthouse"}}'
```

Dashboard: <http://127.0.0.1:4000/>, signing in with the admin token set above. Demo routes in `config/omnigate.dev.json`:

| Route | Shows |
|---|---|
| `demo-chat` | First upstream always answers 503, so every call fails over |
| `demo-claude` | Anthropic-style upstream; call it with either protocol |
| `demo-slow` | First upstream takes 3 s and is abandoned after 1 s |
| `demo-direct` | One healthy upstream, for benchmarks |
| `demo-image`, `demo-video`, `demo-image-sync`, `demo-tts` | Media jobs on four of the adapters (Replicate, fal, OpenAI images, ElevenLabs shapes); `demo-image` fails over, `demo-tts` is cached |

Keys: `og-unlimited-key`, `og-dev-key` ($0.01 budget, blocked after four calls), `og-ratelimited-key` (5 requests per minute).

### Tests

```powershell
cd dataplane; zig build test --summary all
```

```powershell
cd control; mix test
```

```powershell
python tools/test_import_litellm.py
```

## Coming from LiteLLM

```bash
python tools/import_litellm.py litellm.yaml -o config/omnigate.json --generate-key myapp
```

Converts `model_list` to routes (entries sharing a `model_name` become ordered
failover targets), `fallbacks`, per-token prices and timeouts. OpenAI,
Anthropic, Gemini, Groq, Mistral, DeepSeek, OpenRouter, Together, Fireworks,
xAI and Perplexity entries are mapped. Literal API keys
in the YAML are never copied: the tool prints the environment variable to set
instead. Providers with their own API shape (Azure, Bedrock, Vertex and so
on) are listed as skipped. Virtual keys and
budgets live in LiteLLM's database and are not imported.

## Configuration

One JSON file, hot-reloaded by the control plane every 2 s. See
`config/omnigate.example.json` for a real-provider template.

- `keys[]`: `name`, `key` (raw; hashed on load) or `key_sha256`, `budget_usd`, `rpm`, `models` (list of route names the key may use; absent = all), `webhook_secret` or `webhook_secret_env`.
- `upstreams[]`: `name`, `kind` (`openai` or `anthropic`), `base_url`, `api_key_env`, `timeout_ms`, `v1_path` (only for providers whose API is not under `/v1`).
- `routes[]`: `model`, `strategy` (`failover` by default, `round_robin` or `weighted`), ordered `targets[]` of `upstream`, `model`, `weight` (for `weighted`; default 1), `price_in_per_mtok`, `price_out_per_mtok`.
- `retention`: `jobs_days`, `ledger_ids_days` (days, fractions allowed; absent or 0 = keep forever).
- `media`: `public_base_url`, `upstreams[]` (`kind`: `replicate`, `fal`, `openai_images`, `elevenlabs`, `gemini`, `gemini_interactions`, `xai_video`), `routes[]` (`targets[].price` with `per_job_usd`, `per_output_usd`, `per_second_usd`, `per_input_char_usd`; `cache_ttl_s`; `timeout_s`), `storage` (`local` or `s3`), `webhooks` (`secret`, `retry_schedule_ms`, `max_attempts`, `allow_private`).

Provider secrets are never in the file: each upstream names an environment
variable. Text upstream keys are read by the data plane, media upstream keys
and bucket credentials by the control plane.

| Variable | Used by | Default |
|---|---|---|
| `OMNIGATE_INTERNAL_TOKEN` | both | required; shared secret for `/internal/*` |
| `OMNIGATE_LISTEN` | data plane | `127.0.0.1:8080` |
| `OMNIGATE_CONTROL_URL` | data plane | `http://127.0.0.1:4000` |
| `OMNIGATE_POLL_MS` | data plane | `2000`; config poll interval |
| `OMNIGATE_FLUSH_MS` | data plane | `500`; how often queued usage is sent |
| `OMNIGATE_UPSTREAM_TIMEOUT_MS` | data plane | `600000`; max wait for upstream headers, `0` = none |
| `OMNIGATE_COOLDOWN_FAILURES` | data plane | `5`; consecutive failures before an upstream is tried last, `0` = off |
| `OMNIGATE_COOLDOWN_MS` | data plane | `30000` |
| `OMNIGATE_SPOOL` | data plane | `omnigate-usage.spool`; `off` keeps usage in memory only |
| `OMNIGATE_CLIENT_TIMEOUT_MS` | data plane | `30000`; time allowed for a request head and body, and for an idle keep-alive connection; `0` = off |
| `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` | data plane | `300000`; a response stream silent this long is cut and billed for what was metered; `0` = off |
| `OMNIGATE_MAX_CONNECTIONS` | data plane | `4096`; beyond it, an immediate 503 |
| `OMNIGATE_SHUTDOWN_GRACE_MS` | data plane | `10000`; time for in-flight requests after a stop signal |
| `OMNIGATE_LOG_LEVEL` | data plane | `info` (`debug`, `info`, `warn`, `error`) |
| `OMNIGATE_LOG_FORMAT` | data plane | `text`; `json` gives one object per line |
| `OMNIGATE_KEYS` | control plane | `data/keys.json`; keys created through the admin API (hashes only) |
| `OMNIGATE_CONFIG_CACHE` | data plane | `omnigate-config.cache.json`; `off` disables |
| `OMNIGATE_ADMIN_TOKEN` | control plane | generated and logged at startup if unset; dashboard password and `/admin` API token |
| `OMNIGATE_CONTROL_BIND` | control plane | `127.0.0.1`; set an address such as `0.0.0.0` to accept connections from other machines |
| `OMNIGATE_COOKIE_SECURE` | control plane | unset; `1` always marks the session cookie `Secure` (automatic behind a proxy that sends `X-Forwarded-Proto: https`) |
| `OMNIGATE_CONTROL_PORT` | control plane | `4000` |
| `OMNIGATE_CONFIG` | control plane | `../config/omnigate.dev.json` |
| `OMNIGATE_LEDGER` | control plane | `data/ledger.jsonl` |
| `OMNIGATE_MEDIA_DIR` | control plane | `data/media`; where local output storage keeps files unless the config names a `dir` |
| `OMNIGATE_JOBS` | control plane | `data/jobs.jsonl` |
| `OMNIGATE_SIGNING_SECRET` | control plane | derived from the internal token; signs file URLs |
| `OMNIGATE_WEBHOOK_SECRET` | control plane | last-resort webhook signing secret |

## Running it on a server

Container images and a Compose file with TLS in front are included.

```bash
cp .env.example .env
```

```bash
cp config/omnigate.example.json config/omnigate.json
```

Fill in both files (two long random tokens, your host names, provider keys, routes), then:

```bash
docker compose up -d --build
```

What you get:

- **`proxy`** (Caddy) is the only container with published ports. It serves the gateway at `https://$OMNIGATE_API_HOST` and the dashboard at `https://$OMNIGATE_ADMIN_HOST`. Real DNS names get Let's Encrypt certificates automatically; the `localhost` defaults get certificates from Caddy's own CA.
- **`dataplane`** is a 13 MB image: one static binary and a CA bundle on an empty base, running as a non-root user.
- **`control`** is a 57 MB Alpine image with the Elixir release, running as a non-root user, with a health check.
- **State** (ledger, jobs, stored outputs, usage spool, config cache) lives in named volumes and survives restarts.
- **The internal API** between the two is reachable only on the private Docker network; the proxy answers 404 for `/internal/*`.

`python3 tools/container_test.py --compose` brings up this Compose file (with
mock providers added and a throwaway config) and runs 22 checks through TLS: certificate
verification, failover, incremental streaming through the proxy, translation,
a media job with a signed `https` download and a retried webhook, dashboard
login with a `Secure` cookie, and restarts with the control plane down.

Without `--compose` the same test runs with plain `docker` commands, for
machines that have no Compose plugin.

Tested with Docker 29 and Compose 2.40 on Ubuntu 24.04 (x86-64, under WSL 2),
both ways. The test publishes one local port instead of 80 and 443 and uses
its own env file and config. Not tested: ARM, Let's Encrypt issuance with a
real domain, and Kubernetes.

Without containers, the same rules apply: set both tokens, keep the control
plane on a private address (`OMNIGATE_CONTROL_BIND`), and put TLS in front of
both ports.

## How it compares

Checked against public documentation in November 2026. These products change
quickly and "not documented" is not proof of absence, so verify before relying
on a row.

| | omnigate | LiteLLM (OSS) | Cloudflare AI Gateway | Bifrost (OSS) |
|---|---|---|---|---|
| Media jobs: completion webhooks | Signed, retried, restart-safe | None; poll only [1] | Best effort, not retried [2] | Signed (vendor's claim) [2] |
| Media outputs re-hosted to your storage | Yes (local or S3 API) | Not documented | Not documented | Not documented |
| Media output caching (e.g. repeated TTS) | Yes | Not documented | Not documented | Not documented |
| Cross-provider failover inside one media job | Yes | Not documented | Tied to a deprecated endpoint [2] | Yes (vendor's claim) [2] |
| Usage recorded for calls made while the control/DB side is down | Yes, spooled and deduplicated | Not checked | n/a (hosted) | Not checked |
| Extra services to run | None (two binaries, files on disk) | Postgres for keys and spend, Redis for multi-instance limits | n/a (hosted) | Not checked |
| Runtime dependencies | Zig std; Elixir with 2 direct Hex packages | Large PyPI tree; two supply-chain compromises in 2026 [3] | n/a | Not checked |

[1] [LiteLLM video docs](https://docs.litellm.ai/docs/videos) ·
[2] [Maxim AI survey](https://www.getmaxim.ai/articles/ai-gateways-for-image-and-video-generation.md) (published by Bifrost's vendor) ·
[3] [Datadog Security Labs](https://securitylabs.datadoghq.com/articles/litellm-compromised-pypi-docker.md)

Where the others are ahead today, plainly:

- **Provider coverage.** They speak to dozens or hundreds of providers natively. omnigate speaks two text protocols (which reaches every OpenAI-compatible provider, Gemini included) and seven media shapes. Azure, Bedrock and Vertex are not reachable.
- **Production mileage.** They run real traffic. omnigate has passed scripted checks against a handful of real providers and has never served production traffic.
- **Features not here yet:** latency- or cost-aware routing, response caching for text, guardrails, team and SSO management, tracing and log-export integrations (there is a Prometheus endpoint), realtime voice, an admin UI beyond a read-only dashboard.

### Load test

`python tools/load_test.py` drives a running gateway with many concurrent
clients, including ones that stall, disconnect mid-stream, send oversized or
malformed bodies, or never send anything. On this machine (Windows 11,
optimized build, Python mock upstream, 94 clients for 5 minutes):

- 669,000 requests at about 2,100 per second, with no malformed response, crash or hang.
- 635,318 usage events for 635,318 metered requests: none lost, none duplicated.
- Health checks stayed responsive throughout (p99 57 ms).
- Memory was flat at about 45 MB under load and returned to 42 MB afterwards.

The Python mock caps throughput at a few thousand requests per second, so this
shows stability, not a ceiling. It was not run over TLS, against real
providers, or with more than 550 concurrent connections.

### Measured on this machine

Windows 11, localhost, optimized build (`zig build -Doptimize=ReleaseSafe`),
`python tools/bench.py`, 4,000 non-streaming requests over 16 connections
against the Python mock:

- Added latency at the median: about 0.5 ms (three runs: +0.48, +0.49, +0.56). At p95 and p99 the difference is inside the mock's own noise.
- Data plane memory under that load: about 13 MB. Binary: 1.9 MB.

This says the gateway is not a bottleneck in front of a mock. It is not a
comparison with any other gateway; none was measured here.

## Known gaps

**Verified against real providers (November 2026)**

Through the gateway, over TLS, with real keys:

- OpenAI: chat completions (`gpt-4o-mini`, `gpt-5.4-mini`), streaming, embeddings, the Responses API, provider errors.
- Anthropic: messages (`claude-haiku-5-5`, `claude-opus-5-5` with thinking on), streaming, token counting, provider errors.
- Translation both ways: text, system prompts, streaming, tool calls, tool-result round trips, streamed tool calls, error shapes, refused sampling parameters.
- Gemini (`gemini-3.5-flash-lite`, `gemini-embedding-001`) through Google's OpenAI-compatible endpoint: chat, streaming, tool calls and round trips, embeddings, provider errors, failover to it, metering; and the same from an Anthropic-style client, translated.
- Failover from a dead OpenAI-style upstream to Claude; ledger token totals equal to what the providers reported.
- One media job on OpenAI's image API (`gpt-image-1-mini`): generated, re-hosted, downloaded, webhook retried and delivered.
- Replicate (`black-forest-labs/flux-1.1-pro`): prediction created and polled to completion, the image copied off Replicate and downloaded from the gateway, webhook delivered; an unknown model and an out-of-credit model failed with Replicate's own reasons.
- xAI Grok (`grok-4.20-0309-non-reasoning`, `grok-imagine-image`) with no provider-specific code: chat, streaming, tool calls and round trips, the Responses API, provider errors, failover, metering; the same from an Anthropic-style client, translated; xAI's own Anthropic-compatible endpoint as an `anthropic` upstream; and an image job through the `openai_images` adapter.
- Bucket storage on Cloudflare R2 (S3 API, region `auto`): a job's output uploaded under a key prefix, downloaded through the presigned link, refused without a signature or with a tampered one, and confirmed by an independently signed listing and read.
- xAI video (`grok-imagine-video-1.5-lite`): a one-second clip submitted, polled to completion, copied off xAI and downloaded from the gateway as an MP4, billed per second, webhook delivered; an unknown model failed with xAI's reason.
- Gemini video (`gemini-omni-1.2-flash`, through the Interactions API): a short clip generated in one call, stored and downloaded from the gateway as an MP4, webhook delivered.
- Gemini media (`gemini-3.1-flash-lite-image`, `gemini-3.8-flash-lite-tts`): an image and a spoken sentence generated, stored and downloaded from the gateway; the repeat speech request served from cache; an unknown model failed with Google's reason.
- ElevenLabs text-to-speech (`eleven_flash_v2_5`): real MP3 generated, re-hosted and downloaded; an identical request served from cache; an unknown voice failed with the provider's reason.

**Not verified**

- The fal adapter has only run against a mock written from public documentation; expect details to differ.
- S3-compatible storage other than Cloudflare R2 (Amazon S3 itself, Backblaze B2, MinIO and so on).
- Replicate's `owner/name:version` form and job cancellation at a real provider.
- Gemini's Veo models, which have their own job API and no adapter yet (the test key had no access to them); background interactions on Gemini's Interactions API; xAI video with an input image, and its failed and expired states.
- Images in translated requests, long conversations, large payloads, and the official OpenAI and Anthropic SDKs as clients (the checks used plain HTTP).
- Sustained or concurrent load against real providers.
- Platforms other than Windows 11 and x86-64 Linux (CI runs the unit, end-to-end and container suites on Ubuntu 24.04 for every push). macOS and ARM are untried.

**Security**

- No TLS listener on either process; the included Caddy proxy (or another) provides it. Data-plane-to-control-plane traffic over HTTPS is untested; keep it on a private network.
- A managed key's webhook secret is stored in plain text in the keys file, because signing needs it. Protect the data directory.
- One shared admin token: no user accounts, roles or audit log. Sessions cannot be revoked individually; changing the token ends all of them.
- The login lockout counts per client address and lives in memory. Behind a reverse proxy all clients share one address.
- Webhook targets are resolved once per delivery, checked against private addresses, and connected to at the checked address, which closes DNS rebinding. Redirects are not followed.
- Budgets are totals over the whole ledger and never reset; there is no monthly or daily period yet. A key over budget gets 402 on every request, including polling its own jobs.
- Requests the gateway refuses before routing (bad key, rate limit, disallowed model) are not written to the ledger, so they do not appear in metrics or the dashboard.
- Provider response headers other than content type and length are not passed to clients.

**Text gateway**

- Rate limits and cooldowns are per data-plane process and reset on restart. Budgets are enforced after the fact, with up to one poll interval of lag, on a single control-plane node, and cannot newly block a key during a control-plane outage.
- The data plane uses one thread per connection, about two under load. It has been soaked at 94 connections for five minutes and tried at 550 for two; beyond that is untested.
- A client that times out gets a closed connection, not a 408 response.
- Load balancing is round-robin or weighted only, with state per data-plane process; nothing is latency-aware. No response caching, no idle timeout once a response has started streaming.
- For text endpoints the request body is now read before the rate-limit check (so that a disallowed model is a 403, not a 429), which means a key over its limit still costs one body read.
- Translation drops what the other protocol cannot express (thinking blocks, cache control, `response_format`, penalties and similar) and rejects audio and file parts. `/v1/embeddings`, `/v1/responses` and `/v1/completions` are not translated.
- Cached-token and reasoning-token prices are not modelled; cost is input and output tokens only.
- Spool appends are not fsynced, so a power loss can drop the last few usage events. The spool holds at most 100,000 undelivered events.

**Media jobs**

- A crash between a provider accepting a job and its id reaching disk, or during a synchronous provider call, resubmits that job.
- Cost is the configured price of the target that delivered. Provider charges for failed attempts are not recorded or reconciled.
- Retention is off unless configured. When on, it removes finished jobs, their local files and old ledger ids; it does not delete objects in a bucket (use the bucket's lifecycle rules) and does not trim the ledger file itself. A data-plane resend older than `ledger_ids_days` would be counted twice.
- Each metrics scrape scans the whole job store; the output has been checked by tests, not by a real Prometheus server.
- The cache is shared across gateway keys. Two identical cacheable jobs submitted at the same moment both run.
- No per-upstream concurrency limits. Output downloads send no provider credentials. No transcoding.
- Job requests need the control plane: during an outage `/v1/jobs` answers 503.

**Zig 0.17 standard-library quirks worked around**

- `http.Client.fetch` panics on a reset keep-alive connection.
- `privileged_headers` are never sent.
- `http.BodyWriter.flush` does not flush the body's own buffer.

## Next

1. Run the fal adapter against the real service; test bucket storage on Amazon S3; test with the official SDKs as clients
2. Test ARM images and a real-domain certificate
3. Cluster-wide budgets and rate limits across control-plane nodes
4. Ledger rotation, and deleting expired objects from buckets
5. More provider shapes (Veo, Kling, Runway, BFL), then transcoding
6. Realtime voice through a partner stack (LiveKit, Pipecat)
