# Operations

- [Dashboard and admin API](#dashboard-and-admin-api)
- [Metrics](#metrics)
- [Refused requests](#refused-requests)
- [Budgets](#budgets)
- [Rate limits](#rate-limits)
- [Timeouts, failover and cooldowns](#timeouts-failover-and-cooldowns)
- [Connection limits and shutdown](#connection-limits-and-shutdown)
- [Retention](#retention)
- [When the control plane is down](#when-the-control-plane-is-down)
- [Logs](#logs)
- [Load testing](#load-testing)
- [Troubleshooting](#troubleshooting)

## Dashboard and admin API

The control plane serves a dashboard at `/` (sign in with the admin token).
It shows totals for today and overall, every key with its spend against its
budget, recent text requests with their failover attempts, recent media
jobs with their webhook state, requests the gateway refused, the latest
admin actions, and a read-only view of the configuration. It refreshes
itself every four seconds.

What can be changed without editing a file, from the dashboard or the admin
API: **gateway keys**. A key can be created, given a budget, a budget
period, a rate limit and a model list, disabled, rotated and deleted, and
data planes pick the change up within seconds. Keys written in the config
file stay read-only there. Every such change is written to an audit log.

Everything else (upstreams, routes, prices, the media section, retention)
is still changed by editing the config file, which is reloaded within about
two seconds.

The tour of the dashboard, the key API with `curl` examples, and the audit
log are in [Admin](admin.md). The endpoint list is in
[API](api.md#admin-api).

## Metrics

`GET /metrics` on the control plane serves Prometheus text format behind the
admin token. Metric names are listed in the [API reference](api.md#get-metrics).

A scrape job looks like this (standard Prometheus configuration; the README
notes that the output has been checked by tests, not by a real Prometheus
server):

```yaml
scrape_configs:
  - job_name: omnigate
    scheme: https
    metrics_path: /metrics
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/omnigate-admin-token
    static_configs:
      - targets: ["admin.gateway.example.com"]
```

Things to know:

- **Everything is served by the control plane**: the ledger totals, the job
  store, the config, and the refusal counts that data planes report to it.
  The data plane has no metrics endpoint of its own, so there are no latency
  histograms and no upstream health gauges. Per-request latency is in the
  data plane's [access log](#logs).
- **Only requests that reached the failover loop (or the response cache)
  are in the ledger.** Requests the gateway refused earlier are counted
  separately, in `omnigate_rejected_requests_total`; see
  [Refused requests](#refused-requests).
- **Per-key ledger counters are totals over the whole ledger.** They are
  rebuilt from the ledger file at start, so they do not reset when the
  control plane restarts. `omnigate_config_reloads_total`,
  `omnigate_uptime_seconds` and `omnigate_rejected_requests_total` do.
- **A rotated key keeps its series**: usage under earlier secrets is added
  in. A deleted key's series disappear, although its events stay in the
  ledger file.
- **`omnigate_key_errors_total`** counts ledger events with a status of 400
  or above. That includes provider errors passed to the client, 502s after
  every target failed, streams that broke or stalled mid-way (499), and
  failed (502) or canceled (499) media jobs.
- **Input tokens come in three series.** `omnigate_key_input_tokens_total`
  is the input that was not served from a provider's prompt cache;
  `..._cached_input_tokens_total` and `..._cache_write_input_tokens_total`
  are the prompt-cache reads and writes. Add them for the total input.
- **`omnigate_key_cached_responses_total`** counts answers served from the
  gateway's own response cache. They are also in
  `omnigate_key_requests_total`, with no tokens and no cost.
- **`omnigate_key_period_cost_usd`** is the figure a monthly or daily
  budget is compared with. It is a gauge: it drops to zero when the period
  turns.
- **`omnigate_jobs` and `omnigate_webhooks`** describe the jobs currently in
  the job store. With retention on, removed jobs leave these gauges.
- **Each scrape scans the whole job store.** Keep the scrape interval
  moderate if you hold many jobs, or turn on retention.
- The `key` label is the key's `name`. Give keys distinct names.

Useful alerts, given what is exposed: `omnigate_key_blocked == 1`,
`omnigate_webhooks{state="failed"} > 0`,
`omnigate_key_period_cost_usd` approaching `omnigate_key_budget_usd`, and a
rising `omnigate_rejected_requests_total{reason="overloaded"}` or
`{reason="invalid_api_key"}`.

## Refused requests

A request the gateway answers itself before routing (a bad key, a rate
limit, a model the key may not use, a malformed body) never reaches a
provider and never becomes a usage event. Each data plane counts these per
key name and reason and reports the counts to the control plane every
`OMNIGATE_FLUSH_MS`. They appear in the dashboard's "Refused requests"
table and as `omnigate_rejected_requests_total{key, reason}`.

`reason` is the `error.type` the client received: `invalid_api_key`,
`missing_api_key`, `budget_exceeded`, `model_not_allowed`,
`rate_limit_exceeded`, `model_not_found`, `not_found`, `invalid_json`,
`missing_model`, `payload_too_large`, `method_not_allowed`,
`invalid_request`, `gateway_not_ready`, `control_plane_unavailable`. Two
more have no error
body of their own: `client_timeout` (a client that was disconnected for
sending too slowly) and `overloaded` (a connection refused at the
connection cap).

`key` is the key's name, or `-` when the request could not be tied to a
known key (no key, an unknown key, or a connection refused before anything
was read).

Limits, all by design:

- **Best effort.** The counts are not written to disk anywhere. A data
  plane keeps adding them up while the control plane is unreachable and
  hands them over when it is back, but a data-plane restart loses what was
  not yet sent, and a control-plane restart starts every series from zero.
- **Bounded.** A data plane holds at most 1,000 series and the control
  plane 2,000. Beyond that, new series are folded together (under the key
  `-` on the data plane, under key `-` and reason `other` on the control
  plane), so a flood of made-up keys cannot grow memory.
- Errors the control plane produces for the jobs API (`job_not_found`,
  `idempotency_conflict` and the like) are not counted here.

## Budgets

A key with `budget_usd` is blocked once the spend recorded for it in its
current budget period reaches the budget.

- **Spend** is the sum of the cost of the key's ledger events: text calls
  priced by the target's token prices, and media jobs priced by the target's
  `price`.
- **The period is set per key** with `budget_period`: `total` (the default:
  everything the key ever spent, nothing resets it), `monthly` (the current
  UTC calendar month) or `daily` (the current UTC day). A monthly or daily
  key unblocks by itself when the period turns, at 00:00 UTC. A total key
  stays blocked until you raise or remove its budget, in the config file
  for a file key or with a `PATCH` for a managed key
  ([Admin](admin.md#budgets-and-periods)).
- **An event counts in the period of its own time**: when the request
  finished on the data plane (for a media job, when the job finished), not
  when the event reached the ledger. Usage spooled through an outage
  therefore lands in the period it was incurred in.
- **Enforcement is after the fact.** The call that crosses the budget
  completes. The control plane then marks the key blocked in the config
  snapshot, and the data plane starts answering 402 `budget_exceeded` after
  its next poll. The lag is the usage flush interval plus one poll interval.
  Creating a media job is also checked by the control plane directly,
  without that lag.
- **A blocked key cannot start new work, but keeps read access.** Text
  requests and `POST /v1/jobs` answer 402. `GET /v1/models`, fetching and
  listing its jobs, cancelling a job and downloading its files still work,
  so an application can collect results it already paid for. Signed file
  URLs keep working as well.
- **Cost is fixed when an event is recorded**, using the prices in the
  config at that moment. Changing a price does not re-price history. An
  event whose route or target is no longer in the config is recorded with
  zero cost.
- **A target with no prices costs nothing**, so a budget on a key that only
  uses unpriced routes never triggers.
- **A rotated key keeps its spend.** A deleted key's spend does not carry
  over to a new key of the same name.

**How a text call is priced.** The data plane reads four token counts from
the provider's response and reports them separately:

| Count | Priced with | Meaning |
|---|---|---|
| `input_tokens` | `price_in_per_mtok` | Input that was not served from the provider's prompt cache. |
| `cached_input_tokens` | `price_cached_in_per_mtok` | Input read from the provider's prompt cache. |
| `cache_write_input_tokens` | `price_cache_write_per_mtok` | Input written to the provider's prompt cache. |
| `output_tokens` | `price_out_per_mtok` | Output. |

The two protocols report prompt caching differently, and the data plane
turns both into the meaning above, by the protocol of the upstream that
answered (which, for a translated request, is not the client's protocol):

- OpenAI-style upstreams include cached tokens in their input count and
  give them again as `cached_tokens`; the gateway subtracts them, so
  `input_tokens` is the uncached part. They report no cache writes.
- Anthropic-style upstreams report `input_tokens` without the cache, plus
  `cache_read_input_tokens` and `cache_creation_input_tokens`; those are
  taken as they are.

The two cache prices default to the input price, so a config without them
bills every input token at `price_in_per_mtok`, as before. Set
`price_cached_in_per_mtok` (and, for Anthropic-style upstreams,
`price_cache_write_per_mtok`) from your provider's price list to bill
cached input at its real rate. The parsing is covered by unit tests on
response shapes in each provider's format; the README does not record a
comparison of ledger totals against a real provider's bill with prompt
caching in use.

An answer served from the gateway's own
[response cache](configuration.md#response-cache) is recorded as a request
with no tokens and no cost.

Still true, from the README: reasoning tokens have no price of their own;
budgets are enforced on a single control-plane node; and a key cannot be
newly blocked during a control-plane outage.

## Rate limits

A key with `rpm: N` may burst up to N requests and is refilled at N per
minute (a token bucket).

- What counts: every metered text endpoint (not `count_tokens`), and
  `POST /v1/jobs`. Polling, listing and canceling jobs do not count. A
  request answered from the response cache counts like any other.
- A request refused for its model (`model_not_allowed`) does not count. For
  text endpoints the body is read before the limit is checked, so a key over
  its limit still costs one body read.
- Over the limit, the answer is 429 `rate_limit_exceeded` with a
  `Retry-After` header in whole seconds.
- State is in memory in each data-plane process. A restart forgives the
  last minute; several data planes each allow the full limit.
- Changing a key's `rpm` in the config starts it with a full bucket.
- The `x-ratelimit-*` and `anthropic-ratelimit-*` headers a client may see
  on a response are the provider's, passed through
  ([API](api.md#response)). They describe your provider key's limits, not
  this `rpm`.

## Timeouts, failover and cooldowns

Three timeouts, all on the data plane:

| Timeout | Variable (default) | Applies to | When it fires |
|---|---|---|---|
| Upstream | `OMNIGATE_UPSTREAM_TIMEOUT_MS` (10 minutes), or the upstream's `timeout_ms` | Waiting for a provider's response headers | The target is abandoned (`UpstreamTimeout`) and the next one is tried. |
| Client | `OMNIGATE_CLIENT_TIMEOUT_MS` (30 seconds) | A client sending its request head and body, and an idle keep-alive connection between requests | The connection is closed. No response is sent (there is no 408). |
| Stream idle | `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` (5 minutes) | A response in progress: the upstream sending nothing, or the client reading nothing | The connection is closed, and what was metered so far is billed with status 499. |

Each can be turned off with `0`. Notes:

- The client timeout is one allowance for the request head and a fresh one
  for the body; it does not limit how long the gateway then waits for the
  provider.
- The stream idle timeout restarts whenever bytes move, so a long but
  steadily streaming answer is never cut. It also covers a non-streaming
  answer whose body stalls after the headers.
- A client that stalls while sending its body shows in the access log with
  status 408 and `aborted=ClientTimeout` (the 408 is for the log only), and
  is counted as `client_timeout` among the
  [refused requests](#refused-requests). A connection closed while idle, or
  before a complete request head arrived, leaves no access-log line. A
  response cut by the stream idle timeout shows status 499 and
  `aborted=StreamIdleTimeout`.
- Clients that keep connections open for reuse should expect the gateway to
  close a connection that has been idle for the client timeout, and retry
  on a fresh one.

Failover and cooldowns:
- **Failover** to the next target happens on connection errors, timeouts,
  429 and 5xx, and only before any byte has reached the client. A connection
  error is first retried once on a fresh connection, in case a pooled
  connection had gone stale (timeouts and refused connections are not
  retried this way).
- **Cooldown.** An upstream that fails `OMNIGATE_COOLDOWN_FAILURES` times in
  a row (5) is tried last for `OMNIGATE_COOLDOWN_MS` (30 seconds). It is
  still tried, as a last resort. One success clears it. When the cooldown
  ends, the next request tries it again; if that fails it cools down again
  at once. State is per data-plane process and in memory.

To see what happened to a request, look at `x-omnigate-attempts` and
`x-omnigate-upstream` on the response, at the attempts column in the
dashboard, or at the request's line in the access log.

## Connection limits and shutdown

**Connection cap.** The data plane serves at most
`OMNIGATE_MAX_CONNECTIONS` client connections at once (4096 by default). A
connection beyond that is answered at once, without its request being read,
with `503` `overloaded`, `retry-after: 1` and `connection: close`, and is
counted as `overloaded` among the [refused requests](#refused-requests).
The data plane uses one thread per connection, so the cap is also a cap on
threads. The README records what has been tried: a soak at 94 connections
for five minutes and a run at 550 for two; nothing beyond that.

**Graceful shutdown.** On SIGTERM or SIGINT (Ctrl-C, Ctrl-Break or closing
the console on Windows) the data plane:

1. stops accepting connections;
2. closes connections that are between requests;
3. lets requests in flight finish, for up to `OMNIGATE_SHUTDOWN_GRACE_MS`
   (10 seconds by default), then cuts off whatever is still running;
4. makes a last attempt to deliver queued usage (up to 20 batches of 500
   events) and the refusal counts;
5. exits. Usage that could not be delivered stays in the spool file and is
   sent at the next start; with `OMNIGATE_SPOOL=off` it is lost, and the log
   says how many events.

In a container this is what makes `docker stop` end the data plane cleanly
instead of waiting to kill it. Docker and Compose wait 10 seconds by
default before killing a container, which is the same as the default
grace; if you raise `OMNIGATE_SHUTDOWN_GRACE_MS`, raise the container's
stop timeout (`stop_grace_period` in Compose) above it. The container test
checks that the data-plane container exits with status 0 on SIGTERM.

A restart still drops the state the data plane keeps only in memory:
rate-limit buckets, cooldowns, round-robin counters, learned model quirks,
the response cache, and refusal counts not yet reported.

The control plane has no drain step of its own; what a restart of it means
for jobs is in [Deployment](deployment.md#upgrades).

## Retention

Off by default: nothing is deleted unless the config has a `retention`
section.

```json
"retention": { "jobs_days": 30, "ledger_ids_days": 7, "delete_bucket_objects": true }
```

One sweep runs a few seconds after the control plane starts and then every
hour. When it removes something it logs
`retention sweep removed N finished jobs, N stored files, N bucket objects, N ledger dedup ids`.

**`jobs_days`.** Jobs that finished (succeeded, failed or canceled) more
than this many days ago are removed from the job store and its file, and
their outputs are deleted: files on local disk, and objects in the bucket.

- Unfinished jobs are never touched, whatever their age. Neither are jobs
  with a webhook delivery still pending or retrying.
- A removed job can no longer be fetched, replayed by its idempotency key,
  or used as a cache hit.
- **Bucket objects are deleted one by one, best effort.** An object that
  could not be deleted is logged
  (`retention: could not delete bucket object <key>: ...`) and left behind;
  the sweep goes on and does not come back to it, because the job that
  named it is gone. A lifecycle rule on the bucket is still a good
  backstop.
- Only objects under the gateway's own key layout
  (`<prefix><job id>/<name>`) are ever deleted, and an object that a
  remaining job still points at is kept (a cache hit shares the original
  job's object).
- Set `"delete_bucket_objects": false` to leave bucket objects alone and
  expire them with the bucket's own rules instead.
- Bucket deletion needs the bucket credentials to allow deleting objects.
  It is covered by the control plane's unit tests against a stand-in
  server; the README's Cloudflare R2 check predates it and does not cover
  deletion.

**`ledger_ids_days`.** The ledger forgets the event ids it uses to reject
duplicates once they are older than this.

- Spend totals and the ledger file are untouched.
- A usage event that a data plane resends after its id was forgotten would
  be counted twice. Keep this well above the longest outage a data plane
  might spool through.

What retention does not do: it does not trim `ledger.jsonl`. The ledger
file grows for as long as the gateway runs and is replayed in full at every
start; ledger rotation is on the README's "Next" list.

## When the control plane is down

The data plane is built to keep serving text traffic without it.

| | During the outage |
|---|---|
| Text endpoints | Keep working, with the last config received. |
| Keys, routes, rate limits | As in that last config. Config edits are not seen until the control plane is back, and keys cannot be created, changed, rotated or revoked (the admin API is the control plane). |
| Budgets | Keys already blocked stay blocked, also past the end of their period. A key cannot be newly blocked. |
| Response cache | Keeps working: it lives in the data plane. |
| Refused-request counts | Keep adding up in the data plane's memory and are handed over when the control plane answers again. |
| Usage | Queued in memory and appended to the spool file; delivered in batches when the control plane answers again, and deduplicated by request id, so each call is billed once. |
| `/v1/jobs*`, `/v1/files/*` | 503 `control_plane_unavailable`. Signed file URLs for local storage also need the control plane. |
| Running media jobs | Stopped with the control plane. On restart, a job a provider had accepted resumes polling; it is not submitted again. |
| Restarting the data plane | It starts from the config cached on disk. With no cache (first start, or `OMNIGATE_CONFIG_CACHE=off`) it answers 503 `gateway_not_ready` until the control plane is reachable. |

Limits of the spool:

- It holds at most 100,000 undelivered events. Beyond that, new events are
  dropped and the data plane logs `dropping usage event (queue full)`.
- Appends are not fsynced, so a power loss can drop the last few events.
- Delivery is retried with a backoff of up to 10 seconds, in batches of up
  to 500 events.
- With `OMNIGATE_SPOOL=off`, undelivered usage is lost when the data plane
  stops.

## Logs

Both processes log to their console; with Compose, read them with
`docker compose logs control` and `docker compose logs dataplane`.

If `OMNIGATE_ADMIN_TOKEN` is not set, the generated token is written to the
control plane's log at startup. Treat that log as a secret, or set the
variable.

### Data plane: level, format and the access log

`OMNIGATE_LOG_LEVEL` is `debug`, `info` (the default), `warn` or `error`.
`OMNIGATE_LOG_FORMAT` is `text` (the default) or `json`. Everything goes to
standard error.

Every finished request gets one access-log line at `info` level, except
successful `GET /healthz` probes, which are logged at `debug`. In text
form:

```
info(access): POST /v1/chat/completions 200 key=my-app model=claude upstream=anthropic attempts=1 in=11 out=6 12ms id=0123456789abcdef0123456789abcdef
```

| Part | Meaning |
|---|---|
| method, path, status | The status sent to the client. 499 is a stream that broke or stalled; 408 a client that stalled while sending (logged only, never sent). |
| `key=` | The gateway key's **name**. The key itself and its hash are never logged. Absent when the request had no known key. |
| `model=` | The route name the client asked for. |
| `upstream=`, `attempts=` | The upstream that answered and how many were tried. Absent when none answered. |
| `in=`, `out=` | Uncached input tokens and output tokens. Present when either is not zero. |
| `cached_in=` | Input tokens the provider read from or wrote to its prompt cache, when there were any. |
| `cache=hit` | The answer came from the gateway's response cache. |
| `Nms` | From the request head being read to the end of the response. |
| `id=` | The request id (`x-omnigate-request-id`, and the usage event's id in the ledger). |
| `aborted=` | Why the request ended without a normal response, if it did: `ClientTimeout`, `StreamIdleTimeout`, or the name of the I/O error. |

With `OMNIGATE_LOG_FORMAT=json` every line is one JSON object. Ordinary log
lines look like

```json
{"ts":1794312003415,"level":"info","scope":"proxy","msg":"upstream mock-flaky returned 503, failing over"}
```

and access-log lines have `"scope":"access"` and carry their fields as
members instead of a message:

```json
{"ts":1794312003415,"level":"info","scope":"access","method":"POST","path":"/v1/chat/completions","status":200,"key":"my-app","model":"claude","upstream":"anthropic","attempts":1,"input_tokens":11,"output_tokens":6,"latency_ms":12,"request_id":"0123456789abcdef0123456789abcdef"}
```

`ts` is Unix time in milliseconds. `key`, `model`, `upstream` with
`attempts`, `cached_input_tokens`, `cache` (`"hit"`), `request_id` and
`aborted` are present only when they apply; `method`, `path`, `status`,
`input_tokens`, `output_tokens` and `latency_ms` always are. A message
longer than about 2,000 bytes is cut off, and a path longer than 160
bytes is shortened.

(The values in these examples are made up; the field names and order are
the code's.)

The control plane has no access log and no JSON format: it logs through
Elixir's standard logger.

### Lines worth knowing

Control plane:

| Line | Meaning |
|---|---|
| `OMNIGATE_INTERNAL_TOKEN is not set (or is empty). ...` | The control plane refused to start. Set the same value for both processes. |
| `loaded config <path>: N routes, N keys` | Startup. |
| `loaded N managed keys from <path>` | Startup, when the keys file has keys. |
| `cannot write <path>: ...` | A key change could not be saved and was not applied. |
| `audit log <path> could not be written: ...` | An admin action went ahead without its audit line. |
| `retention sweep removed N finished jobs, N stored files, N bucket objects, N ledger dedup ids` | A sweep removed something. |
| `retention: could not delete bucket object <key>: ...` | The object stays in the bucket. |
| `reloaded config <path>` | An edit was applied. |
| `config reload failed, keeping previous: ...` | The edited file is invalid; the old config is still in force. |
| `OMNIGATE_ADMIN_TOKEN is not set. Generated one for this run ...` | The token follows on the same line. |
| `control plane listening on <address>: reachable from the network over plain HTTP ...` | `OMNIGATE_CONTROL_BIND` is not loopback. |
| `ledger replayed N events from <path>` | Startup. |
| `job <id>: <upstream> failed (<outcome>), trying next target` | Media failover. |
| `job <id>: resuming provider job <provider id> on <upstream>` | A job continued after a restart. |
| `job <id>: storing outputs failed: ...` | Storage problem; the job fails with `storage_error`. |
| `webhook for <job id> gave up after N attempts` | Delivery failed for good. |

Data plane:

| Line | Meaning |
|---|---|
| `OMNIGATE_INTERNAL_TOKEN is not set` | The data plane exited at startup. An empty value counts as not set. |
| `bad OMNIGATE_LOG_LEVEL or OMNIGATE_LOG_FORMAT: ...`, `<VARIABLE> is not a valid number: ...` | The data plane exited at startup over a bad setting. The second line names the variable for the timeout, connection, grace and cache settings; a bad value in one of the older numeric variables (`OMNIGATE_POLL_MS`, `OMNIGATE_FLUSH_MS`, `OMNIGATE_UPSTREAM_TIMEOUT_MS`, the cooldown pair) stops it with a parse error that does not name it. |
| `omnigate data plane listening on <address> (control plane <url>)` | Startup. |
| `installed config version <id> (N routes, N keys)` | A new config snapshot is in force. |
| `initial config sync failed (...)` | The control plane was unreachable at startup; the line says whether a cached config is being served. |
| `config fetch returned 401` | The two `OMNIGATE_INTERNAL_TOKEN` values differ. |
| `config sync failed (...); serving last good config` | Logged once per outage. `control plane reachable again` ends it. |
| `upstream <name> returned <status>, failing over` | A 429 or 5xx. |
| `upstream <name> failed: <error>` | A connection error or timeout. |
| `upstream <name> keeps failing; trying it last for the next N ms` | A cooldown started. |
| `usage delivery failed (...); spooling, N events queued` | Logged once per outage. `usage delivery resumed` ends it. |
| `reloaded N undelivered usage events from spool` | Startup after an outage or crash. |
| `<upstream>/<model> rejects sampling parameters; retrying without them` | A learned model quirk. |
| `control plane request <path> failed: ...` | A jobs or files request got 503 `control_plane_unavailable`. |
| `stopping: N connection(s) open, waiting up to N ms for requests in flight` | A stop signal arrived. |
| `N request(s) still running after the grace period; cutting them off` | The grace period was too short for them. |
| `stopped cleanly` | Exit with all usage delivered. |
| `stopped with N usage event(s) undelivered (kept in the spool)` | Exit while the control plane was unreachable; the events are sent at the next start. With `OMNIGATE_SPOOL=off` the line ends `(no spool: they are lost)`. |

## Load testing

`tools/load_test.py` drives a **running** gateway with many kinds of client
at once: keep-alive chat clients, streaming clients, clients that
disconnect after the first chunk, clients that stall half-way through a
body or never send anything, a failover route, a rate-limited key,
oversized and malformed bodies, pipelined requests, and a health probe
throughout. It starts nothing itself; point it at a gateway whose routes
lead to the mock upstreams. Against the quickstart setup:

```bash
python tools/load_test.py --gateway http://127.0.0.1:8080 --key og-unlimited-key --model demo-direct --failover-model demo-chat --duration 60
```

It passes when the gateway stays up and answers `/healthz` throughout,
every completed response is well formed with an expected status, stalled
and silent clients are disconnected, and the gateway's memory, threads and
handles do not keep growing (when it can find the gateway's process).
Options include `--limited-key`, `--dead-model`, `--events-url` (an
endpoint that tallies the usage events received, to check that none is
lost or duplicated), `--client-timeout` (set it to the gateway's
`OMNIGATE_CLIENT_TIMEOUT_MS` in seconds) and `--skip`; the file's docstring
and `--help` list them. It uses only the standard library and exits 0 on
PASS, 1 on FAIL.

It is not part of CI. The README records one run (Windows 11, optimized
build, Python mock upstream, 94 clients for five minutes) and says what it
was not: not over TLS, not against real providers, not beyond 550
connections. `tools/mock_upstream.py` takes `MOCK_PORT_OFFSET` to shift its
ports (9001-9005 by default), so that a second copy can run next to one
that is already in use.

## Troubleshooting

By the `error.type` in the gateway's answer. An answer that has an
`x-omnigate-upstream` header came from a provider, not from the gateway; see
the last rows.

| `error.type` | Likely cause | What to do |
|---|---|---|
| `gateway_not_ready` (503) | The data plane has never received a config. | Check `OMNIGATE_CONTROL_URL`, that the control plane is up (it does not start without `OMNIGATE_INTERNAL_TOKEN`, or with an invalid config file), and that both processes have the same `OMNIGATE_INTERNAL_TOKEN` (data plane log: `config fetch returned 401`). |
| `missing_api_key` (401) | No `Authorization: Bearer` or `x-api-key` header. | Send the gateway key. For a file URL: the `sig` parameter was stripped. With an SDK: it may have picked up no key, or the wrong one, from the environment. |
| `invalid_api_key` (401) | The key's SHA-256 is not known: never configured, deleted, disabled, or replaced by a rotation. | For a file key, check `key_sha256` is the lowercase hex hash of exactly the key string. `echo key \| sha256sum` hashes a trailing newline; use the Python command in [Configuration](configuration.md#gateway-keys). For a managed key, look at its state in the dashboard or `GET /admin/keys`. A new or changed key takes a few seconds to reach the data plane. |
| `budget_exceeded` (402) | Recorded spend in the key's budget period reached `budget_usd`. | Raise or remove the budget, or wait for the period to turn if it is monthly or daily; a `total` budget never resets by itself. See [Budgets](#budgets). The key can still read its jobs and files. |
| `overloaded` (503) | The data plane is at `OMNIGATE_MAX_CONNECTIONS`. | Retry after a second. If it persists: look for clients that open connections without reusing or closing them, lower `OMNIGATE_CLIENT_TIMEOUT_MS` so idle ones are dropped sooner, or raise the cap. |
| `model_not_allowed` (403) | The key has a `models` list without this route. | Add the route name to the list. |
| `model_not_found` (404) | No route with this name. Text endpoints only know `routes[]`; the jobs API only knows `media.routes[]`. | Check the name, and that you are calling the right API for it. |
| `not_found` (404) | The path or method is not one the gateway serves. | See the endpoint list in [API](api.md#text-endpoints). |
| `invalid_json`, `missing_model` (400) | The body is not a JSON object, or has no `"model"` string. | Fix the request. |
| `payload_too_large` (413) | Body over 8 MiB. | Send less; the limit is not configurable. |
| `rate_limit_exceeded` (429) | Over the key's `rpm`. | Wait `Retry-After` seconds, or raise `rpm`. |
| `all_upstreams_failed` (502) | Every target failed. | Read `error.attempts`: `http_429` / `http_5xx` are provider answers; `UpstreamTimeout` means no headers within the timeout; `ConnectionRefused` and similar are network errors; `unknown_upstream` means a target names an upstream that is not in `upstreams[]`; `protocol_mismatch` means an untranslated endpoint (embeddings, responses, completions, count_tokens) was routed to an upstream of the other protocol; `untranslatable_request` means the request has audio or file parts and the target speaks the other protocol. |
| `control_plane_unavailable` (503) | A jobs or files request could not reach the control plane within 30 seconds. | Check the control plane; text endpoints are unaffected. |
| `webhook_not_configured` (400) | A job asked for a webhook but no signing secret exists for the key. | Set one; see [Configuration](configuration.md#mediawebhooks). |
| `invalid_webhook_url` (400) | Not http(s), no host, embedded credentials, does not resolve, or resolves to a private address. | Use a public URL. For local development set `media.webhooks.allow_private` to `true`. |
| `idempotency_conflict` (409) | The `Idempotency-Key` was used before with a different body. | Use a new key for a new request. |
| `job_not_found`, `file_not_found` (404) | Wrong id, a job of another key, a job removed by retention, or a job of a key that was deleted and created again under the same name. | |
| `unauthorized` (401, control plane) | No valid admin token or session on `/admin/*` or `/metrics`. | Send `Authorization: Bearer <admin token>`. A gateway key or the internal token is not accepted here. |
| `csrf_failed` (403, control plane) | A change sent with a session cookie but without the session's CSRF token. | From a script, use the bearer token instead. In the dashboard, reload the page. See [Admin](admin.md#csrf-scripts-and-browsers). |
| `read_only_key` (409, control plane) | The key is defined in the config file. | Edit the file. |
| `key_exists` (409), `key_not_found` (404), `invalid_request` (400, control plane) | See [Admin](admin.md#errors). | |
| `invalid_signature`, `url_expired` (403) | A file URL was altered or is older than its lifetime. Changing `OMNIGATE_SIGNING_SECRET` (or the internal token it is derived from) also invalidates outstanding URLs. | Fetch the job again for a fresh URL. |

A media job that ends `failed`:

| `error.type` / attempt outcome | Likely cause |
|---|---|
| `all_targets_failed` | Read `attempts[].outcome`, below. |
| `missing_api_key_env:<VAR>` | The variable is not set in the **control plane's** environment. Media keys are not read from the data plane. |
| `unsupported_kind:<kind>` | Typo in `media.upstreams[].kind`. |
| `unknown_upstream` | A media target names an upstream that is not in `media.upstreams[]`. |
| `http_<status>: ...` | The provider refused the submit; its message follows. |
| `provider_failed: ...`, `provider_canceled`, `provider_expired: ...` | The provider accepted the job and then reported this. |
| `invalid_input: ...` | The adapter needs a field the job's `input` lacks; see [Providers](providers.md#media-providers). |
| `timeout` | The target did not finish within the route's `timeout_s`. |
| `no_outputs`, `no_output: ...` | The provider finished without a file (for Gemini: a blocked prompt or an early stop). |
| `output_fetch_failed: ...` | The output could not be downloaded: an HTTP error, more than `max_output_bytes`, or a stalled download. |
| `storage_error` | Outputs could not be stored: bucket endpoint, credentials or permissions. The control log has the detail. |
| `route_removed` | The media route was deleted from the config while the job was unfinished. |

Provider answers passed through (they carry `x-omnigate-upstream`):

| Symptom | Likely cause |
|---|---|
| 401 or 403 in the provider's own error format | The provider key is missing or wrong in the **data plane's** environment. An unset `api_key_env` variable is sent as an empty key. |
| 400 naming a parameter | The provider refused the request as sent. In the provider's own protocol the gateway does not alter requests. |
| 404 from the provider | The target's `model` is not a model id the provider knows, or `base_url` / `v1_path` is wrong. |

Other symptoms:

| Symptom | Likely cause |
|---|---|
| Dashboard login answers 429 | Five failed logins from one address within a minute. Behind a reverse proxy all clients share the proxy's address. Wait a minute. |
| Signed out of the dashboard after changing the admin token | Expected: sessions are signed with a key derived from the token. |
| Output URLs point at `127.0.0.1:8080` | `media.public_base_url` is still the default. |
| A webhook never arrives | Look at `webhook.last_status` and `webhook.last_error` in the job. The receiver must answer 2xx; a redirect counts as a failure. |
| Streamed tokens arrive in one burst through your proxy | The proxy is buffering. In Caddy: `flush_interval -1`. |
| Spend shows $0 | The route's targets have no prices. Or the answers came from the response cache, which costs nothing. |
| The control plane exits at once, or its container keeps restarting | `OMNIGATE_INTERNAL_TOKEN` is unset or empty (the log says so), the config file is invalid, or the keys file exists but cannot be read. |
| A connection the client kept open was closed by the gateway | It was idle for `OMNIGATE_CLIENT_TIMEOUT_MS` (30 seconds by default). Most HTTP clients retry on a fresh connection by themselves. |
| A long streamed answer was cut off | The upstream sent nothing, or the client read nothing, for `OMNIGATE_STREAM_IDLE_TIMEOUT_MS`. The ledger has the request with status 499. |
| A changed answer keeps coming back unchanged | The route has `cache_ttl_s` and the response carries `x-omnigate-cache: hit`. |
| A new key works on one data plane and not yet on another | Each data plane polls the config by itself; wait one poll interval. |
| A blocked monthly key is still blocked after midnight UTC on the first | The data plane learns of the change with its next poll; if the control plane is unreachable it cannot learn of it at all. |
