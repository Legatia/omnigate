"""Convert a LiteLLM proxy config.yaml into an omnigate config JSON.

    python tools/import_litellm.py litellm.yaml -o config/omnigate.json
    python tools/import_litellm.py litellm.yaml --generate-key myapp

What is carried over
  * model_list entries -> routes. Entries that share a model_name become
    ordered failover targets (set "strategy": "round_robin" or "weighted" on
    the route afterwards if you want omnigate to spread load across them).
  * router_settings.fallbacks / litellm_settings.fallbacks -> extra targets
    appended to the route.
  * api_key: os.environ/NAME -> api_key_env NAME. A literal key is never
    copied: an env var name is invented and printed for you to set.
  * model_info / litellm_params input_cost_per_token and output_cost_per_token
    -> prices per million tokens.
  * litellm_params.timeout / request_timeout (seconds) -> upstream timeout_ms.

What is not
  * Providers that are neither OpenAI- nor Anthropic-shaped at a /v1 path
    (Azure, Bedrock, Vertex, ...). They are listed as skipped.
  * Virtual keys, teams and budgets (they live in LiteLLM's database, not in
    the YAML), per-deployment rpm/tpm, caching, guardrails and callbacks.

Uses PyYAML when it is installed. Otherwise a small built-in parser handles
the plain block-style YAML these configs are written in, and stops with a
clear error on anything fancier (anchors, multi-line strings).
"""

import argparse
import hashlib
import json
import re
import secrets
import sys

# provider prefix -> (protocol kind, default base URL, default key env var)
PROVIDERS = {
    "openai": ("openai", "https://api.openai.com", "OPENAI_API_KEY"),
    "anthropic": ("anthropic", "https://api.anthropic.com", "ANTHROPIC_API_KEY"),
    "groq": ("openai", "https://api.groq.com/openai", "GROQ_API_KEY"),
    "mistral": ("openai", "https://api.mistral.ai", "MISTRAL_API_KEY"),
    "deepseek": ("openai", "https://api.deepseek.com", "DEEPSEEK_API_KEY"),
    "openrouter": ("openai", "https://openrouter.ai/api", "OPENROUTER_API_KEY"),
    "together_ai": ("openai", "https://api.together.xyz", "TOGETHERAI_API_KEY"),
    "fireworks_ai": ("openai", "https://api.fireworks.ai/inference", "FIREWORKS_API_KEY"),
    "xai": ("openai", "https://api.x.ai", "XAI_API_KEY"),
    "gemini": ("openai", "https://generativelanguage.googleapis.com", "GEMINI_API_KEY"),
    "perplexity": ("openai", "https://api.perplexity.ai", "PERPLEXITYAI_API_KEY"),
    # OpenAI-compatible servers the user points at with api_base.
    "hosted_vllm": ("openai", None, None),
    "ollama": ("openai", "http://127.0.0.1:11434", None),
    "lm_studio": ("openai", "http://127.0.0.1:1234", None),
}


# Providers whose OpenAI-compatible API is not served under /v1.
V1_PATHS = {"gemini": "/v1beta/openai", "perplexity": ""}


# --------------------------------------------------------------------------
# Minimal YAML (fallback when PyYAML is absent)
# --------------------------------------------------------------------------

class YamlError(ValueError):
    pass


def _strip_comment(line):
    quote = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
    return line


def _scalar(text):
    t = text.strip()
    if t == "" or t in ("~", "null", "Null", "NULL"):
        return None
    if t[0] in "[{":
        value, rest = _flow(t, 0)
        if t[rest:].strip():
            raise YamlError(f"trailing text after flow collection: {t!r}")
        return value
    if t[0] in "|>&*!":
        raise YamlError(f"unsupported YAML feature in {t!r}; install PyYAML (pip install pyyaml)")
    if len(t) >= 2 and t[0] == t[-1] and t[0] in "'\"":
        return t[1:-1]
    if t in ("true", "True", "TRUE"):
        return True
    if t in ("false", "False", "FALSE"):
        return False
    if re.fullmatch(r"[-+]?\d+", t):
        return int(t)
    if re.fullmatch(r"[-+]?(\d+\.\d*|\.\d+|\d+)([eE][-+]?\d+)?", t):
        return float(t)
    return t


