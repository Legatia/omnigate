# Contributing to omnigate

Thanks for looking. This page covers how to build the two processes, how to
run every test suite, where things live, and the conventions the existing
code follows.

The repository does not have a license file yet. Ask the maintainer about
terms before assuming any.

Security problems: do not open a public issue. See [SECURITY.md](SECURITY.md).

## Prerequisites

- Zig 0.17 (the container build pins 0.17.0; see `dataplane/Dockerfile`)
- Erlang/OTP 29 with Elixir 1.20 (the container build uses Elixir 1.20.5)
- Python 3.9 or newer; the tools use the standard library only, with one
  exception: the SDK compatibility test needs the official SDKs
  (`pip install openai anthropic`)
- Docker with the Compose plugin, only for the container test

On Windows, Erlang and Elixir are installed but not on `PATH`. In
PowerShell, once per session:

```powershell
$env:Path = 'C:\Program Files\Erlang OTP\bin;C:\Program Files\Elixir\bin;' + $env:Path
```

## Build

Data plane:

```bash
cd dataplane && zig build
```

The binary is `dataplane/zig-out/bin/omnigate-dp`. For an optimized build
(what the container image and the README's measurements use):

```bash
cd dataplane && zig build -Doptimize=ReleaseSafe
```

Control plane:

```bash
cd control && mix deps.get && mix compile
```

To run both by hand against the mock providers, follow the
[Quickstart](docs/quickstart.md).

## Tests

There are six suites and a formatting check. CI
(`.github/workflows/ci.yml`) runs all of them on Linux for every push and
pull request to `main`.

Data plane unit tests:

```bash
cd dataplane && zig build test --summary all
```

Control plane formatting check and unit tests:

```bash
cd control && mix format --check-formatted
```

```bash
cd control && mix test
```

The tests use their own port (4999) and throwaway files in the system temp
directory, so they do not disturb a running dev instance. If the formatting
check fails, run `mix format` and commit the result.

LiteLLM importer tests:

```bash
python tools/test_import_litellm.py
```

End-to-end test, from the repository root, after building the data plane:

```bash
python tools/e2e.py
```

It starts the mock providers, the control plane and the gateway on their
own ports (control plane 14000, gateway 18080, mocks 9001-9005 and
9101-9109) with state in a temp directory, and exits non-zero if any check
fails. `--only text` or `--only media` runs one half; `--keep` leaves the
logs and state in place. On failure it prints where the logs are.

SDK compatibility test, also from the repository root with a built data
plane. It needs the two official SDKs, which the repository itself does not
depend on:

```bash
pip install openai anthropic
```

```bash
python tools/sdk_compat.py
```

It starts the same stack as `tools/e2e.py --only text` (so it cannot run at
the same time as the end-to-end test) and drives the gateway through the
OpenAI and Anthropic Python SDKs: sync and async, streaming and not, both
translation directions, and the exception classes each SDK raises. Places
where the gateway is known to differ from the real APIs print `GAP` and do
not fail the run unless `--strict` is given; `--keep` leaves the logs. CI
installs the latest SDK releases, so a failure in the `sdk` job that your
change did not cause may come from a new SDK version; the job log prints
the versions it ran.

Container test (needs a Linux Docker daemon):

```bash
python3 tools/container_test.py --compose
```

It builds both images, brings up `compose.yaml` with mock providers added,
and runs its checks through the TLS proxy on `127.0.0.1:18443`. Without
`--compose` it uses plain `docker` commands; `--no-build` reuses images
built earlier; `--keep` leaves the containers running.

No test needs an API key. Checks against real providers were done by hand
and are recorded in the README.

Not in CI: the load and soak test, which runs against a gateway you start
yourself (see [Operations](docs/operations.md#load-testing)), and the
benchmark.

```bash
python tools/load_test.py --gateway http://127.0.0.1:8080 --key og-unlimited-key --model demo-direct --failover-model demo-chat --duration 60
```

Run it when you touch connection handling, timeouts, the usage queue or
shutdown in the data plane; that is where it found the bugs it was written
for.

## Layout

```
dataplane/            Zig data plane: the public port
  build.zig, build.zig.zon
  src/main.zig        startup, environment variables, the accept loop, stop signals and shutdown
  src/proxy.zig       request handling: auth, limits, routing, failover, streaming, job passthrough
  src/translate.zig   OpenAI chat completions <-> Anthropic messages (pure functions)
  src/config.zig      the config snapshot and its lookups
  src/control.zig     talks to the control plane: config pull, usage and counter push, config cache
  src/reporter.zig    the usage spool and its delivery loop
  src/usage.zig       token counting from the response stream, prompt-cache tokens included
  src/cache.zig       the exact-match response cache
  src/headers.zig     which provider response headers reach the client
  src/counters.zig    counts of requests refused before routing
  src/watchdog.zig    deadlines for client connections and streams
  src/logging.zig     log level, JSON lines, the access log
  src/ratelimit.zig   per-key token buckets
  src/health.zig      upstream cooldowns
  src/balance.zig     target ordering: failover, round_robin, weighted
  src/quirks.zig      learned provider quirks (sampling parameters, thought signatures)
  Dockerfile

control/              Elixir control plane
  mix.exs, config/config.exs, .formatter.exs
  lib/omnigate_control/
    application.ex    supervision tree, paths, bind address
    config_store.ex   loads, normalizes and hot-reloads the config file
    router.ex         every HTTP route: /internal, /admin, /metrics, dashboard, login
    admin_auth.ex     admin token, sessions, CSRF tokens, failed-login throttle
    keys.ex           managed gateway keys and the keys file
    admin.ex          what operators see: key listings, the overview document
    dashboard.ex      the dashboard page (HTML, CSS and script in one module)
    audit.ex          the admin audit log
    rejections.ex     refused-request counts reported by data planes
    ledger.ex         the usage ledger, including spend per budget period
    metrics.ex        Prometheus output
    retention.ex      periodic cleanup
    jobs.ex           the job API's logic: create, cancel, cost, cache, resume
    jobs/store.ex     durable job state
    jobs/runner.ex    runs one job: submit, poll, re-host, fail over
    jobs/adapter.ex   the adapter behaviour and the kind -> module table
    jobs/adapters/    one module per provider shape
    storage.ex, storage/local.ex, storage/s3.ex, sigv4.ex, url_signer.ex
    webhooks.ex       signing, delivery, retries
    http.ex           outbound HTTP on OTP's httpc
  test/
  Dockerfile

config/
  omnigate.dev.json       mock providers; the default config for local runs
  omnigate.example.json   template for real providers

tools/                Python, standard library only (sdk_compat.py excepted)
  mock_upstream.py, mock_media.py   mock providers, object store, webhook receiver
  e2e.py, container_test.py         the two system tests
  sdk_compat.py                     the official OpenAI and Anthropic SDKs as clients
  load_test.py                      load and soak test against a running gateway
  bench.py                          latency measurement
  import_litellm.py, test_import_litellm.py

compose.yaml, deploy/Caddyfile, .env.example   the Compose deployment
docs/                                          documentation

.github/
  workflows/ci.yml                  CI: six jobs
  workflows/release.yml             release on a version tag (docs/releasing.md)
  actions/setup-zig/                installs the Zig version pinned in dataplane/Dockerfile
  release/dataplane.Dockerfile      release image built from cross-compiled binaries
```

## Conventions

These are what the existing code does. Follow them unless you have a reason
not to, and say the reason in the commit.

### General

- **Say what was verified.** The README separates what has been checked
  against real providers from what has only met a mock, and most adapter
  modules repeat it in their documentation. When you add or change provider
  behaviour, update those statements in the same change, and do not claim
  more than you ran.
- **Keep the README's "Known gaps" honest.** A new limitation goes there
  when it is introduced.
- **No secrets in the repository**, and no placeholders that look like
  them: a dev placeholder with a real secret's prefix has triggered secret
  scanning before. Provider keys are only ever named by environment
  variable.
- **Dependencies are a cost.** The data plane uses only the Zig standard
  library, the control plane has two direct Hex packages (Bandit and Plug),
  and the tools use only the Python standard library (`tools/sdk_compat.py`
  imports the two SDKs it tests, inside a function, so that nothing else
  gains the dependency). Adding one needs a reason.
- **Error answers have one shape:**
  `{"error": {"type": "<snake_case>", "message": "<plain sentence>"}}`. A new
  error type is part of the API: add it to `docs/api.md` (or `docs/admin.md`
  for the admin API) and the troubleshooting table in `docs/operations.md`.
  In the data plane the `type` of a refusal is also the `reason` it is
  counted under, so it shows up as a metric label.
- Files use LF line endings (`.gitattributes`).

### Zig (data plane)

- Each file starts with a `//!` comment that explains what the module is
  for and the trade-offs it makes. Keep it current.
- Unit tests live in the file they test. `src/main.zig` has a `test` block
  that references each module; a new module with tests must be added there
  or its tests will not run.
- Shared state is a struct with its own `Io.Mutex`, in memory, per process
  (`Limiter`, `Health`, `Quirks`, `Cache`, `Watchdog`, and the two
  `Counters`: round-robin positions in `balance.zig`, refusal counts in
  `counters.zig`). Anything that must survive a restart or be shared across
  processes belongs in the control plane.
- Nothing on the request path may wait on the control plane. Usage goes
  through the reporter's queue; config comes from the installed snapshot.
- Nothing on the request path may wait on a peer without a deadline. A
  connection task arms its `watchdog.Conn` before it may block on the
  client or the upstream and re-arms it whenever bytes move.
- Decision logic is written as pure functions where possible so it can be
  tested exhaustively (`balance.order`, the translation functions).
- Fields added to the config snapshot must be optional with a default, and
  unknown values must degrade safely: an older data plane has to keep
  working with a newer control plane (see the tests in `config.zig`).
- Standard-library workarounds are commented at the point of use and listed
  in the README.

### Elixir (control plane)

- Every module has a `@moduledoc` that describes behaviour, including
  failure and restart behaviour.
- State that must survive a restart is written to disk and synced before
  the change is visible or acknowledged (`Ledger`, `Jobs.Store`), and
  replayed at start.
- Jobs and ledger events are JSON-shaped maps with string keys, as stored.
  The normalized config uses atom keys.
- Config values are validated in `ConfigStore.normalize/1`. A missing
  required field or an invalid value raises, which stops a start and makes a
  reload keep the previous config; the newer checks (`models`, `strategy`,
  `weight`, `retention`) raise with a message that names the field, and new
  ones should too.
- JSON uses the standard library's `JSON` module; outbound HTTP goes
  through `OmnigateControl.Http`.
- Secrets are compared with `Plug.Crypto.secure_compare/2`.
- The code is formatted with `mix format`; `control/.formatter.exs` sets
  `line_length: 160`. CI runs `mix format --check-formatted` and fails on a
  file that is not formatted, so run `mix format` before committing.
- Admin actions that change state are recorded with `Audit.record/5`, with
  the outcome and never a secret; a new one should be too.

### Adding a media adapter

The existing adapters all followed the same steps:

1. A module in `control/lib/omnigate_control/jobs/adapters/` implementing
   the `OmnigateControl.Jobs.Adapter` behaviour (`submit/4`, and `poll/5` /
   `cancel/5` for async providers). Its `@moduledoc` documents the provider
   calls, the job `input` it accepts, and what was verified.
2. An entry in `Adapter.for_kind/1` and `Adapter.kinds/0`.
3. A mock of the provider in `tools/mock_media.py` and checks in
   `tools/e2e.py`.
4. An example upstream and route in `config/omnigate.example.json`, a
   section in `docs/providers.md`, and the status in the README.

### Python (tools)

- Standard library only, Python 3.9 compatible. `sdk_compat.py` is the one
  exception, and says how to install what it needs when it is missing.
- Each tool starts with a docstring that shows how to run it and what it
  needs.
- The system tests print one `PASS` / `FAIL` line per check and exit
  non-zero when any check fails.

### Commits

Commit subjects are short and say what changed
("Gemini media adapter: image and speech models through the job API"). The
body explains what and why, and states what was verified and how. Tests,
README status and example config change in the same commit as the feature.

## Pull requests

- Run the unit suites, `mix format --check-formatted` and `tools/e2e.py`
  before opening one. Run `tools/sdk_compat.py` if you touched request or
  response handling, translation or error answers. Run the container test
  if you touched a Dockerfile, `compose.yaml`, `deploy/Caddyfile` or the
  mocks.
- If you change the final stage of `dataplane/Dockerfile` (user, volume,
  environment, entry point), make the same change in
  `.github/release/dataplane.Dockerfile`; the release workflow fails when
  the two differ.
- Add an entry under "Unreleased" in [CHANGELOG.md](CHANGELOG.md).
- Update `docs/` when behaviour, configuration or an error type changes.

## Releases

Cutting a release is described in [docs/releasing.md](docs/releasing.md).
