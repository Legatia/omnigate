# Upgrading

For someone who runs an earlier commit and wants to run the current one.
Versions before the first tag (the pre-release 0.1.0-rc.1) are named by
commit. Upgrades from two of them, 10bc009 and 6d5ed6e, to 0.1.0-rc.1 have
been run as a test ([Tested upgrades](#tested-upgrades)). This page
covers the two security commits of 11 November 2026 in detail, and the
close-out commit that followed them
([The close-out commit](#the-close-out-commit)):

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
- [The close-out commit](#the-close-out-commit)
- [The third-review commit](#the-third-review-commit)
- [The privacy mode commit](#the-privacy-mode-commit)
- [0.1.0-rc.1](#010-rc1)
- [The attestation commit](#the-attestation-commit)
- [The build-around commit](#the-build-around-commit)
- [The receipts commit](#the-receipts-commit)
- [Tested upgrades](#tested-upgrades)
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
   limit. With the `compose.yaml` of d79406b the data plane's budgets were
   the binary's defaults, which admit more than that; the current one sets
   them to fit ([The close-out commit](#the-close-out-commit)). See
   [Deployment](deployment.md#memory-limits) and set
   `OMNIGATE_CONTROL_MEMORY`, `OMNIGATE_DATAPLANE_MEMORY` or the data
   plane's `OMNIGATE_REQUEST_MEMORY_MB` and `OMNIGATE_PARSE_MEMORY_MB`
   (in `.env`) accordingly.
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
(10bc009 or 76bba24) for the length of an upgrade. Both mixed pairs have
since been run as a test, with the 0.1.0-rc.1 build on one side and 10bc009
or 6d5ed6e on the other ([Tested upgrades](#tested-upgrades)): text
requests, usage, media jobs and downloads worked in both. A few minutes of
a test are not a soak, so do not leave it that way for longer than the
upgrade takes.

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
| `keys.json` | A key may have `max_jobs_per_day` and, since the close-out commit, `max_concurrent`. An `rpm` above 1,000,000 that an older commit wrote is read as 1,000,000. | Ignores the new fields. |
| `audit.jsonl` | Failed and throttled sign-ins are no longer one line each: the first from an address in a minute is a line, the rest are counted and written as one summary line with a `repeats` member. Every text field is made valid UTF-8 before it is written. Since the close-out commit a line can have a `peer` member, and `address` is the address the caller was counted under. | Still JSON lines. |

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
| `compose.yaml` | `mem_limit` on both omnigate services (1 GiB each unless `.env` says otherwise). Since the close-out commit also the data plane's three memory budgets, in its `environment`. |
| `.env` | Two new optional variables, `OMNIGATE_CONTROL_MEMORY` and `OMNIGATE_DATAPLANE_MEMORY`. An existing `.env` without them gets the 1 GiB defaults. Since the close-out commit also `OMNIGATE_REQUEST_MEMORY_MB`, `OMNIGATE_PARSE_MEMORY_MB` and `OMNIGATE_CACHE_MAX_MB` (256, 256 and 64 when absent). |
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
| The data plane's memory budgets under Compose | the binary's `1024`, `1024` and `64` | `256`, `256` and `64`, set by `compose.yaml` from `.env` | close-out |
| `Retry-After` on `429 too_many_jobs_today` | `10` | seconds until midnight UTC, at most `3600` | close-out |
| The deadline on the gateway's own answers | `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` | `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` | close-out |

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
  anything. The close-out commit's `compose.yaml` sets the budgets to 256
  MiB each for that reason; with an older Compose file, raise the limit or
  lower the budgets yourself.

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
| A media target with `per_second_usd` on an upstream of kind `openai_images`, `elevenlabs`, `gemini` or `gemini_interactions` | Loaded | Needs `default_seconds` (close-out commit) |

In each "any number" row, a fraction used to be cut to a whole number and
is now rejected, as is zero where the range starts at 1. Through the admin
API, `PATCH /admin/keys/{name}` refuses an `rpm` above 1,000,000, a
`budget_usd` above 1e12, a `max_open_jobs` above 1,000,000,000 and a
`models` list with more than 1,000 names or a name over 256 bytes
(`400 invalid_request`).

New settings, all optional: a key's `max_jobs_per_day` and (close-out
commit) `max_concurrent`,
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
| 400 | `invalid_request` | data plane | An object with more than 65,536 members, a key over 8 KiB, or `model`, `stream` or `stream_options` twice, spelled with escapes or (from the [third-review commit](#the-third-review-commit)) in another letter case; a `stream` or `include_usage` that is not a boolean. |
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
  `transfer-encoding: chunked`. Between e4e30e4 and the close-out commit
  that **included file downloads over 64 KiB**, which used to carry the
  file's length and do so again; the size is also in the job
  (`outputs[].bytes`).
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
  `429 too_many_attempts`, and since the close-out commit so does `GET
  /login` (it ignored the token and showed the form).
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

## The close-out commit

The commit that follows 55a294d closes loose ends the two security commits
left. Nothing changes on disk except two optional members (a key's
`max_concurrent` in `keys.json`, `peer` on audit lines), both ignored by
older code, and either process can be upgraded first. What an installation
can notice:

**Before you start**

- **A per-second price on an image or speech target needs
  `default_seconds`.** A media target with `per_second_usd` above 0 on an
  upstream of kind `openai_images`, `elevenlabs`, `gemini` or
  `gemini_interactions` is rejected when the config is loaded unless it
  sets `default_seconds`: those providers are never sent a duration, so
  the price had nothing to multiply. A config that loaded before can stop
  the control plane at startup (or be refused on a reload). Set
  `default_seconds`, or use `per_job_usd` or `per_output_usd`. Such a job
  is billed `default_seconds` whatever `input.duration` says.
- **Compose: the data plane's memory budgets moved to `.env`.**
  `compose.yaml` now sets `OMNIGATE_REQUEST_MEMORY_MB`,
  `OMNIGATE_PARSE_MEMORY_MB` and `OMNIGATE_CACHE_MAX_MB` in the data-plane
  container's environment, from `.env`, with defaults of 256, 256 and 64
  (they were the binary's 1024, 1024 and 64, which did not fit the 1 GiB
  limit). If you had set any of the three in `.env.dataplane`, move it to
  `.env`: the value there is now overridden. If your traffic needs more
  than 256 MiB of request bodies or parse trees at once, raise the budget
  and `OMNIGATE_DATAPLANE_MEMORY` together
  ([Deployment](deployment.md#memory-limits)). Outside Compose nothing
  changes: the binary's defaults are as they were.

**What clients can notice**

| Change | Before | Now |
|---|---|---|
| A provider's error that is not in its protocol's shape (an array, `error` as a string, plain text) | Passed on as it came | Put into the protocol's error envelope with the provider's message and code; a well-formed one is still passed on byte for byte ([API](api.md#provider-errors)) |
| File downloads over 64 KiB | `transfer-encoding: chunked`, no length | `content-length`, as before e4e30e4 |
| `429 too_many_jobs_today` | `Retry-After: 10` | `Retry-After`: the seconds until midnight UTC, at most 3,600 |
| A non-streaming answer whose provider sends the head and then nothing | The request ended there (after the stream idle timeout), and the connection's later deadlines could be lost | A failed attempt, `StreamIdleTimeout`: the next target is tried, or `502 all_upstreams_failed` |
| A client that takes none of one of the gateway's own answers (an error, the model list, a cache hit) | Cut off after `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` (5 minutes) | Cut off after `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` (30 seconds) |
| `GET /login` with a bearer token from an address locked out for wrong tokens | The sign-in page, `200` | `429 too_many_attempts`, as on `/` |

**What operators can notice**

- **A key can have its own concurrency cap**: `max_concurrent`, in the
  config file and through the admin API, shown in `GET /admin/keys` and on
  the dashboard. `0` (the default) leaves the key on the data plane's
  `OMNIGATE_MAX_CONCURRENT_PER_KEY`. Every key in the config snapshot now
  carries the field; data planes from e4e30e4 on read it, older ones
  ignore it.
- **Audit log.** `address` is, on every line, the address the caller was
  counted under (with `OMNIGATE_TRUST_FORWARDED`, the client the proxy
  reported; before, ordinary lines had the proxy there). The connection's
  own address is in the new member `peer` when it differs. A clean stop
  writes the sign-in counts that have no summary line yet. The dashboard
  shows a summary line's `repeats`.
- **The control plane warns at start when an id file is missing** that its
  ledger snapshot counted ids for (`ledger: the id file for <day> ... is
  missing`): events of that day that are delivered again would be counted
  twice.
- **The control-plane image's health check** asks the port in
  `OMNIGATE_CONTROL_PORT` (it asked 4000 whatever the setting).
- **`tools/malformed_test.py --rpm N`** tells the tool how many requests
  per minute `--rpm-key` allows (it assumed 3), and
  **`tools/import_litellm.py`** writes a LiteLLM timeout of more than an
  hour as `3600000` and says so, instead of writing a config that does not
  load.

**Going back** from this commit to 55a294d needs nothing: remove
`max_concurrent` from file keys only if you want to (older control planes
ignore it).

## The third-review commit

The commit that follows 1cc721f fixes what the third security review
found ([advisories](../SECURITY.md#past-advisories)). Either process can
be upgraded first. On disk: a managed key in `keys.json` can gain
`carried_totals`, and a job in the job log `provider_pending`; older code
ignores both. What an installation can notice:

**What clients can notice**

| Change | Before | Now |
|---|---|---|
| `"Model"`, `"STREAM"`, `"Stream_Options"` or another case of `model`, `stream`, `stream_options` at the top level of a text request; another case of `include_usage` inside `stream_options` | Ignored by the gateway, passed on to the provider | `400 invalid_request` |
| `"stream"` or `"stream_options.include_usage"` that is not `true`, `false` or `null` (`"true"`, `1`) | Read as false, passed on | `400 invalid_request` |
| A stream whose provider never reports usage (it ignores `stream_options`) | Recorded with zero tokens, free | Billed an estimate, `"estimated": true` ([Operations](operations.md#streams-that-end-early)) |
| `POST /v1/jobs` with `metadata` over 16 KiB as JSON | Accepted up to `media.max_input_bytes` together with the input | `413 payload_too_large` |
| `POST /v1/jobs` with a `webhook_url` over 2,048 bytes | Accepted | `400 invalid_webhook_url` |
| `GET /v1/jobs`: a job whose `metadata` is over 1 KiB | In the list | `"metadata": null, "metadata_omitted": true`; `GET /v1/jobs/{id}` shows it |
| Cancelling a job whose provider call had started | `cost_usd` 0, always; webhook at once | `cost_usd` is the route's price if the provider completed the call anyway; the job counts as open, and its webhook waits, until that is known (at most the route's timeout) ([API](api.md#cancel-a-job)) |
| A job whose provider returns more than 16 outputs, or more than 2 GiB of them | All downloaded | That attempt fails (`too_many_outputs`, `output_fetch_failed`); raise `media.max_outputs_per_job` or `media.max_job_output_bytes` if a model of yours needs more |

**What operators can notice**

- **Two new settings**, `media.max_outputs_per_job` (16) and
  `media.max_job_output_bytes` (2 GiB, or `media.max_output_bytes` if that
  is larger) ([Configuration](configuration.md#media)).
- **Estimated usage is more common** if you route to providers that do
  not report usage on streams: those calls now cost the estimate.
- **Outputs stored in a bucket** from now on have `application/octet-stream`
  as their content type unless the type is an image, video or audio type
  (or JSON), as outputs served by the gateway already had. Objects stored
  earlier keep the type they were stored with.
- **Webhook and output URLs on IPv6** are only called when the address is
  in `2000::/3`.
- **The download directory is emptied of leftovers at start** (files named
  `job_<id>-<n>`; ones of jobs this instance does not hold only when they
  are a day old).
- **Admin sign-in throttling** counts an attempt before it compares, so a
  burst of parallel wrong attempts is cut off at the limit rather than
  after it. Correct tokens never use the allowance up.

**Going back** to 1cc721f needs nothing. A job cancelled under the new
code whose account is still open (`"provider_pending": true`) is not
settled by the old code: let such jobs finish (at most a route's timeout)
before going back, or accept that they stay out of the ledger.

## The privacy mode commit

The commit that follows 8421df7 adds [privacy mode](privacy.md). Nothing
changes for a key that does not use it, with the exceptions in the last
table.

Upgrade both processes before you give a key the setting, and check
`GET /admin/keys` afterwards: a control plane from before this commit
ignores a `privacy` it is sent (in the config file and on
`PATCH /admin/keys` alike), without an error, and the key is then simply
not private.

**Mixed versions**

| Control plane | Data plane | What happens |
|---|---|---|
| new | old | The snapshot carries each key's `privacy`; an old data plane ignores it. **Redaction, unlinking, `"store": false` and the cache exemption do not happen** until the data plane is upgraded, and no response says `x-omnigate-privacy`. Media jobs are private and encrypted as configured (that is the control plane's work). An `x-omnigate-privacy` request header is ignored by the old data plane and not passed on. |
| old | new | No key has the setting. The request header works for text requests (`redact`, `unlink`, `no-store`); on `POST /v1/jobs` the new data plane passes `x-omnigate-privacy: no-store` on and the old control plane ignores it, so **the job is not private**. Redaction counts are reported with the refusal counters and an old control plane shows them there, as `omnigate_rejected_requests_total{reason="redacted_email"}` and so on. |

Upgrade both before telling anyone a key is private.

**On disk**

- `keys.json`: a managed key can have a `privacy` object. Older code
  ignores it; if an older control plane then rewrites the file (any key
  change), the setting is lost.
- The job log: jobs gain `private`, `encrypt_to`, `metadata_file`, and later
  `erased` and `outputs_expired`. A private job's input and metadata are in
  `<jobs file>.inputs/<id>.json` and `<id>.meta.json`, not in the log.
  **Going back with private jobs unfinished:** older code reads the input
  file (it knows large inputs live there) and runs the job, but does not
  know `.meta.json` (it deletes it at its next start as a stray file, so the
  job's metadata is lost), does not erase anything when the job ends, and
  stores the outputs unencrypted. Let private jobs finish before going back.
- Stored outputs of keys with `encrypt_to` are age files named
  `out-N.<ext>.age`. Older code serves them like any other stored file.

**New settings, and one new default**

| Setting | Default | Note |
|---|---|---|
| key `privacy` | off | [Privacy mode](privacy.md#switching-it-on). |
| upstream `privacy_store_flag` | by host (`api.openai.com`) | [Configuration](configuration.md#text-upstreams). |
| `retention.private_outputs_hours` | `24` | Only concerns private jobs, which exist only once the setting or the header is used. |

**What clients and operators can notice without using it**

| Change | Before | Now |
|---|---|---|
| A request with an `x-omnigate-privacy` header | Ignored | Acted on; a value that is not understood answers `400 invalid_request` |
| The config snapshot (`GET /internal/config`) | No `privacy` on keys | Every key has `privacy` (`null` when off), every upstream `privacy_store_flag`; the snapshot's version changes once with the upgrade |
| `GET /admin/keys`, `GET /admin/overview` | | Keys gain `privacy` and `privacy_summary`; the overview gains `redactions` |
| `/metrics` | | `omnigate_redactions_total`, `omnigate_key_private` |
| The retention sweep's log line | Ends with the ledger segments | Ends with "and the outputs of N private jobs" |
| A job's `outputs[]` entries | `url`, `content_type`, `bytes`, `sha256` | The same for jobs that are not encrypted; four more fields for those that are |
| `tools/e2e.py` | Standard library only | Uses `pyrage` when it is installed, to decrypt what the gateway encrypted; without it that one check is skipped and the run says so (`OMNIGATE_REQUIRE_PYRAGE=1` turns the skip into a failure, as CI does) |

## 0.1.0-rc.1

The first tagged version. Nothing changes on disk and nothing in the
interface between the two processes; either can be upgraded first. What an
installation can notice:

- **Images are built from the repository root.** `compose.yaml` now says
  `build: {context: ., dockerfile: control/Dockerfile}` (and the same for
  the data plane), because the images carry the license terms in
  `/licenses`. If you keep your own Compose file or build script, change
  `docker build dataplane` to `docker build -f dataplane/Dockerfile .`, and
  likewise for `control`; the old command fails at the first `COPY`. A new
  `.dockerignore` at the root keeps the build context to what is needed.
- **The data plane gives up on a call to the control plane after 10
  seconds** (config poll, usage batch, refusal counts). Before, a control
  plane address that swallowed packets, or a control plane that took a
  request and never answered, held the caller for as long as the operating
  system or the peer allowed: a data plane started in that state did not
  open its port for minutes, and one unanswered call stopped the config
  poll or the usage reporter. The log names it: `(ControlTimeout)`.
- **The data plane finishes stopping when the control plane is slow.**
  Asked to stop (SIGTERM, Ctrl-Break) while a call to the control plane was
  under way, earlier builds logged `config sync failed (Canceled)` and then
  never exited; under Docker that ended in a kill after the stop timeout.
  Nothing was lost (undelivered usage stays in the spool), but the exit was
  not clean. Seen on Windows with the control plane stopped, where a
  refused connection takes about two seconds; on Linux it needs a control
  plane that does not answer. The last attempts to hand over usage and
  counts at a stop now wait at most 2 seconds each.
- **The data plane's memory no longer grows with traffic.** Every
  optimized build before this one (the container image included) kept
  about half a kilobyte per request that it never used again: tens of
  megabytes an hour at ten requests a second, and at a thousand a second
  the 1 GiB limit of the Compose file within half an hour, after which the
  container is killed and restarted. If your data-plane container has been
  restarting under load, this is the likely reason. The fix is in the
  choice of allocator ([changelog](../CHANGELOG.md)); nothing to configure.
  Its resident memory now follows the number of open connections and
  streams being read to their end (about 210 MiB with 890 threads in the
  soak test, about 10 MiB idle), not the number of requests served.
- **The version** in `omnigate_build_info`, in the data plane's outbound
  `user-agent` and in the webhook `user-agent` is `0.1.0-rc.1`.

**Going back** to 99dd04c needs nothing.

## The attestation commit

The commit after 0.1.0-rc.1 adds [attested upstreams](attestation.md), the
`attested` part of privacy mode, the privacy dry run and the Private chat
page. Nothing changes for an installation that uses none of them, with the
exceptions in the last table. Nothing changes on disk.

**Mixed versions.** The data plane enforces an attestation verdict; the
control plane produces it.

| Control plane | Data plane | What happens |
|---|---|---|
| new | old | The snapshot carries each target's verdict and each key's `attested`; an old data plane ignores both. **Attested targets are used whether or not they are verified, and a key's `attested` restricts nothing.** An `x-omnigate-privacy: attested` request header is refused by it with 400. No response says `x-omnigate-attestation`, and `x-omnigate-dry-run` is ignored: the request is **sent** to a provider. |
| old | new | An `attestation` setting on an upstream is ignored by the old control plane, without an error, and nothing is verified; a key with `"privacy": {"attested": true}` makes the old control plane refuse the config (it does not know the field). The new data plane sees no verdict on any target and refuses every `attested` request. |

Upgrade both, the data plane included, before you rely on any of it, and
check a response's `x-omnigate-attestation` header and
`GET /admin/attestations` afterwards.

**What an installation can notice without using it**

| Change | Before | Now |
|---|---|---|
| `x-omnigate-privacy: attested` | `400 invalid_request` | Accepted; on a gateway without attested upstreams the request is refused with `503 attestation_unverified` |
| A request with an `x-omnigate-dry-run` header | Ignored (the request was sent) | `privacy` answers with a dry run; any other value is `400 invalid_request` |
| A key's `privacy` in `GET /admin/keys` and in the snapshot | Four fields (three in the snapshot) | One more, `attested` |
| `/metrics` | | `omnigate_attestation_checks_total` (three series, all 0 without attested upstreams) |
| The dashboard's top bar | | A link to the Private chat page. Using the page creates a managed key named `private-chat`; a config-file key of that name stops the page from working |
| The control plane's outbound calls | | With an attested upstream only: the upstream's host, Intel's and NVIDIA's attestation services ([list](attestation.md#what-the-control-plane-calls)) |

## The build-around commit

The commit after the attestation one adds what outside tools build on
([Building on omnigate](building-on-omnigate.md)): top-ups, the usage feed
and the request tag. Nothing changes for an installation that uses none of
them, with the exceptions below.

**On disk (control plane)**

| File | Change | Old code reading it afterwards |
|---|---|---|
| `keys.json` | A top-level `"topups"` list: the applied top-ups, newest first, at most 10,000. Written (empty) at the first key change after the upgrade. | Reads the keys and ignores the list. **Its next key change writes the file without it**, so the references are forgotten: a payment replayed after going back would be credited again. |
| `ledger.jsonl` and its segments | An event may have a `"tag"`. | Ignores it. |
| `jobs.jsonl` | A job may have a `"tag"`. | Ignores it. |
| `audit.jsonl` | `key.topup` entries, with a `topup` object. | Shows them like any entry. |

**Mixed versions**

| Control plane | Data plane | What happens |
|---|---|---|
| new | old | An `x-omnigate-tag` header is **ignored without an error**: the request is served and its event has no tag. Top-ups and the usage feed work (they are the control plane's alone). |
| old | new | A valid tag is accepted by the data plane and sent with the usage event; the old ledger stores the field as it is and shows it nowhere. `POST /admin/keys/{name}/topup` and `GET /admin/events` answer 404. |

**What an installation can notice without using it**

| Change | Before | Now |
|---|---|---|
| A request with an `x-omnigate-tag` header | Ignored | Recorded if it is 1 to 64 letters, digits, `.`, `_`, `:`, `-`; otherwise, or sent twice, `400 invalid_request` |
| `POST /admin/keys/{name}/topup`, `GET /admin/events` | `404` | The new endpoints |
| The audit log | | `key.topup` entries |

## The receipts commit

Adds a [receipt for each answer](attestation.md#a-receipt-for-each-answer)
from an attested upstream, and more ElevenLabs products for media jobs.
Nothing changes for an installation without an attested upstream, with the
exceptions in the table.

**Between the two processes.** A usage event for an answer from an attested
target now carries `"receipt": {"request_sha256", "response_sha256",
"completion_id"}` (`null` on every other event), and the data plane sends
such requests with `x-no-aliasing: true`.

| Control plane | Data plane | What happens |
|---|---|---|
| new | old | No event carries hashes: no receipt is made. `GET /v1/attestations/<id>` is answered `404 not_found` by the old data plane. Attested routing works as before. |
| old | new | The old control plane ignores the new field (and records the usage as before); `GET /v1/attestations/<id>` gets its `404`. |

**On disk (control plane).** A new file, `data/receipts.json`
(`OMNIGATE_RECEIPTS`), written only when there is an attested upstream. An
older control plane does not read it; deleting it loses the receipts and
nothing else. Include it in backups if receipts matter to you.

| | Before | After |
|---|---|---|
| The control plane's environment | The provider's API key was needed by the data plane only | For receipts the control plane needs the attested upstream's `api_key_env` too (it asks the provider for each signature). Without it every receipt is `not_verified` (`api_key_missing`); nothing else is affected. |
| Requests to an attested upstream | | Carry `x-no-aliasing: true`: a provider that would have served the request with another model under an alias now refuses it. |
| `retention` | | One more setting, `receipts_days` (30). It appears in `GET /admin/overview`'s config and on the dashboard. |
| `Retention.sweep` result, `/metrics` | | `receipts` in the sweep's counts; `omnigate_receipts{verdict}` (three series, all 0 without attested upstreams). |
| A private media job (`no-store`) | Could be seen as `succeeded` for a moment before `input_erased` appeared | Its input is erased in the same write that makes it terminal. |
| ElevenLabs media targets | Text to speech only | A target may name `"api": "sound"`, `"music"`, `"image"` or `"video"`; without it nothing changes. |

## The credits and payments commit

Adds [prepaid credit](credits.md) as a rule of its own (a burn multiplier,
a weekly bonus) and, opt-in, [payments](payments.md)
through NEAR Intents. With neither `credits` nor `payments` in the config
nothing changes in what the gateway does; the differences are the additive
ones in the tables.

**Between the two processes.** The data plane now passes `/v1/payments*` on
to the control plane (GET and POST), also for a key that is blocked.

| Control plane | Data plane | What happens |
|---|---|---|
| new | old | `/v1/payments*` is answered `404 not_found` by the old data plane: payments cannot be used until it is upgraded. Credit (the multiplier, the bonus) is the control plane's alone and works. |
| old | new | The new data plane passes `/v1/payments*` on and the old control plane answers `404`. |

**On disk (control plane).**

| File | Change | Old code reading it afterwards |
|---|---|---|
| `keys.json` | A top-up record gains `"source"`. A prepaid managed key gains `"credits"` (its balance and the weekly measure) at its first top-up after the upgrade, or at the first sample while a bonus rate is set, and `"burn_multiplier"` when it is given one. With no bonus rate, a key that is never topped up and has no multiplier is written exactly as before. (For one day, commits 4b74680 and c45d461, credit was of two kinds: a top-up record carried `"eligible"` and the state two balances. Such a file loads; the two balances are added up and the field is ignored.) | Ignores the new fields, and **drops them at its next key change**: the bonus measure of the current week is then lost (the budget itself is not). Bonuses already credited stay, as top-ups. |
| `ledger.jsonl`, `ledger.NNNNNN.jsonl` | A usage event of a prepaid key whose burn multiplier is not 1 carries `"credits_usd"` next to `"cost_usd"`. Credit added to a key (a top-up, a bonus) is recorded as an event of `"kind": "credit"` with an `amount_usd`, at no cost. At a multiplier of 1 and without top-ups the files are what they were. | Reads `cost_usd` only: **a key's credit burned shrinks back to its cost**, so a prepaid key that was blocked at a multiplier above 1 may be unblocked. It counts each `credit` event as one request of that key, at no cost, with no tokens. |
| `ledger.snapshot` | Holds one more kind of row (what each key burned beyond cost). | Loads it; the rows are not looked at. |
| `payments.json` (new; `OMNIGATE_PAYMENTS`) | Written only when `payments` is configured: one record per payment, with its deposit address and state. | Does not read it. An open payment is then never credited by the gateway: credit it by hand with a top-up under its reference. |

Back `payments.json` up with the rest of the data directory.

| | Before | After |
|---|---|---|
| A key with a total budget | Blocked when its cost reached the budget | Blocked when its credit burned (cost times its burn multiplier) reaches the budget. The same at the default multiplier of 1. |
| `GET /admin/keys`, a key | | Three more fields: `credits_burned_usd`, `credits` (an object for a prepaid key, `null` otherwise), and `period_spend_usd` of a total budget is now the credit burned. The dashboard's "spent" for a total budget is that figure too. |
| `GET /admin/events` | Text requests and media jobs | Every event has `credits_usd`; top-ups and bonuses appear as events of `"kind": "credit"`. A consumer that assumed every event is usage should skip that kind (`examples/usage_export.py` writes them as rows with `amount_usd`, `source` and `reference`). |
| `POST /admin/keys/{name}/topup` | `amount_usd`, `reference` | Also takes `source`; the answer's `topup` has `source`. A reference that starts with `bonus:` can collide with the gateway's own (`bonus:<key>:<ISO week>`); pick other names. |
| Audit log | | New actions written by the gateway itself, with `"auth": "system"` and `"address": null`: `key.bonus`, `payment.create`, `payment.settle`, `payment.refunded`, `payment.failed`. A reader that assumes every line has an address should not. |
| `/metrics` | | `omnigate_key_credits_burned_usd_total`, `omnigate_payments{status}`, `omnigate_payments_credited_usd`. |
| The key store file | Rewritten when a key changes | With a bonus rate set, also rewritten every `credits.sample_interval_s` (15 minutes) while any prepaid managed key holds credit. |
| Config | `credits` and `payments` were unknown top-level sections, silently ignored | Both are read and checked: a config that happened to carry one with fields the gateway does not know no longer loads. |
| Admin API | | `GET /admin/topups`, `GET /admin/payments`. |
| Gateway API | | `/v1/payments*`: `404` unless payments are configured. |

## The top-up page commit

Two pages, both only while `payments` is configured: a
[top-up page](payments.md#the-top-up-page) for key holders on the gateway's
port, and a Payments page on the dashboard. No stored format changes.

**Between the two processes.** The data plane now passes `GET /topup` on to
the control plane (`/internal/topup`).

| Data plane | Control plane | What happens |
|---|---|---|
| new | old | `GET /topup` is answered `404` by the old control plane. |
| old | new | The old data plane asks for a key on `/topup` and then answers `404 not_found`; the page cannot be reached until it is upgraded. The dashboard's Payments page works. |

| What | Before | After |
|---|---|---|
| Gateway port | `GET /topup` was `401` without a key, `404` with one | With payments configured: the top-up page, **without a key**. Without them: `404`. |
| `GET /v1/payments` | `{"payments": [...]}` | One more field, `"credits"`: the key's balance, or null for a key that is not prepaid. |
| The dashboard's top bar | | A link to the Payments page (`/payments`), with payments configured. |

## Tested upgrades

`tools/upgrade_test.py` builds an older commit, lets it write state, stops
or kills it, and starts the current build on the same files
([Contributing](../CONTRIBUTING.md)). On 11 November 2026 it was run from
two commits to the tree that became 0.1.0-rc.1, on Windows, against the
mock providers:

| From | On-disk format it starts from |
|---|---|
| 10bc009 | Ledger snapshot version 1, no `ledger.ids.*` files, no `jobs.jsonl.inputs/` |
| 6d5ed6e | Ledger snapshot version 2 and id files; before `carried_totals`, `provider_pending`, privacy mode and price variants |

Each was run twice: with the old processes asked to stop, and with both
killed while a media job was running at the provider. In all four runs the
current build then showed:

- every key's requests, tokens and cost exactly as the old build reported
  them, across a ledger of some twenty segments and a snapshot;
- 24 requests that the old data plane had answered after its control plane
  was gone, and held in its spool, counted once;
- the key list unchanged (managed keys, one rotated twice, one disabled,
  budgets and period spend), and every secret accepted or refused as
  before;
- finished, failed and cancelled jobs unchanged, and every stored output
  downloading with its recorded hash;
- the job that was running at the provider finished, stored and billed
  once, without being submitted again;
- a webhook that could not be delivered before the upgrade delivered once
  after it, correctly signed;
- the same totals after a further restart, and no file in either data
  directory that this page does not name.

The two mixed pairs (old data plane with the current control plane on the
upgraded files; current data plane with the old control plane on fresh
files) served text in both protocols, recorded usage once, ran a media job
and logged no error on either side. The privacy rows of
[the table above](#the-privacy-mode-commit) were checked the same way: a
key made private is not private through an old data plane, and is as soon
as the data plane is current; the request header redacts on a current data
plane whatever the control plane.

What this does not show: an upgrade under load, one with a large ledger
(the test writes a few hundred events), bucket storage, Linux, or the
container images. One thing it found is fixed in 0.1.0-rc.1 (the stop
described above); the old data plane in these runs showed it, and had to be
killed in the "asked to stop" variant.

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
