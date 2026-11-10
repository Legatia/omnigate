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
| Owns | Authenticating gateway keys, rate limits, routing, load balancing, failover, cooldowns, protocol translation, streaming, counting tokens | The config file, prices, the usage ledger, budgets, media jobs, output storage, webhooks, dashboard, metrics, retention |
| Credentials it holds | Text provider keys (from its environment) | Media provider keys, bucket credentials, webhook secrets, the admin token |
| State | In memory, plus two files: the usage spool and a cache of the last config | Files: the ledger, the job log, stored outputs |
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
| `POST /internal/usage/batch` | push, every `OMNIGATE_FLUSH_MS` when there is something to send | Usage events. |
| `/internal/v1/jobs*`, `/internal/v1/files/*` | per client request | The jobs API, forwarded. The data plane names the authenticated key in `x-omnigate-key-sha256`. |

**The snapshot** is the data plane's whole view of the configuration:

- keys as SHA-256 hashes with `name`, `rpm`, `models` and a `blocked` flag;
- text upstreams, with the *name* of the environment variable holding each
  provider key;
- text routes with `strategy` and each target's `upstream`, `model`,
  `weight`;
- a `version`, a hash of all of the above. It changes whenever anything the
  data plane sees changes, including a key flipping to blocked.

There are no budgets, prices or secrets in it, and nothing about media. The
data plane installs a snapshot only when its version differs from the one in
force, and writes it to the config cache file so that it can start from it
when the control plane is down.

Budgets reach the data plane only as the `blocked` flag: the control plane
compares each key's recorded spend with its budget when it builds the
snapshot.

## A text request

1. **Authenticate.** The key from `Authorization: Bearer` or `x-api-key` is
   hashed and looked up in the snapshot. Unknown: 401. Blocked: 402.
2. **Parse.** The body (at most 8 MiB) must be a JSON object with a `model`
   string, which names a route.
3. **Model limits, then rate limit.** A key restricted to a list of models
   gets 403 for anything else. Then the per-key token bucket is charged.
4. **Order the targets.** The route's strategy picks who goes first
   (`failover`: config order; `round_robin`: rotating; `weighted`: random by
   weight). Targets whose upstream is cooling down go last.
5. **Forward.** For each target in order: rewrite `model` to the target's
   model id; if the upstream speaks the other protocol, translate the
   request; send it with the provider key from the environment; wait for the
   response headers up to the timeout.
   - Connection error: one retry on a fresh connection, then next target.
   - Timeout, 429 or 5xx: next target, and a failure is noted for cooldowns.
   - Anything else: this is the answer.
6. **Stream.** The response body is copied to the client chunk by chunk and
   flushed each time. On the way through, a scanner picks the token counts
   out of the bytes without buffering the body. If the upstream speaks the
   other protocol the stream is translated event by event. From the first
   byte on there is no more failover.
7. **Report.** One usage event is queued. The request does not wait for it
   to be delivered.

If every target fails, the client gets 502 `all_upstreams_failed` with the
list of attempts, and a usage event with status 502 and no tokens is
recorded.

Two provider quirks are handled for translated requests only, because a
client speaking the other protocol cannot know them: models that reject
sampling parameters, and models that demand a thought signature on earlier
tool calls. The first refusal is retried with the fix, and the fix is
remembered per upstream and model in memory.

## Usage: spool and ledger

**On the data plane**, each usage event is appended to an in-memory queue
and to the spool file. A background task sends the oldest events in batches
of up to 500, and removes them only after the control plane has acknowledged
the batch. Failures back off up to 10 seconds. The spool file is truncated
when the queue drains completely, and reloaded at startup, so events survive
both a control-plane outage and a data-plane restart. After a crash the
spool can hold events that were already delivered; they are sent again.

**On the control plane**, a batch is appended to the ledger file
(`ledger.jsonl`) and synced to disk before it is acknowledged, then folded
into per-key totals in memory. Every event carries the request id as its
`id`, and an event whose id was already recorded is skipped. That is what
makes at-least-once delivery bill exactly once.

A text usage event as the data plane sends it:

