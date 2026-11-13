# omnigate

[![CI](https://github.com/Legatia/omnigate/actions/workflows/ci.yml/badge.svg)](https://github.com/Legatia/omnigate/actions/workflows/ci.yml)

**Site and documentation: <https://omnigate.legatia.solutions>**

A self-hostable AI gateway in two small processes. The data plane (Zig) is the port applications call: it fronts OpenAI- and Anthropic-style text APIs with gateway keys, limits, failover and protocol translation. The control plane (Elixir) owns configuration, keys, budgets and the usage ledger, and wraps image, video and speech providers in one async job API.

**Status (November 2026): pre-release. Nothing has run under production load, and the only tagged version is the pre-release 0.1.0-rc.1.** The text gateway and seven of the eight media adapters have been checked by hand against the real provider APIs, and bucket storage against Cloudflare R2; the fal adapter has only met a mock, of the Sume adapter only a successful image and video job have run for real, and of the ElevenLabs adapter speech, one sound effect and one piece of music (its image and video jobs have only met a mock). Everything added after those checks has only met the mock providers in the test suites: managed keys and the admin API, budget periods, the response cache, provider header passthrough, prompt-cache token accounting, provider-shaped errors, structured-output translation, ledger snapshots and retention, and the security fixes of November 2026 (strict request parsing, limits before a body is read, the gateway's own response framing, billing of abandoned streams, address checks on provider outputs, capped outbound responses). Those fixes closed an authentication bypass, remote crashes, resource exhaustion by a valid key and more, and the last two of them (commits e4e30e4 and d79406b) replaced the code that reads every provider response in both processes: if you ran an earlier commit, read [SECURITY.md](SECURITY.md#past-advisories) and [docs/upgrading.md](docs/upgrading.md). See [What has been verified](#what-has-been-verified) and [Known limits](#known-limits).

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
| `tools/` | Python (stdlib) | Mock providers, end-to-end test, SDK compatibility test, container test, hostile-input test, a one-command runner for all of them (`check.py`), load test, benchmark, LiteLLM config importer, the live NEAR AI Cloud check (`near_live.py`), a stand-in for the payment provider (`mock_intents.py`) and the live check of payments with dry quotes (`near_intents_live.py`) |
| `compose.yaml`, `deploy/` | Docker | Both images plus a Caddy proxy for TLS, with one environment file per container |

> **NEAR hackathon reviewers:** the entry (track Privacy & Private AI) is the opt-in part described under [Optional: attested private inference on NEAR AI Cloud](#optional-attested-private-inference-on-near-ai-cloud), with numbered steps to see it work.

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

- **Adapters** for eight provider shapes: Replicate-style predictions, fal-style queues, OpenAI-style images, ElevenLabs (speech, sound effects, music, and the image and video models it relays), Gemini's native API for image and speech models, Gemini's Interactions API for its video-capable models, xAI's video API, and Sume's image and video routers (an aggregator of many makers' models; one real image and one real video job so far).
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
- **Attested providers only.** A request marked `attested` goes only to a provider that runs its models in confidential hardware and whose attestation the gateway has verified itself, and recently: Intel TDX quotes checked up to Intel's pinned root, with revocation, patch status, a fresh nonce, the measured configuration and NVIDIA's verdict on GPU evidence. Built for [NEAR AI Cloud](https://docs.near.ai/cloud/verification). Otherwise the request is refused, not sent elsewhere. What a pass proves and what it does not: [docs/attestation.md](docs/attestation.md).
- **A dry run** (`x-omnigate-dry-run: privacy`) answers with the request as privacy mode left it and sends nothing, and the dashboard's **Private chat** page shows that next to the answer and the attestation checklist.

This is not zero-knowledge inference and does not claim to be: a hosted model has to read the prompt it answers. Redaction limits what the model is shown; attestation is about who else at the provider can read it.

### Operations and admin

- **Dashboard and admin API** behind one admin token (a bearer token for scripts, a signed session cookie with CSRF protection for the browser). Never open by default: without `OMNIGATE_ADMIN_TOKEN` a random one is generated and logged, and one shorter than 16 characters is refused. Wrong tokens and failed sign-ins are throttled per client address.
- **Managed keys.** Create, change, disable, rotate and delete gateway keys from the dashboard or `/admin/keys`; a new key is shown once and stored as a hash. Keys in the config file keep working and are read-only there.
- **Audit log** of key changes and sign-ins, rotated by size.
- **Built to be built around.** omnigate has no plugins; what others add sits next to it, over HTTP. A payment service credits a prepaid key with one idempotent call (`POST /admin/keys/{name}/topup`, once per payment reference, so a payment seen twice is credited once). A billing tool pages through every metered request and job (`GET /admin/events`, by cursor, no content). A client labels its requests with `x-omnigate-tag`. [Building on omnigate](docs/building-on-omnigate.md) has the flows, what is stable, what is deliberately not offered, and three small examples in [`examples/`](examples/) that the end-to-end test runs.
- **Prepaid credit with one rule.** A key with a total budget holds credit: one credit is one dollar when it is added, and a request burns what the provider cost times a burn multiplier (`credits.burn_multiplier`, 1 unless set, or the key's own). Every usage record shows both figures. Credit can earn a weekly bonus on its average balance (`credits.bonus_annual_rate`, off unless set), credited once per ISO week. Credit cannot be withdrawn. At the defaults nothing differs from a plain budget. [Prepaid credit](docs/credits.md).
- **Payments, opt-in.** With a `payments` section in the config, the holder of a prepaid key buys credit through a payment provider, also when the key is out of credit: `POST /v1/payments` answers with a deposit address and the amount to send, and the key is credited once the payment has settled. The one provider today is NEAR Intents (its 1Click API): the payer pays with any of a few hundred assets on a few dozen chains, the operator receives USDC in their own NEAR account. The gateway holds no keys, signs nothing and moves no funds; it verifies the provider's signature on each quote and credits a settlement exactly once. A person does the same on the top-up page the gateway serves at `/topup` (key in, amount and asset chosen, deposit address shown with a QR code, credit followed until it arrives), and the operator sees every payment and balance on the dashboard's Payments page. Without the section none of this exists. [Payments](docs/payments.md).
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

Without containers the same rules apply: give each process only its own secrets, keep the control plane on a private address, and put TLS in front of both ports. A release build of the control plane needs `OMNIGATE_CONFIG`. Tested with Docker 29 and Compose 2.40 on Ubuntu 24.04 (x86-64, and arm64 in CI); not tested with Let's Encrypt on a real domain, or on Kubernetes. What to back up, the readiness probe and upgrades are in [docs/deployment.md](docs/deployment.md), and the hardening checklist in [docs/security.md](docs/security.md).

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
- **Media jobs**, each generated, stored by the gateway and downloaded from it: OpenAI images (`gpt-image-1-mini`), Replicate (`black-forest-labs/flux-1.1-pro`), ElevenLabs speech (`eleven_flash_v2_5`), an ElevenLabs sound effect (`eleven_text_to_sound_v2`, 0.5 s) and piece of music (`music_v1`, 3 s), Gemini image and speech (`gemini-3.1-flash-lite-image`, `gemini-3.8-flash-lite-tts`), Gemini video through the Interactions API (`gemini-omni-1.2-flash`), xAI video (`grok-imagine-video-1.5-lite`). Webhooks were delivered for the OpenAI image (after a retry), Replicate and both video jobs; repeat speech requests were served from cache; an unknown model or voice failed with the provider's own reason at Replicate, xAI, Gemini and ElevenLabs.
- **Bucket storage on Cloudflare R2** (S3 API, region `auto`): upload under a key prefix, download through the presigned link, refusal without a valid signature, confirmed by an independently signed listing and read.

**After commits e4e30e4 and d79406b**, which replaced the control plane's HTTP client and the data plane's response reader: the control plane's new HTTP client and the data plane's new response reader were each run against the real hosts of OpenAI, Anthropic, Gemini, xAI, ElevenLabs, Replicate and fal with deliberately invalid keys; every provider's own auth error came back intact. The successful paths were then re-run with real keys on 11 November 2026, at commit 809b96f, and all passed: OpenAI and Anthropic text (direct, streamed, translated both ways, tool calls, failover, metering), Gemini text, xAI text, an OpenAI image job, Gemini image, speech and video jobs, an xAI image job and a one-second xAI video, a Replicate image job, ElevenLabs speech with a cache hit, and output storage in a Cloudflare R2 bucket. fal has still only returned an auth error, never a completed job.

**NEAR AI Cloud attestation and receipts** (11 November 2026, `tools/near_live.py`): without an API key, 11 checks: the gateway and `z-ai/glm-5.3-flash` verify through the running control plane, GPU evidence included; a model NEAR only relays is refused; the data plane routes by the verdict. With a key, 27 checks: a real completion through the attested target with an e-mail address and a card number redacted and restored, then a whole and a streamed completion whose receipts verified (signed by the model's machine and by NEAR's gateway respectively) and were confirmed from the bytes sent and received by `tools/verify_receipt.py`, which also refused each with one byte changed. See [docs/attestation.md](docs/attestation.md#what-has-been-tested).

**Payments through NEAR Intents** (11 November 2026, `tools/near_intents_live.py`, no funds): the real asset list and dry quotes for six assets on five chains through a running gateway, each quote's signature verified against 1Click's key, and three refusals relayed in the provider's words. One finding went into the code: the real service signs a Bitcoin quote under the asset's other listed id.

Not verified against anything real:

- Payments beyond one. A single real payment has gone through (12 November 2026: $1 of credit paid in ETH on Ethereum mainnet through the top-up page, settled and credited once); refunds, failures, short deposits and expiry have only met `tools/mock_intents.py`, and the weekly bonus has only run in tests that move the clock.
- Privacy mode beyond one run. On 11 November 2026 redaction, restoring (whole, streamed, in tool-call arguments and through translation), no-store, unlink and an encrypted image output were checked against the real OpenAI, Anthropic, Gemini and xAI APIs (35 checks, all passed). Only the email and card classes were exercised there; phone numbers, secrets and Anthropic's diagnostics opt-out have only met the mocks, and how reliably real models repeat placeholders over long conversations has not been measured.
- The fal adapter (a mock written from public documentation; expect details to differ), the Sume adapter beyond one successful image job and one successful video job (cancel, refusals, idempotent replay and failed jobs are mock only, and its prices were never compared with a Sume bill), ElevenLabs image and video jobs (the test workspace's plan is refused on those endpoints, so only the refusal has run for real; a successful job is mock only), and S3-compatible storage other than Cloudflare R2, including deleting bucket objects under retention.
- Everything the status paragraph lists as added later. In particular, the structured-output mapping onto Anthropic's `output_config.format` has not been sent to the live Anthropic API, and prompt-cache token accounting has not been compared with a real provider bill.
- The security fixes against anything but the project's own tests: no external penetration test, no real hostile traffic, and neither the figures billed for an abandoned stream after reading the provider's answer to its end nor the estimate have been compared with what a provider charged for one.
- The official SDKs against real providers: `tools/sdk_compat.py` runs the Python SDKs against the mocks only, and no other language's SDK has been tried.
- Replicate's `owner/name:version` form, job cancellation at a real provider, Gemini's Veo models (no adapter), xAI video with an input image, images in translated requests, long conversations, large payloads, and sustained or concurrent load against real providers.
- Platforms other than Windows 11, Linux (x86-64 and arm64) and macOS on Apple silicon. CI runs the unit, end-to-end, SDK, hostile-input and container suites on x86-64 Ubuntu 24.04 for every push, and a second workflow, Platforms, runs the unit, end-to-end and hostile-input suites on arm64 Ubuntu 24.04 and on macOS 15 (Apple silicon), plus the container suite on arm64. On macOS that is all that has been run: nobody has used it there beyond those suites, and Intel Macs are untried.

## Known limits

The security model is in [SECURITY.md](SECURITY.md); the detail behind each line below is in [docs/operations.md](docs/operations.md) and [docs/architecture.md](docs/architecture.md).

- **What attestation and receipts leave open.** For an attested upstream the gateway verifies the provider's TEE evidence every few minutes and routes by it, and checks the provider's signature on each answer against that evidence (a receipt). It does not check where the measured software was built and does not bind its own TLS connections to the report; the allowlist of accepted measurements is empty unless you fill it. A receipt says that a holder of the verified key signed exactly these bytes: machines serving one model share a key, and a streamed answer is signed by the provider's gateway, not by the model's machine. A target can stay in use for up to twice `max_age_s` after its last successful check in the worst case. Only NEAR AI Cloud is supported ([docs/attestation.md](docs/attestation.md#what-is-not-checked)).
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
- **Client timeouts and threads.** A client that times out gets a closed connection, not a 408, and one that stops reading a response for 30 seconds is disconnected. The data plane uses one thread per connection (and up to two more per request while it waits on an upstream, plus up to three for each of at most 256 abandoned streams being read to their end); it has been soaked at 94 connections for five minutes, tried at 550 for two, and run for 16 minutes at about 830 requests a second with some 80 clients and 890 threads, where its memory held at 213 MiB. Beyond that is untested.
- **Usage spool.** Appends are not fsynced, so a power loss can drop the last few events, and the spool holds at most 100,000 undelivered events (128 MiB); beyond that the oldest are kept and new ones dropped. Counts of refused requests are kept in memory only.
- **Media jobs need the control plane** (during an outage `/v1/jobs` answers 503). A crash between a provider accepting a job and its id reaching disk, or during a synchronous provider call, resubmits that job. There are no per-upstream concurrency limits and no transcoding.
- **The media output cache is shared across gateway keys**, and two identical cacheable jobs submitted at the same moment both run.
- **Ledger retention.** Once `retention.ledger_days` has deleted ledger segments, the two snapshot files hold the only copy of the totals those segments contributed, so back up the whole data directory. Deleting bucket objects under retention is best effort. Duplicate-detection ids are forgotten after 3 days by default, so a usage event resent later than that would be counted twice; raise `retention.ledger_ids_days` if a data plane can hold undelivered usage for longer. A ledger snapshot written by the current code is not read by code from before commit d79406b ([docs/upgrading.md](docs/upgrading.md#going-back)).
- **Metrics.** Each scrape scans the whole job store, and the output has been checked by tests, not by a real Prometheus server.
- **Zig 0.17 standard-library quirks worked around** in the data plane: `http.Client.fetch` panics on a reset keep-alive connection, `privileged_headers` are never sent, and `http.BodyWriter.flush` does not flush the body's own buffer. More are kept away from by validating input first or by not using the code at all: `http.HeaderIterator` unwraps a null on a header line without a colon, the server asserts on a request body without a length, the chunked body reader overflows on a chunk size that does not fit its integer (so chunked request bodies are refused and upstream bodies are read by the gateway's own reader), the server asserts when a response ends with a different number of bytes than its head promised (so an upstream's length is never forwarded), the head parser lets a bare line feed through in a header value, the JSON object's hash map has a fixed seed, and the JSON serialiser indexes past a fixed stack beyond 256 levels of nesting.

## Optional: attested private inference on NEAR AI Cloud

**This part is opt-in.** omnigate is a model gateway and stays one: nothing here runs unless the config gives an upstream an `"attestation"` setting. Without it no attestation is fetched or checked, no request is restricted, and the dashboard has no Private chat page. `config/omnigate.near.json` is a config that switches it on; the default and dev configs do not.

This repository is an entry in the NEAR hackathon (1 to 14 November 2026), track **Privacy & Private AI**. This section is for the people and the coding agents that review it: what was built, what NEAR does in it, and steps to see it work.

**What it is.** omnigate is a self-hostable gateway that applications call instead of calling AI providers directly. The whole repository was written inside the hackathon window (first commit 10 November 2026; see `git log`), with Claude Code.

**The problem.** A team that wants to use hosted models on sensitive text has two worries: what the model is shown, and who else at the provider can read the request. Promises in a privacy policy answer neither in a way that can be checked.

**What was built for it, and NEAR's part.**

1. **Redaction at the gateway** (not NEAR-specific): e-mail addresses, phone numbers, card numbers, IP addresses and secrets in a request are replaced by placeholders before it leaves, and put back in the answer. This limits what the model is shown.
2. **Attested-only routing, on NEAR AI Cloud's TEE attestation**: NEAR AI Cloud runs its gateway and its own models in Intel TDX machines and publishes attestation reports. omnigate verifies those reports itself, natively, with no verification library: the Intel quote and its certificate chain to Intel's pinned root, revocation lists, platform patch status, debug mode, the fresh nonce, the measured configuration, the event log, and NVIDIA's verdict on the GPU evidence. It keeps each model verified (re-checked with a new nonce every few minutes), and a request marked `attested` is sent **only** to a model whose attestation is verified right now. Otherwise it is refused, never sent elsewhere. This answers "who else can read it" with evidence instead of a promise.
3. **A receipt for each answer**: NEAR signs every answer with a key that its attestation binds to the machine. The data plane hashes the exact bytes it sent and received, the control plane fetches NEAR's signature, checks that it covers exactly those bytes and that its key is the key of a report verified *before* the request, and keeps the result as a receipt (`GET /v1/attestations/<request id>`). Anyone holding the receipt and the two bodies can check the signature offline with `tools/verify_receipt.py` (standard library only). Anything missing or ambiguous is `not_verified`, never assumed ([docs/attestation.md](docs/attestation.md#a-receipt-for-each-answer)).
4. **A page that shows all of it**: `/private-chat` in the dashboard has the conversation, the request exactly as the gateway's redaction leaves it, the verification checklist with the raw evidence, and the receipt of each answer.
5. **Nothing kept**: requests from that page go out as `no-store`; the gateway keeps no content of them (a receipt holds hashes and a signature), and the end-to-end test searches every file both processes wrote for a marked prompt to check it.
6. **Agents pay for their own inference, through NEAR Intents** (also opt-in, a `payments` section): a prepaid key that has run out of credit asks the gateway for a payment, gets a deposit address for the asset it wants to pay with (any asset NEAR Intents' 1Click API lists, on any chain it supports), and is credited when the swap has delivered USDC to the operator's NEAR account. The gateway verifies 1Click's Ed25519 signature on every quote before it shows a deposit address, credits a settlement exactly once, and never holds a key or moves funds. What credit then burns and earns is a rule of the gateway's own, independent of NEAR ([docs/credits.md](docs/credits.md)). [docs/payments.md](docs/payments.md) says what is checked and what is trusted.

What the attestation check and a receipt do **not** establish is written down as plainly: [docs/attestation.md](docs/attestation.md#what-is-not-checked) (no image-provenance check; the measurement allowlist is empty unless set; the data plane's TLS connections are not bound to the report; a streamed answer is signed by NEAR's gateway rather than the model's machine, and machines serving one model share a key).

**See it work.** Prerequisites: Zig 0.17, Erlang/OTP 29 with Elixir 1.20, Python 3.9+ ([docs/quickstart.md](docs/quickstart.md) has the setup, including the Windows `PATH`). Build once:

```bash
cd dataplane && zig build && cd ../control && mix deps.get && mix compile && cd ..
```

Without any API key (an attestation report is public):

1. Run `python tools/near_live.py`. See: a checklist of what was verified for NEAR's gateway and for `z-ai/glm-5.3-flash` (genuine TDX quotes, status `UpToDate`, nonce bound, configuration measured, GPU evidence accepted by NVIDIA), then 11 checks that end in `11/11 checks passed`: the running gateway verifies the model NEAR serves itself, refuses `openai/gpt-5` (which NEAR only relays and cannot attest), lets an `attested` request through to the verified model, and refuses it, unsent, on the two other routes.
2. Run `python tools/near_live.py --serve`. It prints an address and an admin token. Open `http://127.0.0.1:4000/private-chat`, sign in with the token. See: the **Verified** panel with a green check per item; each opens to the raw values. Press **Verify again now**: a new nonce, a new verdict in about two seconds.
3. On that page, press **Fill in an example**, then **Send**. See: the middle panel shows the message with `[EMAIL_1]`, `[PHONE_1]` and `[CARD_1]` where the values were. Without a NEAR key the provider answers 401, and the page says so.
4. Choose the model **unattested** (the same NEAR endpoint, configured without attestation) and send again. See: `Not sent`, `attestation_unverified`. Choose **relayed** and see the same, with NEAR's own reason in the Verified panel.
5. Run the offline tests: `cd control && mix test test/attestation_test.exs test/attestation_manager_test.exs test/receipts_test.exs`. See: `22 passed`. The first of them is 96 checks on a saved real report, in which each kind of tampering has to fail with its own error. `python tools/check.py` from the repository root runs every suite (about six minutes).

With a NEAR AI Cloud key (`NEAR_AI_API_KEY`; from https://cloud.near.ai, or $10 of credits at https://nearbuilders.org/dashboard):

6. Set `NEAR_AI_API_KEY` in the shell and run `python tools/near_live.py` again. See: `27/27 checks passed`. Among them a real completion whose answer contains the real e-mail address and card number although the model was only sent placeholders, with `x-omnigate-attestation: verified; tcb=UpToDate; ...` on the response; then, under "a receipt for a real answer", two receipts printed in full, each with `"verdict": "verified"`, followed by the output of `tools/verify_receipt.py` ending in `VERIFIED`, and `NOT VERIFIED` for the same answer with one byte changed. (Three short completions; a few cents.)
7. Run `python tools/near_live.py --serve` with the key set and chat on the page with the model **private**. See: the answer with your values in it on the left, placeholders in the middle, and on the right, under the checklist, **This answer**: "Signed by the model's machine" with a green check, and a **Download receipt** button. (The model reasons before it answers; an answer can take half a minute.)
8. Check a downloaded receipt's signature yourself: `python tools/verify_receipt.py receipt-<id>.json`. See: `VERIFIED`, with a note that the bodies were not given. Change a character of `request_sha256` in the file and run it again. See: `NOT VERIFIED`.

Payments through NEAR Intents (no key and no funds needed for steps 9 to 11):

9. Run `python tools/near_intents_live.py`. See: the real asset list through the gateway (`229 assets on 39 chains` when this was written), then dry quotes for NEAR, Ether, Bitcoin, SOL and USDC on Base and Arbitrum, each a line like `NEAR: $5 takes 1.36 wNEAR (about $5.06), about 20 s`, each passed only because 1Click's signature on it verified; the provider's refusals in its own words; and `13/13 checks passed`. A dry quote creates nothing.
10. Run the offline tests: `cd control && mix test test/payments_test.exs test/credits_test.exs`. See: `52 passed`. Among them: a real quote from 11 November 2026 verifies under the pinned key and fails when its recipient is changed; a settlement seen many times is credited once; a status about another quote credits nothing; a weekly bonus is credited once per week, also for weeks that ended while nothing ran.
11. See the whole flow against a stand-in for the provider: `python tools/e2e.py --only text` (about two minutes). See, under `payments:`, a key with no credit getting `402`, starting a payment, the deposit "arriving" at `tools/mock_intents.py`, the key credited and answering `200` again, and `examples/agent_pays.py` doing the same by itself.
12. With real funds (run once, on 12 November 2026; a dollar or two, there is no test network): `python tools/near_intents_live.py --serve`, then the four commands it prints. [docs/payments.md](docs/payments.md#trying-it-with-real-funds) has the steps. See: the payment going from `awaiting_deposit` to `settled`, the key credited, and one more USDC in the recipient account.

**Status of this part, honestly.** Steps 1 to 7 were run on 11 November 2026 and pass, steps 6 and 7 with a real key against the real service; step 8 is what the end-to-end suite does with a fixed receipt. Two things in it rest on a single real run each: the receipt of a whole answer and the receipt of a streamed one. Steps 9 to 11 were run on 11 November 2026 and pass; step 9 against the real 1Click API with dry quotes only. **No real payment has been made** (step 12): everything after a deposit has only met the mock, and the real service's status answers after a deposit are known from its documentation alone.

**Built with.** Zig 0.17 (standard library only) for the data plane; Elixir 1.20 on Erlang/OTP 29 with [Bandit](https://github.com/mtrudel/bandit) and [Plug](https://github.com/elixir-plug/plug) for the control plane; Python's standard library for the tools (the SDK test uses the official `openai` and `anthropic` packages, the end-to-end test `pyrage` when installed); Docker and Caddy for the Compose deployment. The TDX verification was written for this project in Elixir on OTP's `:crypto`, following Intel's DCAP rules as implemented in Phala's [dcap-qvl](https://github.com/Phala-Network/dcap-qvl) and NEAR's verification documentation; the Intel SGX Root CA certificate is pinned in the source. License: [PolyForm Noncommercial 1.0.0](LICENSE).

## Documentation and license

[Quickstart](docs/quickstart.md) · [Configuration](docs/configuration.md) (every config field and environment variable) · [API reference](docs/api.md) (endpoints, errors, jobs, webhooks, the official SDKs) · [Admin](docs/admin.md) (dashboard, managed keys, budgets, audit log) · [Prepaid credit](docs/credits.md) (the burn multiplier, the weekly bonus) · [Payments](docs/payments.md) (opt-in: buying credit through NEAR Intents, what is checked and what is trusted) · [Building on omnigate](docs/building-on-omnigate.md) (payments and top-ups, the usage feed, agents, what is stable) · [Providers](docs/providers.md) · [Deployment](docs/deployment.md) · [Upgrading](docs/upgrading.md) (what changes on disk, changed defaults, the order to upgrade) · [Security hardening](docs/security.md) (what to expose, where each credential lives, backups, logs) · [Privacy mode](docs/privacy.md) (redaction, no retention, encrypted outputs, and what none of it does) · [Attested upstreams](docs/attestation.md) (TEE attestation of NEAR AI Cloud verified by the gateway, attested-only routing, the Private chat page) · [Operations](docs/operations.md) (metrics, limits, retention, logs, troubleshooting) · [Architecture](docs/architecture.md) · [Migrating from LiteLLM](docs/migrating-from-litellm.md) · [Releasing](docs/releasing.md) · [docs index](docs/README.md) · [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) · [CHANGELOG.md](CHANGELOG.md)

omnigate is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE): free to self-host for personal and other noncommercial use. Business or commercial use needs a paid license; see [COMMERCIAL.md](COMMERCIAL.md) or write to hello@legatia.solutions.
