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
| Monitor it, understand limits and timeouts, read its logs, or debug an error | [Operations](operations.md) |
| Understand how the two processes divide the work | [Architecture](architecture.md) |
| Convert a LiteLLM proxy config | [Migrating from LiteLLM](migrating-from-litellm.md) |
| Cut a release (maintainers) | [Releasing](releasing.md) |

## Related files in the repository

- [`README.md`](../README.md): overview, what has been verified, comparison, measurements, known limits.
- [`config/omnigate.dev.json`](../config/omnigate.dev.json): the config the quickstart uses, with mock providers.
- [`config/omnigate.example.json`](../config/omnigate.example.json): a template for real providers.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): building, tests, code layout.
- [`SECURITY.md`](../SECURITY.md): reporting a vulnerability, security model, past advisories.
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

## If you are upgrading from an earlier commit

Three things changed in ways an existing installation or client can notice.
Each is described where it belongs; this is the list of where to look.

| Change | Read |
|---|---|
| An authentication bypass on the control plane was fixed in commit 97cf396. If your control plane or dashboard host was reachable by anyone you do not trust, there are things to check. | [SECURITY.md](../SECURITY.md#past-advisories) |
| The reason of a gateway error moved from `error.type` to `error.code`, errors now have the shape of the client's protocol, and a provider's 429 reaches the client as 429 instead of 502. | [API: Errors](api.md#errors) |
| The ledger is now several files (segments and snapshots) instead of one. Nothing needs migrating, but backups must take all of them. | [Deployment: Backups](deployment.md#backups) |

## How these pages relate to the README

The README is the landing page: what the project is, what has been verified
against real providers, how it compares, and a short list of known limits.
Reference material lives here and is not repeated there: every config field
and environment variable is in [Configuration](configuration.md), every
endpoint and error in [API](api.md). Where a page here quotes the README
("from the README"), it is repeating a statement about what was or was not
verified, which the README is the record for.
