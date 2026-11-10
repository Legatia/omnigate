"""SDK compatibility test: the official OpenAI and Anthropic Python SDKs as clients.

    pip install openai anthropic      # into any environment; the repo does not depend on them
    python tools/sdk_compat.py
    python tools/sdk_compat.py --keep   # leave logs and state in the temp dir

Starts the same stack as `tools/e2e.py --only text` (mock providers, control
plane on 14000, gateway on 18080) and drives the gateway through the SDKs
instead of hand-written HTTP: both SDKs against both kinds of upstream, sync
and async, streaming and not, plus the error classes each SDK raises.
Needs what e2e.py needs (a built data plane, `mix`) and the two SDKs.
Exit code 0 only when every case passes.

The last section checks the details an SDK user would notice if the gateway
differed from the real APIs: request ids, error codes and envelopes, the model
endpoints, an upstream's 429, structured output through translation.
"""

import argparse
import asyncio
import json
import os
import shutil
import sys
import tempfile
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e  # noqa: E402  (the harness: Stack, text_config, keys, check)
from e2e import GATEWAY, KEY_LIMITED, KEY_MAIN, KEY_RPM, MOCK_TEXT, check, section  # noqa: E402

OPENAI_BASE = GATEWAY + "/v1"   # the OpenAI SDK appends /chat/completions, /models, ...
ANTHROPIC_BASE = GATEWAY        # the Anthropic SDK appends /v1/messages itself

MSG = [{"role": "user", "content": "hi"}]
MOCK_OUT = 6                    # tokens the mocks report for MOCK_TEXT
skipped = []                    # (case, reason)


def load_sdks():
    """Imported here, not at the top, so the repo itself gains no dependency."""
    try:
        import anthropic
        import openai
    except ImportError as exc:
        print(f"tools/sdk_compat.py needs the official SDKs ({exc.name} is not installed):\n"
              f"    pip install openai anthropic", file=sys.stderr)
        sys.exit(2)
    return openai, anthropic


def isolate_env():
    """The SDKs read these when an argument is not given; a developer's shell
    must not leak a second credential or another base URL into the test."""
    for name in list(os.environ):
        if name.startswith(("OPENAI_", "ANTHROPIC_")):
            del os.environ[name]


# --------------------------------------------------------------------------
# case helpers
# --------------------------------------------------------------------------

def describe(exc):
    text = f"{type(exc).__name__}: {exc}"
    response = getattr(exc, "response", None)
    if response is not None:
        try:
            text += f" | HTTP {response.status_code} body={response.text[:300]!r}"
        except Exception:  # a streamed body that was never read
            text += f" | HTTP {response.status_code}"
    elif exc.__traceback__ is not None:
        frame = traceback.extract_tb(exc.__traceback__)[-1]
        text += f" (raised at {os.path.basename(frame.filename)}:{frame.lineno} in {frame.name})"
    return text[:900]


label = ""


def group(short, title):
    """Start a section; `short` (client>upstream) prefixes its case names so each is unique."""
    global label
    label = short
    section(title)


def case(name, fn):
    """Run one case. `fn` returns nothing for a pass, or text saying what was wrong."""
    try:
        problem = fn()
    except Exception as exc:
        problem = describe(exc)
    return check(f"{label}: {name}", not problem, problem)


def skip(name, reason):
    skipped.append((f"{label}: {name}", reason))
    print(f"  SKIP  {label}: {name}   [{reason}]", flush=True)


def differ(**pairs):
    """`what=(got, want)` pairs -> text naming the ones that differ, or None."""
    bad = [f"{what}: got {got!r}, want {want!r}" for what, (got, want) in pairs.items() if got != want]
    return "; ".join(bad) or None


def raises(exc_type, status, fn, check_exc=None):
    """A case that passes when `fn` raises exactly this SDK error class with this HTTP status."""
    def run():
        try:
            fn()
        except exc_type as exc:
            if getattr(exc, "status_code", None) != status:
                return f"{exc_type.__name__} raised, but with status {getattr(exc, 'status_code', None)}, want {status}"
            return check_exc(exc) if check_exc else None
        except Exception as exc:
            return f"want {exc_type.__name__}, got {describe(exc)}"
        return f"want {exc_type.__name__}, but the call succeeded"
    return run


def read_openai_stream(stream):
    """-> (text, last finish_reason, usage or None, number of chunks without choices)."""
    text, finish, usage, bare = [], None, None, 0
    for chunk in stream:
        usage = chunk.usage or usage
        if not chunk.choices:
            bare += 1
            continue
        text.append(chunk.choices[0].delta.content or "")
        finish = chunk.choices[0].finish_reason or finish
    return "".join(text), finish, usage, bare


async def read_openai_stream_async(stream):
    text, finish, usage, bare = [], None, None, 0
    async for chunk in stream:
        usage = chunk.usage or usage
        if not chunk.choices:
            bare += 1
            continue
        text.append(chunk.choices[0].delta.content or "")
        finish = chunk.choices[0].finish_reason or finish
    return "".join(text), finish, usage, bare


WEATHER_PARAMS = {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}
OPENAI_TOOLS = [{"type": "function", "function": {"name": "get_weather", "description": "Current weather for a city.",
                                                  "parameters": WEATHER_PARAMS}}]
OPENAI_TOOL_HISTORY = [
    {"role": "user", "content": "weather in Paris?"},
    {"role": "assistant", "content": None, "tool_calls": [
        {"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"city\": \"Paris\"}"}}]},
    {"role": "tool", "tool_call_id": "call_1", "content": "21C"},
]
ANTHROPIC_TOOLS = [{"name": "get_weather", "description": "Current weather for a city.", "input_schema": WEATHER_PARAMS}]
# The mocks answer with a tool call when tools are offered and the user says "use the tool".
TOOL_ASK = [{"role": "user", "content": "What is the weather in Paris? Please use the tool."}]
PERSON_SCHEMA = {"type": "object", "properties": {"name": {"type": "string"}, "age": {"type": "integer"}},
                 "required": ["name", "age"], "additionalProperties": False}


