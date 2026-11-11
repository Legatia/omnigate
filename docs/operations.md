# Operations

- [Dashboard and admin API](#dashboard-and-admin-api)
- [Health and readiness](#health-and-readiness)
- [Metrics](#metrics)
- [Refused requests](#refused-requests)
- [Budgets](#budgets)
- [Rate limits](#rate-limits)
- [Timeouts, failover and cooldowns](#timeouts-failover-and-cooldowns)
- [Streams that end early](#streams-that-end-early)
- [Connection limits and shutdown](#connection-limits-and-shutdown)
- [Retention](#retention)
- [When the control plane is down](#when-the-control-plane-is-down)
- [Logs](#logs)
- [Load testing](#load-testing)
- [Hostile-input testing](#hostile-input-testing)
- [Troubleshooting](#troubleshooting)

Hardening a deployment (what to expose, where each credential lives, the
admin allow-list, log hygiene) has its own page:
[Security hardening](security.md).

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

## Health and readiness

- `GET /healthz` on the data plane (no key) and on the control plane (no
  credentials) says the process is up.
- `GET /readyz` on the control plane says it can do its job: the config is
  loaded, the job store is running, and the ledger is loaded and writable.
  It answers `503` with a `reason` otherwise, for example
  `ledger file is not writable`.

Which probe to use where, and what the container health checks do, is in
[Deployment](deployment.md#health-and-readiness-probes). The data plane has
no readiness endpoint: whether it has a config shows in its answers
(`503 gateway_not_ready`) and in its log. Its binary can probe itself:
`omnigate-dp healthcheck` asks the address in `OMNIGATE_LISTEN` for
`/healthz` and exits 0 on a 200 within three seconds, 1 otherwise, which is
what the data-plane image's `HEALTHCHECK` runs (the image has no shell and
no curl).

The control plane's listener outlives its stores. The ledger, the job
store, the keys and the audit log run as one group that is restarted, with
a pause growing from half a second to thirty, if one of them keeps
crashing; the listener is not touched. During such a restart `/healthz`
says `200`, `/readyz` says `503` with the reason, and
`GET /internal/config` answers `503 not_ready`, so data planes keep their
config and a key that is over budget stays blocked.

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
  restored from the ledger's snapshot and segments at start, so they do not
  reset when the control plane restarts, and deleting old segments with
  `retention.ledger_days` does not lower them. `omnigate_config_reloads_total`,
  `omnigate_uptime_seconds` and `omnigate_rejected_requests_total` do.
- **A rotated key keeps its series**: usage under earlier secrets is added
  in. A deleted key's series disappear, although its events stay in the
  ledger.
- **`omnigate_key_errors_total`** counts ledger events with a status of 400
  or above. That includes provider errors passed to the client, 502s and
  429s after every target failed, streams that broke or stalled mid-way
  (499), and failed (502) or canceled (499) media jobs.
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
- **Each scrape scans the whole job store**, in one pass and without
  copying it. Keep the scrape interval moderate if you hold many jobs, or
  turn on retention.
- **`omnigate_ledger_dedup_ids`** is the number of event ids held to reject
  resent usage, about 61 MiB of control-plane memory per million. It
  follows your request rate times `retention.ledger_ids_days`.
- **`omnigate_ledger_unpriced_events_total`** counts usage recorded at $0
  because the config has no such route or target (a route renamed while
  data planes still used the old snapshot, a typo in a target), and media
  jobs that succeeded on a target with no price. That is how real spend
  goes missing from a budget; the first event of each route and target is
  also logged.
- **`omnigate_ledger_invalid_events_total`** counts usage events a data
  plane sent that the ledger could not record (missing or mistyped fields).
  It should stay at zero.
- Both of those restart from zero with the control plane.
- The `key` label is the key's `name`. Give keys distinct names.

Useful alerts, given what is exposed: `omnigate_key_blocked == 1`,
`omnigate_webhooks{state="failed"} > 0`,
`omnigate_key_period_cost_usd` approaching `omnigate_key_budget_usd`, a
rising `omnigate_ledger_unpriced_events_total` or
`omnigate_ledger_invalid_events_total`, and a rising
`omnigate_rejected_requests_total{reason="overloaded"}`,
`{reason="concurrency_limit_exceeded"}`,
`{reason="request_memory_exceeded"}` or `{reason="invalid_api_key"}`.

## Refused requests

A request the gateway answers itself before routing (a bad key, a rate
limit, a model the key may not use, a malformed body) never reaches a
provider and never becomes a usage event. Each data plane counts these per
key name and reason and reports the counts to the control plane every
`OMNIGATE_FLUSH_MS`. They appear in the dashboard's "Refused requests"
table and as `omnigate_rejected_requests_total{key, reason}`.

`reason` is the `error.code` the client received: `invalid_api_key`,
`missing_api_key`, `budget_exceeded`, `model_not_allowed`,
`rate_limit_exceeded`, `concurrency_limit_exceeded`,
`request_memory_exceeded`, `model_not_found`, `not_found`, `invalid_json`,
`missing_model`, `payload_too_large`, `method_not_allowed`,
`invalid_request`, `request_too_complex`, `endpoint_not_supported`,
`untranslatable_request`, `gateway_not_ready`, `control_plane_unavailable`,
and `overloaded` (a connection refused at the connection cap, under the key
`-`, or a request refused because the gateway's memory budgets were spoken
for, under the key's name), and `too_many_redactions` (a private request
with more distinct values to replace than one request may hold). One more
has no error body: `client_timeout`, a client that was disconnected for
sending too slowly.

The same report from the data planes carries one more kind of count, which
is not a refusal and is kept apart: how many values
[privacy mode](privacy.md#redaction) replaced before a provider saw them,
per key and class. They appear as `omnigate_redactions_total{key, class}`
and in `GET /admin/overview` under `redactions`; like the refusals they are
held in memory and start from zero with the control plane. They are counts:
what was replaced is never reported.

`upstream_rate_limited` and `all_upstreams_failed` are not in this list.
Those requests reached the failover loop, so they are in the ledger (and in
`omnigate_key_requests_total` and `omnigate_key_errors_total`) instead.

`key` is the key's name, or `-` when the request could not be tied to a
known key (no key, an unknown key, or a connection refused before anything
was read).

`invalid_request` covers everything the gateway refuses for the shape of
the request rather than its content: a malformed or ambiguous request head
(answered 400, 411, 417 or 431), a path that is not in canonical form, a
query string or forwarded header with characters outside the allowed sets
([API](api.md#request-heads-paths-and-queries)). A request refused for its
head is counted under the key `-`, since the key was never read. A steady
trickle of these from the internet is normal; a rise from one of your own
applications means its HTTP client builds requests the gateway will not
take.

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
  `price`, applied to what the adapter sent to the provider
  ([Configuration](configuration.md#mediaroutes)).
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
  zero cost, counted in `omnigate_ledger_unpriced_events_total` and logged
  once per route and target.
- **A target with no prices costs nothing**, so a budget on a key that only
  uses unpriced routes never triggers. For a media target that is counted
  in the same metric and logged once.
- **A blocked key stays blocked while the ledger restarts.** The config
  snapshot says who is over budget, and without the ledger that is not
  known, so the control plane answers data planes `503 not_ready` until the
  totals are loaded; they keep the snapshot they have.
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
  `POST /v1/jobs`. Polling, listing and canceling jobs do not count against
  it (listing has an allowance of its own, below). A request answered from
  the response cache counts like any other.
- **The limit is charged before the request body is read.** A request that
  is then refused for its size, for malformed JSON, for a model the key may
  not use (`model_not_allowed`) or for a model that does not exist has
  therefore used up one request of the allowance. That is the price of not
  reading up to eight megabytes to find out. Until commit e4e30e4 it was the
  other way round: the body was read first and a refused model cost
  nothing.
- A request refused earlier costs nothing: a bad key, a spent budget, an
  unknown endpoint, and the key's concurrency cap or the request-memory
  budget ([Connection limits](#connection-limits-and-shutdown)), which are
  checked just before the rate limit.
- Over the limit, the answer is 429 `rate_limit_exceeded` with a
  `Retry-After` header in whole seconds.
- State is in memory in each data-plane process. A restart forgives the
  last minute; several data planes each allow the full limit.
- **Job creation is counted a second time, in the control plane**, with the
  same `rpm` and the same token bucket, number for number. It is the
  handler that creates the job that counts, so the limit holds however a
  request reached it, and across several data planes. Over it, the control
  plane answers 429 `rate_limit_exceeded` with `Retry-After` (the seconds
  until the next request fits), which the data plane passes on. A request
  that repeats an `Idempotency-Key` the key already used creates nothing
  and is not counted here. The buckets are kept per key, by the hash of its
  current secret (so two keys never share one, and a rotation starts a new
  allowance), in memory; a control-plane restart forgives the last minute.
  (Until commit d79406b the control plane counted in fixed one-minute
  windows.)
- **Listing jobs has its own allowance**, in the control plane: the key's
  `rpm` when it has one, 600 per minute otherwise. `GET /v1/jobs` over it
  answers 429 `rate_limit_exceeded`. It never eats into the allowance for
  creating jobs. Fetching one job by id is not limited.
- Changing a key's `rpm` in the config starts it with a full bucket.
- The `x-ratelimit-*` and `anthropic-ratelimit-*` headers a client may see
  on a response are the provider's, passed through
  ([API](api.md#response)). They describe your provider key's limits, not
  this `rpm`.

**Unfinished jobs per key.** Separately from the rate, a key may have at
most `max_open_jobs` media jobs queued or running at once: the key's own
setting, else `media.max_open_jobs`, 100 by default, `0` for no limit.

- One job more is refused with 429 `too_many_open_jobs` and
  `Retry-After: 10`. The slot comes back when a job reaches a final status,
  or is cancelled.
- Jobs created under the key's earlier secrets count, so a rotation does
  not reset it. A replay by `Idempotency-Key` returns the existing job and
  is never refused.
- It bounds what a single key can leave running at your providers, and
  what it can make the control plane hold: each job's `input` and
  `metadata` (at most `media.max_input_bytes` together, 1 MiB by default)
  stay on disk for as long as the job does. An input over 8 KiB is kept in
  a file of its own (`<job log>.inputs/<job id>.json`) rather than in
  memory.

**Jobs per day per key.** A key may create at most `max_jobs_per_day` jobs
per UTC day: the key's own setting, else `media.max_jobs_per_day`, 10,000
by default, `0` for no limit.

- One job more is refused with 429 `too_many_jobs_today`. The count starts
  again at midnight UTC, and the answer's `Retry-After` says how far away
  that is, in seconds, but never more than 3,600: a client that honours it
  comes back at most once an hour, and finds out if the limit was raised
  in the meantime. (Until the close-out commit it was a fixed 10 seconds.)
- Every created job counts, whatever became of it. That is the point: the
  open-jobs limit does not bound jobs that end at once (a refused input, a
  provider that is down), and each of those still costs a log line, a
  ledger event and a webhook call.
- Jobs created under the key's earlier secrets count, and the count
  survives a control-plane restart (it is rebuilt from the job log). A
  replay by `Idempotency-Key` creates nothing and is never refused.

## Timeouts, failover and cooldowns

Four timeouts, all on the data plane:

| Timeout | Variable (default) | Applies to | When it fires |
|---|---|---|---|
| Upstream | `OMNIGATE_UPSTREAM_TIMEOUT_MS` (10 minutes), or the upstream's `timeout_ms` | Waiting for a provider's response headers | The target is abandoned (`UpstreamTimeout`) and the next one is tried. |
| Client | `OMNIGATE_CLIENT_TIMEOUT_MS` (30 seconds) | A client sending its request head and body, and an idle keep-alive connection between requests | The connection is closed. No response is sent (there is no 408). |
| Stream idle | `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` (5 minutes) | The **upstream** sending nothing after its response head. | A response already being relayed: both sides are closed, and the call is billed with status 499: the provider's figures if they had arrived, otherwise an estimate ([below](#streams-that-end-early)). An answer of which nothing has been sent on yet: a failed attempt (`StreamIdleTimeout`), and the next target is tried. |
| Client stall | `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` (30 seconds) | A client that is connected but takes none of a response: a provider's answer, a file download, a jobs API answer, or one of the gateway's own answers (an error, the model list, a cache hit) once the request has been read. | The client's connection is closed. For a metered stream the upstream is then read to its end in the background and the call billed with status 499 ([below](#streams-that-end-early)). |

The first three can be turned off with `0`; a client stall timeout of `0`
means "the same as the stream idle timeout". Until commit e4e30e4 the
stream idle timeout covered both directions, so a client that stopped
reading was given five minutes; it now gets thirty seconds. Notes:

- The client timeout is one allowance for the request head and a fresh one
  for the body; it does not limit how long the gateway then waits for the
  provider.
- The stream idle timeout restarts whenever bytes move, so a long but
  steadily streaming answer is never cut. It also covers a non-streaming
  answer whose body stalls after the headers. Such an answer is buffered
  before any of it is sent (up to 64 KiB, or all of it when it is being
  translated), so nothing has reached the client when the timeout passes:
  the attempt fails with `StreamIdleTimeout` and the request goes to the
  route's next target, or ends in `502 all_upstreams_failed` with that
  outcome among the `attempts`. In that phase the silence is noticed after
  between one and two times the timeout. Until the close-out commit the
  watchdog ended such a request's task instead, which could leave the
  following attempts and the connection without any deadline.
- Until the close-out commit the gateway's own answers (errors, the model
  list, cache hits) were written under the stream idle timeout; they are
  under the client stall timeout now. A refusal sent before the request
  body was read is under the client timeout.
- A client that stalls while sending its body shows in the access log with
  status 408 and `aborted=ClientTimeout` (the 408 is for the log only), and
  is counted as `client_timeout` among the
  [refused requests](#refused-requests). A connection closed while idle, or
  before a complete request head arrived, leaves no access-log line. A
  response cut by the stream idle timeout shows status 499 and
  `aborted=StreamIdleTimeout`; one given up on because the client stopped
  reading shows status 499 and `aborted=ClientStalled`.
- Clients that keep connections open for reuse should expect the gateway to
  close a connection that has been idle for the client timeout, and retry
  on a fresh one.

Failover and cooldowns:
- **Failover** to the next target happens on connection errors, timeouts,
  429 and 5xx, on a response the gateway cannot frame (`UpstreamUnparseable`:
  both a length and chunked encoding, a chunk size that does not parse) and
  on a short answer that is cut off before its end (`UpstreamTruncated`),
  and only before any byte has reached the client. When no
  target is left, the client gets 429 if any of them answered 429 (with
  the longest `retry-after` those sent), and 502 otherwise. A connection
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

## Streams that end early

A response that stops before its end is still paid for at the provider, so
the gateway bills it. What it bills depends on whether the provider's
closing usage figures were seen.

| What happened | What the data plane does | What is billed |
|---|---|---|
| The client disconnected mid-response, or stopped reading for `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` (30 seconds) | Finishes with the client's connection and keeps reading the upstream **in the background**: to the provider's closing usage, or the end of the answer, or for at most `OMNIGATE_ABORT_DRAIN_MS` (2 minutes) and `OMNIGATE_ABORT_DRAIN_MAX_MB` (64) more megabytes. Then closes the upstream connection. | The provider's real figures if they arrived; otherwise an estimate. |
| The upstream went silent until the stream idle timeout | Closes both sides | The real figures if they had already been seen; otherwise an estimate. |
| The upstream broke the connection mid-response, or sent less than it declared | Drops the client's connection (without the closing chunk of the chunked response) | The same. |
| An event stream reached its proper end, and the provider never reported usage (it ignores `stream_options.include_usage`, as some OpenAI-compatible servers do) | Nothing special: the client got the whole answer, status 200 | An estimate. Before the third-review commit such a call was recorded with zero tokens. |

- **Reading on happens off the client's connection.** The connection is
  free at once; the exchange with the provider is handed to a task of its
  own. One usage event is written when that task ends, so the ledger line
  of an abandoned stream can appear up to two minutes after the client
  left, and the access-log line (written when the client's request ended)
  shows the figures known at that moment. The data plane logs
  `request <id>: read N more bytes from <upstream> after the client left; billing the provider's usage (in=N out=N)`
  (or `billing ESTIMATED usage`) when it is done.
- **It still counts against the key.** Until the reading ends, the request
  keeps its place in the key's concurrency cap
  (`OMNIGATE_MAX_CONCURRENT_PER_KEY`), so opening streams and hanging up is
  not a way around the cap.
- **At most 256 answers are read on at once.** Beyond that, and during a
  shutdown, an abandoned stream is billed the estimate at once, as with
  `OMNIGATE_ABORT_DRAIN_MS=0`.
- **The estimate** is never less than what was metered. Missing input is
  taken as the request body's bytes divided by 4, plus 1,600 tokens for
  every image, document, file or audio part the request names (such a part
  is often a short URL that the provider turns into many tokens). Missing
  output is, for an event stream, the larger of one token per event
  received and the generated text received divided by 4 (so a provider
  that sends several tokens per event is not billed at a fraction); the
  response's bytes divided by 4 when it was not an event stream. It is
  meant to be near what the provider charged, and errs high for the
  request.
- **How to tell.** The usage event carries `"estimated": true`, which is
  written to the ledger segment with the rest of the event and shown per
  request in `GET /admin/overview` (`requests[].estimated`, for the newest
  requests only). In the data plane's access log the line has status 499
  and `aborted=ClientDisconnected`, `ClientStalled` or `StreamIdleTimeout`,
  with `usage=estimated` in the text format and `"estimated":true` in the
  JSON format when the figures on that line are an estimate. The dashboard
  page and `/metrics` do not show the mark; to count estimated calls over
  time, search the ledger segments or the access log.
- **`OMNIGATE_ABORT_DRAIN_MS=0`** skips the reading: a client that leaves
  before the closing figures is billed the estimate at once. A larger
  value makes the bill exact more often and keeps the upstream connection
  (and the provider generating) that much longer after the client has
  gone.
- OpenAI-style providers send the usage as the last event of a stream, so
  for them almost every abandoned stream needs the reading. Anthropic-style
  providers report input at the start and output near the end.
- Only metered endpoints produce a usage event at all
  ([API](api.md#text-endpoints)).

Earlier commits billed only what had been metered when the client left,
which for an OpenAI-style stream was usually nothing; then, until commit
e4e30e4, the client's own connection waited up to five seconds (and 8 MiB)
for the figures, which a long generation outlasted.

## Connection limits and shutdown

**Connection cap.** The data plane serves at most
`OMNIGATE_MAX_CONNECTIONS` client connections at once (4096 by default). A
connection beyond that is answered at once, without its request being read,
with `503` `overloaded`, `retry-after: 1` and `connection: close`, and is
counted as `overloaded` among the [refused requests](#refused-requests).
The data plane uses one thread per connection, so the cap is also a cap on
threads. The README records what has been tried: a soak at 94 connections
for five minutes and a run at 550 for two; nothing beyond that.

**Per-key and memory limits.** A valid key is not allowed to decide how
much the process holds. Before a request body is read, the data plane
checks, in this order:

| Limit | Variable (default) | Over it |
|---|---|---|
| Requests of one key in flight | `OMNIGATE_MAX_CONCURRENT_PER_KEY` (512) | 429 `concurrency_limit_exceeded` |
| Request bodies of one key in flight (declared length, counted twice) | a quarter of `OMNIGATE_REQUEST_MEMORY_MB` (1024) | 429 `request_memory_exceeded` |
| Request bodies of all keys in flight | `OMNIGATE_REQUEST_MEMORY_MB` (1024) | 503 `overloaded` |

Then the rate limit, then the declared length against the 8 MiB limit, and
only then is the body read. Where a body has to be parsed into a tree
(translation, the response cache, provider quirks), the tree is built in
an arena capped at 128 times the text plus 1 MiB and at most 96 MiB, and
the caps of all trees being built are reserved against
`OMNIGATE_PARSE_MEMORY_MB` (1024; half of it per key): 400
`request_too_complex`, 429 `request_memory_exceeded` or 503 `overloaded`.
Every one of the 429 and 503 answers has `retry-after: 1` and is counted
among the [refused requests](#refused-requests).

- These are refusals, not failures; a client that retries gets through
  when the load has passed.
- The defaults are generous on purpose (512 requests in flight for one key
  is more than most applications ever have). Lower
  `OMNIGATE_MAX_CONCURRENT_PER_KEY` if you hand keys to parties you do not
  trust, and size the two memory budgets to the memory the process may
  use: the binary's defaults add up to 2 GiB, which is why `compose.yaml`
  sets them to 256 MiB each for its 1 GiB container
  ([Deployment](deployment.md#memory-limits)).
- A key can have a cap of its own, `max_concurrent`, in the config file or
  through the admin API (since the close-out commit); the variable is the
  cap of every key without one.
- The measurements behind this, from the commit that added it: an 8 MiB
  body built to be expensive took 1,096 MiB at its peak before and 30 MiB
  after; a body of keys chosen to collide in the parser's hash map took 4
  seconds of CPU before and none after.

**Graceful shutdown.** On SIGTERM or SIGINT (Ctrl-C, Ctrl-Break or closing
the console on Windows) the data plane:

1. stops accepting connections;
2. closes connections that are between requests;
3. lets requests in flight finish, for up to `OMNIGATE_SHUTDOWN_GRACE_MS`
   (10 seconds by default), then cuts off whatever is still running, and
   stops reading upstream answers whose client has left (each is billed
   what is known by then, as an estimate);
4. makes a last attempt to deliver queued usage (up to 20 batches of 500
   events) and the refusal counts;
5. exits. Usage that could not be delivered stays in the spool file and is
   sent at the next start; with `OMNIGATE_SPOOL=off` it is lost, and the log
   says how many events.

In a container this is what makes `docker stop` end the data plane cleanly
instead of waiting to kill it. Docker waits 10 seconds by default before
killing a container, which is the same as the default grace, so
`compose.yaml` gives the data plane `stop_grace_period: 20s`; if you raise
`OMNIGATE_SHUTDOWN_GRACE_MS`, raise that above it. The container test
checks that the data-plane container exits with status 0 on SIGTERM, and
that both services have their stop timeouts.

**Exit codes of the data plane.** `0` after a clean stop, `1` for a startup
error (a missing token, a bad setting), `2` for an argument it does not
know (the only one is `healthcheck`, which itself exits 0 or 1), and `70`
after a panic. Request
input is validated so that it cannot reach a panic, but if one happens
anyway the whole process ends, so an optimized build logs one line
(`error(panic): <message>`, or a JSON line with `"scope":"panic"`) and
exits with 70 for the supervisor to restart it. Usage events already
queued are in the spool and are delivered after the restart; requests in
flight, and refusal counts not yet reported, are lost. Debug builds keep
the standard handler and its stack trace instead. Treat an exit with 70 as
a bug to report.

A restart still drops the state the data plane keeps only in memory:
rate-limit buckets, cooldowns, round-robin counters, learned model quirks,
the response cache, and refusal counts not yet reported.

The control plane has no drain step for requests; at a clean stop it
writes a ledger snapshot, for which `compose.yaml` gives it
`stop_grace_period: 30s`. What a restart of it means for jobs is in
[Deployment](deployment.md#upgrades).

## Retention

Jobs, files and ledger segments are kept for ever unless the config has a
`retention` section that says otherwise. The ledger's duplicate-detection
ids are the one thing with a finite default: 3 days.

```json
"retention": { "jobs_days": 30, "ledger_ids_days": 3, "ledger_days": 90, "delete_bucket_objects": true }
```

One sweep runs a few seconds after the control plane starts and then every
hour. When it removes something it logs
`retention sweep removed N finished jobs, N stored files, N bucket objects, N ledger dedup ids, N ledger segments`.

**`jobs_days`.** Jobs that finished (succeeded, failed or canceled) more
than this many days ago are removed from the job store and its file, and
their outputs are deleted: files on local disk, and objects in the bucket.

- Unfinished jobs are never touched, whatever their age. Neither are jobs
  with a webhook delivery still pending or retrying.
- A removed job can no longer be fetched, replayed by its idempotency key,
  or used as a cache hit. Its input file, if it had one
  (`<job log>.inputs/<job id>.json`), goes with it.
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
duplicates once they are older than this. The default is 3 days, also when
there is no `retention` section at all; `0` keeps them for ever. (The
default was 14 until commit d79406b, and before commit 3a0b147 ids were
kept for ever.)

- Ids are kept per UTC day, in memory and in one small file per day next
  to the ledger (`ledger.ids.YYYY-MM-DD`, 16 bytes per id). Forgetting is
  deleting whole days, so an id is kept for at least the configured time
  and at most a day longer.
- Spend totals and the ledger's segments are untouched. What shrinks is
  the set held in memory (about 61 MiB per million ids; see
  `omnigate_ledger_dedup_ids`), which otherwise grows with every request
  ever served. The ids are no longer part of the snapshots, so writing a
  snapshot no longer stalls the ledger (at a million ids: 1.6 seconds
  before, 12 milliseconds after).
- A usage event that a data plane resends after its id was forgotten would
  be counted twice. An id only matters while a data plane might still
  resend its event, and the only place a resend comes from is a data
  plane's spool. **Keep this above the longest time a data plane may hold
  undelivered usage**: the longest control-plane outage, or the longest a
  data plane is switched off with events in its spool, that you expect to
  ride out. Three days covers a control plane that is down over a weekend,
  or a data plane stopped on Friday and started on Monday. Raise it if
  yours can be apart for longer.

**`ledger_days`.** Sealed ledger segments (the files
`ledger.NNNNNN.jsonl`) whose last write is older than this are deleted.

- Totals are unaffected: per-key spend, period spend and the metrics keep
  counting what the deleted segments held, because the ledger's snapshots
  carry it. What is gone is the event history itself (one line per request,
  with tokens, upstream and attempts).
- **After the first deletion, the two snapshot files are the only copy of
  those totals.** Back up the whole data directory, snapshots included; see
  [Deployment](deployment.md#backups).
- A segment is deleted only when both snapshots cover it, and the newest
  sealed segment always stays. After a restart only the snapshot the
  control plane started from is vouched for, so the sweep writes a new one
  first (the one it started from becomes the spare) and then deletes what
  both cover. A quiet installation that records nothing after a restart
  therefore still gets rid of due segments; until commit 10bc009 it did
  not.
- The active segment is sealed at 64 MiB or after the UTC day turns, so
  with steady traffic there is about one segment per day and `ledger_days`
  is accurate to about a day. An installation with no traffic seals nothing
  and deletes nothing.
- The age that counts is the file's modification time. A restored or
  copied segment whose time stamp was not preserved looks new and is kept
  longer.

Without `ledger_days` the segments are kept for ever. They no longer slow
down a start, which loads the newest snapshot and replays only what came
after it; they only take disk space.

### Private jobs

Jobs created under [privacy mode](privacy.md#no-retention)'s `no_store` have
a rule of their own, which does not wait for `jobs_days`:

- their `input` and `metadata` are erased the moment the job ends (not by
  the sweep; the job does it), and
- their outputs are deleted by the sweep once the job finished more than
  `retention.private_outputs_hours` ago (24 by default; `0` keeps them like
  any other job's). Local files and bucket objects alike, whatever
  `delete_bucket_objects` says. The job stays, with `"outputs_expired": true`.

The sweep runs hourly, so the outputs live between 24 and 25 hours with the
default. Its log line counts them:

```text
retention sweep removed 0 finished jobs, 0 stored files, 0 bucket objects, 0 ledger dedup ids, 0 ledger segments, and the outputs of 3 private jobs
```

A bucket lifecycle rule is still a good backstop for objects a failed delete
left behind.

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

- It holds at most 100,000 undelivered events, and at most 128 MiB of
  them. Beyond that the **oldest are kept and new events are dropped**,
  counted and logged as an error (`dropping usage event (queue full); N
  dropped so far`, for the first and then every thousandth). Oldest,
  because a queue that shed from the front would turn one long outage into
  the silent loss of everything before it.
- The file follows what is undelivered, not how long the process has run:
  it is emptied when the queue drains, and rewritten to hold only the
  pending events once the delivered ones at its front outweigh them (and
  exceed 1 MiB). Until commit e4e30e4 it only shrank when the queue was
  empty.
- **A spool of any size never stops a start.** It is read in pieces; a
  damaged or overlong line is skipped; and if it holds more than the queue
  may, the front of it is loaded, the rest is discarded with an error in
  the log (`the usage spool holds more than can be queued ...: keeping the
  oldest N events ... and DISCARDING the rest`), and the gateway starts.
- After a crash the file can hold events that were already delivered; they
  are sent again and the ledger drops them by id.
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
| `usage=estimated` | The token counts on this line are an estimate: the response ended before the provider's closing figures arrived. When the upstream is read on in the background, the usage event written afterwards may carry the provider's real figures instead. See [Streams that end early](#streams-that-end-early). |
| `in=`, `out=` | Uncached input tokens and output tokens. Present when either is not zero. |
| `cached_in=` | Input tokens the provider read from or wrote to its prompt cache, when there were any. |
| `cache=hit` | The answer came from the gateway's response cache. |
| `Nms` | From the request head being read to the end of the response. |
| `id=` | The request id (`x-omnigate-request-id`, and the usage event's id in the ledger). |
| `aborted=` | Why the request ended without a normal response, if it did: `ClientTimeout`, `StreamIdleTimeout`, `ClientDisconnected`, `ClientStalled`, `UpstreamTruncated`, or the name of the I/O error. |

Text that came from a client (the path, the model name) cannot break out of
its line: in the text format a control byte is written as `\xNN` and a
space as `_`, so a line break in a model name cannot start a forged log
line. A request whose head was refused leaves no access-log line; it is
counted among the [refused requests](#refused-requests) and logged at
`debug` level.

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
`attempts`, `cached_input_tokens`, `cache` (`"hit"`), `estimated`
(`true`, the same fact as `usage=estimated` in the text form),
`request_id` and `aborted` are present only when they apply; `method`,
`path`, `status`, `input_tokens`, `output_tokens` and `latency_ms` always
are. A message longer than about 2,000 bytes is cut off, and a path longer
than 160 bytes is shortened.

The query string of a request is never logged, in either format: for a
signed file URL it is the credential.

(The values in these examples are made up; the field names and order are
the code's.)

The control plane has no access log and no JSON format: it logs through
Elixir's standard logger.

### Lines worth knowing

Control plane:

| Line | Meaning |
|---|---|
| `OMNIGATE_INTERNAL_TOKEN is not set (or is empty). ...` | The control plane refused to start. Set the same value for both processes. |
| `OMNIGATE_ADMIN_TOKEN is shorter than 16 characters. ...` | The control plane refused to start. Set a long random value, or leave it unset to have one generated. |
| `OMNIGATE_CONFIG is not set. Point it at your config file ...` | A release build of the control plane refused to start: only a development build falls back to the development config. |
| `OMNIGATE_CONTROL_PORT is not a whole number: ...`, `OMNIGATE_CONTROL_PORT must be between 1 and 65535, got ...`, `OMNIGATE_AUDIT_MAX_MB is not a number: ...`, `OMNIGATE_AUDIT_MAX_MB must not be negative, got ...`, `OMNIGATE_CONTROL_BIND is not an IP address: ...` | The control plane refused to start over a setting it could not read. Nothing is replaced by a default. |
| `loaded config <path>: N routes, N keys` | Startup. |
| `loaded N managed keys from <path>` | Startup, when the keys file has keys. |
| `cannot write <path>: ...` | A key change could not be saved and was not applied. |
| `audit log <path> could not be written: ...` | An admin action went ahead without its audit line. |
| `retention sweep removed N finished jobs, N stored files, N bucket objects, N ledger dedup ids, N ledger segments` | A sweep removed something. |
| `retention: could not delete bucket object <key>: ...` | The object stays in the bucket. |
| `reloaded config <path>` | An edit was applied. |
| `config reload failed, keeping previous: ...` | The edited file is invalid; the old config is still in force. |
| `OMNIGATE_ADMIN_TOKEN is not set. Generated one for this run ...` | The token follows on the same line. |
| `control plane listening on <address>: reachable from the network over plain HTTP ...` | `OMNIGATE_CONTROL_BIND` is not loopback. |
| `ledger ready in N ms from a snapshot plus N later events (<path>)` | Startup. Without a usable snapshot the line says `from N events`. |
| `ledger: sealed segment N (N bytes)` | The active segment was closed under its number and a new one started. |
| `ledger: ignoring ledger.snapshot (<reason>)` | A snapshot failed a check (checksum, contents, or the segment bytes it covers) and was not used. The spare, or a full replay, takes its place. |
| `ledger: using the previous snapshot; the newest one was unusable` | Startup went on from the spare. |
| `ledger: the id file for <day> (<path>) is missing; the snapshot recorded N ids in it. ...` | Warning, at startup. A `ledger.ids.<day>` file that the snapshot counted ids for is gone (deleted, or left out of a restore). The totals are unaffected, but a usage event of that day that a data plane delivers again would be counted a second time. Restore the file from the backup that holds the snapshot, if you have it. |
| `ledger: no usable snapshot, and segments before N were deleted by retention. ...` | Error. Totals were rebuilt from the remaining segments only; spend recorded before them is lost. Restore the data directory from a backup. |
| `ledger: snapshot failed: ...` | A snapshot could not be written. Usage is still recorded; the next start replays more. |
| `ledger: sealing segment N failed, will try again: ...` | Error (a full disk, a permission). The batch is recorded; the segment stays active and is sealed after a later batch. |
| `ledger: skipped N events after the snapshot that it had already counted` | Startup. Events after the snapshot whose ids the snapshot already knew were not counted a second time. |
| `ledger: dropped N of M usage events in a batch as invalid (missing or mistyped fields)` | A data plane sent events the ledger cannot record. Also in `omnigate_ledger_invalid_events_total`. |
| `ledger: usage for route <route> via <upstream>/<model> has no price in the config and is recorded at $0 ...` | Once per route and target. Also in `omnigate_ledger_unpriced_events_total`. |
| `media route <route>: target <upstream>/<model> has no price, so its jobs are recorded at $0 ...` | Once per target. |
| `job <id> could not be stored: ...` | Error. The client got `503 storage_unavailable`; check the disk of the data directory. |
| `job <id>: its cost is not in the ledger yet (...); it will be recorded later` | Error. The ledger was restarting when the job finished; the cost is recorded within about a minute. |
| `ledger: cutting N bytes of a torn last line from ledger.jsonl` | Startup after a crash in the middle of a write. The batch was never acknowledged and is sent again. |
| `job store compacted its log (N lines since the last time)` | Routine. |
| `OmnigateControl.Supervisor stopped (...); the HTTP listener stays up, starting the group again in N ms` | Error. One of the stores (ledger, job store, keys, audit log) crashed repeatedly and the group they run in gave up. The listener stays up; `/readyz` answers 503 until the group is back. Find the crash above this line. |
| `OmnigateControl.Supervisor is running again`, `OmnigateControl.Supervisor could not start (...); trying again in N ms` | The group came back, or failed to and will be tried again (the pause doubles up to 30 seconds). |
| `key "<name>" is defined in the config file and also exists as a managed key: ...` | The managed key is shadowed and its secret no longer works. See [Admin](admin.md#gateway-keys-two-sources). |
| `request <id> <METHOD> <path> failed: ...` | The control plane answered `500 internal_error`; `<id>` is the `request_id` the client got. |
| `job <id>: <upstream> failed (<outcome>), trying next target` | Media failover. |
| `job <id>: resuming provider job <provider id> on <upstream>` | A job continued after a restart. |
| `job <id>: storing outputs failed: ...` | Storage problem; the job fails with `storage_error`. |
| `webhook for <job id> gave up after N attempts` | Delivery failed for good. |

Data plane:

| Line | Meaning |
|---|---|
| `OMNIGATE_INTERNAL_TOKEN is not set` | The data plane exited at startup. An empty value counts as not set. |
| `bad OMNIGATE_LOG_LEVEL or OMNIGATE_LOG_FORMAT: ...`, `<VARIABLE> is not a valid number: "<value>" (expected a whole number from <min> to <max>)`, `OMNIGATE_LISTEN must be host:port, got ...`, `OMNIGATE_LISTEN has no valid port: ...` | The data plane exited at startup over a bad setting. Every numeric variable is read strictly (digits only) and named in the message. |
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
| `dropping usage event (queue full); N dropped so far` | Error. The control plane has been unreachable long enough to fill the queue; usage for these requests is lost. |
| `the usage spool holds more than can be queued (N bytes on disk): keeping the oldest N events (N bytes) and DISCARDING the rest` | Error, at startup. See [When the control plane is down](#when-the-control-plane-is-down). |
| `request <id>: read N more bytes from <upstream> after the client left; billing the provider's usage (in=N out=N)` | A stream whose client left was read to its end. `billing ESTIMATED usage` when the provider's figures did not come. |
| `unknown argument "<arg>" (the only subcommand is: healthcheck)` | The data plane was started with an argument it does not know, and exited with status 2. |
| `<upstream>/<model> rejects sampling parameters; retrying without them` | A learned model quirk. |
| `control plane request <path> failed: ...` | A jobs or files request got 503 `control_plane_unavailable`. The line has the path only, never the query string. |
| `error(panic): ...` | The data plane hit an internal error and exited with status 70. See [Connection limits and shutdown](#connection-limits-and-shutdown). |
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

## Hostile-input testing

`tools/malformed_test.py` is the counterpart of the load test for requests
that are wrong on purpose. It drives a gateway over raw sockets with:

- the requests that used to end the process (a header line without a
  colon, a `POST` with no length, JSON nested hundreds of levels deep, a
  chunked request body with a chunk size that overflows);
- request-smuggling and header-injection attempts (a second request hidden
  behind bare line feeds, two lengths, a length with chunked encoding, a
  body on a `GET`, an unread body after an early error);
- every non-canonical spelling of a path (`/v1/jobs/`, `//v1/jobs`,
  `/%76%31/jobs`, dot segments);
- a few hundred generated variations of broken request heads. They are
  seeded: `--seed` replays a run, `--count` sets how many.

After every case it asks `/healthz` on a fresh connection. Staying up is
the property under test; where a case has one right answer (400, 411, 417,
413) that is checked too, and no case may produce a 500. It exits 0 only if
the gateway survived everything and every expected status matched.

**By itself**, with a built data plane and `mix` available, it starts the
mock providers, the control plane and the gateway through the end-to-end
harness (on that harness's ports, with state in a temp directory) and stops
them at the end:

```bash
python tools/malformed_test.py
```

Run this way it also plays the other side and checks the limits:

- **an upstream that answers like an attacker**: chunk sizes that overflow,
  bodies shorter than their `content-length`, both framings at once, a
  header smuggled into the content type (special model names of
  `tools/mock_upstream.py` on port 9005);
- **an upstream that breaks connections** (inside the script, on port
  9006): it resets them while they idle, while a request is being written
  to them, or never reads the request; the next request must work, on a
  new connection;
- **a control plane that does the same**, a stand-in inside the script on
  port 4300, with a second gateway on port 8190 pointed at it;
- **names and flags a provider's parser could read differently**
  (`"Model"`, `"Stream": true`, `"stream": "true"`): refused;
- **the limits that apply before a request body is read**: the per-key
  concurrency cap, the rate limit, the size limit;
- **bodies that are cheap to send and used to be expensive to parse**;
- **the `healthcheck` subcommand**;
- that **a client which hangs up mid-stream, or stops reading without
  hanging up, is still billed**, with the provider's own figures when the
  provider goes on to report them and an estimate, marked as one,
  otherwise. It reads the result through `GET /admin/overview`.

`--thorough` runs 1,500 generated cases instead of 250 and takes several
minutes. It cannot run at the same time as the end-to-end or SDK suites,
which use the same ports; when a case fails it keeps the logs and says
where.

**Against a gateway you started yourself**, name it, with a valid key and a
text route that key may use:

```bash
python tools/malformed_test.py --gateway 127.0.0.1:8080 --key og-unlimited-key --model demo-direct
```

`--rpm-key` adds the check that the trailing-slash spelling cannot be used
to create jobs past a rate limit, and that the limit is applied before the
body is read. The second check sends as many requests as the key allows
per minute and expects the next one to be refused, so the tool has to know
that number: `--rpm`, 3 unless given. The dev config's `og-ratelimited-key`
allows 5: `--rpm-key og-ratelimited-key --rpm 5`. `--other-key`, `--concurrency-cap`, `--translated-model`,
`--late-model` and `--flood-model` switch on further checks against your
own instance; `--help` says what each needs. The hostile-upstream and
hostile-control-plane cases only run when the script started the stack
itself. The billing checks then run only if you
give it `--events-url` (a URL that lists the usage events received) and
the routes for `--drip-model` and `--stall-model`. Point it at a test
instance, never at production: it sends several megabytes of junk and
deliberately trips refusal counters. Standard library only.

CI runs it in its own job, in the first form
(`.github/workflows/ci.yml`), and `python tools/check.py` includes it. The
container test sends a smaller set of malformed requests through the TLS
proxy as well ([Deployment](deployment.md#testing-the-compose-file)).

## Troubleshooting

By the reason in the gateway's answer, which is always `error.code`,
whichever of the two processes raised the error (see
[API](api.md#errors); until commit 10bc009 the control plane put it in
`error.type`). An answer that has an `x-omnigate-upstream` header
came from a provider, not from the gateway; see the last rows. A gateway
error carries `x-omnigate-request-id`, which is the `id=` of the request's
line in the data plane's access log.

| Reason | Likely cause | What to do |
|---|---|---|
| `gateway_not_ready` (503) | The data plane has never received a config. | Check `OMNIGATE_CONTROL_URL`, that the control plane is up (it does not start without `OMNIGATE_INTERNAL_TOKEN`, or with an invalid config file), and that both processes have the same `OMNIGATE_INTERNAL_TOKEN` (data plane log: `config fetch returned 401`). |
| `missing_api_key` (401) | No `Authorization: Bearer` or `x-api-key` header. | Send the gateway key. For a file URL: the `sig` parameter was stripped. With an SDK: it may have picked up no key, or the wrong one, from the environment. |
| `invalid_api_key` (401) | The key's SHA-256 is not known: never configured, deleted, disabled, or replaced by a rotation. | For a file key, check `key_sha256` is the lowercase hex hash of exactly the key string. `echo key \| sha256sum` hashes a trailing newline; use the Python command in [Configuration](configuration.md#gateway-keys). For a managed key, look at its state in the dashboard or `GET /admin/keys`. A new or changed key takes a few seconds to reach the data plane. |
| `budget_exceeded` (402) | Recorded spend in the key's budget period reached `budget_usd`. | Raise or remove the budget, or wait for the period to turn if it is monthly or daily; a `total` budget never resets by itself. See [Budgets](#budgets). The key can still read its jobs and files. |
| `overloaded` (503) with no request id | The data plane is at `OMNIGATE_MAX_CONNECTIONS`. | Retry after a second. If it persists: look for clients that open connections without reusing or closing them, lower `OMNIGATE_CLIENT_TIMEOUT_MS` so idle ones are dropped sooner, or raise the cap. |
| `overloaded` (503) with a request id | The request bodies in flight, or the requests being converted, have used up `OMNIGATE_REQUEST_MEMORY_MB` or `OMNIGATE_PARSE_MEMORY_MB`. | Retry after a second (the SDKs do). If it persists under honest load, raise the budget, and the container's memory limit with it. |
| `concurrency_limit_exceeded` (429) | The key has its `max_concurrent` (or, without one, `OMNIGATE_MAX_CONCURRENT_PER_KEY`) requests in flight. Streams whose client hung up count until the provider's answer has been read to its end. | Retry after a second. Raise the cap if one key legitimately runs that many requests at once. |
| `request_memory_exceeded` (429) | The key's requests in flight are too large together (a quarter of `OMNIGATE_REQUEST_MEMORY_MB`), or it is having as many large requests converted at once as it may (half of `OMNIGATE_PARSE_MEMORY_MB`). | Retry after a second; send fewer large requests at once, or raise the budget. |
| `request_too_complex` (400) | The request must be translated for a provider of the other protocol (or its `stream_options` rewritten) and has an object with more than 1,024 members, or far more values than its size suggests. | Use a route with an upstream of the client's own protocol, which forwards the body without parsing it, or split the object. |
| `model_not_allowed` (403) | The key has a `models` list without this route. | Add the route name to the list. |
| `model_not_found` (404) | No route with this name. Text endpoints only know `routes[]`; the jobs API only knows `media.routes[]`. | Check the name, and that you are calling the right API for it. |
| `not_found` (404) | The path or method is not one the gateway serves. | See the endpoint list in [API](api.md#text-endpoints). |
| `invalid_json`, `missing_model` (400) | The body is not a JSON object, is nested deeper than 64 levels, or has no `"model"` string. | Fix the request. |
| `invalid_request` (400): `a JSON object in the request body has too many members`, `a key in the request body is too long`, `"model", "stream" and "stream_options" may each appear only once`, `... must be spelled without escapes` | The body has an object with more than 65,536 members, a key over 8 KiB, or one of the three fields the gateway acts on twice or written with escapes. | Fix the request. |
| `invalid_request` (400): `the request path is not in canonical form` | The path has a trailing slash, an empty, `.` or `..` segment, a percent-encoded character, or another character outside letters, digits and `-._~:@`. | Send the path plain: `/v1/jobs`, not `/v1/jobs/`. Look for a base URL that ends in a slash, or a client that encodes path segments. |
| `invalid_request` (400): `the query string contains unsupported characters` | A `%`, `/`, space or other character outside the allowed set in the query string. | Remove the parameter; the gateway uses none beyond `limit`, `exp` and `sig`. |
| `invalid_request` (400): `invalid idempotency-key header ...`, `invalid anthropic-version header`, `invalid anthropic-beta header` | The header's value has characters the gateway will not forward. | For the two `anthropic-` headers use letters, digits and `-._` (plus commas and spaces in `anthropic-beta`). An idempotency key, which is only checked on job requests, may be any 1 to 255 visible ASCII characters without spaces. |
| `invalid_request` (400, 411 or 417) with no request id, or a bare 400 or 431 | The request head itself was refused: malformed, ambiguous about its body, without a `Content-Length` on a `POST` (a chunked request body included), with an `Expect` other than `100-continue`, or larger than 16 KiB. | Fix the client. A 411 can also come from a proxy in front that hands a request body on with chunked encoding (because the client sent it that way, or because the proxy re-chunks): the gateway needs a `Content-Length`. The included Caddy configuration does not buffer request bodies, so a client that sends a chunked body through it is expected to get the 411 as well; that has not been tested. See [API](api.md#request-heads-paths-and-queries). |
| `payload_too_large` (413) | Body over 8 MiB. | Send less; the limit is not configurable. |
| `rate_limit_exceeded` (429) | Over the key's `rpm`. For `POST /v1/jobs` the control plane counts as well, and can be the one that answers. On `GET /v1/jobs`: the key is listing too often (its `rpm`, or 600 per minute). Remember that requests refused for their body or model count against the limit too. | Wait `Retry-After` seconds, or raise `rpm`. |
| `too_many_open_jobs` (429) | The key already has `max_open_jobs` jobs queued or running. | Wait for jobs to finish (the answer suggests 10 seconds in `Retry-After`), cancel some, or raise the key's `max_open_jobs` (or `media.max_open_jobs`). |
| `too_many_jobs_today` (429) | The key already created `max_jobs_per_day` jobs this UTC day, failed and canceled ones included. | Wait for midnight UTC (`Retry-After` counts down to it, an hour at a time at most), or raise the key's `max_jobs_per_day` (or `media.max_jobs_per_day`). |
| `storage_unavailable` (503) on `POST /v1/jobs` | The control plane could not write the job to its job store. | Check the disk and permissions of the control plane's data directory; its log has `job <id> could not be stored`. |
| `payload_too_large` (413) on `POST /v1/jobs`, from the control plane | `input` and `metadata` together exceed `media.max_input_bytes`. | Send less, pass large inputs by URL, or raise the setting. |
| `invalid_request` (400) on `POST /v1/jobs`: `"input.duration" must be a number of seconds, 0 or more` (or the same for `seconds`, `n`, `num_outputs`, `num_images`) | A field that feeds the price is negative or not a number. | Fix the request. |
| `invalid_request` (400) on `POST /v1/jobs`: `this model is priced per second: send "input.duration" ...` | The route has a `per_second_usd` price, the job names no duration, and the target has no `default_seconds`. Jobs like this were accepted (and billed nothing per second) before commit d79406b. | Send `input.duration`, or set `default_seconds` on the route's targets. |
| `invalid_request` (400) on `POST /v1/jobs`: `"input.duration" must be at most N seconds for this model`, `this model does not accept the input field(s) ...`, `"input.<field>" must be one of: ...` | The route's `max_seconds`, `allowed_input` or `price_multipliers` refuse the job. | Fix the request, or change the route in the config. |
| `all_upstreams_failed` (502) | Every target failed, and none of them answered 429. | Read `error.attempts`: `http_429` / `http_5xx` are provider answers; `UpstreamTimeout` means no headers within the timeout; `ConnectionRefused` and similar are network errors; `unknown_upstream` means a target names an upstream that is not in `upstreams[]`; `protocol_mismatch` means that target speaks the other protocol and the endpoint is not translated; `untranslatable_request` means the request has audio or file parts and that target speaks the other protocol. |
| `upstream_rate_limited` (429) | No target succeeded, and at least one answered 429. | Wait for the `retry-after` the response carries (the longest any rate-limited provider asked for), or add a target at another provider to the route. This is your provider key's limit, not the gateway key's `rpm`. |
| `endpoint_not_supported` (400) | An untranslated endpoint (embeddings, responses, completions, count_tokens) was called on a route whose upstreams all speak the other protocol. | Call a route that has an upstream of the endpoint's own protocol, or add one to this route. |
| `untranslatable_request` (400) | The request has audio or file parts, and every target of the route would need it translated. | Use a route with an upstream of the client's own protocol. |
| `control_plane_unavailable` (503) | A jobs or files request could not reach the control plane within 30 seconds. | Check the control plane; text endpoints are unaffected. |
| `webhook_not_configured` (400) | A job asked for a webhook but no signing secret exists for the key. | Set one; see [Configuration](configuration.md#mediawebhooks). |
| `invalid_webhook_url` (400) | Not http(s), no host, embedded credentials, does not resolve, or resolves to a private address. | Use a public URL. For local development set `media.webhooks.allow_private` to `true`. |
| `idempotency_conflict` (409) | The `Idempotency-Key` was used before with a different body. | Use a new key for a new request. |
| `job_not_found`, `file_not_found` (404) | Wrong id, a job of another key, a job removed by retention, or a job of a key that was deleted and created again under the same name. | |
| `unauthorized` (401, control plane) | No valid admin token or session on `/admin/*` or `/metrics`. | Send `Authorization: Bearer <admin token>`. A gateway key or the internal token is not accepted here. |
| `too_many_attempts` (429, control plane) | 20 wrong bearer tokens from this address within a minute. Until the minute is over the right token is refused too. | Find what is sending the wrong token (an old token in a script or a scrape job), then wait a minute. Behind a proxy without `OMNIGATE_TRUST_FORWARDED`, everyone shares the proxy's address. See [Admin](admin.md#two-ways-in). |
| `csrf_failed` (403, control plane) | A change sent with a session cookie but without the session's CSRF token. | From a script, use the bearer token instead. In the dashboard, reload the page. See [Admin](admin.md#csrf-scripts-and-browsers). |
| `read_only_key` (409, control plane) | The key is defined in the config file. | Edit the file. |
| `key_exists` (409), `key_not_found` (404), `invalid_request` (400, control plane) | See [Admin](admin.md#errors). | |
| `invalid_request` (400): `the request path must not contain encoded characters` | The path sent to the control plane (directly, or through the gateway for `/v1/jobs*` and `/v1/files/*`) contains a `%`. | Send the path plain. Key names, job ids and file names never need encoding. |
| `internal_error` (500, control plane) | The control plane failed while handling the request. | Find the `request_id` from the error in the control plane's log (`request <id> ... failed:`). |
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
| `too_many_outputs: ...` | The provider's answer listed more files than `media.max_outputs_per_job` (16). Nothing was downloaded. Raise the setting if the model really produces that many. |
| `completed_after_cancel` | Not a failure: the job was canceled, the provider completed the call all the same, and the job was billed for it ([API](api.md#cancel-a-job)). |
| `output_fetch_failed: ...` | The output could not be downloaded: an HTTP error, more than `max_output_bytes` (or, with `the outputs together exceed media.max_job_output_bytes`, more than that in all), or a stalled download. `output_fetch_failed: blocked: output url resolves to a private or loopback address` means the URL the provider returned, or one it redirected to, does not point at a public address; the control plane refuses to fetch it unless `media.webhooks.allow_private` is set. `too many redirects` means more than five. |
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
| Dashboard login answers 429 | Five failed logins from one address within a minute. Behind a reverse proxy all clients share the proxy's address unless `OMNIGATE_TRUST_FORWARDED=1` is set (as `compose.yaml` does). Wait a minute. |
| The dashboard host answers 403 to everything | The request comes from outside `OMNIGATE_ADMIN_ALLOW`. Remember that the proxy judges the address it sees, which behind another proxy is that proxy's. |
| The data-plane container restarts with exit code 70 | A panic. The line `error(panic): ...` in its log says where. Report it. |
| A file URL downloads instead of displaying in the browser | Intended: stored outputs are served as attachments. Fetch the file and use it from your own origin. |
| A call the client cancelled shows up with tokens and cost | Intended: an abandoned stream is billed, exactly when the provider's figures arrive in time and by estimate otherwise. See [Streams that end early](#streams-that-end-early). |
| Signed out of the dashboard after changing the admin token | Expected: sessions are signed with a key derived from the token. |
| Output URLs point at `127.0.0.1:8080` | `media.public_base_url` is still the default. |
| A webhook never arrives | Look at `webhook.last_status` and `webhook.last_error` in the job. The receiver must answer 2xx; a redirect counts as a failure. |
| Streamed tokens arrive in one burst through your proxy | The proxy is buffering. In Caddy: `flush_interval -1`. |
| Spend shows $0 | The route's targets have no prices. Or the answers came from the response cache, which costs nothing. |
| The control plane exits at once, or its container keeps restarting | `OMNIGATE_INTERNAL_TOKEN` is unset or empty, `OMNIGATE_ADMIN_TOKEN` is set but shorter than 16 characters, a release build has no `OMNIGATE_CONFIG`, `OMNIGATE_CONTROL_PORT`, `OMNIGATE_AUDIT_MAX_MB` or `OMNIGATE_CONTROL_BIND` has a value it cannot read (the log names each of these), the config file is invalid (a negative media price, a bad `max_open_jobs` or a whole-number setting that is a fraction or out of range included), or the keys file exists but cannot be read. |
| The data plane exits at once | A setting it cannot read: the log names the variable. Numeric settings take digits only (`2000`, not `2s`, `2_000` or `+2000`). |
| `docker compose up` fails with a missing `env_file` | `.env.control` or `.env.dataplane` does not exist. Copy the `.example` files; see [Deployment](deployment.md#compose-with-tls). |
| The control container is `unhealthy` | `GET /readyz` is failing. Call it (`docker compose exec control wget -q -O - http://127.0.0.1:4000/readyz`) and read `reason`; a refused connection means the control plane is still loading its ledger or is not running. |
| A managed key stopped working after a config edit | The config file now defines a key with the same name, which shadows the managed one. `GET /admin/keys` shows it with `"state": "shadowed"`. |
| An application reports a rate limit although its key has no `rpm` | `429 upstream_rate_limited`: the provider's limit on your provider key, passed on. |
| A connection the client kept open was closed by the gateway | It was idle for `OMNIGATE_CLIENT_TIMEOUT_MS` (30 seconds by default). Most HTTP clients retry on a fresh connection by themselves. |
| A long streamed answer was cut off | The upstream sent nothing for `OMNIGATE_STREAM_IDLE_TIMEOUT_MS`, or the client read nothing for `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` (30 seconds by default; a client that pauses reading for longer than that, to do slow work per chunk, needs it raised). The ledger has the request with status 499, with estimated token counts if the provider's own did not arrive. |
| A response or a file download ends with a broken connection instead of an error | The provider (or, for a file, the control plane) cut its answer short after the gateway had started sending. A chunked response without its closing chunk is how that is signalled. | Retry. The access log has `aborted=UpstreamTruncated` (or the I/O error). |
| A file download shows no size or progress | Between commit e4e30e4 and the close-out commit, files over 64 KiB were sent chunked, without a `content-length`. | Update the data plane: downloads carry their length again. The size is also in the job (`outputs[].bytes`). |
| The data-plane container is killed and restarted under load (`OOMKilled`) | Its memory limit (`OMNIGATE_DATAPLANE_MEMORY`, 1 GiB) is below what its budgets admit. With the current `compose.yaml` they are 256 + 256 + 64 MiB; a Compose file from before the close-out commit, or budgets you raised in `.env`, admit more. | Raise the limit or lower `OMNIGATE_REQUEST_MEMORY_MB` and `OMNIGATE_PARSE_MEMORY_MB` (in `.env` under Compose); see [Deployment](deployment.md#memory-limits). |
| The control-plane container is killed and restarted (`OOMKilled`) | Its memory limit (`OMNIGATE_CONTROL_MEMORY`, 1 GiB) is too small for the duplicate-detection ids of your traffic, or for a media output a provider returned inline. | Look at `omnigate_ledger_dedup_ids` (61 MiB per million); raise the limit, or shorten `retention.ledger_ids_days` if your data planes are never cut off that long. |
| The data-plane container is `unhealthy` | `omnigate-dp healthcheck` gets no `200` from `/healthz` on `OMNIGATE_LISTEN` within three seconds. | The process is not listening or is not answering; read its log. |
| The control plane does not start after an upgrade, naming a setting | Whole-number settings are read strictly since commit d79406b: `"rpm": 600.0`, a negative budget, a `timeout_s` of 0 or a `media.max_input_bytes` over 8,000,000 used to load. | Fix the value the message names; see [Upgrading](upgrading.md). |
| A changed answer keeps coming back unchanged | The route has `cache_ttl_s` and the response carries `x-omnigate-cache: hit`. |
| A new key works on one data plane and not yet on another | Each data plane polls the config by itself; wait one poll interval. |
| A blocked monthly key is still blocked after midnight UTC on the first | The data plane learns of the change with its next poll; if the control plane is unreachable it cannot learn of it at all. |
