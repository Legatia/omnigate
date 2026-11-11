# Quickstart

Two parts: run everything locally against the mock providers that ship in
`tools/` (no API keys needed), then point the gateway at one real provider.

## Prerequisites

- Zig 0.17
- Erlang/OTP 29 with Elixir 1.20
- Python 3.9 or newer. The tools use the standard library only, except the
  optional SDK test, which needs the two official SDKs
  (`pip install openai==3.49.0 anthropic==2.8.0`, the versions CI pins).

The README records what has been tried: Windows 11 and x86-64 Linux, where
CI builds and runs both processes on Ubuntu 24.04 for every push. macOS and
ARM are untried. The commands below are given for PowerShell (as in the
README) and for a POSIX shell.

On Windows, Erlang and Elixir are installed but not on `PATH`. In PowerShell,
once per session:

```powershell
$env:Path = 'C:\Program Files\Erlang OTP\bin;C:\Program Files\Elixir\bin;' + $env:Path
```

## 1. Build the data plane

```bash
cd dataplane && zig build
```

The binary is `dataplane/zig-out/bin/omnigate-dp` (`omnigate-dp.exe` on
Windows).

## 2. Check the build with the end-to-end test (optional)

From the repository root:

```bash
python tools/e2e.py
```

It starts the mock providers, the control plane and the gateway on their own
ports (control plane 14000, gateway 18080, mocks 9001-9005 and 9101-9109),
keeps its state in a temporary directory, and exits non-zero if any check
fails. It needs those ports to be free, so run it before you start the pieces
by hand, not at the same time.

