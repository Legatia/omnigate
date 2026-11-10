# Migrating from LiteLLM

`tools/import_litellm.py` converts a LiteLLM proxy `config.yaml` into an
omnigate config file. It handles the text side only: models, fallbacks,
prices and timeouts. It needs Python 3.9 or newer and nothing else.

## Run it

```bash
python tools/import_litellm.py litellm.yaml -o config/omnigate.json --generate-key myapp
```

| Argument | Meaning |
|---|---|
| `litellm.yaml` | Your LiteLLM proxy config. |
| `-o`, `--output` | Where to write the omnigate JSON. Without it, the JSON goes to standard output. |
| `--generate-key NAME` | Add one gateway key with this name. The key is printed once, to standard error; only its SHA-256 is written to the file. |

The JSON goes to the file (or standard output); everything else the tool has
to say goes to standard error:

- how many models and upstreams were imported;
- each entry it skipped, and why;
- the environment variables you need to set **for the data plane**;
- notes (missing prices, ignored fallbacks, a master key that was not
  imported).

It exits with an error if nothing could be imported.

Then start omnigate with `OMNIGATE_CONFIG` pointing at the result; see the
[Quickstart](quickstart.md#5-one-real-provider).

## What is carried over

| LiteLLM | omnigate |
|---|---|
| `model_list` entries | Routes. `model_name` becomes the route's `model`. |
| Several entries with the same `model_name` | One route with those entries as targets, in file order. |
| `router_settings.fallbacks` / `litellm_settings.fallbacks` | The fallback models' targets are appended to the source route. |
| `litellm_params.api_key: os.environ/NAME` | `api_key_env: NAME`. |
| `litellm_params.api_base` (or `base_url`) | The upstream's `base_url`, with a trailing `/v1` removed. |
| `input_cost_per_token`, `output_cost_per_token` (in `model_info` or `litellm_params`) | `price_in_per_mtok`, `price_out_per_mtok` (multiplied by one million). |
| `litellm_params.timeout` / `request_timeout` (seconds) | The upstream's `timeout_ms`. |

Imported routes have no `strategy`, so they use omnigate's default:
`failover`, in order. LiteLLM load-balances entries that share a
`model_name`; if that is what you want, add `"strategy": "round_robin"` or
`"weighted"` to the route afterwards
([Configuration](configuration.md#text-routes)).

### Providers that are mapped

The provider is the prefix of `litellm_params.model` (`openai/gpt-4o`). A
model with no prefix is treated as Anthropic if its name starts with
`claude`, otherwise as OpenAI.

| Prefix | Becomes | Base URL | Default key variable |
|---|---|---|---|
| `openai` | `openai` upstream | `https://api.openai.com` | `OPENAI_API_KEY` |
| `anthropic` | `anthropic` upstream | `https://api.anthropic.com` | `ANTHROPIC_API_KEY` |
| `gemini` | `openai` upstream with `v1_path: /v1beta/openai` | `https://generativelanguage.googleapis.com` | `GEMINI_API_KEY` |
| `xai` | `openai` upstream | `https://api.x.ai` | `XAI_API_KEY` |
| `groq` | `openai` upstream | `https://api.groq.com/openai` | `GROQ_API_KEY` |
| `mistral` | `openai` upstream | `https://api.mistral.ai` | `MISTRAL_API_KEY` |
| `deepseek` | `openai` upstream | `https://api.deepseek.com` | `DEEPSEEK_API_KEY` |
| `openrouter` | `openai` upstream | `https://openrouter.ai/api` | `OPENROUTER_API_KEY` |
| `together_ai` | `openai` upstream | `https://api.together.xyz` | `TOGETHERAI_API_KEY` |
| `fireworks_ai` | `openai` upstream | `https://api.fireworks.ai/inference` | `FIREWORKS_API_KEY` |
| `perplexity` | `openai` upstream with `v1_path: ""` | `https://api.perplexity.ai` | `PERPLEXITYAI_API_KEY` |
| `ollama` | `openai` upstream | `http://127.0.0.1:11434` | `OLLAMA_API_KEY` (invented) |
| `lm_studio` | `openai` upstream | `http://127.0.0.1:1234` | `LM_STUDIO_API_KEY` (invented) |
| `hosted_vllm` | `openai` upstream | none: the entry needs an `api_base` | `HOSTED_VLLM_API_KEY` (invented) |

When an entry has its own `api_base`, that URL is used instead of the
default, the upstream is named after that URL, and no `v1_path` is added.

Being mapped means the importer writes a config for it. It does not mean
the provider has been tested through omnigate: see
[Providers](providers.md) for which ones have.

## What is not carried over

- **Literal API keys.** A key written into the YAML is never copied. The
  tool invents an environment variable name, writes that into the config,
  and tells you to set the variable.
- **Providers with their own API shape** (Azure, Bedrock, Vertex and so
  on). Each such entry is listed as skipped.
- **An `api_base` that comes from an environment variable**
  (`os.environ/...`). The entry is skipped; write the URL in the config.
- **Virtual keys, teams and budgets.** They live in LiteLLM's database, not
  in the YAML. Create gateway keys in omnigate instead: in the config file,
  or at run time from the dashboard or the admin API
  ([Admin](admin.md)), with `budget_usd`, `budget_period` and `rpm` as
  needed. omnigate has keys but no teams or users.
- **`general_settings.master_key`.** Not imported; the tool says so. The
  nearest thing in omnigate is the admin token (`OMNIGATE_ADMIN_TOKEN`),
  which is set in the control plane's environment.
- **Per-deployment `rpm` / `tpm`, caching, guardrails and callbacks.**
  omnigate's own exact-match response cache is turned on per route with
  `cache_ttl_s` ([Configuration](configuration.md#response-cache)); the
  importer never sets it.

## After the import

1. **Keys.** If you did not use `--generate-key`, add at least one entry to
   `keys` ([Configuration](configuration.md#gateway-keys)), or create a key
   from the dashboard once the gateway is running.
2. **Environment.** Set every variable the tool listed in the data plane's
   environment.
3. **Prices.** Routes without prices in the YAML are imported with zero
   prices, and the tool names them. Fill in `price_in_per_mtok` /
   `price_out_per_mtok`, or spend will show as $0 and budgets will not
   trigger.
4. **Clients.** Point applications at the gateway with one of the new
   gateway keys. The model names they send stay the same (`model_name`).
   For the official SDKs that means changing `base_url` and the API key;
   see [Using the official SDKs](api.md#using-the-official-sdks).
5. **Media.** Add a `media` section by hand if you need image, video or
   speech jobs ([Providers](providers.md#media-providers)).

## YAML support

If PyYAML is installed, the tool uses it. Otherwise a small built-in parser
handles the plain block-style YAML these configs are usually written in,
and stops with a clear error on anything fancier (anchors, multi-line
strings). If you hit that error, install PyYAML and run it again.

## Tests

```bash
python tools/test_import_litellm.py
```
