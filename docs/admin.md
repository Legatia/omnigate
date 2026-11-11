# Admin: dashboard, keys, budgets and the audit log

Everything on this page happens on the **control plane's** port (4000 by
default) and uses the **admin token** (`OMNIGATE_ADMIN_TOKEN`), never a
gateway key. Keep that port private, and let only operators' addresses
reach it where you can; see
[Deployment](deployment.md#what-to-keep-private) and
[Security hardening](security.md).

- [Two ways in](#two-ways-in)
- [The dashboard](#the-dashboard)
- [Gateway keys: two sources](#gateway-keys-two-sources)
- [Key lifecycle with curl](#key-lifecycle-with-curl)
- [Budgets and periods](#budgets-and-periods)
- [The audit log](#the-audit-log)
- [CSRF: scripts and browsers](#csrf-scripts-and-browsers)
- [Admin API reference](#admin-api-reference)

The examples use the quickstart's addresses and admin token
(`http://127.0.0.1:4000`, `dev-admin-token-change-me`). Key management has
been exercised by the unit tests and the end-to-end test against mock
providers; nothing here has run under production load.

## Two ways in

| | How | Used by |
|---|---|---|
| Bearer token | `Authorization: Bearer <admin token>` on every request | Scripts, `curl`, Prometheus |
| Session | `POST /login` with the token as the form field `password`; the answer sets the `omnigate_session` cookie (12 hours, `HttpOnly`, `SameSite=Strict`, `Secure` behind TLS) | The dashboard in a browser |

Both open the same things: the dashboard page, `/admin/*` and `/metrics`.
There is one admin token and no user accounts; changing the token ends
every session. The token must be at least 16 characters long, or the
control plane does not start.

The sign-in form is the only request body the control plane reads from a
caller without a credential, and it may be at most 4,096 bytes, declared in
`Content-Length` (`413 payload_too_large` otherwise). Every other body is
parsed only after the admin token, a session or the internal token has been
checked; see [API](api.md#errors-and-request-paths).

**Guessing is throttled, per client address, for both ways in.**

| | Limit | Then |
|---|---|---|
| Sign-in form | 5 wrong passwords within a minute | `429` on `POST /login` until the minute is over, for the right password too. A correct sign-in before that clears the count. |
| Bearer token | 20 wrong tokens within a minute, counted wherever the token is accepted: `/admin/*`, `/metrics`, the dashboard page (`/`), `/login` and `/logout` | `429 too_many_attempts` with `retry-after: 60` on `/admin/*`, `/metrics`, `/` and `GET /login` for **every** bearer token from that address, the right one included, until the minute is over. (Until the close-out commit, the one after 55a294d, `GET /login` answered such a request with the sign-in page and `200`.) On `POST /login` and `/logout` a bearer token from that address is ignored for that time, as if none had been sent: the form's password, or the session, decides there. |

- The minute starts with the first failure. A request with no
  `Authorization` header at all is not a guess and is not counted
  (`/admin/*` and `/metrics` answer it `401`, the dashboard page sends it
  to `/login`). Any `Authorization` header that is not the admin token as
  a bearer token counts, another scheme such as `Basic` included.
- The token is compared in one place for all of these paths. Until commit
  d79406b the dashboard page and `/login` compared it on their own, outside
  the count. During a lockout the token is not compared at all, so the
  answer says nothing about whether it was right. A correct token does not
  clear the bearer count; the count ends with its minute.
- The bearer limit is the higher one on purpose: scripts share an address
  more often than people do, and a lockout also stops your own automation
  (a Prometheus scrape from the same address, for example) for that minute.
- A signed-in browser session keeps working during a bearer lockout.
- The counts are in memory, per control-plane process. IPv6 addresses are
  counted by their /64.
- **Which address counts.** By default it is the address of the
  connection. Behind a reverse proxy that is the proxy's address for
  everyone, so one person guessing locks everybody out. With
  `OMNIGATE_TRUST_FORWARDED=1` the last hop of `X-Forwarded-For` is used
  instead, which is right when the proxy is the only way in and writes that
  header itself; `compose.yaml` sets it, and `deploy/Caddyfile` replaces
  whatever a client sent under that name with the address of the
  connection. Do not set it when clients can reach the control plane
  directly: they could then choose the address they are counted under.

## The dashboard

Open the control plane's address in a browser (`http://127.0.0.1:4000/` in
the quickstart, `https://$OMNIGATE_ADMIN_HOST` behind the Compose proxy) and
sign in with the admin token.

The page is one HTML document with its styles and script inline; it loads
nothing from other hosts. It is rendered on the server, so it shows current
data with JavaScript off. With JavaScript on it refreshes itself every four
seconds from `GET /admin/overview` (the top bar shows the time of the last
update, in UTC), and the buttons that change keys work.

From top to bottom:

**Overview.** Six figures: requests, errors, tokens in, tokens out, spend
and media jobs. Each shows the total over the whole ledger and, beneath it,
the figure for today (the current UTC day).

**Keys.** One row per gateway key, keys from the config file first.

| Column | Shows |
|---|---|
| Key | The name, tagged `file` or `managed` (see [below](#gateway-keys-two-sources)). |
| State | `active`, `blocked` (budget spent for the current period), `disabled` (switched off by an operator) or `shadowed` (a managed key that a config-file key of the same name has put out of use; see [below](#gateway-keys-two-sources)). Shadowed keys are listed last, so that you can see why such a key stopped working. |
| Spend | Without a budget: total spend. With one: spend against the budget with a progress bar; for a monthly or daily budget that is this period's spend, with the all-time total beneath. |
| Requests, Errors, Tokens in / out, Jobs | Totals from the ledger. Prompt-cache reads and writes are noted next to the tokens when there are any. |
| Per min | The key's `rpm`, or a dash for no limit. |
| Models | The key's model list, or `all`. |
| Actions | For managed keys: **Disable** / **Enable**, **Rotate**, **Delete**. For file keys: `in config file`. |

Disable, Rotate and Delete ask for a second click: the button turns into
`Confirm ...?` for six seconds, with a Cancel button next to it. Enable acts
at once.

Below the table is the **Create a key** form: name, optional budget in US
dollars, what the budget covers (everything, each calendar month, each day),
optional requests per minute, and an optional comma-separated model list.
(A key's limits on media jobs, `max_open_jobs` and `max_jobs_per_day`, are
not in the form or the table; set them with the API.)
After creating or rotating a key the page shows the key itself in a panel
with a Copy button. **That is the only time the key is shown**; only its
SHA-256 is stored.

**Recent requests.** Up to 25 of the newest text requests: time, key,
model, the upstream and model that served it, status, tokens, latency, cost,
and each failover attempt with its outcome. The list is taken from the 50
newest ledger events and comes back after a restart, like the totals: both
are part of the ledger's snapshots.

**Recent media jobs.** The 25 newest jobs: created, id, key, model, status,
upstream, cost, links to the outputs, and the webhook's delivery state.

**Refused requests.** Requests the gateway turned away before routing them
(bad key, rate limit, disallowed model and so on), as counts per key and
reason. These counts are kept in memory and start from zero whenever the
control plane restarts; see [Operations](operations.md#refused-requests).

**Admin activity.** The ten newest entries of the [audit log](#the-audit-log):
time, action, target, outcome, how the caller was authenticated, and the
address. A summary line for repeated failed sign-ins is listed like any
other entry, with its `repeats` count under the outcome ("418 more").

**Configuration.** A read-only view of what the config file says: text
upstreams (name, protocol, host), text routes (strategy, cache time,
targets), media upstreams and routes, output storage, and retention.
Upstreams are shown by host only; keys, hashes and secrets never appear.
Routes, upstreams and everything under `media` are still changed by editing
the config file.

A key's [privacy mode](privacy.md) shows under its state (`private:
no-store, redact, unlink`). Managed keys have a **Privacy on** / **Privacy
off** button: on sets `"privacy": true`; off removes the whole setting, an
`encrypt_to` recipient included, and like the other destructive buttons asks
for a second click. The form that creates a key has a privacy choice and a
field for the recipient. Anything finer (single parts, single classes) is set
over the admin API.

## Gateway keys: two sources

| | File keys | Managed keys |
|---|---|---|
| Defined in | `keys[]` in the config file | The keys file, `OMNIGATE_KEYS` (default `data/keys.json`) |
| Created by | Editing the file | `POST /admin/keys` or the dashboard |
| Changed through the admin API | No: `409 read_only_key` | Yes |
| The key itself | Chosen by you; the file holds it or its SHA-256 | Generated (`og-` followed by 43 random characters), returned once, never stored |
| Shown in listings as | `"source": "file"` | `"source": "managed"` |

The two lists are merged, file keys first, and everything else in the
gateway treats them alike: the same snapshot goes to data planes, the same
budgets, rate limits and model lists apply.

Names are how keys are told apart in listings, metrics and the admin API's
paths. The API refuses to create a managed key under a name that is
already in use, by a managed key or a file key (`409 key_exists`).

**Shadowed keys.** The other way round is possible: you can add a file key
to the config under the name of an existing managed key. The file wins.

- The file key is in use. The managed key is **shadowed**: it is left out
  of the snapshot sent to data planes, so its secret is answered
  `401 invalid_api_key` like a key that does not exist.
- The control plane logs a warning once, when the key becomes shadowed
  (`key "<name>" is defined in the config file and also exists as a managed
  key: ...`).
- `GET /admin/keys`, `GET /admin/usage`, `GET /admin/overview` and the
  dashboard's key table all list the shadowed key after all the others,
  with `"state": "shadowed"` and `"shadowed": true`. (Until commit 10bc009
  the dashboard and the overview left it out.)
- The two keys have different secrets, and usage is recorded per secret, so
  the file key starts with its own spend; the managed key's spend stays
  with the managed key.
- To end it, remove or rename the file key (the managed key works again,
  with its spend and jobs), or delete the managed key with
  `DELETE /admin/keys/{name}`. `PATCH`, rotate and delete on that name act
  on the managed key, not on the file key.

Two file keys with one name are still not checked for; do not do that.

Things to know about the keys file:

- It is rewritten atomically (temporary file, sync, rename) on every change.
  A change that cannot be saved is not applied (`500 storage_error`).
- It holds key **hashes**, never keys. It does hold a key's
  `webhook_secret` in clear text if you set one, because signing needs the
  secret itself. Protect the data directory.
- If the file exists but cannot be read or parsed, the control plane refuses
  to start rather than start with no managed keys.
- A managed key stored with an `rpm` above 1,000,000 (possible in a file
  written before commit d79406b, which introduced the bound) is read as
  1,000,000.
- Back it up with the ledger; see [Deployment](deployment.md#backups).

A change reaches the data planes with their next config poll
(`OMNIGATE_POLL_MS`, two seconds by default). Because the data plane keeps
serving its last config when the control plane is down, a key that was
deleted or disabled during an outage of the *connection* between the two
keeps working on that data plane until it can poll again.

## Key lifecycle with curl

Each command below sends the admin token as a bearer token, so none needs a
CSRF token. The JSON answers are shown formatted; the ids, times and
numbers are made up, the shape is what the code returns.

### Create

```bash
curl -X POST http://127.0.0.1:4000/admin/keys -H "Authorization: Bearer dev-admin-token-change-me" -H "Content-Type: application/json" -d '{"name":"my-app","budget_usd":25,"budget_period":"monthly","rpm":600,"models":["demo-chat","demo-claude"]}'
```

`201 Created`:

```json
{
  "name": "my-app",
  "key": "og-<43 characters, shown only in this answer>",
  "source": "managed",
  "created_at": "2026-11-10T12:00:00Z",
  "budget_usd": 25.0,
  "budget_period": "monthly",
  "period_spend_usd": 0.0,
  "period_resets_at": "2026-12-01T00:00:00Z",
  "rpm": 600,
  "models": ["demo-chat", "demo-claude"],
  "max_open_jobs": 100,
  "max_jobs_per_day": 10000,
  "disabled": false,
  "blocked": false,
  "state": "active",
  "shadowed": false,
  "has_webhook_secret": false,
  "requests": 0,
  "errors": 0,
  "input_tokens": 0,
  "cached_input_tokens": 0,
  "cache_write_input_tokens": 0,
  "output_tokens": 0,
  "cached_responses": 0,
  "jobs": 0,
  "cost_usd": 0.0
}
```

Save `key` now: no later call returns it. Only `name` is required.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | required | 1 to 64 characters: letters, digits, `.`, `_`, `-`, starting with a letter or digit. Cannot be changed later. |
| `budget_usd` | number, 0 to 1,000,000,000,000, or `null` | `null` (no budget) | See [Budgets and periods](#budgets-and-periods). |
| `budget_period` | `"total"`, `"monthly"` or `"daily"` | `"total"` | What the budget covers. `null` also means `"total"`. |
| `rpm` | whole number, 0 to 1,000,000 | `0` (no limit) | Requests per minute, per data-plane process. `null` also means `0`. |
| `max_concurrent` | whole number, 0 to 1,000,000 | `0` (the data plane's `OMNIGATE_MAX_CONCURRENT_PER_KEY`) | Requests the key may have in flight at once on one data-plane process, in place of `OMNIGATE_MAX_CONCURRENT_PER_KEY`; one more answers `429 concurrency_limit_exceeded`. `0` and `null` mean the key has no cap of its own. The dashboard shows a cap under the key's rate limit ("12 at once"). |
| `models` | list of at most 1,000 route names, each 1 to 256 bytes, or `null` | `null` (all) | Text and media routes the key may use. A name given twice is kept once; an empty list allows none. |
| `max_open_jobs` | whole number, 0 to 1,000,000,000, or `null` | `null` (the config's `media.max_open_jobs`, 100 unless set) | Media jobs the key may have unfinished at one time; `0` for no limit. Listings show the limit in force, so a key without its own shows the default. |
| `max_jobs_per_day` | whole number, 0 to 1,000,000,000, or `null` | `null` (the config's `media.max_jobs_per_day`, 10,000 unless set) | Media jobs the key may create per UTC day, whatever became of them; `0` for no limit. One job more answers `429 too_many_jobs_today`. Listings show the limit in force, as for `max_open_jobs`. |
| `webhook_secret` | string up to 256 bytes, or `null` | `null` | Signing secret for this key's job webhooks. `""` also clears it. Never returned; listings show `has_webhook_secret`. |
| `disabled` | boolean | `false` | A disabled key is refused. |

Unknown fields are ignored. A bad value answers `400 invalid_request` with a
message naming the field. The whole numbers are read strictly: a fraction
(`600.0`), a string (`"600"`) or a value above the range is a bad value.
The upper bounds on `rpm` and `max_concurrent` are there because data
planes hold them in 32-bit fields; the same bounds on the numbers apply to
keys in the config file
([Configuration](configuration.md#gateway-keys)).

### List

```bash
curl http://127.0.0.1:4000/admin/keys -H "Authorization: Bearer dev-admin-token-change-me"
```

`{"keys": [...]}`: every key from both sources in the shape above, without
`key`. `GET /admin/usage` returns the same document.

### Change

`PATCH` with only the fields to change; the others keep their values.

```bash
curl -X PATCH http://127.0.0.1:4000/admin/keys/my-app -H "Authorization: Bearer dev-admin-token-change-me" -H "Content-Type: application/json" -d '{"budget_usd":50,"rpm":1200}'
```

Remove a budget, or lift the model limit, with `null`:

```bash
curl -X PATCH http://127.0.0.1:4000/admin/keys/my-app -H "Authorization: Bearer dev-admin-token-change-me" -H "Content-Type: application/json" -d '{"budget_usd":null,"models":null}'
```

Disable a key without deleting it, and enable it again with `false`:

```bash
curl -X PATCH http://127.0.0.1:4000/admin/keys/my-app -H "Authorization: Bearer dev-admin-token-change-me" -H "Content-Type: application/json" -d '{"disabled":true}'
```

The answer is `200` with the key as in a listing. A disabled key is left
out of the snapshot sent to data planes, so the gateway answers it with
`401 invalid_api_key`, the same as a key that does not exist (a key over
its budget gets `402 budget_exceeded` instead). Its usage stays in the
ledger and it keeps its name.

### Rotate

```bash
curl -X POST http://127.0.0.1:4000/admin/keys/my-app/rotate -H "Authorization: Bearer dev-admin-token-change-me"
```

`200` with the key record and a new `key`, again shown only once. The old
secret stops working as soon as the data planes have polled; there is no
overlap period in which both work. The record is kept: spend, budget and
media jobs made under earlier secrets still belong to the key, so a job
created before the rotation can be fetched with the new secret. The hashes
of the 50 most recent earlier secrets are remembered for this (and are
never accepted again).

### Delete

```bash
curl -X DELETE http://127.0.0.1:4000/admin/keys/my-app -H "Authorization: Bearer dev-admin-token-change-me"
```

`200` with `{"deleted": "my-app"}`. The gateway then answers the key with
`401`. Its usage events stay in the ledger, but they no longer appear
under a name in listings and metrics, and its media jobs can no longer be
fetched through the gateway. Creating a new key with the same name later
does not bring them back: the new key has a new secret and a new hash.

### Errors

Admin API errors have the same shape as every other error of the gateway:

```json
{"error": {"message": "a key named \"my-app\" already exists", "type": "invalid_request_error", "param": null, "code": "key_exists"}}
```

The reason is in `error.code`; `error.type` is a broader, OpenAI-style
category. (Until commit 10bc009 the control plane answered
`{"error": {"type": "<reason>", "message": "..."}}`; a script that matched
on `error.type` must match on `error.code` now.) The message texts are for
people and may change. Every response also carries an `x-request-id`
header.

| Status | `error.code` | When |
|---|---|---|
| 400 | `invalid_request` | A missing or malformed `name`, or a field with a bad value. Also any request whose path contains a percent-encoded character: `/admin/keys/my%2Dapp` is refused, `/admin/keys/my-app` is the only spelling. Key names never need encoding. |
| 400 | `invalid_json` | The body is not valid JSON. |
| 401 | `unauthorized` | No valid admin token or session. |
| 403 | `csrf_failed` | A session-authenticated change without the CSRF token; see [below](#csrf-scripts-and-browsers). |
| 404 | `key_not_found` | No key has this name. |
| 409 | `key_exists` | Create: the name is taken, by a managed or a file key. |
| 409 | `read_only_key` | Change, rotate or delete of a key that is defined in the config file. |
| 429 | `too_many_attempts` | Too many wrong bearer tokens from this address within a minute; see [Two ways in](#two-ways-in). |
| 500 | `storage_error` | The keys file could not be written; nothing was changed. |
| 500 | `internal_error` | An unexpected failure. The error has a `request_id` (the value of the `x-request-id` header) that is also in the control plane's log. |

An unknown path under `/admin` answers `401` without the admin token and
`404 not_found` with it. The errors every control-plane request can get are
listed in [API](api.md#errors-and-request-paths).

## Budgets and periods

A key with `budget_usd` is blocked once its recorded spend **in the current
budget period** reaches the budget.

| `budget_period` | Spend that counts | Unblocks |
|---|---|---|
| `total` (default) | Everything the key ever spent | Only when you raise or remove the budget |
| `monthly` | The current calendar month, UTC | By itself at 00:00 UTC on the first of the next month |
| `daily` | The current day, UTC | By itself at 00:00 UTC |

- Both key sources take both fields: `budget_usd` and `budget_period` in a
  `keys[]` entry of the config file, or in a create or `PATCH` call for a
  managed key.
- An event counts in the period of its own time (when the request finished
  on the data plane, in UTC), not of the moment it reached the ledger.
- Listings show `period_spend_usd` and `period_resets_at` (`null` for a
  total budget); `/metrics` has `omnigate_key_period_cost_usd`.
- A blocked key may not start anything new: text requests and
  `POST /v1/jobs` answer `402 budget_exceeded`. It keeps read access to what
  it already has: `GET /v1/models`, fetching and listing its jobs,
  downloading its files, and cancelling a job.
- Enforcement is after the fact, as before: the call that crosses the
  budget completes, and the data plane learns of the block with its next
  config poll. The same lag applies to unblocking when a period turns.

What spend is made of, including prompt-cache token prices, is in
[Operations](operations.md#budgets).

## The audit log

Every state-changing admin action appends one JSON line to
`OMNIGATE_AUDIT_LOG` (default `data/audit.jsonl`; `/data/audit.jsonl` in the
container image) and is synced to disk before the action's response is
sent. Failed and throttled sign-ins are the exception: they are counted and
summed up, as described [below](#failed-and-throttled-sign-ins).

```json
{"ts": "2026-11-10T18:02:11Z", "action": "key.update", "target": "my-app", "auth": "token", "address": "203.0.113.7", "outcome": "ok", "fields": ["budget_usd", "rpm"]}
```

| Field | Meaning |
|---|---|
| `ts` | UTC time, to the second. |
| `action` | `key.create`, `key.update`, `key.rotate`, `key.delete`, `login`, `logout`. |
| `target` | The key name as it was sent, cut to 64 characters, or `null`. |
| `auth` | How the caller was authenticated: `token` (bearer), `session` (dashboard), `password` (a login attempt) or `none`. A key action can no longer be recorded with `none`: the admin API is not reachable without a credential. An older entry that says so was made through the bypass described in [SECURITY.md](../SECURITY.md#past-advisories). |
| `address` | The address the caller is counted under, the same one the lockouts use, on every line, summary lines included: the peer of the connection, or with `OMNIGATE_TRUST_FORWARDED` (which `compose.yaml` sets) the last hop of `X-Forwarded-For`; an IPv6 address by its /64 (`2001:db8:1:2::`). Until the close-out commit an ordinary line had the peer here, which behind the Compose proxy was always the proxy. |
| `peer` | The address at the other end of the connection, written only when it differs from `address`: the proxy, behind a trusted one, or the full IPv6 address. Never on a summary line. |
| `forwarded_for` | Present when the request had an `X-Forwarded-For` header: the first 400 bytes of its value, made one line of valid UTF-8 and cut to 200 characters. A direct caller can fake it, so it is recorded, not trusted. |
| `outcome` | `ok`, or the error's reason, its `error.code` (`invalid_request`, `key_exists`, `read_only_key`, `key_not_found`, ...). For logins: `ok`, `denied` or `throttled`. |
| `fields` | For `key.update`: the names of the fields that were sent (sorted, at most 20), never their values. |
| `privacy` | For a `key.create` or `key.update` that set the key's [privacy mode](privacy.md): what it became, in a few words (`no-store, redact, unlink, encrypt`), or `off`. The `encrypt_to` recipient itself is never written. |
| `repeats` | Only on a summary line: how many more sign-in attempts with this outcome the address made in that minute, beyond the one that has its own line. |

What is and is not recorded:

- Failed attempts are recorded too (a refused create, a wrong password, a
  sign-in refused by the lockout). Failed and throttled sign-ins are
  counted rather than written one by one.
  Requests refused before they reach a handler are not recorded: a change
  without a valid admin token (`401`), one refused by the bearer-token
  lockout (`429`), one without the CSRF token (`403`) or a sign-in form
  over 4,096 bytes (`413`) leaves no line. Wrong bearer tokens are counted
  for the lockout but never written here, on any path.
- A logout is recorded only when it ends a session.
- Reads (`GET`) are not recorded.
- Never a key, a token, a password or a webhook secret.
- Every text value in an entry is made valid UTF-8 before the entry is
  encoded (invalid bytes become U+FFFD), and in `forwarded_for` control
  characters, line breaks included, become spaces. Bytes a caller chose
  can therefore neither start a line of their own nor stop the log. An
  entry that still cannot be encoded is left out and reported in the
  control plane's log.
- If the line cannot be written (a full disk, say), the action is still
  carried out and the control plane logs an error.

Read the newest entries, newest first:

```bash
curl "http://127.0.0.1:4000/admin/audit?limit=20" -H "Authorization: Bearer dev-admin-token-change-me"
```

`{"entries": [...]}`. `limit` is between 1 and 500 and defaults to 50. The
control plane keeps the newest 500 entries in memory for this; older ones
are only in the files. At start the list is reloaded from the live file
alone, so right after a rotation and a restart it can be shorter.

**Rotation.** When the next line would take the file past
`OMNIGATE_AUDIT_MAX_MB` (50 by default), `audit.jsonl` is renamed to
`audit.jsonl.1`, an existing `.1` becomes `.2`, `.2` becomes `.3`, and an
existing `.3` is deleted. Three older files are kept, so the log holds
about four times the limit at most, and entries older than that are gone:
copy the files elsewhere if you need them for longer. `0` turns rotation
off and the file grows without bound. The file is opened for each entry,
so you can also move or rotate it from outside at any time without
restarting the control plane.

### Failed and throttled sign-ins

A failed sign-in (`denied`) or one refused by the lockout (`throttled`) is
something anyone who can reach the form can cause, as often as they like.
So these do not get one line each (until commit d79406b they did):

- The first such attempt from an address in a minute is written as an
  ordinary line. The sign-in request does not wait for it, and the line is
  not synced by itself.
- Further attempts from that address with the same outcome in the same
  minute are only counted.
- When the minute is over, one summary line says how many more there were.
  It is written, and synced, within 15 seconds after the minute ends. An
  address with a single attempt gets no summary line.

```json
{"ts": "2026-11-10T18:03:00Z", "action": "login", "target": null, "auth": "password", "address": "203.0.113.7", "outcome": "denied", "repeats": 418}
```

An address therefore costs at most two lines per outcome and minute: at
most four a minute, whatever it sends.

- **The minute** is the clock minute, not the lockout's minute, which
  starts with the first failure. A summary line's `ts` is the end of the
  minute it sums up.
- **The address** the attempts are grouped by is the one the lockout
  counts: the peer, or with `OMNIGATE_TRUST_FORWARDED` the last hop of
  `X-Forwarded-For`, and an IPv6 address by its /64. Both lines carry it
  in `address`, so the first line and its summary can be matched up; the
  first line also has `peer` (when that differs) and `forwarded_for`, the
  summary has neither. (Until the close-out commit the first line had the
  peer in `address`, so behind the Compose proxy the two lines for one
  client named different addresses.)
- **A cap on what is followed.** At most 2,000 combinations of address and
  outcome are counted at a time. Attempts beyond that are counted together
  under the address `"(others)"`, which gets its own first line (without
  `peer` and `forwarded_for`) and its own summary line.
- The counts are in memory until their summary line is written. A clean
  stop of the control plane (`docker stop`, a restart of the audit
  process) writes the summary lines of every count it still holds, the
  running minute included; such a line's `ts` is the time of writing, not
  the end of the minute. A kill, or a crash of the whole runtime, still
  loses those counts. (Until the close-out commit every stop lost them.)
- Because repeats are only counted, a flood of failed sign-ins does not put
  a queue of synced writes in front of an operator's own action. A
  successful sign-in is an ordinary entry: one line, synced before the
  answer.

## CSRF: scripts and browsers

Requests that change something (`POST`, `PATCH`, `DELETE` on `/admin/*`, and
`POST /logout`) are protected against cross-site request forgery. Which
rule applies depends on how the request is authenticated:

- **Bearer token: nothing extra to send.** A browser never attaches an
  `Authorization` header on its own, so a request that carries the admin
  token cannot have been forged by another site. Every `curl` example on
  this page works as written.
- **Session cookie: a CSRF token is required.** The dashboard page carries
  the token for its session in `<meta name="csrf" content="...">` and sends
  it back in the `x-csrf-token` header (its sign-out form sends it as the
  form field `_csrf`). Without it the answer is `403 csrf_failed`. The token
  is derived from the session cookie, so it is different for every session
  and nothing is stored on the server.
- **Both at once: the session rule applies.** A request that carries a
  valid session cookie is treated as a session request, whatever its
  `Authorization` header says, so it needs the CSRF token even when it also
  sends the admin token. (Until commit d79406b the bearer token won.) A
  script should send the token and no cookie.

If you script against the admin API, use the bearer token. Driving it with
a session cookie works only if the script also reads the token out of the
dashboard page, which is not a stable interface. `GET` requests need no
CSRF token either way.

## Admin API reference

All on the control plane's port, all behind the admin token or a session.

| Method and path | Purpose |
|---|---|
| `GET /admin/keys` | Every key with its usage. |
| `POST /admin/keys` | Create a managed key. `201`, with the key itself. |
| `PATCH /admin/keys/{name}` | Change a managed key: `budget_usd`, `budget_period`, `rpm`, `max_concurrent`, `models`, `max_open_jobs`, `max_jobs_per_day`, `webhook_secret`, `disabled`, `privacy` ([Privacy mode](privacy.md#switching-it-on)). |
| `POST /admin/keys/{name}/rotate` | Give a managed key a new secret. `200`, with the new key. |
| `DELETE /admin/keys/{name}` | Delete a managed key. |
| `GET /admin/usage` | The same document as `GET /admin/keys`. |
| `GET /admin/overview` | Everything the dashboard shows, as one JSON document. |
| `GET /admin/audit?limit=N` | The newest audit entries. |
| `GET /metrics` | Prometheus metrics; see [API](api.md#get-metrics). |

`GET /admin/overview` is the feed the dashboard polls. Its top-level fields:

| Field | Content |
|---|---|
| `generated_at` | UTC time the document was built. |
| `totals`, `today` | `requests`, `errors`, `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `cached_responses`, `jobs`, `cost_usd`; over the whole ledger, and for the current UTC day. |
| `keys` | As `GET /admin/keys`, shadowed keys included. |
| `requests` | Up to 25 text requests, taken from the 50 newest ledger events. Each has the request's `id` (the `x-omnigate-request-id` the client was given) and `estimated`, which is `true` when its token counts are an estimate because the response ended before the provider's final usage arrived. |
| `jobs` | The 25 newest media jobs, with output URLs and webhook state. |
| `rejected` | Up to 50 `{key, reason, count}` series of refused requests, largest first. |
| `redactions` | Up to 50 `{key, class, count}` series: values [privacy mode](privacy.md#redaction) replaced before a provider saw them. Counts only. |
| `audit` | The 10 newest audit entries. |
| `config` | The read-only configuration view: upstreams by host, routes, media, storage, retention (`jobs_days`, `ledger_ids_days`, `ledger_days`, `delete_bucket_objects`, `private_outputs_hours`). |

It is the dashboard's own feed rather than a versioned interface: expect its
shape to follow the dashboard.