| Field | Meaning |
|---|---|
| `id` | The request id (also `x-omnigate-request-id`). |
| `key_sha256` | Which gateway key. |
| `route_model` | The model name the client used. |
| `upstream`, `target_model` | Which target answered; null when all failed. |
| `status` | HTTP status sent to the client; 499 for a stream that broke mid-way; 502 when all targets failed. |
| `stream` | Whether the request was streamed. |
| `input_tokens`, `output_tokens` | As read from the provider's response. |
| `latency_ms` | From the start of the failover loop to the end of the response. |
| `attempts` | Each upstream tried and its outcome. |
| `ts_ms` | When the request finished on the data plane. |

The control plane adds `cost_usd` (from the target's prices at the time of
recording), `ts` and `received_at`. Media jobs are written to the same
ledger by the control plane itself, with `"kind": "media"`, the job id as
`id`, and the job's own `cost_usd`.

At startup the ledger file is replayed to rebuild the totals and the set of
seen ids. The file is never rewritten; `retention.ledger_ids_days` only
trims the in-memory id set.

Known limits, from the README: spool appends are not fsynced, so a power
loss can drop the last few events; the spool holds at most 100,000
undelivered events; the ledger lives on a single control-plane node.

## A media job

```
queued ──▶ running ──▶ succeeded
              │──────▶ failed
              └──────▶ canceled
```

1. **Create.** The control plane checks the key's budget and model list,
   finds the media route, validates `input`, `metadata`, the webhook URL and
   the idempotency key, and writes the job to the job log. With an
   idempotency key already used by this gateway key, the existing job is
   returned instead.
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
   S3-compatible bucket by SigV4-signed PUT. A storage failure fails the job
   without trying another provider, since the next one would hit the same
   storage.
6. **Finish.** The job moves to a final status exactly once. Its cost goes
   to the ledger (the job id is the event id, so repeating this after a
   crash is harmless), and its webhook, if any, is armed.
7. **Webhook.** Delivery attempts are scheduled by a small timer process;
   the state of each delivery is stored in the job, so retries continue
   after a restart.

**Restart safety.** At startup the control plane replays the job log and
resumes every unfinished job. A job with a recorded provider id goes
straight back to polling; it is never submitted, and paid for, a second
time. Finished jobs whose ledger event or webhook was cut off by the crash
get them now. The README names the remaining window: a crash between a
provider accepting a job and its id reaching disk, or during a synchronous
provider call, resubmits that job.

**Adapters** are small modules implementing `submit`, and optionally `poll`
and `cancel`. There are seven: `replicate`, `fal`, `openai_images`,
`elevenlabs`, `gemini`, `gemini_interactions`, `xai_video`. See
[Providers](providers.md#media-providers).

## State on disk

| File | Process | Written | Purpose |
|---|---|---|---|
| The config file | control (read only) | by you | Keys, upstreams, routes, media, retention. |
| `ledger.jsonl` | control | Appended and synced per batch. Never rewritten. | Usage events; source of all spend totals. |
| `jobs.jsonl` | control | Each change appends the job's full snapshot, synced before the change is visible. Rewritten compacted (one line per job) at start and after a retention sweep. | Job state. |
| The media directory | control | One directory per job. | Locally stored outputs. |
| `omnigate-usage.spool` | data | Appended per request (not synced); truncated when drained. | Undelivered usage events. |
| `omnigate-config.cache.json` | data | Rewritten (temp file, then rename) when a new snapshot is installed. | Start without the control plane. Holds key hashes and routes, never secrets. |

There is no database and no message broker. Rate-limit buckets, cooldowns,
round-robin counters and learned model quirks are in the data plane's memory
only and start fresh after a restart.

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
- **Three audiences, three credentials.** Applications use gateway keys,
  data planes use the internal token, operators use the admin token, and
  none works in another's place.
- **No extra services to run.** State is files on disk, replayed at start.
  The README's comparison table lists this as a deliberate difference.
- **Small dependency surface.** The data plane uses only the Zig standard
  library, the control plane has two direct Hex packages, the tools use only
  the Python standard library.
- **Provider output URLs expire.** So outputs are copied into storage the
  operator controls and jobs hand out the operator's URLs.
- **Paying a provider twice is worse than a slow restart.** So the provider
  job id is persisted before polling, and a resumed job polls instead of
  resubmitting.

What this design does not give you yet, also from the README: cluster-wide
budgets and rate limits (both are per process or per node), latency- or
cost-aware routing, text response caching, and ledger rotation.
