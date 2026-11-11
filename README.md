# omnigate

[![CI](https://github.com/Legatia/omnigate/actions/workflows/ci.yml/badge.svg)](https://github.com/Legatia/omnigate/actions/workflows/ci.yml)

A self-hostable AI gateway in two small processes. The data plane (Zig) is the port applications call: it fronts OpenAI- and Anthropic-style text APIs with gateway keys, limits, failover and protocol translation. The control plane (Elixir) owns configuration, keys, budgets and the usage ledger, and wraps image, video and speech providers in one async job API.

**Status (November 2026): pre-release. Nothing has run under production load, and no version has been tagged.** The text gateway and six of the eight media adapters have been checked by hand against the real provider APIs, and bucket storage against Cloudflare R2; the fal and Sume adapters have only met a mock. Everything added after those checks has only met the mock providers in the test suites: managed keys and the admin API, budget periods, the response cache, provider header passthrough, prompt-cache token accounting, provider-shaped errors, structured-output translation, ledger snapshots and retention, and the security fixes of November 2026 (strict request parsing, limits before a body is read, the gateway's own response framing, billing of abandoned streams, address checks on provider outputs, capped outbound responses). Those fixes closed an authentication bypass, remote crashes, resource exhaustion by a valid key and more, and the last two of them (commits e4e30e4 and d79406b) replaced the code that reads every provider response in both processes: if you ran an earlier commit, read [SECURITY.md](SECURITY.md#past-advisories) and [docs/upgrading.md](docs/upgrading.md). See [What has been verified](#what-has-been-verified) and [Known limits](#known-limits).

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
| `tools/` | Python (stdlib) | Mock providers, end-to-end test, SDK compatibility test, container test, hostile-input test, a one-command runner for all of them (`check.py`), load test, benchmark, LiteLLM config importer |
| `compose.yaml`, `deploy/` | Docker | Both images plus a Caddy proxy for TLS, with one environment file per container |

## Features

### Text gateway

- **Endpoints.** `POST /v1/chat/completions` and `POST /v1/messages`, streaming and not; `/v1/embeddings`, `/v1/responses`, `/v1/completions` and `/v1/messages/count_tokens` as same-protocol passthrough; `GET /v1/models` and `GET /v1/models/{id}`.
- **Protocol translation.** An OpenAI client can use a route served by an Anthropic-style upstream and the reverse, including streaming, tools, images and JSON-schema structured output. A route can mix both kinds as failover targets.
- **Provider differences absorbed.** An upstream's `v1_path` covers OpenAI-compatible providers that do not serve the API under `/v1` (Gemini uses `/v1beta/openai`). For translated requests, a model that refuses sampling parameters or demands a thought signature on earlier tool calls is retried with the fix, which is then remembered.
- **Failover** to the next target on connection errors, timeouts, 429 and 5xx, before any byte reaches the client, with one retry on a fresh connection first. Upstreams that keep failing are tried last for a while.
- **Load balancing.** `failover` (config order), `round_robin` or `weighted` per route; the other targets remain as failover.
- **Per-key limits.** A model list (403 for anything else), requests per minute (429 with `Retry-After`), requests in flight and the memory they hold (429), and a budget that is total, monthly or daily (402 once spent; the key keeps read access to its models, jobs and files).
- **Usage metering** from the response stream without buffering it, with prompt-cache reads and writes counted and priced separately. Token counts are read only from the provider's usage objects, and a stream the client abandons is still billed: the provider's answer is read to its end in the background for its real figures, and an estimate marked as one is billed when they do not come.
- **Usage that survives outages.** Events are spooled to disk, sent in batches with retries and deduplicated by request id in the ledger, so a call is billed once even if the control plane was down.
- **Response cache**, opt-in per route (`cache_ttl_s`): an identical non-streaming request from the same key is answered from memory, counted but not billed.
- **Looks like the provider to an SDK.** Gateway errors use each protocol's own envelope and type names, with the gateway's reason in `error.code`; responses carry `x-request-id` / `request-id`; a provider's rate-limit and retry headers are passed on by allowlist; when no target succeeds and a provider answered 429, the client gets 429 with the longest `retry-after`. Errors from the jobs API and the admin API have the same envelope, whichever of the two processes raised them.
- **Keeps serving text without the control plane**, including after a data-plane restart (the last config is cached on disk).
- **Holds up under hostile clients and upstreams.** Request heads, paths and JSON are validated before anything else reads them, so a malformed or ambiguous request gets a 4xx instead of reaching code that could crash or be fooled. A key's concurrency, its request memory and its rate limit are checked before a body is read, and a body is parsed into a tree only where translation or the cache needs one, inside a capped allocator. Provider responses are read with the gateway's own bounded framing and re-framed for the client. Timeouts for slow requests, stalled clients and silent upstreams, a connection cap, and a graceful stop that finishes requests in flight and delivers queued usage.
- **Access log.** One line per request with key name, route, upstream, attempts, tokens, latency and request id; JSON lines on request.

### Media jobs

One async API in front of providers that each have a different one: `POST /v1/jobs`, `GET /v1/jobs/{id}`, `GET /v1/jobs`, `POST /v1/jobs/{id}/cancel`, `GET /v1/files/{job}/{name}`.

- **Adapters** for eight provider shapes: Replicate-style predictions, fal-style queues, OpenAI-style images, ElevenLabs-style text to speech, Gemini's native API for image and speech models, Gemini's Interactions API for its video-capable models, xAI's video API, and Sume's image and video routers (an aggregator of many makers' models; mock only so far).
- **Prices that follow the request**: a target's rate per second or per image can depend on fields of the job (resolution, audio), and a combination with no price is refused instead of run for free.
- **Failover across providers** inside one job: a failed submit, a provider-side failure or a timeout moves on to the next target.
- **Output custody.** Each output is copied to a local directory or to your own S3-compatible bucket; job results carry your signed URLs, not the provider's expiring ones.
- **Webhooks that are signed and retried** ([Standard Webhooks](https://www.standardwebhooks.com/) headers, HMAC-SHA256, a backoff schedule), with delivery state on the job. A delivery connects to the address that passed the private-address check.
- **Idempotency keys**, **output caching** for identical requests, and **restart safety**: a job a provider already accepted resumes polling after a control-plane restart and is not submitted again.
- **One ledger.** Per-job, per-output, per-second and per-character prices land in the same ledger and budgets as tokens, computed from what the adapter sent to the provider. A route can set a default, minimum and maximum duration, list the input fields it accepts and multiply the price by the value of a field.
- **Limits where the work starts.** Job creation is rate-limited in the control plane as well as the data plane, with caps on unfinished jobs per key, jobs per key per day and the size of a job's input. Provider output URLs are fetched only from public addresses, every outbound response (webhook receivers included) is read through a size cap, and stored outputs are served as downloads, never as pages.

### Privacy mode

A setting per gateway key, or per request with `x-omnigate-privacy`; each part can be used alone. [docs/privacy.md](docs/privacy.md) says what each part does and, as plainly, what it does not.

- **Redaction before the provider.** E-mail addresses, phone numbers, payment card numbers, IP addresses and common secret formats in a text request are replaced by placeholders (`[EMAIL_1]`) before the request leaves, and the originals are put back in the answer, also when a stream cuts a placeholder in two and inside tool-call arguments. Pattern matching: it does not find names, and the provider still reads everything else.
- **No retention at the gateway.** No response cache for the key; a media job's input and metadata never enter the job log and are erased when the job ends, and its outputs are deleted a day later; OpenAI is told `"store": false`.
- **Encrypted job outputs.** Outputs are encrypted to the key owner's [age](https://age-encryption.org) recipient before they are stored on disk or in the bucket; the gateway cannot read them afterwards.
- **Unlinking.** The request fields that name an end user to the provider (`user`, `safety_identifier`, `prompt_cache_key`, `metadata`) are removed.

This is not zero-knowledge inference and does not claim to be: a hosted model has to read the prompt it answers.

### Operations and admin

- **Dashboard and admin API** behind one admin token (a bearer token for scripts, a signed session cookie with CSRF protection for the browser). Never open by default: without `OMNIGATE_ADMIN_TOKEN` a random one is generated and logged, and one shorter than 16 characters is refused. Wrong tokens and failed sign-ins are throttled per client address.
- **Managed keys.** Create, change, disable, rotate and delete gateway keys from the dashboard or `/admin/keys`; a new key is shown once and stored as a hash. Keys in the config file keep working and are read-only there.
- **Audit log** of key changes and sign-ins, rotated by size.
- **Prometheus metrics** at `/metrics`: per-key requests, errors, tokens, cost, budget and blocked state; refused requests by reason; jobs and webhooks by state.
- **A ledger that stays bounded.** Usage events are written in segments with checksummed snapshots, so a start replays only what came after the last snapshot. Retention can delete old segments while totals stay exact, along with finished jobs and their files (local and bucket); those are off by default. Duplicate-detection ids live in per-day files and expire after 3 days unless configured otherwise.
- **Probes and credentials.** `GET /healthz` on both processes, `GET /readyz` on the control plane, and `omnigate-dp healthcheck` for the data-plane container. Gateway keys, the data planes' internal token and the admin token do not work in each other's place.

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

Both processes need the same `OMNIGATE_INTERNAL_TOKEN` and refuse to start without it. `OMNIGATE_ADMIN_TOKEN` is the dashboard password and the `/admin` API token (at least 16 characters). A text request and a media job:

```bash
curl -N http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer og-unlimited-key" -d '{"model":"demo-chat","stream":true,"messages":[{"role":"user","content":"hi"}]}'
```

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer og-unlimited-key" -d '{"model":"demo-image","input":{"prompt":"a lighthouse"}}'
```

The dashboard is at <http://127.0.0.1:4000/>; sign in with the admin token set above. The demo routes and keys of `config/omnigate.dev.json` are listed in the [quickstart](docs/quickstart.md#demo-routes-and-keys).

Other suites: `zig build test --summary all` in `dataplane/`, `mix test` in `control/`, `python tools/test_import_litellm.py`, `python tools/sdk_compat.py` (the official OpenAI and Anthropic Python SDKs as clients, against the mocks), `python tools/malformed_test.py` (malformed, ambiguous and smuggling requests, a hostile upstream and a hostile control plane, against a stack it starts itself; the gateway must survive them) and `python3 tools/container_test.py --compose` (the Compose file through TLS). `python tools/check.py` runs everything but the container test with one command; see [CONTRIBUTING.md](CONTRIBUTING.md#tests). Coming from LiteLLM, `python tools/import_litellm.py litellm.yaml -o config/omnigate.json --generate-key myapp` converts a proxy config; see [docs/migrating-from-litellm.md](docs/migrating-from-litellm.md).

## Running on a server

Container images and a Compose file with a Caddy proxy for TLS are included. Secrets are split by who needs them, one environment file per container:

```bash
cp .env.example .env
```

```bash
cp .env.control.example .env.control
```

```bash
cp .env.dataplane.example .env.dataplane
```

```bash
cp config/omnigate.example.json config/omnigate.json
```

- `.env`: the two host names, and `OMNIGATE_ADMIN_ALLOW` to limit who may reach the dashboard host. No secrets.
- `.env.control`: the internal token, the admin token, media provider keys, webhook secrets, bucket credentials.
- `.env.dataplane`: the internal token and the text provider keys. The data plane faces the internet and gets nothing else.

Fill them in, then `docker compose up -d --build`. Only the proxy publishes ports; the control plane and the internal API between the two processes stay on the private Docker network, and both omnigate containers have a memory limit (1 GiB each unless `.env` says otherwise). **Upgrading from an earlier commit:** read [docs/upgrading.md](docs/upgrading.md) for what changes on disk, which defaults changed and the order to upgrade in; a deployment from before commit 3a0b147 kept everything in one `.env` and must also be [split](docs/deployment.md#coming-from-a-commit-before-3a0b147) before it will start.

Without containers the same rules apply: give each process only its own secrets, keep the control plane on a private address, and put TLS in front of both ports. A release build of the control plane needs `OMNIGATE_CONFIG`. Tested with Docker 29 and Compose 2.40 on Ubuntu 24.04 (x86-64); not tested on ARM, with Let's Encrypt on a real domain, or on Kubernetes. What to back up, the readiness probe and upgrades are in [docs/deployment.md](docs/deployment.md), and the hardening checklist in [docs/security.md](docs/security.md).

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

**After commits e4e30e4 and d79406b**, which replaced the control plane's HTTP client and the data plane's response reader: the control plane's new HTTP client and the data plane's new response reader were each run against the real hosts of OpenAI, Anthropic, Gemini, xAI, ElevenLabs, Replicate and fal with deliberately invalid keys; every provider's own auth error came back intact. The successful paths were then re-run with real keys on 11 November 2026, at commit 809b96f, and all passed: OpenAI and Anthropic text (direct, streamed, translated both ways, tool calls, failover, metering), Gemini text, xAI text, an OpenAI image job, Gemini image, speech and video jobs, an xAI image job and a one-second xAI video, a Replicate image job, ElevenLabs speech with a cache hit, and output storage in a Cloudflare R2 bucket. fal has still only returned an auth error, never a completed job.

Not verified against anything real:

- Privacy mode. Everything in it runs against the mock providers in the test suites (which assert on what the mock received and on what the client got back), and files the gateway encrypted are decrypted by an independent age implementation there. No real provider has been sent a redacted request or `"store": false` by this code, and how well real models repeat placeholders has not been measured.

- The fal adapter (a mock written from public documentation; expect details to differ), the Sume adapter (the same: written from Sume's public documentation, never run with a Sume key, and its prices never compared with a Sume bill), and S3-compatible storage other than Cloudflare R2, including deleting bucket objects under retention.
- Everything the status paragraph lists as added later. In particular, the structured-output mapping onto Anthropic's `output_config.format` has not been sent to the live Anthropic API, and prompt-cache token accounting has not been compared with a real provider bill.
- The security fixes against anything but the project's own tests: no external penetration test, no real hostile traffic, and neither the figures billed for an abandoned stream after reading the provider's answer to its end nor the estimate have been compared with what a provider charged for one.
- The official SDKs against real providers: `tools/sdk_compat.py` runs the Python SDKs against the mocks only, and no other language's SDK has been tried.
- Replicate's `owner/name:version` form, job cancellation at a real provider, Gemini's Veo models (no adapter), xAI video with an input image, images in translated requests, long conversations, large payloads, and sustained or concurrent load against real providers.
- Platforms other than Windows 11 and x86-64 Linux (CI runs the unit, end-to-end, SDK, hostile-input and container suites on Ubuntu 24.04 for every push). macOS and ARM are untried.

## Known limits

The security model is in [SECURITY.md](SECURITY.md); the detail behind each line below is in [docs/operations.md](docs/operations.md) and [docs/architecture.md](docs/architecture.md).

- **No TLS listener** on either process; the included Caddy proxy (or another) provides it. Data-plane-to-control-plane traffic is plain HTTP and belongs on a private network.
- **One shared admin token.** No user accounts or roles, so the audit log records how a caller was authenticated and from where, not who they were; sessions cannot be revoked individually. The lockouts for failed sign-ins and wrong tokens count per client address, in memory, and locking an address out also stops legitimate callers that share it.
- **A managed key's webhook secret is stored in clear text** in the keys file. Protect the data directory.
- **Budgets are enforced after the fact**: the call that crosses the budget completes, the block arrives one usage flush plus one config poll later, on a single control-plane node, and a key cannot be newly blocked during a control-plane outage.
- **Per-process state.** Rate limits, cooldowns, round-robin positions and the response cache live in each data-plane process and reset on restart; several data planes each allow the full rate limit for text requests (job creation is counted once more in the control plane, also in memory). The response cache is exact-match only.
- **Strict request parsing.** The gateway accepts one spelling per path and refuses percent-encoded paths, trailing slashes, query strings outside a small character set, chunked request bodies (411), JSON nested deeper than 64 levels and a duplicated `model` field. A request that must be translated may not have more than 1,024 members in one object. A client that an earlier commit served may now get a 4xx; see [docs/api.md](docs/api.md#request-heads-paths-and-queries).
- **Limits come before the body, so refusals cost.** A key's rate limit is charged before its request body is read: a request then refused for its model or its JSON has used up one request of the allowance. The data plane's own default memory budgets admit about 2 GiB, more than a 1 GiB container: the Compose file sets them lower to fit its limit, and anyone running the binary under a memory limit of their own has to do the same ([docs/deployment.md](docs/deployment.md#memory-limits)).
- **Responses are re-framed.** A provider's `content-length` is never passed on: non-streaming answers over 64 KiB are sent chunked, without a length, and a response the provider cuts short ends with a dropped connection. (File downloads keep their length.)
- **Translation covers chat completions and messages only.** It drops what the other protocol cannot express (thinking blocks, cache control, penalties and similar) and refuses audio and file parts; any other endpoint on a route whose upstreams all speak the other protocol answers 400 `endpoint_not_supported`.
- **Pricing gaps.** Reasoning tokens have no price of their own, and for media jobs the cost is the configured price of the target that delivered; provider charges for failed attempts are not recorded. A response that ends before the provider's final usage arrives, and whose upstream answer could not be read to its end either, is billed an estimate (request size, media parts, events and text received), marked `estimated` in the ledger line, the access log and `GET /admin/overview`, but not on the dashboard page or in the metrics. Reading an abandoned answer to its end keeps the provider generating for up to two minutes by default.
- **Client timeouts and threads.** A client that times out gets a closed connection, not a 408, and one that stops reading a response for 30 seconds is disconnected. The data plane uses one thread per connection; it has been soaked at 94 connections for five minutes and tried at 550 for two, and beyond that is untested.
- **Usage spool.** Appends are not fsynced, so a power loss can drop the last few events, and the spool holds at most 100,000 undelivered events (128 MiB); beyond that the oldest are kept and new ones dropped. Counts of refused requests are kept in memory only.
- **Media jobs need the control plane** (during an outage `/v1/jobs` answers 503). A crash between a provider accepting a job and its id reaching disk, or during a synchronous provider call, resubmits that job. There are no per-upstream concurrency limits and no transcoding.
- **The media output cache is shared across gateway keys**, and two identical cacheable jobs submitted at the same moment both run.
- **Ledger retention.** Once `retention.ledger_days` has deleted ledger segments, the two snapshot files hold the only copy of the totals those segments contributed, so back up the whole data directory. Deleting bucket objects under retention is best effort. Duplicate-detection ids are forgotten after 3 days by default, so a usage event resent later than that would be counted twice; raise `retention.ledger_ids_days` if a data plane can hold undelivered usage for longer. A ledger snapshot written by the current code is not read by code from before commit d79406b ([docs/upgrading.md](docs/upgrading.md#going-back)).
- **Metrics.** Each scrape scans the whole job store, and the output has been checked by tests, not by a real Prometheus server.
- **Zig 0.17 standard-library quirks worked around** in the data plane: `http.Client.fetch` panics on a reset keep-alive connection, `privileged_headers` are never sent, and `http.BodyWriter.flush` does not flush the body's own buffer. More are kept away from by validating input first or by not using the code at all: `http.HeaderIterator` unwraps a null on a header line without a colon, the server asserts on a request body without a length, the chunked body reader overflows on a chunk size that does not fit its integer (so chunked request bodies are refused and upstream bodies are read by the gateway's own reader), the server asserts when a response ends with a different number of bytes than its head promised (so an upstream's length is never forwarded), the head parser lets a bare line feed through in a header value, the JSON object's hash map has a fixed seed, and the JSON serialiser indexes past a fixed stack beyond 256 levels of nesting.

## Documentation and license

[Quickstart](docs/quickstart.md) · [Configuration](docs/configuration.md) (every config field and environment variable) · [API reference](docs/api.md) (endpoints, errors, jobs, webhooks, the official SDKs) · [Admin](docs/admin.md) (dashboard, managed keys, budgets, audit log) · [Providers](docs/providers.md) · [Deployment](docs/deployment.md) · [Upgrading](docs/upgrading.md) (what changes on disk, changed defaults, the order to upgrade) · [Security hardening](docs/security.md) (what to expose, where each credential lives, backups, logs) · [Privacy mode](docs/privacy.md) (redaction, no retention, encrypted outputs, and what none of it does) · [Operations](docs/operations.md) (metrics, limits, retention, logs, troubleshooting) · [Architecture](docs/architecture.md) · [Migrating from LiteLLM](docs/migrating-from-litellm.md) · [Releasing](docs/releasing.md) · [docs index](docs/README.md) · [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) · [CHANGELOG.md](CHANGELOG.md)

omnigate is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE): free to self-host for personal and other noncommercial use. Business or commercial use needs a paid license; see [COMMERCIAL.md](COMMERCIAL.md) or write to hello@legatia.solutions.
