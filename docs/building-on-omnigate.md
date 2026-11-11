# Building on omnigate

omnigate is a model gateway. What it does inside a request (routing,
failover, translation, redaction, metering) is the project's own code, and
changes there are made in the repository. Everything else is meant to be
built **around** it, over HTTP, by programs that omnigate knows nothing
about: a payment service that credits keys, a billing tool that reads usage,
an agent harness that calls models.

This page is for the people writing those programs. It names the interfaces
you can rely on, shows the three most common things built around a gateway,
and says plainly what is not offered.

- [The interfaces](#the-interfaces)
- [Agents, harnesses and apps](#agents-harnesses-and-apps)
- [Taking payments: prepaid keys and top-ups](#taking-payments-prepaid-keys-and-top-ups)
- [Reading usage](#reading-usage)
- [Reacting to media jobs](#reacting-to-media-jobs)
- [Operating notes](#operating-notes)
- [What is not offered](#what-is-not-offered)
- [What "stable" means before 1.0](#what-stable-means-before-10)

Three runnable examples go with it, in [`examples/`](../examples/), Python
standard library only. The end-to-end test (`tools/e2e.py`) runs each of
them against the mock providers on every change, so they do not rot:

| File | What it is |
|---|---|
| [`examples/agent_client.py`](../examples/agent_client.py) | A tool-calling loop against the gateway, with the handling of 402, 429 and 5xx a client owes it |
| [`examples/prepaid_topup.py`](../examples/prepaid_topup.py) | The skeleton of a payment service: hears of payments, credits keys, safe to restart |
| [`examples/usage_export.py`](../examples/usage_export.py) | Pages the usage feed into a CSV file, continuing where it stopped |

## The interfaces

| Interface | Port | Who calls it | Reference |
|---|---|---|---|
| Gateway API: the OpenAI and Anthropic text endpoints, `/v1/models`, the jobs API, file URLs | data plane (`8080`) | applications, agents, SDKs, with a **gateway key** | [API](api.md) |
| Admin API: keys, top-ups, the usage feed, the audit log | control plane (`4000`) | your own back-office programs, with the **admin token** | [Admin](admin.md#admin-api-reference) |
| Webhooks: a signed `POST` when a media job finishes | from the control plane to a URL you give | your receiver | [API](api.md#webhooks) |
| Metrics: Prometheus text | control plane, `GET /metrics` | your monitoring | [API](api.md#get-metrics) |

There is no fifth one. In particular there is no plugin API and no hook that
runs your code inside a request; see [What is not offered](#what-is-not-offered).

## Agents, harnesses and apps

Anything that takes a base URL and an API key works, because the gateway
speaks the providers' own protocols:

| Client speaks | Base URL | Key goes in |
|---|---|---|
| OpenAI (Chat Completions, Responses, embeddings) | `http://<gateway>:8080/v1` | `Authorization: Bearer <gateway key>` |
| Anthropic (Messages) | `http://<gateway>:8080` | `x-api-key: <gateway key>` |

`"model"` is the name of a route in the gateway's config, not a provider's
model id. Which provider answers, and in which protocol, is the gateway's
business: an OpenAI-style client can be routed to an Anthropic model and the
other way round ([translation](api.md#translation)). The official SDKs are
covered in [Using the official SDKs](api.md#using-the-official-sdks).

**One key per agent, tenant or end user.** A gateway key is the unit
everything is enforced and counted by. Create one with
`POST /admin/keys` ([Admin](admin.md#create)) and give it:

| Field | What it guards against |
|---|---|
| `budget_usd` with `budget_period` | An agent that loops: the key is answered `402 budget_exceeded` once the budget is spent |
| `rpm`, `max_concurrent` | A burst: `429` with `retry-after` |
| `models` | Using a route it was not meant to use: `403` |
| `max_open_jobs`, `max_jobs_per_day` | Media jobs piling up |
| `privacy` | What a provider may see and what is kept: [Privacy mode](privacy.md) |

These hold whatever the agent does, because they are enforced by the
gateway and not by the agent's own code.

**What a client owes the gateway.** Three answers deserve handling, and
`examples/agent_client.py` shows all three:

| Answer | Meaning | Do |
|---|---|---|
| `402`, code `budget_exceeded` | The key's budget is spent | Stop and report. Retrying cannot help until the key is topped up or its period turns |
| `429` | A rate limit: the key's own (`rate_limit_exceeded`, `concurrency_limit_exceeded`) or every provider's (`upstream_rate_limited`) | Wait for the `retry-after` header, then try again |
| `5xx` | Every target failed, or the gateway is overloaded | Back off and try again; the error lists the `attempts` |

Every response carries `x-omnigate-request-id`. It is the `id` of that
request in the usage feed, so a client can log it and a billing tool can
find the same request later.

**Tagging requests.** A client may send `x-omnigate-tag: <label>` on a text
request or on `POST /v1/jobs`: its own name for whose request this is (a
tenant, a run, an end user's id in *your* system). The gateway records it
with the request's usage and does nothing else with it:

- 1 to 64 characters of letters, digits, `.`, `_`, `:` and `-`. Anything
  else, or the header sent twice, is `400 invalid_request`: a tag that
  would be dropped or cut is refused, so that your books never silently
  miss a request.
- It is never sent to a provider, and it is in no metric (a label per end
  user would not survive Prometheus). It is in the ledger and therefore in
  the [usage feed](#reading-usage).
- [Privacy mode](privacy.md) does not remove it: `unlink` is about what a
  provider can tie to a person, and the tag never leaves your own machine.
  The same goes for `no-store`. If your tags must not identify people, send
  an opaque id, not an e-mail address (the character set already keeps `@`
  out).
- One tag per request. For finer attribution use more keys.

```bash
curl http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer og-unlimited-key" -H "x-omnigate-tag: tenant-42" -d '{"model":"demo-chat","messages":[{"role":"user","content":"hi"}]}'
```

## Taking payments: prepaid keys and top-ups

omnigate has a budget per key and one call that adds to it safely. A
payment service of any kind (a chain watcher, a card processor's webhook
receiver, a manual back-office tool) is a small program next to the control
plane, and this section is how to write one.

(There is now also one payment provider built in, opt-in: with a `payments`
section in the config, key holders buy credit themselves in crypto through
NEAR Intents, with no program of yours in between. See
[Payments](payments.md). It credits keys through the same top-up described
here, and everything else on this page works next to it. What credit burns
and earns, whoever paid for it, is in [Prepaid credit](credits.md).)

1. **A customer gets a key with an empty prepaid budget.** A `total` budget
   is credit bought in advance: it does not start over by itself.

   ```bash
   curl http://127.0.0.1:4000/admin/keys -H "Authorization: Bearer dev-admin-token-change-me" -H "Content-Type: application/json" -d '{"name":"customer-42","budget_usd":0}'
   ```

   The answer contains the key itself, once. With a budget of 0 the key is
   answered `402` until it is topped up.

2. **Each payment is one top-up, named by the payment.**

   ```bash
   curl http://127.0.0.1:4000/admin/keys/customer-42/topup -H "Authorization: Bearer dev-admin-token-change-me" -H "Content-Type: application/json" -d '{"amount_usd":5,"reference":"0x9f2c...e1"}'
   ```

   ```json
   {
     "key": { "name": "customer-42", "budget_usd": 5.0, "period_spend_usd": 0.0, "state": "active", "...": "..." },
     "topup": { "reference": "0x9f2c...e1", "key": "customer-42", "amount_usd": 5.0, "budget_usd": 5.0, "at": "2026-11-11T18:00:00Z", "replayed": false }
   }
   ```

   `reference` is your id for the payment: a transaction hash, the payment
   provider's id, an invoice number. The budget and the reference are
   written to disk together. **Sending the same top-up again adds nothing**
   and answers with what the first call did, `"replayed": true`. So your
   service may deliver each payment at least once (retry on a timeout,
   rescan after a restart) and omnigate turns that into exactly once.

3. **The key works again within seconds.** The data plane learns of the new
   budget with its next config poll (`OMNIGATE_POLL_MS`, two seconds by
   default); no restart.

What can come back, besides `200`:

| Status and code | Meaning | Do |
|---|---|---|
| `400 invalid_request` | `amount_usd` is not a number above 0 (at most 1e9), or `reference` is not 1 to 200 printable ASCII characters without spaces | Fix the call; nothing was added |
| `404 key_not_found` | No such key | Create it, or set the payment aside for a person |
| `409 not_prepaid` | The key has no budget, or a `monthly` or `daily` one | Top-ups only add to a `total` budget; give the key one first |
| `409 read_only_key` | The key is defined in the config file | Use a managed key |
| `409 reference_conflict` | The reference was already used for another key or another amount | A bug in your service, or two payments sharing an id: a person must look |
| `5xx`, or no answer | Nothing is known | Send it again later with the same reference |

Things to know:

- **How much is left** is `budget_usd - period_spend_usd` in
  `GET /admin/keys`. `omnigate_key_budget_usd`, `omnigate_key_period_cost_usd`
  and `omnigate_key_blocked` are the same in [metrics](api.md#get-metrics),
  for an alert before a customer runs dry.
- **Spending is checked after the fact.** The request that crosses the
  budget completes, and so can a few that were in flight; then the key is
  blocked. A prepaid balance can therefore end slightly below zero. Size the
  smallest top-up accordingly, or keep a margin.
- **The price is yours.** `cost_usd` is computed from the prices in your
  config ([Configuration](configuration.md)), so what a customer's dollar
  buys is whatever you set there, markup included. omnigate does not know
  what the provider billed you.
- **Refunds and corrections** are not top-ups: a negative amount is refused.
  Set the budget outright with `PATCH /admin/keys/{name}`
  (`{"budget_usd": ...}`), which the audit log records as a change.
- **References are remembered** in the key store file, the newest 10,000
  across all keys. A payment replayed after 10,000 later ones would be
  credited again; keep your own cursor (as the example does) rather than
  rescanning from the beginning of time.
- **Every top-up is audited** (`key.topup`, with the reference, the amount,
  the budget after it, and whether it was a replay): `GET /admin/audit`.
- **Subscriptions instead of prepaid:** give the key a `monthly` budget. It
  unblocks by itself when the month turns; your service only changes the
  budget when the plan changes ([Budgets and periods](admin.md#budgets-and-periods)).

`examples/prepaid_topup.py` is this service with a file standing in for the
payment source. Replace its `FileSource` with whatever tells you that money
arrived; it only has to hand out `{reference, key, amount_usd}` and may hand
out the same payment more than once.

## Reading usage

Three views, for three purposes:

| You want | Use |
|---|---|
| Every single request and job, and every top-up, to bill or analyse | `GET /admin/events`, below |
| Totals per key, right now | `GET /admin/keys` (`requests`, tokens, `cost_usd`, `credits_burned_usd`, `period_spend_usd`, and a prepaid key's `credits`) |
| Time series and alerts | `GET /metrics` (`omnigate_key_*` per key, never per tag) |

**The usage feed.** `GET /admin/events` returns what the ledger recorded,
oldest first: one event per metered text request and one per media job.

```bash
curl "http://127.0.0.1:4000/admin/events?limit=2" -H "Authorization: Bearer dev-admin-token-change-me"
```

```json
{
  "events": [
    {
      "cursor": "1-412", "id": "0d5f...", "kind": "text", "ts": "2026-11-11T18:00:01.120Z", "received_at": "2026-11-11T18:00:01.640Z",
      "key": "customer-42", "tag": "tenant-42", "model": "demo-chat", "upstream": "mock-ok", "target_model": "ok-1",
      "status": 200, "stream": false, "input_tokens": 11, "cached_input_tokens": 0, "cache_write_input_tokens": 0, "output_tokens": 7,
      "outputs": null, "cached": false, "estimated": false, "latency_ms": 31, "cost_usd": 0.0000041, "credits_usd": 0.0000041
    }
  ],
  "next": "1-824",
  "more": true,
  "gap": false
}
```

| Parameter | Meaning |
|---|---|
| `after` | A cursor: the `next` of an earlier page, or one event's `cursor`. Left out: from the oldest event still on disk |
| `limit` | Events per page, 1 to 1000 (default 100) |
| `key` | Only this key's events, by name, across its rotations. `404 key_not_found` for a name that does not exist |

How to consume it:

- **Loop until `more` is false**, passing `next` as `after`; then poll with
  the last `next` for new events. Save the cursor after you have stored the
  page. A page can be shorter than `limit`, or empty, while `more` is true
  (a filtered page skips other keys' events, and one call reads at most
  4 MiB of the ledger): keep going.
- **The order is the order of recording**, which is close to but not the
  same as the order of `ts`. `ts` is when the request finished on the data
  plane; `received_at` is when the event reached the ledger, which can be
  later after an outage.
- **`id` is unique.** For a text request it is the `x-omnigate-request-id`
  the client received; for a media job it is the job id. If your consumer
  crashes between storing a page and saving the cursor, drop repeats by it.
- **`gap: true`** means the events between your cursor and the oldest one
  left were deleted by `retention.ledger_days`
  ([Operations](operations.md#retention)). Per-key totals stay exact; the
  single events are gone. With the default (`0`, keep forever) it never
  happens. A cursor from another installation, or one that was edited, is
  `400 invalid_cursor`.
- **`key` is a name, or `null`** for a key that has been deleted since. Key
  hashes are never in the feed.
- **No content.** The ledger holds no prompt, answer, job input or output,
  so neither does the feed.
- **`cost_usd` and `credits_usd`.** The first is what the provider cost.
  The second is what the event burned of the key's credit: the same number,
  unless the key is prepaid and a
  [burn multiplier](credits.md#the-burn-multiplier) applies.
- **`"kind": "credit"`** is credit added to a key, in the same order as its
  usage: `amount_usd`, `source` (`admin`, a payment provider's name,
  `bonus`), `reference`, `bonus_eligible` and `budget_usd` (the budget after
  it); `cost_usd` and `credits_usd` are 0. A consumer that only wants usage
  skips this kind. (New with the credits commit: a consumer written before
  it sees rows without a model or tokens.)
- **`estimated: true`** marks token counts the gateway had to estimate
  because a response ended before the provider's own figures arrived;
  `cached: true` marks an answer from the gateway's response cache, counted
  and not charged.

`examples/usage_export.py` is a complete consumer: it appends to a CSV file
and keeps its cursor next to it.

## Reacting to media jobs

A job can carry a `webhook_url`. When it finishes, the control plane sends a
signed `POST` there, with retries ([delivery](api.md#delivery-and-retries)).
A receiver must verify the signature against the raw body before trusting
it; [Verifying the signature](api.md#verifying-the-signature) has the code.
The key's `webhook_secret` (set on the key, in the config or through
`PATCH /admin/keys/{name}`) is the signing secret.

A job's `metadata` (up to 16 KiB of your own JSON) comes back in the webhook
and when the job is fetched; `x-omnigate-tag` on `POST /v1/jobs` puts a label
on its event in the usage feed. Use the first for what your receiver needs,
the second for what your billing needs.

There are no webhooks for text requests, for a key running out of budget, or
for configuration changes. For a budget alert use the metrics above.

## Operating notes

- **There is one admin token, and it can do everything**: create and delete
  keys, change budgets, read usage, read the audit log. There are no scoped
  or read-only tokens yet. So run a payment service or a billing exporter
  where the control plane runs (the same host or private network), give it
  the token from the same secret store, and treat it as part of your
  trusted back office.
- **The control plane's port must not be public.** Only the data plane's
  port is for clients. [Security hardening](security.md) has the details,
  including the admin allow-list in the bundled proxy.
- **Wrong admin tokens are throttled** per client address
  ([Admin](admin.md#two-ways-in)). A service with a stale token will see
  `429` after a few tries, not endless `401`s.
- **A script uses the bearer token**, not a browser session: no CSRF token
  is needed ([CSRF](admin.md#csrf-scripts-and-browsers)).
- **Changes reach the data plane within its poll interval** (two seconds
  by default). A key you just created, topped up or disabled is live then, not
  in the same instant.
- **Back up the control plane's data directory.** Managed keys (with the
  top-up references) and the ledger live there
  ([Security hardening](security.md)).

## What is not offered

- **No plugins, no in-process hooks.** You cannot register code that runs
  when a request arrives, before it is routed, or when a response comes
  back. Routing rules, protocol translation, redaction classes, a new kind
  of provider adapter: those are changes to omnigate itself, made in the
  repository ([CONTRIBUTING.md](../CONTRIBUTING.md)).
- **No per-request callback to your service.** The gateway does not ask
  anyone whether a request may proceed. What may proceed is decided by the
  key's settings, which you change through the admin API ahead of time.
- **No scoped admin tokens** (see above).
- **No event push for usage.** The usage feed is polled.
- **No multi-node ledger.** One control plane owns the keys and the ledger.

If something you need cannot be built from keys, budgets, tags, the usage
feed, webhooks and metrics, that is worth an issue: it is how the list of
interfaces grows.

## What "stable" means before 1.0

omnigate has not reached 1.0, and nothing here is frozen. What the project
commits to until then:

| Interface | Commitment |
|---|---|
| The gateway's provider-compatible endpoints | They follow the providers' own APIs. A difference from those is a bug |
| The jobs API, file URLs, webhook payloads and signatures | Changes are additive where possible; a breaking change is listed in the [changelog](../CHANGELOG.md) under "Changed" and in [Upgrading](upgrading.md) |
| `GET/POST/PATCH/DELETE /admin/keys...`, `POST /admin/keys/{name}/topup`, `GET /admin/events`, `GET /admin/audit`, `GET /metrics` | The same: fields may be added, and a consumer must ignore fields it does not know. Removing or renaming a field, or changing what one means, is a breaking change and is announced as above |
| Cursors of `GET /admin/events` | Opaque text. Do not build or take apart one; a cursor stays valid across restarts and upgrades of the same installation |
| `GET /admin/overview`, `/admin/private-chat/*` | **Not stable.** They are the feeds of the dashboard's own pages and change with them. Do not build on them |
| `/internal/*` | Between the two processes only |

"Announced" means: in the changelog entry of the version that changes it and
in the upgrade notes, before the release is tagged. It does not mean a
deprecation period; before 1.0 there is none.
