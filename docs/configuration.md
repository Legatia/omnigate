# Configuration

Two things configure omnigate:

- **One JSON file**, read by the control plane. It holds gateway keys,
  upstreams, routes, the media section and retention.
- **Environment variables** for each process: addresses, tokens, file paths,
  timeouts, and every provider secret.

Gateway keys can also be created at run time through the admin API or the
dashboard. Those live in a separate keys file, not in the config file; see
[Admin](admin.md#gateway-keys-two-sources).

Provider secrets are never in the JSON file. Each upstream names an
environment variable (`api_key_env`) and the process that calls that provider
reads it: text upstream keys are read by the **data plane**, media upstream
keys and bucket credentials by the **control plane**.

Contents:

- [The config file](#the-config-file)
  - [Gateway keys](#gateway-keys)
  - [Text upstreams](#text-upstreams)
  - [Text routes](#text-routes)
  - [Response cache](#response-cache)
  - [Retention](#retention)
  - [Media](#media)
- [Environment variables](#environment-variables)
- [What the data plane receives](#what-the-data-plane-receives)

## The config file

The control plane loads the file named by `OMNIGATE_CONFIG` at startup and
checks its modification time every 2 seconds. When the file changes it is
loaded again; no restart is needed. The data plane picks the change up on its
next poll (`OMNIGATE_POLL_MS`, 2 seconds by default).

Behaviour on a bad file:

- **At startup**, a file that is missing, is not valid JSON, lacks a required
  field or has an invalid value stops the control plane from starting.
- **On reload**, the control plane logs
  `config reload failed, keeping previous: ...` and keeps serving the previous
  config. It does not try that version of the file again; fix the file and
  save it.

Templates: [`config/omnigate.dev.json`](../config/omnigate.dev.json) (mock
providers, used by the quickstart) and
[`config/omnigate.example.json`](../config/omnigate.example.json) (real
providers; replace every `<...>` placeholder).

Top-level shape:

```json
{
  "keys": [],
  "upstreams": [],
  "routes": [],
  "media": {},
  "retention": {}
}
```

Every top-level section is optional and defaults to empty.

### Gateway keys

`keys[]` are the credentials applications present to the data plane. Keys
written here are "file keys": they are read-only for the admin API, and are
listed before the managed keys created through it
([Admin](admin.md#gateway-keys-two-sources)).

| Field | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | required | Label shown in the dashboard, the admin API, the access log and metrics. Give every key its own name. The admin API refuses a managed key whose name a file key already has. The other way round, a file key added under the name of an existing managed key takes over: the file key is used and the managed key is shadowed ([Admin](admin.md#gateway-keys-two-sources)). |
| `key` | string | one of `key` / `key_sha256` is required | The key in clear text. Hashed on load. Meant for local development. |
| `key_sha256` | string | | Lowercase hex SHA-256 of the key. If both fields are present, this one is used. |
| `budget_usd` | number, 0 or more | none (no budget) | The key is blocked once its recorded spend in the current budget period reaches this amount. A negative value, or one that is not a number, is rejected when the file is loaded. See [Operations](operations.md#budgets). |
| `budget_period` | string | `total` | What the budget covers: `total` (everything, never resets), `monthly` (the current UTC calendar month) or `daily` (the current UTC day). Any other value is rejected when the file is loaded. |
| `rpm` | whole number, 0 to 1,000,000 | `0` (unlimited) | Requests per minute, enforced by each data-plane process. Job creation is counted a second time by the control plane; see [Operations](operations.md#rate-limits). A value that is not a whole number in that range (`600.0` and `"600"` included) is rejected when the file is loaded. |
| `max_concurrent` | whole number, 0 to 1,000,000 | `0` (the data plane's `OMNIGATE_MAX_CONCURRENT_PER_KEY`) | Requests the key may have in flight at once on one data-plane process, in place of that process's `OMNIGATE_MAX_CONCURRENT_PER_KEY` (512). One more gets `429 concurrency_limit_exceeded`. `0` means the key has no cap of its own; it cannot switch the cap off. A value that is not a whole number in that range is rejected when the file is loaded. |
| `models` | list of strings | absent (all models) | Route names, text or media, the key may use. An empty list allows none. Anything other than a list of strings is rejected when the file is loaded. |
| `max_open_jobs` | whole number, 0 or more | absent (the value of `media.max_open_jobs`) | Media jobs the key may have unfinished (queued or running) at one time. `0` means no limit. Anything else is rejected when the file is loaded. See [Operations](operations.md#rate-limits). |
| `max_jobs_per_day` | whole number, 0 or more | absent (the value of `media.max_jobs_per_day`) | Media jobs the key may create per UTC day, whatever became of them. `0` means no limit. Anything else is rejected when the file is loaded. See [Operations](operations.md#rate-limits). |
| `disabled` | boolean | `false` | `true` switches the key off without removing it: the gateway answers it with 401, and its usage stays in the ledger. |
| `webhook_secret` | string | none | Signing secret for this key's job webhooks. |
| `webhook_secret_env` | string | none | Name of an environment variable (read by the control plane) holding that secret. Used when `webhook_secret` is absent. |

`max_concurrent` is new with the close-out commit (the one after
55a294d). Until then every key had the data plane's
`OMNIGATE_MAX_CONCURRENT_PER_KEY` (see [Environment variables](#data-plane))
and nothing else; a key without the field still does.

A key is any string; it is only ever compared by its SHA-256. The LiteLLM
importer generates keys as `og-` followed by random characters, which is a
reasonable convention:

```bash
python -c "import secrets; print('og-' + secrets.token_urlsafe(32))"
```

To get the value for `key_sha256`:

```bash
python -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" 'og-your-key-here'
```

The hash must be lowercase hex, which is what the command prints.

Example:

```json
{
  "name": "my-app",
  "key_sha256": "<sha256 hex of the gateway key you hand to the app>",
  "budget_usd": 25.0,
  "budget_period": "monthly",
  "rpm": 600,
  "max_concurrent": 64,
  "max_open_jobs": 20,
  "max_jobs_per_day": 2000,
  "models": ["claude", "gpt", "gemini", "image"],
  "webhook_secret_env": "MY_APP_WEBHOOK_SECRET"
}
```

### Text upstreams

`upstreams[]` are the LLM providers the data plane forwards to.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | required | Referenced by route targets; reported in `x-omnigate-upstream`. |
| `kind` | string | required | `openai` or `anthropic`: the protocol the provider speaks. |
| `base_url` | string | required | Scheme and host, without the `/v1` path (for example `https://api.openai.com`). A trailing slash is ignored. |
| `api_key_env` | string | required | Environment variable, read by the **data plane**, holding the provider key. |
| `timeout_ms` | whole number, 0 to 3,600,000 | `0` | Maximum wait for the provider's response headers. `0` uses the data plane's `OMNIGATE_UPSTREAM_TIMEOUT_MS`. |
| `v1_path` | string | absent (`/v1`) | For providers that do not serve the API under `/v1`: the leading `/v1` of the request path is replaced by this value. Gemini's OpenAI-compatible endpoint uses `/v1beta/openai`. An empty string puts the API at the root. |

How the key is sent: `openai` upstreams get `Authorization: Bearer <key>`;
`anthropic` upstreams get `x-api-key: <key>` and an `anthropic-version`
header (the client's, or `2023-06-01` if the client sent none). If the named
variable is not set in the data plane's environment, an empty key is sent and
the provider will refuse the request.

`kind` is checked when the file is loaded: a value other than `openai` or
`anthropic` is refused with a message naming the upstream (at startup the
control plane does not start; on a reload the previous config stays in
force). Media providers do not go here; they go under `media.upstreams`.

### Text routes

`routes[]` map the model name a client sends to one or more targets.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `model` | string | required | The name clients put in `"model"`. |
| `strategy` | string | `failover` | `failover`, `round_robin` or `weighted`. Any other value is rejected when the file is loaded. |
| `cache_ttl_s` | whole number, 0 to 31,536,000 (a year) | `0` (off) | Seconds the data plane may answer an identical request from its own memory instead of calling a provider. See [Response cache](#response-cache). |
| `targets` | list | required | Tried in the order the strategy gives; see below. |

Each target:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `upstream` | string | required | Name of an entry in `upstreams[]`. |
| `model` | string | required | The provider's model id. Replaces `"model"` in the forwarded request. |
| `weight` | whole number, 0 to 1,000,000 | `1` | Used by `weighted` only. `0` means never first, but still a fallback. |
| `price_in_per_mtok` | number, 0 or more | `0` | US dollars per million input tokens that were not served from the provider's prompt cache. |
| `price_cached_in_per_mtok` | number, 0 or more | the value of `price_in_per_mtok` | US dollars per million input tokens read from the provider's prompt cache. |
| `price_cache_write_per_mtok` | number, 0 or more | the value of `price_in_per_mtok` | US dollars per million input tokens written to the provider's prompt cache (Anthropic-style upstreams report these). |
| `price_out_per_mtok` | number, 0 or more | `0` | US dollars per million output tokens. |

A config that sets only the input and output prices bills every input token
at the input price, cached or not. How the four token counts are told apart
is in [Operations](operations.md#budgets).

**Whole-number settings are read strictly.** `rpm`, `timeout_ms`,
`cache_ttl_s` and `weight` go into 32-bit fields in the data plane, where
one value that does not fit makes the whole snapshot unreadable. Each is
therefore a whole number within the range in its table, and so are the
whole-number settings of the `media` section below. A fraction (`600.0`), a
string, a negative number or a value above the range is rejected when the
file is loaded, with a message that names the setting; until commit d79406b
a fraction was cut to a whole number without a word. A price above
1,000,000,000, or a `budget_usd` above 1,000,000,000,000, is rejected too.

A usage event for a route or target the config does not have (or no longer
has) is recorded at $0, counted in `omnigate_ledger_unpriced_events_total`
and logged once per route and target.

Strategies:

- `failover`: config order. The first target takes all the traffic; the
  others are used when it fails.
- `round_robin`: the starting target rotates with every request; the rest
  follow in ring order as failover.
- `weighted`: the starting target is drawn at random in proportion to each
  target's `weight`; the rest follow in config order as failover. At least
  one target must have a weight above 0.

Whatever the strategy, targets whose upstream is cooling down after repeated
failures are moved to the end of the order. Rotation counters and cooldowns
live in memory in each data-plane process.

A route may mix `openai` and `anthropic` upstreams. For
`/v1/chat/completions` and `/v1/messages` the gateway translates when the
target speaks the other protocol; for the other endpoints a target of the
other protocol is skipped (`protocol_mismatch`), and if that leaves no
target at all the request is refused with `400 endpoint_not_supported`.

Example with two providers behind one name:

```json
{
  "model": "claude",
  "strategy": "weighted",
  "targets": [
    { "upstream": "anthropic", "model": "claude-sonnet-5-5", "weight": 3, "price_in_per_mtok": 2.0, "price_cached_in_per_mtok": 0.1, "price_out_per_mtok": 10.0 },
    { "upstream": "openai", "model": "<openai model id>", "weight": 1, "price_in_per_mtok": 0.0, "price_out_per_mtok": 0.0 }
  ]
}
```

The prices above are the ones in `config/omnigate.example.json`; check them
against your provider's price list before relying on the spend figures.

### Response cache

A text route with `cache_ttl_s` above 0 lets each data plane remember
successful answers and reuse them:

```json
{ "model": "faq", "cache_ttl_s": 600, "targets": [ { "upstream": "openai", "model": "<openai model id>" } ] }
```

- **What is cached.** Non-streaming answers with a 2xx status on the metered
  endpoints (`/v1/chat/completions`, `/v1/messages`, `/v1/completions`,
  `/v1/embeddings`, `/v1/responses`). Requests with `"stream": true` are
  never looked up or stored.
- **What counts as the same request.** The same gateway key, the same route
  name, the same endpoint path and the same JSON body. Key order inside
  objects and whitespace do not matter; array order and every value do. The
  match is exact: there is no semantic matching.
- **Never across keys.** The gateway key is part of the identity, so one key
  is never served an answer another key paid for.
- **Checks still apply.** A hit is looked up after authentication, the
  budget, the key's concurrency and memory limits, the rate limit and the
  model list, and counts against the rate limit like any request.
- **Some requests are never cached.** The cache key is the request in
  canonical form, which takes parsing it into a tree. A body with more than
  1,024 members in one object, or one whose tree would pass its memory cap
  or the tree budget (see `OMNIGATE_PARSE_MEMORY_MB`), is served normally
  but neither looked up nor stored, and its response carries no
  `x-omnigate-cache` header.
- **Billing.** A hit is recorded in the ledger as a request with no tokens
  and no cost, marked as served from cache.
- **Bounds.** The cache lives in the memory of each data-plane process:
  `OMNIGATE_CACHE_MAX_MB` (64 by default; `0` turns caching off whatever the
  routes say). The least recently used answers are evicted first, an answer
  larger than a quarter of that budget is not kept, and a restart starts
  empty. Several data planes each have their own cache.
- There is no per-request switch; a client cannot opt out or force a
  refresh. Removing `cache_ttl_s` from the route stops lookups as soon as
  the data planes have polled the new config.

Responses carry `x-omnigate-cache: hit` or `miss`; see
[API](api.md#response-cache). This is separate from the media job cache
(`media.routes[].cache_ttl_s`, below), which stores output files in the
control plane and is shared across keys.

### Retention

```json
"retention": { "jobs_days": 30, "ledger_ids_days": 3, "ledger_days": 90, "delete_bucket_objects": true }
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `jobs_days` | number, fractions allowed | `0` (keep forever) | Finished jobs older than this are removed, with their output files: on local disk, and in the bucket unless `delete_bucket_objects` is `false`. |
| `ledger_ids_days` | number, fractions allowed | `3` | The ledger forgets the duplicate-detection ids of whole UTC days that ended longer ago than this, so an id is kept for at least this long and at most a day longer. An explicit `0` keeps them for ever. The default was 14 until commit d79406b. |
| `ledger_days` | number, fractions allowed | `0` (keep forever) | Sealed ledger segments (the history of usage events) last written longer ago than this are deleted. Spend totals are not affected: they are carried in the ledger's snapshots. |
| `delete_bucket_objects` | boolean | `true` | Whether a removed job's objects are also deleted from an S3-compatible bucket. Only has an effect when `jobs_days` is set. Anything but `true` or `false` is rejected when the file is loaded. |

No job, file or ledger segment is deleted unless you set these. The one
setting with a default is `ledger_ids_days`: with no `retention` section at
all, duplicate-detection ids older than 3 days are dropped from memory and
their per-day files (`ledger.ids.YYYY-MM-DD`) are deleted. That touches no
total and no file of events; what it costs, and when to raise it, is
described in [Operations](operations.md#retention). A negative number, or a value that
is not a number, for one of the three `_days` fields is rejected when the
file is loaded. Details and caveats are in
[Operations](operations.md#retention); read the one about `ledger_days` and
backups before you set it.

### Media

The `media` section configures async jobs. It never leaves the control
plane (apart from the route names, which data planes list in
`GET /v1/models`).

| Field | Type | Default | Meaning |
|---|---|---|---|
| `public_base_url` | string | `http://127.0.0.1:8080` | The address clients use to reach the gateway. Output URLs for locally stored files start with it. |
| `poll_interval_ms` | whole number, 1 to 3,600,000 | `2000` | How often a running job polls its provider. |
| `max_output_bytes` | whole number, 1 to 1,099,511,627,776 (1 TiB) | `536870912` (512 MiB) | Largest single output file the gateway will download and store. A provider that answers with the media inline (base64 in JSON, or raw bytes) is read up to four thirds of this plus 64 KiB, and never more than 256 MiB; that answer is held in memory. |
| `max_input_bytes` | whole number, 1 to 8,000,000 | `1048576` (1 MiB) | Largest `input` and `metadata` of one job, measured together as JSON. A larger request is refused with `413 payload_too_large`. Both are kept on disk for as long as the job is; an input over 8 KiB goes into a file of its own next to the job log (`<OMNIGATE_JOBS>.inputs/<job id>.json`). |
| `max_open_jobs` | whole number, 0 or more | `100` | Unfinished jobs (queued or running) one gateway key may have at a time; a key can set its own `max_open_jobs`. `0` means no limit. One job more is refused with `429 too_many_open_jobs`. Anything but a whole number of 0 or more is rejected when the file is loaded. |
| `max_jobs_per_day` | whole number, 0 or more | `10000` | Jobs one gateway key may create per UTC day; a key can set its own `max_jobs_per_day`. `0` means no limit. One job more is refused with `429 too_many_jobs_today`. It bounds what the open-jobs limit does not: jobs that end at once (a refused input, a provider that is down) and still cost a log line, a ledger event and a webhook call each. |
| `upstreams` | list | `[]` | Media providers. |
| `routes` | list | `[]` | Media models. |
| `storage` | object | local disk | Where outputs are stored. |
| `webhooks` | object | see below | Webhook signing and retries. |

#### `media.upstreams[]`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | required | Referenced by media route targets. |
| `kind` | string | required | One of `replicate`, `fal`, `openai_images`, `elevenlabs`, `gemini`, `gemini_interactions`, `xai_video`. See [Providers](providers.md#media-providers). |
| `base_url` | string | required | Provider API base, for example `https://api.replicate.com`. A trailing slash is ignored. |
| `api_key_env` | string | required | Environment variable, read by the **control plane**, holding the provider key. |

An unknown `kind`, or a key variable that is not set, does not stop the file
from loading. A job that reaches such a target records the attempt as
`unsupported_kind:<kind>` or `missing_api_key_env:<VARIABLE>` and moves on to
the next target.

#### `media.routes[]`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `model` | string | required | The name clients put in `"model"` when creating a job. |
| `cache_ttl_s` | integer | absent | When set, identical requests reuse a stored output for this many seconds, unless the request says `"cache": false`. See [API](api.md#caching). |
| `timeout_s` | whole number, 1 to 604,800 | `600` | How long one target gets before the job moves to the next. Also the HTTP timeout for providers that answer in one call. |
| `allowed_input` | list of strings | absent (any field) | The top-level `input` fields a job on this route may carry. A job with any other field is refused with `400 invalid_request` instead of being forwarded: providers bill for options (a quality, a size, a number of outputs) that your price does not know about. |
| `price_multipliers` | object | absent | Factors on the job's price by the value of an input field; see [Price multipliers](#price-multipliers). |
| `targets` | list | required | Tried in order. |

Each target has `upstream`, `model` (the provider's model id), an optional
`price` object and, for per-second prices, three optional settings:

| Target field | Type | Default | Meaning |
|---|---|---|---|
| `default_seconds` | number above 0 | absent | The duration billed when the request names none. Without it, a job on a route with a `per_second_usd` price must send `input.duration` (or `input.seconds`) above 0, or it is refused with `400 invalid_request`. **Required** on a per-second target whose upstream is never sent a duration (see below). |
| `min_seconds` | number, 0 or more | absent | The least duration billed, whatever the request says. |
| `max_seconds` | number, 0 or more | absent | A request for more than this is refused with `400 invalid_request`. |

`min_seconds` above `max_seconds`, `default_seconds` above `max_seconds`
and a `default_seconds` of 0 are rejected when the file is loaded.

**Per-second prices and providers that take no duration.** Only the video
kinds (`replicate`, `fal`, `xai_video`) are sent a duration from the
request. An upstream of kind `openai_images`, `elevenlabs`, `gemini` or
`gemini_interactions` never is, so there a `per_second_usd` price has
nothing from the request to multiply: the job is billed
`default_seconds` (raised to `min_seconds`), whatever `input.duration`
says, and `max_seconds` refuses nothing. A per-second price on such a
target **without** `default_seconds` is rejected when the file is loaded
(since the close-out commit; before, such a job was refused or billed
nothing per second depending on the request). Set `default_seconds`, or
price the target with `per_job_usd` or `per_output_usd`.

The
three only matter on a target whose `per_second_usd` is above 0. They
change what is billed and what is accepted, not what is sent to the
provider, and a job is checked against every per-second target of its route
when it is created, not only the one that ends up delivering.

All four price fields default to `0` and are added together. A price that
is negative, or not a number, is rejected when the file is loaded. A target
with no price at all records its jobs at $0, which is counted in
`omnigate_ledger_unpriced_events_total` and logged once per target.

| `price` field | Charged |
|---|---|
| `per_job_usd` | Once per successful job. |
| `per_output_usd` | Per output file stored. |
| `per_second_usd` | Times the seconds the adapter asks the provider for, or the target's `default_seconds` when the request names none; never less than `min_seconds`. |
| `per_input_char_usd` | Times the characters of text the adapter sends to the provider. |

Seconds and characters are counted from **what the adapter sends**, not
from one field the client chose to fill in, so a request cannot lower its
own price by moving its text or its duration into another field:

| Adapter (`kind`) | Characters counted | Seconds counted |
|---|---|---|
| `replicate`, `fal`, `xai_video` | `input.prompt`, `input.text` and `input.input`, each when it is a string, added together (the whole `input` goes to the provider) | The larger of `input.duration` and `input.seconds` (a number, a string that is one, or a number followed by `s`: `5`, `"5"`, `"5s"`) |
| `openai_images` | `input.prompt` | none |
| `elevenlabs` | `input.text` | none |
| `gemini` | Every `text` part of the request's `contents` and `systemInstruction`, whether it came from the short form (`prompt`, else `text`) or from a native body | none |
| `gemini_interactions` | The request's `input` (a string, or every `text` inside it) and `system_instruction` | none |

For the adapters that send no duration, the seconds of a `per_second_usd`
price come from the target's `default_seconds` and `min_seconds` alone.
Each of the four parts is at least zero by itself. A job whose
`input.duration` or `input.seconds` is negative or not a duration, or whose
`input.n`, `input.num_outputs` or `input.num_images` is not a whole number
of 0 or more, is refused with `400 invalid_request` when it is created
([API](api.md#job-errors)).

Cost is the configured price of the target that delivered, times the
route's price multipliers. A failed or canceled job costs nothing in the
ledger, and a cache hit costs nothing.

##### Price multipliers

`price_multipliers` maps an input field to the factor each of its values
puts on the whole price of the job:

```json
"price_multipliers": {
  "quality": { "low": 1, "medium": 4, "high": 16, "default": 16 },
  "size": { "1024x1024": 1, "1024x1536": 1.5, "1536x1024": 1.5, "default": 1.5 }
}
```

- Each factor is a number from 0 to 1,000,000; the factors of several
  fields are multiplied together.
- A job that sends a listed field must use one of the listed values;
  anything else is refused with `400 invalid_request`, naming the allowed
  values. Numbers and booleans are matched by their text (`4` matches
  `"4"`).
- `"default"` is the factor for a job that does not send the field. Without
  a `"default"`, such a job is charged a factor of 1.
- If the config changes while a job runs and the job's value is no longer
  listed, the job is charged the highest factor of that field.
- An entry that is not an object of value to factor is rejected when the
  file is loaded.

Use it together with `allowed_input`, so that an option that changes what
the provider charges cannot be sent without the price following it.

#### `media.storage`

Local disk (the default):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `kind` | string | `local` | |
| `dir` | string | `OMNIGATE_MEDIA_DIR`, else `data/media` under the control plane's working directory | Files are stored as `<dir>/<job id>/<name>`. |
| `url_ttl_s` | whole number, 1 to 31,536,000 | `3600` | Lifetime of the signed download URLs handed to clients. |

S3-compatible bucket:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `kind` | string | | `s3` |
| `endpoint` | string | required | For example `https://s3.us-east-1.amazonaws.com`. Path-style URLs are used: `<endpoint>/<bucket>/<key>`. |
| `bucket` | string | required | |
| `region` | string | `us-east-1` | Cloudflare R2 uses `auto`. |
| `prefix` | string | none | Key prefix. `outputs` and `/outputs/` both mean `outputs/`. |
| `access_key_env` | string | required | Environment variable (control plane) with the access key id. |
| `secret_key_env` | string | required | Environment variable (control plane) with the secret key. |
| `presign_ttl_s` | positive integer | `3600`, unless `public_base_url` is set | Lifetime of the presigned GET URLs handed to clients. |
| `public_base_url` | string | `<endpoint>/<bucket>` | Set this without `presign_ttl_s` to hand out plain `<public_base_url>/<key>` URLs, for a public bucket or a CDN in front of it. |

Objects are stored under `<prefix><job id>/<name>`. The README records that
bucket storage was checked against Cloudflare R2 only; other S3-compatible
services, Amazon S3 included, have only met the mock.

#### `media.webhooks`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `secret` | string | none | Signing secret for keys that have none of their own. |
| `secret_env` | string | none | Environment variable (control plane) holding that secret. Used when `secret` is absent. |
| `retry_schedule_ms` | list of at most 50 whole numbers, each 0 to 2,592,000,000 (30 days) | `[5000, 30000, 120000, 600000, 1800000, 7200000, 21600000]` | Delay before each retry. |
| `max_attempts` | whole number, 1 to 100 | length of the schedule plus 1 | Total deliveries tried before giving up. An attempt is recorded before its request is sent, so one that a restart cuts short is used up. |
| `timeout_ms` | whole number, 1 to 600,000 | `10000` | How long the receiver gets to answer. Only the status of its answer is used; at most 16 KiB of the body are read. |
| `max_concurrent` | whole number, 1 to 10,000 | `16` | Webhook deliveries in flight at once, over all keys. The rest wait their turn, fairly across keys. |
| `max_concurrent_per_key` | whole number, 1 to 10,000 | `4` | Deliveries in flight at once for the jobs of one gateway key, so that one key's slow receiver cannot hold up everyone else's webhooks. |
| `allow_private` | boolean | `false` | Allow addresses that are not public: loopback, private, link-local and the other special-purpose ranges. It applies to webhook URLs **and** to the output URLs a provider returns, which the control plane downloads under the same rule. For local development, where the providers and receivers are mocks on the same machine. |

The secret used for a job is the first one that exists: the key's own
(`webhook_secret` / `webhook_secret_env`), then `media.webhooks.secret` /
`secret_env`, then the `OMNIGATE_WEBHOOK_SECRET` environment variable. A job
that asks for a webhook when none of these is set is refused
(`webhook_not_configured`).

## Environment variables

### Both processes

| Variable | Default | Meaning |
|---|---|---|
| `OMNIGATE_INTERNAL_TOKEN` | none | Shared secret for `/internal/*`, sent by the data plane in the `x-omnigate-internal` header. Must be the same on both sides. Required by both: without it (or with an empty value, which counts as not set) the data plane exits at startup and the control plane refuses to start, each with a log line that names the variable. |

### Data plane

| Variable | Default | Meaning |
|---|---|---|
| `OMNIGATE_LISTEN` | `127.0.0.1:8080` | IP address and port to listen on. |
| `OMNIGATE_CONTROL_URL` | `http://127.0.0.1:4000` | Base URL of the control plane. |
| `OMNIGATE_POLL_MS` | `2000` | How often the config is fetched. |
| `OMNIGATE_FLUSH_MS` | `500` | How often queued usage, and the counts of refused requests, are sent. |
| `OMNIGATE_UPSTREAM_TIMEOUT_MS` | `600000` | Maximum wait for upstream response headers. `0` means no limit. An upstream's `timeout_ms` overrides it. |
| `OMNIGATE_CLIENT_TIMEOUT_MS` | `30000` | How long a client may take to send a request (head and body), and how long an idle keep-alive connection is kept open. `0` means no limit. |
| `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` | `300000` | How long an **upstream** (or the control plane, for the jobs API and files) may send nothing after its response head. A response already being relayed is cut off, and the call is still billed: the provider's figures if they had arrived, otherwise an estimate. An answer of which nothing has reached the client yet (a non-streaming answer whose body does not come) counts as a failed attempt, `StreamIdleTimeout`, and the next target is tried; there the silence is noticed after between one and two times this value. `0` means no limit. Until commit e4e30e4 this also covered a client that read nothing; that is `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` now. |
| `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` | `30000` | A client that stays connected but takes none of a response for this long is given up on. That is every response written once the request has been read: a provider's answer, a file download, a jobs API answer, and (since the close-out commit) the gateway's own answers, such as errors, the model list and cache hits, which used to be written under the stream idle timeout. For a provider's answer the upstream is then read to its end without the client, as for one that disconnected. A refusal sent before the request body was read is under `OMNIGATE_CLIENT_TIMEOUT_MS`. `0` uses the value of `OMNIGATE_STREAM_IDLE_TIMEOUT_MS`. |
| `OMNIGATE_MAX_CONNECTIONS` | `4096` | Client connections served at once. Further connections get an immediate `503` (`overloaded`) and are closed. |
| `OMNIGATE_MAX_CONCURRENT_PER_KEY` | `512` | Requests one gateway key may have in flight at once, checked before a request body is read. One more gets `429 concurrency_limit_exceeded` with `retry-after: 1`. An upstream answer still being read after its client left counts until it is finished. `0` means no cap. A key's own [`max_concurrent`](#gateway-keys) takes its place for that key. |
| `OMNIGATE_REQUEST_MEMORY_MB` | `1024` (`256` under `compose.yaml`) | Memory all request bodies in flight may take together, by their declared length, each counted twice (as received and as sent on). One key may hold a quarter of it. Beyond the key's share a request gets `429 request_memory_exceeded`, beyond the whole budget `503 overloaded`, both with `retry-after: 1` and before the body is read. `0` means no cap. |
| `OMNIGATE_PARSE_MEMORY_MB` | `1024` (`256` under `compose.yaml`) | Memory that may be reserved at once for parsing JSON into trees, which only translation between protocols, the response cache, the fixes for provider quirks and rewriting an existing `stream_options` need. One tree may take 128 times its text plus 1 MiB, at most 96 MiB; a request that needs more gets `400 request_too_complex`. One key may reserve half the budget: beyond that `429 request_memory_exceeded`, beyond the whole budget `503 overloaded`. `0` means no budget (the per-tree cap still applies). |
| `OMNIGATE_ABORT_DRAIN_MS` | `120000` | When a client leaves or stalls in the middle of a response: how long the data plane keeps reading the upstream in the background to learn the provider's final token usage. If it arrives the call is billed those figures, otherwise an estimate. `0` bills the estimate at once. The default was `5000` until commit e4e30e4. See [Operations](operations.md#streams-that-end-early). |
| `OMNIGATE_ABORT_DRAIN_MAX_MB` | `64` | ... or until this many more megabytes of the answer have been read, whichever comes first. Until commit e4e30e4 this was a fixed 8 MiB. |
| `OMNIGATE_SHUTDOWN_GRACE_MS` | `10000` | After SIGINT or SIGTERM (Ctrl-C or Ctrl-Break on Windows): how long requests in flight may take to finish before they are cut off and the process exits. |
| `OMNIGATE_CACHE_MAX_MB` | `64` | Memory for the [response cache](#response-cache) of routes that set `cache_ttl_s`. `0` turns it off. |
| `OMNIGATE_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error` (`warning` and `err` are accepted too; case does not matter). |
| `OMNIGATE_LOG_FORMAT` | `text` | `text`, or `json` for one JSON object per line. See [Operations](operations.md#logs). |
| `OMNIGATE_COOLDOWN_FAILURES` | `5` | Consecutive failures before an upstream is tried last. `0` turns cooldowns off. |
| `OMNIGATE_COOLDOWN_MS` | `30000` | How long an upstream stays in that state. |
| `OMNIGATE_SPOOL` | `omnigate-usage.spool` | File for undelivered usage events. `off` keeps them in memory only. The file shrinks as events are acknowledged, and a file of any size never stops a start ([Operations](operations.md#when-the-control-plane-is-down)). |
| `OMNIGATE_CONFIG_CACHE` | `omnigate-config.cache.json` | Last config received, reused when starting while the control plane is down. `off` disables it. |
| the names in `upstreams[].api_key_env` | none | Provider keys for text upstreams. |

The spool and the config cache are relative to the data plane's working
directory unless given as absolute paths.

The three limits `OMNIGATE_MAX_CONCURRENT_PER_KEY`,
`OMNIGATE_REQUEST_MEMORY_MB` and `OMNIGATE_PARSE_MEMORY_MB` are checked
before a request body is read. The two memory settings are ceilings on what
the data plane admits, not on what the process uses in total: add the
response cache (`OMNIGATE_CACHE_MAX_MB`) and a few tens of megabytes of its
own. The binary's defaults (1024 + 1024 + 64) are meant for a host without
a memory limit. `compose.yaml` limits the data-plane container to 1 GiB
and therefore sets the three itself, to 256 + 256 + 64, from `.env`
([below](#compose-only)); see [Deployment](deployment.md#memory-limits).

`omnigate-dp healthcheck` is the binary's one subcommand: it asks the
address in `OMNIGATE_LISTEN` for `/healthz` and exits 0 if that answers 200
within three seconds, 1 otherwise. It reads no other variable, needs no
token and prints nothing; the container image's `HEALTHCHECK` runs it. Any
other argument stops the data plane with exit status 2.

**Numeric variables are read strictly.** A value must be a whole number
written in digits only, within the variable's range (the millisecond and
count settings go up to at least two billion; no sign, no `_`, no unit, no
decimal point). Anything else stops the data plane at startup with a
message that names the variable, as does a log level or format that is not
one of the values above, or an `OMNIGATE_LISTEN` without a valid port. A
numeric variable that is set but empty counts as unset. A typo never
quietly becomes a default.

### Control plane

| Variable | Default | Meaning |
|---|---|---|
| `OMNIGATE_ADMIN_TOKEN` | generated and logged at startup | Dashboard password, and bearer token for `/admin/*` and `/metrics`. A value that is set but shorter than 16 characters stops the control plane from starting, with a log line that says so (earlier commits only warned). Unset or empty, a random one is generated for the run. |
| `OMNIGATE_TRUST_FORWARDED` | unset | `1` or `true`: failed logins and wrong admin tokens are counted against the address in the last hop of `X-Forwarded-For` instead of the address of the connection. Set it only when every request arrives through a proxy that writes that header itself, as in `compose.yaml`; a client that can reach the control plane directly could otherwise choose the address it is counted under. It changes nothing else: an ordinary audit-log line still records the connection's address (the summary line that aggregates repeated failed sign-ins carries the address they were counted under). |
| `OMNIGATE_CONTROL_BIND` | `127.0.0.1` | IP address to listen on. Set an address such as `0.0.0.0` to accept connections from other machines. Must be an IP address, not a host name; anything else stops the start. |
| `OMNIGATE_CONTROL_PORT` | `4000` | Port to listen on: a whole number from 1 to 65535. Anything else stops the start, with a message that names the variable. |
| `OMNIGATE_COOKIE_SECURE` | unset | `1` always marks the session cookie `Secure`. This is automatic when the request arrives with `X-Forwarded-Proto: https`. |
| `OMNIGATE_CONFIG` | `../config/omnigate.dev.json` in a development build; required in a release build | Path of the config file. The development config, whose keys and webhook secret are published in this repository, stands in only when the control plane was compiled in the `dev` or `test` environment (`mix run`, as in the quickstart). A release (`MIX_ENV=prod`, which is what the container image builds) refuses to start without the variable, or with an empty one. |
| `OMNIGATE_LEDGER` | `data/ledger.jsonl` | The usage ledger's active segment. Sealed segments (`ledger.000001.jsonl`, ...), the snapshots (`ledger.snapshot`, `ledger.snapshot.prev`) and the per-day files of duplicate-detection ids (`ledger.ids.YYYY-MM-DD`) are written next to it and named after it. See [Architecture](architecture.md#ledger-files-segments-and-snapshots). |
| `OMNIGATE_JOBS` | `data/jobs.jsonl` | Job state. Job inputs over 8 KiB are kept next to it in the directory `<this path>.inputs/` (`data/jobs.jsonl.inputs/`), one file per job; it belongs to the job log and must be backed up with it. |
| `OMNIGATE_KEYS` | `data/keys.json` | Gateway keys created through the admin API or the dashboard: hashes, limits, and a key's webhook secret if it has one. See [Admin](admin.md#gateway-keys-two-sources). |
| `OMNIGATE_AUDIT_LOG` | `data/audit.jsonl` | The admin audit log. Rotated files (`.1` to `.3`) are kept next to it. See [Admin](admin.md#the-audit-log). |
| `OMNIGATE_AUDIT_MAX_MB` | `50` | Size, in megabytes (fractions allowed), at which the audit log is rotated. `0` turns rotation off. A negative value, or one that is not a number (`50MB`, say), stops the start with a message that names the variable; earlier commits replaced it by the default without a word. |
| `OMNIGATE_MEDIA_DIR` | `data/media` | Where local output storage keeps files, unless the config names a `dir`. |
| `OMNIGATE_SIGNING_SECRET` | derived from `OMNIGATE_INTERNAL_TOKEN` | Signs the download URLs of locally stored files. |
| `OMNIGATE_WEBHOOK_SECRET` | none | Last-resort webhook signing secret. |
| the names in `media.upstreams[].api_key_env` | none | Provider keys for media upstreams. |
| the names in `media.storage.access_key_env` / `secret_key_env` | none | Bucket credentials. |
| the names in `webhook_secret_env` / `media.webhooks.secret_env` | none | Webhook signing secrets. |

Relative defaults are resolved against the control plane's working
directory. When it is started from `control/` as in the quickstart, the
config default is the repository's `config/omnigate.dev.json` and state goes
to `control/data/`.

The control plane checks these before it opens its port, and logs the
reason and stops if one fails: `OMNIGATE_INTERNAL_TOKEN` is set, the
numeric variables (`OMNIGATE_CONTROL_PORT`, `OMNIGATE_AUDIT_MAX_MB`) and
the bind address can be read, a config path is known (see
`OMNIGATE_CONFIG`), and an admin token that was set is at least 16
characters long. A token, a config path or a numeric variable that is set
but empty counts as unset.

Not configurable through the environment: when the ledger seals a segment
(at 64 MiB, or after the UTC day turns) and how often it writes a snapshot
(every 50,000 events, and every five minutes while there is something new).

The container images set some of these differently; see
[Deployment](deployment.md#what-the-images-set).

### Compose only

Read by Compose from `.env` for `compose.yaml` itself: the proxy's
environment, the two memory limits, and the data plane's three memory
budgets, which `compose.yaml` passes to the data-plane container.

| Variable | Default | Meaning |
|---|---|---|
| `OMNIGATE_API_HOST` | `localhost` | Host name the proxy serves the gateway on. |
| `OMNIGATE_ADMIN_HOST` | `admin.localhost` | Host name the proxy serves the dashboard and admin API on. |
| `OMNIGATE_ADMIN_ALLOW` | `0.0.0.0/0 ::/0` (everyone) | Source ranges that may reach the dashboard host at all, as CIDR ranges separated by spaces. Everyone else gets `403` from the proxy before the control plane sees the request. See [Security hardening](security.md#limit-who-can-reach-the-admin-host). |
| `OMNIGATE_CONTROL_MEMORY` | `1g` | Memory limit (`mem_limit`) of the control-plane container, as a Docker size (`512m`, `1g`, `2g`). A container that grows past its limit is killed and restarted. See [Deployment](deployment.md#memory-limits). |
| `OMNIGATE_DATAPLANE_MEMORY` | `1g` | The same for the data-plane container. |
| `OMNIGATE_REQUEST_MEMORY_MB` | `256` | The data plane's budget for request bodies in flight ([above](#data-plane)), set by `compose.yaml` in the container's environment so that the budgets fit the limit. Under Compose set it **here**: the same name in `.env.dataplane` is overridden by this one. |
| `OMNIGATE_PARSE_MEMORY_MB` | `256` | The same for its budget for JSON trees. |
| `OMNIGATE_CACHE_MAX_MB` | `64` | The same for its response cache. |

With these defaults the three add up to 576 MiB of the container's 1,024.
If you raise one, raise `OMNIGATE_DATAPLANE_MEMORY` by at least as much.

### Which file a variable goes in (Compose)

`compose.yaml` gives each container its own environment file, so that the
process that faces the internet holds as little as possible:

| File | Read by | Holds |
|---|---|---|
| `.env` | Compose itself | `OMNIGATE_API_HOST`, `OMNIGATE_ADMIN_HOST`, `OMNIGATE_ADMIN_ALLOW`, `OMNIGATE_CONTROL_MEMORY`, `OMNIGATE_DATAPLANE_MEMORY`, and the data plane's `OMNIGATE_REQUEST_MEMORY_MB`, `OMNIGATE_PARSE_MEMORY_MB` and `OMNIGATE_CACHE_MAX_MB`. No secrets. |
| `.env.control` | the control plane | `OMNIGATE_INTERNAL_TOKEN`, `OMNIGATE_ADMIN_TOKEN`, media provider keys, webhook secrets, bucket credentials, and any other control-plane variable from the table above. |
| `.env.dataplane` | the data plane | `OMNIGATE_INTERNAL_TOKEN` (the same value), the text provider keys, and any other data-plane variable from the table above (timeouts, the connection cap, the per-key concurrency cap, logging), except the three memory settings, which Compose takes from `.env`. Never the admin token, media keys, webhook secrets or bucket credentials. |

Each has an `.example` file next to it. `compose.yaml` itself sets
`OMNIGATE_TRUST_FORWARDED=1` for the control plane. The steps are in
[Deployment](deployment.md#compose-with-tls).

## What the data plane receives

The data plane never reads the config file. It fetches a snapshot from the
control plane (`GET /internal/config`) that contains:

- for each key that is not disabled, from the config file or created
  through the admin API: its SHA-256, name, `rpm`, `models`, and whether it
  is currently blocked by its budget (a disabled key is left out, so the
  data plane treats it as unknown), and its `max_concurrent` (`0` when the
  key has none of its own);
- the text upstreams as configured (the `api_key_env` name, never a secret);
- for each text route: `model`, `strategy`, `cache_ttl_s`, and each target's
  `upstream`, `model` and `weight`;
- the names of the media routes, which the data plane only uses to list
  them in `GET /v1/models`.

Budgets, budget periods, prices, raw keys, webhook secrets and the rest of
the `media` section stay in the control plane.

While the control plane's ledger is starting or restarting, the endpoint
answers `503 not_ready` with `retry-after: 1` instead of a snapshot: the
snapshot says which keys are over budget, and that cannot be known without
the ledger. A data plane keeps the config it has and asks again.