def sdk_config():
    """The e2e text config plus routes to the mocks' special models (see tools/mock_upstream.py)."""
    config = e2e.text_config()
    price = {"price_in_per_mtok": 100.0, "price_out_per_mtok": 300.0}
    config["routes"] += [
        {"model": "busy", "targets": [dict(upstream="mock-ok", model="rate-limited-1", **price)]},
        {"model": "busy-claude", "targets": [dict(upstream="mock-anthropic", model="rate-limited-1", **price)]},
        {"model": "rid", "targets": [dict(upstream="mock-ok", model="rid-1", **price)]},
        {"model": "rid-claude", "targets": [dict(upstream="mock-anthropic", model="rid-1", **price)]},
        {"model": "down", "targets": [dict(upstream="mock-flaky", model="f", **price)]},
    ]
    return config


def openai_tool_round_trip(oa, route):
    """The model asks for a tool, the SDK parses the call, the result goes back, the answer is text."""
    def run():
        first = oa.chat.completions.create(model=route, messages=TOOL_ASK, tools=OPENAI_TOOLS)
        message = first.choices[0].message
        calls = message.tool_calls or []
        problem = differ(finish_reason=(first.choices[0].finish_reason, "tool_calls"), calls=(len(calls), 1),
                         name=(calls[0].function.name if calls else None, "get_weather"),
                         arguments=(json.loads(calls[0].function.arguments) if calls else None, {"city": "Paris"}),
                         call_type=(calls[0].type if calls else None, "function"),
                         has_id=(bool(calls and calls[0].id), True))
        if problem:
            return problem
        follow = TOOL_ASK + [
            {"role": "assistant", "content": None, "tool_calls": [
                {"id": calls[0].id, "type": "function",
                 "function": {"name": calls[0].function.name, "arguments": calls[0].function.arguments}}]},
            {"role": "tool", "tool_call_id": calls[0].id, "content": "21C and sunny"},
        ]
        second = oa.chat.completions.create(model=route, messages=follow, tools=OPENAI_TOOLS)
        return differ(text=(second.choices[0].message.content, MOCK_TEXT), finish_reason=(second.choices[0].finish_reason, "stop"),
                      tool_calls=(second.choices[0].message.tool_calls, None))
    return run


def openai_tool_stream(oa, route):
    def run():
        with oa.chat.completions.stream(model=route, messages=TOOL_ASK, tools=OPENAI_TOOLS) as s:
            for _ in s:
                pass
            final = s.get_final_completion()
        calls = final.choices[0].message.tool_calls or []
        return differ(finish_reason=(final.choices[0].finish_reason, "tool_calls"), calls=(len(calls), 1),
                      name=(calls[0].function.name if calls else None, "get_weather"),
                      arguments=(json.loads(calls[0].function.arguments) if calls else None, {"city": "Paris"}))
    return run


