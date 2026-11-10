# Operations

- [Dashboard and admin API](#dashboard-and-admin-api)
- [Metrics](#metrics)
- [Budgets](#budgets)
- [Rate limits](#rate-limits)
- [Timeouts, failover and cooldowns](#timeouts-failover-and-cooldowns)
- [Retention](#retention)
- [When the control plane is down](#when-the-control-plane-is-down)
- [Logs](#logs)
- [Troubleshooting](#troubleshooting)

## Dashboard and admin API

The control plane serves a read-only dashboard at `/` (sign in with the
admin token). It shows per-key totals, up to 50 recent text requests with
their failover attempts, and the 20 most recent media jobs with their
webhook state. The page reloads itself every two seconds.

The same per-key totals are available as JSON from `GET /admin/usage`; see
[API](api.md#get-adminusage).

There is no API or UI for changing anything: keys, routes, budgets and
limits are changed by editing the config file, which is reloaded within
about two seconds.

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

- **Everything comes from the control plane's own state**: the ledger
  totals, the job store and the config. The data plane has no metrics
  endpoint, so there are no latency histograms, no upstream health gauges
  and no count of rate-limited requests.
- **Only requests that reached the failover loop are in the ledger.**
  Requests the gateway refused earlier (400, 401, 402, 403, 404, 413, 429)
  are not counted anywhere.
- **Per-key counters are totals over the whole ledger.** They are rebuilt
  from the ledger file at start, so they do not reset when the control plane
  restarts. `omnigate_config_reloads_total` and `omnigate_uptime_seconds` do.
- **`omnigate_key_errors_total`** counts ledger events with a status of 400
  or above. That includes provider errors passed to the client, 502s after
  every target failed, streams that broke mid-way (499), and failed (502) or
  canceled (499) media jobs.
- **`omnigate_jobs` and `omnigate_webhooks`** describe the jobs currently in
  the job store. With retention on, removed jobs leave these gauges.
- **Each scrape scans the whole job store.** Keep the scrape interval
  moderate if you hold many jobs, or turn on retention.
- The `key` label is the key's `name`. Give keys distinct names.

Useful alerts, given what is exposed: `omnigate_key_blocked == 1`,
`omnigate_webhooks{state="failed"} > 0`, and
`omnigate_key_cost_usd_total` approaching `omnigate_key_budget_usd`.

## Budgets

A key with `budget_usd` is blocked once the spend recorded for it reaches
the budget.

- **Spend** is the sum of the cost of every ledger event for that key: text
  calls priced by the target's `price_in_per_mtok` / `price_out_per_mtok`,
  and media jobs priced by the target's `price`.
- **There is no budget period.** Spend is the total over the whole ledger;
  nothing resets it monthly or otherwise. To let a blocked key continue,
  raise or remove its `budget_usd` in the config.
- **Enforcement is after the fact.** The call that crosses the budget
  completes. The control plane then marks the key blocked in the config
  snapshot, and the data plane starts answering 402 `budget_exceeded` after
  its next poll. The lag is the usage flush interval plus one poll interval.
  Creating a media job is also checked by the control plane directly,
  without that lag.
- **A blocked key is refused on every gateway endpoint**, including
  `GET /v1/models` and polling its own jobs. Signed file URLs keep working.
- **Cost is fixed when an event is recorded**, using the prices in the
  config at that moment. Changing a price does not re-price history. An
  event whose route or target is no longer in the config is recorded with
  zero cost.
- **A target with no prices costs nothing**, so a budget on a key that only
  uses unpriced routes never triggers.

From the README: cached-token and reasoning-token prices are not modelled
(cost is input and output tokens only); budgets are enforced on a single
control-plane node; and a key cannot be newly blocked during a control-plane
outage.

## Rate limits

A key with `rpm: N` may burst up to N requests and is refilled at N per
minute (a token bucket).

- What counts: every metered text endpoint (not `count_tokens`), and
  `POST /v1/jobs`. Polling, listing and canceling jobs do not count.
- A request refused for its model (`model_not_allowed`) does not count. For
  text endpoints the body is read before the limit is checked, so a key over
  its limit still costs one body read.
- Over the limit, the answer is 429 `rate_limit_exceeded` with a
  `Retry-After` header in whole seconds.
- State is in memory in each data-plane process. A restart forgives the
  last minute; several data planes each allow the full limit.
- Changing a key's `rpm` in the config starts it with a full bucket.

## Timeouts, failover and cooldowns

- **Timeout** is the maximum wait for an upstream's response headers:
  `OMNIGATE_UPSTREAM_TIMEOUT_MS` (10 minutes by default), or the upstream's
  own `timeout_ms`. There is no idle timeout once a response has started
  streaming.
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
`x-omnigate-upstream` on the response, or at the attempts column in the
dashboard.

## Retention

Off by default: nothing is deleted unless the config has a `retention`
section.

```json
"retention": { "jobs_days": 30, "ledger_ids_days": 7 }
```

One sweep runs a few seconds after the control plane starts and then every
hour. When it removes something it logs
`retention sweep removed N finished jobs, N stored files, N ledger dedup ids`.

**`jobs_days`.** Jobs that finished (succeeded, failed or canceled) more
than this many days ago are removed from the job store and its file, and
their outputs on local disk are deleted.

- Unfinished jobs are never touched, whatever their age. Neither are jobs
  with a webhook delivery still pending or retrying.
- A removed job can no longer be fetched, replayed by its idempotency key,
  or used as a cache hit.
- **Outputs in a bucket are not deleted.** Expire those with the bucket's
  own lifecycle rules.

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
| Keys, routes, rate limits | As in that last config. Config edits are not seen until the control plane is back. |
| Budgets | Keys already blocked stay blocked. A key cannot be newly blocked. |
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

Lines worth knowing, control plane:

| Line | Meaning |
|---|---|
| `loaded config <path>: N routes, N keys` | Startup. |
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
| `omnigate data plane listening on <address> (control plane <url>)` | Startup. |
| `installed config version <id> (N routes, N keys)` | A new config snapshot is in force. |
| `initial config sync failed (...)` | The control plane was unreachable at startup; the line says whether a cached config is being served. |
| `config fetch returned 401` | The two `OMNIGATE_INTERNAL_TOKEN` values differ, or the control plane has none. |
| `config sync failed (...); serving last good config` | Logged once per outage. `control plane reachable again` ends it. |
| `upstream <name> returned <status>, failing over` | A 429 or 5xx. |
| `upstream <name> failed: <error>` | A connection error or timeout. |
| `upstream <name> keeps failing; trying it last for the next N ms` | A cooldown started. |
| `usage delivery failed (...); spooling, N events queued` | Logged once per outage. `usage delivery resumed` ends it. |
| `reloaded N undelivered usage events from spool` | Startup after an outage or crash. |
| `<upstream>/<model> rejects sampling parameters; retrying without them` | A learned model quirk. |

## Troubleshooting

By the `error.type` in the gateway's answer. An answer that has an
`x-omnigate-upstream` header came from a provider, not from the gateway; see
the last rows.

| `error.type` | Likely cause | What to do |
|---|---|---|
| `gateway_not_ready` (503) | The data plane has never received a config. | Check `OMNIGATE_CONTROL_URL`, that the control plane is up, and that both processes have the same `OMNIGATE_INTERNAL_TOKEN` (data plane log: `config fetch returned 401`). If the log says `config sync failed` although the control plane is up, the config may name a text upstream `kind` other than `openai` or `anthropic`. |
| `missing_api_key` (401) | No `Authorization: Bearer` or `x-api-key` header. | Send the gateway key. For a file URL: the `sig` parameter was stripped. |
| `invalid_api_key` (401) | The key's SHA-256 is not in the config. | Check `key_sha256` is the lowercase hex hash of exactly the key string. `echo key \| sha256sum` hashes a trailing newline; use the Python command in [Configuration](configuration.md#gateway-keys). A newly added key takes a few seconds to reach the data plane. |
| `budget_exceeded` (402) | Recorded spend reached `budget_usd`. | Raise or remove the budget. Spend never resets by itself; see [Budgets](#budgets). |
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
| `job_not_found`, `file_not_found` (404) | Wrong id, a job of another key, or a job removed by retention. | |
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
| Spend shows $0 | The route's targets have no prices. |