def _flow(t, i):
    """Parse a flow collection or scalar starting at t[i]; return (value, next index)."""
    while i < len(t) and t[i] == " ":
        i += 1
    if i < len(t) and t[i] == "[":
        out, i = [], i + 1
        while True:
            while i < len(t) and t[i] in " ,":
                i += 1
            if i >= len(t):
                raise YamlError(f"unterminated [ in {t!r}")
            if t[i] == "]":
                return out, i + 1
            value, i = _flow(t, i)
            out.append(value)
    if i < len(t) and t[i] == "{":
        out, i = {}, i + 1
        while True:
            while i < len(t) and t[i] in " ,":
                i += 1
            if i >= len(t):
                raise YamlError(f"unterminated {{ in {t!r}")
            if t[i] == "}":
                return out, i + 1
            key, i = _flow_token(t, i, ":")
            if i >= len(t) or t[i] != ":":
                raise YamlError(f"expected ':' in flow mapping {t!r}")
            value, i = _flow(t, i + 1)
            out[key] = value
    return _flow_token(t, i, ",]}")


def _flow_token(t, i, stops):
    while i < len(t) and t[i] == " ":
        i += 1
    if i < len(t) and t[i] in "'\"":
        end = t.index(t[i], i + 1)
        return t[i + 1:end], end + 1
    j = i
    while j < len(t) and t[j] not in stops:
        j += 1
    return _scalar(t[i:j]), j


def _split_key(content):
    """'key: value' -> (key, value_text) or None when the line is not a mapping entry."""
    if content[:1] in "'\"":
        end = content.find(content[0], 1)
        if end == -1:
            return None
        rest = content[end + 1:]
        if rest.startswith(":") and (len(rest) == 1 or rest[1] in " \t"):
            return content[1:end], rest[1:]
        return None
    if content[:1] in "[{":
        return None
    m = re.match(r"([^:]+?):(\s+.*|\s*)$", content)
    if not m:
        return None
    return m.group(1).strip(), m.group(2)


def parse_yaml(text):
    lines = []
    for raw in text.splitlines():
        if raw.strip() in ("---", "..."):
            continue
        line = _strip_comment(raw).rstrip()
        if not line.strip():
            continue
        if "\t" in line[: len(line) - len(line.lstrip())]:
            raise YamlError("tabs are not valid YAML indentation")
        lines.append([len(line) - len(line.lstrip()), line.strip()])
    if not lines:
        return None
    value, i = _block(lines, 0, lines[0][0])
    if i != len(lines):
        raise YamlError(f"could not parse line: {lines[i][1]!r}")
    return value


def _block(lines, i, indent):
    if lines[i][1] == "-" or lines[i][1].startswith("- "):
        out = []
        while i < len(lines) and lines[i][0] == indent and (lines[i][1] == "-" or lines[i][1].startswith("- ")):
            content = lines[i][1]
            item = content[1:].lstrip()
            if not item:
                if i + 1 < len(lines) and lines[i + 1][0] > indent:
                    value, i = _block(lines, i + 1, lines[i + 1][0])
                else:
                    value, i = None, i + 1
            elif _split_key(item) is not None or item == "-" or item.startswith("- "):
                # "- key: value" or "- - x": a collection that starts on the dash line.
                inner = indent + (len(content) - len(item))
                lines[i] = [inner, item]
                value, i = _block(lines, i, inner)
            else:
                value, i = _scalar(item), i + 1
            out.append(value)
        return out, i

    out = {}
    while i < len(lines) and lines[i][0] == indent and not (lines[i][1] == "-" or lines[i][1].startswith("- ")):
        pair = _split_key(lines[i][1])
        if pair is None:
            raise YamlError(f"expected 'key: value', got {lines[i][1]!r}")
        key, value_text = pair
        if value_text.strip():
            out[key] = _scalar(value_text)
            i += 1
        elif i + 1 < len(lines) and lines[i + 1][0] > indent:
            out[key], i = _block(lines, i + 1, lines[i + 1][0])
        elif i + 1 < len(lines) and lines[i + 1][0] == indent and (lines[i + 1][1] == "-" or lines[i + 1][1].startswith("- ")):
            # A sequence may sit at the same indent as its key.
            out[key], i = _block(lines, i + 1, indent)
        else:
            out[key] = None
            i += 1
    return out, i


