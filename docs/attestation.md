# Attested upstreams

Some providers run their models inside confidential hardware: virtual
machines whose memory the host cannot read, on processors that sign a
statement of what is running in them. That statement is an *attestation*.
omnigate can require one of an upstream, verify it itself, keep it
verified, and refuse to send a request anywhere else.

It is built for [NEAR AI Cloud](https://docs.near.ai/cloud/verification),
which runs its gateway and the models it serves itself in Intel TDX
machines, with NVIDIA GPUs that attest too. `"provider": "near"` is the one
kind there is.

Read [What a pass means](#what-a-pass-means) and
[What is not checked](#what-is-not-checked) before you rely on it.

Contents:

- [Switching it on](#switching-it-on)
- [What is verified, in order](#what-is-verified-in-order)
- [What a pass means](#what-a-pass-means)
- [What is not checked](#what-is-not-checked)
- [How it is kept verified](#how-it-is-kept-verified)
- [What the data plane does with the verdict](#what-the-data-plane-does-with-the-verdict)
- [Requests that may only go to attested providers](#requests-that-may-only-go-to-attested-providers)
- [Seeing what a provider would be sent](#seeing-what-a-provider-would-be-sent)
- [Looking at it: the admin API, metrics, logs](#looking-at-it-the-admin-api-metrics-logs)
- [The Private chat page](#the-private-chat-page)
- [Trying it against the real service](#trying-it-against-the-real-service)
- [What the control plane calls](#what-the-control-plane-calls)
- [Mixed versions](#mixed-versions)
- [What has been tested](#what-has-been-tested)

## Switching it on

An `attestation` object on a text upstream. `config/omnigate.near.json` is
a complete config that uses it:

```json
{
  "name": "near-ai",
  "kind": "openai",
  "base_url": "https://cloud-api.near.ai",
  "api_key_env": "NEAR_AI_API_KEY",
  "attestation": {
    "provider": "near",
    "accepted_tcb": ["UpToDate"],
    "gpu": "if_present",
    "max_age_s": 900
  }
}
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `provider` | string | required | `near`. Nothing else is known; anything else is refused when the file is loaded. |
| `accepted_tcb` | list of strings | `["UpToDate"]` | The platform patch statuses that count as a pass, as Intel names them: `UpToDate`, `SWHardeningNeeded`, `ConfigurationNeeded`, `ConfigurationAndSWHardeningNeeded`, `OutOfDate`, `OutOfDateConfigurationNeeded`. A revoked platform never passes. One or more. |
| `gpu` | string | `if_present` | What to do about NVIDIA GPU evidence in a model's report. `if_present`: verify it when it is there. `require`: also fail when it is missing. `skip`: never look at it (and never call NVIDIA). |
| `max_age_s` | whole number, 60 to 86,400 | `900` | How old a verification may be. The control plane verifies again after half of it. See [How it is kept verified](#how-it-is-kept-verified). |
| `measurements` | object | every list empty | Allowlists of what was measured, each a list of at most 64 hexadecimal values: `gateway_app_compose_sha256`, `model_app_compose_sha256` (64 characters each), `gateway_mr_td`, `model_mr_td` (96 characters each). An empty list accepts any value. See [What a pass means](#what-a-pass-means). |

A setting that is not understood (another field, a misspelt one, a wrong
type or range) stops the config from loading: at startup the control plane
does not start, on a reload the previous config stays in force. Apart from
`gpu` and `accepted_tcb` above, nothing switches a check off, and nothing
names another trust anchor: not a setting here, not an environment
variable.

Every model a route sends to that upstream is then attested by its
canonical name. NEAR serves some models itself and relays others to third
parties; only the first kind has an attestation. Its public model list
(`GET https://cloud-api.near.ai/v1/models`, no key needed) marks them
`"owned_by": "nearai"`. A target on an attested upstream whose model has no
attestation is simply never used; put such a model on an upstream without
the setting if you want it reachable.

## What is verified, in order

For each (upstream, model) the control plane makes up a nonce (32 random
bytes) and asks the provider for a report bound to it:
`GET <base_url>/v1/attestation/report?model=<model>&provider=near&signing_algo=ed25519&nonce=<nonce>`
with `x-no-aliasing: true`. No API key is sent; the report is public. The
answer has a report for the provider's gateway and one or more for the
model. The gateway's report and **every** model report must pass all of the
following, or the whole check fails. The code is
`control/lib/omnigate_control/attestation/` (`near.ex`, `tdx.ex`).

1. **The report claims our nonce.** A report that echoes another nonce is
   somebody else's, or an old one; it is refused before anything is fetched
   for it.
2. **The quote is a genuine Intel TDX quote** (`tdx.ex`, following Intel's
   DCAP verification as implemented in Phala's `dcap-qvl`):
   - the certificate chain inside the quote ends at the Intel SGX Root CA,
     whose certificate is pinned in the source;
   - no certificate in it is revoked, by Intel's revocation lists for the
     root and for the platform CA (both signed, both within their validity);
   - Intel's signed list of patch levels for this platform family ("TCB
     info") and its description of the quoting enclave are authentic (signed
     by a certificate under the same root) and current;
   - the quoting enclave is Intel's, in an acceptable version, and it signed
     the key the quote is signed with;
   - the quote's signature over its header and body holds;
   - the platform's patch level, looked up in that list, gives its status.
3. **The status is one the setting accepts** (`accepted_tcb`).
4. **The machine is not in debug mode**, and its other attributes are the
   ones Intel's verifier accepts (not migratable, no reserved bits, no
   service-TD extension, `SEPT_VE_DISABLE` set).
5. **The quote binds our nonce and a signing key.** Its 64 bytes of report
   data are the signing identity the report names (hashed together with the
   TLS key fingerprint when the report carries one), then the nonce. So the
   quote was produced after the nonce was, and the machine vouches for that
   key.
6. **The configuration shown is the one measured.** The report carries the
   machine's software configuration (`app_compose`: which container images,
   with which settings). Its SHA-256 must be the value the processor
   recorded at start (`MRCONFIGID`).
7. **The event log replays to the measured value.** The boot events in the
   report, hashed in order, must give the register value in the quote
   (`RTMR3`). Each event's digest is recomputed from its content.
8. **GPU evidence**, per `gpu`: the evidence in a model's report must carry
   the same nonce, and NVIDIA's remote attestation service
   (`nras.attestation.nvidia.com`) must return an overall verdict of true.
9. **The model report names the model that was asked for**, and there is at
   least one.
10. **The measurement allowlists**, where set.

## What a pass means

The provider's gateway and the machine that serves the model are genuine
Intel TDX virtual machines, on platforms in an accepted patch state, not in
debug mode, running exactly the configuration the report shows, and they
answered a number this gateway had just made up. With GPU evidence: the
model's GPUs are genuine and in a state NVIDIA accepts.

It does **not** by itself mean that the configuration is software you
trust. The checks establish "this is the hardware, and this is what runs on
it"; whether what runs on it is, say, NEAR's published inference stack
rather than something that copies prompts elsewhere is a policy question,
and the policy is `measurements`. With the lists empty, as they are unless
you fill them, any configuration on genuine hardware passes. To pin one:
take `app_compose_sha256` and `mr_td` of the gateway and the model from
`GET /admin/attestations` after reading the configuration they stand for
(the provider's verification pages say how), and put them in the lists.
They change when the provider deploys a new version, and the target then
fails until you add the new values: that is what pinning is.

## What is not checked

- **Where the images were built.** `app_compose` names container images by
  digest. Whether those digests were built from the source the provider
  publishes (NEAR documents Sigstore provenance for this) is not verified.
- **That a connection ends inside the attested machine.** A report can
  bind the TLS key of the provider's endpoint (NEAR's does when asked to).
  The gateway does not ask for that binding, and the data plane does not
  compare a fingerprint with the certificate of the connections it sends
  requests on. The connection is ordinary verified TLS to the provider's
  host name.
- **That one particular answer came from that machine.** NEAR signs
  responses with the attested keys (`GET /v1/signature/<id>`). Nothing in
  the request path fetches or checks those signatures: the data plane would
  have to hash the exact bytes it sent and received, and it does not. The
  verification function exists (`Near.verify_response_signature/5`) and is
  tested with keys made in the test; it has never seen a real signature.
  So the claim is about the provider's deployment at the time of the last
  check, not about each response. The provider's own documentation makes
  the same caveat in another form: instances of a model share one signing
  key, so even a verified signature does not tie an answer to the instance
  whose report was checked.
- **NVIDIA's verdict token.** Its content is read; its own signature is
  not checked. It is trusted because it arrives over verified TLS from
  NVIDIA's host.
- **Quote formats other than the one in use.** Every quote seen from the
  service is version 4 with a TD 1.0 body. Version 5 and TD 1.5 bodies are
  implemented from the reference and have not met a real quote. A quote
  without an embedded certificate chain is refused.
- **Media providers.** No media adapter has an attestation.

And one thing that no attestation gives: the model reads the prompt. An
enclave keeps the *operator of the machine* out; it does not keep the
software inside it from seeing what it is asked. [Redaction](privacy.md#redaction)
is what limits what the model itself is shown.

## How it is kept verified

The control plane's attestation manager
(`control/lib/omnigate_control/attestation/manager.ex`) looks at the config
once a second.

- A pair that is new, or whose upstream or setting changed, is `pending`
  and checked at once.
- A verified pair is checked again when half of `max_age_s` has passed
  (never sooner than 30 seconds), each time with a new nonce.
- A pair is `verified` only until `max_age_s` after its last pass. Nothing
  extends that but another pass.
- **A check that fails on the evidence** (a bad quote, a wrong nonce, a
  status or measurement the setting refuses, GPU evidence NVIDIA rejects)
  withdraws the pair at once.
- **A check that could not get its inputs** (the report, Intel's
  collateral, NVIDIA's verdict: a network error, a 5xx, a 429) leaves a
  pass that is still within `max_age_s` standing, and is tried again after
  5, 15, 60 and then every 120 seconds. If no check passes before the pass
  runs out, the pair is withdrawn.
- Up to four checks run at a time; one check has 120 seconds in all.
- Intel's collateral is fetched once per platform family, shared by all
  checks, and fetched again after a day, long before the documents expire
  (they are valid for about a month), so that a revocation or a newly
  required patch level is noticed. If a refetch fails, the copy at hand is
  used for as long as it is itself valid.

Nothing is kept on disk. After a restart of the control plane every pair
starts as `pending` and is verified again, which takes a few seconds (about
five for the first, with Intel's collateral to fetch; under two after).

## What the data plane does with the verdict

The config snapshot the data plane polls carries, for each target on an
attested upstream, `"attestation": {"verified": true|false, "max_age_s": N, "tcb": "UpToDate", "since": <unix seconds>}`.
The snapshot only changes when a verdict flips, not at every re-check.

A target is used only while **both** hold:

- the snapshot says `verified`, and
- the control plane has answered a config poll within the last `max_age_s`.

The second is there because a data plane keeps serving its last config when
the control plane is down, and must not keep calling a target "verified"
when nobody is verifying any more. A data plane that starts from its cached
config while the control plane is unreachable does not use attested targets
at all until the control plane answers.

Otherwise the target is passed over like one that is down: the route's next
target is tried (the attempt is recorded as `attestation_unverified`). When
that leaves no target that was tried, the answer is

```text
HTTP/1.1 503 Service Unavailable
{"error":{"code":"attestation_unverified","type":"server_error","message":"the providers of this model must prove what they run on, and none has a verified attestation right now", ...}}
```

and nothing was sent anywhere. Such refusals are counted per key like the
other refusals (`omnigate_rejected_requests_total{reason="attestation_unverified"}`).

A response that came from a target on an attested upstream carries

```text
x-omnigate-attestation: verified; tcb=UpToDate; since=1794416000
```

`since` is the Unix time from which the pair has been verified without a
gap. The header describes the provider's deployment as last checked (see
[What is not checked](#what-is-not-checked)); it is not a signature over
the response.

**How stale can "verified" be?** At most `max_age_s` after the last pass as
the control plane counts, plus, if the control plane stops answering right
at the end of that, another `max_age_s` at the data plane: twice
`max_age_s` in the worst case, half of it in the ordinary one. The two
processes compare durations, not wall clocks, so clock differences between
their machines do not matter.

## Requests that may only go to attested providers

The above protects every request to an attested upstream. The fifth part of
[privacy mode](privacy.md), `attested`, is about the request instead: it may
go **only** to a target whose attestation holds, whatever else the route
has.

On a key:

```json
{ "name": "legal-team", "key_sha256": "...", "privacy": { "redact": true, "no_store": true, "unlink": true, "attested": true } }
```

or per request, on any key:

```text
x-omnigate-privacy: attested
x-omnigate-privacy: redact, no-store, attested
```

- A target on an upstream without an attestation setting is passed over
  (`not_attested` in the attempts), and so is one whose attestation does not
  hold. If none is left: `503 attestation_unverified`, nothing sent.
- `"privacy": true` and `x-omnigate-privacy: on` do **not** include it.
  They are the three parts every gateway can do; including this one would
  refuse every request of a key that had `true` before the part existed, on
  any gateway without an attested upstream.
- Such a request is never answered from the response cache, and its answer
  is not put there: the cache does not know who wrote what it holds.
- `POST /v1/jobs` with it is refused (`503 attestation_unverified`): no
  media provider is attested.

## Seeing what a provider would be sent

```text
x-omnigate-dry-run: privacy
```

on a text request makes the gateway answer with the request as privacy mode
left it, and send nothing:

```json
{
  "object": "omnigate.privacy_dry_run",
  "sent_upstream": false,
  "protections": "redact, unlink",
  "attested_only": false,
  "replaced": {"email": 1, "phone": 1, "card": 1, "ip": 0, "secret": 0},
  "body": "{\"model\":\"private\",\"messages\":[{\"role\":\"user\",\"content\":\"Write to [EMAIL_1] ...\"}]}"
}
```

`body` is the request body after unlinking and redaction, as a string. It
went through the same code as a request that is forwarded, up to the point
where a target is chosen; what a provider is sent differs from it only in
what is done per target (the model name is replaced by the target's, a
request for a provider of the other protocol is translated, OpenAI is added
`"store": false`). The request is authenticated, rate-limited and counted
against the key's concurrency like any other; it is not billed, not written
to the ledger, and the values it replaced are counted in
`omnigate_redactions_total`. The one value is `privacy`; anything else, or
the header twice, is `400 invalid_request`, so that a request meant to stay
in the gateway is never sent on because of a typo. It is refused on
`POST /v1/jobs`.

## Looking at it: the admin API, metrics, logs

`GET /admin/attestations` (admin token or session):

```json
{
  "attestations": [
    {
      "upstream": "near-ai",
      "model": "z-ai/glm-5.3-flash",
      "provider": "near",
      "state": "verified",
      "verified": true,
      "reason": null,
      "reason_code": null,
      "checked_at": 1794416021,
      "age_s": 44,
      "verified_since": 1794415000,
      "until": 1794416921,
      "max_age_s": 900,
      "last_attempt_at": 1794416021,
      "next_check_at": 1794416471,
      "checks": 3,
      "policy": {"accepted_tcb": ["UpToDate"], "gpu": "if_present", "measurements": {"gateway_app_compose_sha256": [], "...": []}},
      "evidence": {
        "nonce": "7f2e5643...",
        "verified_at": 1794416021,
        "gateway": {"tcb_status": "UpToDate", "advisory_ids": [], "quote_version": 4, "td_attributes": "0000001000000000",
                    "report_data": "...", "signing_algo": "ed25519", "signing_address": "40599fb2...", "tls_cert_fingerprint": null,
                    "app_compose_sha256": "73dbb78c...", "mr_td": "...", "rtmr3": "...", "gpu": "skipped", "collateral_expires_at": 1797000000},
        "models": [{"tcb_status": "UpToDate", "gpu": "verified", "...": "..."}]
      }
    }
  ],
  "checks": {"ok": 3, "failed": 0, "unavailable": 0}
}
```

`state` is `pending`, `verified` or `failed`; `reason` says why in one
line, `reason_code` is the name of the check that failed
(`nonce_mismatch`, `bad_quote`, `tcb_status_not_accepted`,
`report_unavailable`, `measurement_not_allowed`, ...). `evidence` is that of
the last pass and stays there for the record after a later failure;
`verified` is the verdict. The gateway's `gpu` is always `skipped`: GPU
evidence belongs to models.

`POST /admin/attestations/verify` with `{"upstream": "...", "model": "..."}`
runs a check now, with a new nonce, waits for it, and answers with the
entry as above (`404` when the config routes no such pair to an attested
upstream). It is written to the audit log (`attestation.verify`).

Metrics (`GET /metrics`):

| Metric | Type | Meaning |
|---|---|---|
| `omnigate_attestation_verified{upstream,model}` | gauge | 1 while the pair is verified and recent enough, else 0. Alert on 0. |
| `omnigate_attestation_age_seconds{upstream,model}` | gauge | Seconds since the last pass; absent until there has been one. |
| `omnigate_attestation_checks_total{outcome}` | counter | Checks since start: `ok`, `failed` (the evidence did not hold), `unavailable` (it could not be fetched). |

Log lines of the control plane, one per change of state, never one per
check:

```text
[info] attestation: near-ai/z-ai/glm-5.3-flash verified (TCB UpToDate, signer 40599fb284f43953…)
[warning] attestation: near-ai/openai/gpt-5 NOT verified: no attestation report (HTTP 503: Provider error: No provider found that supports attestation reports for model: openai/gpt-5). Its targets are not used until it verifies.
[warning] attestation: near-ai/z-ai/glm-5.3-flash could not be checked again (...); the last pass stands until it is 900 s old
[warning] attestation: near-ai/z-ai/glm-5.3-flash was verified 912 s ago and has not been verified again: withdrawn (...)
```

## The Private chat page

`/private-chat` on the control plane (same sign-in as the dashboard, linked
from its top bar) is a chat with three panels:

- **Conversation**: what you type and the answer, with your own values.
- **What left this machine**: the last message as the provider is sent it,
  placeholders marked, from a [dry run](#seeing-what-a-provider-would-be-sent)
  of the same request.
- **Verified**: the checks of [the list above](#what-is-verified-in-order)
  for the chosen model's attested target, each of which opens to the raw
  values, the time of the last check, and a button that runs one now.

Two switches: redaction, and "attested providers only". The model list has
every text route, marked attested or not, so the refusal can be seen by
picking one that is not.

How it works, so that nothing about it has to be taken on trust: the page
adds no path around the gateway. The control plane sends each message to
the data plane's public port with an ordinary gateway key, twice: once with
`x-omnigate-dry-run: privacy`, once for real with the `x-omnigate-privacy`
header the switches ask for (always including `no-store`). The key is a
managed key named `private-chat`, created on first use; its secret is held
in the control plane's memory only, and the key is rotated after a restart
to get a new one. It is an ordinary key: it is in the key list, its usage is
billed and counted, and it can be given a budget or be disabled there (a
disabled key makes the page's messages fail with 401).

Nothing of a conversation is kept by the gateway: the page holds the
history in the browser tab and sends all of it with each message, the
control plane neither logs nor audits the body, and every request goes out
as `no-store`. The end-to-end suite sends a marked prompt through the page's
endpoint and then searches every file both processes wrote for it.

The control plane reaches the data plane at `OMNIGATE_GATEWAY_URL`, or, if
that is not set, at the config's `media.public_base_url`
(`http://127.0.0.1:8080` by default). The Compose file sets it to
`http://dataplane:8080`, the data plane's address inside the Compose
network.

Without a provider key in the data plane's environment the verification
panel works (attestation needs no key) and a chat is answered by the
provider with its own 401, which the page says.

## Trying it against the real service

```bash
python tools/near_live.py
```

needs the network and no key. It runs the control plane's attestation code
once from the command line and prints the checklist; starts both processes
with `config/omnigate.near.json` on ports of their own; waits for the
verdicts (the model NEAR serves itself verifies, the one it relays does
not); and checks that a request for attested providers only is let through
to the first and refused, unsent, on the others. With `NEAR_AI_API_KEY`
set it also sends one real completion with an e-mail address and a card
number in it, and checks that the answer has them back and the response
says `x-omnigate-attestation: verified`.

```bash
python tools/near_live.py --serve
```

starts the same on the usual ports and prints the address of the Private
chat page and the admin token.

The check alone, without starting anything:

```bash
cd control && mix run --no-start -e "OmnigateControl.Attestation.Live.main()"
```

(`main(["--all"])` for every model NEAR serves itself, `["--json"]` for the
evidence as JSON; in a release, `bin/omnigate_control eval 'OmnigateControl.Attestation.Live.main()'`.)

It is not part of `tools/check.py` or CI: it depends on three services on
the internet.

## What the control plane calls

With an attested upstream configured the control plane makes outbound HTTPS
calls it otherwise would not:

| Host | For |
|---|---|
| the upstream's own host (`cloud-api.near.ai`) | The attestation report. No API key is sent. |
| `api.trustedservices.intel.com`, `certificates.trustedservices.intel.com` | Intel's collateral: patch-level lists, the quoting enclave's identity, revocation lists. Once a day per platform family. |
| `nras.attestation.nvidia.com` | NVIDIA's verdict on a model's GPU evidence, unless `gpu` is `skip`. The evidence (public, from the report) is posted there at every check. |

Allow these if the control plane's egress is filtered. Certificates are
checked against the system's trust store; redirects are not followed.

## Mixed versions

The data plane enforces the verdict; the control plane produces it. Both
must be this version or later.

| Control plane | Data plane | What happens |
|---|---|---|
| new | old | The snapshot carries the verdict; an old data plane ignores it and **uses attested targets whether or not they are verified**, and ignores a key's `attested`. An `x-omnigate-privacy: attested` header is refused by it with 400 (it does not know the word), which is at least not a silent pass. |
| old | new | The old control plane does not know the `attestation` setting. A config with it still loads there (older code ignores fields it does not know) and nothing is verified; the new data plane sees no verdict on any target, so nothing is treated as attested and `attested` requests are refused everywhere. |

Upgrade both, data plane included, before telling anyone a route is
attested, and check `GET /admin/attestations` and a response's
`x-omnigate-attestation` header afterwards.

## What has been tested

- **Against the real service** (11 November 2026, no API key):
  `tools/near_live.py`, 11 checks. NEAR's gateway and `z-ai/glm-5.3-flash`
  verify through the running control plane, including GPU evidence accepted
  by NVIDIA; a re-check with a new nonce passes; `openai/gpt-5`, which NEAR
  relays, has no attestation and is refused; the data plane lets an
  `attested` request through to the verified model (NEAR then answers 401
  for lack of a key) and refuses it, unsent, on the other two routes. The
  standalone prototype of the same code verified all ten text models NEAR
  served itself that day.
- **Not run for lack of a key**: a real completion through an attested
  target. The request path up to NEAR's own 401 is exercised; an answer
  coming back, with redaction restored, is not.
- **Offline, on a saved real report** (`control/test/attestation_test.exs`,
  96 checks): the saved report and Intel's collateral as fetched with it
  verify at the recorded time, and each tampering fails with its own error:
  flipped bits in the quote's signature, body, attestation key and the
  quoting enclave's report; a wrong nonce in the quote and in the echo; a
  swapped signer, algorithm or TLS fingerprint; an altered configuration;
  altered, dropped and added events; tampered, expired, not-yet-valid and
  wrong-family collateral; a foreign trust anchor and a foreign root in the
  chain; revoked leaf and intermediate certificates (on a throwaway PKI);
  response signatures in both algorithms with keys made in the test.
- **The manager** (`control/test/attestation_manager_test.exs`): the
  setting's validation; pending, verified and failed; withdrawal at once on
  bad evidence; a recent pass standing through fetch failures; a model the
  provider cannot attest next to one it can; the measurement allowlists;
  pairs following the config. The trust anchor reaches verification only as
  a function argument in these tests; a test checks that no code reads one
  from the environment or the config.
- **End to end with the mock** (`tools/e2e.py`): a mock cannot produce
  evidence that verifies, so the mock upstream answers in four ways that
  must each be refused (a report with a quote that is not one, a report for
  another nonce, a web page, "no attestation for this model"); routes fail
  over past unverified targets or answer 503; the `attested` part on a key
  and in the header; the dry run; the Private chat page's endpoints. For
  the one thing the real control plane cannot be made to say in a test, a
  second data plane runs in front of a control plane played by the test
  script that calls a target verified: the data plane uses it, labels the
  response, stops using it when that control plane has been silent for
  longer than `max_age_s`, and uses it again when it answers.
- **Hostile input** (`tools/malformed_test.py`): misspelt, repeated and
  oversized `x-omnigate-privacy: attested` and `x-omnigate-dry-run` headers.
