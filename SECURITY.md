# Security

## Reporting a vulnerability

Please report security problems privately. Do not open a public issue or
pull request for them.

> **CONTACT PLACEHOLDER. Maintainer: replace this block with the address or
> private reporting channel to use, before publishing this file.**
>
> Report to: `<security contact to be filled in>`

Include, as far as you can:

- what is affected (data plane, control plane, a tool, the container
  setup) and the commit you looked at;
- how to reproduce it, ideally against the mock providers
  (`config/omnigate.dev.json`, `tools/e2e.py`);
- what an attacker gains.

Please do not test against deployments you do not own, and do not include
real provider keys, gateway keys or tokens in a report.

There are no tagged releases yet. Fixes are made on `main`.

## Security model in brief

omnigate is two processes. The **data plane** is the public port that
applications call. The **control plane** holds configuration, the usage
ledger, media jobs and the dashboard, and is meant to stay on a private
network behind a TLS proxy. See [docs/architecture.md](docs/architecture.md).

### Three credentials, three audiences

| Credential | Held by | Sent as | Opens |
|---|---|---|---|
| Gateway key | Applications | `Authorization: Bearer` or `x-api-key`, to the data plane | Text endpoints, the jobs API and file downloads, within that key's model list, rate limit and budget |
| Internal token (`OMNIGATE_INTERNAL_TOKEN`) | The two processes | `x-omnigate-internal`, from data plane to control plane | `/internal/*` on the control plane: the config snapshot, usage intake, the forwarded jobs API |
| Admin token (`OMNIGATE_ADMIN_TOKEN`) | Operators | `Authorization: Bearer`, or once as the dashboard password | The dashboard, `/admin/*` and `/metrics` on the control plane |

None of them works in another's place.

- **Gateway keys** are stored and compared as SHA-256 hashes. The config can
  hold only the hash (`key_sha256`); the data plane only ever receives
  hashes. A key can be limited to a list of models, a request rate and a
  budget.
- **The internal token** is compared in constant time. If it is not set,
  the control plane refuses every internal request.
- **The admin token** is never open by default: if it is not set, a random
  one is generated at startup and written to the log. The dashboard
  exchanges it for a signed session cookie (12 hours, `HttpOnly`,
  `SameSite=Strict`, `Secure` when reached over TLS), so the token itself is
  sent once. Five failed logins from one address lock that address out for a
  minute.

### Provider secrets

- Provider keys, bucket credentials and (optionally) webhook secrets are
  read from environment variables. The config file only names the variables.
- Text provider keys exist only in the data plane's environment; media
  provider keys and bucket credentials only in the control plane's.
- The config snapshot sent to data planes contains no budgets, no prices and
  no secrets.
- Requests that carry a provider key do not follow redirects.

### Files and webhooks

- Outputs on local disk are served through URLs signed with HMAC-SHA256 that
  expire (one hour by default), or to the gateway key that owns the job.
  The signing key is `OMNIGATE_SIGNING_SECRET`, or is derived from the
  internal token.
- Outputs in a bucket are assumed private and handed out as presigned URLs.
- Webhooks are signed the [Standard Webhooks](https://www.standardwebhooks.com/)
  way (HMAC-SHA256 over id, timestamp and body). Receivers should verify the
  signature and the timestamp; see [docs/api.md](docs/api.md#webhooks).
- Webhook URLs must be http(s), without embedded credentials, and must not
  resolve to loopback, private or link-local addresses unless
  `media.webhooks.allow_private` is set.

### What must stay private

- The control plane's port. Expose the dashboard only through a TLS proxy
  that refuses `/internal/*` from outside, as `deploy/Caddyfile` does.
- Both tokens, the `.env` file, and the config file if it holds raw keys or
  inline webhook secrets.
- `ledger.jsonl` and `jobs.jsonl` (usage per key; job inputs, metadata and
  webhook URLs), and the media directory or bucket.
- The control plane's log, if you let it generate the admin token.

Details: [docs/deployment.md](docs/deployment.md#what-to-keep-private).

## Known limits

These come from the README's [Known gaps](README.md#known-gaps) section
and from the code. They are known, not vulnerabilities to report.

- **No TLS listener on either process.** The included Caddy proxy (or
  another) provides it. Data-plane-to-control-plane traffic over HTTPS is
  untested; keep it on a private network.
- **One shared admin token.** No user accounts, roles or audit log.
  Sessions cannot be revoked individually; changing the token ends all of
  them.
- **The login lockout counts per client address and lives in memory.**
  Behind a reverse proxy all clients share one address.
- **DNS rebinding on webhook targets is not closed.** The check against
  private addresses and the connection that follows resolve the host name
  separately.
- **Budgets are enforced after the fact**, with up to one poll interval of
  lag, and cannot newly block a key during a control-plane outage.
- **Rate limits are per data-plane process** and reset on restart.
- **The media output cache is shared across gateway keys.** An identical
  cacheable request from another key reuses the stored output.
- **Output downloads send no provider credentials**, and follow redirects.
- **Nothing has run under production load.**