def load_yaml(text):
    try:
        import yaml  # type: ignore
    except ImportError:
        return parse_yaml(text)
    return yaml.safe_load(text)


# --------------------------------------------------------------------------
# Conversion
# --------------------------------------------------------------------------

def _slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "upstream"


def _env_name(text):
    return re.sub(r"[^A-Z0-9]+", "_", text.upper()).strip("_") + "_API_KEY"


def convert(doc):
    """Return (omnigate_config, report). `report` lists skipped models, env vars and notes."""
    doc = doc or {}
    report = {"skipped": [], "env": {}, "notes": []}
    upstreams = {}   # (kind, base_url, api_key_env, timeout_ms) -> upstream dict
    routes = {}      # model_name -> list of targets (insertion order kept)

    for entry in doc.get("model_list") or []:
        name = entry.get("model_name")
        params = entry.get("litellm_params") or {}
        info = entry.get("model_info") or {}
        model = params.get("model")
        if not name or not isinstance(model, str):
            report["skipped"].append((str(name), "entry has no model_name or litellm_params.model"))
            continue

        if "/" in model and model.split("/", 1)[0] in PROVIDERS:
            provider, target_model = model.split("/", 1)
        elif "/" in model:
            report["skipped"].append((name, f"provider '{model.split('/', 1)[0]}' is not OpenAI- or Anthropic-shaped at /v1"))
            continue
        else:
            provider, target_model = ("anthropic" if model.startswith("claude") else "openai"), model

        kind, base_url, default_env = PROVIDERS[provider]
        api_base = params.get("api_base") or params.get("base_url")
        if isinstance(api_base, str) and api_base.startswith("os.environ/"):
            report["skipped"].append((name, "api_base comes from an environment variable; write the URL in the config"))
            continue
        if api_base:
            # omnigate appends the client's path (/v1/...), so drop a trailing /v1.
            base_url = re.sub(r"/v1/?$", "", api_base.rstrip("/"))
        if not base_url:
            report["skipped"].append((name, f"provider '{provider}' needs an api_base"))
            continue

        api_key = params.get("api_key")
        if isinstance(api_key, str) and api_key.startswith("os.environ/"):
            key_env = api_key.split("/", 1)[1]
        elif api_key:
            key_env = _env_name(provider if not api_base else _slug(base_url.split("//", 1)[-1]))
            report["env"][key_env] = "a literal api_key was in the YAML; it was NOT copied. Set this variable to it."
        else:
            key_env = default_env or _env_name(provider)
        report["env"].setdefault(key_env, f"API key for {base_url}")

        timeout = params.get("timeout") or params.get("request_timeout")
        timeout_ms = int(float(timeout) * 1000) if isinstance(timeout, (int, float)) and timeout > 0 else 0

        ident = (kind, base_url, key_env, timeout_ms)
        if ident not in upstreams:
            base_name = provider if not api_base else _slug(base_url.split("//", 1)[-1])
            up_name, n = base_name, 2
            while any(u["name"] == up_name for u in upstreams.values()):
                up_name, n = f"{base_name}-{n}", n + 1
            up = {"name": up_name, "kind": kind, "base_url": base_url, "api_key_env": key_env}
            if provider in V1_PATHS and not api_base:
                up["v1_path"] = V1_PATHS[provider]
            if timeout_ms:
                up["timeout_ms"] = timeout_ms
            upstreams[ident] = up

        target = {"upstream": upstreams[ident]["name"], "model": target_model}
        cost_in = info.get("input_cost_per_token", params.get("input_cost_per_token"))
        cost_out = info.get("output_cost_per_token", params.get("output_cost_per_token"))
        target["price_in_per_mtok"] = round(float(cost_in) * 1e6, 6) if isinstance(cost_in, (int, float)) else 0.0
        target["price_out_per_mtok"] = round(float(cost_out) * 1e6, 6) if isinstance(cost_out, (int, float)) else 0.0
        if target not in routes.setdefault(name, []):
            routes[name].append(target)

    # Fallbacks: [{"model-a": ["model-b", "model-c"]}, ...]
    primary = {name: list(targets) for name, targets in routes.items()}
    for section in ("router_settings", "litellm_settings"):
        for mapping in (doc.get(section) or {}).get("fallbacks") or []:
            if not isinstance(mapping, dict):
                continue
            for source, fallbacks in mapping.items():
                if source not in routes:
                    report["notes"].append(f"fallback source '{source}' is not an imported model; ignored")
                    continue
                for fb in fallbacks or []:
                    if fb not in primary:
                        report["notes"].append(f"fallback '{fb}' for '{source}' is not an imported model; ignored")
                        continue
                    for target in primary[fb]:
                        if target not in routes[source]:
                            routes[source].append(target)

    unpriced = [name for name, targets in routes.items()
                if any(t["price_in_per_mtok"] == 0.0 and t["price_out_per_mtok"] == 0.0 for t in targets)]
    if unpriced:
        report["notes"].append("no prices in the YAML for: " + ", ".join(sorted(unpriced))
                               + ". Fill price_in_per_mtok / price_out_per_mtok or spend will show as $0.")
    if (doc.get("general_settings") or {}).get("master_key"):
        report["notes"].append("general_settings.master_key was not imported; create gateway keys instead.")

    config = {
        "keys": [],
        "upstreams": list(upstreams.values()),
        "routes": [{"model": name, "targets": targets} for name, targets in routes.items()],
    }
    return config, report


