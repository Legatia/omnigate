# Architecture

omnigate is two processes with a narrow interface between them.

```
 apps ──▶ dataplane (Zig) ──────────▶ LLM providers (OpenAI-style, Anthropic-style)
            ▲   │  │
     config │   │  └─ /v1/jobs, /v1/files ─┐
            │   ▼ usage events             ▼
          control (Elixir) ── ledger · budgets · jobs · webhooks ──▶ media providers
                                                     └──▶ your bucket (S3 API) or local disk
```

- [The two planes](#the-two-planes)
- [The interface between them](#the-interface-between-them)
- [A text request](#a-text-request)
- [Usage: spool and ledger](#usage-spool-and-ledger)
- [A media job](#a-media-job)
- [State on disk](#state-on-disk)
- [Why it is built this way](#why-it-is-built-this-way)

## The two planes

| | Data plane (`dataplane/`, Zig 0.17) | Control plane (`control/`, Elixir 1.20 / OTP 29) |
|---|---|---|
| Audience | Applications. The public port. | Operators and data planes. A private port. |
| Owns | Validating request heads, paths and bodies before anything else reads them; authenticating gateway keys, rate limits, routing, load balancing, failover, cooldowns, protocol translation, streaming, counting tokens, the response cache, client and stream timeouts, the connection cap, the access log | The config file, managed keys, prices, the usage ledger, budgets and their periods, media jobs (and their own rate and open-job limits), output storage, webhooks, dashboard, admin API, audit log, metrics, retention |
| Credentials it holds | The internal token and text provider keys (from its environment). Nothing else: in the Compose deployment its container is given no admin token, media key, webhook secret or bucket credential | The internal token, the admin token, media provider keys, bucket credentials, webhook secrets |
| State | In memory, plus two files: the usage spool and a cache of the last config | Files: the ledger (segments and snapshots), the job log, the keys file, the audit log, stored outputs |
| Dependencies | The Zig standard library | Two direct Hex packages (Bandit, Plug); outbound HTTP uses OTP's `httpc` |
| If it stops | Applications get no answers | Text traffic continues; jobs answer 503; usage waits in the spool |

Text requests never pass through the control plane. Job and file requests
do: the data plane authenticates the key and forwards them.

## The interface between them

All of it is HTTP from the data plane to the control plane, under
`/internal/*`, authenticated with the shared internal token in the
`x-omnigate-internal` header.

| Call | Direction | Purpose |
|---|---|---|
| `GET /internal/config` | pull, every `OMNIGATE_POLL_MS` | The config snapshot. |
| `POST /internal/usage/batch` | push, every `OMNIGATE_FLUSH_MS` when there is something to send | Usage events. At-least-once, spooled to disk. |
| `POST /internal/counters` | push, every `OMNIGATE_FLUSH_MS` when there is something to send | Counts of requests the data plane refused before routing, by key name and reason. Best effort, memory only. |
| `/internal/v1/jobs*`, `/internal/v1/files/*` | per client request | The jobs API, forwarded. The data plane names the authenticated key in `x-omnigate-key-sha256`. |

**What a client can make the data plane say to the control plane** is
narrow on purpose, because that call carries the internal token. The
address comes from the data plane's own configuration. Of the client's
request, a path and a query string go into it, both validated character by
character (one canonical spelling, no percent-encoding, a small character
set) and set as separate components of the URL instead of being spliced
into a string that is parsed again; and one header, `Idempotency-Key`,
restricted to letters, digits and `-._:`. The data plane also sends its
own id for the request (`x-omnigate-request-id`), which the control plane
uses in its log and echoes, so one id follows a request through both
processes. Of the control plane's answer, the data plane relays the status,
the content type, the length, the body and six headers by name: the four
that say how a stored file is to be treated (`content-disposition`,
`x-content-type-options`, `content-security-policy`, `cache-control`),
`location` (where a bucket-stored file lives) and `retry-after`. Nothing
else, cookies and server headers included.

**The snapshot** is the data plane's whole view of the configuration:

- keys as SHA-256 hashes with `name`, `rpm`, `models` and a `blocked` flag.
  File keys and managed keys are merged into one list before this point, so
  the data plane cannot tell them apart; a disabled key is left out;
- text upstreams, with the *name* of the environment variable holding each
  provider key;
- text routes with `strategy`, `cache_ttl_s` and each target's `upstream`,
  `model`, `weight`;
- `media_models`, the names of the media routes, used only to list them in
  `GET /v1/models`;
- a `version`, a hash of all of the above. It changes whenever anything the
  data plane sees changes, including a key flipping to blocked.

There are no budgets, prices or secrets in it, and nothing about media
beyond those names. The data plane installs a snapshot only when its
version differs from the one in force, and writes it to the config cache
file so that it can start from it when the control plane is down.

Budgets reach the data plane only as the `blocked` flag: the control plane
compares each key's recorded spend in its current budget period with its
budget every time it builds the snapshot, which is on every poll. That is
also how a monthly or daily key unblocks: the first snapshot built after
the period turns no longer has the flag. Creating, changing, rotating or
deleting a managed key travels the same way, as a changed key list in the
next snapshot.

## A text request

1. **Accept.** A connection beyond `OMNIGATE_MAX_CONNECTIONS` is answered
   503 at once. Otherwise the connection gets a task and a deadline: a
   watchdog task cancels it if the client does not deliver a request within
   `OMNIGATE_CLIENT_TIMEOUT_MS`.
2. **Validate the head.** Before anything else reads it, the raw request
   head is checked by plain scanning (`guard.zig`): every header line has a
   name and a colon, there are no bare line feeds or control bytes, the
   target is a plain path, and the body's framing is unambiguous (one
   length, or chunked, never both; no body on a method that has none; a
   length on a method that has one). A head that fails is answered 400, 411
   or 417 and the connection is closed. The path must then be in its one
   canonical form and the query string plain, or the answer is 400.
3. **Authenticate.** The key from `Authorization: Bearer` or `x-api-key` is
   hashed and looked up in the snapshot. Unknown: 401. Blocked: 402 for
   anything that starts new work (reading the model list, jobs and files
   stays allowed).
4. **Parse.** The body (at most 8 MiB, nested at most 64 levels deep) must
   be a JSON object with a `model` string, which names a route.
5. **Model limits, then rate limit.** A key restricted to a list of models
   gets 403 for anything else. Then the per-key token bucket is charged.
6. **Response cache.** If the route has `cache_ttl_s` and the request is
   not a stream, the request is hashed together with the route name, the
   path and the key's hash, and looked up in an in-memory cache. A hit is
   answered from memory and reported as a usage event with no tokens,
   marked `cached`; nothing below happens.
7. **Order the targets.** The route's strategy picks who goes first
   (`failover`: config order; `round_robin`: rotating; `weighted`: random by
   weight). Targets whose upstream is cooling down go last.
8. **Forward.** For each target in order: rewrite `model` to the target's
   model id; if the upstream speaks the other protocol, translate the
   request; send it with the provider key from the environment; wait for the
   response headers up to the timeout.
   - Connection error: one retry on a fresh connection, then next target.
   - Timeout, 429 or 5xx: next target, and a failure is noted for cooldowns.
   - Anything else: this is the answer.
9. **Stream.** The response body is copied to the client chunk by chunk and
   flushed each time. On the way through, a small JSON reader picks the
   token counts out of the bytes without buffering the body (see
   [below](#reading-usage-from-the-stream)). If the upstream speaks the
   other protocol the stream is translated event by event. From the first
   byte on there is no more failover. The response head carries the
   gateway's own headers and the provider headers on a fixed allowlist
   (retry hints, rate-limit counters, request ids). Each chunk pushes the
   connection's deadline forward; if nothing moves for
   `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` the watchdog cancels the task, and the
   call is reported with status 499. If the client goes away mid-response,
   the data plane keeps reading the upstream for up to
   `OMNIGATE_ABORT_DRAIN_MS` to learn the provider's closing usage, then
   reports the call with status 499 as well.
10. **Report.** One usage event is queued. The request does not wait for it
   to be delivered. A complete, successful, non-streaming answer on a route
   with `cache_ttl_s` is also put in the response cache.
11. **Log.** One access-log line is written for the request.

If every target fails, the client gets the list of attempts in a 429
`upstream_rate_limited` when any of them answered 429 (with the longest
`retry-after` those sent), and in a 502 `all_upstreams_failed` otherwise. A
usage event with that status and no tokens is recorded.

**Errors and ids.** Every answer the data plane produces, except
`GET /healthz` and the immediate `503 overloaded`, carries the request id
as `x-omnigate-request-id`, and as `x-request-id` and `request-id` (the
provider's own values when it sent them). The gateway's own errors are written in the shape of the client's
protocol, with the provider's category in `error.type` and the gateway's
reason in `error.code`; the table is in [API](api.md#errors). The control
plane writes its errors in the same OpenAI-style envelope, from a copy of
the same category table (`errors.ex`), so a client of the jobs API cannot
tell which process refused it.

A request that is refused in steps 1 to 5, one whose route does not exist,
and one that no target of the route can be sent at all
(`endpoint_not_supported`, `untranslatable_request`) produce no usage event.
They are counted per key name and reason instead, and the counts are sent
to the control plane on the same interval as usage.

**Stopping.** On SIGTERM or SIGINT the accept loop ends, idle connections
are cancelled, requests in flight get `OMNIGATE_SHUTDOWN_GRACE_MS` to
finish, and queued usage is delivered once more before the process exits.

Two provider quirks are handled for translated requests only, because a
client speaking the other protocol cannot know them: models that reject
sampling parameters, and models that demand a thought signature on earlier
tool calls. The first refusal is retried with the fix, and the fix is
remembered in memory per gateway key, upstream and model. Per key, because
the evidence is a provider's error text, and a client can make a provider
echo text of its choosing: in a shared table one key could switch sampling
parameters off for everyone using that model. Scoped to the key that
provoked it, the worst a client can do is change its own requests. The
table holds at most 20,000 entries; beyond that nothing more is remembered
and each such request pays for its own retry.

### Reading usage from the stream

The token counts that become the bill are read by a byte-at-a-time JSON
tokenizer (`usage.zig`) that tracks where it is in the document. A number
counts only at the places the protocols put usage: `usage.<field>`,
`usage.<details>.cached_tokens`, Anthropic's `message.usage.<field>`, and
the Responses API's `response.usage.<field>`. Strings are skipped as
strings. An earlier version searched the raw bytes for `"prompt_tokens":`
and the like, so text that a client could get echoed into a response (a
tool schema, a tool call's arguments) could change that client's own bill.

- Values are max-merged, so Anthropic's cumulative `output_tokens` and
  OpenAI's single final `usage` object both come out right, and the reader
  does not care where network reads split the data.
- No count above 2^40 is believed, and sums saturate, so no number a
  provider sends can overflow anything.
- The reader also notes whether the provider's **closing** figures were
  seen (a top-level `usage` with an output count, or `response.usage`),
  and counts bytes and server-sent events. When a response ends early
  without the closing figures, the usage event carries an estimate instead
  and is marked `estimated`: never less than what was metered, missing
  input taken as the request's bytes divided by 4, missing output as one
  token per event (or the response's bytes divided by 4). See
  [Operations](operations.md#streams-that-end-early).

### When input is hostile

A panic anywhere in the data plane ends every connection it is serving, so
the rule is that no input may reach code that asserts on its shape.

- Request heads and JSON nesting are checked by code that cannot fail in
  any way other than returning "no" (`guard.zig`), before the standard
  library's parser, header iterator or JSON serialiser see them. The
  client's JSON may nest 64 levels, an upstream's 128; the serialiser's own
  limit is 256.
- Text from a client or a provider that goes into a log line has its
  control bytes escaped.
- After answering a request whose body it did not read, the data plane
  closes the connection instead of reusing it (the unread body would be
  parsed as the next request), and reads and discards what the client is
  still sending for up to two seconds first, so the client sees the answer
  and not a reset.
- If a panic happens anyway, an optimized build logs one line and exits
  with status 70, which a supervisor can tell from a clean stop (0) and a
  startup error (1). Usage events are appended to the spool as they are
  queued, so they survive the restart.

`tools/malformed_test.py` and the fuzz tests in `translate.zig` and
`usage.zig` exercise this; none of it has faced real hostile traffic.

## Usage: spool and ledger

**On the data plane**, each usage event is appended to an in-memory queue
and to the spool file. A background task sends the oldest events in batches
of up to 500, and removes them only after the control plane has acknowledged
the batch. Failures back off up to 10 seconds. The spool file is truncated
when the queue drains completely, and reloaded at startup, so events survive
both a control-plane outage and a data-plane restart. After a crash the
spool can hold events that were already delivered; they are sent again.

**On the control plane**, a batch is appended to the ledger's active
segment (`ledger.jsonl`) and synced to disk before it is acknowledged, then
folded into per-key totals in memory. Every event carries the request id as its
`id`, and an event whose id was already recorded is skipped. That is what
makes at-least-once delivery bill exactly once.

A text usage event as the data plane sends it:

| Field | Meaning |
|---|---|
| `id` | The request id (also `x-omnigate-request-id`). |
| `key_sha256` | Which gateway key. |
| `route_model` | The model name the client used. |
| `upstream`, `target_model` | Which target answered; null when all failed. |
| `status` | HTTP status sent to the client; 499 for a stream that broke mid-way; 502 when all targets failed, or 429 when any of them was rate limited. |
| `stream` | Whether the request was streamed. |
| `input_tokens` | Input tokens that were not served from the provider's prompt cache. |
| `cached_input_tokens` | Input tokens read from the provider's prompt cache. |
| `cache_write_input_tokens` | Input tokens written to the provider's prompt cache. |
| `output_tokens` | Output tokens. |
| `cached` | `true` when the answer came from the gateway's own response cache; such an event has no upstream and no tokens. |
| `estimated` | `true` when the token counts are an estimate, because the response ended before the provider's closing usage arrived. Kept in the ledger line; it does not change how the event is priced. |
| `latency_ms` | From the start of the failover loop to the end of the response. |
| `attempts` | Each upstream tried and its outcome. |
| `ts_ms` | When the request finished on the data plane. |

The token counts are read from the response in the provider's own terms and
then normalised by the protocol of the upstream that answered: an
OpenAI-style input count includes cached tokens, so they are subtracted; an
Anthropic-style one does not, so its cache reads and writes are taken as
reported. Whatever the provider, `input_tokens` in the ledger means
"uncached input".

The control plane adds `cost_usd` (the four counts times the target's four
prices at the time of recording; zero for a `cached` event), `ts` (from
`ts_ms`) and `received_at`. Media jobs are written to the same ledger by
the control plane itself, with `"kind": "media"`, the job id as `id`, and
the job's own `cost_usd`.

Besides the per-key totals, the ledger keeps each key's spend per UTC month
and per UTC day, keyed by the event's own time. That is what a monthly or
daily budget is compared with. Rows of periods long past are dropped from
memory (the segments keep the events for as long as they are kept), and
totals for the current UTC day feed the dashboard's "today" figures.

Totals are kept per key **hash**. A managed key that has been rotated has
several hashes; the control plane adds them up wherever it shows a key.

Known limits, from the README: spool appends are not fsynced, so a power
loss can drop the last few events; the spool holds at most 100,000
undelivered events; the ledger lives on a single control-plane node.

### Ledger files: segments and snapshots

The ledger is not one file that is replayed from the beginning at every
start. It is a set of files next to each other, named after
`OMNIGATE_LEDGER` (`ledger.jsonl` by default):

| File | What it is |
|---|---|
| `ledger.jsonl` | The **active segment**: one JSON event per line, appended and synced before a batch is acknowledged. |
| `ledger.000001.jsonl`, `ledger.000002.jsonl`, ... | **Sealed segments**: older events, in order. The active segment's number is one more than the highest sealed number. |
| `ledger.snapshot` | Everything a replay of the covered events would have produced: the totals per key, per UTC day and per budget period, the duplicate-detection ids, and the short list of recent requests. It records the position it covers, a segment number and a byte offset. |
| `ledger.snapshot.prev` | The snapshot before that one, kept as a spare. |
| `ledger.snapshot.tmp` | A snapshot being written. Never read. |

- **Sealing.** The active segment is renamed to its numbered name, and a
  new empty one started, when it reaches 64 MiB, and at the first
  five-minute check after the UTC day it was written in has ended.
- **Snapshots** are written every 50,000 events, every five minutes when
  anything was recorded since the last one, after a segment is sealed, after
  a start that had to replay events, and at a clean stop. A snapshot is a
  magic line, a SHA-256 of the payload, and the payload (Erlang's external
  term format). It is written to the `.tmp` name and synced; then the
  current snapshot is renamed to `.prev` and the new one into place.
- **Start.** The control plane loads the newest snapshot that passes every
  check (the magic line and the checksum match, the contents decode, and the
  ledger bytes it covers are still there and are the same bytes) and replays
  only the events written after it. If the newest one fails a check the
  spare is used; if both fail, every segment is replayed. The commit that
  introduced this records 1,000,000 events loading in 0.75 s instead of
  10.7 s.
- **Nothing to migrate.** An installation that only ever had `ledger.jsonl`
  is simply at segment 1, still active. Its first start with this code
  replays the file once and writes the first snapshot.
- **Deleting old segments.** `retention.ledger_days` deletes sealed
  segments whose last write is older than the cutoff. A segment is deleted
  only when both snapshot generations cover it, and the newest sealed
  segment is never deleted (the numbering is read from the file names).
  After a restart only the snapshot the process started from is vouched
  for, so the sweep first writes a new one, which makes the validated one
  the spare, and then deletes. Lifetime and period totals are
  unaffected, because the snapshots carry what the deleted segments
  contributed.
- **The consequence.** Once segments have been deleted, the two snapshots
  hold the only copy of those totals. If both were lost or damaged, the next
  start would rebuild the totals from the segments that remain and log an
  error saying that spend recorded before them is lost. Without
  `ledger_days` the segments are complete, and losing the snapshots costs
  start-up time only.
- **`retention.ledger_ids_days`** trims the set of duplicate-detection ids
  (which is also part of every snapshot). It touches neither totals nor
  segments.

Each step is safe to crash in. A torn last line of the active segment is
cut off at the next start (its batch was never acknowledged, so the data
plane sends it again). A crash while a snapshot is being installed leaves
either the old one or the spare usable. A crash between the two halves of
sealing leaves no active file, which a start treats as an empty one. The
unit tests in `control/test/ledger_snapshot_test.exs` exercise these states;
none of this has run in production.

## A media job

```
queued ──▶ running ──▶ succeeded
              │──────▶ failed
              └──────▶ canceled
```

1. **Create.** The control plane checks the key's budget (for its current
   period), its model list and its requests-per-minute limit (counted here
   as well as in the data plane, in fixed one-minute windows), finds the
   media route, validates `input` and `metadata` (objects, together no
   larger than `media.max_input_bytes`, with no negative duration or
   count), the webhook URL and the idempotency key, and writes the job to
   the job log. With an idempotency key already used by this gateway key,
   the existing job is returned instead. Otherwise the job store refuses
   the job if the key already has `max_open_jobs` unfinished ones; that
   check and the insert happen in one step inside the store, so two
   requests cannot both take the last slot.
2. **Cache.** If caching applies and an identical job succeeded earlier
   (and is fresh enough), its stored outputs are shared with the new job,
   which finishes at once at no cost.
3. **Run.** A task takes the route's targets in order. Before each submit
   it records which target it is trying. An adapter either answers with the
   outputs directly (one-call providers) or returns a provider job id, which
   is written to the job log *before* polling starts.
4. **Poll.** Every `media.poll_interval_ms` the adapter asks the provider.
   A target that exceeds the route's `timeout_s`, reports a failure, or has
   five transient polling errors in a row is abandoned and the next target
   is tried.
5. **Re-host.** Each output is downloaded (or decoded, for inline results),
   hashed, and moved into the configured storage: a local directory, or an
   S3-compatible bucket by SigV4-signed PUT. An output URL comes out of a
   provider's answer, so it is treated like a webhook URL: the host is
   resolved once, every address is checked against the private-address
   rule, and the connection goes to the checked address. Redirects are
   followed by the control plane itself, one hop at a time with the same
   check on each, and at most five of them. A storage failure fails the job
   without trying another provider, since the next one would hit the same
   storage.
6. **Finish.** The job moves to a final status exactly once. Its cost is
   computed from what the adapter that delivered sent to the provider (each
   adapter reports the characters and seconds in its own request; see
   [Configuration](configuration.md#mediaroutes)), with every part of the
   price at least zero. The cost goes to the ledger (the job id is the
   event id, so repeating this after a crash is harmless), and the job's
   webhook, if any, is armed.
7. **Webhook.** Delivery attempts are scheduled by a small timer process;
   the state of each delivery is stored in the job, so retries continue
   after a restart. For each attempt the target host is resolved once, the
   addresses are checked against the private-address rule, and the
   connection goes to the address that was checked.

**Restart safety.** At startup the control plane replays the job log and
resumes every unfinished job. A job with a recorded provider id goes
straight back to polling; it is never submitted, and paid for, a second
time. Finished jobs whose ledger event or webhook was cut off by the crash
get them now. The README names the remaining window: a crash between a
provider accepting a job and its id reaching disk, or during a synchronous
provider call, resubmits that job.

**Serving a stored file.** The bytes and their declared type came from a
provider. The control plane serves them as a download
(`content-disposition: attachment`), with `nosniff` and a sandboxing
`Content-Security-Policy`, and keeps the declared type only when it is one
of a short list of image, video and audio types (and JSON); anything else
goes out as `application/octet-stream`. The data plane passes those
headers on to the client.

**Adapters** are small modules implementing `submit` and `billable`, and
optionally `poll` and `cancel`. There are seven: `replicate`, `fal`, `openai_images`,
`elevenlabs`, `gemini`, `gemini_interactions`, `xai_video`. See
[Providers](providers.md#media-providers).

## State on disk

| File | Process | Written | Purpose |
|---|---|---|---|
| The config file | control (read only) | by you | File keys, upstreams, routes, media, retention. |
| `ledger.jsonl` | control | Appended and synced per batch. Renamed to the next numbered name when it is sealed (at 64 MiB, or after the UTC day turns); never rewritten. | The ledger's active segment: the newest usage events. |
| `ledger.000001.jsonl`, ... | control | Never written again once sealed. Deleted by `retention.ledger_days`, if set. | Sealed ledger segments: the older usage events. |
| `ledger.snapshot`, `ledger.snapshot.prev` | control | Replaced (temp file, sync, two renames) every 50,000 events, every five minutes while there is something new, after sealing and at a clean stop. | The ledger's totals, period spend and duplicate-detection ids up to a recorded position, so a start replays only what came after. Once segments have been deleted, the only copy of their totals. Its checksum catches accidents and is not a signature, so the decoded contents are also checked row by row before any of it is used; a file that does not look exactly like a snapshot is ignored. |
| `jobs.jsonl` | control | A new job appends its full snapshot; each later change appends a short patch line with only the fields that changed, so a job's input is written once. Every line is synced before the change is visible. Rewritten compacted (one full line per job) at start, after a retention sweep, and while running (checked once a minute) once the lines appended since the last compaction exceed both 5,000 and twice the number of jobs. | Job state. |
| `keys.json` | control | Replaced whole on every key change (temp file, sync, rename). | Managed keys: name, SHA-256 of the current secret and of earlier ones, budget and period, rate limit, models, disabled flag, and the webhook secret (in clear text) if set. Never a key itself. |
| `audit.jsonl`, `audit.jsonl.1` to `.3` | control | One line appended and synced per admin action. When the file would pass `OMNIGATE_AUDIT_MAX_MB` (50) it is renamed to `.1`, the older files move up, and the fourth falls off. | Who changed which key, and sign-ins. |
| The media directory | control | One directory per job. | Locally stored outputs. |
| `omnigate-usage.spool` | data | Appended per request (not synced); truncated when drained. | Undelivered usage events. |
| `omnigate-config.cache.json` | data | Rewritten (temp file, then rename) when a new snapshot is installed. | Start without the control plane. Holds key hashes and routes, never secrets. |

File names are the defaults; each has an environment variable
([Configuration](configuration.md#environment-variables)).

There is no database and no message broker. In memory only, and starting
fresh after a restart:

- data plane: rate-limit buckets, cooldowns, round-robin counters, learned
  model quirks, the response cache, and refusal counts not yet reported;
- control plane: the refusal counts it has received, the failed-login and
  wrong-token counters, and the per-key job-creation counts of the current
  minute. The short lists of recent requests and audit entries that the
  dashboard shows are also held in memory, but both come back after a
  restart: the request list from the ledger's snapshot and segments, the
  audit list from the live audit file.

Dashboard sessions are not state at all: the cookie is signed with a key
derived from the admin token and carries its own expiry.

## Why it is built this way

The reasons below are the ones stated in the code and the README.

- **The public path must not depend on the control plane.** "A control-plane
  outage must never take the gateway down" is the rule in the data plane's
  control client. Hence the pulled snapshot, the config cache, and usage
  delivery that never blocks a request.
- **Bill once, even through outages.** Usage delivery is at-least-once with
  a spool on one side and id-based deduplication on the other, instead of a
  synchronous write per request.
- **Secrets stay where they are used.** The snapshot carries key hashes and
  variable names. Text provider keys exist only in the data plane's
  environment, media and bucket credentials only in the control plane's.
  The Compose deployment enforces that with one environment file per
  container, so the process that faces the internet never holds the admin
  token.
- **Never trust a URL someone else chose.** A webhook URL comes from a
  client and an output URL from a provider. Both go through one module
  (`net_guard.ex`) that resolves the host once, refuses anything that is
  not a public unicast address (loopback, private, link-local, carrier NAT,
  documentation and benchmarking ranges, multicast, and the IPv6 forms that
  carry an IPv4 address inside), and hands back the address to connect to.
- **A limit that guards paid work is enforced where the work starts.** The
  data plane rate-limits job creation, but only for the path it recognises
  as one; the control plane counts again in the handler that creates the
  job, and caps unfinished jobs per key there.
- **Bill what the provider was asked for.** A media job's price follows the
  request the adapter built, not labels in the client's input; an abandoned
  stream is billed, by the provider's figures when they can still be read
  and by an estimate otherwise; and token counts are read only from where
  the protocols put them.
- **Three audiences, three credentials.** Applications use gateway keys,
  data planes use the internal token, operators use the admin token, and
  none works in another's place.
- **Keys are stored as hashes.** A managed key is generated by the control
  plane, shown once and kept only as its SHA-256, like a file key written
  with `key_sha256`. A lost key is replaced by rotation, not recovered.
- **A cache must not leak across tenants.** The response cache makes the
  gateway key part of the identity of a request, and sits behind
  authentication, the budget, model limits and the rate limit.
- **Refusals are worth seeing but not worth a disk write.** Requests the
  gateway turns away are counted in memory and reported best effort, while
  anything that costs money goes through the spool and the ledger.
- **A slow or silent peer must not hold a thread for ever.** The data plane
  uses one thread per connection, so every wait on a client or an upstream
  has a deadline, enforced by one watchdog task that cancels the
  connection's task (which also works on Windows, where shutting a socket
  down from another thread does not wake a blocked read).
- **No extra services to run.** State is files on disk, loaded at start.
  The README's comparison table lists this as a deliberate difference.
- **Start-up time must not grow with history.** A ledger that is replayed
  from its first event gets slower to start every day. Snapshots bound the
  replay to what was written since the last one, and segments let old
  history be deleted without touching the totals.
- **An SDK should not be able to tell the gateway from the provider.** So
  the gateway's own errors, its model list and its request-id headers follow
  the protocol of the endpoint the client called.
- **The control plane refuses what it does not recognise.** Its guards and
  its router must see the same path, so a path with an encoded character is
  refused outright, an unknown first segment is a 404 at the guard, and
  credentials are checked before a body is parsed. Wrong credentials are
  counted per address and locked out for a minute after too many; the
  listener speaks HTTP/1.1 only, since every protocol left on is one more
  parser in front of the authentication.
- **One spelling per path on the public port too.** The data plane decides
  what a request is from its path and then forwards that path. With a
  single canonical form the two can never disagree.
- **A crash must be visible and survivable.** One process serves every
  connection, so input is validated before anything can assert on it, and
  the last line of defence is a panic handler that logs and exits with a
  status a supervisor can act on.
- **Small dependency surface.** The data plane uses only the Zig standard
  library, the control plane has two direct Hex packages, the tools use only
  the Python standard library. The one exception is deliberate and
  optional: `tools/sdk_compat.py` needs the official OpenAI and Anthropic
  SDKs, because testing them is its purpose.
- **Provider output URLs expire.** So outputs are copied into storage the
  operator controls and jobs hand out the operator's URLs.
- **Paying a provider twice is worse than a slow restart.** So the provider
  job id is persisted before polling, and a resumed job polls instead of
  resubmitting.

What this design does not give you yet: cluster-wide budgets and rate
limits (both are per process or per node), and latency- or cost-aware
routing. The response cache and the refusal counts are likewise per
data-plane process, not shared.
