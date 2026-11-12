# Changelog

All notable changes to omnigate are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The first
tagged version is the pre-release 0.1.0-rc.1.

When a release is cut, the "Unreleased" section is renamed to
`## [<version>] - <date>` and a new, empty "Unreleased" section is started
above it. The release workflow publishes the section whose heading starts
with `## [<version>]` as the release notes, so keep that heading format;
see [docs/releasing.md](docs/releasing.md).

Which features have been checked against real providers, and which have
only met a mock, is tracked in the README's
[What has been verified](README.md#what-has-been-verified) section and in
`docs/`, rather than here.

## [Unreleased]

### Added

- **Attested upstreams** ([docs/attestation.md](docs/attestation.md)). A
  text upstream can carry `"attestation": {"provider": "near", ...}`: the
  control plane then verifies NEAR AI Cloud's TEE attestation for every
  model routed there and keeps it verified, and the data plane only uses a
  target while that holds. The verification is the gateway's own code on
  OTP's `:crypto`: the Intel TDX quote, its certificate chain to Intel's
  pinned root, revocation lists, Intel's signed patch-level lists, the
  quoting enclave's identity, debug mode, the nonce and signing-key
  binding, the measured configuration, the event log, NVIDIA's verdict on
  GPU evidence, and optional allowlists of measurements. A check that fails
  on the evidence withdraws the target at once; one that cannot fetch its
  inputs leaves a recent pass standing until `max_age_s`. The data plane
  also stops counting a verdict when its control plane has been silent for
  longer than `max_age_s`. Unverified targets are passed over; with none
  left the answer is `503 attestation_unverified`.
- **Privacy mode, fifth part: `attested`.** On a key (`"privacy":
  {"attested": true}`) or per request (`x-omnigate-privacy: attested`): the
  request goes only to a target whose attestation is verified right now,
  and is refused otherwise. Not part of `"privacy": true` or of the
  header's `on`. Responses from an attested target carry
  `x-omnigate-attestation: verified; tcb=...; since=...`.
- **A privacy dry run.** `x-omnigate-dry-run: privacy` on a text request
  answers with the request as privacy mode left it and sends nothing.
- **The Private chat page** (`/private-chat` on the control plane; only
  present while the config has an upstream with an `attestation` setting): the
  conversation, what the provider is sent for it, and the attestation
  checklist with its raw values and a "verify again now" button. It sends
  through the data plane with a managed key of its own (`private-chat`) and
  keeps nothing. `OMNIGATE_GATEWAY_URL` tells the control plane where the
  data plane is.
- **A receipt for each answer from an attested upstream**
  ([docs/attestation.md](docs/attestation.md#a-receipt-for-each-answer)).
  The data plane hashes the exact request body it sent and the exact
  response body it received and reports the two hashes with the provider's
  completion id (no content); the control plane fetches the provider's
  signature (`GET /v1/signature/<id>`), checks that it covers exactly those
  hashes, that it is valid, and that its key is the key of exactly one
  report verified before the request, and keeps the result:
  `GET /v1/attestations/<request id>` for the key that made the request,
  `GET /admin/receipts` for the operator, `omnigate_receipts{verdict}`,
  `retention.receipts_days`, `OMNIGATE_RECEIPTS`. Anything missing, late,
  unknown or ambiguous is `not_verified`. `tools/verify_receipt.py` checks
  a receipt offline against the two bodies (standard library only). The
  Private chat page shows the receipt of each answer and offers it as a
  download. Requests to an attested upstream now carry
  `x-no-aliasing: true`.
- `GET /admin/attestations`, `POST /admin/attestations/verify`, and the
  metrics `omnigate_attestation_verified`, `omnigate_attestation_age_seconds`
  and `omnigate_attestation_checks_total`.
- **ElevenLabs beyond speech** ([docs/providers.md](docs/providers.md#elevenlabs)).
  A target on an `elevenlabs` upstream may name `"api"`: `"sound"` (sound
  effects), `"music"`, `"image"` or `"video"` (the image and video models
  ElevenLabs relays, as jobs that are polled); without it the target is
  text to speech, as before. `input.duration` is the length in seconds for
  every product and is what `max_seconds` and per-second prices apply to;
  it is sent under the provider's own field name, and those names are not
  taken from the request. Music from a composition plan is billed for the
  sum of its sections. Not supported: the products that take an uploaded
  file (speech to text, dubbing, voice changer, audio isolation).
- `config/omnigate.near.json`, `tools/near_live.py` (the integration
  against the real service; `--serve` starts the gateway with that config)
  and `OmnigateControl.Attestation.Live` (the check alone, from the command
  line).

- **Built to be built around** ([docs/building-on-omnigate.md](docs/building-on-omnigate.md)).
  Three additions for programs that stand next to the gateway, and a page
  that says which interfaces they can rely on:
  - `POST /admin/keys/{name}/topup` adds `amount_usd` to a managed key's
    total budget once per `reference` (a payment id). The budget and the
    reference are written together; the same call again adds nothing and
    says `"replayed": true`; the reference with another key or amount is
    `409 reference_conflict`; a key without a total budget is
    `409 not_prepaid`. Audited as `key.topup`.
  - `GET /admin/events?after=&limit=&key=` is a usage feed: every recorded
    text request and media job, oldest first, by cursor, by key name, with
    no content and no key hash. It says so (`"gap": true`) when retention
    deleted events a reader had not reached.
  - `x-omnigate-tag` on a text request or `POST /v1/jobs` is the caller's
    label for it, recorded in the ledger and shown in the feed; never sent
    to a provider, in no metric. A value outside 1 to 64 letters, digits,
    `.`, `_`, `:`, `-` is refused with 400 rather than dropped.
  - `examples/`: a tool-calling agent client, a prepaid top-up service
    with a file as its payment source, and a usage exporter to CSV, each
    run by `tools/e2e.py` against the mock providers.
- **Prepaid credit as one rule** ([docs/credits.md](docs/credits.md)),
  whoever paid and however. A key with a total budget holds credit: one
  credit is one US dollar when it is added, the balance is top-ups plus
  bonuses minus burns, and a key at or below zero is blocked. Credit cannot
  be withdrawn or refunded.
  - **A burn multiplier.** `credits.burn_multiplier` (1 unless set), or a
    key's own `burn_multiplier`: a request burns what the provider cost
    times it. Usage records, the events feed, the key listing and the
    metrics show both the provider cost and the credit burned.
  - **Where credit came from.** A top-up carries a `source` (`source` on
    `POST /admin/keys/{name}/topup`; `admin` unless given). All credit is
    the same otherwise.
  - **A weekly bonus** on the time-weighted average of the balance over the
    ISO week, at `credits.bonus_annual_rate` ÷ 52 (0, that is off,
    unless set). Credited as a top-up of its own under
    `bonus:<key>:<ISO week>`, so a week is credited once whatever happens,
    including weeks that ended while the control plane was not running.
  - `GET /admin/topups`: applied top-ups and bonuses. Top-ups and bonuses
    are also events of `"kind": "credit"` in `GET /admin/events`.
  With the defaults (multiplier 1, rate 0) a prepaid key behaves as before.
- **Payments, opt-in** ([docs/payments.md](docs/payments.md)). With a
  `payments` section in the config, the holder of a prepaid managed key
  buys credit through a payment provider, also when the key is blocked:
  `GET /v1/payments/assets`, `POST /v1/payments/quote`, `POST /v1/payments`
  (a deposit address and the amount to send), `GET /v1/payments/{id}`,
  `GET /v1/payments`, `POST /v1/payments/{id}/tx`; `GET /admin/payments`
  for operators. Without the section the endpoints answer 404 and nothing
  else changes.
  - Payments are a provider interface with one adapter, **NEAR Intents**
    (its 1Click API): the payer pays with any asset it lists, on any chain
    it supports; the operator's NEAR account receives the settle asset
    (native USDC on NEAR unless set).
  - The gateway holds no keys, signs nothing and moves no funds. It
    verifies 1Click's Ed25519 signature on every quote (against the key
    pinned from 1Click's SDK) and that the quote repeats what was asked
    before it shows a deposit address; it believes a status only about the
    quote it stored; and it credits a settlement once, through the
    idempotent top-up, under `near_intents:<deposit address>`. That the
    funds arrived is the provider's word: said plainly in the docs.
  - `examples/agent_pays.py`: on a 402, list the assets, start a payment,
    print what to send where, wait for the settlement, try again.
  - `tools/mock_intents.py` (a stand-in for 1Click that signs like it) and
    `tools/near_intents_live.py` (the real asset list and dry quotes through
    a running gateway; `--serve` for one real payment by hand).

- **A site** (`site/`): a landing page, and the pages of `docs/` rendered
  to static HTML by `python site/build.py` (needs
  `pip install -r site/requirements.txt`; everything else in the repository
  still needs the standard library only). `docs/` stays the source. The
  build fails when a link between two pages names a page or a heading that
  does not exist, and CI runs it. The pages load nothing from another host.

### Changed

- `tools/e2e.py` keeps the managed keys and the audit log of a run in the
  run's own directory (they were in `control/data/`, shared between runs).
- `GET /admin/keys` and the config snapshot: a key's `privacy` object has a
  fifth field, `attested`. A target in the snapshot may carry
  `attestation`.
- The error text for a malformed `x-omnigate-privacy` header names
  `attested` among the parts.
- A key with a total budget is blocked when its **credit burned** reaches
  the budget: its cost times its burn multiplier. At the default multiplier
  of 1 that is its cost, as before. `period_spend_usd` of such a key, and
  the dashboard's "spent" figure, are the credit burned.
- `GET /admin/events`: every event has `credits_usd`; events of
  `"kind": "credit"` (top-ups, bonuses) are new. `examples/usage_export.py`
  writes them with `amount_usd`, `source` and `reference` columns.
- The audit log has entries written by the gateway itself
  (`"auth": "system"`, no address): `key.bonus` and `payment.*`.
- `credits` and `payments` in a config file are now read and checked;
  before, they were unknown sections and ignored.
- The data plane's answer when the control plane cannot be reached says
  "this endpoint is served by the control plane" (it named media jobs).

### Fixed

- **A private media job could be read as finished before its input was
  erased.** It became terminal in one write and lost its input and metadata
  in a second, so a `GET /v1/jobs/{id}` in between showed `succeeded` with
  the input still there and without `input_erased`. Both now happen in the
  write that ends the job (for a canceled job with an open provider call,
  in the write that closes its account); the files are deleted right after,
  and again at the next start if a stop came in between.

### Verified

- Against the real NEAR AI Cloud on 11 November 2026: `tools/near_live.py`,
  11 checks without an API key and 27 with one (see
  [docs/attestation.md](docs/attestation.md#what-has-been-tested)): a real
  completion with redaction through the attested target, and a whole and a
  streamed completion whose receipts verified (signed by the model's
  machine and by NEAR's gateway respectively) and were confirmed by
  `tools/verify_receipt.py` from the bytes sent and received.
- Not implemented, and said so in the documentation: image provenance, and
  binding the data plane's TLS connections to the report.
- Against the real ElevenLabs API on 11 November 2026, through the gateway:
  one sound effect (0.5 s) and one piece of music (3 s) generated,
  re-hosted and billed; the image and video endpoints refused the test
  workspace's plan (`402 paid_plan_required`), and that refusal failed the
  job cleanly or moved it to the next target. A successful image or video
  job has only run against the mock.
- Against the real NEAR Intents 1Click API on 11 November 2026, without
  funds (`tools/near_intents_live.py`): the asset list (229 assets on 39
  chains) and dry quotes for NEAR, Ether, Bitcoin, SOL and USDC on Base and
  Arbitrum through a running gateway, each with its signature verified; the
  provider's refusals relayed in its words. It showed that the service signs
  a Bitcoin quote under the asset's other listed id, which the adapter now
  accepts for ids the provider's own list gives the same coin. **No payment
  has been made**: everything after a deposit has only met the mock.

## [0.1.0-rc.1] - 2026-11-11

The first pre-release: the first version to be tagged and published. Nothing
in it has run under production load.

### Added

- **The license terms travel with every copy.** Each release archive holds
  `LICENSE`, `COMMERCIAL.md` and a short `README.txt` next to the binary,
  and both container images carry the same three files in `/licenses`
  (checked by the container test) and the label
  `org.opencontainers.image.licenses`.
- **`tools/upgrade_test.py`**: builds an older commit in a temporary git
  worktree, lets it write realistic state, stops or kills it, and checks
  that the current build reads everything back exactly; `--mixed` runs old
  and new processes side by side. Run from 10bc009 and 6d5ed6e; see
  [Tested upgrades](docs/upgrading.md#tested-upgrades).
- **`tools/privacy_soak.py`**: sustained mixed load with private and
  ordinary keys side by side, every request with values of its own, with
  checks for restored answers, cross-request leaks, what the providers
  received, exact billing, memory and what is left on disk. `MOCK_WATCH`
  and `GET /__watch` in `tools/mock_upstream.py` support it. Three
  16-minute runs against ReleaseSafe builds (279,469, 816,757 and 798,604
  requests) found no wrong answer, no value of another request in any
  answer, no private value at the providers or on disk, and no billing
  difference; the first two found the memory growth described under
  "Fixed".

- **Sume as a media provider** (kind `sume`): one adapter for Sume's image
  and video routers. A target says which router its model is on
  (`"router": "image"` or `"video"`). Submits carry an idempotency key
  derived from the job, so a submit that is sent twice starts one job at
  Sume; polls follow the interval Sume asks for; a job is canceled at Sume
  only while Sume says it can be, and otherwise polled on and billed if it
  completes. Written from Sume's public documentation; one real image job
  and one real video job have run through it, the rest only against a mock. See
  [docs/providers.md](docs/providers.md#sume).
- **Price variants** (`price.variants` on a media target, any kind): rates
  per second, per output, per job or per character that depend on fields
  of the request, such as resolution or audio. A request with no priced
  variant is refused with `400 invalid_request` when the job is created.
  Prices without variants work as before. See
  [docs/configuration.md](docs/configuration.md#price-variants).
- A per-second price is applied to the seconds the provider reports for
  its result, where an adapter reports them (today: `sume`), instead of
  the seconds requested.

### Changed

- **Both images are built from the repository root** (`docker build -f
  dataplane/Dockerfile .`, and `build: {context: ., dockerfile: ...}` in
  `compose.yaml`), so that the license files can be copied in. A root
  `.dockerignore` replaces the two per-directory ones. Your own build
  commands or Compose files need the same change
  ([Upgrading](docs/upgrading.md#010-rc1)).
- The version is `0.1.0-rc.1` in `control/mix.exs` and
  `dataplane/build.zig.zon`.
- An adapter's cancel may now report that the provider can no longer stop
  the job; the runner then treats the job as on a provider without cancel
  (polled to the route's timeout, billed if it completes). No existing
  adapter does so.

### Fixed

- **The data plane's memory grew with every request in optimized builds**
  (the ReleaseSafe build that the images and the release binaries are).
  It used Zig's `smp_allocator`, which keeps freed memory on the list of
  the thread that freed it; a request's memory is allocated and freed on
  different threads (the upstream exchange and the body pump run as their
  own tasks so that they can be timed out), so the freeing threads' lists
  grew while the allocating threads mapped fresh memory. Measured: about
  0.3 to 0.6 kB per request that was never used again, 16 MiB a minute at
  850 requests a second in a mixed load (246 to 565 MiB over 16 minutes and
  still rising), 36 to 42 MiB a minute for two clients doing plain chat at
  a thousand requests a second. Not a leak in the program: the Debug build
  stayed at 11 MiB under the same load. Optimized builds now use the
  allocator the Zig runtime hands a ReleaseSafe program, which returns
  freed memory; the same mixed load then holds 212 MiB flat, at the same
  throughput (798,604 requests in 16 minutes, 212 to 213 MiB throughout,
  on Windows; the Linux release binary, run for 8 minutes inside WSL, held
  304 to 317 MiB and about 2,300 memory mappings).
  Earlier load tests were too short and too slow to show it.
  Found by `tools/privacy_soak.py`.
- **The data plane did not finish stopping when its control plane was
  slow.** A stop request that arrived while a call to the control plane was
  under way cancelled that call; the config poll, the usage reporter and
  the counter flush each took the cancellation for an ordinary failure,
  slept again, and the process never exited (under Docker: killed after
  the stop timeout). Undelivered usage was in the spool either way. Seen on
  Windows with the control plane stopped; on Linux it takes a control
  plane that does not answer. Found by the upgrade test.
- **Calls from the data plane to the control plane had no time limit.** A
  control plane address that swallows packets, or a control plane that
  accepts a request and never answers, held the caller indefinitely: a
  data plane started in that state did not open its port (so it served
  nothing from its cached config either), and one unanswered call stopped
  the config poll or the usage reporter. Each call is now given up after
  10 seconds, 2 seconds for the last attempts at a stop. Found while
  trying the release build's smoke test on a machine where a closed port
  does not refuse.

### Verified

- Re-ran the real-provider checks with real keys on the rewritten HTTP client and response reader (11 November 2026): OpenAI, Anthropic, Gemini, xAI, Replicate, ElevenLabs and Cloudflare R2 all pass. fal has still not completed a job.

### Security

**Third review (November 2026), fixed in the commit that follows 1cc721f.**
A third independent review found no way past authentication and no crash,
and one high, five medium and seven low findings, all fixed here with a
regression test each. Advisories for the first five are in
[SECURITY.md](SECURITY.md#past-advisories); what an installation can
notice is in [docs/upgrading.md](docs/upgrading.md#the-third-review-commit).
Update both processes; nothing needs rotating and nothing changes on disk
that older code cannot read.

- **High: one failed write to a provider could take that provider away
  until a restart** (data plane). A request that could not be written in
  full, was cancelled by the upstream timeout while being written, or got
  no response head, left its socket in the HTTP client's pool marked as
  ready; every later request to that upstream was handed the dead socket,
  failed and put it back. A provider that resets an idle connection while a
  large request is being sent to it was enough. A connection now goes back
  to the pool only when the exchange ended at a clean message boundary;
  everything else closes it. The same rule holds for calls to the control
  plane.
- **Medium: a provider that reads JSON more loosely than the gateway could
  be sent another model or an unmetered stream.** `"Model"`, `"STREAM"`,
  `"ſtream"` and `"Include_Usage"` are not the fields the gateway acts on,
  but they are to a parser that ignores case. Such names are refused (400
  `invalid_request`), as are a `stream` or `stream_options.include_usage`
  that is not `true`, `false` or `null`. Independently, an event stream
  that ends without the provider's usage figures is now billed an estimate
  (`"estimated": true`) instead of nothing, which also covers providers
  that ignore `stream_options`.
- **Medium: a job's `webhook_url` and `metadata` were held in memory
  without a limit of their own** (control plane). The URL is capped at
  2,048 bytes and metadata at 16 KiB (413); a list of jobs leaves out
  metadata over 1 KiB (`"metadata_omitted": true`).
- **Medium: cancelling a media job after the provider call had started
  made that call free**, and let a key run more provider calls at once
  than `max_open_jobs`. A job cancelled while its provider call is in
  flight stays out of the ledger and in the open-jobs count until the
  runner knows how the call ended; a call that completed is billed on the
  cancelled job (`cost_usd`), and nothing of it is fetched or kept.
- **Medium: a provider's answer could fill the disk.** Outputs per job are
  capped (`media.max_outputs_per_job`, 16) and so are their bytes together
  (`media.max_job_output_bytes`, 2 GiB); a download that fails or a type
  hint that is not text no longer leaves files in the download directory,
  which is also swept at start.
- **Medium: quadratic CPU in the filter that hides the usage chunk** (data
  plane): an upstream that sent one long event a byte at a time cost a
  megabyte of searching per byte. The search now resumes where it stopped.
- **Low:** the admin throttles count an attempt before comparing the
  secret, so parallel guesses cannot all slip through one check; a write
  to a peer that stops reading ends at the request's timeout (it could
  block for ever); outputs in a bucket get the same reduced content type
  as ones the gateway serves; names are matched to the end of the string
  (`\A...\z`), so a key name cannot end in a newline; an IPv4 client on a
  dual-stack socket is throttled as itself, not as one /64 with every
  other IPv4 client; a managed key keeps its lifetime spend past its 51st
  rotation; and output and webhook URLs are only fetched from public
  unicast IPv6 (`2000::/3`), which closes `::ffff:0:a.b.c.d`.

Five commits fix what two independent reviews of the code found in
November 2026: 97cf396, fde530c and 3a0b147 after the first review,
e4e30e4 (data plane) and d79406b (control plane) after the second.
Everything was found by reading the code and small proofs of concept;
**nothing is known to have been exploited.** The full advisories, one per
class, are in [SECURITY.md](SECURITY.md#past-advisories).

**What to do, for everyone who ran an earlier commit:**

1. Update **both** processes to d79406b or later. The fixes are on both
   sides. Read [docs/upgrading.md](docs/upgrading.md) first: it lists what
   changes on disk, which defaults changed, what clients will notice and
   the order to upgrade in. In short: back up the control plane's data
   directory, check the config file against the stricter validation,
   upgrade the control plane, then the data planes.
2. If the control plane's port, or the dashboard's host name behind the
   Compose proxy, could be reached by anyone you do not trust: set a new
   admin token, delete managed gateway keys you did not create, rotate the
   gateway keys that were created or rotated in that time, and look in the
   audit log for key actions with `"auth": "none"`.
3. Compose users: split `.env` into `.env.control` and `.env.dataplane`
   (Compose will not start without them), and make sure the admin token is
   at least 16 characters long. See
   [docs/deployment.md](docs/deployment.md#coming-from-a-commit-before-3a0b147).
4. If you bill or budget from the ledger and hand gateway keys to parties
   you do not fully trust, compare the period before the update with your
   providers' invoices.
5. After the second pair of commits there is nothing to rotate, but there
   are settings to look at: `default_seconds` on media targets priced per
   second (a job without a duration is now refused otherwise);
   `retention.ledger_ids_days` if a data plane can hold undelivered usage
   for more than three days; the memory limits of the Compose file against
   the data plane's memory budgets; `OMNIGATE_MAX_CONCURRENT_PER_KEY` if
   your keys are held by strangers; and any proxy in front of the data
   plane that sends request bodies chunked (they now answer 411).

**What was wrong:**

- **Authentication bypass on the control plane (97cf396).** A request whose
  first path segment was percent-encoded (`/%61dmin/keys`,
  `/%69nternal/config`, `/%6Detrics`) skipped the admin-token,
  internal-token and CSRF checks and still reached its handler, because the
  checks looked at the path as sent while the router matched the decoded
  one.
  - *Who was affected:* anyone whose control plane, or dashboard host name,
    was reachable by someone they do not trust. Such a caller needed no
    credential to use the whole admin API (including creating, rotating and
    deleting gateway keys), to read `/metrics`, and to use `/internal/*`.
    The admin token, the internal token and provider keys were not
    revealed.
  - *The fix:* a path with any encoded character is refused with 400 before
    routing; an unknown first path segment is a 404 at the check; and
    credentials are checked before the body is parsed.
- **Remote crashes of the data plane (fde530c).** A header line without a
  colon, or a `POST` without a length, ended the gateway process with one
  unauthenticated request; JSON nested 256 levels deep did the same with a
  valid key. One process serves every connection, so each crash dropped
  every request in flight.
  - *Who was affected:* every deployment; the data plane is the public
    port. Nothing was disclosed.
  - *The fix:* request heads and JSON nesting are validated before any code
    that asserts on their shape; a panic, should one still happen, logs one
    line and exits with status 70.
- **Request smuggling into the internal API (fde530c).** The data plane
  pasted the client's request target into the URL of its call to the
  control plane and copied `Idempotency-Key` unchecked. A request line or
  header value with bare line feeds could carry a second request, or extra
  headers, which the gateway then sent to `/internal/*` with its own
  internal token.
  - *Who was affected:* deployments whose data plane was reachable by
    parties they do not trust. The path the regression test replays uses a
    valid gateway key; assume the keyless one (signed file URLs) was open
    too. Usage events could have been written under any key.
  - *The fix:* strict request heads, one canonical spelling per path, a
    small character set for query strings and copied headers, and a URL
    built from parsed parts.
- **Billing evasion (fde530c, 3a0b147).** A client that disconnected
  mid-stream was billed only what had been metered, usually nothing for an
  OpenAI-style stream. The usage scanner matched token-count keys anywhere
  in a response, including in text a client could get echoed. Media jobs
  were priced from the client's own `duration` and text fields, a negative
  duration lowered the price, and `POST /v1/jobs/` (with a trailing slash)
  created jobs without being rate limited.
  - *Who was affected:* operators who give gateway keys to parties they do
    not fully trust. A key holder could use provider capacity the ledger
    did not record.
  - *The fix:* abandoned streams are billed (real figures within
    `OMNIGATE_ABORT_DRAIN_MS`, an estimate otherwise); usage is read only
    from real usage objects; media cost follows what the adapter sent, with
    every part clamped at zero; job creation is rate-limited and capped in
    the control plane.
- **Server-side request forgery through provider outputs (3a0b147).** The
  control plane downloaded job outputs from whatever URL a provider's
  answer named, following redirects, with no check on the address. A
  steered answer could make it fetch an internal address and store the
  response as a downloadable job output. The private-address list used for
  webhooks also missed several IPv6 forms and special-purpose ranges.
  - *Who was affected:* deployments with media routes whose control plane
    can reach internal HTTP services, where job creators or a provider are
    not fully trusted.
  - *The fix:* output URLs go through the same guard as webhook URLs
    (resolve once, check every address, connect to the checked address),
    redirects are followed one checked hop at a time, at most five, and the
    list of refused ranges follows the IANA registries.
- **Other hardening from the same review (fde530c, 3a0b147).** Stored
  outputs are served as downloads with `nosniff` and a sandboxing
  `Content-Security-Policy` instead of inline with a provider-declared
  type; wrong admin bearer tokens are throttled; a short admin token stops
  the start; each container gets only its own secrets; a release build
  refuses to start without `OMNIGATE_CONFIG` instead of using the
  development config; learned provider quirks are per gateway key; log
  lines escape control bytes; the control plane speaks HTTP/1.1 only.

- **Resource exhaustion of the data plane by a valid key (e4e30e4).** A
  request body was read and parsed into a JSON tree before the key's rate
  limit was consulted, and nothing bounded what the tree cost or how many
  requests a key had in flight. One 8 MiB body of tiny values took 1,096
  MiB at its peak; one body of colliding keys took 4 seconds of CPU; a
  chunked request body with an oversized chunk size reached a decoder that
  overflows.
  - *Who was affected:* deployments that give gateway keys to parties they
    do not fully trust, or whose keys can leak. Any valid key was enough,
    whatever its `rpm` or model list, to exhaust the gateway's memory or
    CPU and end the process for everyone. Without a key there was no
    exposure, and nothing was disclosed.
  - *The fix:* the key's requests in flight, the memory its requests hold
    and its rate limit are checked before the body is read; a
    same-protocol request is forwarded without building a tree; trees that
    are needed are built in capped, budgeted arenas with bounded objects;
    chunked request bodies answer 411. The same attack body now peaks at
    30 MiB and the collision body costs nothing measurable.
  - *What to do:* update the data plane; then size the new limits
    (`OMNIGATE_MAX_CONCURRENT_PER_KEY`, `OMNIGATE_REQUEST_MEMORY_MB`,
    `OMNIGATE_PARSE_MEMORY_MB`). Clients must send a `Content-Length`.
- **Crashes of the data plane from malformed upstream responses
  (e4e30e4).** Three responses from an upstream ended the gateway process:
  a chunk size too large for its integer, a body shorter than its declared
  length (the length had been promised to the client), and a head with
  both a length and chunked encoding. A content type with a bare line feed
  could add a header line to the gateway's answer.
  - *Who was affected:* every deployment, to the degree that someone else
    can decide what an upstream answers: the provider itself, anything on
    the path to an upstream reached over plain HTTP, or whatever answers
    on the control plane's address. A buggy upstream that truncated a
    response could do it by accident.
  - *The fix:* the gateway frames and reads upstream (and control-plane)
    response bodies itself, with every size bounded, and frames its own
    answers; an upstream's length is never forwarded.
  - *What to do:* update the data plane. Note that file downloads over 64
    KiB are now sent chunked, without a `content-length`, and that a
    response an upstream cuts short ends with a dropped connection.
- **Memory exhaustion of the control plane through webhook receivers
  (d79406b).** Outbound responses were buffered whole. A client-chosen
  webhook receiver that answered with an endless body ran the control
  plane out of memory, and the delivery that did it had not used up an
  attempt, so it was repeated after the restart.
  - *Who was affected:* deployments with media routes where a key that can
    request webhooks is held by a party they do not fully trust, or where
    a media provider is not fully trusted. While the control plane is
    down, the jobs API, the dashboard and usage intake stop; text traffic
    goes on. Nothing was disclosed.
  - *The fix:* every outbound response is read through a cap (16 KiB for
    a webhook receiver, 4 MiB for provider and bucket API answers, the
    output limit for downloads and inline media); a webhook attempt is
    recorded before it is sent; deliveries are capped at 16 overall and 4
    per key; jobs per key per day are capped; Compose sets memory limits.
  - *What to do:* update the control plane.
- **Crash of the control plane by text that is not valid UTF-8
  (d79406b).** A provider's error body or an `X-Forwarded-For` header with
  such bytes made the JSON encoder raise inside the job store or the audit
  log; four such crashes within five seconds stopped the whole control
  plane, listener included. While the ledger restarted, keys over their
  budget could be handed to data planes as unblocked.
  - *Who was affected:* deployments with media routes whose provider can
    return such bytes in an error; and deployments whose control-plane
    port could be reached directly (or through a proxy that forwards the
    client's `X-Forwarded-For`) by someone they do not trust, without any
    credential. Nothing was disclosed.
  - *The fix:* outside text is made valid UTF-8 before it is logged,
    stored or encoded; the stores answer errors instead of dying and
    restart as a group without touching the listener; the config snapshot
    is refused (503 `not_ready`) until the ledger's totals are loaded.
  - *What to do:* update the control plane.
- **Other hardening from the second review (e4e30e4, d79406b).** A
  per-second media price is no longer skipped when the client leaves the
  duration out, and routes can restrict and price input options; an
  abandoned stream is read to its end in the background and billed the
  provider's figures; a client that stops reading is given up on after 30
  seconds; the admin token cannot be probed outside the throttle; request
  bodies are parsed only for authenticated callers and the sign-in form;
  failed sign-ins are aggregated in the audit log; whole-number settings
  are validated strictly; the usage spool never blocks a start; the
  included proxy sets `X-Forwarded-For` itself.

### Added

**Privacy mode (the commit after 8421df7).** A setting per gateway key
(`"privacy": true`, or part by part), which a request can add to with
`x-omnigate-privacy` and never take from. What each part does and does not
do is in [docs/privacy.md](docs/privacy.md); what an installation notices is
in [docs/upgrading.md](docs/upgrading.md#the-privacy-mode-commit).

- **Redaction** (`redact`; data plane, `dataplane/src/redact.zig`): e-mail
  addresses, phone numbers, payment card numbers (Luhn-checked), IPv4 and
  IPv6 addresses and common secret formats (provider keys by prefix, AWS
  keys, JWTs, bearer tokens, PEM private keys) in the text of a request to
  the six text endpoints are replaced by placeholders (`[EMAIL_1]`, stable
  per request, numbered in order of appearance) before a provider sees
  them. The originals are put back in the answer: whole answers, event
  streams (a placeholder cut across events is held until its other half
  arrives; nothing else waits), tool-call arguments, translated answers and
  quoted errors. One pass over the client's bytes, no tree; every detector
  is bounded, and the unit tests hold the scanner to linear work on text
  built to be expensive. At most 16,384 distinct values per request
  (`400 too_many_redactions` beyond). Names are not detected. Counted per
  key and class: `omnigate_redactions_total`.
- **No retention** (`no_store`): no response cache for the key; OpenAI's
  `"store": false` on chat completions and Responses (upstreams on
  `api.openai.com`, or marked `privacy_store_flag`). A private media job
  keeps its input and metadata out of the job log (in files of their own),
  erases them when it ends, before its webhook goes out, keeps only the
  kind of a provider's failure, uses no job cache, and has its outputs
  deleted `retention.private_outputs_hours` (24) after it finished.
- **Encrypted job outputs** (`encrypt_to`): outputs are encrypted to an age
  X25519 recipient (age v1 format, implemented on `:crypto` in
  `OmnigateControl.Age`) before they reach local storage or the bucket; a
  download is encrypted as it arrives, so its temporary file holds only
  ciphertext. The job reports `"encryption": "age"`, the hash and size of
  the stored file and of the plaintext. Decryption by an independent
  implementation (pyrage) is part of the end-to-end suite.
- **Unlinking** (`unlink`): `user`, `safety_identifier`, `prompt_cache_key`
  and `metadata` (OpenAI), `metadata` and `diagnostics` (Anthropic) are
  removed from a request, under any spelling a provider's parser could read
  as those names.
- The setting on file keys and managed keys (`privacy` in the config file,
  `POST`/`PATCH /admin/keys`, a button and two form fields on the
  dashboard), in the config snapshot (without the recipient), in
  `GET /admin/keys` (`privacy`, `privacy_summary`) and in the audit log
  (what the setting became, never the recipient). `omnigate_key_private`.
- Responses to a text request name the parts that applied:
  `x-omnigate-privacy: no-store, redact, unlink`.
- `tools/mock_upstream.py`: `echo-1` models that answer with what they were
  sent, in three-character pieces when streaming, and `GET /__last` to read
  back what a mock received. `tools/e2e.py`, `tools/malformed_test.py` and
  `tools/sdk_compat.py` gained privacy sections; the end-to-end suite ends
  by searching every file the two processes wrote for the private prompt.
- `config/omnigate.example.json`: a key with privacy mode, and the two
  media settings of the third-review commit (`max_outputs_per_job`,
  `max_job_output_bytes`).

**Close-out (the commit after 55a294d).** What an installation has to do
is in [docs/upgrading.md](docs/upgrading.md#the-close-out-commit).

- A gateway key can have its own concurrency cap, `max_concurrent` (0 to
  1,000,000; `0` leaves it on `OMNIGATE_MAX_CONCURRENT_PER_KEY`): in the
  config file, through the admin API, in the config snapshot, in
  `GET /admin/keys` and on the dashboard.
- Audit log: a `peer` member (the connection's address, when it differs
  from `address`); the dashboard shows a summary line's `repeats`.
- Control plane: a warning at start when an id file that the ledger
  snapshot counted ids for is missing.
- `tools/malformed_test.py --rpm`, the per-minute limit of `--rpm-key`
  (default 3; 5 for the dev config's key). The tool gained cases for an
  upstream and a control plane that send a head and no body, for a client
  that takes none of the gateway's own answers, and for the length of
  file downloads.
- `tools/mock_upstream.py`: the error bodies two providers really send
  (`err-array-1`, `err-string-1`), a well-formed one in an unusual
  spelling (`err-exact-1`), two on the Anthropic mock, and `stall-body`
  (a 200 head, then nothing). `tools/sdk_compat.py` checks that both SDKs
  raise the right class with the provider's message for them.

**Since the second security review (commits e4e30e4 and d79406b)**

- Data plane: `OMNIGATE_MAX_CONCURRENT_PER_KEY` (512),
  `OMNIGATE_REQUEST_MEMORY_MB` (1024) and `OMNIGATE_PARSE_MEMORY_MB`
  (1024), checked before a request body is read, with the answers 429
  `concurrency_limit_exceeded`, 429 `request_memory_exceeded`, 503
  `overloaded` (all with `retry-after: 1`) and 400 `request_too_complex`.
- Data plane: `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` (30 s) for a client that
  stays connected but reads nothing, and `OMNIGATE_ABORT_DRAIN_MAX_MB`
  (64) next to `OMNIGATE_ABORT_DRAIN_MS`.
- Data plane: `omnigate-dp healthcheck`, and a `HEALTHCHECK` in
  `dataplane/Dockerfile` that runs it.
- Data plane: the JSON access log marks estimated usage
  (`"estimated": true`).
- Control plane: `media.max_jobs_per_day` (10,000) and a per-key
  `max_jobs_per_day`, in the config file and through `/admin/keys`; one
  job more answers 429 `too_many_jobs_today`.
- Control plane: `GET /v1/jobs` is rate-limited per key (its `rpm`, or
  600 per minute), and leaves inputs over 8 KiB out of the list
  (`"input_omitted": true`).
- Control plane: media targets take `default_seconds`, `min_seconds` and
  `max_seconds`; media routes take `allowed_input` and
  `price_multipliers`. `input.duration` may be written `"5s"`.
- Control plane: `media.webhooks.max_concurrent` (16) and
  `max_concurrent_per_key` (4).
- Control plane: 503 `storage_unavailable` when a job cannot be written,
  and 503 `not_ready` on `GET /internal/config` while the ledger loads.
- Metrics: `omnigate_ledger_invalid_events_total` and
  `omnigate_ledger_unpriced_events_total`.
- Compose: memory limits for both containers (`OMNIGATE_CONTROL_MEMORY`,
  `OMNIGATE_DATAPLANE_MEMORY`, 1 GiB each by default).
- `tools/malformed_test.py` also plays a hostile upstream and a hostile
  control plane, and checks the limits that apply before a body is read,
  expensive bodies, the `healthcheck` subcommand and the billing of
  clients that stop reading. `tools/container_test.py` checks the memory
  limits and that a client cannot choose its `X-Forwarded-For`.
- `docs/upgrading.md`.

**Text gateway (data plane)**

- OpenAI- and Anthropic-compatible streaming proxy with gateway-key
  authentication, model routing, failover on connection errors, 429 and 5xx,
  and token metering from the response stream.
- `POST /v1/chat/completions` and `POST /v1/messages`, plus
  `/v1/embeddings`, `/v1/responses`, `/v1/completions` and
  `/v1/messages/count_tokens` as same-protocol passthrough; `GET /v1/models`
  and `GET /healthz`.
- Translation between OpenAI chat completions and Anthropic messages:
  requests, responses, server-sent events, tools and images.
- At-least-once usage delivery: events are queued, appended to an on-disk
  spool and sent in batches with backoff, so calls made during a
  control-plane outage are still billed.
- Timeouts on waiting for upstream response headers, global or per upstream
  (`timeout_ms`), with cancellation; one retry on a fresh connection before
  failing over.
- Per-key requests-per-minute limits (`rpm`), answered with 429 and
  `Retry-After`.
- Upstream cooldowns: an upstream that keeps failing is tried last for a
  while.
- The last config is cached on disk, so a data plane restarted during a
  control-plane outage still serves.
- When a client did not ask for the OpenAI usage chunk on a stream, the
  gateway asks for it to meter the call and hides it from the client.
- `v1_path` on upstreams, for OpenAI-compatible providers that do not serve
  the API under `/v1` (Gemini uses `/v1beta/openai`).
- Route strategies: `failover` (default), `round_robin` and `weighted` with
  a per-target `weight`. The other targets remain as failover, and cooling
  upstreams still go last.
- Per-key model limits (`models`): anything else is a 403
  `model_not_allowed`.
- Client timeout (`OMNIGATE_CLIENT_TIMEOUT_MS`, 30 s): a client that does
  not finish sending its request, or leaves a keep-alive connection idle,
  is disconnected.
- Stream idle timeout (`OMNIGATE_STREAM_IDLE_TIMEOUT_MS`, 5 min): a response
  that stops moving is cut off, and what was metered up to then is billed.
  (Since e4e30e4 it covers a silent upstream only; see "Changed".)
- Connection cap (`OMNIGATE_MAX_CONNECTIONS`, 4096): further connections get
  an immediate 503 `overloaded` with `retry-after`.
- Graceful shutdown on SIGINT and SIGTERM (Ctrl-C and Ctrl-Break on
  Windows): requests in flight get `OMNIGATE_SHUTDOWN_GRACE_MS` (10 s) to
  finish, and queued usage is delivered before exit.
- Access log: one line per request with key name, route, upstream,
  attempts, tokens, latency and request id. `OMNIGATE_LOG_LEVEL` sets the
  level, and `OMNIGATE_LOG_FORMAT=json` writes every log line as one JSON
  object.
- Response cache, opt-in per route with `cache_ttl_s`: an identical
  non-streaming request from the same gateway key is answered from memory.
  Bounded by `OMNIGATE_CACHE_MAX_MB` (64); responses carry
  `x-omnigate-cache: hit` or `miss`; hits are counted but not billed.
- Provider response headers for the caller are passed on by allowlist:
  `retry-after`, `x-ratelimit-*`, `anthropic-ratelimit-*`, the provider's
  request id and a few more. A final 502 carries the last upstream's
  `retry-after`.
- Prompt-cache accounting: usage events separate uncached input, cache
  reads and cache writes, normalised by the upstream's protocol (OpenAI
  counts cached tokens inside its input figure, Anthropic beside it).
- Requests refused before routing (bad key, rate limit, disallowed model,
  timeouts, the connection cap and so on) are counted per key name and
  reason and reported to the control plane.
- `GET /v1/models` also lists the media job models the key may use.
- `GET /v1/models/{id}`. Model objects carry `created`, and a client that
  sends an `anthropic-version` header gets the model list and model objects
  in Anthropic's shape.
- `x-request-id` and `request-id` on every response except `GET /healthz`
  and the immediate 503 at the connection cap: the provider's own value
  when it sent one, the gateway's request id otherwise.
- Structured output through translation: OpenAI's `response_format` with a
  JSON schema becomes Anthropic's `output_config.format` and the reverse;
  `{"type": "json_object"}` becomes an instruction in the system prompt.
  Covered against the mock providers; the Anthropic side has not been
  verified against the live API.
- `OMNIGATE_ABORT_DRAIN_MS` (5 s): after a client disconnects mid-response
  the data plane keeps reading the upstream this long, and at most 8 MiB,
  for the provider's final usage. `0` bills an estimate at once. (Since
  e4e30e4: 120 s, in the background, with `OMNIGATE_ABORT_DRAIN_MAX_MB`;
  see "Changed".)
- Usage events carry `"estimated": true` when their token counts are an
  estimate, and the text access log marks such a line `usage=estimated`.
- Exit status 70 after a panic, with one log line (`error(panic): ...`), so
  a supervisor can tell it from a clean stop and from a startup error.

**Control plane**

- Config file with hot reload, a durable JSONL usage ledger replayed at
  start, per-key budgets, and a minimal dashboard.
- The ledger deduplicates on event id and records event time, so a resent
  batch never bills twice.
- Async media jobs behind one API (`/v1/jobs`, `/v1/files`): failover across
  providers, outputs re-hosted to local disk or an S3-compatible bucket
  (SigV4), signed and retried webhooks, idempotency keys, output caching,
  restart-safe job state, and job costs in the same ledger and budgets as
  tokens.
- Media adapters: Replicate-style predictions, fal-style queues,
  OpenAI-style images, ElevenLabs-style text to speech, Gemini's native API
  for image and speech models (raw PCM speech is stored as WAV), xAI video,
  and Gemini's Interactions API for its video-capable "omni" models.
- Dashboard login and admin API protected by one admin token
  (`OMNIGATE_ADMIN_TOKEN`): a bearer token on `/admin/*`, and the dashboard
  password, exchanged for a signed session cookie (`HttpOnly`,
  `SameSite=Strict`, 12 hours). A random token is generated and logged at
  start if none is set. Five failed logins lock an address out for a minute.
- `OMNIGATE_CONTROL_BIND` to listen beyond localhost, with a warning that
  the listener is plain HTTP.
- `GET /healthz` on the control plane, without credentials.
- `OMNIGATE_MEDIA_DIR` for the local output directory.
- Per-key model limits applied to media jobs.
- `retention` config: finished jobs and their local files are removed after
  `jobs_days`, ledger duplicate-detection ids after `ledger_ids_days`. Off
  by default.
- `GET /metrics` in Prometheus text format, behind the admin token.
- Managed gateway keys: create, change, disable, rotate and delete keys
  through `/admin/keys` or the dashboard, without editing the config. A new
  key is shown once and stored only as a hash, in `OMNIGATE_KEYS`
  (`data/keys.json`). Keys in the config file keep working and are
  read-only for the API. A rotated key keeps its spend, budget and jobs.
- New dashboard: totals for today and overall, spend against budget per
  key, key management, recent requests and media jobs, refused requests,
  admin activity and a read-only configuration view. It updates live from
  `GET /admin/overview` and loads no external assets.
- CSRF protection for changes made with a dashboard session; requests with
  the bearer token are exempt.
- Budget periods: `budget_period` on a key is `total` (default), `monthly`
  or `daily` (UTC). A monthly or daily key unblocks by itself when the
  period turns.
- Prices for prompt-cache tokens per text target:
  `price_cached_in_per_mtok` and `price_cache_write_per_mtok`, both
  defaulting to the input price.
- Admin audit log (`OMNIGATE_AUDIT_LOG`, `data/audit.jsonl`): key changes,
  sign-ins and sign-outs, shown in the dashboard and at `GET /admin/audit`.
- `disabled` on a key in the config file.
- Metrics: `omnigate_key_cached_input_tokens_total`,
  `omnigate_key_cache_write_input_tokens_total`,
  `omnigate_key_cached_responses_total`, `omnigate_key_period_cost_usd` and
  `omnigate_rejected_requests_total{key, reason}`.
- Retention also deletes a removed job's objects from an S3-compatible
  bucket (`retention.delete_bucket_objects`, on by default; only acts when
  `jobs_days` is set).
- Ledger snapshots: the control plane writes a checksummed snapshot of its
  totals and loads it at start, replaying only the events written after it
  (1,000,000 events: 10.7 s before, 0.75 s after). A damaged snapshot is
  ignored in favour of the previous one, or of a full replay.
- Ledger segments: the event log is split into numbered files by size and
  at the turn of the UTC day, and `retention.ledger_days` deletes old ones
  while lifetime and period totals stay exact. An existing `ledger.jsonl`
  needs no migration.
- The job log is compacted while the control plane runs, not only at start
  and after a retention sweep.
- `GET /readyz` on the control plane: 200 when the config is loaded, the
  job store is running and the ledger is loaded and writable, 503 with a
  reason otherwise. No credentials.
- The audit log is rotated by size (`OMNIGATE_AUDIT_MAX_MB`, 50; three older
  files are kept; `0` turns rotation off).
- `media.max_open_jobs` (100) and a per-key `max_open_jobs`: the number of
  unfinished media jobs a key may have at once. One more answers 429
  `too_many_open_jobs`. Settable in the config file and through
  `/admin/keys`; listings show the limit in force.
- `media.max_input_bytes` (1 MiB): the largest `input` and `metadata` of a
  job together; more answers 413.
- Job creation is rate-limited in the control plane as well, with the
  key's `rpm` in fixed one-minute windows (429 `rate_limit_exceeded`).
  (Since d79406b: a token bucket; see "Changed".)
- `OMNIGATE_TRUST_FORWARDED`: count failed logins and wrong admin tokens
  per address in `X-Forwarded-For` instead of per connection, for a control
  plane that is only reachable through a proxy.
- Wrong admin bearer tokens are throttled: 20 from one address within a
  minute, then 429 `too_many_attempts` for that address until the minute
  is over.

**Packaging and tools**

- Container images for both processes (the data plane as a static binary on
  an empty base image, the control plane as an Elixir release on Alpine;
  both non-root), a `compose.yaml` and a Caddy configuration that terminates
  TLS for two host names and hides `/internal/*`.
- `tools/container_test.py`: builds the images and checks them through the
  TLS proxy; `--compose` tests `compose.yaml` itself.
- `tools/e2e.py`: starts the whole stack against mock providers and checks
  it end to end.
- `tools/mock_upstream.py` and `tools/mock_media.py`: mock text and media
  providers, an S3-compatible object store and a webhook receiver.
- `tools/bench.py`: measures the latency the gateway adds on localhost.
- `tools/import_litellm.py`: converts a LiteLLM proxy config; maps OpenAI,
  Anthropic, Gemini, Groq, Mistral, DeepSeek, OpenRouter, Together,
  Fireworks, xAI and Perplexity entries.
- Documentation under `docs/`, `CONTRIBUTING.md`, `SECURITY.md`, this
  changelog, and a CI workflow (`.github/workflows/ci.yml`).
- `tools/load_test.py`: a load and soak test with well-behaved and hostile
  clients (stalled, silent, disconnecting, oversized, malformed).
- `tools/sdk_compat.py`: runs the official OpenAI and Anthropic Python SDKs
  through the gateway against the mock providers (sync, async, streaming,
  errors, both translation directions). Needs `pip install openai anthropic`.
- `tools/mock_upstream.py`: a fifth mock on port 9005 that stalls
  mid-stream, and `MOCK_PORT_OFFSET` to run a second copy on other ports.
- CI: an `sdk` job that runs `tools/sdk_compat.py`, and a formatting check
  (`mix format --check-formatted`) in the control-plane job.
- Release workflow (`.github/workflows/release.yml`): pushing a tag `v*`
  builds data-plane binaries for five targets, pushes multi-architecture
  images of both planes to GHCR and creates a GitHub release with this
  changelog's section as notes. Described in `docs/releasing.md`.
- `docs/admin.md` (dashboard, key lifecycle, budgets, audit log, CSRF) and
  a section on using the official SDKs in `docs/api.md`.
- `tools/sdk_compat.py` also checks what an SDK user would notice: request
  ids, error codes and envelopes, the model endpoints, a provider's 429,
  structured output through translation. It no longer has a list of
  tolerated gaps; every case must pass.
- `tools/mock_upstream.py`: models that always answer 429 with
  `retry-after`, that send a provider request id, and answers that follow a
  requested JSON schema.
- `tools/malformed_test.py`: a hostile-input suite. It replays the requests
  that used to crash the data plane or slip past a check, plus a few
  hundred generated (seeded) malformed request heads, asks `/healthz`
  after every one, and checks that a client which hangs up mid-stream is
  still billed. By default it starts its own stack through the end-to-end
  harness; `--gateway` points it at a running one, `--thorough` runs many
  more generated cases. CI runs it in a job of its own.
- `tools/check.py`: runs every check a change should pass (builds, unit
  tests, `zig fmt --check`, `mix format --check-formatted`, the importer
  tests, the end-to-end, SDK and hostile-input suites) with one command and
  a summary; `--quick` for unit tests and formatting only.
- `-Dstrip=true` for the data-plane build, used by `dataplane/Dockerfile`:
  the binary leaves its debug information out.
- An `x-request-id` header on every response of the control plane. A data
  plane relaying a client's request sends its own id along, so one id
  follows the request through both processes and is the `request_id` of a
  500 from either.
- `GET /admin/overview`: each recent request has its `id` and an
  `estimated` flag.
- `tools/container_test.py` also sends requests byte for byte through the
  TLS proxy: odd spellings of `/admin` and `/internal` paths, malformed and
  oversized requests to both hosts, the admin allow-list (a second proxy on
  port 18444), and that the data-plane container holds no admin token.
- `OMNIGATE_ADMIN_ALLOW` for the Compose proxy: CIDR ranges that may reach
  the dashboard host; everyone else gets 403. Open by default.
- `.env.control.example` and `.env.dataplane.example`, and
  `stop_grace_period` for both services in `compose.yaml`.
- `docs/security.md`, an operator's hardening guide, and one advisory per
  class of fixed vulnerability in `SECURITY.md`.

### Changed

**Close-out (the commit after 55a294d)**

- **A provider's error body that is not its protocol's error envelope is
  put into one**, with the provider's message, its code when it gave one,
  and the provider's status: Google's OpenAI-compatible endpoint answers a
  bad key with a JSON array, xAI with `error` as a string, and an SDK
  could not read either. A well-formed provider error is still relayed
  byte for byte. Translated errors read the same shapes.
- **A media target priced per second on a provider that is never sent a
  duration** (`openai_images`, `elevenlabs`, `gemini`,
  `gemini_interactions`) **must set `default_seconds`**, or the config is
  rejected at load. Such a job is billed the default whatever the request
  names, and the request-time check no longer refuses it for a duration
  the provider never sees.
- **Compose sets the data plane's memory budgets**
  (`OMNIGATE_REQUEST_MEMORY_MB` 256, `OMNIGATE_PARSE_MEMORY_MB` 256,
  `OMNIGATE_CACHE_MAX_MB` 64, from `.env`), so that they fit the 1 GiB
  container limit. A value for them in `.env.dataplane` is now
  overridden. The binary's own defaults are unchanged.
- `429 too_many_jobs_today` carries a `Retry-After` of the seconds until
  midnight UTC, at most 3,600 (it was 10).
- The gateway's own answers (errors, the model list, cache hits) are
  written under `OMNIGATE_CLIENT_STALL_TIMEOUT_MS`, not the stream idle
  timeout.
- `GET /login` with a bearer token from an address locked out for wrong
  tokens answers `429 too_many_attempts` (it showed the sign-in page).
- Audit log: `address` is the address the caller was counted under on
  every line, so a failed sign-in's first line and its summary line name
  the same address behind a proxy.
- The control-plane image's health check asks the port in
  `OMNIGATE_CONTROL_PORT`.
- `tools/import_litellm.py` cuts a timeout above one hour to `3600000` ms
  and reports it.
- `:inets` is no longer started with the control plane (nothing used it).

**Since the second security review (commits e4e30e4 and d79406b).** The
full list, with old and new values, is in
[docs/upgrading.md](docs/upgrading.md).

- **The rate limit is checked before the request body is read**, after
  the key's concurrency cap and the request-memory budget and before the
  size limit. A request that is then refused for its model or its JSON has
  used up one request of the key's `rpm`. This reverses the earlier
  change further down this list ("the request body is now read before the
  rate-limit check").
- **Chunked request bodies are refused with 411.** Every request with a
  body needs a `Content-Length`.
- **The gateway frames its own responses.** An answer that is not a
  stream and is at most 64 KiB is buffered and sent with a counted
  `content-length`; everything else is sent chunked, file downloads over
  64 KiB included, and an upstream's length is never forwarded. A response
  an upstream cuts short after the client's response has started drops the
  client's connection.
- **Abandoned streams are read to their end in the background.**
  `OMNIGATE_ABORT_DRAIN_MS` defaults to 120000 instead of 5000 and no
  longer holds the client's connection; the byte cap is
  `OMNIGATE_ABORT_DRAIN_MAX_MB` (64) instead of a fixed 8 MiB. The
  estimate billed when the provider's figures do not come is floored by
  the generated text received and allows 1,600 tokens per image, document,
  file or audio part of the request.
- `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` covers only a silent upstream; a
  client that reads nothing is cut off after
  `OMNIGATE_CLIENT_STALL_TIMEOUT_MS` (30 s, where it used to get 5
  minutes).
- `Idempotency-Key` is validated only on job requests, as 1 to 255
  visible ASCII characters; on other endpoints it is ignored.
- The body of a text request may have at most 65,536 members per object
  and keys of at most 8 KiB, and `model`, `stream` and `stream_options`
  may each appear once, spelled without escapes (400 `invalid_request`).
- The usage spool keeps the oldest events when it overflows (100,000
  events or 128 MiB), compacts its file as events are acknowledged, and
  never stops a start whatever its size.
- `retention.ledger_ids_days` defaults to 3 instead of 14. Ids are kept
  per UTC day in files of their own (`ledger.ids.YYYY-MM-DD`) and are no
  longer part of the ledger snapshot, which is now version 2 (snapshot
  pause at a million ids: 1.6 s before, 12 ms after). A version 1 snapshot
  is converted at the first start; older code does not read version 2.
- A job input over 8 KiB is kept in a file of its own
  (`<jobs log>.inputs/<job id>.json`) instead of in the job record.
- Whole-number settings in the config file are validated strictly, with
  bounds (`rpm` at most 1,000,000 and so on); a fraction is rejected where
  it used to be cut. The admin API applies the same bounds.
- A media job on a route priced per second must name a duration unless
  the target has `default_seconds`; it used to be accepted and billed no
  seconds.
- The control plane counts job creations with a token bucket like the
  data plane's, per key hash, instead of fixed one-minute windows.
- The control plane reads every outbound response through a cap, with an
  HTTP client of its own in place of OTP's `httpc`; a webhook attempt is
  recorded before it is sent.
- The control plane parses a request body only for authenticated callers
  and the sign-in form; wrong bearer tokens are counted on the dashboard
  page and the sign-in page too; failed sign-ins are aggregated in the
  audit log (summary lines carry `repeats`).
- The control plane's stores restart as a group without stopping the
  listener; `/readyz` reports it.
- `deploy/Caddyfile` sets `X-Forwarded-For` from the connection's address
  for both hosts.

**Earlier**

- The dashboard and the `/admin` API now require the admin token. They were
  previously open to anyone who could reach the control plane's port.
- `GET /v1/models` lists only the routes the calling key may use.
- For text endpoints the request body is now read before the rate-limit
  check, so that a disallowed model is a 403 rather than a 429. A key over
  its limit therefore still costs one body read. (Reversed in e4e30e4; see
  the top of this list.)
- The placeholder webhook secret in the dev config is written without the
  `whsec_` prefix (same key bytes), and test placeholders are assembled at
  compile time, so secret scanners no longer flag them.
- `config/omnigate.json`, the operator's own config, is ignored by git.
- A key over its budget is refused only where it would start new work (text
  requests and `POST /v1/jobs`). It keeps access to its model list, its
  jobs and files, and can cancel a job. Previously it got 402 everywhere.
- Both processes refuse to start without `OMNIGATE_INTERNAL_TOKEN`, and an
  empty value counts as not set. The control plane used to start without it
  and then refuse every data-plane request.
- A text upstream whose `kind` is not `openai` or `anthropic` is refused
  when the config is loaded. It used to be passed on to data planes, which
  could not parse the snapshot.
- In usage events, the ledger and metrics, `input_tokens` now means input
  that was **not** served from the provider's prompt cache. For
  OpenAI-style upstreams, which count cached tokens inside their input
  figure, cached tokens moved to `cached_input_tokens`. Cost is unchanged
  unless a cache price is configured.
- `GET /admin/usage` returns more fields per key (source, state, budget
  period, cache token counts) and includes managed keys.
- Webhook delivery resolves the target host once per attempt, checks the
  addresses and connects to the checked address. This closes DNS rebinding
  between the check and the call.
- Optimized data-plane builds use the multi-threaded allocator instead of
  the standard library's checking allocator, which cut memory for 100,000
  queued usage events from 427 MiB to 77 MiB.
- The control plane's code is formatted with `mix format` at a line length
  of 160, and CI enforces it.
- The retention log line also reports the bucket objects removed, and the
  ledger segments.
- **Gateway errors are provider-shaped, and the gateway's reason moved from
  `error.type` to `error.code`.** On OpenAI-style endpoints the error is
  `{"error": {"message", "type", "param", "code"}}`; on Anthropic-style
  endpoints it is `{"type": "error", "error": {"type", "message", "code"},
  "request_id"}`. `type` is now the provider's category
  (`invalid_request_error`, `rate_limit_error`, `not_found_error`, ...). A
  client that matched on `error.type` must match on `error.code` instead.
  The mapping is in `docs/api.md`.
- **One error shape everywhere.** Errors the control plane raises (for the
  jobs API and file downloads, and on its own port for the admin API,
  `/metrics` and `/internal/*`) have the same OpenAI-style envelope:
  `{"error": {"message", "type", "param", "code"}}`, with the reason in
  `error.code` and an OpenAI-style category in `error.type`. They used to
  be `{"error": {"type": "<reason>", "message"}}`. A client of the jobs API
  or a script against the admin API that read the reason from `error.type`
  must read `error.code`.
- When no target of a route succeeded and any of them answered 429, the
  client gets 429 `upstream_rate_limited` with the longest `retry-after`
  those targets sent. It used to get 502 `all_upstreams_failed` (and, for
  a few commits, 429 only when the last target tried was the rate-limited
  one).
- An endpoint that none of a route's upstreams can serve (embeddings on a
  route with only Anthropic-style upstreams, for example) answers 400
  `endpoint_not_supported`, and a request that no target can be sent
  because it cannot be translated answers 400 `untranslatable_request`.
  Both used to be 502s, and neither is written to the ledger any more;
  they are counted as refused requests.
- On the control plane, a body that is not JSON (400 `invalid_json`), a
  body that is too large (413 `payload_too_large`) and an unexpected
  exception (500 `internal_error`, with a `request_id` that is also in the
  log) all answer with the JSON error object.
- A config-file key with the name of a managed key now shadows it: the
  file key is used, the managed key is left out, a warning is logged, and
  `GET /admin/keys` lists the managed key with `"state": "shadowed"`.
  Previously both were in the key list under one name.
- The control plane refuses a request path that contains a percent-encoded
  character with 400, answers an unknown first path segment with 404 before
  authentication, and checks credentials before parsing the body (see
  Security above). `/admin/keys/{name}` therefore has exactly one spelling.
- The control image's health check calls `/readyz` instead of `/healthz`.
- CI installs pinned versions of the two SDKs (`openai` 3.49.0,
  `anthropic` 2.8.0) for the `sdk` job instead of the latest ones, so that
  a new SDK release cannot fail CI without a change in the repository.
- The README was rewritten as a shorter landing page: the environment
  table and the config field lists now live only in
  `docs/configuration.md`, and it no longer states counts of test checks.
- **Compose: secrets are split per container.** `compose.yaml` reads
  `.env.control` and `.env.dataplane` instead of giving one `.env` to both
  containers; `.env` now holds only the host names and
  `OMNIGATE_ADMIN_ALLOW`. An existing deployment must create the two files
  before it will start. Compose also sets `OMNIGATE_TRUST_FORWARDED=1` for
  the control plane.
- **An admin token shorter than 16 characters stops the control plane from
  starting.** It used to log a warning.
- **A release build of the control plane refuses to start without
  `OMNIGATE_CONFIG`.** Only development and test builds fall back to
  `config/omnigate.dev.json`.
- **The gateway refuses requests it used to accept.** A path must be in one
  canonical form (no percent-encoding, no trailing slash, no empty or dot
  segments) and a query string may only use a small character set, or the
  answer is 400 `invalid_request`. A malformed or ambiguous request head is
  400, a body without a length 411, an `Expect` other than `100-continue`
  417, a head over 16 KiB 431. JSON nested deeper than 64 levels is 400
  `invalid_json`. `Idempotency-Key`, `anthropic-version` and
  `anthropic-beta` values are limited to plain characters.
- **A response that ends early is billed.** A client that disconnects
  mid-stream is billed the provider's real usage when it arrives within
  `OMNIGATE_ABORT_DRAIN_MS`, and otherwise an estimate; so is a stream cut
  off by the idle timeout or by the upstream before its final usage.
  Earlier commits billed only what had been metered up to that point.
- **Media job cost is computed from what the adapter sent to the
  provider.** Per-character prices count the text fields the adapter
  forwards (for the adapters that forward the whole input: `prompt`, `text`
  and `input` added together), per-second prices the larger of `duration`
  and `seconds`, and only for the adapters that send a duration. A job with
  a negative or non-numeric duration or count is refused with 400, and a
  negative media price stops the config from loading.
- `retention.ledger_ids_days` defaults to 14 instead of keeping
  duplicate-detection ids for ever; an explicit `0` keeps the old
  behaviour. (The default is 3 since d79406b.)
- Stored outputs are served as attachments, with
  `x-content-type-options: nosniff` and a sandboxing
  `content-security-policy`, and with their stored content type only when
  it is on a short list of media types (`application/octet-stream`
  otherwise).
- The data plane passes on six headers of a control-plane answer by name:
  `content-disposition`, `x-content-type-options`,
  `content-security-policy` and `cache-control` on a stored file,
  `location` on the redirect to a bucket-stored file, and `retry-after` on
  a 429. It used to pass on none of them, so the redirect had no target and
  a job-creation 429 from the control plane no `Retry-After`.
- Numeric environment variables are read strictly in both processes:
  digits only for the data plane's settings, a well-formed number in range
  for `OMNIGATE_CONTROL_PORT` and `OMNIGATE_AUDIT_MAX_MB`. A bad value
  stops the process at startup with a message that names the variable; it
  used to be half-read, or replaced by a default without a word. A variable
  that is set but empty counts as unset.
- The data plane refuses a job request body over 8,000,000 bytes itself,
  with the answer the control plane would give, instead of sending it
  across first.
- `x-request-id` and `request-id` never disagree: when a provider sent
  only one of the two, that id goes into both.
- `retention.ledger_days` also takes effect on an installation that records
  nothing after a restart: the sweep writes the second snapshot generation
  itself instead of waiting for one.
- A managed key shadowed by a config-file key of the same name is listed
  in the dashboard and in `GET /admin/overview`, with the state `shadowed`.
- The control image's health check has a start period of 120 seconds
  instead of 20, for a first start that replays a large ledger.
- The outbound `user-agent` of both processes carries the version from
  `dataplane/build.zig.zon` and `control/mix.exs` (`omnigate/0.1.0`,
  `omnigate-webhooks/0.1.0`) instead of a hand-written `0.1`.
- Provider output downloads resolve the host once, refuse non-public
  addresses and connect to the checked address, like webhooks; redirects
  are followed by the control plane itself, at most five.
  `media.webhooks.allow_private` now governs these downloads too.
- `jobs.jsonl`: a job's later changes are appended as patch lines with only
  the changed fields, instead of full copies of the job. Older files are
  read as before; older code cannot read the new lines.
- Learned provider quirks (refused sampling parameters, thought
  signatures) are remembered per gateway key, not shared across keys.
- The usage scanner reads token counts only from usage objects at the
  places the protocols define, not from matching text anywhere in a
  response.
- `POST /login` and `POST /logout` accept a body of at most 4,096 bytes,
  and the control plane's listener speaks HTTP/1.1 only.
- The data plane's text log escapes control bytes in client-supplied text
  and never logs a query string.
- CI has a seventh job, `hostile`, for `tools/malformed_test.py`, and the
  container test uses a second local port (18444).

### Fixed

- **An upstream that sent a 200 head and then no body, on an answer that
  is not a stream, ended the request and could disarm the gateway's
  deadlines.** The silence was timed by the watchdog, which cancels the
  connection's task and waits for it; the task then went on to the next
  upstream without any deadline, and the watchdog served no other
  connection until it finished. Such a wait is now timed next to the read,
  the attempt fails with `StreamIdleTimeout`, and the request fails over
  cleanly (or ends in a 502). The same applied to a control plane that
  stalled inside a jobs answer. A task the watchdog did cancel now ends
  without starting anything else. Found by reading the code and
  reproduced with `tools/malformed_test.py` against the previous binary
  (a client that sent half a request head was never dropped while such a
  connection stayed open); not seen in use. (Close-out commit.)
- File downloads over 64 KiB carry their `Content-Length` again; since
  e4e30e4 they were sent chunked. (Close-out commit.)
- Sign-in counts that had no summary line yet were lost whenever the
  control plane stopped; a clean stop now writes them. (Close-out commit.)
- Streamed responses were not flushed per chunk, so streams arrived in one
  burst.
- An error after the response had started no longer triggers failover.
- Translated requests that a model refuses because of sampling parameters
  (`temperature`, `top_p`, `top_k`) are retried without them, and the model
  is remembered. Found against the real OpenAI and Anthropic APIs: current
  Claude models answer 400 to parameters that OpenAI clients send routinely.
- Translated requests that Gemini 3 and later refuse for lacking a "thought
  signature" on earlier tool calls are retried with the placeholder Google
  documents, and the model is remembered. Found against the real Gemini API.
- A client that connected and sent nothing, or stopped half-way through a
  request, held a thread for ever. Found with the load test.
- Data-plane memory crept upwards under load, because usage events were
  allocated on request threads and freed on the flush thread. The queue is
  now one reused buffer. Found with the load test.
- As PID 1 in a container the data plane ignored SIGTERM, so `docker stop`
  waited for its kill timeout. It now drains and exits with status 0.
- A client that was refused before its request body had been read (a bad
  key on a `POST`, for example) could see a reset connection instead of the
  answer. The data plane now finishes its side, reads and discards what
  the client is still sending for a short time, and then closes.
- A connection whose answer said `connection: close` was held open until
  the client timeout. It is closed at once.
- A client that requested a large stored file and then stopped reading
  held its connection for ever; the stream idle timeout now covers the
  gateway's own answers and file downloads.