def anthropic_tool_round_trip(an, route):
    def run():
        first = an.messages.create(model=route, max_tokens=64, messages=TOOL_ASK, tools=ANTHROPIC_TOOLS)
        uses = [b for b in first.content if b.type == "tool_use"]
        problem = differ(stop_reason=(first.stop_reason, "tool_use"), tool_uses=(len(uses), 1),
                         name=(uses[0].name if uses else None, "get_weather"),
                         input=(uses[0].input if uses else None, {"city": "Paris"}), has_id=(bool(uses and uses[0].id), True))
        if problem:
            return problem
        follow = TOOL_ASK + [
            {"role": "assistant", "content": [{"type": "tool_use", "id": uses[0].id, "name": uses[0].name, "input": uses[0].input}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": uses[0].id, "content": "21C and sunny"}]},
        ]
        second = an.messages.create(model=route, max_tokens=64, messages=follow, tools=ANTHROPIC_TOOLS)
        return differ(text=(second.content[0].text if second.content else None, MOCK_TEXT), stop_reason=(second.stop_reason, "end_turn"))
    return run


def anthropic_tool_stream(an, route):
    def run():
        with an.messages.stream(model=route, max_tokens=64, messages=TOOL_ASK, tools=ANTHROPIC_TOOLS) as s:
            final = s.get_final_message()
        uses = [b for b in final.content if b.type == "tool_use"]
        return differ(stop_reason=(final.stop_reason, "tool_use"), tool_uses=(len(uses), 1),
                      name=(uses[0].name if uses else None, "get_weather"), input=(uses[0].input if uses else None, {"city": "Paris"}))
    return run
ANTHROPIC_TOOL_HISTORY = [
    {"role": "user", "content": "weather in Paris?"},
    {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_1", "name": "get_weather", "input": {"city": "Paris"}}]},
    {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_1", "content": "21C"}]},
]


# --------------------------------------------------------------------------
# OpenAI SDK
# --------------------------------------------------------------------------

def openai_cases(openai):
    # max_retries=0 everywhere: a retry must never turn a failure into a pass.
    oa = openai.OpenAI(base_url=OPENAI_BASE, api_key=KEY_MAIN, max_retries=0, timeout=30)

    group("failover", "failover, seen through the SDK")

    def failover():
        raw = oa.chat.completions.with_raw_response.create(model="chat", messages=MSG)
        return differ(text=(raw.parse().choices[0].message.content, MOCK_TEXT),
                      upstream=(raw.headers.get("x-omnigate-upstream"), "mock-ok"),
                      attempts=(raw.headers.get("x-omnigate-attempts"), "2"))
    case("OpenAI SDK on route chat: the first upstream answers 503, the call succeeds on the second", failover)

    def failover_stream():
        text, _, _, _ = read_openai_stream(oa.chat.completions.create(model="chat", messages=MSG, stream=True))
        return differ(text=(text, MOCK_TEXT))
    case("OpenAI SDK on route chat: a stream fails over the same way", failover_stream)

    group("openai>openai", "OpenAI SDK -> OpenAI-style upstream (route direct)")

    def chat():
        r = oa.chat.completions.create(model="direct", messages=MSG)
        return differ(object=(r.object, "chat.completion"), role=(r.choices[0].message.role, "assistant"),
                      text=(r.choices[0].message.content, MOCK_TEXT), finish_reason=(r.choices[0].finish_reason, "stop"),
                      prompt_tokens=(r.usage.prompt_tokens, 11), completion_tokens=(r.usage.completion_tokens, MOCK_OUT),
                      total_tokens=(r.usage.total_tokens, 11 + MOCK_OUT),
                      id_is_text=(isinstance(r.id, str) and bool(r.id), True), created_is_int=(isinstance(r.created, int), True))
    case("chat.completions.create returns a typed completion", chat)

    def chat_stream():
        text, finish, usage, bare = read_openai_stream(oa.chat.completions.create(model="direct", messages=MSG, stream=True))
        return differ(text=(text, MOCK_TEXT), finish_reason=(finish, "stop"), usage=(usage, None), chunks_without_choices=(bare, 0))
    case("chat.completions.create(stream=True) yields the text, a finish_reason and no usage chunk", chat_stream)

    def chat_stream_usage():
        chunks = list(oa.chat.completions.create(model="direct", messages=MSG, stream=True,
                                                 stream_options={"include_usage": True}))
        last = chunks[-1]
        text = "".join(c.choices[0].delta.content or "" for c in chunks if c.choices)
        return differ(text=(text, MOCK_TEXT), last_chunk_choices=(last.choices, []),
                      last_chunk_has_usage=(last.usage is not None, True),
                      total_tokens=(last.usage.total_tokens if last.usage else None, 11 + MOCK_OUT),
                      usage_on_earlier_chunks=([c.usage for c in chunks[:-1] if c.usage], []))
    case("stream_options.include_usage puts usage on the final chunk only", chat_stream_usage)

    def raw_headers():
        raw = oa.chat.completions.with_raw_response.create(model="direct", messages=MSG)
        request_id = raw.headers.get("x-omnigate-request-id", "")
        return differ(request_id_is_32_hex=(len(request_id) == 32 and all(c in "0123456789abcdef" for c in request_id), True),
                      upstream=(raw.headers.get("x-omnigate-upstream"), "mock-ok"),
                      text=(raw.parse().choices[0].message.content, MOCK_TEXT))
    case("with_raw_response exposes x-omnigate-request-id and still parses", raw_headers)

    def raw_streaming_headers():
        with oa.chat.completions.with_streaming_response.create(model="direct", messages=MSG) as response:
            request_id = response.headers.get("x-omnigate-request-id", "")
            completion = response.parse()
        return differ(request_id_length=(len(request_id), 32), text=(completion.choices[0].message.content, MOCK_TEXT))
    case("with_streaming_response exposes the same header", raw_streaming_headers)

    def stream_helper():
        with oa.chat.completions.stream(model="direct", messages=MSG) as s:
            kinds = {event.type for event in s}
            final = s.get_final_completion()
        return differ(has_content_events=({"content.delta", "content.done"} <= kinds, True),
                      text=(final.choices[0].message.content, MOCK_TEXT), finish_reason=(final.choices[0].finish_reason, "stop"))
    case("chat.completions.stream() helper accumulates a final completion", stream_helper)

    def early_close():
        stream = oa.chat.completions.create(model="direct", messages=MSG, stream=True)
        next(iter(stream))
        stream.close()
        return differ(text_after=(oa.chat.completions.create(model="direct", messages=MSG).choices[0].message.content, MOCK_TEXT))
    case("a stream closed after its first chunk leaves the client usable", early_close)

    def models():
        listed = list(oa.models.list())
        ids = {m.id for m in listed}
        return differ(routes_listed=({"chat", "direct", "claude"} <= ids, True),
                      objects=({m.object for m in listed}, {"model"}),
                      owned_by_is_text=(all(isinstance(m.owned_by, str) for m in listed), True))
    case("models.list() iterates the routes", models)

    def models_limited():
        limited = openai.OpenAI(base_url=OPENAI_BASE, api_key=KEY_LIMITED, max_retries=0, timeout=30)
        return differ(ids=([m.id for m in limited.models.list()], ["direct"]))
    case("models.list() with a model-limited key shows only its model", models_limited)

    def embeddings():
        r = oa.embeddings.create(model="direct", input="hello")
        vector = r.data[0].embedding
        return differ(object=(r.object, "list"), item_object=(r.data[0].object, "embedding"), index=(r.data[0].index, 0),
                      is_float_list=(isinstance(vector, list) and len(vector) > 0 and all(isinstance(x, float) for x in vector), True),
                      prompt_tokens_is_int=(isinstance(r.usage.prompt_tokens, int), True))
    case("embeddings.create (SDK default: base64 on the wire) returns float vectors", embeddings)

    def embeddings_float():
        r = oa.embeddings.create(model="direct", input=["hello", "world"], encoding_format="float")
        return differ(count=(len(r.data), 2), indexes=([d.index for d in r.data], [0, 1]),
                      is_float_list=(all(isinstance(x, float) for d in r.data for x in d.embedding) and len(r.data[0].embedding) > 0, True))
    case("embeddings.create(encoding_format='float') with two inputs returns two vectors", embeddings_float)

    def responses():
        r = oa.responses.create(model="direct", input="hi")
        return differ(object=(r.object, "response"), status=(r.status, "completed"), output_text=(r.output_text, MOCK_TEXT),
                      input_tokens=(r.usage.input_tokens, 11), output_tokens=(r.usage.output_tokens, MOCK_OUT))
    case("responses.create returns a typed response with output_text", responses)

    def responses_stream():
        events = list(oa.responses.create(model="direct", input="hi", stream=True))
        types = [e.type for e in events]
        text = "".join(e.delta for e in events if e.type == "response.output_text.delta")
        done = events[-1]
        return differ(first_event=(types[0], "response.created"), last_event=(types[-1], "response.completed"), text=(text, MOCK_TEXT),
                      final_output_text=(done.response.output_text if types[-1] == "response.completed" else None, MOCK_TEXT))
    case("responses.create(stream=True) yields typed events", responses_stream)

    group("openai errors", "OpenAI SDK: errors map to the SDK's exception classes")
    case("unknown model -> openai.NotFoundError",
         raises(openai.NotFoundError, 404, lambda: oa.chat.completions.create(model="no-such-model", messages=MSG),
                lambda exc: differ(message_mentions_model=("model" in str(exc).lower(), True))))
    bad = openai.OpenAI(base_url=OPENAI_BASE, api_key="og-not-a-key", max_retries=0, timeout=30)
    case("bad key -> openai.AuthenticationError",
         raises(openai.AuthenticationError, 401, lambda: bad.chat.completions.create(model="direct", messages=MSG)))
    case("bad key on models.list() -> openai.AuthenticationError",
         raises(openai.AuthenticationError, 401, lambda: list(bad.models.list())))

    rpm = openai.OpenAI(base_url=OPENAI_BASE, api_key=KEY_RPM, max_retries=0, timeout=30)

    def rate_limit():
        for n in range(3):
            try:
                rpm.chat.completions.create(model="direct", messages=MSG)
            except Exception as exc:
                return f"call {n + 1} of the 3 allowed failed: {describe(exc)}"
        return raises(openai.RateLimitError, 429, lambda: rpm.chat.completions.create(model="direct", messages=MSG),
                      lambda exc: differ(retry_after_is_seconds=(exc.response.headers.get("retry-after", "").isdigit(), True)))()
    case("3-per-minute key, max_retries=0 -> 3 calls, then openai.RateLimitError with Retry-After", rate_limit)

    limited = openai.OpenAI(base_url=OPENAI_BASE, api_key=KEY_LIMITED, max_retries=0, timeout=30)
    case("model-limited key on another model -> openai.PermissionDeniedError",
         raises(openai.PermissionDeniedError, 403, lambda: limited.chat.completions.create(model="chat", messages=MSG)))
    case("... and the stream form of the same call raises before yielding anything",
         raises(openai.PermissionDeniedError, 403,
                lambda: list(limited.chat.completions.create(model="chat", messages=MSG, stream=True))))

    group("openai>anthropic", "OpenAI SDK -> Anthropic-style upstream (route claude, translated)")

    def translated():
        raw = oa.chat.completions.with_raw_response.create(model="claude", messages=MSG, max_tokens=64)
        r = raw.parse()
        return differ(upstream=(raw.headers.get("x-omnigate-upstream"), "mock-anthropic"),
                      object=(r.object, "chat.completion"), model=(r.model, "claude"), role=(r.choices[0].message.role, "assistant"),
                      text=(r.choices[0].message.content, MOCK_TEXT), finish_reason=(r.choices[0].finish_reason, "stop"),
                      prompt_tokens=(r.usage.prompt_tokens, 13), completion_tokens=(r.usage.completion_tokens, MOCK_OUT),
                      total_tokens=(r.usage.total_tokens, 13 + MOCK_OUT),
                      id_is_text=(isinstance(r.id, str) and bool(r.id), True), created_is_int=(isinstance(r.created, int), True))
    case("chat.completions.create returns a typed completion", translated)

    def translated_stream():
        chunks = list(oa.chat.completions.create(model="claude", messages=MSG, stream=True))
        text = "".join(c.choices[0].delta.content or "" for c in chunks if c.choices)
        finishes = [c.choices[0].finish_reason for c in chunks if c.choices and c.choices[0].finish_reason]
        return differ(text=(text, MOCK_TEXT), finish_reasons=(finishes, ["stop"]),
                      objects=({c.object for c in chunks}, {"chat.completion.chunk"}), models=({c.model for c in chunks}, {"claude"}),
                      one_id=(len({c.id for c in chunks}), 1), usage_chunks=([c.usage for c in chunks if c.usage], []))
    case("chat.completions.create(stream=True) yields well-formed chunks", translated_stream)

    def translated_stream_usage():
        chunks = list(oa.chat.completions.create(model="claude", messages=MSG, stream=True,
                                                 stream_options={"include_usage": True}))
        last = chunks[-1]
        return differ(last_chunk_choices=(last.choices, []), last_chunk_has_usage=(last.usage is not None, True),
                      completion_tokens=(last.usage.completion_tokens if last.usage else None, MOCK_OUT),
                      prompt_tokens=(last.usage.prompt_tokens if last.usage else None, 13))
    case("stream_options.include_usage puts usage on the final chunk", translated_stream_usage)

    def translated_stream_helper():
        with oa.chat.completions.stream(model="claude", messages=MSG) as s:
            kinds = {event.type for event in s}
            final = s.get_final_completion()
        return differ(has_content_events=({"content.delta", "content.done"} <= kinds, True),
                      text=(final.choices[0].message.content, MOCK_TEXT), finish_reason=(final.choices[0].finish_reason, "stop"))
    case("chat.completions.stream() helper accumulates a final completion", translated_stream_helper)

    def tool_history():
        r = oa.chat.completions.create(model="claude", messages=OPENAI_TOOL_HISTORY, tools=OPENAI_TOOLS, tool_choice="auto")
        return differ(text=(r.choices[0].message.content, MOCK_TEXT), tool_calls=(r.choices[0].message.tool_calls, None))
    case("a conversation holding a tool call and its result is accepted (request side only)", tool_history)
    case("tool-call round trip: the SDK parses tool_calls, the result goes back, the answer is text", openai_tool_round_trip(oa, "claude"))
    case("streamed tool call: chat.completions.stream() assembles the arguments", openai_tool_stream(oa, "claude"))

    group("openai>openai tools", "OpenAI SDK -> OpenAI-style upstream: tool calls")
    case("tool-call round trip", openai_tool_round_trip(oa, "direct"))
    case("streamed tool call: chat.completions.stream() assembles the arguments", openai_tool_stream(oa, "direct"))
    return oa


# --------------------------------------------------------------------------
# Anthropic SDK
# --------------------------------------------------------------------------

def anthropic_message_problems(message, model, input_tokens):
    block = message.content[0] if message.content else None
    return differ(type=(message.type, "message"), role=(message.role, "assistant"), model=(message.model, model),
                  blocks=(len(message.content), 1), block_type=(getattr(block, "type", None), "text"),
                  text=(getattr(block, "text", None), MOCK_TEXT), stop_reason=(message.stop_reason, "end_turn"),
                  input_tokens=(message.usage.input_tokens, input_tokens), output_tokens=(message.usage.output_tokens, MOCK_OUT),
                  id_is_text=(isinstance(message.id, str) and bool(message.id), True))


def anthropic_route_cases(an, route, model_reported, input_tokens):
    def create():
        return anthropic_message_problems(an.messages.create(model=route, max_tokens=64, messages=MSG), model_reported, input_tokens)
    case("messages.create returns a typed message", create)

    def raw_events():
        types = [event.type for event in an.messages.create(model=route, max_tokens=64, messages=MSG, stream=True)]
        types = [t for t in types if t != "ping"]
        # How the text is cut into deltas is the upstream's business; the frame around it is not.
        return differ(opening=(types[:2], ["message_start", "content_block_start"]),
                      middle=(set(types[2:-3]), {"content_block_delta"}),
                      closing=(types[-3:], ["content_block_stop", "message_delta", "message_stop"]))
    case("messages.create(stream=True) yields the documented event sequence", raw_events)

    def stream():
        with an.messages.stream(model=route, max_tokens=64, messages=MSG) as s:
            text = "".join(s.text_stream)
            final = s.get_final_message()
        return differ(text_stream=(text, MOCK_TEXT)) or anthropic_message_problems(final, model_reported, input_tokens)
    case("messages.stream(): text_stream and get_final_message()", stream)

    def stream_events():
        with an.messages.stream(model=route, max_tokens=64, messages=MSG) as s:
            seen = [event.type for event in s]
            text = s.get_final_text()
        return differ(text=(text, MOCK_TEXT), has_text_events=("text" in seen, True), ends_with=(seen[-1], "message_stop"))
    case("messages.stream(): iterating events and get_final_text()", stream_events)


def anthropic_cases(anthropic):
    an = anthropic.Anthropic(base_url=ANTHROPIC_BASE, api_key=KEY_MAIN, max_retries=0, timeout=30)

    group("anthropic>anthropic", "Anthropic SDK -> Anthropic-style upstream (route claude)")
    anthropic_route_cases(an, "claude", "mock-claude", 13)

    case("tool-use round trip", anthropic_tool_round_trip(an, "claude"))
    case("streamed tool use: messages.stream() assembles the input", anthropic_tool_stream(an, "claude"))

    def count_tokens():
        r = an.messages.count_tokens(model="claude", messages=MSG)
        return differ(input_tokens_is_positive_int=(isinstance(r.input_tokens, int) and r.input_tokens > 0, True))
    case("messages.count_tokens returns input_tokens", count_tokens)

    def raw_headers():
        raw = an.messages.with_raw_response.create(model="claude", max_tokens=64, messages=MSG)
        return differ(request_id_length=(len(raw.headers.get("x-omnigate-request-id", "")), 32),
                      upstream=(raw.headers.get("x-omnigate-upstream"), "mock-anthropic"),
                      text=(raw.parse().content[0].text, MOCK_TEXT))
    case("with_raw_response exposes x-omnigate-request-id and still parses", raw_headers)

    def bearer():
        client = anthropic.Anthropic(base_url=ANTHROPIC_BASE, auth_token=KEY_MAIN, max_retries=0, timeout=30)
        return differ(text=(client.messages.create(model="claude", max_tokens=64, messages=MSG).content[0].text, MOCK_TEXT))
    case("a client built with auth_token (Authorization: Bearer) instead of api_key works", bearer)

    group("anthropic errors", "Anthropic SDK: errors map to the SDK's exception classes")
    case("unknown model -> anthropic.NotFoundError",
         raises(anthropic.NotFoundError, 404, lambda: an.messages.create(model="no-such-model", max_tokens=64, messages=MSG)))
    bad = anthropic.Anthropic(base_url=ANTHROPIC_BASE, api_key="og-not-a-key", max_retries=0, timeout=30)
    case("bad key -> anthropic.AuthenticationError",
         raises(anthropic.AuthenticationError, 401, lambda: bad.messages.create(model="claude", max_tokens=64, messages=MSG)))

    def stream_error():
        with an.messages.stream(model="no-such-model", max_tokens=64, messages=MSG) as s:
            return "".join(s.text_stream)
    case("unknown model in messages.stream() -> anthropic.NotFoundError before any event",
         raises(anthropic.NotFoundError, 404, stream_error))
    # The 3-per-minute key was used up by the OpenAI cases a moment ago.
    rpm = anthropic.Anthropic(base_url=ANTHROPIC_BASE, api_key=KEY_RPM, max_retries=0, timeout=30)
    case("rate-limited key -> anthropic.RateLimitError",
         raises(anthropic.RateLimitError, 429, lambda: rpm.messages.create(model="direct", max_tokens=64, messages=MSG)))
    limited = anthropic.Anthropic(base_url=ANTHROPIC_BASE, api_key=KEY_LIMITED, max_retries=0, timeout=30)
    case("model-limited key on another model -> anthropic.PermissionDeniedError",
         raises(anthropic.PermissionDeniedError, 403, lambda: limited.messages.create(model="claude", max_tokens=64, messages=MSG)))
    # extra_body, because newer SDK versions no longer have a `temperature` argument.
    case("the provider's own 400 (temperature refused) -> anthropic.BadRequestError with the provider's error type",
         raises(anthropic.BadRequestError, 400,
                lambda: an.messages.create(model="claude", max_tokens=64, messages=MSG, extra_body={"temperature": 0.2}),
                lambda exc: differ(error_type=(exc.type, "invalid_request_error"))))

    group("anthropic>openai", "Anthropic SDK -> OpenAI-style upstream (route direct, translated)")
    anthropic_route_cases(an, "direct", "direct", 11)

    def tool_history():
        r = an.messages.create(model="direct", max_tokens=64, messages=ANTHROPIC_TOOL_HISTORY, tools=ANTHROPIC_TOOLS)
        return differ(text=(r.content[0].text, MOCK_TEXT), stop_reason=(r.stop_reason, "end_turn"))
    case("a conversation holding a tool_use and its tool_result is accepted (request side only)", tool_history)
    case("tool-use round trip: the SDK parses the tool_use block, the result goes back, the answer is text",
         anthropic_tool_round_trip(an, "direct"))
    case("streamed tool use: messages.stream() assembles the input", anthropic_tool_stream(an, "direct"))

    def failover():
        raw = an.messages.with_raw_response.create(model="chat", max_tokens=64, messages=MSG)
        return differ(upstream=(raw.headers.get("x-omnigate-upstream"), "mock-ok"), text=(raw.parse().content[0].text, MOCK_TEXT))
    case("failover route chat also answers the Anthropic SDK", failover)


# --------------------------------------------------------------------------
# async clients
# --------------------------------------------------------------------------

def async_cases(openai, anthropic):
    group("async", "async clients")

    async def openai_stream(route, **extra):
        async with openai.AsyncOpenAI(base_url=OPENAI_BASE, api_key=KEY_MAIN, max_retries=0, timeout=30) as client:
            stream = await client.chat.completions.create(model=route, messages=MSG, stream=True, **extra)
            text, finish, _, _ = await read_openai_stream_async(stream)
        return differ(text=(text, MOCK_TEXT), finish_reason=(finish, "stop"))

    async def anthropic_stream(route, model_reported, input_tokens):
        async with anthropic.AsyncAnthropic(base_url=ANTHROPIC_BASE, api_key=KEY_MAIN, max_retries=0, timeout=30) as client:
            async with client.messages.stream(model=route, max_tokens=64, messages=MSG) as s:
                text = "".join([piece async for piece in s.text_stream])
                final = await s.get_final_message()
        return differ(text_stream=(text, MOCK_TEXT)) or anthropic_message_problems(final, model_reported, input_tokens)

    case("AsyncOpenAI streams from the OpenAI-style upstream", lambda: asyncio.run(openai_stream("direct")))
    case("AsyncOpenAI streams from the Anthropic-style upstream", lambda: asyncio.run(openai_stream("claude")))
    case("AsyncAnthropic messages.stream() from the Anthropic-style upstream",
         lambda: asyncio.run(anthropic_stream("claude", "mock-claude", 13)))
    case("AsyncAnthropic messages.stream() from the OpenAI-style upstream",
         lambda: asyncio.run(anthropic_stream("direct", "direct", 11)))

    async def gathered():
        async with openai.AsyncOpenAI(base_url=OPENAI_BASE, api_key=KEY_MAIN, max_retries=0, timeout=30) as client:
            answers = await asyncio.gather(*[client.chat.completions.create(model="direct", messages=MSG) for _ in range(8)])
        return differ(texts=({a.choices[0].message.content for a in answers}, {MOCK_TEXT}))
    case("AsyncOpenAI: 8 concurrent calls on one client all answer", lambda: asyncio.run(gathered()))


# --------------------------------------------------------------------------
# the details an SDK user would notice
# --------------------------------------------------------------------------

def fidelity_cases(openai, anthropic):
    """Places where a gateway typically gives itself away. Each case states what the real API does."""
    oa = openai.OpenAI(base_url=OPENAI_BASE, api_key=KEY_MAIN, max_retries=0, timeout=30)
    an = anthropic.Anthropic(base_url=ANTHROPIC_BASE, api_key=KEY_MAIN, max_retries=0, timeout=30)
    oa_limited = openai.OpenAI(base_url=OPENAI_BASE, api_key=KEY_LIMITED, max_retries=0, timeout=30)
    oa_bad = openai.OpenAI(base_url=OPENAI_BASE, api_key="og-not-a-key", max_retries=0, timeout=30)
    an_bad = anthropic.Anthropic(base_url=ANTHROPIC_BASE, api_key="og-not-a-key", max_retries=0, timeout=30)
    an_limited = anthropic.Anthropic(base_url=ANTHROPIC_BASE, api_key=KEY_LIMITED, max_retries=0, timeout=30)

    group("models", "model endpoints, in each SDK's own shape")
    case("OpenAI SDK: models.retrieve('direct') returns the model (GET /v1/models/{id})",
         lambda: differ(id=(oa.models.retrieve("direct").id, "direct"), object=(oa.models.retrieve("direct").object, "model")))
    case("OpenAI SDK: models.list() items carry the integer `created` the Model type declares",
         lambda: differ(created_is_int=({isinstance(m.created, int) and m.created > 0 for m in oa.models.list()}, {True})))
    case("OpenAI SDK: retrieving a model that does not exist -> openai.NotFoundError",
         raises(openai.NotFoundError, 404, lambda: oa.models.retrieve("no-such-model"), lambda exc: differ(code=(exc.code, "model_not_found"))))
    case("OpenAI SDK: a model-limited key cannot retrieve a model it may not use (same 404)",
         raises(openai.NotFoundError, 404, lambda: oa_limited.models.retrieve("chat")))

    def anthropic_models():
        listed = list(an.models.list())
        first = listed[0]
        return differ(type=(first.type, "model"), display_name_is_text=(isinstance(first.display_name, str) and bool(first.display_name), True),
                      created_at_is_a_date=(getattr(first.created_at, "year", 0) >= 2024, True),
                      lists_the_routes=({"claude", "direct"} <= {m.id for m in listed}, True))
    case("Anthropic SDK: models.list() items are Anthropic-shaped (type, display_name, created_at)", anthropic_models)
    case("Anthropic SDK: models.retrieve('claude') returns the model",
         lambda: differ(id=(an.models.retrieve("claude").id, "claude"), type=(an.models.retrieve("claude").type, "model")))
    case("Anthropic SDK: retrieving a model that does not exist -> anthropic.NotFoundError with Anthropic's error type",
         raises(anthropic.NotFoundError, 404, lambda: an.models.retrieve("no-such-model"),
                lambda exc: differ(error_type=(exc.type, "not_found_error"))))

    group("request ids", "request ids, where each SDK looks for them")

    def openai_request_id():
        raw = oa.chat.completions.with_raw_response.create(model="direct", messages=MSG)
        ours = raw.headers.get("x-omnigate-request-id", "")
        return differ(gateway_id_length=(len(ours), 32), sdk_request_id=(raw.parse()._request_id, ours))
    case("OpenAI SDK: completion._request_id is set (x-request-id), to the gateway's id when the provider sent none", openai_request_id)
    case("OpenAI SDK: ... and to the provider's own id when it sent one",
         lambda: differ(request_id=(oa.chat.completions.create(model="rid", messages=MSG)._request_id, "req_mock_openai_1")))

    def anthropic_request_id():
        raw = an.messages.with_raw_response.create(model="claude", max_tokens=64, messages=MSG)
        ours = raw.headers.get("x-omnigate-request-id", "")
        return differ(gateway_id_length=(len(ours), 32), sdk_request_id=(raw.parse()._request_id, ours))
    case("Anthropic SDK: message._request_id is set (request-id), to the gateway's id when the provider sent none", anthropic_request_id)
    case("Anthropic SDK: ... and to the provider's own id when it sent one",
         lambda: differ(request_id=(an.messages.create(model="rid-claude", max_tokens=64, messages=MSG)._request_id, "req_mock_anthropic_1")))
    case("OpenAI SDK: a streamed response carries the id too",
         lambda: differ(has_id=(bool(oa.chat.completions.with_raw_response.create(model="direct", messages=MSG, stream=True)
                                     .headers.get("x-request-id")), True)))

    def openai_error_id(exc):
        return differ(exc_request_id_length=(len(exc.request_id or ""), 32),
                      same_as_gateway_header=(exc.request_id, exc.response.headers.get("x-omnigate-request-id")))
    case("OpenAI SDK: an error the gateway raises before routing has a request id (exc.request_id)",
         raises(openai.NotFoundError, 404, lambda: oa.chat.completions.create(model="no-such-model", messages=MSG), openai_error_id))
    case("OpenAI SDK: ... also when the key is refused",
         raises(openai.AuthenticationError, 401, lambda: oa_bad.chat.completions.create(model="direct", messages=MSG), openai_error_id))

    def anthropic_error_id(exc):
        body = exc.body if isinstance(exc.body, dict) else {}
        return differ(exc_request_id_length=(len(exc.request_id or ""), 32), body_request_id=(body.get("request_id"), exc.request_id))
    case("Anthropic SDK: an error the gateway raises has a request id, in the header and in the body",
         raises(anthropic.NotFoundError, 404, lambda: an.messages.create(model="no-such-model", max_tokens=64, messages=MSG), anthropic_error_id))

    group("error shapes", "the gateway's own errors, in each protocol's shape")

    def openai_error(code, error_type):
        return lambda exc: differ(code=(exc.code, code), type=(exc.type, error_type), param=(exc.param, None),
                                  message_is_text=(isinstance(exc.message, str) and bool(exc.message), True))
    case("OpenAI SDK: unknown model -> code model_not_found, type invalid_request_error",
         raises(openai.NotFoundError, 404, lambda: oa.chat.completions.create(model="no-such-model", messages=MSG),
                openai_error("model_not_found", "invalid_request_error")))
    case("OpenAI SDK: bad key -> code invalid_api_key",
         raises(openai.AuthenticationError, 401, lambda: oa_bad.chat.completions.create(model="direct", messages=MSG),
                openai_error("invalid_api_key", "invalid_request_error")))
    case("OpenAI SDK: model-limited key -> code model_not_allowed, type permission_error",
         raises(openai.PermissionDeniedError, 403, lambda: oa_limited.chat.completions.create(model="chat", messages=MSG),
                openai_error("model_not_allowed", "permission_error")))
    rpm = openai.OpenAI(base_url=OPENAI_BASE, api_key=KEY_RPM, max_retries=0, timeout=30)
    # The 3-per-minute key was used up by the earlier sections.
    case("OpenAI SDK: rate-limited key -> code rate_limit_exceeded, type rate_limit_error",
         raises(openai.RateLimitError, 429, lambda: rpm.chat.completions.create(model="direct", messages=MSG),
                openai_error("rate_limit_exceeded", "rate_limit_error")))

    def anthropic_error(error_type, code):
        def look(exc):
            body = exc.body if isinstance(exc.body, dict) else {}
            return differ(envelope_type=(body.get("type"), "error"), error_type=(exc.type, error_type),
                          code=((body.get("error") or {}).get("code"), code))
        return look
    case("Anthropic SDK: unknown model -> Anthropic's envelope, type not_found_error",
         raises(anthropic.NotFoundError, 404, lambda: an.messages.create(model="no-such-model", max_tokens=64, messages=MSG),
                anthropic_error("not_found_error", "model_not_found")))
    case("Anthropic SDK: bad key -> type authentication_error",
         raises(anthropic.AuthenticationError, 401, lambda: an_bad.messages.create(model="claude", max_tokens=64, messages=MSG),
                anthropic_error("authentication_error", "invalid_api_key")))
    case("Anthropic SDK: model-limited key -> type permission_error",
         raises(anthropic.PermissionDeniedError, 403, lambda: an_limited.messages.create(model="claude", max_tokens=64, messages=MSG),
                anthropic_error("permission_error", "model_not_allowed")))
    an_rpm = anthropic.Anthropic(base_url=ANTHROPIC_BASE, api_key=KEY_RPM, max_retries=0, timeout=30)
    case("Anthropic SDK: rate-limited key -> type rate_limit_error",
         raises(anthropic.RateLimitError, 429, lambda: an_rpm.messages.create(model="direct", max_tokens=64, messages=MSG),
                anthropic_error("rate_limit_error", "rate_limit_exceeded")))
    case("Anthropic SDK: malformed request the gateway refuses (no model) -> anthropic.BadRequestError, type invalid_request_error",
         raises(anthropic.BadRequestError, 400,
                lambda: an.post("/v1/messages", body={"max_tokens": 5, "messages": MSG}, cast_to=dict),
                anthropic_error("invalid_request_error", "missing_model")))

    group("upstream 429", "a provider's 429 on the last target reaches the SDK as a rate limit, not a 502")

    def retry_after(exc):
        return differ(retry_after=(exc.response.headers.get("retry-after"), "7"))
    case("OpenAI SDK -> OpenAI-style upstream: openai.RateLimitError with the provider's Retry-After",
         raises(openai.RateLimitError, 429, lambda: oa.chat.completions.create(model="busy", messages=MSG),
                lambda exc: retry_after(exc) or differ(code=(exc.code, "upstream_rate_limited"), type=(exc.type, "rate_limit_error"))))
    case("OpenAI SDK -> Anthropic-style upstream (translated): the same",
         raises(openai.RateLimitError, 429, lambda: oa.chat.completions.create(model="busy-claude", messages=MSG), retry_after))
    case("OpenAI SDK, streaming: raised before any chunk",
         raises(openai.RateLimitError, 429, lambda: list(oa.chat.completions.create(model="busy", messages=MSG, stream=True)), retry_after))
    case("Anthropic SDK -> Anthropic-style upstream: anthropic.RateLimitError with the provider's Retry-After",
         raises(anthropic.RateLimitError, 429, lambda: an.messages.create(model="busy-claude", max_tokens=64, messages=MSG),
                lambda exc: retry_after(exc) or differ(error_type=(exc.type, "rate_limit_error"))))
    case("Anthropic SDK -> OpenAI-style upstream (translated): the same",
         raises(anthropic.RateLimitError, 429, lambda: an.messages.create(model="busy", max_tokens=64, messages=MSG), retry_after))
    case("OpenAI SDK: any other failure of the last target stays a 502 (openai.InternalServerError), with the attempts listed",
         raises(openai.InternalServerError, 502, lambda: oa.chat.completions.create(model="down", messages=MSG),
                lambda exc: differ(code=(exc.code, "all_upstreams_failed"), type=(exc.type, "server_error"),
                                   attempts=([a.get("outcome") for a in (exc.body or {}).get("attempts", [])], ["http_503"]))))
    case("Anthropic SDK: the same, as anthropic.InternalServerError with type api_error",
         raises(anthropic.InternalServerError, 502, lambda: an.messages.create(model="down", max_tokens=64, messages=MSG),
                lambda exc: differ(error_type=(exc.type, "api_error"))))

    group("unsupported", "an endpoint that cannot be served for a model is the caller's error (400), not an outage")
    case("OpenAI SDK: embeddings on a route served only by an Anthropic-style upstream -> openai.BadRequestError",
         raises(openai.BadRequestError, 400, lambda: oa.embeddings.create(model="claude", input="hello"),
                lambda exc: differ(code=(exc.code, "endpoint_not_supported"), type=(exc.type, "invalid_request_error"))))
    case("OpenAI SDK: responses.create on such a route -> openai.BadRequestError",
         raises(openai.BadRequestError, 400, lambda: oa.responses.create(model="claude", input="hi")))
    case("Anthropic SDK: count_tokens on a route served only by an OpenAI-style upstream -> anthropic.BadRequestError",
         raises(anthropic.BadRequestError, 400, lambda: an.messages.count_tokens(model="direct", messages=MSG),
                lambda exc: differ(error_type=(exc.type, "invalid_request_error"))))

    group("structured output", "structured output survives translation")

    def openai_json_schema():
        r = oa.chat.completions.create(model="claude", messages=MSG, response_format={
            "type": "json_schema", "json_schema": {"name": "person", "strict": True, "schema": PERSON_SCHEMA}})
        try:
            parsed = json.loads(r.choices[0].message.content)
        except ValueError:
            return f"the answer is not JSON: {r.choices[0].message.content!r} (the schema did not reach the upstream)"
        return differ(keys=(sorted(parsed), ["age", "name"]), age_is_int=(isinstance(parsed.get("age"), int), True))
    case("OpenAI SDK -> Anthropic-style upstream: response_format json_schema reaches the provider as output_config.format", openai_json_schema)

    def openai_parse_helper():
        import pydantic

        class Person(pydantic.BaseModel):
            name: str
            age: int
        parsed = oa.chat.completions.parse(model="claude", messages=MSG, response_format=Person).choices[0].message.parsed
        return differ(is_person=(isinstance(parsed, Person), True), name=(getattr(parsed, "name", None), "Paris"))
    case("OpenAI SDK -> Anthropic-style upstream: chat.completions.parse() with a pydantic model returns the parsed object", openai_parse_helper)

    def anthropic_output_config():
        r = an.messages.create(model="direct", max_tokens=64, messages=MSG,
                               extra_body={"output_config": {"format": {"type": "json_schema", "schema": PERSON_SCHEMA}}})
        try:
            parsed = json.loads(r.content[0].text)
        except ValueError:
            return f"the answer is not JSON: {r.content[0].text!r} (the schema did not reach the upstream)"
        return differ(keys=(sorted(parsed), ["age", "name"]))
    case("Anthropic SDK -> OpenAI-style upstream: output_config.format reaches the provider as response_format", anthropic_output_config)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="omnigate through the official OpenAI and Anthropic Python SDKs")
    ap.add_argument("--keep", action="store_true", help="keep the temp dir (logs, ledger)")
    args = ap.parse_args()
    openai, anthropic = load_sdks()
    isolate_env()

    work = tempfile.mkdtemp(prefix="omnigate-sdk-")
    stack = e2e.Stack(work, sdk_config(), False)
    print(f"openai {openai.__version__}, anthropic {anthropic.__version__}, python {sys.version.split()[0]}")
    print(f"state and logs: {work}")
    started = time.time()
    try:
        stack.start_mocks()
        stack.start_control()
        stack.start_gateway()
        if not e2e.wait_until(lambda: e2e.call("GET", GATEWAY + "/v1/models", key=KEY_MAIN)[0] == 200, 15):
            stack.fail("gateway never received its config from the control plane", "gateway")
        openai_cases(openai)
        anthropic_cases(anthropic)
        async_cases(openai, anthropic)
        fidelity_cases(openai, anthropic)
    finally:
        stack.stop_all()

    failed = [name for name, ok in e2e.results if not ok]
    print(f"\n{len(e2e.results) - len(failed)}/{len(e2e.results)} cases passed, {len(skipped)} skipped, in {time.time() - started:.0f}s")
    for name, reason in skipped:
        print(f"skipped: {name} ({reason})")
    if failed:
        print("failed:")
        for name in failed:
            print(f"  - {name}")
        print(f"logs kept in {work}")
        sys.exit(1)
    if args.keep:
        print(f"kept {work}")
    else:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