def main(argv=None):
    ap = argparse.ArgumentParser(description="Convert a LiteLLM config.yaml to an omnigate config.")
    ap.add_argument("litellm_config")
    ap.add_argument("-o", "--output", help="write the omnigate JSON here (default: stdout)")
    ap.add_argument("--generate-key", metavar="NAME",
                    help="add a gateway key with this name; the key itself is printed once to stderr")
    args = ap.parse_args(argv)

    with open(args.litellm_config, encoding="utf-8") as f:
        try:
            doc = load_yaml(f.read())
        except YamlError as e:
            raise SystemExit(f"cannot parse {args.litellm_config}: {e}")

    config, report = convert(doc)
    err = sys.stderr

    if args.generate_key:
        key = "og-" + secrets.token_urlsafe(32)
        config["keys"].append({"name": args.generate_key, "key_sha256": hashlib.sha256(key.encode()).hexdigest()})
        print(f"gateway key '{args.generate_key}' (shown once, only its hash is stored): {key}", file=err)

    text = json.dumps(config, indent=2) + "\n"
    if args.output:
        with open(args.output, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    else:
        sys.stdout.write(text)

    print(f"imported {len(config['routes'])} models over {len(config['upstreams'])} upstreams", file=err)
    for name, why in report["skipped"]:
        print(f"  skipped {name}: {why}", file=err)
    if report["env"]:
        print("set these environment variables for the data plane:", file=err)
        for name, why in report["env"].items():
            print(f"  {name}  ({why})", file=err)
    for note in report["notes"]:
        print(f"  note: {note}", file=err)
    if not config["keys"]:
        print("  note: no gateway keys yet; rerun with --generate-key NAME or add one to \"keys\".", file=err)
    if not config["routes"]:
        raise SystemExit("nothing could be imported")


if __name__ == "__main__":
    main()
