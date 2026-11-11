# omnigate documentation

omnigate is a self-hostable AI gateway made of two processes: a data plane
(Zig) that applications talk to, and a control plane (Elixir) that owns
configuration, gateway keys, the usage ledger, budgets and media jobs. The
[project README](../README.md) has the overview, what has been verified
against real providers, the comparison with other gateways and the list of
known limits.

These pages describe the code as committed. Where a feature has only been
exercised against a mock, or not at all, the page says so.

## Start here

| If you want to | Read |
|---|---|
| Run it on your machine with mock providers, then with a real one | [Quickstart](quickstart.md) |
| Write or change the config file, or look up an environment variable | [Configuration](configuration.md) |
| Call the gateway from an application, with plain HTTP or the official SDKs | [API reference](api.md) |
| Use the dashboard, create and revoke gateway keys, set budgets, read the audit log | [Admin](admin.md) |
| Connect OpenAI, Anthropic, Gemini, xAI or a media provider | [Providers](providers.md) |
| Put it on a server with TLS | [Deployment](deployment.md) |
| Upgrade an installation that runs an earlier commit: what changes on disk, which defaults changed, what clients will notice, the order to upgrade the two processes, and going back | [Upgrading](upgrading.md) |
| Harden a deployment: what to expose, where each credential lives, the admin allow-list, backups, logs | [Security hardening](security.md) |
| Monitor it, understand limits and timeouts, read its logs, or debug an error | [Operations](operations.md) |
| Understand how the two processes divide the work | [Architecture](architecture.md) |
| Convert a LiteLLM proxy config | [Migrating from LiteLLM](migrating-from-litellm.md) |
| Cut a release (maintainers) | [Releasing](releasing.md) |

## Related files in the repository

- [`README.md`](../README.md): overview, what has been verified, comparison, measurements, known limits.
- [`config/omnigate.dev.json`](../config/omnigate.dev.json): the config the quickstart uses, with mock providers.
- [`config/omnigate.example.json`](../config/omnigate.example.json): a template for real providers.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): building, tests, code layout.
- [`SECURITY.md`](../SECURITY.md): reporting a vulnerability, security model, known limits, past advisories.
- `.env.example`, `.env.control.example`, `.env.dataplane.example`: the three environment files of the Compose deployment.
- [`CHANGELOG.md`](../CHANGELOG.md): what changed.

## Status in one paragraph

From the README, as of November 2026: the text gateway and the OpenAI image,
ElevenLabs speech, Replicate, Gemini (image, speech, video) and xAI video
adapters have been checked against the real APIs, and bucket storage against
Cloudflare R2. The fal adapter has only met a mock, and nothing has run under
production load. [Providers](providers.md) lists the status of each one.

For the features added after those checks, the repository records tests
against mocks only: managed keys and the admin API, budget periods, the
response cache, provider header passthrough, prompt-cache token accounting,
deleting bucket objects under retention, provider-shaped errors and request
ids, the model endpoints, a provider's 429 passed on as 429, structured
output through translation (the Anthropic side has not been sent to the
live API), and the ledger's snapshots, segments and `retention.ledger_days`.
The official OpenAI and Anthropic Python SDKs are run through the gateway
against the mock providers (`tools/sdk_compat.py`); no run against real
providers is recorded.

The same holds for the security fixes of November 2026: strict request
heads and paths, bounded JSON nesting, billing of abandoned streams,
media cost computed from what an adapter sends, address checks on provider
output downloads, throttling of wrong admin tokens, the admin allow-list
in the proxy, and, from commits e4e30e4 and d79406b, limits that apply
before a request body is read, the gateway's own framing of every response
it relays, capped outbound responses in the control plane, stores that
survive bad input, and duplicate-detection ids in per-day files. They are
covered by unit and fuzz tests, by `tools/malformed_test.py` and by the
container test. No external security test has been done.

Those last two commits replaced the code that reads every provider
response in both processes. After commits e4e30e4 and d79406b: the control
plane's new HTTP client and the data plane's new response reader were each
run against the real hosts of OpenAI, Anthropic, Gemini, xAI, ElevenLabs,
Replicate and fal with deliberately invalid keys; every provider's own auth
error came back intact. The successful paths that were verified earlier
with real keys (text, images, speech, video, bucket storage) have NOT been
re-run on the new client and reader.

## If you are upgrading from an earlier commit

Several things changed in ways an existing installation or client can
notice. [Upgrading](upgrading.md) is the page to read first: it covers the
two security commits of 11 November 2026 (e4e30e4 for the data plane,
d79406b for the control plane and Compose) step by step, and lists what
still applies from older commits. Each change is also described where it
belongs; this is the list of where to look.

