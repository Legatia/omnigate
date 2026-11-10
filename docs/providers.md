# Providers

How to configure each provider that works today, and how far each has been
tested. The "Status" lines repeat the README's
[What has been verified](../README.md#what-has-been-verified) section
(November 2026); "verified" there means through the gateway, over TLS, with
real keys. Nothing has run
under sustained or concurrent load against real providers.

- [Text providers](#text-providers): OpenAI, Anthropic, Gemini, xAI, other
  OpenAI-compatible services
- [Media providers](#media-providers): Replicate, fal, OpenAI images,
  ElevenLabs, Gemini image and speech, Gemini video, xAI video
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
  [Configuration](configuration.md#mediaroutes). `duration`, `seconds`,
  `n`, `num_outputs` and `num_images` in a job's `input` must not be
  negative, whatever the adapter.
- Targets in a route are tried in order. A failed submit, a provider-side
  failure, a timeout (`timeout_s`) or an answer with no outputs moves on to
  the next target.
- No per-upstream concurrency limits, and no transcoding.

| `kind` | Provider API | Style | Status |
|---|---|---|---|
| `replicate` | Replicate predictions | submit and poll | verified |
| `fal` | fal queue | submit and poll | mock only |
| `openai_images` | OpenAI image generation | one call | verified |
| `elevenlabs` | ElevenLabs text to speech | one call | verified |
| `gemini` | Gemini `generateContent` (image, speech) | one call | verified |
| `gemini_interactions` | Gemini Interactions API (video) | one call, or submit and poll | verified in the foreground; background polling mock only |
| `xai_video` | xAI video generation | submit and poll | verified |

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
    { "upstream": "fal", "model": "<fal video model id>", "price": { "per_second_usd": 0.0 } }
  ]
}
```

The job's `input` is sent as the body of `POST {base_url}/{model}`. The
queue is polled until `COMPLETED`; every object with a `url` field in the
result (`images[]`, `video`, `audio` and so on) becomes an output. The
status, result and cancel URLs fal returns are followed only when they are
under the configured `base_url`.

```bash
curl http://127.0.0.1:8080/v1/jobs -H "Authorization: Bearer <gateway key>" -d '{"model":"video","input":{"prompt":"waves","duration":5}}'
```

With `per_second_usd`, the price is multiplied by the larger of
`input.duration` and `input.seconds`. With `per_input_char_usd`, the
characters of `input.prompt`, `input.text` and `input.input` are added
together, because the whole `input` is sent. The same holds for the
Replicate and xAI video adapters.

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
  ]
}
```

One synchronous `POST /v1/images/generations`. The job's `input` is the
request body, with `model` set to the target's model. Results may come back
as `b64_json` or as a `url`; both are stored. For base64 results the stored
content type follows `input.output_format` (`jpeg`, `webp`, otherwise PNG).

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
    { "upstream": "xai-video", "model": "<xai video model id>", "price": { "per_second_usd": 0.0 } }
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
(or `input.seconds`, whichever is larger). If the client leaves both out,
that part of the price is zero, whatever length the provider then
generates; a negative value is refused when the job is created.

Status: verified with `grok-imagine-video-1.5-lite`: a one-second clip
submitted, polled to completion, copied off xAI and downloaded from the
gateway as an MP4, billed per second, webhook delivered; an unknown model
failed with xAI's reason. Not verified: an input image, and the failed and
expired states.

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
