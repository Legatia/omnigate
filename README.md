# omnigate

[![CI](https://github.com/Legatia/omnigate/actions/workflows/ci.yml/badge.svg)](https://github.com/Legatia/omnigate/actions/workflows/ci.yml)

A self-hostable AI gateway in two small processes. The data plane (Zig) is the port applications call: it fronts OpenAI- and Anthropic-style text APIs with gateway keys, limits, failover and protocol translation. The control plane (Elixir) owns configuration, keys, budgets and the usage ledger, and wraps image, video and speech providers in one async job API.

**Status (November 2026): pre-release. Nothing has run under production load, and no version has been tagged.** The text gateway and six of the seven media adapters have been checked by hand against the real provider APIs, and bucket storage against Cloudflare R2; the fal adapter has only met a mock. Everything added after those checks has only met the mock providers in the test suites: managed keys and the admin API, budget periods, the response cache, provider header passthrough, prompt-cache token accounting, provider-shaped errors, structured-output translation, ledger snapshots and retention. See [What has been verified](#what-has-been-verified) and [Known limits](#known-limits).

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
| `control/` | Elixir 1.20 / OTP 29 | Config, managed keys, prices, budgets, the usage ledger, media jobs, output storage, webhooks, dashboard, admin API, metrics |
| `config/` | JSON | Keys, upstreams, routes, media section, retention |
| `tools/` | Python (stdlib) | Mock providers, end-to-end test, SDK compatibility test, container test, load test, benchmark, LiteLLM config importer |
| `compose.yaml`, `deploy/` | Docker | Both images plus a Caddy proxy for TLS |

## Features

### Text gateway

- **Endpoints.** `POST /v1/chat/completions` and `POST /v1/messages`, streaming and not; `/v1/embeddings`, `/v1/responses`, `/v1/completions` and `/v1/messages/count_tokens` as same-protocol passthrough; `GET /v1/models` and `GET /v1/models/{id}`.
- **Protocol translation.** An OpenAI client can use a route served by an Anthropic-style upstream and the reverse, including streaming, tools, images and JSON-schema structured output. A route can mix both kinds as failover targets.
- **Provider differences absorbed.** An upstream's `v1_path` covers OpenAI-compatible providers that do not serve the API under `/v1` (Gemini uses `/v1beta/openai`). For translated requests, a model that refuses sampling parameters or demands a thought signature on earlier tool calls is retried with the fix, which is then remembered.
- **Failover** to the next target on connection errors, timeouts, 429 and 5xx, before any byte reaches the client, with one retry on a fresh connection first. Upstreams that keep failing are tried last for a while.
- **Load balancing.** `failover` (config order), `round_robin` or `weighted` per route; the other targets remain as failover.
- **Per-key limits.** A model list (403 for anything else), requests per minute (429 with `Retry-After`), and a budget that is total, monthly or daily (402 once spent; the key keeps read access to its models, jobs and files).
- **Usage metering** from the response stream without buffering it, with prompt-cache reads and writes counted and priced separately.
- **Usage that survives outages.** Events are spooled to disk, sent in batches with retries and deduplicated by request id in the ledger, so a call is billed once even if the control plane was down.
- **Response cache**, opt-in per route (`cache_ttl_s`): an identical non-streaming request from the same key is answered from memory, counted but not billed.
- **Looks like the provider to an SDK.** Gateway errors use each protocol's own envelope and type names, with the gateway's reason in `error.code`; responses carry `x-request-id` / `request-id`; a provider's rate-limit and retry headers are passed on by allowlist; a 429 from the last upstream reaches the client as 429.
- **Keeps serving text without the control plane**, including after a data-plane restart (the last config is cached on disk).
- **Holds up under hostile clients.** Timeouts for slow requests and stalled streams, a connection cap, and a graceful stop that finishes requests in flight and delivers queued usage.
- **Access log.** One line per request with key name, route, upstream, attempts, tokens, latency and request id; JSON lines on request.

### Media jobs

One async API in front of providers that each have a different one: `POST /v1/jobs`, `GET /v1/jobs/{id}`, `GET /v1/jobs`, `POST /v1/jobs/{id}/cancel`, `GET /v1/files/{job}/{name}`.

- **Adapters** for seven provider shapes: Replicate-style predictions, fal-style queues, OpenAI-style images, ElevenLabs-style text to speech, Gemini's native API for image and speech models, Gemini's Interactions API for its video-capable models, and xAI's video API.
- **Failover across providers** inside one job: a failed submit, a provider-side failure or a timeout moves on to the next target.
- **Output custody.** Each output is copied to a local directory or to your own S3-compatible bucket; job results carry your signed URLs, not the provider's expiring ones.
- **Webhooks that are signed and retried** ([Standard Webhooks](https://www.standardwebhooks.com/) headers, HMAC-SHA256, a backoff schedule), with delivery state on the job. A delivery connects to the address that passed the private-address check.
- **Idempotency keys**, **output caching** for identical requests, and **restart safety**: a job a provider already accepted resumes polling after a control-plane restart and is not submitted again.
- **One ledger.** Per-job, per-output, per-second and per-character prices land in the same ledger and budgets as tokens.

### Operations and admin

- **Dashboard and admin API** behind one admin token (a bearer token for scripts, a signed session cookie with CSRF protection for the browser). Never open by default: without `OMNIGATE_ADMIN_TOKEN` a random one is generated and logged.
- **Managed keys.** Create, change, disable, rotate and delete gateway keys from the dashboard or `/admin/keys`; a new key is shown once and stored as a hash. Keys in the config file keep working and are read-only there.
- **Audit log** of key changes and sign-ins, rotated by size.
- **Prometheus metrics** at `/metrics`: per-key requests, errors, tokens, cost, budget and blocked state; refused requests by reason; jobs and webhooks by state.
- **A ledger that stays bounded.** Usage events are written in segments with checksummed snapshots, so a start replays only what came after the last snapshot. Retention (off by default) can delete old segments while totals stay exact, along with finished jobs, their files (local and bucket) and old duplicate-detection ids.
- **Probes and credentials.** `GET /healthz` on both processes and `GET /readyz` on the control plane. Gateway keys, the data planes' internal token and the admin token do not work in each other's place.

## Quickstart

Prerequisites: Zig 0.17, Erlang/OTP 29 with Elixir 1.20, Python 3.9+. The full walk-through, with POSIX commands, the Windows `PATH` setup and a real provider, is in [docs/quickstart.md](docs/quickstart.md).

```bash
cd dataplane && zig build
```

```bash
python tools/e2e.py
```

The end-to-end test starts the mock providers, the control plane and the gateway on their own ports, with state in a temp directory, and exits non-zero if any check fails. It covers login and key management, failover and timeouts, load balancing, model limits, the response cache, streaming, translation, rate limits, the ledger and budgets, a control-plane outage with a gateway restart, and media jobs with failover, webhooks, caching, cancellation, a control-plane restart mid-job and bucket storage.

To run the pieces by hand, use four terminals from the repo root (PowerShell shown; run `mix deps.get` in `control/` before the first start):

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

Both processes need the same `OMNIGATE_INTERNAL_TOKEN` and refuse to start without it. `OMNIGATE_ADMIN_TOKEN` is the dashboard password and the `/admin` API token. A text request and a media job:

```bash
curl -N http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer og-unlimited-key" -d '{"model":"demo-chat","stream":true,"messages":[{"role":"user","content":"hi"}]}'
```

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer og-unlimited-key" -d '{"model":"demo-image","input":{"prompt":"a lighthouse"}}'
```

The dashboard is at <http://127.0.0.1:4000/>; sign in with the admin token set above. The demo routes and keys of `config/omnigate.dev.json` are listed in the [quickstart](docs/quickstart.md#demo-routes-and-keys).

Other suites: `zig build test --summary all` in `dataplane/`, `mix test` in `control/`, `python tools/test_import_litellm.py`, `python tools/sdk_compat.py` (the official OpenAI and Anthropic Python SDKs as clients, against the mocks) and `python3 tools/container_test.py --compose` (the Compose file through TLS); see [CONTRIBUTING.md](CONTRIBUTING.md#tests). Coming from LiteLLM, `python tools/import_litellm.py litellm.yaml -o config/omnigate.json --generate-key myapp` converts a proxy config; see [docs/migrating-from-litellm.md](docs/migrating-from-litellm.md).

## Running on a server

Container images and a Compose file with a Caddy proxy for TLS are included: copy `.env.example` to `.env` and `config/omnigate.example.json` to `config/omnigate.json`, fill in both, then `docker compose up -d --build`. Only the proxy publishes ports; the control plane and the internal API between the two processes stay on the private Docker network.

Without containers the same rules apply: set both tokens, keep the control plane on a private address, and put TLS in front of both ports. Tested with Docker 29 and Compose 2.40 on Ubuntu 24.04 (x86-64); not tested on ARM, with Let's Encrypt on a real domain, or on Kubernetes. What to back up, the readiness probe and upgrades are in [docs/deployment.md](docs/deployment.md).

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
- **Features not here yet:** latency- or cost-aware routing, guardrails, team and SSO management, tracing and log-export integrations (there is a Prometheus endpoint and a JSON access log), realtime voice, an admin UI for anything but keys (upstreams, routes and prices are edited in the config file).

## Measurements

**Load test.** `python tools/load_test.py` drives a running gateway with many concurrent clients, including ones that stall, disconnect mid-stream, send oversized or malformed bodies, or never send anything. On one machine (Windows 11, optimized build, Python mock upstream, 94 clients for 5 minutes):

- 669,000 requests at about 2,100 per second, with no malformed response, crash or hang.
- 635,318 usage events for 635,318 metered requests: none lost, none duplicated.
- Health checks stayed responsive throughout (p99 57 ms).
- Memory was flat at about 45 MB under load and returned to 42 MB afterwards.

The Python mock caps throughput at a few thousand requests per second, so this shows stability, not a ceiling. It was not run over TLS, against real providers, or with more than 550 concurrent connections.

**Added latency.** Same machine, localhost, optimized build (`zig build -Doptimize=ReleaseSafe`), `python tools/bench.py`, 4,000 non-streaming requests over 16 connections against the Python mock:

- Added latency at the median: about 0.5 ms (three runs: +0.48, +0.49, +0.56). At p95 and p99 the difference is inside the mock's own noise.
- Data plane memory under that load: about 13 MB. Binary: 1.9 MB.

This says the gateway is not a bottleneck in front of a mock. It is not a comparison with any other gateway; none was measured here. Both sets of figures were recorded before the response cache, prompt-cache accounting and provider-shaped errors were added, and have not been taken again since.

## What has been verified

Through the gateway, over TLS, with real keys (November 2026):

- **OpenAI**: chat completions (`gpt-4o-mini`, `gpt-5.4-mini`), streaming, embeddings, the Responses API, provider errors.
- **Anthropic**: messages (`claude-haiku-5-5`, `claude-opus-5-5` with thinking on), streaming, token counting, provider errors.
- **Translation both ways**: text, system prompts, streaming, tool calls and tool-result round trips, streamed tool calls, provider error shapes, refused sampling parameters.
- **Gemini** (`gemini-3.5-flash-lite`, `gemini-embedding-001`) through Google's OpenAI-compatible endpoint: chat, streaming, tool calls, embeddings, provider errors, failover to it, metering; and the same from an Anthropic-style client, translated.
- **xAI Grok** (`grok-4.20-0309-non-reasoning`) with no provider-specific code: chat, streaming, tool calls, the Responses API, failover, metering; translated from an Anthropic-style client; xAI's Anthropic-compatible endpoint as an `anthropic` upstream; and an image job (`grok-imagine-image`) through the `openai_images` adapter.
- **Failover** from a dead OpenAI-style upstream to Claude, with ledger token totals equal to what the providers reported.
- **Media jobs**, each generated, stored by the gateway and downloaded from it: OpenAI images (`gpt-image-1-mini`), Replicate (`black-forest-labs/flux-1.1-pro`), ElevenLabs speech (`eleven_flash_v2_5`), Gemini image and speech (`gemini-3.1-flash-lite-image`, `gemini-3.8-flash-lite-tts`), Gemini video through the Interactions API (`gemini-omni-1.2-flash`), xAI video (`grok-imagine-video-1.5-lite`). Webhooks were delivered for the OpenAI image (after a retry), Replicate and both video jobs; repeat speech requests were served from cache; an unknown model or voice failed with the provider's own reason at Replicate, xAI, Gemini and ElevenLabs.
- **Bucket storage on Cloudflare R2** (S3 API, region `auto`): upload under a key prefix, download through the presigned link, refusal without a valid signature, confirmed by an independently signed listing and read.

Not verified against anything real:

- The fal adapter (a mock written from public documentation; expect details to differ), and S3-compatible storage other than Cloudflare R2, including deleting bucket objects under retention.
- Everything the status paragraph lists as added later. In particular, the structured-output mapping onto Anthropic's `output_config.format` has not been sent to the live Anthropic API, and prompt-cache token accounting has not been compared with a real provider bill.
- The official SDKs against real providers: `tools/sdk_compat.py` runs the Python SDKs against the mocks only, and no other language's SDK has been tried.
- Replicate's `owner/name:version` form, job cancellation at a real provider, Gemini's Veo models (no adapter), xAI video with an input image, images in translated requests, long conversations, large payloads, and sustained or concurrent load against real providers.
- Platforms other than Windows 11 and x86-64 Linux (CI runs the unit, end-to-end, SDK and container suites on Ubuntu 24.04 for every push). macOS and ARM are untried.

## Known limits

The security model is in [SECURITY.md](SECURITY.md); the detail behind each line below is in [docs/operations.md](docs/operations.md) and [docs/architecture.md](docs/architecture.md).

- **No TLS listener** on either process; the included Caddy proxy (or another) provides it. Data-plane-to-control-plane traffic is plain HTTP and belongs on a private network.
- **One shared admin token.** No user accounts or roles, so the audit log records how a caller was authenticated and from where, not who they were; sessions cannot be revoked individually. The login lockout counts per client address, in memory.
- **A managed key's webhook secret is stored in clear text** in the keys file. Protect the data directory.
- **Budgets are enforced after the fact**: the call that crosses the budget completes, the block arrives one usage flush plus one config poll later, on a single control-plane node, and a key cannot be newly blocked during a control-plane outage.
- **Per-process state.** Rate limits, cooldowns, round-robin positions and the response cache live in each data-plane process and reset on restart; several data planes each allow the full rate limit. The response cache is exact-match only.
- **Translation covers chat completions and messages only.** It drops what the other protocol cannot express (thinking blocks, cache control, penalties and similar) and refuses audio and file parts; any other endpoint on a route whose upstreams all speak the other protocol answers 400 `endpoint_not_supported`.
- **Pricing gaps.** Reasoning tokens have no price of their own, and for media jobs the cost is the configured price of the target that delivered; provider charges for failed attempts are not recorded.
- **Client timeouts and threads.** A client that times out gets a closed connection, not a 408. The data plane uses one thread per connection; it has been soaked at 94 connections for five minutes and tried at 550 for two, and beyond that is untested.
- **Usage spool.** Appends are not fsynced, so a power loss can drop the last few events, and the spool holds at most 100,000 undelivered events. Counts of refused requests are kept in memory only.
- **Media jobs need the control plane** (during an outage `/v1/jobs` answers 503). A crash between a provider accepting a job and its id reaching disk, or during a synchronous provider call, resubmits that job. There are no per-upstream concurrency limits and no transcoding.
- **The media output cache is shared across gateway keys**, and two identical cacheable jobs submitted at the same moment both run.
- **Two error shapes on the jobs API.** Errors raised by the control plane keep its own shape (the reason in `error.type`), those raised by the data plane use the OpenAI shape (the reason in `error.code`); see [docs/api.md](docs/api.md#errors).
- **Ledger retention.** Once `retention.ledger_days` has deleted ledger segments, the two snapshot files hold the only copy of the totals those segments contributed, so back up the whole data directory. Deleting bucket objects under retention is best effort.
- **Metrics.** Each scrape scans the whole job store, and the output has been checked by tests, not by a real Prometheus server.
- **Zig 0.17 standard-library quirks worked around** in the data plane: `http.Client.fetch` panics on a reset keep-alive connection, `privileged_headers` are never sent, and `http.BodyWriter.flush` does not flush the body's own buffer.

## Documentation and license

[Quickstart](docs/quickstart.md) · [Configuration](docs/configuration.md) (every config field and environment variable) · [API reference](docs/api.md) (endpoints, errors, jobs, webhooks, the official SDKs) · [Admin](docs/admin.md) (dashboard, managed keys, budgets, audit log) · [Providers](docs/providers.md) · [Deployment](docs/deployment.md) · [Operations](docs/operations.md) (metrics, limits, retention, logs, troubleshooting) · [Architecture](docs/architecture.md) · [Migrating from LiteLLM](docs/migrating-from-litellm.md) · [Releasing](docs/releasing.md) · [docs index](docs/README.md) · [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) · [CHANGELOG.md](CHANGELOG.md)

There is no license file yet. Until there is one, no terms for use or redistribution have been granted; ask the maintainer before assuming any.
