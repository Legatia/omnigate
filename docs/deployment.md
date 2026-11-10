# Deployment

- [Compose with TLS](#compose-with-tls)
- [Health and readiness probes](#health-and-readiness-probes)
- [Running without containers](#running-without-containers)
- [What to keep private](#what-to-keep-private)
- [Backups](#backups)
- [Upgrades](#upgrades)

Read the README's [Known limits](../README.md#known-limits) first. In
short: nothing has run under production load; neither process has a TLS
listener of its own; there is one shared admin token and no user accounts.

If you ran a commit older than 3a0b147, read
[SECURITY.md](../SECURITY.md#past-advisories) before anything else: it
lists what was fixed, who was affected and what to rotate. The hardening
checklist for a new or existing installation is in
[Security hardening](security.md), and what changes for an installation
that is being updated is under [Upgrades](#upgrades) below.

## Compose with TLS

The repository has two Dockerfiles, a `compose.yaml` and a Caddy
configuration that puts TLS in front of both processes.

### 1. Create the four files you own

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

All four paths are ignored by git.

### 2. Fill in the three environment files

Secrets are split by who needs them. Each container gets only its own
file, so the data plane, which is the process that faces the internet, never
holds the admin token, a media provider key, a webhook secret or a bucket
credential. (Earlier commits gave one `.env` to both containers; see
[Upgrades](#upgrades) if you have one.)

**`.env`** is read by Compose itself, for the proxy. Nothing in it is a
secret.

| Variable | Value |
|---|---|
| `OMNIGATE_API_HOST` | Host name applications will use, for example `gateway.example.com`. |
| `OMNIGATE_ADMIN_HOST` | Host name for the dashboard, for example `admin.gateway.example.com`. |
| `OMNIGATE_ADMIN_ALLOW` | Who may reach the dashboard host at all: CIDR ranges separated by spaces, for example `203.0.113.0/24 2001:db8::/32`. The default, `0.0.0.0/0 ::/0`, is everyone; narrow it to your office or VPN. See [The admin allow-list](#the-admin-allow-list). |

**`.env.control`** is the control plane's environment.

| Variable | Value |
|---|---|
| `OMNIGATE_INTERNAL_TOKEN` | A long random string. Shared by the two processes. |
| `OMNIGATE_ADMIN_TOKEN` | A different long random string, at least 16 characters. Dashboard password and admin API token. |
| media provider keys | One variable per `media.upstreams[].api_key_env` named in your config. |
| webhook secrets | The variables your config's `webhook_secret_env` and `media.webhooks.secret_env` name, or `OMNIGATE_WEBHOOK_SECRET`. |
| bucket credentials | The variables `media.storage.access_key_env` and `secret_key_env` name, if storage is a bucket. |

**`.env.dataplane`** is the data plane's environment.

| Variable | Value |
|---|---|
| `OMNIGATE_INTERNAL_TOKEN` | The same value as in `.env.control`. |
| text provider keys | One variable per `upstreams[].api_key_env` named in your config. |

A provider whose key serves both a text upstream and a media upstream (the
example config uses `OPENAI_API_KEY` and `GEMINI_API_KEY` that way) goes in
both files.

One way to make a token:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

What happens with a bad value:

- **`OMNIGATE_INTERNAL_TOKEN` empty or missing**: neither process starts.
  Each logs that the variable is not set and exits, and with
  `restart: unless-stopped` the containers keep restarting until it is set.
- **`OMNIGATE_ADMIN_TOKEN` shorter than 16 characters**: the control plane
  logs why and refuses to start, and its container keeps restarting until
  the value is fixed.
- **`OMNIGATE_ADMIN_TOKEN` empty or missing**: a random one is generated at
  each start and written to the control plane's log. Set one.
- **A file that does not exist**: Compose refuses to start the service that
  names it.

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

What you get:

- **`proxy`** (Caddy) is the only container with published ports (80 and
  443). It serves the gateway at `https://$OMNIGATE_API_HOST` and the
  dashboard at `https://$OMNIGATE_ADMIN_HOST`. Real DNS names get Let's
  Encrypt certificates automatically; the `localhost` defaults get
  certificates from Caddy's own CA.
- **`dataplane`** is one static binary and a CA bundle on an empty base
  image, running as a non-root user.
- **`control`** is an Alpine image with the Elixir release, running as a
  non-root user, with a health check on `/readyz`.
- **State** lives in named volumes and survives restarts.
- **The internal API** between the two is reachable only on the private
  Docker network; the proxy answers 404 for `/internal/*`.
- **The dashboard host** can be limited to source ranges you choose
  (`OMNIGATE_ADMIN_ALLOW`); everyone else gets 403 from the proxy.
- **Stored job outputs** (`/v1/files/*` on the gateway host) are served as
  downloads: the gateway itself sends `Content-Disposition: attachment`,
  `X-Content-Type-Options: nosniff` and a sandboxing
  `Content-Security-Policy` with them, and the proxy passes them through.
- **Both services have a stop timeout** in `compose.yaml` (30 seconds for
  the control plane, 20 for the data plane), so a stop or restart lets them
  finish cleanly.

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
| `control-data` | `control:/data` | The ledger (`ledger.jsonl`, sealed segments `ledger.NNNNNN.jsonl`, `ledger.snapshot` and `ledger.snapshot.prev`), `jobs.jsonl`, `keys.json` (managed keys), `audit.jsonl` and its rotated files (admin audit log), `media/` (locally stored outputs) |
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

`compose.yaml` adds one more for the control plane:
`OMNIGATE_TRUST_FORWARDED=1`. The proxy is the only way in and writes
`X-Forwarded-For` itself, so failed logins and wrong admin tokens are
counted per real client address instead of all against the proxy. Remove it
if you ever publish the control plane's port directly.

The data-plane variables for timeouts, the connection cap, the response
cache and logging are not set by the image; add the ones you want to
change to `.env.dataplane` (for example `OMNIGATE_LOG_FORMAT=json` for a
log shipper). Control-plane variables go in `.env.control`.

**Stopping.** `docker compose stop` (or `down`, or a restart) sends
SIGTERM.

- The data plane stops accepting connections, lets requests in flight
  finish for up to `OMNIGATE_SHUTDOWN_GRACE_MS` (10 seconds), delivers
  queued usage and exits with status 0. `compose.yaml` gives it
  `stop_grace_period: 20s`; if you raise the grace period, raise that above
  it as well.
- The control plane writes a ledger snapshot at a clean stop, and
  `compose.yaml` gives it `stop_grace_period: 30s` for that. If it is killed
  first, nothing is lost: the next start replays the events written since
  the last snapshot.

See [Operations](operations.md#connection-limits-and-shutdown).

**Restarts.** Both services have `restart: unless-stopped`. A data plane
that hits an internal error it cannot continue from (a panic) logs one line,
`error(panic): ...`, and exits with status 70; Compose starts it again, and
usage that was already queued is delivered from the spool. An exit with
status 70 is a bug worth reporting ([SECURITY.md](../SECURITY.md) if it can
be triggered from outside).

### The admin allow-list

`OMNIGATE_ADMIN_ALLOW` in `.env` is a list of CIDR ranges, separated by
spaces. The proxy answers `403` to every request for the dashboard host
that comes from outside them: the dashboard, the login form, `/admin/*`,
`/metrics`, and the two probes. The gateway host is not affected. The
default lets everyone through, which leaves the admin token as the only
gate.

- The address that counts is the one the proxy sees. Behind another proxy
  or load balancer, or under Docker Desktop's network, that is the address
  of that proxy or of the Docker gateway, not the client's; an allow-list
  is then no use at this layer and belongs on the outer one.
- A monitoring system that scrapes `/metrics` or probes `/readyz` through
  the dashboard host must be inside the list.
- A change needs the proxy container to be re-created:
  `docker compose up -d proxy`.

The container test starts a second proxy whose list contains only
documentation ranges and checks that it serves the gateway host to everyone
and answers 403 to everything on the dashboard host.

### Testing the Compose file

```bash
python3 tools/container_test.py --compose
```

brings up this `compose.yaml` with mock providers added, a throwaway
config and two throwaway environment files (one per container, as in a real
deployment), publishes two local ports instead of 80 and 443 (18443, and
18444 for a second proxy with a closed admin allow-list), and checks it
through TLS. Besides the functional checks it sends requests byte for byte
through the real proxy: odd spellings of `/admin` and `/internal` paths,
with and without credentials; malformed and oversized requests to both
hosts, after which both containers must still be the same, never-restarted
processes; that the data-plane container holds the internal token and no
admin token; that both services have their stop timeouts; and that the
data-plane container shuts down cleanly on SIGTERM. Without `--compose` the
same test uses plain `docker` commands. Needs a Linux Docker daemon and
Python 3.9 or newer. CI runs it on every push.

From the README: tested with Docker 29 and Compose 2.40 on Ubuntu 24.04
(x86-64, under WSL 2). **Not tested: ARM, Let's Encrypt issuance with a real
domain, and Kubernetes.**

## Health and readiness probes

| Process | Probe | Says |
|---|---|---|
| Data plane | `GET /healthz` on its port, no key | The process is up and answering. It does not say that a config has been loaded: a data plane that has never reached the control plane and has no cached config answers `ok` here and `503 gateway_not_ready` to everything else. |
| Control plane | `GET /healthz`, no credentials | The process is up and answering. |
| Control plane | `GET /readyz`, no credentials | It can do its job: the config is loaded, the job store is running, the ledger is loaded and its file is writable. `200 {"status":"ready"}`, or `503 {"status":"not_ready","reason":"..."}` naming the first thing that is not. |

- **The control image's health check calls `/readyz`** every 10 seconds
  (3 second timeout, 120 second start period, 3 retries);
  `docker compose ps` shows the result. While the control plane is still
  loading its ledger the port is not open at all, so the probe fails with a
  refused connection rather than a 503. With snapshots that phase is under
  a second, but a first start on a large ledger written by an older commit
  replays it in full once (about 11 seconds per million events were
  measured), which is what the long start period is for: failures inside
  it do not count, and a healthy answer ends it early. If a start takes
  longer still, the container is reported unhealthy until it is done.
  Nothing restarts it for that: `compose.yaml` has no rule that acts on
  health.
- **The data-plane image has no health check.** It is one static binary on
  an empty base image, with nothing in it to run a probe. Probe
  `GET /healthz` from outside (the proxy, a load balancer, your monitoring).
- `compose.yaml` starts the data plane after the control plane without
  waiting for it to be healthy. That is fine: the data plane retries until
  the control plane answers, and serves from its cached config meanwhile.
- Behind the Compose proxy, the control plane's `/healthz` and `/readyz`
  are reachable on the dashboard's host name without credentials, from the
  addresses `OMNIGATE_ADMIN_ALLOW` lets through (everyone, by default).
  They disclose nothing but the state named above.
- For an orchestrator with separate liveness and readiness probes, use
  `/healthz` for liveness and `/readyz` for readiness on the control plane.
  Kubernetes itself is untested.

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
relative to the working directory: `OMNIGATE_LEDGER`, `OMNIGATE_JOBS`,
`OMNIGATE_KEYS`, `OMNIGATE_AUDIT_LOG`, `OMNIGATE_MEDIA_DIR`.
`OMNIGATE_CONFIG` is not optional here: a release build refuses to start
without it, so that the development config with its published keys can
never be the one in force on a server. The image also sets
`RELEASE_DISTRIBUTION=none` so the release does not start Erlang
distribution.

Give each process only its own secrets, as the Compose files do: the
internal token to both; the admin token, media provider keys, webhook
secrets and bucket credentials to the control plane only; text provider
keys to the data plane only.

**The proxy in front.** Whatever you use, it has to do what
`deploy/Caddyfile` does:

- terminate TLS for the gateway and for the dashboard;
- pass streamed responses through without buffering (Caddy:
  `flush_interval -1`);
- refuse `/internal` and `/internal/*` from outside;
- send `X-Forwarded-Proto: https` to the control plane, so the session
  cookie is marked `Secure` (or set `OMNIGATE_COOKIE_SECURE=1`);
- leave the gateway's response headers alone, those on `/v1/files/*` in
  particular: the download and sandbox headers on a stored file come from
  the gateway and must reach the browser;
- optionally, let only the source addresses of your operators reach the
  dashboard host;
- append the client's address to `X-Forwarded-For` (do not pass a
  client-supplied value through as the last hop) if you set
  `OMNIGATE_TRUST_FORWARDED=1` on the control plane, and set that variable
  only if this proxy is the only way to reach it.

Data-plane-to-control-plane traffic over HTTPS is untested; keep it on a
private network. Platforms other than Windows 11 and x86-64 Linux
containers are not verified.

Both processes refuse request paths that are not plain. The control plane
answers `400` to any path with a percent-encoded character; the data plane
answers `400` to any path that is not in its one canonical form (no `%`, no
trailing slash, no empty, `.` or `..` segment) and to a query string with
characters outside a small set. Nothing either serves needs more, so the
proxy needs no rule of its own for that; do not add one that rewrites or
normalises paths on the way in. The rules are in
[API](api.md#request-heads-paths-and-queries).

## What to keep private

| Thing | Why |
|---|---|
| The control plane's port (4000) | Dashboard, admin API, metrics and the internal API. Expose it only through a TLS proxy that hides `/internal/*`, and preferably only to operators (`OMNIGATE_ADMIN_ALLOW` with the Compose proxy). |
| `OMNIGATE_INTERNAL_TOKEN` | Anyone holding it can read the config snapshot, write usage events and act as any gateway key on the jobs API. It also derives the file URL signing key unless `OMNIGATE_SIGNING_SECRET` is set. |
| `OMNIGATE_ADMIN_TOKEN` | Dashboard, `/admin/*` and `/metrics`. Whoever holds it can create gateway keys and revoke existing ones. |
| `.env.control` | Holds both tokens, media provider keys, webhook secrets and bucket credentials. |
| `.env.dataplane` | Holds the internal token and the text provider keys. |
| `.env` | Host names and the admin allow-list only. Not secret unless you kept secrets in it from an earlier commit. |
| The config file | Holds gateway keys if you used `"key"` instead of `"key_sha256"`, and webhook secrets if you wrote them inline. |
| `keys.json` | Managed keys: hashes only, but a key's webhook secret in clear text if it has one. The control plane writes it with mode `0600`. |
| `audit.jsonl` and its rotated files | Who changed which key and who signed in, with client addresses. No secrets. |
| The ledger files (`ledger*.jsonl`, `ledger.snapshot*`), `jobs.jsonl` | Usage per key, and every job's input (prompts), metadata and webhook URL. |
| The data plane's log | Key names, route names and request paths in the access log. Never keys, hashes or request bodies. |
| The media directory or bucket | The generated files. Buckets are assumed private; clients get presigned URLs. |
| The data plane's port (8080) | Not secret, but plain HTTP. Publish it only through TLS. |

The three credentials do not work in each other's place: a gateway key is
not accepted by the control plane, the admin token is not accepted by the
gateway, and the internal token opens only `/internal/*`.

More in [SECURITY.md](../SECURITY.md) and
[Security hardening](security.md).

## Backups

What holds state that cannot be recomputed:

| What | Where (Compose) | If lost |
|---|---|---|
| The usage ledger | `control-data`: `/data/ledger.jsonl`, the sealed segments `/data/ledger.NNNNNN.jsonl`, `/data/ledger.snapshot` and `/data/ledger.snapshot.prev` | Spend totals are loaded from these at every start. Without any of them all spend is zero and budget-blocked keys are unblocked. What losing only some of them means is described below the table. |
| Job state | `control-data`: `/data/jobs.jsonl` | Jobs, their idempotency keys, cache entries and pending webhooks are gone. |
| Managed keys | `control-data`: `/data/keys.json` | Every key created through the dashboard or the admin API stops working: the gateway answers them with 401. The keys cannot be recovered (only hashes were ever stored); you create new ones and hand them out again. Their past usage is still in the ledger but no longer belongs to a named key. |
| The admin audit log | `control-data`: `/data/audit.jsonl`, `/data/audit.jsonl.1` to `.3` | The record of key changes and sign-ins is gone. Nothing else depends on it. |
| Locally stored outputs | `control-data`: `/data/media/` | Output URLs of existing jobs answer 404. Not applicable with bucket storage. |
| Your config and the three environment files (`.env`, `.env.control`, `.env.dataplane`) | the repository directory | You re-create them by hand. File keys come back with the config. Losing the internal token also invalidates outstanding signed file URLs, unless `OMNIGATE_SIGNING_SECRET` is set. |

**Back up and restore the ledger as one set of files, from one moment.**
The simplest rule is to treat the whole data directory as the unit.

- The segments (`ledger.jsonl` and the numbered files) are the events. The
  two snapshots are the totals up to a recorded position in them.
- **Without `retention.ledger_days`** the segments are complete, and the
  snapshots only save start-up time: lose or damage both and the next start
  replays every segment and arrives at the same totals.
- **With `retention.ledger_days`** old segments are deleted, and the two
  snapshots are then the only record of the spend those segments held. Lose
  both, and that spend is gone even though the remaining segments survive;
  the control plane says so in an error at start (`ledger: no usable
  snapshot, and segments before N were deleted by retention ...`). A backup
  taken before you turned the setting on does not help for what was
  recorded afterwards, so keep backing up.
- A snapshot is used only if the segment bytes it covers are present and
  unchanged. One restored next to segments from a different moment is
  ignored (`ledger: ignoring ledger.snapshot (...)` in the log) and the
  control plane falls back to the spare, then to replaying what it has.
  Mixing files from two backups therefore does no silent damage, but with
  deleted segments it can leave you without a usable snapshot.
- For the same reason, do not copy the files one by one from a running
  control plane. Stop it first, as shown below.

Restore `keys.json` together with the ledger from the same backup: the
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

The ledger's active segment, the job file and the audit log are appended
to and synced to disk on every write (the job file is also rewritten
compacted at start, after a retention sweep, and from time to time while
running). On start, a torn last line of the active segment is cut off, a
torn last line of the job file is skipped, and unreadable lines of the
audit log are skipped too; none of them is treated as fatal. `keys.json`
is different: it is replaced
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

Read [CHANGELOG.md](../CHANGELOG.md) first.

### Coming from a commit before 3a0b147

Three security commits (97cf396, fde530c, 3a0b147) changed things an
existing installation has to act on. What they fixed is in
[SECURITY.md](../SECURITY.md#past-advisories).

1. **Split the environment file.** `compose.yaml` no longer reads secrets
   from `.env`; it reads `.env.control` and `.env.dataplane`, and Compose
   will not start a service whose file is missing. Copy the two `.example`
   files, move each variable from your old `.env` into the file of the
   process that reads it ([step 2](#2-fill-in-the-three-environment-files)),
   and leave only the host names (and `OMNIGATE_ADMIN_ALLOW`, if you want
   one) in `.env`.
2. **Check the admin token's length.** A token shorter than 16 characters
   now stops the control plane from starting.
3. **Rotate, if the control plane was reachable.** If its port, or the
   dashboard's host name, could be reached by anyone you do not trust
   before the update: set a new `OMNIGATE_ADMIN_TOKEN`, delete managed keys
   you did not create, and rotate the gateway keys that were created or
   rotated in that time. No endpoint ever returned the internal token, so
   none of these fixes requires a new one; if you change it anyway, change
   it in both files and restart both containers together, and expect
   outstanding signed file URLs to stop working unless
   `OMNIGATE_SIGNING_SECRET` is set. The full list is in the advisories.
4. **Running without containers:** a control-plane release now needs
   `OMNIGATE_CONFIG`.
5. **Clients may see new refusals.** The gateway now answers `400` to a
   path with a percent-encoded character, a trailing slash or a `.`
   segment, to a query string with characters outside a small set, and to
   JSON nested deeper than 64 levels; `411` to a `POST` without a length;
   and an `Idempotency-Key` may only contain letters, digits and `-._:`.
   Job creation can answer `429 too_many_open_jobs`, and a job with a
   negative duration `400`. See [API](api.md#request-heads-paths-and-queries).
6. **Bills can change.** A stream the client abandons is now billed (the
   provider's real figures when they arrive within
   `OMNIGATE_ABORT_DRAIN_MS`, an estimate otherwise), and media jobs priced
   per second or per character are priced from what is sent to the
   provider. See [Operations](operations.md#streams-that-end-early).
7. **Duplicate-detection ids now expire after 14 days by default**
   (`retention.ledger_ids_days`). The first retention sweep after the
   update drops older ids from memory. Set `0` to keep the old behaviour.
8. **Settings are read strictly** (commit 10bc009). A numeric environment
   variable with anything but digits in it, or an `OMNIGATE_AUDIT_MAX_MB`
   that is not a number, now stops the process at startup with a message
   that names it, where it used to be half-read or replaced by a default.
   Check your environment files before the restart.
9. **A proxy of your own no longer needs a rule for `/v1/files/*`.** For
   one commit the included Caddyfile added the download headers to stored
   files; the gateway now sends them itself. If you copied that rule, it
   does no harm, but it is not needed.

What the code does during a restart:

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
  (`cached_input_tokens`, `cache_write_input_tokens`, `cached`,
  `estimated`); events written before they existed are read as before.
- **The job file's lines changed.** A job's later changes are now appended
  to `jobs.jsonl` as short patch lines instead of full copies of the job. A
  file written by an older commit is read as before. Going back is the
  problem: older code does not know patch lines and would take each one for
  a job. Keep the backup from before the upgrade if you might need to go
  back.
- **The ledger's new files need no migration.** A `ledger.jsonl` written
  by an older commit is read as segment 1. The first start with the newer
  code replays it once in full and writes the first snapshot; later starts
  load the snapshot. Going back to an older commit is another matter: older
  code reads only `ledger.jsonl`, so once a segment has been sealed it would
  start with the totals of the active segment alone. Keep the backup from
  before the upgrade if you might need to go back.
- **Changes a client can see.** The reason of a gateway error moved from
  `error.type` to `error.code`, and errors now have the shape of the
  client's protocol. Since commit 10bc009 that includes the errors the
  control plane raises, for the jobs API and for the admin API: all of them
  have the OpenAI-style envelope with the reason in `error.code`. A
  provider's 429 reaches the client as 429 instead of 502 whenever no
  target succeeded and any of them was rate limited. An application or
  script that matched on `error.type`, or treated every 502 alike, needs to
  be changed with the upgrade. See [API](api.md#errors) and the changelog's
  "Changed" section.
- **No job, file or ledger segment is deleted by an upgrade itself.** Those
  parts of retention are off unless the config turns them on. The ledger's
  duplicate-detection ids are the exception since commit 3a0b147: ids older
  than 14 days are forgotten unless `retention.ledger_ids_days` says
  otherwise.

The README lists the remaining windows: a crash between a provider accepting
a job and its id reaching disk, or during a synchronous provider call,
resubmits that job.

Keep a backup of `control-data` from before the upgrade. The repository has
no migration tooling for the ledger or job files.