If you have the official OpenAI and Anthropic Python SDKs installed,
`python tools/sdk_compat.py` runs the same local stack through them; see
[Using the official SDKs](api.md#using-the-official-sdks).

A third tool, `python tools/malformed_test.py`, starts the same kind of
stack and sends it malformed and hostile requests; the gateway must
survive all of them. It also plays an upstream and a control plane that
answer like an attacker (for which it uses ports 4300, 8190 and 9006 besides
the ones above), checks the limits that apply before a request body is read,
and checks that a client which hangs up or stops reading is still billed
([Operations](operations.md#hostile-input-testing)). And
`python tools/check.py` runs every suite a change
should pass (builds, unit tests, formatting, these three) with one command;
`--quick` runs only the unit tests and formatting checks.

## 3. Run the pieces by hand

Four terminals, all starting in the repository root.

Terminal 1, mock text providers (ports 9001-9005):

```bash
python tools/mock_upstream.py
```

Terminal 2, mock media providers, object store and webhook receiver (ports
9101-9109):

```bash
python tools/mock_media.py
```

Terminal 3, the control plane (port 4000). PowerShell:

```powershell
cd control; $env:OMNIGATE_INTERNAL_TOKEN='dev-internal-token'; $env:OMNIGATE_ADMIN_TOKEN='dev-admin-token-change-me'; $env:MOCK_API_KEY='mock-secret'; mix run --no-halt
```

POSIX shell:

```bash
cd control && OMNIGATE_INTERNAL_TOKEN=dev-internal-token OMNIGATE_ADMIN_TOKEN=dev-admin-token-change-me MOCK_API_KEY=mock-secret mix run --no-halt
```

The first run needs `mix deps.get` in `control/` beforehand.

Terminal 4, the data plane (port 8080). PowerShell:

```powershell
cd dataplane; $env:OMNIGATE_INTERNAL_TOKEN='dev-internal-token'; $env:MOCK_API_KEY='mock-secret'; .\zig-out\bin\omnigate-dp.exe
```

POSIX shell:

```bash
cd dataplane && OMNIGATE_INTERNAL_TOKEN=dev-internal-token MOCK_API_KEY=mock-secret ./zig-out/bin/omnigate-dp
```

With no `OMNIGATE_CONFIG` set, the control plane loads
`config/omnigate.dev.json`. That fallback exists only in a development
build such as this `mix run`; a release build refuses to start without the
variable. Both processes must be given the same
`OMNIGATE_INTERNAL_TOKEN`; neither starts without it. The admin token must
be at least 16 characters long, or the control plane refuses to start
(leave it unset and one is generated and logged). `MOCK_API_KEY` is the
variable the dev config's upstreams name in `api_key_env`; the mocks only
insist that it is not empty.

These tokens, and the keys in the dev config, are published in this
repository. They are for a trial on your own machine and nothing else.

The data plane prints one access-log line per request, with the key's name,
the route, the upstream that answered, tokens and latency. Stop it with
Ctrl-C: it finishes requests in flight and delivers queued usage before it
exits.

## 4. Try it

The examples use `curl` from a POSIX shell (Git Bash on Windows).

A streamed chat completion. The first upstream of `demo-chat` always answers
503, so every call fails over to the second:

```bash
curl -N http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer og-unlimited-key" -d '{"model":"demo-chat","stream":true,"messages":[{"role":"user","content":"hi"}]}'
```

The same route without streaming, showing the gateway's response headers
(`x-omnigate-upstream`, `x-omnigate-attempts`, `x-omnigate-request-id`, and
the request id again as `x-request-id` and `request-id`, where the SDKs
look for it):

```bash
curl -i http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer og-unlimited-key" -d '{"model":"demo-chat","messages":[{"role":"user","content":"hi"}]}'
```

An Anthropic-style upstream called with the OpenAI protocol (the gateway
translates):

```bash
curl http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer og-unlimited-key" -d '{"model":"demo-claude","messages":[{"role":"user","content":"hi"}]}'
```

The same upstream called with the Anthropic protocol:

```bash
curl http://127.0.0.1:8080/v1/messages -H "x-api-key: og-unlimited-key" -d '{"model":"demo-claude","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}'
```

A media job. The answer is `202` with a job object:

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer og-unlimited-key" -d '{"model":"demo-image","input":{"prompt":"a lighthouse"}}'
```

Poll it with the `id` from that answer until `status` is `succeeded`, then
open the URL in `outputs[0].url`:

```bash
curl http://127.0.0.1:8080/v1/jobs/JOB_ID -H "Authorization: Bearer og-unlimited-key"
```

Dashboard: <http://127.0.0.1:4000/>. Sign in with the admin token set above
(`dev-admin-token-change-me`). The calls you just made are under "Recent
requests" and "Recent media jobs".

Paths are taken literally: `/v1/jobs`, not `/v1/jobs/`. The gateway
answers `400` to a trailing slash, a percent-encoded character or a dot
segment in a path ([API](api.md#request-heads-paths-and-queries)).

To throw malformed requests at the gateway you just started, instead of
letting the tool start its own (it must survive all of them):

```bash
python tools/malformed_test.py --gateway 127.0.0.1:8080 --key og-unlimited-key --model demo-direct
```

Run this way it leaves out the hostile upstream and the hostile control
plane, which need a stack of its own, and the billing checks, which need
further options. Its `--rpm-key` option adds two checks of the rate limit;
`--rpm` says how many requests per minute that key allows (3 unless given).
With the dev config that is `--rpm-key og-ratelimited-key --rpm 5`.

### Create a key without editing the config

In the dashboard, fill in "Create a key" under Keys; the new key is shown
once. Or from a shell, with the admin token:

```bash
curl -X POST http://127.0.0.1:4000/admin/keys -H "Authorization: Bearer dev-admin-token-change-me" -H "Content-Type: application/json" -d '{"name":"my-app","budget_usd":5,"budget_period":"monthly"}'
```

The answer contains `"key": "og-..."`. Within a couple of seconds the
gateway accepts it:

```bash
curl http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer <the key from the answer>" -d '{"model":"demo-direct","messages":[{"role":"user","content":"hi"}]}'
```

Keys made this way are stored (as hashes) in `control/data/keys.json`, not
in the config file. Changing, rotating and deleting them is in
[Admin](admin.md).

### With an SDK

The official OpenAI and Anthropic SDKs work by pointing `base_url` at the
gateway and using a gateway key as the API key:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="og-unlimited-key")
print(client.chat.completions.create(model="demo-chat", messages=[{"role": "user", "content": "hi"}]).choices[0].message.content)
```

The Anthropic snippet, and what differs from the real APIs, is in
[Using the official SDKs](api.md#using-the-official-sdks).

### Demo routes and keys

Routes in `config/omnigate.dev.json`:

| Route | Shows |
|---|---|
| `demo-chat` | First upstream always answers 503, so every call fails over |
| `demo-claude` | Anthropic-style upstream; call it with either protocol |
| `demo-slow` | First upstream takes 3 s and is abandoned after 1 s |
| `demo-direct` | One healthy upstream, for benchmarks |
| `demo-image` | Media job on the Replicate-style adapter; the first target fails, the second delivers |
| `demo-video` | Media job on the fal-style adapter. Priced per second, so a job must name a duration: `"input":{"prompt":"waves","duration":5}`. Without one it is refused with `400 invalid_request` |
| `demo-image-sync` | Media job on the OpenAI-images-style adapter |
| `demo-tts` | Media job on the ElevenLabs-style adapter; cached (input: `text`, `voice_id`) |

Keys:

| Key | Behaviour |
|---|---|
| `og-unlimited-key` | No budget, no rate limit |
| `og-dev-key` | $0.01 budget; blocked (HTTP 402) after four calls |
| `og-ratelimited-key` | 5 requests per minute; then HTTP 429 with `Retry-After` |

## 5. One real provider

This replaces the mocks with OpenAI. Any provider from
[Providers](providers.md) works the same way.

Create `config/omnigate.json` (this path is ignored by git):

```json
{
  "keys": [
    { "name": "my-app", "key": "og-local-test-key" }
  ],
  "upstreams": [
    {
      "name": "openai",
      "kind": "openai",
      "base_url": "https://api.openai.com",
      "api_key_env": "OPENAI_API_KEY"
    }
  ],
  "routes": [
    {
      "model": "gpt",
      "targets": [
        {
          "upstream": "openai",
          "model": "gpt-4o-mini",
          "price_in_per_mtok": 0.0,
          "price_out_per_mtok": 0.0
        }
      ]
    }
  ]
}
```

Notes on this file:

- `"key"` holds the gateway key in clear text, which is fine for a local
  trial. For anything else use `"key_sha256"`; see
  [Configuration](configuration.md#gateway-keys).
- `gpt-4o-mini` is one of the models the README lists as checked. Use any
  model id your account has.
- The prices are zero, so the ledger records tokens but no cost. Fill in
  your provider's prices in US dollars per million tokens to get spend and
  budgets.

Stop the control plane and the data plane (the mocks are no longer needed).
Start the control plane with the new config. PowerShell:

```powershell
cd control; $env:OMNIGATE_INTERNAL_TOKEN='dev-internal-token'; $env:OMNIGATE_ADMIN_TOKEN='dev-admin-token-change-me'; $env:OMNIGATE_CONFIG='../config/omnigate.json'; mix run --no-halt
```

POSIX shell:

```bash
cd control && OMNIGATE_INTERNAL_TOKEN=dev-internal-token OMNIGATE_ADMIN_TOKEN=dev-admin-token-change-me OMNIGATE_CONFIG=../config/omnigate.json mix run --no-halt
```

Start the data plane with your provider key in its environment. Text
provider keys are read by the data plane, not by the control plane. Put your
own key where the placeholder is. PowerShell:

```powershell
cd dataplane; $env:OMNIGATE_INTERNAL_TOKEN='dev-internal-token'; $env:OPENAI_API_KEY='<your OpenAI key>'; .\zig-out\bin\omnigate-dp.exe
```

POSIX shell:

```bash
cd dataplane && OMNIGATE_INTERNAL_TOKEN=dev-internal-token OPENAI_API_KEY='<your OpenAI key>' ./zig-out/bin/omnigate-dp
```

Call it:

```bash
curl http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer og-local-test-key" -d '{"model":"gpt","messages":[{"role":"user","content":"Say hello."}]}'
```

`"model"` in the request is the route name (`gpt`), not the provider's model
id. The gateway replaces it with the target's `model` before forwarding.

Edits to the config file are picked up by the control plane within about two
seconds, and by the data plane on its next poll (two seconds by default). No
restart is needed.

## Next

- [Configuration](configuration.md) for every field and variable.
- [Admin](admin.md) for the dashboard, managed keys, budgets and the audit log.
- [Providers](providers.md) to add Anthropic, Gemini, xAI and media providers.
- [Deployment](deployment.md) and [Security hardening](security.md) before
  exposing it to anything but localhost.
