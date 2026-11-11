# Providers

How to configure each provider that works today, and how far each has been
tested. The "Status" lines repeat the README's
[What has been verified](../README.md#what-has-been-verified) section
(November 2026); "verified" there means through the gateway, over TLS, with
real keys. Nothing has run
under sustained or concurrent load against real providers.

**After commits e4e30e4 and d79406b**, which replaced the control plane's
HTTP client and the data plane's response reader: the control plane's new
HTTP client and the data plane's new response reader were each run against
the real hosts of OpenAI, Anthropic, Gemini, xAI, ElevenLabs, Replicate and
fal with deliberately invalid keys; every provider's own auth error came
back intact. The successful paths were then re-run with real keys on 11 November 2026, at commit 809b96f, and all passed: OpenAI and Anthropic text (direct, streamed, translated both ways, tool calls, failover, metering), Gemini text, xAI text, an OpenAI image job, Gemini image, speech and video jobs, an xAI image job and a one-second xAI video, a Replicate image job, ElevenLabs speech with a cache hit, and output storage in a Cloudflare R2 bucket. fal has still only returned an auth error, never a completed job. The Sume adapter was added after all of this and has only met a mock.

Read every "Status: verified" line on this page, and the status column of
the media table, with that in mind: each records a check made before those
two commits, on the client and the reader they replaced. The check with
invalid keys changes no status below. It covers no successful request, and
the fal adapter is still not verified.

- [Text providers](#text-providers): OpenAI, Anthropic, Gemini, xAI, other
  OpenAI-compatible services
- [Media providers](#media-providers): Replicate, fal, OpenAI images,
  ElevenLabs, Gemini image and speech, Gemini video, xAI video, Sume
- [Not reachable](#not-reachable)

Model ids in the examples marked `<...>` are placeholders: use an id your
account has. Unless an example says otherwise its prices are `0.0`; fill in
your provider's prices to get spend figures and budgets. Text targets take
four prices: input, output, and optionally prompt-cache reads and writes
(`price_cached_in_per_mtok`, `price_cache_write_per_mtok`), which default to
the input price; see [Configuration](configuration.md#text-routes).

## Text providers

A text provider is an entry in `upstreams[]` plus one or more routes that
target it. Its key goes in the **data plane's** environment, under the name
in `api_key_env`. Field reference:
[Configuration](configuration.md#text-upstreams).

The gateway speaks two protocols, `openai` and `anthropic`. A client can use
either protocol with any upstream on `/v1/chat/completions` and
`/v1/messages`; see [Translation](api.md#translation).

For every text provider, the gateway passes the provider's rate-limit,
retry-after and request-id response headers on to the client
([API](api.md#response)), and tells prompt-cache reads and writes apart
from ordinary input when it meters a call
([Operations](operations.md#budgets)). Both are covered by unit tests on
OpenAI- and Anthropic-format responses; the "Status" lines below predate
them and do not include them.

What a text provider is sent, and how its answer is read, is the same for
all of them:

- **A request in the provider's own protocol is the client's own bytes.**
  The gateway replaces the value of `"model"` with the target's model id
  and changes nothing else, so key order, whitespace and the spelling of
  numbers reach the provider as the client wrote them. Two exceptions, both
  on streamed `/v1/chat/completions` and `/v1/completions` requests whose
  client did not set `stream_options.include_usage` to `true`: the gateway
  appends `"stream_options":{"include_usage":true}` to the body, or, when
  the body already has a `stream_options`, parses the body and writes it
  out again with the flag set, under the limits of the next point
  ([API](api.md#streaming)).
- **A translated request is rebuilt.** A request for a provider of the
  other protocol is parsed and written in that protocol. That step accepts
  at most 1,024 members in any one object and a bounded amount of memory; a
  request beyond either is refused with `400 request_too_complex` before
  anything is sent to a provider
  ([API](api.md#limits-on-what-one-request-and-one-key-may-hold)).
- **Clients must declare the length of a request body.** A chunked request
  body (`Transfer-Encoding: chunked`) is refused with `411`.
- **Answers are re-framed.** The gateway reads the provider's response body
  with its own bounded reader and frames the client's response itself; the
  provider's `content-length` is never passed on. An answer that is not an
  event stream and is at most 64 KiB is sent with a length the gateway
  counted; everything else is sent chunked.
- **An answer the provider cuts short.** Before anything was sent to the
  client it is a failed attempt and the next target is tried. Once the
  client's response has started, the client's connection is dropped
  without the closing chunk, so the client sees an incomplete response,
  and the call is recorded with status 499.
- **An answer with an ambiguous length** (both a `content-length` and
  chunked encoding, two different lengths, a transfer coding other than
  `chunked`) or a chunk size that does not parse is a failed attempt
  (`UpstreamUnparseable`); the next target is tried.
- **Timeouts.** A provider gets the upstream's `timeout_ms`
  (`OMNIGATE_UPSTREAM_TIMEOUT_MS` when that is `0`) to send its response
  headers. After that, a provider that sends nothing for
  `OMNIGATE_STREAM_IDLE_TIMEOUT_MS` (300,000 by default) ends the response.
  A client that is connected but takes none of the response is a separate
  case with its own, shorter timeout, `OMNIGATE_CLIENT_STALL_TIMEOUT_MS`
  (30,000).
- **A stream the client abandons is read on.** When the client hangs up or
  stalls, the gateway keeps reading the provider's answer in the background
  for the closing usage figures, for at most `OMNIGATE_ABORT_DRAIN_MS`
  (120,000, two minutes, by default) and `OMNIGATE_ABORT_DRAIN_MAX_MB` (64)
  more. The connection to the provider is closed only then, so the provider
  may go on generating until that point ([API](api.md#streaming)).

The details are in [API](api.md#response). `tools/malformed_test.py` plays
a provider that sends such answers (the special models of
`tools/mock_upstream.py`). What has been run against real providers since
this reader replaced the old one is recorded at the top of this page.

### OpenAI

```json
{ "name": "openai", "kind": "openai", "base_url": "https://api.openai.com", "api_key_env": "OPENAI_API_KEY" }
```

```json
{
  "model": "gpt",
  "targets": [
    { "upstream": "openai", "model": "<openai model id>", "price_in_per_mtok": 0.0, "price_out_per_mtok": 0.0 }
  ]
}
```

Status: verified. Chat completions (`gpt-4o-mini`, `gpt-5.4-mini`),
streaming, embeddings, the Responses API, provider errors.

### Anthropic

```json
{ "name": "anthropic", "kind": "anthropic", "base_url": "https://api.anthropic.com", "api_key_env": "ANTHROPIC_API_KEY" }
```

```json
{
  "model": "claude",
  "targets": [
    { "upstream": "anthropic", "model": "claude-sonnet-5-5", "price_in_per_mtok": 2.0, "price_out_per_mtok": 10.0 }
  ]
}
```

(This route is the one in `config/omnigate.example.json`, prices included;
check them against Anthropic's price list.)

The client's `anthropic-version` and `anthropic-beta` headers are forwarded;
without an `anthropic-version` the gateway sends `2023-06-01`.

Status: verified. Messages (`claude-haiku-5-5`, `claude-opus-5-5` with
thinking on), streaming, token counting, provider errors. Translation both
ways was verified between OpenAI and Anthropic: text, system prompts,
streaming, tool calls, tool-result round trips, streamed tool calls, error
shapes, refused sampling parameters.

Current Claude models refuse `temperature` and `top_p`. A client speaking
the Anthropic protocol gets Anthropic's own error for that. A client
speaking the OpenAI protocol (a translated request) gets a retry without
them.

### Gemini (text)

Google serves an OpenAI-compatible API, but not under `/v1`. Use an `openai`
upstream with `v1_path`:

```json
{
  "name": "gemini",
  "kind": "openai",
  "base_url": "https://generativelanguage.googleapis.com",
  "api_key_env": "GEMINI_API_KEY",
  "v1_path": "/v1beta/openai"
}
```

```json
{
  "model": "gemini",
  "targets": [
    { "upstream": "gemini", "model": "<gemini model id>", "price_in_per_mtok": 0.0, "price_out_per_mtok": 0.0 }
  ]
}
```

Status: verified with `gemini-3.5-flash-lite` and `gemini-embedding-001`.
Chat, streaming, tool calls and round trips, embeddings, provider errors,
failover to it, metering; and the same from an Anthropic-style client,
translated.

Gemini 3 and later demand a "thought signature" on earlier tool calls. An
Anthropic-style client cannot carry one, so when a translated request is
refused for that reason the gateway retries with the placeholder Google
documents and remembers it for that model.

Gemini's image, speech and video models are not served by this endpoint; see
[Gemini image and speech](#gemini-image-and-speech) and
[Gemini video](#gemini-video-interactions-api).

### xAI (Grok)

No provider-specific code: an `openai` upstream.

```json
{ "name": "xai", "kind": "openai", "base_url": "https://api.x.ai", "api_key_env": "XAI_API_KEY" }
```

```json
{
  "model": "grok",
  "targets": [
    { "upstream": "xai", "model": "<xai model id>", "price_in_per_mtok": 0.0, "price_out_per_mtok": 0.0 }
  ]
}
```

Status: verified with `grok-4.20-0309-non-reasoning`. Chat, streaming, tool
calls and round trips, the Responses API, provider errors, failover,
metering; the same from an Anthropic-style client, translated. The README
also records that xAI's own Anthropic-compatible endpoint worked as an
`anthropic` upstream; the repository does not record the base URL used for
that.

### Other OpenAI-compatible providers

Any service that speaks the OpenAI protocol can be an `openai` upstream. Set
`base_url` to the part before `/v1`, and add `v1_path` if the API is not
under `/v1`. The LiteLLM importer (`tools/import_litellm.py`) carries this
table of base URLs:

| Provider | `base_url` | `v1_path` | Default key variable |
|---|---|---|---|
| Groq | `https://api.groq.com/openai` | | `GROQ_API_KEY` |
| Mistral | `https://api.mistral.ai` | | `MISTRAL_API_KEY` |
| DeepSeek | `https://api.deepseek.com` | | `DEEPSEEK_API_KEY` |
| OpenRouter | `https://openrouter.ai/api` | | `OPENROUTER_API_KEY` |
| Together | `https://api.together.xyz` | | `TOGETHERAI_API_KEY` |
| Fireworks | `https://api.fireworks.ai/inference` | | `FIREWORKS_API_KEY` |
| Perplexity | `https://api.perplexity.ai` | `""` (API at the root) | `PERPLEXITYAI_API_KEY` |
| Ollama (local) | `http://127.0.0.1:11434` | | none |
| LM Studio (local) | `http://127.0.0.1:1234` | | none |

Status: none of the providers in this table appears in the README's list of
verified providers. Treat them as untested until you have tried them.

`api_key_env` is required in the config even for a local server that needs
no key; name any variable.

Example:

```json
{ "name": "groq", "kind": "openai", "base_url": "https://api.groq.com/openai", "api_key_env": "GROQ_API_KEY" }
```

### Failover across text providers

List several targets in one route. Verified per the README: failover from a
dead OpenAI-style upstream to Claude, with ledger token totals equal to what
the providers reported.

```json
{
  "model": "chat",
  "targets": [
    { "upstream": "openai", "model": "<openai model id>", "price_in_per_mtok": 0.0, "price_out_per_mtok": 0.0 },
    { "upstream": "anthropic", "model": "claude-sonnet-5-5", "price_in_per_mtok": 2.0, "price_out_per_mtok": 10.0 }
  ]
}
```

## Media providers

A media provider is an entry in `media.upstreams[]` plus one or more
`media.routes[]` that target it. Its key goes in the **control plane's**
environment. Field reference: [Configuration](configuration.md#media).

Clients use all of them through the same [Jobs API](api.md#jobs-api); only
the contents of `input` differ per adapter. Common behaviour:

- Each output is downloaded (or decoded) and stored in your storage; the job
  carries your URLs. Output downloads send no provider credentials. An
  output URL is fetched only if it, and every redirect on the way (at most
  five), resolves to a public address; otherwise the attempt fails with
  `output_fetch_failed: blocked: ...`. `media.webhooks.allow_private` lifts
  that for local development.
- A stored output is served as a download, with its content type kept only
  when it is a common image, video or audio type
  ([API](api.md#file-urls)).
- Per-character and per-second prices are applied to what the adapter
  sends to the provider, as listed per adapter in
  [Configuration](configuration.md#mediaroutes).
- **Durations and counts are checked when the job is created,** whatever
  the adapter. `input.duration` and `input.seconds` may be a number of 0 or
  more, a string that is one, or a number followed by `s`: `5`, `"5"`,
  `"2.5"`, `"5s"`. `input.n`, `input.num_outputs` and `input.num_images`
  must be whole numbers of 0 or more. Anything else is refused with
  `400 invalid_request`. The value is forwarded as the client wrote it; the
  gateway does not turn `"5s"` into `5`.
- **A per-second price needs a duration.** On a route with a target whose
  `per_second_usd` is above 0, a job that names no duration (or `0`) is
  refused with `400 invalid_request`, unless that target has
  `default_seconds`: then that many seconds are billed. `min_seconds` is
  the least that is billed, and a request for more than `max_seconds` is
  refused. The three settings change what is billed and accepted; they are
  not sent to the provider, which generates whatever length it would have
  anyway.
- **For `openai_images`, `elevenlabs`, `gemini` and `gemini_interactions`
  no duration is counted from the request.** A per-second price on such a
  target is billed from `default_seconds` and `min_seconds` alone: a
  `duration` the client writes is not what is billed. If you price such a
  target per second, set
  `default_seconds`. Without it a job that names no duration is refused,
  and one that names any duration above 0 is accepted and billed only
  `min_seconds` for that part of the price (nothing, when that is not set
  either).
- **A route can restrict and price input options.** `allowed_input` lists
  the top-level `input` fields a job may carry; a job with any other field
  is refused instead of forwarded. `price_multipliers` puts a factor on the
  job's price by the value of an input field (a quality, a size), and then
  only the listed values are accepted. Both are described in
  [Configuration](configuration.md#price-multipliers). They matter most for
  adapters that forward the whole `input`: the provider charges for options
  your price otherwise knows nothing about.
- **Provider answers are read through caps.** An API answer (a submit, a
  poll, a result) may be at most 4 MiB. An answer that carries the media
  inline (`elevenlabs`, `gemini`, `gemini_interactions`, `openai_images`)
  may be four thirds of `media.max_output_bytes` plus 64 KiB, and never
  more than 256 MiB; it is held in memory. A download may be at most
  `media.max_output_bytes`. A larger answer is a failed call
  (`request_failed: :response_too_large`) or a failed download
  (`output_fetch_failed: :output_too_large`), and the attempt fails; a
  poll is tried five times in a row first.
- **A provider's error text is cut before it is stored.** What a provider
  says about a failure ends up in the job's `attempts[].outcome`: at most
  300 characters, made one line of valid UTF-8 first.
- Targets in a route are tried in order. A failed submit, a provider-side
  failure, a timeout (`timeout_s`) or an answer with no outputs moves on to
  the next target.
- No per-upstream concurrency limits, and no transcoding.

The duration, input and multiplier settings are covered by the control
plane's unit tests (`control/test/wave6_test.exs`) against a stub provider.
None of them has been used with a real provider.

| `kind` | Provider API | Style | Status |
|---|---|---|---|
| `replicate` | Replicate predictions | submit and poll | verified |
| `fal` | fal queue | submit and poll | mock only |
| `openai_images` | OpenAI image generation | one call | verified |
| `elevenlabs` | ElevenLabs text to speech | one call | verified |
| `gemini` | Gemini `generateContent` (image, speech) | one call | verified |
| `gemini_interactions` | Gemini Interactions API (video) | one call, or submit and poll | verified in the foreground; background polling mock only |
| `xai_video` | xAI video generation | submit and poll | verified |
| `sume` | Sume image and video routers | submit and poll | mock only |

### Replicate

```json
{ "name": "replicate", "kind": "replicate", "base_url": "https://api.replicate.com", "api_key_env": "REPLICATE_API_TOKEN" }
```

```json
{
  "model": "image",
  "timeout_s": 300,
  "targets": [
    { "upstream": "replicate", "model": "<owner/name or owner/name:version>", "price": { "per_output_usd": 0.0 } }
  ]
}
```

The target `model` is `owner/name` (the gateway calls
`POST /v1/models/{owner}/{name}/predictions`) or `owner/name:version` (it
calls `POST /v1/predictions` with that version). The job's `input` is sent
as the prediction's `input`, so it takes whatever the Replicate model takes:

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer <gateway key>" -d '{"model":"image","input":{"prompt":"a lighthouse at dusk"}}'
```

The prediction is polled until it is `succeeded`, `failed` or `canceled`.
Its `output` (a URL or a list of URLs) becomes the job's outputs.

Status: verified with `black-forest-labs/flux-1.1-pro`: prediction created
and polled to completion, the image copied off Replicate and downloaded from
the gateway, webhook delivered; an unknown model and an out-of-credit model
failed with Replicate's own reasons. Not verified: the `owner/name:version`
form, and job cancellation at a real provider.

### fal

```json
{ "name": "fal", "kind": "fal", "base_url": "https://queue.fal.run", "api_key_env": "FAL_KEY" }
```

```json
{
  "model": "video",
  "timeout_s": 900,
  "targets": [
    { "upstream": "fal", "model": "<fal video model id>", "price": { "per_second_usd": 0.0 }, "default_seconds": 5, "min_seconds": 1, "max_seconds": 10 }
  ]
}
```

(As in `config/omnigate.example.json`. The three `_seconds` settings take
effect once `per_second_usd` is above 0.)

The job's `input` is sent as the body of `POST {base_url}/{model}`. The
queue is polled until `COMPLETED`; every object with a `url` field in the
result (`images[]`, `video`, `audio` and so on) becomes an output. The
status, result and cancel URLs fal returns are followed only when they are
under the configured `base_url`.

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer <gateway key>" -d '{"model":"video","input":{"prompt":"waves","duration":5}}'
```

With `per_second_usd`, the price is multiplied by the larger of
`input.duration` and `input.seconds` (each a number, a numeric string or a
number followed by `s`), or by the target's `default_seconds` when the job
names neither, and never by less than `min_seconds`; see
[Media providers](#media-providers) above for when a job is refused. With
`per_input_char_usd`, the characters of `input.prompt`, `input.text` and
`input.input` are added together, because the whole `input` is sent. The
same holds for the Replicate and xAI video adapters.

Status: **not verified.** The fal adapter has only run against a mock
written from public documentation; expect details to differ.

### OpenAI images

```json
{ "name": "openai-images", "kind": "openai_images", "base_url": "https://api.openai.com", "api_key_env": "OPENAI_API_KEY" }
```

```json
{
  "model": "image-sync",
  "targets": [
    { "upstream": "openai-images", "model": "<openai image model id>", "price": { "per_output_usd": 0.0 } }
  ],
  "allowed_input": ["prompt", "size", "quality", "background", "output_format"],
  "price_multipliers": {
    "quality": { "low": 1, "medium": 4, "high": 16, "default": 16 },
    "size": { "1024x1024": 1, "1024x1536": 1.5, "1536x1024": 1.5, "default": 1.5 }
  }
}
```

(As in `config/omnigate.example.json`. Check the fields and the factors
against your provider's documentation and price list.)

One synchronous `POST /v1/images/generations`. The job's `input` is the
request body, with `model` set to the target's model. Results may come back
as `b64_json` or as a `url`; both are stored. For base64 results the stored
content type follows `input.output_format` (`jpeg`, `webp`, otherwise PNG).

Because the whole `input` is forwarded, a client can ask for options that
change what the provider charges. With the route above:

- a job may carry only the five listed fields; one with `n`, say, is
  refused with `400 invalid_request`;
- `quality` and `size` must be one of the listed values, and the job's
  price is multiplied by both factors (`"default"` is the factor for a job
  that does not send the field).

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer <gateway key>" -d '{"model":"image-sync","input":{"prompt":"a red cube"}}'
```

The same adapter works for other providers with an OpenAI-style images
endpoint: point `base_url` at them (for xAI, `https://api.x.ai`).

Status: verified with `gpt-image-1-mini` (generated, re-hosted, downloaded,
webhook retried and delivered), and with xAI's `grok-imagine-image` through
this adapter.

### ElevenLabs

```json
{ "name": "elevenlabs", "kind": "elevenlabs", "base_url": "https://api.elevenlabs.io", "api_key_env": "ELEVENLABS_API_KEY" }
```

```json
{
  "model": "speech",
  "cache_ttl_s": 2592000,
  "targets": [
    { "upstream": "elevenlabs", "model": "<elevenlabs model_id>", "price": { "per_input_char_usd": 0.0 } }
  ]
}
```

One synchronous `POST /v1/text-to-speech/{voice_id}`. Job `input`:

| Field | Required | Meaning |
|---|---|---|
| `text` | yes | What to say. |
| `voice_id` | yes | The ElevenLabs voice (letters, digits, `_` and `-` only). |
| `output_format` | no | Default `mp3_44100_128`. |
| anything else | no | Passed through in the request body. |

`model_id` is set to the target's model.

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer <gateway key>" -d '{"model":"speech","input":{"text":"Hello from omnigate.","voice_id":"<voice id>"}}'
```

Speech is a good fit for `cache_ttl_s`: an identical request then reuses the
stored audio with no provider call and no charge.

Status: verified with `eleven_flash_v2_5`: real MP3 generated, re-hosted and
downloaded; an identical request served from cache; an unknown voice failed
with the provider's reason.

### Gemini image and speech

Gemini's image and speech models are served only by Google's native API, so
they use a media adapter instead of the text upstream.

```json
{ "name": "gemini-media", "kind": "gemini", "base_url": "https://generativelanguage.googleapis.com", "api_key_env": "GEMINI_API_KEY" }
```

```json
{
  "model": "gemini-image",
  "targets": [
    { "upstream": "gemini-media", "model": "<gemini image model id>", "price": { "per_output_usd": 0.0 } }
  ]
}
```

```json
{
  "model": "gemini-speech",
  "cache_ttl_s": 86400,
  "targets": [
    { "upstream": "gemini-media", "model": "<gemini tts model id>", "price": { "per_input_char_usd": 0.0 } }
  ]
}
```

One synchronous `POST /v1beta/models/{model}:generateContent`. Job `input`
is either the short form:

| Field | Meaning |
|---|---|
| `prompt` (or `text`) | The prompt, or the text to speak. |
| `voice` | For speech: a voice name such as `Kore`. Its presence also asks for audio output. |

or Gemini's own request fields, sent through untouched: `contents` (a list)
with optional `generationConfig`, `systemInstruction` and `safetySettings`.
Use this for anything the short form does not cover, such as reference
images or several speakers.

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer <gateway key>" -d '{"model":"gemini-image","input":{"prompt":"a green cube"}}'
```

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer <gateway key>" -d '{"model":"gemini-speech","input":{"text":"Hello from omnigate.","voice":"Kore"}}'
```

Files come back inline. Raw PCM speech (`audio/L16`) is wrapped in a WAV
header so the stored file plays as it is. A prompt Google refuses fails the
attempt with Google's reason (`no_output: prompt blocked (...)`).

Status: verified with `gemini-3.1-flash-lite-image` and
`gemini-3.8-flash-lite-tts`: an image and a spoken sentence generated,
stored and downloaded from the gateway; the repeat speech request served
from cache; an unknown model failed with Google's reason.

### Gemini video (Interactions API)

Gemini's video-capable "omni" models are reachable only through the
Interactions API.

```json
{ "name": "gemini-interactions", "kind": "gemini_interactions", "base_url": "https://generativelanguage.googleapis.com", "api_key_env": "GEMINI_API_KEY" }
```

```json
{
  "model": "gemini-video",
  "timeout_s": 600,
  "targets": [
    { "upstream": "gemini-interactions", "model": "<gemini omni model id>", "price": { "per_job_usd": 0.0 } }
  ]
}
```

`POST /v1beta/interactions`. Job `input` is either `prompt` (or `text`), or
a native Interactions body that has an `input` field; in both cases `model`
is filled in from the target.

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer <gateway key>" -d '{"model":"gemini-video","input":{"prompt":"a short clip of waves"}}'
```

A native body with `"background": true` makes Google answer before the work
is done; the gateway then polls `GET /v1beta/interactions/{id}`:

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer <gateway key>" -d '{"model":"gemini-video","input":{"input":"a longer clip of waves","background":true}}'
```

A foreground request is one HTTP call that lasts as long as the generation;
`timeout_s` is its limit.

Status: verified with `gemini-omni-1.2-flash`: a short clip generated in one
call, stored and downloaded from the gateway as an MP4, webhook delivered.
Not verified: background interactions (the polling path has only met the
mock).

### xAI video

```json
{ "name": "xai-video", "kind": "xai_video", "base_url": "https://api.x.ai", "api_key_env": "XAI_API_KEY" }
```

```json
{
  "model": "grok-video",
  "timeout_s": 900,
  "targets": [
    { "upstream": "xai-video", "model": "<xai video model id>", "price": { "per_second_usd": 0.0 }, "default_seconds": 5, "min_seconds": 1, "max_seconds": 10 }
  ]
}
```

`POST /v1/videos/generations` with the job's `input` plus `model`, then
`GET /v1/videos/{request_id}` until the status is `done`, `failed` or
`expired`. `input` takes `prompt` and optionally `duration` (seconds),
`aspect_ratio`, `resolution` and `image: {"url": ...}`.

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer <gateway key>" -d '{"model":"grok-video","input":{"prompt":"a wave breaking","duration":4}}'
```

Price it with `per_second_usd`, which is multiplied by `input.duration`
(or `input.seconds`, whichever is larger). With a price above 0:

- If the client leaves both out, the target's `default_seconds` are
  billed, whatever length the provider then generates. Without
  `default_seconds` the job is refused with `400 invalid_request`. (Until
  commit d79406b such a job was accepted and that part of its price was
  zero.)
- Never less than `min_seconds` is billed, and a request for more than
  `max_seconds` is refused.
- A negative value, or one that is not a duration, is refused when the job
  is created.

None of the three settings is sent to xAI: set them to what the model
does.

Status: verified with `grok-imagine-video-1.5-lite`: a one-second clip
submitted, polled to completion, copied off xAI and downloaded from the
gateway as an MP4, billed per second, webhook delivered; an unknown model
failed with xAI's reason. Not verified: an input image, and the failed and
expired states.

### Sume

[Sume](https://www.sume.com/docs) is an aggregator: one key reaches image
and video models of many makers through two generate endpoints, and every
request is a job that is polled.

```json
{ "name": "sume", "kind": "sume", "api_key_env": "SUME_API_KEY" }
```

`base_url` may be left out for this kind; it defaults to
`https://api.sume.com`.

```json
{
  "model": "veo-fast",
  "timeout_s": 900,
  "targets": [
    {
      "upstream": "sume",
      "model": "<sume video model id>",
      "router": "video",
      "max_seconds": 8,
      "price": {
        "variants": [
          { "when": { "resolution": "720p", "generate_audio": false }, "per_second_usd": 0.0 },
          { "when": { "resolution": "720p", "generate_audio": true }, "per_second_usd": 0.0 }
        ]
      }
    }
  ]
},
{
  "model": "sume-image",
  "targets": [
    { "upstream": "sume", "model": "<sume image model id>", "router": "image", "price": { "per_output_usd": 0.0 } }
  ]
}
```

- **`router` is required** on every Sume target: `"image"` for models on
  Sume's Image Router, `"video"` for those on its Video Router (video,
  lip-sync, captions). The config is refused without it; the gateway does
  not guess from a model's name. Sume's model list says which is which.
- `input` is sent as Sume's request body with `model` filled in:
  `prompt`, `duration`, `resolution`, `aspect_ratio`, `image_url`,
  `num_images` and whatever else the model takes. Sume refuses a field the
  model does not take, and the job then moves on with
  `sume_invalid_request`.
- `mode` is always sent as `"async"`, and an `input.webhook_url`,
  `input.metadata` or `input.wait_timeout_seconds` is never forwarded. The
  job's own `webhook_url` and `metadata` stay with the gateway, as for
  every provider.
- **One charge per job.** Every submit carries an `Idempotency-Key`
  derived from the gateway's job id and the attempt. If the answer to a
  submit is lost, or the gateway restarts before it has recorded Sume's job
  id, the submit is sent again with the same key and Sume answers with the
  original job instead of starting a second one.
- **Polling** follows what Sume asks for: `next_poll_after_seconds` (or the
  `x-sume-poll-after` header) when it is longer than
  `media.poll_interval_ms`, up to 60 seconds, and `retry-after` on a 429,
  which is treated as a request to wait rather than a failed poll. Repeated
  5xx answers give the job up to the next target.
- **Outputs** are the `url` of each artifact in the job's result, fetched
  from Sume's media host under the same address checks as every provider
  output, and stored by the gateway.
- **Prices.** Sume charges per second or per image, and the rate depends on
  the request (resolution, for some models whether audio is generated).
  Use [`price.variants`](configuration.md#price-variants) to say so; a
  request with no variant is refused when the job is created. For a job
  priced per second, the seconds are those Sume reports for the artifact
  (`duration_ms`) when it reports them, otherwise the `input.duration`
  asked for. Images are billed per artifact stored (`per_output_usd`).
  The rates themselves are yours to enter, from Sume's pricing page or its
  catalog (`GET https://api.sume.com/v1/catalog`); nothing in this
  repository tracks them, and what Sume charges has not been compared with
  what the gateway records.
- **Failures.** A refusal or a failed job is recorded as `sume_<code>`
  with Sume's message, where the code is Sume's own (`sume_insufficient_funds`,
  `sume_rate_limited`, `sume_unauthorized`), or `sume_<public_reason>` for
  a job that failed (`sume_content_policy_rejected`). For a private job
  only that word is kept. A refusal Sume marks retryable with a wait of at
  most 10 seconds is retried once on Sume, with the same key; every other
  refusal moves the job to the route's next target, **including
  insufficient funds**: another provider may still be able to run it. Sume
  says a refused submit and a failed job are not charged.
- **Cancel.** Sume can stop a job only until generation starts. While it
  reports the job as cancelable, canceling the gateway's job cancels it
  there and nothing is owed. After that, the gateway's job is canceled at
  once but Sume's keeps running: the gateway keeps polling it and records
  its price if it completes, as it does for a provider with no cancel at
  all ([API](api.md#cancel-a-job)).

Status: **not verified.** The adapter was written from Sume's public
documentation (read on 11 November 2026) and has only run against the
project's mock of it; no request has been made with a Sume key. Expect
details to differ. Its public endpoints were reached without a key: the
catalog answers, and a submit is refused with the documented error object.

### Failover across media providers

List several targets in one media route; they may be of different kinds, as
long as each accepts the same `input`:

```json
{
  "model": "image",
  "timeout_s": 300,
  "targets": [
    { "upstream": "fal", "model": "<fal model id, e.g. owner/model>", "price": { "per_output_usd": 0.0 } },
    { "upstream": "replicate", "model": "<owner/name or owner/name:version>", "price": { "per_output_usd": 0.0 } }
  ]
}
```

The job's cost is the price of the target that delivered. Provider charges
for failed attempts are not recorded or reconciled.

## Not reachable

- Azure, Bedrock and Vertex (providers with their own API shape).
- Gemini's Veo models, which have their own job API and no adapter yet.
- Other media shapes (Kling, Runway, BFL): there is no adapter for them.
- Realtime voice.