| Change | Read |
|---|---|
| Two security commits (e4e30e4, d79406b) fixed resource exhaustion of the data plane by a valid key, crashes of the data plane from malformed upstream responses, memory exhaustion of the control plane through webhook receivers, and a crash of the control plane by text that is not valid UTF-8. Update both processes, control plane first. | [SECURITY.md](../SECURITY.md#past-advisories), [Upgrading: the order to upgrade the two processes](upgrading.md#the-order-to-upgrade-the-two-processes) |
| Three earlier security commits (97cf396, fde530c, 3a0b147) fixed an authentication bypass on the control plane, remote crashes and request smuggling on the data plane, ways to avoid being billed, and a request-forgery path through provider outputs. Update both processes; if your control plane or dashboard host was reachable by anyone you do not trust, there are things to rotate and check. | [SECURITY.md](../SECURITY.md#past-advisories) |
| The Compose deployment now reads `.env.control` and `.env.dataplane` instead of one `.env`, and will not start without them. An admin token shorter than 16 characters, or a release build without `OMNIGATE_CONFIG`, stops the control plane from starting. | [Deployment: coming from a commit before 3a0b147](deployment.md#coming-from-a-commit-before-3a0b147) |
| Since commit d79406b the control plane reads whole-number settings strictly, with bounds: a config file that an older commit loaded (`"rpm": 600.0`, a negative budget) can stop the new one at startup. Both omnigate containers of the Compose deployment now have a memory limit, 1 GiB each unless `.env` says otherwise, and the data plane's default memory budgets admit more than that. | [Upgrading: configuration that used to load and no longer does](upgrading.md#configuration-that-used-to-load-and-no-longer-does), [Deployment: memory limits](deployment.md#memory-limits) |
| The gateway is stricter about requests: one spelling per path, no percent-encoding, a small character set in query strings, bounded JSON nesting, `411` for a body without a length. Since commit e4e30e4 a chunked request body is also answered `411`, the rate limit is charged before the body is read, and a key has a cap on requests in flight and on the memory they hold. | [API: request heads, paths and queries](api.md#request-heads-paths-and-queries), [API: limits on what one request and one key may hold](api.md#limits-on-what-one-request-and-one-key-may-hold) |
| Responses are framed by the gateway since commit e4e30e4: an answer over 64 KiB is sent chunked, file downloads included, which used to carry the file's length. A client that reads nothing of a response is disconnected after 30 seconds, not five minutes. | [Upgrading: what changes for clients](upgrading.md#what-changes-for-clients) |
| Bills can change: an abandoned stream is billed (by estimate if need be, and since commit e4e30e4 after its upstream has been read on in the background for up to two minutes), media jobs are priced from what is sent to the provider, and job creation has a second rate limit, a cap on unfinished jobs and, since commit d79406b, a cap on jobs per key per day. A media route priced per second now refuses a job that names no duration unless its target has `default_seconds`. | [Operations: streams that end early](operations.md#streams-that-end-early), [Operations: rate limits](operations.md#rate-limits), [Configuration: media routes](configuration.md#mediaroutes) |
| `retention.ledger_ids_days` defaults to 3 days since commit d79406b (it was 14 days from commit 3a0b147 until then; before that the ids were kept for ever). Set it higher before upgrading if a data plane can hold undelivered usage for longer than three days. | [Operations: retention](operations.md#retention), [Upgrading: defaults that changed](upgrading.md#defaults-that-changed) |
| The reason of a gateway error moved from `error.type` to `error.code`, and errors now have the shape of the client's protocol. Since commit 10bc009 the control plane's errors (jobs API, file downloads, admin API) have that same envelope too. A provider's 429 reaches the client as 429 instead of 502 whenever no target succeeded. | [API: Errors](api.md#errors) |
| The ledger is several files (segments and snapshots) instead of one, and since commit d79406b also one file of duplicate-detection ids per day (`ledger.ids.YYYY-MM-DD`); large job inputs are in a directory next to the job log (`jobs.jsonl.inputs/`). Nothing needs migrating, but backups must take all of them, and a ledger snapshot written by the current code is not read by code from before d79406b. | [Upgrading: what changes on disk](upgrading.md#what-changes-on-disk), [Upgrading: going back](upgrading.md#going-back), [Deployment: Backups](deployment.md#backups) |

## How these pages relate to the README

The README is the landing page: what the project is, what has been verified
against real providers, how it compares, and a short list of known limits.
Reference material lives here and is not repeated there: every config field
and environment variable is in [Configuration](configuration.md), every
endpoint and error in [API](api.md). Where a page here quotes the README
("from the README"), it is repeating a statement about what was or was not
verified, which the README is the record for.
