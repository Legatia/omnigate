# Privacy mode

Privacy mode is a setting on a gateway key. It has five parts, each of which
can be switched on by itself:

| Part | Setting | What it does |
|---|---|---|
| No retention | `no_store` | The gateway keeps nothing of a request's content: no response cache, and for media jobs no input or metadata after the job ends, and no outputs after a day. |
| Redaction | `redact` | E-mail addresses, phone numbers, payment card numbers, IP addresses and common secret formats in a text request are replaced by placeholders before the provider sees them, and put back in the answer. |
| Encrypted outputs | `encrypt_to` | The outputs of the key's media jobs are encrypted to an [age](https://age-encryption.org) recipient before they are stored anywhere. |
| Unlinking | `unlink` | The request fields that name an end user to the provider are removed. |
| Attested providers only | `attested` | A text request only goes to a provider that has proven, and recently, what hardware and configuration it runs on. Otherwise it is refused, not sent elsewhere. It needs an [attested upstream](attestation.md) in the config. |

Read [What it does not do](#what-it-does-not-do) before you rely on it. In
one sentence: the provider still reads the prompt, with the listed kinds of
values replaced; this is pattern matching and policy inside the gateway, not
cryptography that hides a prompt from the model that answers it.

Contents:

- [Switching it on](#switching-it-on)
- [No retention](#no-retention)
- [Redaction](#redaction)
- [Encrypted outputs](#encrypted-outputs)
- [Unlinking](#unlinking)
- [Attested providers only](#attested-providers-only)
- [The request header](#the-request-header)
- [What it does not do](#what-it-does-not-do)
- [What has been tested](#what-has-been-tested)

## Switching it on

On a key in the config file, or on a managed key through the admin API or
the dashboard:

```json
{ "name": "support-bot", "key_sha256": "...", "privacy": true }
```

`true` is `no_store`, `redact` (every class) and `unlink`. It is not
`attested`: see [Attested providers only](#attested-providers-only). Part
by part:

```json
{
  "name": "support-bot",
  "key_sha256": "...",
  "privacy": {
    "no_store": true,
    "redact": ["email", "phone", "card", "ip", "secret"],
    "unlink": true,
    "encrypt_to": "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"
  }
}
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `no_store` | boolean | `false` | [No retention](#no-retention). |
| `redact` | boolean, or a list of classes | `false` | [Redaction](#redaction). `true` is every class; a list picks from `email`, `phone`, `card`, `ip`, `secret`. |
| `unlink` | boolean | `false` | [Unlinking](#unlinking). |
| `encrypt_to` | string | none | An age X25519 recipient (`age1...`). [Encrypted outputs](#encrypted-outputs). |
| `attested` | boolean | `false` | [Attested providers only](#attested-providers-only). |

`false`, `null`, or leaving `privacy` out switches everything off. Anything
else is refused: an unknown field, an unknown class, a recipient that is not
a valid `age1...` address (its checksum is verified). In the config file
that fails the load, with a message naming the key (at startup the control
plane does not start; on a reload the previous config stays in force); over
the admin API it is a `400 invalid_request` and the key is unchanged.

With the admin API:

```bash
# on, for a new key
curl -sS -X POST "$CONTROL/admin/keys" -H "authorization: Bearer $OMNIGATE_ADMIN_TOKEN" \
  -H 'content-type: application/json' -d '{"name": "support-bot", "privacy": true}'

# change it: the setting is replaced as a whole
curl -sS -X PATCH "$CONTROL/admin/keys/support-bot" -H "authorization: Bearer $OMNIGATE_ADMIN_TOKEN" \
  -H 'content-type: application/json' -d '{"privacy": {"redact": ["email", "secret"], "unlink": true}}'

# off
curl -sS -X PATCH "$CONTROL/admin/keys/support-bot" -H "authorization: Bearer $OMNIGATE_ADMIN_TOKEN" \
  -H 'content-type: application/json' -d '{"privacy": false}'
```

A key's view (`GET /admin/keys`) has `privacy` (the setting, `null` when
off) and `privacy_summary` (`"no-store, redact, unlink"`). The dashboard
shows the summary under the key's state, has a **Privacy on** / **Privacy
off** button for managed keys (on is the same as `"privacy": true`; off
removes the whole setting, the recipient included, and asks for a second
click), and takes both in the form that creates a key. Every change is
written to the [audit log](admin.md#the-audit-log) with what the setting
became (`"privacy": "no-store, redact"`, or `"off"`); the recipient is never
written there.

A change reaches the data planes with their next config poll (two seconds by
default, `OMNIGATE_POLL_MS`). The data plane is sent `no_store`, `redact` and
`unlink`; the recipient stays in the control plane, which is where jobs run.

## No retention

For a text request (`no_store`):

- The data plane's [response cache](api.md#response-cache) is neither read
  nor written, whatever the route's `cache_ttl_s` says. The response carries
  no `x-omnigate-cache` header.
- A request to OpenAI's chat completions or Responses endpoint is sent with
  `"store": false`, replacing whatever the client sent. On chat completions
  `metadata` is removed with it (OpenAI refuses `metadata` without `store`).
  This applies to upstreams whose `base_url` host is `api.openai.com`, and
  to any upstream you mark with `"privacy_store_flag": true`
  ([Configuration](configuration.md#text-upstreams)); set it to `false` to
  switch it off for one. No other provider has a per-request flag of this
  kind that the gateway knows of, so nothing is added for them: their
  retention is whatever your agreement with them says.

What the gateway writes about a text request was already free of content
before this setting existed, and stays so: the access log line and the usage
event hold the key's name, the model, the upstream, token counts, timings
and the request id ([Operations](operations.md#logs)). Neither process logs
a request or response body.

For a media job (`no_store`, from the key or from the
[request header](#the-request-header)); the job is then "private", and its
view says `"private": true`:

- Its `input` and `metadata` are never written to the job log. They are kept
  in two files next to it (`<jobs file>.inputs/<job id>.json` and
  `.meta.json`) while the job runs, because the job has to be able to
  continue after a restart and a provider may be tried again.
- When the job ends (succeeded, failed or canceled, and its account with the
  provider is closed), both files are deleted and the job says
  `"input_erased": true`. The job's record loses both in the same write
  that ends it, so it is never readable as finished with its input still
  there; the files go right after. This happens before the webhook is sent, so the
  webhook carries neither; nor does `GET /v1/jobs/{id}`, the job list, or the
  answer to a repeated `Idempotency-Key`. Until then `GET /v1/jobs/{id}`
  still returns them to the key that created the job. A job that ended just
  as the control plane stopped is erased at its next start.
- "Deleted" means the file is removed. Nothing overwrites its blocks; what a
  file system, a snapshot or a backup taken in between keeps is outside the
  gateway's reach. Keep `/data` on encrypted storage if that matters.
- What a provider says about a failed attempt is reduced to its kind
  (`http_400`, `timeout`): providers quote the request in their errors.
- The job neither reads nor feeds the [job cache](api.md#caching).
- Its outputs are deleted `retention.private_outputs_hours` after it
  finished (24 by default; the sweep runs hourly, so up to an hour later),
  from local disk and from the bucket. The job itself stays, with its status
  and cost, and says `"outputs_expired": true`. `0` keeps a private job's
  outputs like any other job's. See
  [Configuration](configuration.md#retention).

## Redaction

With `redact`, the data plane looks through the text of a request to
`/v1/chat/completions`, `/v1/messages`, `/v1/completions`, `/v1/responses`,
`/v1/embeddings` and `/v1/messages/count_tokens`, replaces what it finds with
placeholders, and sends that to the provider:

```text
client sends:     Write to bob@example.com about card 4111 1111 1111 1111.
provider sees:    Write to [EMAIL_1] about card [CARD_1].
provider answers: Done. I told [EMAIL_1] that [CARD_1] was declined.
client receives:  Done. I told bob@example.com that 4111 1111 1111 1111 was declined.
```

The same value always gets the same placeholder within a request, numbered
per class in order of first appearance. The numbering depends only on the
text, so the next turn of the same conversation produces the same
placeholders, and a provider's prompt cache still matches the unchanged
beginning. The map from placeholder to original exists in the memory of that
one request and is gone when it ends.

### What is found

| Class | Placeholder | Recognised |
|---|---|---|
| `email` | `[EMAIL_n]` | `local@domain.tld`: a domain with a dot and an alphabetic top-level label of two letters or more. |
| `phone` | `[PHONE_n]` | International numbers written with a leading `+` (8 to 15 digits, with spaces, dashes, dots or parentheses between groups); North American numbers written `(555) 123-4567`, `555-123-4567`, `555.123.4567` or `555 123 4567`, optionally after `1`; national numbers written with a leading `0` and separators (`020 7946 0958`, `01 23 45 67 89`). A plain run of digits is not taken for a phone number. |
| `card` | `[CARD_n]` | 13 to 19 digits that pass the Luhn check and start with 2 to 6, written together or in groups of four or more (`4111 1111 1111 1111`, `3782-822463-10005`). |
| `ip` | `[IP_n]` | IPv4 addresses (`a.b.c.d`, each part 0 to 255) and IPv6 addresses (full or `::`-compressed, with or without an IPv4 tail). A dotted version number of four parts looks the same as an IPv4 address and is replaced too. |
| `secret` | `[SECRET_n]` | Provider keys by their prefix (`sk-`, `sk_`, `xai-`, `r8_`, `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`, `glpat-`, `hf_`, `og-`, `whsec_`, `xoxb-` and the other `xox?-`, `AIza`, `npm_`, `pypi-`, `cfat_`, `gsk_`, `pplx-`, `shpat_`, `dop_v1_`, `rk_live_`), when what follows is long enough and looks random; AWS access key ids (`AKIA…`, `ASIA…`); the 40 characters after `aws_secret_access_key`; JWTs (`eyJ….….…`); the token after `Bearer `; PEM private key blocks. |

Where text is looked for: the string values under the keys `content`,
`text`, `input`, `prompt`, `system`, `instructions`, `output` and
`arguments`, at any depth; the strings of an array under one of them; and
every string inside an object under `input` or `arguments` (a tool call's
arguments). That covers messages in both protocols, system prompts, tool
results, earlier tool calls, the Responses API's `input` and `instructions`,
a completion's `prompt`, and the inputs of an embeddings request.

### What comes back

Placeholders in the answer are replaced by their originals: in a whole JSON
answer, in an event stream (also when the provider's chunking cuts a
placeholder in two, `"[EMA"` in one event and `"IL_1]"` in the next: the
first half is held until the event that continues the same piece of text
arrives, and nothing else is delayed), in tool-call arguments (`arguments`,
Anthropic's `input` and streamed `partial_json`), in translated answers, and
in a provider's error message when it quotes the request.

Text of your own that already looks like a placeholder (`[EMAIL_1]` typed by
a user) is treated as a value: it travels under a placeholder of its own and
comes back exactly as written.

The response has `x-omnigate-privacy: redact` (with the other parts that
applied), so a client can see that the request was handled this way.

### Limits you should know

- **Names are not detected**, nor street addresses, dates of birth, account
  numbers, or anything else without a recognisable shape. If "Maria Keller"
  is in the prompt, the provider reads "Maria Keller".
- **It is pattern matching and it can miss.** An address written `bob at
  example dot com`, a phone number in a format not listed above, a card
  number in groups of three, a key from a provider whose prefix is not in the
  list: none of these is found. It can also replace something that only looks
  like a value (a four-part version number); that one is put back in the
  answer, but the provider reasoned about a placeholder.
- **Only text under the keys above.** Images, audio, PDFs and other
  attachments (base64 or by URL), tool definitions and their descriptions,
  `name` fields, ids, and Anthropic document blocks (their text is under
  `data`) are not looked at.
- **The model has to repeat a placeholder exactly** for it to be put back.
  A model that writes `EMAIL_1` without brackets, translates it, or splits
  it across words leaves a placeholder in the answer.
- **Embeddings are of the redacted text.** The vector you get describes
  `Write to [EMAIL_1]`, not the original sentence. That is the point (the
  provider never saw the address), but two texts that differ only in a
  redacted value now embed the same.
- **One request may hold 16,384 distinct values.** More is refused with
  `400 too_many_redactions` rather than sent on with some of them in clear.
- A token longer than 8 KiB is not taken for a secret; a private key block
  is taken up to 16 KiB.
- An answer that is not a stream is read whole before it is looked through,
  up to 16 MiB; a longer one counts as a failed upstream. The originals put
  back into one answer may add up to 32 MiB; beyond that placeholders are
  left as they are.
- The [response cache](api.md#response-cache) is off for a key that
  redacts.
- Billing follows the provider's own token counts, which are those of the
  redacted prompt.
- Media jobs are not redacted: a job's input goes to the media provider as
  it is.

How many values were replaced is counted per key and class
(`omnigate_redactions_total`, [Operations](operations.md#metrics)). Counts
only: what was replaced is never logged, reported or stored.

## Encrypted outputs

With `encrypt_to`, each output of the key's media jobs is encrypted to that
recipient before it is stored, on local disk or in the bucket. A download is
encrypted as it arrives, so the temporary file that precedes the store never
holds the plaintext either; bytes a provider returns inline are encrypted in
memory.

Create a key pair with the `age` tools and give the gateway the public half:

```bash
age-keygen -o key.txt        # prints: Public key: age1...
```

A finished job then looks like this:

```json
"outputs": [{
  "url": "https://llm.example.com/v1/files/job_…/out-0.png.age?exp=…&sig=…",
  "content_type": "application/octet-stream",
  "bytes": 70412,
  "sha256": "…of the encrypted file…",
  "encryption": "age",
  "plaintext_content_type": "image/png",
  "plaintext_bytes": 70190,
  "plaintext_sha256": "…of the image…"
}]
```

and is read with any age implementation:

```bash
curl -sS -o out-0.png.age "$URL"
age -d -i key.txt -o out-0.png out-0.png.age
sha256sum out-0.png        # equals plaintext_sha256
```

The format is age v1 with one X25519 recipient, binary (not armored). The
gateway has no private key and cannot decrypt what it stored; lose `key.txt`
and the outputs are gone. Only native `age1...` recipients are accepted (not
SSH keys, plugins or passphrases).

Jobs of such a key do not use the [job cache](api.md#caching) in either
direction: an output encrypted for one key is of no use to another.
`encrypt_to` and `no_store` are independent; a key can have either or both.

What this does not cover: the provider produced the output and has it under
its own URL for as long as it keeps it, and the bytes pass through the
control plane's memory in clear while they are downloaded.

## Unlinking

With `unlink`, the top-level request fields that name an end user to the
provider, or tie one request to another, are removed before the request is
sent (and before it is translated):

| Client speaks | Removed |
|---|---|
| OpenAI (`/v1/chat/completions`, `/v1/completions`, `/v1/responses`, `/v1/embeddings`) | `user`, `safety_identifier`, `prompt_cache_key`, `metadata` |
| Anthropic (`/v1/messages`, `/v1/messages/count_tokens`) | `metadata` (its one field is `user_id`), `diagnostics` (its `previous_message_id` names the client's previous response) |

They are removed under every spelling a provider's parser could read as that
name (`"User"`, an escaped letter). Fields a request needs in order to work
are left alone even where they link requests: `previous_response_id`,
`conversation`, Anthropic's `container`. Removing `safety_identifier` means
OpenAI's abuse systems see all of this key's traffic as one user; that is
what the setting is for, and worth knowing if your use depends on per-user
enforcement at the provider.

Independently of this setting, the data plane has always built its request
to a provider from scratch. What a provider receives, for every key:
`content-type`, `accept-encoding: identity`, `user-agent: omnigate/<version>`,
the provider key (`authorization` or `x-api-key`), and for Anthropic
`anthropic-version` and, if the client sent one, `anthropic-beta`. No client
header is forwarded besides those two; not the gateway key or its name, not
the client's address, no cookies.

What still links requests: they all arrive from the gateway's address under
your provider key, and the content itself.

## Attested providers only

`attested` restricts where a text request may go: only to a target on an
[attested upstream](attestation.md) whose attestation is verified right
now. A target on any other upstream is passed over, and so is an attested
one whose evidence does not currently hold. If that leaves none, the answer
is `503 attestation_unverified` and nothing was sent to anyone.

```json
{ "name": "legal-team", "key_sha256": "...", "privacy": { "no_store": true, "redact": true, "unlink": true, "attested": true } }
```

Things to know:

- `"privacy": true` does **not** switch it on, and neither does
  `x-omnigate-privacy: on`. Those are the three parts every gateway can do.
  This one needs an attested upstream; had `true` included it, every key
  that was `true` before the part existed would be refused on every model.
  Ask for it by name.
- A request that has it is never answered from the response cache, and its
  answer is not stored there.
- A media job that has it is refused (`503 attestation_unverified`): no
  media provider is attested.
- A response that came from an attested target says so:
  `x-omnigate-attestation: verified; tcb=UpToDate; since=<unix seconds>`.
- What an attestation proves, what it does not, and how old a verification
  can be: [Attested upstreams](attestation.md#what-a-pass-means). In one
  sentence: it is about who else can read the request on the provider's
  side (the operator of the machine cannot), not about what the model
  itself is shown; that is what redaction limits. The two are meant to be
  used together.

To see what a provider would be sent without sending it, add
`x-omnigate-dry-run: privacy` to a request:
[Seeing what a provider would be sent](attestation.md#seeing-what-a-provider-would-be-sent).

## The request header

A request can switch protections on for itself, on any key:

```text
x-omnigate-privacy: on                    all of no-store, redact, unlink
x-omnigate-privacy: redact                one part
x-omnigate-privacy: no-store, unlink      several
x-omnigate-privacy: redact, attested      attested providers only is asked for by name
```

It can only add to the key's setting. There is no value that switches a part
off, and a value the gateway does not understand (`off`, `false`, a
misspelling, the header sent twice) is refused with `400 invalid_request`
rather than ignored: a request that asked for privacy and mistyped it does
not go out without. `redact` in the header means every class.

On `POST /v1/jobs` the part that matters is `no-store` (it makes that job
private); `redact` and `unlink` are accepted and have no effect there, and
`attested` gets the job refused (no media provider is attested).
Encryption cannot be asked for per request: it needs a recipient, which is
the key's.

The response to a text request names the parts that applied:
`x-omnigate-privacy: no-store, redact, unlink`.

With the official SDKs the header goes in `extra_headers`, per call or on
the client (`default_headers`); nothing else changes, streaming helpers
included:

```python
from openai import OpenAI
client = OpenAI(base_url="https://llm.example.com/v1", api_key="<gateway key>")
answer = client.chat.completions.create(
    model="gpt",
    messages=[{"role": "user", "content": "Write to bob@example.com about the invoice."}],
    extra_headers={"x-omnigate-privacy": "redact"},
)
```

```python
import anthropic
client = anthropic.Anthropic(base_url="https://llm.example.com", api_key="<gateway key>",
                             default_headers={"x-omnigate-privacy": "on"})
```

## What it does not do

- **It does not hide the prompt from the model.** The model reads
  everything that was not replaced, and has to: that is what it answers.
  There is no zero-knowledge proof or homomorphic encryption here, and
  nothing could make a hosted model answer a prompt it cannot read. With
  `attested`, the request goes only to a provider that runs the model in
  confidential hardware and has proven it, which keeps the provider's own
  operators out of the machine's memory; the limits of that proof are in
  [Attested upstreams](attestation.md#what-is-not-checked).
- **It does not control what the provider keeps.** `"store": false` covers
  OpenAI's stored completions and responses. Abuse-monitoring retention,
  logs and training policies are set by your agreement with each provider
  (for OpenAI and Anthropic, ask for zero data retention if you need it).
- **Redaction is not anonymisation.** See
  [the limits above](#limits-you-should-know); a person can be identified by
  what is left.
- **It does not hide usage.** The ledger records that the key made a request,
  when, to which model, and what it cost, as for any key.
- **It does not protect against whoever runs the gateway.** The data plane
  sees every request in clear, and an operator can switch the setting off
  (the [audit log](admin.md#the-audit-log) records that).
- **Erasure is deletion, not wiping** (see [No retention](#no-retention)).

## What has been tested

All of the above runs against the mock providers in the repository's test
suites: unit tests in both processes; the end-to-end suite, which asserts
on what the mock provider received (never the original values), on what the
client got back (always the original values, whole and streamed, in both
protocols and through translation), and that after the run no file either
process wrote contains the prompt or metadata of a private request; the
hostile-input suite (megabytes of text built to be expensive to look
through, more values than a request may hold, hostile upstream answers
while there are placeholders to turn back); and both official SDKs, with
streaming. Files the gateway encrypted are decrypted by an independent age
implementation (pyrage, the Python binding of the Rust implementation) in
the end-to-end suite, at every chunk boundary of the format.

Not exercised against a real provider in this round: that OpenAI accepts
the request as edited (`"store": false`, `metadata` removed), and how real
models treat placeholders in practice. A model that paraphrases a
placeholder leaves it unrestored; try your own prompts before relying on
restoration.
