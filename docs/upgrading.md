# Upgrading

For someone who runs an earlier commit and wants to run the current one.
No release has been tagged, so versions are named by commit. This page
covers the two security commits of 11 November 2026 in detail:

| Commit | Process | What it is |
|---|---|---|
| e4e30e4 | data plane | Limits before the body is read, the gateway's own response framing, exact billing of abandoned streams, the `healthcheck` subcommand |
| d79406b | control plane, Compose | Capped outbound responses, stores that survive bad input, duplicate-detection ids in per-day files, media pricing settings, memory limits in Compose |

What they fixed, and who was affected, is in
[SECURITY.md](../SECURITY.md#past-advisories). If you come from before
commit 10bc009, read [Coming from older commits](#coming-from-older-commits)
at the end first: those steps still apply and are not repeated here.

Contents:

- [Before you start](#before-you-start)
- [The order to upgrade the two processes](#the-order-to-upgrade-the-two-processes)
- [What changes on disk](#what-changes-on-disk)
- [Defaults that changed](#defaults-that-changed)
- [Configuration that used to load and no longer does](#configuration-that-used-to-load-and-no-longer-does)
- [What changes for clients](#what-changes-for-clients)
- [What changes for operators](#what-changes-for-operators)
- [Going back](#going-back)
- [Coming from older commits](#coming-from-older-commits)

## Before you start

1. **Back up the control plane's data directory**, all of it, with the
   control plane stopped or at least idle: the ledger's active segment,
   sealed segments and both snapshots, `jobs.jsonl`, `keys.json`, the audit
   log and the media directory. The first start of the new control plane
   rewrites the ledger snapshot in a format the old code does not read
   ([Going back](#going-back)).
2. **Check your config file against the stricter rules** in
   [Configuration that used to load and no longer does](#configuration-that-used-to-load-and-no-longer-does).
   A file the old control plane loaded can now stop the new one at startup.
3. **If you price media routes per second**, decide on `default_seconds`
   for their targets: without it, a job that names no duration is now
   refused ([What changes for clients](#what-changes-for-clients)).
4. **If your data planes can be cut off from the control plane for more
   than three days** with usage in their spool, set
   `"retention": {"ledger_ids_days": 14}` (the old default) or more before
   you start the new control plane ([Defaults that changed](#defaults-that-changed)).
5. **Compose users: look at memory.** Both containers now have a 1 GiB
   limit, and the data plane's own default budgets admit more than that.
   See [Deployment](deployment.md#memory-limits) and set
   `OMNIGATE_CONTROL_MEMORY`, `OMNIGATE_DATAPLANE_MEMORY` or the data
   plane's `OMNIGATE_REQUEST_MEMORY_MB` and `OMNIGATE_PARSE_MEMORY_MB`
   accordingly.
6. **If a proxy or load balancer in front of the data plane sends request
   bodies with chunked encoding**, make it send a `Content-Length`: chunked
   request bodies now answer `411`.

## The order to upgrade the two processes

Upgrade both. The two commits belong together as one security update, and
each fixes a different process.

**Nothing in the interface between the two processes changed in these two
commits**: the config snapshot has the same shape, usage events and
refusal counts are sent the same way, and the forwarded jobs API is the
same. A new process therefore works next to the other's previous commit
(10bc009 or 76bba24) for the length of an upgrade. That follows from
reading the code; a mixed pair has not been run as a test, so do not leave
it that way for longer than the upgrade takes.

The recommended order is **control plane first, then the data planes**:

1. **Control plane.** Stop it, start the new one, and wait for
   `GET /readyz` to answer `200`.
   - It is the process that can refuse to start (a config value the
     stricter rules reject), and the one that changes files on disk. Find
     that out while the old data planes are still serving: a data plane
     keeps serving text requests from its last config while the control
     plane is away, and spools usage until it is back. Only `/v1/jobs*` and
     `/v1/files/*` answer `503` in the meantime.
   - Its first start reads the old ledger snapshot, moves the
     duplicate-detection ids into per-day files and writes a new snapshot.
     Nothing needs to be run by hand.
   - A media job that a provider had accepted resumes polling after the
     restart, as before.
2. **Data planes**, one at a time if you run several. Each stop is a
   graceful one: requests in flight get `OMNIGATE_SHUTDOWN_GRACE_MS` (10
   seconds) to finish, queued usage is delivered or stays in the spool, and
   the new binary reads the old spool file and the old config cache as they
   are.

With Compose, `docker compose up -d --build` rebuilds and replaces both;
Compose starts the control plane first and does not wait for it, which is
fine, since the new data plane starts from its cached config.

Each process forgets what it keeps in memory when it restarts, as with any
restart: rate-limit buckets, cooldowns, the response cache, learned model
quirks and refusal counts not yet reported on the data plane; the
control plane's rate-limit buckets, lockouts and refusal counts.

## What changes on disk

### Control plane (its data directory)

| File | Change | Old code reading it afterwards |
|---|---|---|
| `ledger.snapshot`, `ledger.snapshot.prev` | Written as **version 2** from the first start on. A version 2 snapshot holds the totals and, per day, how long that day's id file was; it no longer holds the ids themselves, so its size follows the number of keys, not the number of requests. A version 1 snapshot is still read, once, at the first start. | Ignores a version 2 snapshot (`ledger: ignoring ledger.snapshot (unexpected contents)`) and rebuilds from the segments that are still on disk. See [Going back](#going-back). |
| `ledger.ids.YYYY-MM-DD` (new) | One file per UTC day on which usage was recorded, next to the ledger, 16 bytes per event id, appended and never rewritten. Created at the first start from the ids in the old snapshot. Whole days are deleted by `retention.ledger_ids_days`. | Not looked at. |
| `ledger.jsonl`, `ledger.NNNNNN.jsonl` | Unchanged. | Reads them. |
| `jobs.jsonl` | A job whose `input` is over 8 KiB as JSON is written with `"input": null` and `"input_file": true`. Jobs created before the upgrade keep their input inline. | Reads the file, but sees such a job without its input. |
| `jobs.jsonl.inputs/` (new directory; `<OMNIGATE_JOBS>.inputs/`) | One file `<job id>.json` per large input, written before the job that points at it, deleted with the job. At a start, an input file without a job is removed. | Not looked at. |
| `keys.json` | A key may have `max_jobs_per_day`. An `rpm` above 1,000,000 that an older commit wrote is read as 1,000,000. | Ignores the new field. |
| `audit.jsonl` | Failed and throttled sign-ins are no longer one line each: the first from an address in a minute is a line, the rest are counted and written as one summary line with a `repeats` member. Every text field is made valid UTF-8 before it is written. | Still JSON lines. |

**Back up the new files with the old ones.** `ledger.ids.*` belongs to the
snapshot that names it, and `jobs.jsonl.inputs/` to `jobs.jsonl`:

- A ledger restored without its id files starts with its totals intact but
  has forgotten which events it already counted; a data plane that resends
  one of them would have it counted twice.
- A job log restored without the inputs directory has jobs whose input is
  gone: a finished one shows `"input": null`, an unfinished one fails with
  `internal_error` when it is next run.

The rule is the one that already applied: back up the whole data
directory, not single files ([Deployment](deployment.md#backups)).

### Data plane (its working directory, `/data` in the image)

| File | Change |
|---|---|
| `omnigate-usage.spool` | Same format (one JSON event per line). The new binary rewrites it to shed delivered events while it runs, so its size follows what is undelivered. A file left by the old binary is read as it is; a file of any size no longer stops a start, and if it holds more than can be queued (100,000 events or 128 MiB) the oldest are kept and the rest discarded with an error in the log. |
| `omnigate-config.cache.json` | Unchanged. |

### Deployment files

| File | Change |
|---|---|
| `compose.yaml` | `mem_limit` on both omnigate services (1 GiB each unless `.env` says otherwise). |
| `.env` | Two new optional variables, `OMNIGATE_CONTROL_MEMORY` and `OMNIGATE_DATAPLANE_MEMORY`. An existing `.env` without them gets the 1 GiB defaults. |
| `deploy/Caddyfile` | The proxy sets `X-Forwarded-For` itself, from the address of the connection, for both hosts. If you run your own proxy configuration with `OMNIGATE_TRUST_FORWARDED=1`, make yours do the same. |
| `dataplane/Dockerfile` | A `HEALTHCHECK` that runs `/omnigate-dp healthcheck`. `docker ps` now shows a health status for the data-plane container; Compose itself does nothing with it. |
| `config/omnigate.example.json` | Shows the new settings. Your own `config/omnigate.json` is not touched and needs none of them. |

## Defaults that changed

| Setting | Before | Now | Since |
|---|---|---|---|
| `OMNIGATE_ABORT_DRAIN_MS` (how long an abandoned stream's upstream is read on) | `5000` | `120000` | e4e30e4 |
| How much more of an abandoned answer is read | 8 MiB, fixed | `OMNIGATE_ABORT_DRAIN_MAX_MB`, `64` | e4e30e4 |
| A client that stays connected but reads nothing | cut off after `OMNIGATE_STREAM_IDLE_TIMEOUT_MS`, `300000` | cut off after the new `OMNIGATE_CLIENT_STALL_TIMEOUT_MS`, `30000` | e4e30e4 |
| `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` | `300000`, both directions | `300000`, a silent upstream only | e4e30e4 |
| Requests one key may have in flight | no limit | `OMNIGATE_MAX_CONCURRENT_PER_KEY`, `512` | e4e30e4 |
| Request bodies held at once | no limit | `OMNIGATE_REQUEST_MEMORY_MB`, `1024` (a quarter per key) | e4e30e4 |
| Memory for parsing JSON into trees | no limit | `OMNIGATE_PARSE_MEMORY_MB`, `1024` (half per key; at most 96 MiB per tree) | e4e30e4 |
| Abandoned streams read on at once | each on its own connection, up to the connection cap | 256 | e4e30e4 |
| Usage queue | 100,000 events | 100,000 events and 128 MiB | e4e30e4 |
| `retention.ledger_ids_days` | `14` | `3` | d79406b |
| `media.max_jobs_per_day` (and a key's `max_jobs_per_day`) | no limit | `10000` per key per UTC day | d79406b |
| `media.webhooks.max_concurrent` | no limit | `16` | d79406b |
| `media.webhooks.max_concurrent_per_key` | no limit | `4` | d79406b |
| `GET /v1/jobs` per key | no limit | the key's `rpm`, or 600 per minute when it has none | d79406b |
| A webhook receiver's answer | read whole | at most 16 KiB read | d79406b |
| A provider's or the bucket's answer to an API call | read whole | at most 4 MiB; an answer that carries media inline up to four thirds of `media.max_output_bytes` plus 64 KiB, at most 256 MiB | d79406b |
| The control plane's count of job creations | fixed one-minute windows | a token bucket like the data plane's (burst of `rpm`, refilled at `rpm` per minute) | d79406b |
| Memory limit of each omnigate container under Compose | none | `1g` (`OMNIGATE_CONTROL_MEMORY`, `OMNIGATE_DATAPLANE_MEMORY`) | d79406b |

What each means in practice:

- **`OMNIGATE_ABORT_DRAIN_MS` 5 s to 120 s.** It no longer holds the
  client's connection: the reading happens in the background. A provider
  keeps generating (and charging) for an abandoned stream for up to two
  minutes instead of five seconds, and in exchange the bill is the
  provider's real figure far more often. Set it back to `5000`, or to `0`,
  if you prefer the old trade.
- **Stalled clients, 5 minutes to 30 seconds.** A client that pauses
  reading a stream or a download for more than 30 seconds while staying
  connected is disconnected. Raise `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` if
  yours do that on purpose.
- **`ledger_ids_days` 14 to 3.** At the first retention sweep after the
  upgrade (a few seconds after the start) the ids of days that ended more
  than three days ago are forgotten. That frees memory (61 MiB per million
  ids) and is safe as long as no data plane still holds usage from before
  then that it has already delivered once without getting the
  acknowledgement. If a data plane has been cut off, or switched off, for
  longer than three days with events in its spool, set the value higher
  before you upgrade.
- **512 requests per key, 10,000 jobs per key per day, 600 listings per
  minute.** Generous, but a batch application can meet them. Each has a
  setting.
- **Compose memory limits.** A container that passes its limit is killed
  and restarted by Docker. The control plane's memory follows
  `omnigate_ledger_dedup_ids`; the data plane's default budgets
  (`OMNIGATE_REQUEST_MEMORY_MB` 1,024 plus `OMNIGATE_PARSE_MEMORY_MB`
  1,024 plus the 64 MiB cache) are above the 1 GiB limit, so under heavy
  hostile load the container would be killed before the budgets refuse
  anything. Raise the limit or lower the budgets.

## Configuration that used to load and no longer does

The control plane validates more of the config file. At startup a rejected
value stops it, with a log line that names the setting; on a reload the
previous config stays in force.

| Setting | Was | Now |
|---|---|---|
| `keys[].rpm`, `upstreams[].timeout_ms` | Any number; a fraction was cut to a whole number | A whole number: `rpm` 0 to 1,000,000, `timeout_ms` 0 to 3,600,000. `600.0` is rejected. |
| `routes[].cache_ttl_s`, `targets[].weight` | A whole number of 0 or more | Also at most 31,536,000 and 1,000,000 |
| `keys[].budget_usd` | Any number, negative included | 0 to 1e12 |
| Text and media prices | 0 or more | Also at most 1e9 |
| `keys[].max_open_jobs`, `media.max_open_jobs` | A whole number of 0 or more | Also at most 1,000,000,000 |
| `media.poll_interval_ms` | Any number | A whole number, 1 to 3,600,000 |
| `media.max_output_bytes` | Any number | A whole number, 1 to 1 TiB |
| `media.max_input_bytes` | Any number | A whole number, 1 to 8,000,000 |
| `media.routes[].timeout_s` | Any number | A whole number, 1 to 604,800 |
| `media.storage.url_ttl_s` | Any number | A whole number, 1 to 31,536,000 |
| `media.webhooks.max_attempts` | Any number | A whole number, 1 to 100 |
| `media.webhooks.timeout_ms` | Any number | A whole number, 1 to 600,000 |
| `media.webhooks.retry_schedule_ms` | Any list | At most 50 whole numbers, each 0 to 2,592,000,000 |

In each "any number" row, a fraction used to be cut to a whole number and
is now rejected, as is zero where the range starts at 1. Through the admin
API, `PATCH /admin/keys/{name}` refuses an `rpm` above 1,000,000, a
`budget_usd` above 1e12, a `max_open_jobs` above 1,000,000,000 and a
`models` list with more than 1,000 names or a name over 256 bytes
(`400 invalid_request`).

New settings, all optional: a key's `max_jobs_per_day`,
`media.max_jobs_per_day`, a media route's `allowed_input` and
`price_multipliers`, a media target's `default_seconds`, `min_seconds` and
`max_seconds`, `media.webhooks.max_concurrent` and
`max_concurrent_per_key`. See [Configuration](configuration.md).

The data plane has five new environment variables, all optional:
`OMNIGATE_MAX_CONCURRENT_PER_KEY`, `OMNIGATE_REQUEST_MEMORY_MB`,
`OMNIGATE_PARSE_MEMORY_MB`, `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` and
`OMNIGATE_ABORT_DRAIN_MAX_MB`; `OMNIGATE_ABORT_DRAIN_MS` has a new default.
Like every numeric variable they take digits only.

## What changes for clients

Error bodies keep their shape: the OpenAI or Anthropic envelope with the
gateway's reason in `error.code`. What is new is listed here.

### New answers

| Status | `error.code` | From | When |
|---|---|---|---|
| 400 | `request_too_complex` | data plane | A request that must be translated (or have its `stream_options` rewritten) has an object with more than 1,024 members, or needs a tree of more than 128 times its size plus 1 MiB (at most 96 MiB). |
| 400 | `invalid_request` | data plane | An object with more than 65,536 members, a key over 8 KiB, or `model`, `stream` or `stream_options` twice or spelled with escapes. |
| 411 | `invalid_request` | data plane | **A chunked request body.** `Transfer-Encoding: chunked` on a `POST` was accepted before; now every request with a body needs a `Content-Length`. |
| 429 | `concurrency_limit_exceeded` | data plane | The key has 512 requests in flight. `retry-after: 1`. |
| 429 | `request_memory_exceeded` | data plane | The key's share of the request-memory or tree budget is in use. `retry-after: 1`. |
| 503 | `overloaded` | data plane | The whole budget is in use. Unlike the `overloaded` at the connection cap, this one is in the client's protocol and has a request id. `retry-after: 1`. |
| 429 | `too_many_jobs_today` | control plane | `POST /v1/jobs` beyond the key's jobs per UTC day. |
| 429 | `rate_limit_exceeded` | control plane | `GET /v1/jobs` more often than the key's `rpm`, or 600 a minute. |
| 503 | `storage_unavailable` | control plane | `POST /v1/jobs` when the job could not be written to disk. |
| 400 | `invalid_request` | control plane | `POST /v1/jobs` on a route priced per second without a duration (and without a configured default), above the route's `max_seconds`, with an input field outside the route's `allowed_input`, or with a value outside its `price_multipliers`. |

The official OpenAI and Anthropic SDKs retry 429 and 503 answers that
carry `retry-after` by themselves.

### Changed behaviour

- **The rate limit is charged before the body is read.** A text request
  refused for its size, its JSON, an unknown model or a model the key may
  not use now uses up one request of the key's `rpm`. Before, the body was
  read first and those refusals were free. A client that probes model
  names against a rate-limited key sees `429` sooner.
- **The order of refusals changed with it.** A request that is both over
  the rate limit and wrong in its body now gets `429 rate_limit_exceeded`,
  not the `400`, `403` or `404` it got before; one whose declared length
  is over 8 MiB gets its `413` after the rate limit, without any of the
  body being read.
- **`Idempotency-Key` is only looked at on job requests.** On text
  endpoints it is ignored whatever it contains (before: `400` for anything
  but letters, digits and `-._:`). On `/v1/jobs*` it may now be any 1 to
  255 visible ASCII characters, so base64 and UUID keys with `+ / = | #`
  work.
- **Responses are framed by the gateway.** An answer that is not a stream
  and is at most 64 KiB carries a `content-length`; everything else is
  `transfer-encoding: chunked`, **including file downloads over 64 KiB**,
  which used to carry the file's length. A client that needs the size
  takes it from the job (`outputs[].bytes`).
- **A response the provider cuts short drops the connection.** When an
  upstream breaks off after the gateway has started sending, or sends less
  than it declared, the client's connection is closed without the closing
  chunk, so the client's HTTP library reports an incomplete response. A
  short answer that is cut off before anything was sent fails over to the
  next target instead.
- **A client that stops reading is disconnected after 30 seconds**, not
  five minutes.
- **A stream the client abandons is billed later and more exactly.** The
  usage event is written when the provider's answer has been read to its
  end, up to two minutes after the client left.
- **Estimates are higher for requests with media.** When a call is billed
  by estimate, each image, document, file or audio part of the request
  adds 1,600 input tokens, and the output estimate is at least the
  generated text received divided by 4.
- **`duration` may be written `"5s"`.** A number followed by `s` is
  accepted for `input.duration` and `input.seconds`.
- **Job lists leave large inputs out.** In `GET /v1/jobs`, a job whose
  input is over 8 KiB has `"input": null` and `"input_omitted": true`;
  `GET /v1/jobs/{id}` returns it in full.
- **Webhook timing.** At most 16 deliveries run at once (4 per key), so
  when many are due together some start later than the schedule says. An
  attempt cut short by a control-plane restart now counts as used.
- **Job creation bursts.** The control plane's own count of a key's `rpm`
  is a token bucket now: a key that has been idle may create up to `rpm`
  jobs at once, and a refusal's `Retry-After` is the time until the next
  one fits, not the end of the minute.
- **Media job prices can change** if the operator uses the new settings:
  a minimum or default duration, and multipliers by input value.

### On the control plane's own port

- A wrong bearer token is counted on `/` and `/login` as well as on
  `/admin/*` and `/metrics`; 20 from one address in a minute lock that
  address out of bearer access. `/admin/*`, `/metrics` and `/` then answer
  `429 too_many_attempts`; the sign-in page ignores the token and shows the
  form.
- A request that carries both a valid session cookie and the bearer token
  is treated as a session, so a change made that way needs the CSRF token.
- A request body is not read at all for a caller without credentials,
  except the sign-in form; the answer then carries `connection: close`.
- `GET /internal/config` can answer `503 not_ready` (data planes handle
  it by keeping their config).

## What changes for operators

- **Two new metrics**: `omnigate_ledger_invalid_events_total` and
  `omnigate_ledger_unpriced_events_total`. A media target without a price,
  and usage for a route or target that is not in the config, are now
  counted and logged once instead of passing silently at $0.
- **The JSON access log marks estimates** (`"estimated": true`), and
  `aborted` can be `ClientStalled` or `UpstreamTruncated`.
- **`omnigate-dp healthcheck`** and a `HEALTHCHECK` in the data-plane
  image; exit status 2 for an unknown argument.
- **The control plane's listener outlives its stores.** If the ledger, the
  job store, the keys or the audit log crash repeatedly, that group is
  restarted with a growing pause and `/readyz` reports it, where four
  crashes in five seconds used to stop the whole control plane. A
  supervisor that restarted the control plane when it exited will see
  fewer exits; alert on `/readyz` instead.
- **A per-second media route without `default_seconds` refuses jobs that
  name no duration.** Before, such a job was accepted and billed nothing
  per second.
- **Refused-request reasons** `concurrency_limit_exceeded`,
  `request_memory_exceeded` and `request_too_complex` appear in
  `omnigate_rejected_requests_total`.
- **Keys admin**: `max_jobs_per_day` can be set on a managed key and is
  shown in `GET /admin/keys`.

## Going back

**Data plane.** The old binary reads the new binary's spool and config
cache. Going back loses nothing but the fixes.

**Control plane.** Going back is possible but not free:

- The old code does not read a version 2 snapshot. It ignores both
  snapshot files and replays every ledger segment that is still on disk,
  which gives the right totals **only if `retention.ledger_days` has never
  deleted a segment**. If it has, the old code starts with the totals of
  the remaining segments and logs `ledger: no usable snapshot, and
  segments before N were deleted by retention`; restore the backup you
  took before upgrading instead, and accept losing the usage recorded
  since.
- Right after an upgrade the spare snapshot (`ledger.snapshot.prev`) is
  still the old version 1 file, which the old code would use. It is
  replaced by the next snapshot the new code writes (after 50,000 events,
  or five minutes with something new), so do not count on it.
- Jobs created by the new code with an input over 8 KiB have that input in
  `jobs.jsonl.inputs/`, which the old code does not know: it sees those
  jobs with an empty input, and an unfinished one fails when the old code
  runs it.
- The `ledger.ids.*` files are ignored by the old code, which rebuilds its
  ids from the events it replays.
- Remove the new settings from the config only if you want to; the old
  code ignores settings it does not know.

## Coming from older commits

The steps for earlier changes still apply, in this order:

| If you run a commit before | Do |
|---|---|
| 97cf396, fde530c, 3a0b147 (the first security fixes) | Read [SECURITY.md](../SECURITY.md#past-advisories): besides updating, you may have to set a new admin token and rotate gateway keys. |
| 3a0b147 | Split the single `.env` into `.env.control` and `.env.dataplane`, and make sure the admin token has at least 16 characters; a release build needs `OMNIGATE_CONFIG`. Steps: [Deployment](deployment.md#coming-from-a-commit-before-3a0b147). |
| fde530c | Clients: paths must be in canonical form (no trailing slash, no percent-encoding), query strings plain, JSON nested at most 64 levels; a `POST` without a length answers `411`. Abandoned streams are billed. See [API](api.md#request-heads-paths-and-queries). |
| 10bc009 | Clients of the jobs API and scripts against the admin API: the reason of an error from the control plane moved from `error.type` to `error.code`. Numeric environment variables are read strictly in both processes. |
| 17e0fe6, b3c5b39 | Clients: the data plane's errors became provider-shaped, with the gateway's reason in `error.code` instead of `error.type`. Reports: `input_tokens` excludes prompt-cache reads, which are counted separately. See the "Changed" section of the [changelog](../CHANGELOG.md). |

The ledger needs no manual migration from any commit: a plain
`ledger.jsonl` from before segments and snapshots existed is read as it
is, and a version 1 snapshot is converted at the first start. The job log
is read by newer code whatever wrote it; the reverse does not hold (older
code cannot read the patch lines and input files that newer code writes).
