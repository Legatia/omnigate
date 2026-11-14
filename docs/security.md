# Security hardening

A checklist for operators: what to expose, where each credential lives, and
what to look after once the gateway is running. It describes the code as
committed and the Compose deployment in this repository; adapt the same
rules to any other way of running it.

The security model, the known limits and the advisories for past
vulnerabilities are in [SECURITY.md](../SECURITY.md). Report a
vulnerability the way that file says, not in a public issue.

Nothing here has been proven under attack. The measures below are covered
by unit tests, by `tools/malformed_test.py` and by the container test, all
against mock providers; the project has not had an external penetration
test and has never run under production load.

- [The short version](#the-short-version)
- [What to expose](#what-to-expose)
- [The three credentials](#the-three-credentials)
- [What each container holds](#what-each-container-holds)
- [Limit who can reach the admin host](#limit-who-can-reach-the-admin-host)
- [TLS](#tls)
- [Gateway keys](#gateway-keys)
- [Limits to size](#limits-to-size)
- [Media prices](#media-prices)
- [Outbound calls: webhooks and provider outputs](#outbound-calls-webhooks-and-provider-outputs)
- [Stored outputs](#stored-outputs)
- [Backups of `/data`](#backups-of-data)
- [Log hygiene](#log-hygiene)
- [Staying current, and upgrade notes](#staying-current-and-upgrade-notes)
- [Checking a deployment](#checking-a-deployment)

## The short version

1. Publish only the proxy's ports. Never publish 4000 (control plane) or
   8080 (data plane) themselves.
2. Use three long random secrets: the internal token, the admin token (16
   characters at least, or the control plane will not start) and gateway
   keys. Keep them in the file of the container that needs them and nowhere
   else.
3. Set `OMNIGATE_ADMIN_ALLOW` to the networks your operators come from.
4. Leave `media.webhooks.allow_private` off outside local development.
5. Give every gateway key a model list, a rate limit and a budget.
6. Size the data plane's limits to the memory it may use: the per-key
   concurrency cap and the two memory budgets. `compose.yaml` sets the
   budgets to fit its 1 GiB container limit; the binary's own defaults
   admit 2 GiB and are meant for a host without a limit.
7. Price every media target, and close the options a client could use to
   make a job cost more than its price says (`default_seconds`,
   `allowed_input`, `price_multipliers`).
8. Back up the control plane's `/data` as one set, and protect the backup
   like the live data.
9. Treat the control plane's log as a secret if you let it generate the
   admin token; better, set one.
10. Update when the changelog has a "Security" entry, and rotate what the
    advisory tells you to.

## What to expose

| Thing | Expose to | How |
|---|---|---|
| The gateway (`https://$OMNIGATE_API_HOST`) | Your applications, or the internet | Through the TLS proxy, ports 80 and 443. |
| The dashboard and admin API (`https://$OMNIGATE_ADMIN_HOST`) | Operators only | Through the TLS proxy, narrowed with `OMNIGATE_ADMIN_ALLOW`, or not published at all outside a VPN. |
| The control plane's port (4000) | Nobody outside the private network | It is plain HTTP and serves the internal API. `compose.yaml` does not publish it. |
| The data plane's port (8080) | Only the proxy | Plain HTTP. `compose.yaml` does not publish it. |
| `/internal/*` | Only data planes | The proxy answers 404 for it on the dashboard host; the control plane also refuses every percent-encoded spelling of a path, so `/%69nternal/...` does not get through either. |

Things that are reachable without a credential, by design:

- `GET /healthz` on the gateway host.
- `GET /healthz`, `GET /readyz` and the sign-in form on the dashboard host
  (unless the allow-list keeps the caller out). They disclose nothing but
  "up" and "ready".
- A signed file URL (`/v1/files/...?exp=...&sig=...`) until it expires, one
  hour by default (`media.storage.url_ttl_s`). Whoever holds the URL holds
  the file.

Both processes refuse what they do not recognise rather than passing it
on. The control plane answers an unknown first path segment with 404 before
any handler runs, so a route added later stays closed until it is
deliberately opened, and it checks credentials before it reads a body: the
only body it reads from a caller without credentials is the sign-in form,
up to 4,096 bytes. The data plane accepts one spelling per path and
refuses malformed or ambiguous request heads
([API](api.md#request-heads-paths-and-queries)).
Do not put a proxy in front that rewrites or normalises paths, and make
sure it hands request bodies on with a `Content-Length`: the data plane
answers `411` to a chunked request body.

The limits on the public port (8 MiB bodies, 16 KiB heads, timeouts, a
connection cap, a cap on the requests one key has in flight, and budgets
for the memory that request bodies and their parsing may take) bound what
one client or one key can hold. Which of them you should size is under
[Limits to size](#limits-to-size). They are not a defence against a
volumetric attack; that belongs to the network in front.

## The three credentials

| | Gateway key | Internal token | Admin token |
|---|---|---|---|
| Held by | Applications | The two processes | Operators |
| Opens | Text endpoints, the jobs API and file downloads, within the key's model list, rate limit, budget, open-job limit and jobs-per-day limit | `/internal/*` on the control plane: the config snapshot (key hashes, upstream addresses), usage intake, and the jobs API as **any** gateway key | The dashboard, `/admin/*` (which creates and revokes gateway keys) and `/metrics` |
| Lives in (Compose) | The application's own secret store. The gateway stores only its SHA-256: in `config/omnigate.json` for a file key, in `/data/keys.json` for a managed key | `.env.control` **and** `.env.dataplane`, the same value | `.env.control` only |
| Never put it in | The config file in clear text (`"key"`) outside local trials | `.env`, the config file, an application | `.env.dataplane`, `.env`, an application |
| Strength | Generated ones are 32 random bytes; your own should be as long | Long and random; neither process starts without it | At least 16 characters or the control plane refuses to start; make it 32 random bytes |
| Guessing | An unknown key is a 401; refusals are counted per reason, with a cap on distinct series | Compared in constant time | Compared in constant time. 5 failed sign-ins, or 20 wrong bearer tokens, per address per minute, then that address is locked out for the rest of the minute |

None of them works in another's place.

The count of wrong bearer tokens covers every place the admin token is
accepted as one: `/admin/*`, `/metrics`, and since commit d79406b also the
dashboard page (`/`) and `/login`, which used to compare the token on
their own. Once an address is locked out, its token is not compared at
all, so the answer says nothing about whether it was right: `/admin/*`,
`/metrics`, `/` and `GET /login` answer `429 too_many_attempts` (`GET
/login` showed the sign-in form with `200` until the close-out commit, the
one after 55a294d). The two counts are
separate: wrong bearer tokens do not lock the sign-in form, and failed
sign-ins do not lock bearer access.

One way to make a secret:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

### Rotating them

**Admin token.** Change `OMNIGATE_ADMIN_TOKEN` in `.env.control` and
re-create the control container:

```bash
docker compose up -d control
```

Every dashboard session ends (sessions are signed with a key derived from
the token), and scripts and Prometheus need the new value. Gateway traffic
is not interrupted: the data plane serves from its last config while the
control plane restarts.

**Internal token.** Change `OMNIGATE_INTERNAL_TOKEN` in both
`.env.control` and `.env.dataplane` and re-create both containers together:

```bash
docker compose up -d control dataplane
```

While the two values differ, the data plane logs `config fetch returned
401`, keeps serving text from its last config and spools usage. Signed file
URLs handed out before the change stop working, unless
`OMNIGATE_SIGNING_SECRET` is set separately (then they depend on that
instead).

**Gateway keys.**

- A managed key: `POST /admin/keys/{name}/rotate`, or the Rotate button.
  The old secret stops working at the data planes' next poll (two seconds
  by default); spend, budget and jobs stay with the key
  ([Admin](admin.md#rotate)).
- A file key: generate a new key, put its SHA-256 in `key_sha256`, save the
  config. It is picked up within seconds. Usage is recorded per key hash,
  so a file key replaced this way starts again at zero spend and can no
  longer fetch jobs created under the old secret. Prefer managed keys for
  anything you expect to rotate.

**Provider keys, bucket credentials, webhook secrets.** Rotate them at the
provider, change the variable in the file of the container that reads it
(text provider keys in `.env.dataplane`, everything else in
`.env.control`), and re-create that container. A managed key's own webhook
secret is changed with `PATCH /admin/keys/{name}`.

## What each container holds

`compose.yaml` gives each container only its own environment file. The
container test checks that the data-plane container has the internal token
and no admin token.

| Container | Faces | Environment file | Secrets it holds | State it holds |
|---|---|---|---|---|
| `proxy` (Caddy) | The internet | `.env` through Compose: host names and the allow-list | TLS private keys, in the `caddy-data` volume | Certificates |
| `dataplane` | The internet, through the proxy | `.env.dataplane` | The internal token; text provider keys | `/data`: the usage spool and a copy of the last config (key hashes and routes, no secrets) |
| `control` | The private network; operators through the proxy | `.env.control` | The internal token, the admin token, media provider keys, webhook secrets, bucket credentials | `/data`: the ledger, jobs, managed keys, the audit log, stored outputs |

Keep it that way when you add variables: a new data-plane setting goes in
`.env.dataplane`, and nothing the data plane does not read belongs there.
If you still have a single `.env` with secrets from an earlier commit,
split it ([Deployment](deployment.md#coming-from-a-commit-before-3a0b147)).

What a compromise of each would mean, so you know what to rotate:

- **The data plane's environment**: the internal token (and with it the
  jobs API as any key, usage intake and the config snapshot) and your text
  provider keys. Not the admin token, not media keys, not the bucket.
- **The control plane's environment or `/data`**: everything.

## Limit who can reach the admin host

By default anyone who can reach the dashboard's host name can try the admin
token; the token and the lockout are then the only gates.
`OMNIGATE_ADMIN_ALLOW` adds one in front of them. In `.env`:

```
OMNIGATE_ADMIN_ALLOW=203.0.113.0/24 2001:db8::/32
```

then `docker compose up -d proxy`. It is a space-separated list of CIDR
ranges. The proxy answers 403 to every request for the dashboard host from
outside them, before the control plane sees it; the gateway host is not
affected. (The ranges above are documentation addresses; use your own.)

Things to get right:

- **The address is the one the proxy sees.** Behind another load balancer
  or proxy, or under Docker Desktop's network, that is the address of that
  hop, not of the client, and the list cannot tell clients apart. Put the
  restriction on the outermost hop in that case.
- **Monitoring comes through the same door.** A Prometheus server that
  scrapes `/metrics`, or a probe on `/readyz`, on the dashboard host must
  be inside the list.
- **It complements the token, it does not replace it.**

The lockouts count per client address. `compose.yaml` sets
`OMNIGATE_TRUST_FORWARDED=1` on the control plane so that the address is
the one the proxy reports in `X-Forwarded-For` rather than the proxy's own;
otherwise one person guessing would lock every operator out. Set that
variable only where a proxy you control is the only way to reach the
control plane and writes the header itself. If you publish the control
plane's port directly, remove it: a client could otherwise choose the
address it is counted under and never be locked out.

"Writes the header itself" means: from the address of the connection, in
place of whatever the client sent under that name. The included Caddyfile
now says so explicitly for both hosts
(`header_up X-Forwarded-For {remote_host}`), and the container test checks
that a client which claims a new address with every failed sign-in is
still locked out. Two things to get right in a setup of your own:

- **A proxy configuration of your own must do the same.** The control
  plane takes the last hop named in the header. A proxy that passes a
  client's header through untouched lets the client pick that hop.
- **If the Compose proxy itself sits behind another proxy or a load
  balancer**, `{remote_host}` is that hop's address for every request,
  and one person guessing locks everyone out. Replace it with
  `{client_ip}` **and** list the outer proxy under `trusted_proxies` in
  Caddy's global options, as the comment in `deploy/Caddyfile` says. Do
  not do one without the other: `{client_ip}` is only the client's
  address when Caddy has been told which proxies to believe.

The header's value is also written to the audit log (`forwarded_for`),
next to the address of the connection, so that a line can be traced when
every connection comes from the proxy.

If you do not use the Compose proxy, the equivalent is a firewall rule or
your proxy's own access control in front of the control plane's port.

## TLS

- Neither process has a TLS listener. The proxy terminates TLS for both
  host names; with real DNS names Caddy obtains and renews certificates by
  itself. (Issuance for a real domain has been seen once, by a Caddy
  of the same major version outside the bundled container:
  [Deployment](deployment.md#behind-a-proxy-you-already-run).)
- Traffic between the proxy, the data plane and the control plane is plain
  HTTP on the private Docker network. It carries the internal token and
  gateway key hashes. Keep those three on one host or one private network;
  data-plane-to-control-plane traffic over HTTPS is untested.
- The dashboard's session cookie is marked `Secure` when the request
  arrives with `X-Forwarded-Proto: https`, which the Compose proxy sends.
  Behind a proxy that does not, set `OMNIGATE_COOKIE_SECURE=1`.
- Without containers, keep the control plane on a loopback or private
  address (`OMNIGATE_CONTROL_BIND` defaults to `127.0.0.1`, and the control
  plane warns when it is set wider).
- Calls to providers, buckets and webhook receivers use the URLs you (or,
  for webhooks, your clients) configure; use `https` ones.
- **An upstream reached over plain HTTP can be impersonated by anyone on
  the network path** (a self-hosted OpenAI-compatible server on another
  machine, say). Since commit e4e30e4 a malformed answer from an upstream
  can no longer end the gateway process: the data plane reads every
  response with its own bounded reader and frames its own answer. What a
  forged answer can still do is be a well-formed one: wrong content for
  the client, and usage figures of the forger's choosing in your ledger.
  Prefer `https` upstreams; where that is not possible, keep the path to
  the upstream on a network you control.

## Gateway keys

A gateway key in the wrong hands spends your provider budget. Bound each
one:

| Limit | Field | Effect |
|---|---|---|
| Which models | `models` | 403 for any other route, text or media. |
| How fast | `rpm` | 429 beyond it. Per data-plane process for text; job creation is counted again in the control plane, with the same kind of token bucket. The limit is charged before the body is read, so a request that is then refused for its JSON or its model has used one. |
| How much | `budget_usd` with `budget_period` | 402 once spent. Enforced after the fact: the call that crosses the line completes. |
| How many requests at once | `max_concurrent` (default: the data plane's `OMNIGATE_MAX_CONCURRENT_PER_KEY`, 512) | 429 `concurrency_limit_exceeded` beyond it, per data-plane process, before the body is read. |
| How many media jobs at once | `max_open_jobs` (default 100, from `media.max_open_jobs`) | 429 `too_many_open_jobs` beyond it. |
| How many media jobs per day | `max_jobs_per_day` (default 10,000, from `media.max_jobs_per_day`) | 429 `too_many_jobs_today` beyond it, until the UTC day turns. It bounds what the open-jobs limit does not: jobs that end at once (a refused input, a provider that is down) and still cost a log line, a ledger event and a webhook call each. |

One limit applies to every key alike and has no per-key setting:
`GET /v1/jobs` is limited to the key's `rpm`, or to 600 a minute for a key
without one. See [Limits to size](#limits-to-size).

- Write file keys as `key_sha256`, never as `key`, outside local trials.
- One key per application, so that one can be revoked without the others,
  and so that names in logs and metrics mean something.
- A key that is disabled, deleted or rotated away is refused as unknown at
  the data planes' next poll. A data plane that cannot reach the control
  plane keeps accepting it until it can poll again.
- The development config (`config/omnigate.dev.json`) contains published
  keys and a published webhook secret and allows private addresses. A
  release build of the control plane refuses to start without
  `OMNIGATE_CONFIG`, so it cannot be picked up by accident on a server; do
  not point `OMNIGATE_CONFIG` at it either.

## Limits to size

A gateway key is a credential you handed to someone else. The data plane
checks the limits below before it reads a request body, so that a valid
key cannot decide how much the process holds. They are environment
variables of the data plane (`.env.dataplane`), with defaults that are
generous on purpose. Decide each one for your deployment.

| Setting | Default | What it bounds | Over it |
|---|---|---|---|
| `OMNIGATE_MAX_CONCURRENT_PER_KEY` | `512` | Requests one key has in flight. An upstream answer still being read after its client left counts until it is finished, so opening streams and hanging up is no way around it. | 429 `concurrency_limit_exceeded` |
| `OMNIGATE_REQUEST_MEMORY_MB` | `1024` | Request bodies in flight, by declared length, each counted twice. One key may hold a quarter. | 429 `request_memory_exceeded` for the key's share, 503 `overloaded` for the whole |
| `OMNIGATE_PARSE_MEMORY_MB` | `1024` | Memory reserved for parsing JSON into trees (translation, the response cache, provider quirks). One tree may take at most 96 MiB; one key may reserve half. | 400 `request_too_complex` for one tree, 429 `request_memory_exceeded`, 503 `overloaded` |
| `OMNIGATE_MAX_CONNECTIONS` | `4096` | Client connections served at once. | An immediate 503 `overloaded` |
| `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` | `30000` | How long a client may stay connected without taking any of a response. | The client is cut off; the call is still billed. |
| `OMNIGATE_ABORT_DRAIN_MS`, `OMNIGATE_ABORT_DRAIN_MAX_MB` | `120000`, `64` | How long, and how much, an upstream answer is read on after its client left, to bill the provider's real figures. At most 256 answers are read on at once. | An estimate is billed. |

- **The concurrency cap has a default and a per-key setting.**
  `OMNIGATE_MAX_CONCURRENT_PER_KEY` applies to every key that has no
  `max_concurrent` of its own (a key field since the close-out commit; in
  the config file or through the admin API). Lower the default if you hand
  keys to parties you do not trust, and give your busiest legitimate key a
  cap of its own above what it has in flight.
- **Size the two memory budgets to the memory the process may use.** The
  binary's defaults add up to 2 GiB, for a host without a limit.
  `compose.yaml` gives the data-plane container 1 GiB
  (`OMNIGATE_DATAPLANE_MEMORY`) and, since the close-out commit, sets the
  budgets to 256 MiB each from `.env`, so that under heavy hostile load a
  budget refuses a request, which costs one client a retry, before the
  container is killed, which ends every connection. If you raise a budget,
  raise the container's limit with it; if you run the binary under a
  limit of your own, do the same sum:
  [Deployment](deployment.md#memory-limits). The budgets bound request
  bodies and parse trees only; the response cache
  (`OMNIGATE_CACHE_MAX_MB`, 64), the usage queue and per-connection
  buffers come on top.
- **The container limits are a backstop.** Both omnigate containers have
  a memory limit in `compose.yaml` (1 GiB each unless `.env` says
  otherwise); a container past its limit is killed and restarted instead
  of taking the host down. Without containers, set the equivalent in your
  service manager.
- **Reading on costs provider money.** After a client leaves, the
  provider keeps generating for up to `OMNIGATE_ABORT_DRAIN_MS` (two
  minutes), billed to the key at the provider's real figures. Lower it if
  you would rather stop the provider sooner and bill an estimate.
- **On the control plane**, the settings that bound what keys and
  receivers can make it hold are in the config file: `max_open_jobs` and
  `max_jobs_per_day` per key, `media.max_input_bytes` (1 MiB),
  `media.max_output_bytes` (512 MiB; a provider answer that carries the
  media inline is held in memory, up to 256 MiB),
  `media.max_outputs_per_job` (16) and `media.max_job_output_bytes`
  (2 GiB), which bound what one provider answer can put on the disk, the
  webhook delivery
  caps, and `retention.ledger_ids_days`, which decides how many
  duplicate-detection ids are held (about 61 MiB per million).
- **Alert on the refusals.** A rise of
  `omnigate_rejected_requests_total` for the reasons
  `concurrency_limit_exceeded`, `request_memory_exceeded` or `overloaded`
  means a key is at a cap: either a client misbehaves or the cap is too
  low for honest traffic.

None of this has been sized against real traffic by this project. The
measurements that exist are in
[Operations](operations.md#connection-limits-and-shutdown).

## Media prices

A media job is billed from the price you configure, not from what the
provider charges. Where the two can differ, a key holder can run up
provider cost that the key's budget never sees. Close these gaps in the
config file ([Configuration](configuration.md#mediaroutes)):

- **Price every target.** A target with no price records its jobs at $0.
  That is now counted (`omnigate_ledger_unpriced_events_total`) and logged
  once per target, as is text usage for a route or target that is not in
  the config.
- **Routes priced per second: set `default_seconds`.** The seconds billed
  are the ones the adapter asks the provider for. A job on such a route
  that names no duration is refused (`400 invalid_request`) unless the
  target has `default_seconds`; until commit d79406b it was accepted and
  billed nothing per second. `min_seconds` is the least duration billed
  whatever the request says, and `max_seconds` refuses longer requests.
- **Options the provider bills for: `allowed_input` and
  `price_multipliers`.** `allowed_input` lists the top-level `input`
  fields a job on the route may carry; a job with any other field is
  refused instead of being forwarded. `price_multipliers` puts a factor on
  the price by the value of a field (a quality, a size), and a job that
  sends a listed field must use a listed value. Use them together, so that
  an option that changes what the provider charges cannot be sent without
  the price following it.
- **Seconds and characters are counted from what is sent to the
  provider**, not from one field the client chose to fill in.

Two more settings decide whether each call is counted once:

- **`retention.ledger_ids_days`** (default 3 days; 14 until commit
  d79406b). The ledger forgets the ids it uses to reject resent usage once
  they are older than this, by whole UTC days. A usage event that a data
  plane resends after its id was forgotten is counted twice. Raise the
  value above the longest time a data plane may hold undelivered usage:
  the longest control-plane outage, or the longest a data plane is
  switched off with events in its spool, that you expect to ride out. The
  cost of a higher value is memory, about 61 MiB per million requests
  ([Operations](operations.md#retention)).
- **`omnigate_ledger_invalid_events_total`** counts usage events the
  ledger could not record. It should stay at zero; alert on it and on
  `omnigate_ledger_unpriced_events_total`.

## Outbound calls: webhooks and provider outputs

The control plane makes HTTP requests to URLs that somebody else chose: a
client's `webhook_url`, and the output URLs in a provider's answer. Either
could be aimed at something inside your network (a metadata service, an
admin panel).

- Leave `media.webhooks.allow_private` at `false`. Every such URL must then
  be `http` or `https`, carry no credentials, and resolve only to public
  addresses: loopback, private, link-local (which includes cloud metadata
  addresses), carrier NAT, documentation, benchmarking and multicast ranges
  are refused, as are the IPv6 forms that carry an IPv4 address inside.
  Of IPv6, only global unicast (`2000::/3`) is called at all.
- The host is resolved once, every address is checked, and the connection
  goes to the checked address, so a DNS answer that changes between the
  check and the call cannot redirect it.
- Webhook deliveries do not follow redirects. Output downloads follow at
  most five, each checked the same way.
- `allow_private: true` switches all of this off, for webhooks **and**
  output downloads. It exists for local development against the mocks.
- Egress filtering on the control plane's host is still worth having; the
  checks above are in the application, not in the network.

Where a call goes is one half. The other is what the far side can make the
control plane do with its answer, since a webhook receiver is run by
whoever holds a gateway key:

- **A receiver's answer is read up to 16 KiB**, and only its status is
  used. A receiver cannot make the control plane hold a large answer.
- **An attempt is recorded before its request is sent.** A delivery that a
  crash or a restart cuts short has used up its attempt, so a receiver
  gets at most `media.webhooks.max_attempts` requests per job whatever
  happens in between.
- **At most 16 deliveries run at once, 4 for the jobs of one gateway
  key** (`media.webhooks.max_concurrent`, `max_concurrent_per_key`). One
  key's slow receiver cannot hold up everyone else's webhooks; the rest
  wait their turn, so a delivery can start later than the retry schedule
  says.
- **`max_jobs_per_day`** (10,000 per key by default) bounds how many
  webhook calls, log lines and ledger events one key can cause in a day
  with jobs that end at once.
- **Provider and bucket answers are read through a cap too**: 4 MiB for
  an API answer; for an answer that carries the media inline, four thirds
  of `media.max_output_bytes` plus 64 KiB and never more than 256 MiB; a
  download, `media.max_output_bytes`. Text from outside (a provider's
  error body, a header value) is made valid, single-line UTF-8 before it
  is logged or stored.

## Stored outputs

Files in local storage are bytes a provider produced. They are served as
downloads from a sandboxed context, never as pages on the gateway's
origin: `Content-Disposition: attachment`, `X-Content-Type-Options:
nosniff`, a sandboxing `Content-Security-Policy`, and a content type that
is kept only for a short list of media types.

The gateway sends these headers itself (the data plane passes on what the
control plane set), so they do not depend on a proxy. Make sure a proxy of
your own does not strip or override response headers on `/v1/files/*`.

Serve the gateway on a host name of its own, not on one that also hosts an
application with cookies.

With bucket storage the files never pass through the gateway on the way
out: clients get presigned URLs. Keep the bucket private and give the
gateway's credentials no more than put, get and (for retention) delete on
its prefix.

## Privacy mode

A key can be set to keep nothing of its requests in the gateway, to have
addresses, numbers and secrets replaced by placeholders before a provider
sees them, to drop the fields that name an end user, and to have its media
outputs encrypted to a key only its owner holds: [Privacy mode](privacy.md).
Three things about it belong on this page:

- It narrows what a provider is shown and what the gateway keeps. It does
  not hide a prompt from the provider that answers it, and it does not find
  names. The page says plainly what each part does not do; read that part
  before you describe the feature to anyone else.
- Redaction and unlinking run in the data plane on every request of the
  key, so they hold for whatever client uses the key. A request can add
  protections with a header and cannot remove any; a header the gateway
  does not understand is refused, not ignored.
- An operator can switch a key's privacy mode off. Every change is in the
  [audit log](admin.md#the-audit-log) with what the setting became.

## Backups of `/data`

The control plane's `/data` volume is the installation: the ledger
(segments, both snapshots and the per-day id files `ledger.ids.YYYY-MM-DD`),
`jobs.jsonl` and its directory of large inputs (`jobs.jsonl.inputs/`),
`keys.json`, the audit log and locally stored outputs. How to take and
restore a copy is in [Deployment](deployment.md#backups). From a security
point of view:

- **A backup is as sensitive as the live volume.** `jobs.jsonl` and
  `jobs.jsonl.inputs/` hold every job's input (prompts), metadata and
  webhook URL; `keys.json` holds key hashes and, in clear text, the
  webhook secret of any managed key that has one; the ledger holds usage
  per key; the audit log holds the addresses of operators and of everyone
  who failed to sign in. Encrypt backups and restrict who can read them.
- **Take the directory as one set, from one moment**, with the control
  plane stopped. Once `retention.ledger_days` has deleted old segments,
  the two snapshot files are the only copy of those totals.
- **The two new kinds of file belong to the set.** A ledger restored
  without its `ledger.ids.*` files has its totals but has forgotten which
  events it already counted, so resent usage is counted twice. A job log
  restored without `jobs.jsonl.inputs/` has jobs without their input.
- **The snapshots in a backup taken after commit d79406b are not read by
  older code**, which then rebuilds its totals from the segments that are
  left. Keep the last backup from before an upgrade until you are sure you
  will not go back ([Upgrading](upgrading.md#going-back)).
- **Back up the three environment files and the config separately**, in
  your secret store, not next to the data.
- **The audit log is not tamper-evident** and keeps only three rotated
  files. If you need a longer or stronger record, ship it elsewhere as it
  is written.
- The data plane's volume needs no backup: an undelivered usage spool and
  a config copy.
- On a shared host, the volumes are readable by root and by user 10001.
  `keys.json` is written with mode `0600`.

## Log hygiene

- **Set the admin token.** If `OMNIGATE_ADMIN_TOKEN` is unset, the control
  plane generates one at every start and writes it to its log. Anyone who
  can read `docker compose logs control` then has it.
- **What the data plane logs:** one line per request with the key's
  **name**, the route, the upstream, token counts and the path. Never a
  key, a key hash, a request or response body, or a query string (for a
  signed file URL the query string is the credential). Text that came from
  a client has control bytes escaped, so a model name cannot forge a log
  line.
  With `OMNIGATE_LOG_FORMAT=json` a line whose token counts are an
  estimate now says so (`"estimated": true`), as the text format already
  did (`usage=estimated`); `aborted` can also be `ClientStalled` or
  `UpstreamTruncated`.
- **What the control plane logs:** start-up, config reloads, job failover,
  errors with a request id. Provider error text can appear in job lines;
  it is cut to one line of valid UTF-8 first, so it cannot forge a line.
- **New lines worth an alert** are listed in
  [Operations](operations.md#lines-worth-knowing): usage recorded at $0
  for want of a price, usage events dropped as invalid, a job that could
  not be stored, and the data plane dropping usage because its queue is
  full or discarding part of an oversized spool at startup. One more is
  not in that list: when the control plane's stores are restarted as a
  group it logs, as an error,
  `OmnigateControl.Supervisor stopped (...); the HTTP listener stays up, starting the group again in N ms`,
  and `OmnigateControl.Supervisor is running again` when they are back.
  Repeated, it means some input keeps crashing a store; `/readyz` says 503
  meanwhile.
- **Your proxy's access log is yours to decide.** `deploy/Caddyfile` does
  not turn one on. If you do, remember that proxies usually record the
  full request URI: signed file URLs would then be in that log, usable
  until they expire.
- **Watch for:** `omnigate_rejected_requests_total` rising for
  `invalid_api_key` or `invalid_request`, and for
  `concurrency_limit_exceeded`, `request_memory_exceeded` or `overloaded`
  (a key at a cap); `omnigate_ledger_unpriced_events_total` or
  `omnigate_ledger_invalid_events_total` rising at all (spend that is not
  reaching a budget); `login` entries with outcome `denied` or `throttled`
  in the audit log, and their `repeats`; key actions you did not make; a
  data-plane container that restarted with exit code 70 (a panic: the log
  has one `error(panic): ...` line; report it); a container that was
  killed for memory.
- **Failed sign-ins are aggregated in the audit log.** The first failed or
  throttled sign-in from an address in a minute is a line of its own; the
  rest are counted and written as one summary line with a `repeats` member
  when the minute is over. An address therefore costs at most two lines
  per minute and outcome, and a flood of guesses can neither fill the log
  nor make an operator's own action wait behind it. The attempts in that
  minute are `repeats` plus the one that got its own line. The control
  plane follows at most 2,000 such counts (address, outcome and minute) at
  once; beyond that, further addresses are counted together under the
  address `(others)`. `address` means the same on every line: the address
  the caller was counted under, which with `OMNIGATE_TRUST_FORWARDED` is
  the one the proxy reported; the connection's own address is in `peer`
  when it differs. (Until the close-out commit ordinary lines had the
  connection's address in `address`, which behind the Compose proxy was
  the proxy.) A clean stop writes the counts that have no summary line
  yet; a kill loses them.
- Wrong bearer tokens are counted and throttled but not written to the
  audit log.
- Ship logs somewhere the containers cannot rewrite them if you rely on
  them after an incident.

## Staying current, and upgrade notes

The stable release is 1.0.0. Fixes land on `main` first, so "current"
means the newest release or a recent commit of `main`.

- Read the "Security" section of [CHANGELOG.md](../CHANGELOG.md) before
  every update, and [SECURITY.md](../SECURITY.md#past-advisories) for what
  each fix means for an installation that ran the older code.
- An update is `git pull` and `docker compose up -d --build`
  ([Deployment](deployment.md#upgrades)). Take a backup of `control-data`
  first.
- What an update changes on disk, in defaults and for clients, and the
  order to upgrade the two processes (the control plane first, then the
  data planes), is in [Upgrading](upgrading.md).

Coming from 1cc721f or earlier: the commit after it fixes what a third
review found (a provider made unreachable by one failed write, field
names a lax provider reads differently, free provider calls through
cancel, unbounded downloads). Update both processes; nothing needs
rotating. What changes is in
[Upgrading](upgrading.md#the-third-review-commit).

Coming from a commit before e4e30e4 or d79406b (November 2026), in short
(the full list is in [Upgrading](upgrading.md)):

- Update both processes. One commit fixes the data plane, the other the
  control plane.
- Nothing has to be rotated for these two.
- Check your config file against the stricter rules before the restart: a
  value the old control plane loaded can stop the new one at startup.
- Decide on memory: the Compose file now limits both containers to 1 GiB.
  Its budgets for the data plane fit that limit since the close-out
  commit; with an earlier `compose.yaml`, or the binary's own defaults,
  they admit more ([Limits to size](#limits-to-size)).
- If you price media routes per second, set `default_seconds`
  ([Media prices](#media-prices)).
- If a data plane can be cut off from the control plane for more than
  three days with usage in its spool, set `retention.ledger_ids_days`
  higher before the new control plane starts.
- If a proxy of your own sits in front: it must send request bodies with a
  `Content-Length`, and write `X-Forwarded-For` itself if the control
  plane trusts it.
- Look at spend for the period if untrusted parties held gateway keys:
  abandoned streams were billed by a low estimate, and per-second media
  jobs without a duration were billed nothing per second.

Coming from a commit before 3a0b147, in short (the steps are in
[Deployment](deployment.md#coming-from-a-commit-before-3a0b147)):

- Update both processes. The fixes are on both sides.
- Split `.env` into `.env.control` and `.env.dataplane`; Compose will not
  start without them.
- Make sure the admin token has at least 16 characters.
- If the control plane's port or the dashboard's host name was reachable
  by anyone you do not trust: set a new admin token, delete managed keys
  you did not create, rotate the gateway keys created or rotated in that
  time, and read the audit log for key actions with `"auth": "none"`.
- If the data plane was reachable from the internet (it is meant to be):
  nothing to rotate for the crash and smuggling fixes themselves, but look
  at spend for the period if untrusted parties held gateway keys, since
  abandoned streams and some media jobs were under-billed.
- Nothing is known to have been exploited. All of it was found by reading
  the code.

## Checking a deployment

From outside, with the names of your own deployment:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://$OMNIGATE_ADMIN_HOST/internal/config
```

must print `404`, and

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://$OMNIGATE_ADMIN_HOST/admin/keys
```

must print `401` (or `403` from outside the allow-list). Port 4000 and port
8080 must not answer from outside at all.

The repository's own checks:

- `python3 tools/container_test.py --compose` builds the images, brings up
  `compose.yaml` with mock providers and checks it through the TLS proxy:
  odd spellings of guarded paths, the allow-list, malformed requests, the
  split of secrets, clean shutdown, the two memory limits, that a client
  cannot choose the address its failed sign-ins are counted under by
  sending `X-Forwarded-For`, and that a dozen failed sign-ins leave a few
  audit lines. It tests the Compose file, not your running deployment
  ([Deployment](deployment.md#testing-the-compose-file)).
- `python tools/malformed_test.py` starts a local stack with mock
  providers and sends it hostile requests. Run that way it also plays an
  upstream and a control plane that answer like an attacker, checks the
  limits that apply before a body is read, and checks that a client which
  hangs up or stops reading is still billed. With `--gateway` it tests an
  instance you started yourself, without the hostile-upstream and
  hostile-control-plane cases
  ([Operations](operations.md#hostile-input-testing)). Point it at a test
  instance, never at production.
- `python tools/check.py` runs every suite except the container test with
  one command.

What remains open is listed, without euphemism, under
[Known limits](../SECURITY.md#known-limits) in SECURITY.md.
