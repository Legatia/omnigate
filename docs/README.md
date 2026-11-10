# omnigate documentation

omnigate is a self-hostable AI gateway made of two processes: a data plane
(Zig) that applications talk to, and a control plane (Elixir) that owns
configuration, the usage ledger, budgets and media jobs. The
[project README](../README.md) has the overview, the comparison with other
gateways and the full list of known gaps.

These pages describe the code as committed. Where a feature has only been
exercised against a mock, or not at all, the page says so in the same words
the README uses.

## Start here

| If you want to | Read |
|---|---|
| Run it on your machine with mock providers, then with a real one | [Quickstart](quickstart.md) |
| Write or change the config file, or look up an environment variable | [Configuration](configuration.md) |
| Call the gateway from an application | [API reference](api.md) |
| Connect OpenAI, Anthropic, Gemini, xAI or a media provider | [Providers](providers.md) |
| Put it on a server with TLS | [Deployment](deployment.md) |
| Monitor it, set budgets and limits, or debug an error | [Operations](operations.md) |
| Understand how the two processes divide the work | [Architecture](architecture.md) |
| Convert a LiteLLM proxy config | [Migrating from LiteLLM](migrating-from-litellm.md) |

## Related files in the repository

- [`README.md`](../README.md): overview, comparison, measurements, known gaps.
- [`config/omnigate.dev.json`](../config/omnigate.dev.json): the config the quickstart uses, with mock providers.
- [`config/omnigate.example.json`](../config/omnigate.example.json): a template for real providers.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): building, tests, code layout.
- [`SECURITY.md`](../SECURITY.md): reporting a vulnerability, security model.
- [`CHANGELOG.md`](../CHANGELOG.md): what changed.

## Status in one paragraph

From the README, as of November 2026: the text gateway and the OpenAI image,
ElevenLabs speech, Replicate, Gemini (image, speech, video) and xAI video
adapters have been checked against the real APIs, and bucket storage against
Cloudflare R2. The fal adapter has only met a mock, and nothing has run under
production load. [Providers](providers.md) lists the status of each one.
