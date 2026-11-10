# omnigate

A self-hostable AI gateway. Phase 0: an OpenAI- and Anthropic-compatible text
gateway with failover, streaming, usage metering and budgets.

```
 apps ──▶ dataplane (Zig)  ──▶ providers (OpenAI-style, Anthropic-style)
            ▲      │
   config   │      │ usage events
            │      ▼
          control (Elixir) ── ledger (JSONL) · budgets · dashboard
```

| Part | Language | Job |
|---|---|---|
| `dataplane/` | Zig 0.17 | Authenticates gateway keys, routes by model, fails over, streams responses, meters tokens |
| `control/` | Elixir 1.20 / OTP 29 | Owns config, prices and budgets; durable usage ledger; blocks keys that overspend |
| `config/` | JSON | Keys, upstreams, routes |
| `tools/mock_upstream.py` | Python | Fake providers for local testing, no API keys needed |

## What works today

- `POST /v1/chat/completions` (OpenAI shape) and `POST /v1/messages` (Anthropic shape), streaming and non-streaming
- `GET /v1/models`, `GET /healthz`
- Gateway keys via `Authorization: Bearer` or `x-api-key`; only SHA-256 hashes reach the data plane
- Failover to the next target on connection errors, 429 and 5xx, before any byte is sent to the client
- Token usage read from the response stream without buffering it
- Usage ledger appended and fsynced before it is acknowledged; totals are rebuilt from it on restart
- Budgets per key: the control plane marks a key blocked and the data plane answers 402
- Config file hot reload (control plane, every 2 s) and config polling (data plane, every 2 s)
- The data plane keeps serving its last good config when the control plane is down

## Run it locally

Erlang and Elixir are installed but not on `PATH`. In PowerShell, per session:

```powershell
$env:Path = 'C:\Program Files\Erlang OTP\bin;C:\Program Files\Elixir\bin;' + $env:Path
```

Three terminals, from the repo root:

```powershell
python tools/mock_upstream.py
```

```powershell
cd control; $env:OMNIGATE_INTERNAL_TOKEN='dev-internal-token'; mix run --no-halt
```

```powershell
cd dataplane; zig build; $env:OMNIGATE_INTERNAL_TOKEN='dev-internal-token'; $env:MOCK_API_KEY='mock-secret'; .\zig-out\bin\omnigate-dp.exe
```

Then:

```bash
curl -N http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer og-unlimited-key" -d '{"model":"demo-chat","stream":true,"messages":[{"role":"user","content":"hi"}]}'
```

The `demo-chat` route lists a mock that always returns 503 first, so every call
shows a failover. Dashboard: <http://127.0.0.1:4000/>. The `og-dev-key` key has
a $0.01 budget and is blocked after four calls.

## Tests

```powershell
cd dataplane; zig build test --summary all
cd control; mix test
```

## Environment variables

| Variable | Used by | Default |
|---|---|---|
| `OMNIGATE_INTERNAL_TOKEN` | both | required; shared secret for `/internal/*` |
| `OMNIGATE_LISTEN` | data plane | `127.0.0.1:8080` |
| `OMNIGATE_CONTROL_URL` | data plane | `http://127.0.0.1:4000` |
| `OMNIGATE_POLL_MS` | data plane | `2000` |
| `OMNIGATE_CONTROL_PORT` | control plane | `4000` |
| `OMNIGATE_CONFIG` | control plane | `../config/omnigate.dev.json` |
| `OMNIGATE_LEDGER` | control plane | `data/ledger.jsonl` |
| each upstream's `api_key_env` | data plane | provider API key |

## Using real providers

Copy `config/omnigate.example.json`, fill in model ids and prices (USD per 1M
tokens), point `OMNIGATE_CONFIG` at it, and set the provider keys as
environment variables for the data plane. This path has not been tested against
real providers yet.

## Known gaps

- A route can only use upstreams that speak the client's protocol; there is no OpenAI ↔ Anthropic translation yet.
- Usage events are sent one at a time, best effort. Events are lost while the control plane is down.
- Budgets are enforced after the fact, with up to one poll interval of lag, and on a single control-plane node.
- No rate limiting, no caching, no TLS listener, no request timeouts.
- The control plane binds to localhost and `/admin` and `/` have no authentication.
- Cached-token and reasoning-token prices are not modelled; cost is input and output tokens only.
- Zig 0.17 standard-library quirks worked around: `http.Client.fetch` panics on a reset keep-alive connection, and `privileged_headers` are never sent.

## Next

1. Batched, retried usage reporting with a local spool
2. Cluster-wide budgets and rate limits across control-plane nodes
3. LiteLLM config import
4. Phase 1: async image and video jobs
