# Deployment

- [Compose with TLS](#compose-with-tls)
- [Running without containers](#running-without-containers)
- [What to keep private](#what-to-keep-private)
- [Backups](#backups)
- [Upgrades](#upgrades)

Read the README's [Known gaps](../README.md#known-gaps) first. In short:
nothing has run under production load; neither process has a TLS listener of
its own; there is one shared admin token and no user accounts.

## Compose with TLS

The repository has two Dockerfiles, a `compose.yaml` and a Caddy
configuration that puts TLS in front of both processes.

### 1. Create the two files you own

```bash
cp .env.example .env
```

```bash
cp config/omnigate.example.json config/omnigate.json
```

Both paths are ignored by git.

### 2. Fill in `.env`

| Variable | Value |
|---|---|
| `OMNIGATE_INTERNAL_TOKEN` | A long random string. Shared by the two processes. |
| `OMNIGATE_ADMIN_TOKEN` | A different long random string. Dashboard password and admin API token. |
| `OMNIGATE_API_HOST` | Host name applications will use, for example `gateway.example.com`. |
| `OMNIGATE_ADMIN_HOST` | Host name for the dashboard, for example `admin.gateway.example.com`. |
| provider keys | One variable per `api_key_env` named in your config, plus bucket credentials and webhook secrets if your config names any. |

One way to make a token:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Do not leave the two tokens empty. With an empty `OMNIGATE_INTERNAL_TOKEN`
neither process starts: each logs that the variable is not set and exits,
and with `restart: unless-stopped` both containers keep restarting until it
is set. With an empty `OMNIGATE_ADMIN_TOKEN` a random one is generated at
each start and written to the control plane's log.

The same `.env` is given to both containers, so text provider keys (read by
the data plane) and media provider keys (read by the control plane) all go
in this one file.

### 3. Fill in `config/omnigate.json`

Replace every `<...>` placeholder, remove the upstreams and routes you do
not use, and set:

- `keys[].key_sha256` to the SHA-256 of each gateway key
  ([how](configuration.md#gateway-keys)), or leave `keys` empty and create
  keys from the dashboard once the stack is up ([Admin](admin.md));
- `media.public_base_url` to `https://` followed by your
  `OMNIGATE_API_HOST`, so that file URLs point at the proxy;
- `media.storage` to your bucket, or to `{"kind": "local"}` to keep outputs
  in the control plane's volume.

Field reference: [Configuration](configuration.md). Provider examples:
[Providers](providers.md).

### 4. Start

```bash
docker compose up -d --build
```

What you get, from the README:

- **`proxy`** (Caddy) is the only container with published ports (80 and
  443). It serves the gateway at `https://$OMNIGATE_API_HOST` and the
  dashboard at `https://$OMNIGATE_ADMIN_HOST`. Real DNS names get Let's
  Encrypt certificates automatically; the `localhost` defaults get
  certificates from Caddy's own CA.
- **`dataplane`** is one static binary and a CA bundle on an empty base
  image, running as a non-root user.
- **`control`** is an Alpine image with the Elixir release, running as a
  non-root user, with a health check on `/healthz`.
- **State** lives in named volumes and survives restarts.
- **The internal API** between the two is reachable only on the private
  Docker network; the proxy answers 404 for `/internal/*`.

Check it:

```bash
curl https://$OMNIGATE_API_HOST/healthz
```

```bash
docker compose ps
```

```bash
docker compose logs --tail 50 control dataplane
```

With the `localhost` defaults the certificate comes from Caddy's local CA,
which your client does not trust yet. The container test copies that CA out
of the proxy container (`/data/caddy/pki/authorities/local/root.crt`) and
verifies against it.

### Volumes

| Volume | Mounted in | Holds |
|---|---|---|
| `control-data` | `control:/data` | `ledger.jsonl`, `jobs.jsonl`, `keys.json` (managed keys), `audit.jsonl` (admin audit log), `media/` (locally stored outputs) |
| `dataplane-data` | `dataplane:/data` | `omnigate-usage.spool`, `omnigate-config.cache.json` |
| `caddy-data`, `caddy-config` | `proxy` | Certificates and Caddy's own state |

`config/omnigate.json` is mounted read-only into the control container. The
control plane re-reads it when it changes. Hot reload through this bind
mount is not covered by the container test; if an edit is not picked up
(the control log prints `reloaded config` when it is), restart the control
container.

### What the images set

The images change these defaults; everything else is as in
[Configuration](configuration.md#environment-variables).

| Image | Variable | Value |
|---|---|---|
| control | `OMNIGATE_CONTROL_BIND` | `0.0.0.0` (the container's own network; only published ports are reachable from outside) |
| control | `OMNIGATE_CONFIG` | `/config/omnigate.json` |
| control | `OMNIGATE_LEDGER` | `/data/ledger.jsonl` |
| control | `OMNIGATE_JOBS` | `/data/jobs.jsonl` |
| control | `OMNIGATE_KEYS` | `/data/keys.json` |
| control | `OMNIGATE_AUDIT_LOG` | `/data/audit.jsonl` |
| control | `OMNIGATE_MEDIA_DIR` | `/data/media` |
| dataplane | `OMNIGATE_LISTEN` | `0.0.0.0:8080` |
| dataplane | `OMNIGATE_CONTROL_URL` | `http://control:4000` |

Both run as user `10001` with `/data` as the working directory, which is
where the data plane writes its spool and config cache.

The data-plane variables for timeouts, the connection cap, the response
cache and logging are not set by the image; add the ones you want to
change to `.env` (for example `OMNIGATE_LOG_FORMAT=json` for a log
shipper). The same `.env` goes to both containers, and the control plane
ignores the ones it does not know.

**Stopping.** `docker compose stop` (or `down`, or a restart) sends
SIGTERM. The data plane then stops accepting connections, lets requests in
flight finish for up to `OMNIGATE_SHUTDOWN_GRACE_MS` (10 seconds), delivers
queued usage and exits with status 0. Compose kills a container that has
not stopped after 10 seconds by default, so if you raise the grace period,
give the `dataplane` service a longer `stop_grace_period` as well. See
[Operations](operations.md#connection-limits-and-shutdown).

### Testing the Compose file

```bash
python3 tools/container_test.py --compose
```

brings up this `compose.yaml` with mock providers added and a throwaway
config, publishes one local port (18443) instead of 80 and 443, and checks
it through TLS, including that the data-plane container shuts down cleanly
on SIGTERM. Without `--compose` the same test uses plain `docker`
commands. Needs a Linux Docker daemon and Python 3.9 or newer. CI runs it
on every push.

From the README: tested with Docker 29 and Compose 2.40 on Ubuntu 24.04
(x86-64, under WSL 2). **Not tested: ARM, Let's Encrypt issuance with a real
domain, and Kubernetes.**

## Running without containers

The same rules apply as with Compose: set both tokens, keep the control
plane on a private address, and put TLS in front of both ports.

**Data plane.** Build an optimized binary and run it with its environment:

```bash
cd dataplane && zig build -Doptimize=ReleaseSafe
```

The result is `dataplane/zig-out/bin/omnigate-dp`. It needs
`OMNIGATE_INTERNAL_TOKEN`, `OMNIGATE_CONTROL_URL`, the provider keys your
text upstreams name, and a working directory it can write to (for the spool
and config cache, or set `OMNIGATE_SPOOL` and `OMNIGATE_CONFIG_CACHE` to
absolute paths). To accept connections from a proxy on another machine, set
`OMNIGATE_LISTEN` to a non-loopback address. Stop it with SIGTERM (or
Ctrl-C) so that it drains requests and delivers queued usage before it
exits; under a service manager, allow it at least
`OMNIGATE_SHUTDOWN_GRACE_MS` before a kill.

Once a release has been tagged, prebuilt data-plane binaries for Linux
(x86-64 and arm64, static), Windows and macOS are attached to it, each
with a SHA-256 file; see [Releasing](releasing.md#what-a-release-contains).
Only the x86-64 Linux binary is executed when a release is built; the
others are cross-compiled and, like the platforms themselves, untested.

**Control plane.** The container image builds an Elixir release and starts
it. The same steps on a host (this is what `control/Dockerfile` runs; it has
not been tested separately outside the image):

```bash
cd control && MIX_ENV=prod mix deps.get --only prod && MIX_ENV=prod mix release
```

```bash
_build/prod/rel/omnigate_control/bin/omnigate_control start
```

Outside the image, set the paths explicitly, because the defaults are
relative to the working directory: `OMNIGATE_CONFIG`, `OMNIGATE_LEDGER`,
`OMNIGATE_JOBS`, `OMNIGATE_KEYS`, `OMNIGATE_AUDIT_LOG`,
`OMNIGATE_MEDIA_DIR`. The image also sets
`RELEASE_DISTRIBUTION=none` so the release does not start Erlang
distribution.

**The proxy in front.** Whatever you use, it has to do what
`deploy/Caddyfile` does:

- terminate TLS for the gateway and for the dashboard;
- pass streamed responses through without buffering (Caddy:
  `flush_interval -1`);
- refuse `/internal` and `/internal/*` from outside;
- send `X-Forwarded-Proto: https` to the control plane, so the session
  cookie is marked `Secure` (or set `OMNIGATE_COOKIE_SECURE=1`).

From the README: data-plane-to-control-plane traffic over HTTPS is untested;
keep it on a private network. Platforms other than Windows 11 and x86-64
Linux containers are not verified.

## What to keep private

| Thing | Why |
|---|---|
| The control plane's port (4000) | Dashboard, admin API, metrics and the internal API. Expose it only through a TLS proxy that hides `/internal/*`, and preferably only to operators. |
| `OMNIGATE_INTERNAL_TOKEN` | Anyone holding it can read the config snapshot, write usage events and act as any gateway key on the jobs API. It also derives the file URL signing key unless `OMNIGATE_SIGNING_SECRET` is set. |
| `OMNIGATE_ADMIN_TOKEN` | Dashboard, `/admin/*` and `/metrics`. Whoever holds it can create gateway keys and revoke existing ones. |
| `.env` | Holds both tokens and every provider key. |
| The config file | Holds gateway keys if you used `"key"` instead of `"key_sha256"`, and webhook secrets if you wrote them inline. |
| `keys.json` | Managed keys: hashes only, but a key's webhook secret in clear text if it has one. The control plane writes it with mode `0600`. |
| `audit.jsonl` | Who changed which key and who signed in, with client addresses. No secrets. |
| `ledger.jsonl`, `jobs.jsonl` | Usage per key, and every job's input (prompts), metadata and webhook URL. |
| The data plane's log | Key names, route names and request paths in the access log. Never keys, hashes or request bodies. |
| The media directory or bucket | The generated files. Buckets are assumed private; clients get presigned URLs. |
| The data plane's port (8080) | Not secret, but plain HTTP. Publish it only through TLS. |

The three credentials do not work in each other's place: a gateway key is
not accepted by the control plane, the admin token is not accepted by the
gateway, and the internal token opens only `/internal/*`.

More in [SECURITY.md](../SECURITY.md).

## Backups

What holds state that cannot be recomputed:

| What | Where (Compose) | If lost |
|---|---|---|
| The usage ledger | `control-data`: `/data/ledger.jsonl` | Spend totals are rebuilt from this file at every start. Without it all spend is zero and budget-blocked keys are unblocked. |
| Job state | `control-data`: `/data/jobs.jsonl` | Jobs, their idempotency keys, cache entries and pending webhooks are gone. |
| Managed keys | `control-data`: `/data/keys.json` | Every key created through the dashboard or the admin API stops working: the gateway answers them with 401. The keys cannot be recovered (only hashes were ever stored); you create new ones and hand them out again. Their past usage is still in the ledger but no longer belongs to a named key. |
| The admin audit log | `control-data`: `/data/audit.jsonl` | The record of key changes and sign-ins is gone. Nothing else depends on it. |
| Locally stored outputs | `control-data`: `/data/media/` | Output URLs of existing jobs answer 404. Not applicable with bucket storage. |
| Your config and `.env` | the repository directory | You re-create them by hand. File keys come back with the config. |

Restore `keys.json` together with `ledger.jsonl` from the same backup: the
ledger records usage by key hash, and `keys.json` is what ties those hashes
(including the ones from before a rotation) to a key and its budget.

The data plane's volume holds only usage events not yet delivered and a copy
of the last config; once the spool has drained there is nothing in it worth
keeping. The response cache and the refusal counts are in memory only.

A simple way to take a consistent copy is to stop the control plane, copy
the volume, and start it again. While it is stopped the gateway keeps
serving text requests and spools their usage; job requests answer 503 (see
[Operations](operations.md#when-the-control-plane-is-down)).

```bash
docker compose stop control
```

```bash
docker run --rm -v omnigate_control-data:/data:ro -v "$PWD":/backup alpine tar czf /backup/control-data.tgz -C /data .
```

```bash
docker compose start control
```

The volume name is prefixed with the Compose project name (the directory
name by default); check it with `docker volume ls`. This procedure is
ordinary Docker practice, not something the repository's tests exercise.

The ledger, the job file and the audit log are appended to and synced to
disk on every write (the job file is also rewritten compacted at start and
after a retention sweep). On start, a torn last line of the ledger or the
job file is skipped rather than treated as fatal, and unreadable lines of
the audit log are skipped too. `keys.json` is different: it is replaced
whole on every change (temporary file, sync, rename), so a copy taken at
any moment is complete; and if it exists but cannot be parsed, the control
plane refuses to start rather than run without the managed keys.

Outputs in a bucket are not backed up by the gateway. With retention on
(`jobs_days`), the gateway deletes a removed job's objects from the bucket
unless `retention.delete_bucket_objects` is `false`; see
[Operations](operations.md#retention). Back them up with the bucket's own
tools.

## Upgrades

No release has been tagged yet, and `compose.yaml` builds both images from
source, so an upgrade is a rebuild from newer source:

```bash
git pull
```

```bash
docker compose up -d --build
```

The repository has a release workflow that, when a version tag is pushed,
publishes multi-architecture images to GHCR
(`ghcr.io/<owner>/omnigate-dataplane` and `-control`, tagged with the
version and `latest`) and data-plane binaries on a GitHub release; see
[Releasing](releasing.md). It has not run yet. Once it has, you can pin
`image:` to a version in your own copy of the Compose file instead of
building.

Read [CHANGELOG.md](../CHANGELOG.md) first. What the code does during a
restart:

- **Control plane restarting.** The data plane keeps serving text requests
  from its last config and queues usage; job requests answer 503. When the
  control plane is back, queued usage is delivered and deduplicated by
  request id. Unfinished jobs resume: a job a provider had already accepted
  is polled, not submitted again. Undelivered webhooks are re-armed.
- **Data plane restarting.** On SIGTERM it stops accepting connections and
  lets requests in flight finish for up to `OMNIGATE_SHUTDOWN_GRACE_MS`
  (10 seconds); only requests still running after that are cut off. Queued
  usage is delivered before exit, and anything left in the spool is
  reloaded and delivered at the next start. If the control plane is
  unreachable at that moment, the cached config is used. Rate-limit
  buckets, cooldowns, round-robin counters, learned model quirks and the
  response cache start fresh. While the one data plane is down, clients get
  connection errors: there is no second instance in the Compose file.
- **Config compatibility.** The data plane ignores fields in the config
  snapshot that it does not know, and treats an unknown route `strategy` as
  `failover`. A data plane older than the control plane therefore keeps
  working, without the newer features (a route's `cache_ttl_s`, media
  models in `/v1/models`). Upgrade both together all the same: an older
  control plane does not have the endpoint a newer data plane reports
  refused requests to (the data plane then just keeps those counts).
- **Files written by newer versions.** `keys.json` and `audit.jsonl` are
  created the first time they are needed. Ledger events gained fields
  (`cached_input_tokens`, `cache_write_input_tokens`, `cached`); events
  written before they existed are read as before.
- **Nothing is deleted by an upgrade itself.** Retention is off unless the
  config turns it on.

The README lists the remaining windows: a crash between a provider accepting
a job and its id reaching disk, or during a synchronous provider call,
resubmits that job.

Keep a backup of `control-data` from before the upgrade. The repository has
no migration tooling for the ledger or job files.
