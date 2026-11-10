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
  exception: the SDK compatibility test needs the official SDKs, at the
  versions CI pins (`pip install openai==3.49.0 anthropic==2.8.0`)
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

Add `-Dstrip=true` to leave the debug information out, as
`dataplane/Dockerfile` does; a panic still names itself in one log line.
The version the binary reports (in its `user-agent`) comes from
`dataplane/build.zig.zon`, and the control plane's from `control/mix.exs`;
nowhere else.

Control plane:

```bash
cd control && mix deps.get && mix compile
```

To run both by hand against the mock providers, follow the
[Quickstart](docs/quickstart.md).

## Tests

There are seven suites and a formatting check. CI
(`.github/workflows/ci.yml`) runs all of them on Linux for every push and
pull request to `main`.

One command runs everything except the container test, in order, with each
step's output in a log file and a summary at the end:

```bash
python tools/check.py
```

`--quick` runs only the builds, unit tests and formatting checks (about a
minute); `--only e2e sdk` and `--skip malformed` choose steps; `--list`
shows them. Its steps are `build`, `zig-test`, `zig-fmt`
(`zig fmt --check`, which CI does not run), `mix-format`, `mix-test`,
`importer`, `e2e`, `sdk` (skipped when the two SDKs are not installed) and
`malformed`. It needs `zig` and `mix` on `PATH` (on Windows it adds the
default install folders of Erlang and Elixir itself; set `ZIG` to the
compiler's path if it is elsewhere). The suites one by one:

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
pip install openai==3.49.0 anthropic==2.8.0
```

```bash
python tools/sdk_compat.py
```

It starts the same stack as `tools/e2e.py --only text` (so it cannot run at
the same time as the end-to-end test) and drives the gateway through the
OpenAI and Anthropic Python SDKs: sync and async, streaming and not, both
translation directions, the exception classes each SDK raises, and the
details an SDK user would notice (request ids, error codes and envelopes,
the model endpoints, a provider's 429, structured output). Every case must
pass; there is no mode that tolerates known gaps. `--keep` leaves the logs.

The two versions above are the ones the suite was written against, and CI
installs exactly those (`OPENAI_SDK_VERSION` and `ANTHROPIC_SDK_VERSION` at
the top of `.github/workflows/ci.yml`), so a new SDK release cannot turn CI
red by itself. To move to newer SDKs, run the suite locally with them, fix
what they notice, and change the two numbers in the workflow and on this
page in the same pull request. The job log prints the versions it ran.

Hostile-input test, from the repository root with a built data plane:

```bash
python tools/malformed_test.py
```

It starts the mock providers, the control plane and the gateway through
the end-to-end harness (so it cannot run at the same time as the
end-to-end or SDK suites) and sends, over raw sockets, the requests that
used to crash the data plane or slip past a check (a header line without a
colon, a `POST` without a length, deeply nested JSON, smuggling attempts,
non-canonical paths) and 250 generated variations of broken request heads,
asking `/healthz` after every one. Then it checks that a client which
hangs up mid-stream is still billed: the provider's real figures when they
arrive, an estimate marked as one when they never do. It passes only if
the gateway survived all of it and every case with one right answer got
that answer. The generated cases are seeded: a failure prints the seed,
and `--seed` replays it; `--count` sets how many, and `--thorough` runs
1,500. When a case fails the logs are kept and their directory printed.

To test a gateway you started yourself instead (as in the
[Quickstart](docs/quickstart.md#3-run-the-pieces-by-hand)):

```bash
python tools/malformed_test.py --gateway 127.0.0.1:8080 --key og-unlimited-key --model demo-direct --rpm-key og-ratelimited-key
```

The billing checks then run only with `--events-url`, `--drip-model` and
`--stall-model`. Never point it at a production gateway.

Container test (needs a Linux Docker daemon):

```bash
python3 tools/container_test.py --compose
```

It builds both images, brings up `compose.yaml` with mock providers added
and one environment file per container, and runs its checks through the
TLS proxy on `127.0.0.1:18443` (a second proxy with a closed admin
allow-list listens on `127.0.0.1:18444`). The checks include requests sent
byte for byte through the proxy: odd spellings of guarded paths, malformed
and oversized requests, and that the data-plane container holds no admin
token. Without `--compose` it uses plain `docker` commands; `--no-build`
reuses images built earlier; `--keep` leaves the containers running.

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
for. Run the hostile-input test as well when you touch request parsing,
path handling or anything that forwards client bytes.

## Layout

```
dataplane/            Zig data plane: the public port
  build.zig, build.zig.zon
  src/main.zig        startup, environment variables (read strictly), the accept loop, stop signals and shutdown
  src/proxy.zig       request handling: auth, limits, routing, failover, streaming, job passthrough
  src/guard.zig       checks on bytes from the network before anything else reads them: request heads, paths, JSON depth
  src/translate.zig   OpenAI chat completions <-> Anthropic messages (pure functions)
  src/errors.zig      the gateway's own errors in each protocol's shape; reason -> category table
  src/models.zig      GET /v1/models and /v1/models/{id} in each protocol's shape
  src/config.zig      the config snapshot and its lookups
  src/control.zig     talks to the control plane: config pull, usage and counter push, config cache
  src/reporter.zig    the usage spool and its delivery loop
  src/usage.zig       token counting from the response stream (a small JSON reader), prompt-cache tokens, estimates
  src/cache.zig       the exact-match response cache
  src/headers.zig     which provider and control-plane response headers reach the client
  src/counters.zig    counts of requests refused before routing
  src/watchdog.zig    deadlines for client connections and streams
  src/logging.zig     log level, JSON lines, the access log
  src/ratelimit.zig   per-key token buckets
  src/health.zig      upstream cooldowns
  src/balance.zig     target ordering: failover, round_robin, weighted
  src/quirks.zig      learned provider quirks (sampling parameters, thought signatures), per gateway key
  Dockerfile

control/              Elixir control plane
  mix.exs, config/config.exs, .formatter.exs
  lib/omnigate_control/
    application.ex    supervision tree, paths, bind address, startup checks
    env.ex            numeric environment variables, read strictly
    errors.ex         the one error envelope and its category table
    config_store.ex   loads, normalizes and hot-reloads the config file
    router.ex         every HTTP route: /internal, /admin, /metrics, dashboard, login
    admin_auth.ex     admin token, sessions, CSRF tokens, the throttles for failed logins and wrong tokens
    rate_limit.ex     per-key requests per minute for job creation
    net_guard.ex      which addresses may be called when the URL came from a client or a provider
    keys.ex           managed gateway keys and the keys file
    admin.ex          what operators see: key listings, the overview document
    dashboard.ex      the dashboard page (HTML, CSS and script in one module)
    audit.ex          the admin audit log
    rejections.ex     refused-request counts reported by data planes
    ledger.ex         the usage ledger: totals, spend per budget period, snapshots, sealing
    ledger/files.ex   the ledger on disk: segments, snapshot files, crash safety
    metrics.ex        Prometheus output
    retention.ex      periodic cleanup
    jobs.ex           the job API's logic: create, cancel, cost, cache, resume
    jobs/store.ex     durable job state
    jobs/runner.ex    runs one job: submit, poll, re-host, fail over
    jobs/adapter.ex   the adapter behaviour (submit, poll, cancel, billable) and the kind -> module table
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
  malformed_test.py                 hostile input against a gateway it starts (or one you name)
  check.py                          runs every suite but the container test, with a summary
  load_test.py                      load and soak test against a running gateway
  bench.py                          latency measurement
  import_litellm.py, test_import_litellm.py

compose.yaml, deploy/Caddyfile                 the Compose deployment
.env.example                                   host names and the admin allow-list (read by Compose)
.env.control.example, .env.dataplane.example   one environment file per container
docs/                                          documentation

.github/
  workflows/ci.yml                  CI: seven jobs
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
- **Keep the README honest and short.** A new limitation goes into its
  "Known limits" when it is introduced, and a limitation the code no longer
  has comes out in the same change. Something checked against a real
  provider goes into "What has been verified"; do not move a line there on
  the strength of a mock. The README carries no counts of test checks and
  no reference tables: those live in `docs/`.
- **No secrets in the repository**, and no placeholders that look like
  them: a dev placeholder with a real secret's prefix has triggered secret
  scanning before. Provider keys are only ever named by environment
  variable.
- **Each process gets only its own secrets.** A new variable goes into the
  example file of the container that reads it (`.env.control.example` or
  `.env.dataplane.example`), never into both for convenience, and nothing
  the data plane does not read goes into its file.
- **Dependencies are a cost.** The data plane uses only the Zig standard
  library, the control plane has two direct Hex packages (Bandit and Plug),
  and the tools use only the Python standard library (`tools/sdk_compat.py`
  imports the two SDKs it tests, inside a function, so that nothing else
  gains the dependency). Adding one needs a reason.
- **Error answers have one shape, written in two places.** The gateway's
  reason (`<snake_case>`) is `error.code`; `error.type` is the provider's
  broader category for it.
  - Data plane: every error goes through `errors.zig`, which writes it in
    the shape of the client's protocol. The reason is also what a refusal
    is counted under, so it shows up as a metric label. A new reason needs
    a row in `typesFor` (or a deliberate decision to let the status decide)
    and a line in the test that lists every reason.
  - Control plane: every error goes through `send_error` in `router.ex`,
    which builds the OpenAI-style envelope with
    `OmnigateControl.Errors.body/4`. `errors.ex` holds a copy of the OpenAI
    column of `typesFor`; change the two tables together, so that a client
    of `/v1/jobs` cannot tell which process refused it.
  - Either way a new reason is part of the API: add it to `docs/api.md` (or
    `docs/admin.md` for the admin API) and to the troubleshooting table in
    `docs/operations.md`.
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
- No input may reach code that asserts on its shape: a panic in one
  connection's task ends the process for all of them. Bytes from a client
  or an upstream go through `guard.zig` first (request heads, paths, JSON
  depth), headers are iterated with `guard.HeaderIterator`, not the
  standard library's, and anything a client sent is copied into a request
  of the gateway's own only after it has been checked character by
  character. A new parser of peer input needs a test that feeds it garbage.
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
  loaded or replayed at start.
- Jobs and ledger events are JSON-shaped maps with string keys, as stored.
  The normalized config uses atom keys.
- Numeric environment variables go through `OmnigateControl.Env` (and
  `envInt` in the data plane's `main.zig`): a value is a well-formed number
  in range or a startup error that names the variable, never a silent
  default. A new one is added to `Env.check_all/0`.
- Config values are validated in `ConfigStore.normalize/1`. A missing
  required field or an invalid value raises, which stops a start and makes a
  reload keep the previous config; the newer checks (`models`, `strategy`,
  `weight`, `retention`) raise with a message that names the field, and new
  ones should too.
- JSON uses the standard library's `JSON` module; outbound HTTP goes
  through `OmnigateControl.Http`.
- Secrets are compared with `Plug.Crypto.secure_compare/2`.
- The router's guards deny by default. A route under a new first path
  segment answers 404 until that segment is added to the guard in
  `router.ex`, with a decision about which credential it needs; say which
  in the commit. No route may need a percent-encoded character in its path.
- A URL that came from a client or a provider is never fetched directly.
  It goes through `NetGuard.target/2`, and the request is made to the
  address that returned (`connect_to:`), with redirects followed by our
  own code one checked hop at a time.
- What a media job costs comes from the adapter's `billable/1`, which must
  describe the request the adapter actually builds. An adapter that sends
  a new text or duration field has to count it there.
- The code is formatted with `mix format`; `control/.formatter.exs` sets
  `line_length: 160`. CI runs `mix format --check-formatted` and fails on a
  file that is not formatted, so run `mix format` before committing.
- Admin actions that change state are recorded with `Audit.record/5`, with
  the outcome and never a secret; a new one should be too.

### Adding a media adapter

The existing adapters all followed the same steps:

1. A module in `control/lib/omnigate_control/jobs/adapters/` implementing
   the `OmnigateControl.Jobs.Adapter` behaviour (`submit/4`, `billable/1`,
   and `poll/5` / `cancel/5` for async providers). `billable/1` returns the
   characters of text and the seconds of media in the request `submit/4`
   builds; it is what per-character and per-second prices are applied to.
   Its `@moduledoc` documents the provider calls, the job `input` it
   accepts, and what was verified.
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

- Run `python tools/check.py` before opening one: the unit suites, the
  formatting checks, `tools/e2e.py`, `tools/malformed_test.py` and, when
  the two SDKs are installed, `tools/sdk_compat.py`. Install the SDKs and
  let that step run if you touched request or response handling,
  translation or error answers. Run the container test, which `check.py`
  leaves out, if you touched a Dockerfile, `compose.yaml`,
  `deploy/Caddyfile`, an `.env*.example` file or the mocks.
- If you change the final stage of `dataplane/Dockerfile` (user, volume,
  environment, entry point), make the same change in
  `.github/release/dataplane.Dockerfile`; the release workflow fails when
  the two differ.
- Add an entry under "Unreleased" in [CHANGELOG.md](CHANGELOG.md).
- Update `docs/` when behaviour, configuration or an error type changes.
- A fix for a vulnerability gets an entry under "Security" in the
  changelog and an advisory in [SECURITY.md](SECURITY.md#past-advisories)
  that says what was wrong, who was affected and what to do.

## Releases

Cutting a release is described in [docs/releasing.md](docs/releasing.md).
