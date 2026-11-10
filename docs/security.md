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
6. Back up the control plane's `/data` as one set, and protect the backup
   like the live data.
7. Treat the control plane's log as a secret if you let it generate the
   admin token; better, set one.
8. Update when the changelog has a "Security" entry, and rotate what the
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
deliberately opened, and it checks credentials before it reads a body. The
data plane accepts one spelling per path and refuses malformed or
ambiguous request heads ([API](api.md#request-heads-paths-and-queries)).
Do not put a proxy in front that rewrites or normalises paths.

The limits on the public port (8 MiB bodies, 16 KiB heads, timeouts, a
connection cap) bound what one client can hold. They are not a defence
against a volumetric attack; that belongs to the network in front.

## The three credentials

| | Gateway key | Internal token | Admin token |
|---|---|---|---|
| Held by | Applications | The two processes | Operators |
| Opens | Text endpoints, the jobs API and file downloads, within the key's model list, rate limit, budget and open-job limit | `/internal/*` on the control plane: the config snapshot (key hashes, upstream addresses), usage intake, and the jobs API as **any** gateway key | The dashboard, `/admin/*` (which creates and revokes gateway keys) and `/metrics` |
| Lives in (Compose) | The application's own secret store. The gateway stores only its SHA-256: in `config/omnigate.json` for a file key, in `/data/keys.json` for a managed key | `.env.control` **and** `.env.dataplane`, the same value | `.env.control` only |
| Never put it in | The config file in clear text (`"key"`) outside local trials | `.env`, the config file, an application | `.env.dataplane`, `.env`, an application |
| Strength | Generated ones are 32 random bytes; your own should be as long | Long and random; neither process starts without it | At least 16 characters or the control plane refuses to start; make it 32 random bytes |
| Guessing | An unknown key is a 401; refusals are counted per reason, with a cap on distinct series | Compared in constant time | Compared in constant time. 5 failed sign-ins, or 20 wrong bearer tokens, per address per minute, then that address is locked out for the rest of the minute |

None of them works in another's place.

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

If you do not use the Compose proxy, the equivalent is a firewall rule or
your proxy's own access control in front of the control plane's port.

## TLS

- Neither process has a TLS listener. The proxy terminates TLS for both
  host names; with real DNS names Caddy obtains and renews certificates by
  itself. (Issuance with a real domain has not been tested by this
  project.)
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

## Gateway keys

A gateway key in the wrong hands spends your provider budget. Bound each
one:

| Limit | Field | Effect |
|---|---|---|
| Which models | `models` | 403 for any other route, text or media. |
| How fast | `rpm` | 429 beyond it. Per data-plane process for text; job creation is counted again in the control plane. |
| How much | `budget_usd` with `budget_period` | 402 once spent. Enforced after the fact: the call that crosses the line completes. |
| How many media jobs at once | `max_open_jobs` (default 100, from `media.max_open_jobs`) | 429 `too_many_open_jobs` beyond it. |

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
- The host is resolved once, every address is checked, and the connection
  goes to the checked address, so a DNS answer that changes between the
  check and the call cannot redirect it.
- Webhook deliveries do not follow redirects. Output downloads follow at
  most five, each checked the same way.
- `allow_private: true` switches all of this off, for webhooks **and**
  output downloads. It exists for local development against the mocks.
- Egress filtering on the control plane's host is still worth having; the
  checks above are in the application, not in the network.

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

## Backups of `/data`

The control plane's `/data` volume is the installation: the ledger
(segments and both snapshots), `jobs.jsonl`, `keys.json`, the audit log and
locally stored outputs. How to take and restore a copy is in
[Deployment](deployment.md#backups). From a security point of view:

- **A backup is as sensitive as the live volume.** `jobs.jsonl` holds every
  job's input (prompts), metadata and webhook URL; `keys.json` holds key
  hashes and, in clear text, the webhook secret of any managed key that has
  one; the ledger holds usage per key; the audit log holds operators'
  addresses. Encrypt backups and restrict who can read them.
- **Take the directory as one set, from one moment**, with the control
  plane stopped. Once `retention.ledger_days` has deleted old segments,
  the two snapshot files are the only copy of those totals.
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
- **What the control plane logs:** start-up, config reloads, job failover,
  errors with a request id. Provider error text can appear in job lines.
- **Your proxy's access log is yours to decide.** `deploy/Caddyfile` does
  not turn one on. If you do, remember that proxies usually record the
  full request URI: signed file URLs would then be in that log, usable
  until they expire.
- **Watch for:** `omnigate_rejected_requests_total` rising for
  `invalid_api_key` or `invalid_request`; `login` entries with outcome
  `denied` or `throttled` in the audit log; key actions you did not make;
  a data-plane container that restarted with exit code 70 (a panic: the
  log has one `error(panic): ...` line; report it).
- Wrong bearer tokens are counted and throttled but not written to the
  audit log; failed sign-ins are.
- Ship logs somewhere the containers cannot rewrite them if you rely on
  them after an incident.

## Staying current, and upgrade notes

No release has been tagged, so "current" means a recent commit of `main`.

- Read the "Security" section of [CHANGELOG.md](../CHANGELOG.md) before
  every update, and [SECURITY.md](../SECURITY.md#past-advisories) for what
  each fix means for an installation that ran the older code.
- An update is `git pull` and `docker compose up -d --build`
  ([Deployment](deployment.md#upgrades)). Take a backup of `control-data`
  first.

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
  split of secrets, clean shutdown. It tests the Compose file, not your
  running deployment.
- `python tools/malformed_test.py` starts a local stack with mock
  providers and sends it hostile requests; with `--gateway` it tests an
  instance you started yourself
  ([Operations](operations.md#hostile-input-testing)). Point it at a test
  instance, never at production.
- `python tools/check.py` runs every suite except the container test with
  one command.

What remains open is listed, without euphemism, under
[Known limits](../SECURITY.md#known-limits) in SECURITY.md.
