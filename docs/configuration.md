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
| `budget_usd` | number | none (no budget) | The key is blocked once its recorded spend in the current budget period reaches this amount. See [Operations](operations.md#budgets). |
| `budget_period` | string | `total` | What the budget covers: `total` (everything, never resets), `monthly` (the current UTC calendar month) or `daily` (the current UTC day). Any other value is rejected when the file is loaded. |
| `rpm` | integer | `0` (unlimited) | Requests per minute, enforced by each data-plane process. |
| `models` | list of strings | absent (all models) | Route names, text or media, the key may use. An empty list allows none. Anything other than a list of strings is rejected when the file is loaded. |
| `disabled` | boolean | `false` | `true` switches the key off without removing it: the gateway answers it with 401, and its usage stays in the ledger. |
| `webhook_secret` | string | none | Signing secret for this key's job webhooks. |
| `webhook_secret_env` | string | none | Name of an environment variable (read by the control plane) holding that secret. Used when `webhook_secret` is absent. |

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
| `timeout_ms` | integer | `0` | Maximum wait for the provider's response headers. `0` uses the data plane's `OMNIGATE_UPSTREAM_TIMEOUT_MS`. |
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
| `cache_ttl_s` | non-negative integer | `0` (off) | Seconds the data plane may answer an identical request from its own memory instead of calling a provider. See [Response cache](#response-cache). |
| `targets` | list | required | Tried in the order the strategy gives; see below. |

Each target:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `upstream` | string | required | Name of an entry in `upstreams[]`. |
| `model` | string | required | The provider's model id. Replaces `"model"` in the forwarded request. |
| `weight` | non-negative integer | `1` | Used by `weighted` only. `0` means never first, but still a fallback. |
| `price_in_per_mtok` | number | `0` | US dollars per million input tokens that were not served from the provider's prompt cache. |
| `price_cached_in_per_mtok` | number, 0 or more | the value of `price_in_per_mtok` | US dollars per million input tokens read from the provider's prompt cache. |
| `price_cache_write_per_mtok` | number, 0 or more | the value of `price_in_per_mtok` | US dollars per million input tokens written to the provider's prompt cache (Anthropic-style upstreams report these). |
| `price_out_per_mtok` | number | `0` | US dollars per million output tokens. |

A config that sets only the input and output prices bills every input token
at the input price, cached or not. How the four token counts are told apart
is in [Operations](operations.md#budgets).

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
  budget, the model list and the rate limit, and counts against the rate
  limit like any request.
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
"retention": { "jobs_days": 30, "ledger_ids_days": 7, "ledger_days": 90, "delete_bucket_objects": true }
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `jobs_days` | number, fractions allowed | `0` (keep forever) | Finished jobs older than this are removed, with their output files: on local disk, and in the bucket unless `delete_bucket_objects` is `false`. |
| `ledger_ids_days` | number, fractions allowed | `0` (keep forever) | The ledger forgets duplicate-detection ids recorded longer ago than this. |
| `ledger_days` | number, fractions allowed | `0` (keep forever) | Sealed ledger segments (the history of usage events) last written longer ago than this are deleted. Spend totals are not affected: they are carried in the ledger's snapshots. |
| `delete_bucket_objects` | boolean | `true` | Whether a removed job's objects are also deleted from an S3-compatible bucket. Only has an effect when `jobs_days` is set. Anything but `true` or `false` is rejected when the file is loaded. |

Nothing is deleted unless you set these. A negative number, or a value that
is not a number, for one of the three `_days` fields is rejected when the
file is loaded. Details and caveats are in
[Operations](operations.md#retention); read the one about `ledger_days` and
backups before you set it.

### Media

The `media` section configures async jobs. It never leaves the control plane.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `public_base_url` | string | `http://127.0.0.1:8080` | The address clients use to reach the gateway. Output URLs for locally stored files start with it. |
| `poll_interval_ms` | integer | `2000` | How often a running job polls its provider. |
| `max_output_bytes` | integer | `536870912` (512 MiB) | Largest single output file the gateway will download and store. |
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
| `timeout_s` | integer | `600` | How long one target gets before the job moves to the next. Also the HTTP timeout for providers that answer in one call. |
| `targets` | list | required | Tried in order. |

Each target has `upstream`, `model` (the provider's model id) and an optional
`price` object. All four price fields default to `0` and are added together:

| `price` field | Charged |
|---|---|
| `per_job_usd` | Once per successful job. |
| `per_output_usd` | Per output file. |
| `per_second_usd` | Times `input.duration` (or `input.seconds`). |
| `per_input_char_usd` | Times the length of the first of `input.text`, `input.prompt`, `input.input` that is a string. |

Cost is the configured price of the target that delivered. A failed or
canceled job costs nothing in the ledger, and a cache hit costs nothing.

#### `media.storage`

Local disk (the default):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `kind` | string | `local` | |
| `dir` | string | `OMNIGATE_MEDIA_DIR`, else `data/media` under the control plane's working directory | Files are stored as `<dir>/<job id>/<name>`. |
| `url_ttl_s` | integer | `3600` | Lifetime of the signed download URLs handed to clients. |

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
| `retry_schedule_ms` | list of integers | `[5000, 30000, 120000, 600000, 1800000, 7200000, 21600000]` | Delay before each retry. |
| `max_attempts` | integer | length of the schedule plus 1 | Total deliveries tried before giving up. |
| `timeout_ms` | integer | `10000` | How long the receiver gets to answer. |
| `allow_private` | boolean | `false` | Allow webhook URLs that resolve to loopback, private or link-local addresses. For local development. |

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
| `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` | `300000` | A response in progress is cut off when the upstream sends nothing, or the client reads nothing, for this long. What was metered up to then is still billed. `0` means no limit. |
| `OMNIGATE_MAX_CONNECTIONS` | `4096` | Client connections served at once. Further connections get an immediate `503` (`overloaded`) and are closed. |
| `OMNIGATE_SHUTDOWN_GRACE_MS` | `10000` | After SIGINT or SIGTERM (Ctrl-C or Ctrl-Break on Windows): how long requests in flight may take to finish before they are cut off and the process exits. |
| `OMNIGATE_CACHE_MAX_MB` | `64` | Memory for the [response cache](#response-cache) of routes that set `cache_ttl_s`. `0` turns it off. |
| `OMNIGATE_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error` (`warning` and `err` are accepted too; case does not matter). |
| `OMNIGATE_LOG_FORMAT` | `text` | `text`, or `json` for one JSON object per line. See [Operations](operations.md#logs). |
| `OMNIGATE_COOLDOWN_FAILURES` | `5` | Consecutive failures before an upstream is tried last. `0` turns cooldowns off. |
| `OMNIGATE_COOLDOWN_MS` | `30000` | How long an upstream stays in that state. |
| `OMNIGATE_SPOOL` | `omnigate-usage.spool` | File for undelivered usage events. `off` keeps them in memory only. |
| `OMNIGATE_CONFIG_CACHE` | `omnigate-config.cache.json` | Last config received, reused when starting while the control plane is down. `off` disables it. |
| the names in `upstreams[].api_key_env` | none | Provider keys for text upstreams. |

The spool and the config cache are relative to the data plane's working
directory unless given as absolute paths. A numeric variable that does not
parse, or a log level or format that is not one of the values above, stops
the data plane at startup.

### Control plane

| Variable | Default | Meaning |
|---|---|---|
| `OMNIGATE_ADMIN_TOKEN` | generated and logged at startup | Dashboard password, and bearer token for `/admin/*` and `/metrics`. A warning is logged if it is shorter than 16 characters. |
| `OMNIGATE_CONTROL_BIND` | `127.0.0.1` | IP address to listen on. Set an address such as `0.0.0.0` to accept connections from other machines. Must be an IP address, not a host name. |
| `OMNIGATE_CONTROL_PORT` | `4000` | Port to listen on. |
| `OMNIGATE_COOKIE_SECURE` | unset | `1` always marks the session cookie `Secure`. This is automatic when the request arrives with `X-Forwarded-Proto: https`. |
| `OMNIGATE_CONFIG` | `../config/omnigate.dev.json` | Path of the config file. |
| `OMNIGATE_LEDGER` | `data/ledger.jsonl` | The usage ledger's active segment. Sealed segments (`ledger.000001.jsonl`, ...) and the snapshots (`ledger.snapshot`, `ledger.snapshot.prev`) are written next to it and named after it. See [Architecture](architecture.md#ledger-files-segments-and-snapshots). |
| `OMNIGATE_JOBS` | `data/jobs.jsonl` | Job state. |
| `OMNIGATE_KEYS` | `data/keys.json` | Gateway keys created through the admin API or the dashboard: hashes, limits, and a key's webhook secret if it has one. See [Admin](admin.md#gateway-keys-two-sources). |
| `OMNIGATE_AUDIT_LOG` | `data/audit.jsonl` | The admin audit log. Rotated files (`.1` to `.3`) are kept next to it. See [Admin](admin.md#the-audit-log). |
| `OMNIGATE_AUDIT_MAX_MB` | `50` | Size, in megabytes (fractions allowed), at which the audit log is rotated. `0` turns rotation off. A negative value, or one that is not a number, is replaced by the default without a message. |
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

Not configurable through the environment: when the ledger seals a segment
(at 64 MiB, or after the UTC day turns) and how often it writes a snapshot
(every 50,000 events, and every five minutes while there is something new).

The container images set some of these differently; see
[Deployment](deployment.md#what-the-images-set).

### Compose only

| Variable | Default | Meaning |
|---|---|---|
| `OMNIGATE_API_HOST` | `localhost` | Host name the proxy serves the gateway on. |
| `OMNIGATE_ADMIN_HOST` | `admin.localhost` | Host name the proxy serves the dashboard and admin API on. |

## What the data plane receives

The data plane never reads the config file. It fetches a snapshot from the
control plane (`GET /internal/config`) that contains:

- for each key that is not disabled, from the config file or created
  through the admin API: its SHA-256, name, `rpm`, `models`, and whether it
  is currently blocked by its budget (a disabled key is left out, so the
  data plane treats it as unknown);
- the text upstreams as configured (the `api_key_env` name, never a secret);
- for each text route: `model`, `strategy`, `cache_ttl_s`, and each target's
  `upstream`, `model` and `weight`;
- the names of the media routes, which the data plane only uses to list
  them in `GET /v1/models`.

Budgets, budget periods, prices, raw keys, webhook secrets and the rest of
the `media` section stay in the control plane.
