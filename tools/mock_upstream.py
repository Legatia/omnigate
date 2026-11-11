"""Mock LLM providers for local end-to-end tests. No network, no API keys.

  :9001  OpenAI-shaped, always answers 503   (forces failover)
  :9002  OpenAI-shaped, works (JSON and SSE)
  :9003  Anthropic-shaped, works (JSON and SSE)
  :9004  OpenAI-shaped, works but waits 3 s before answering (forces a timeout)
  :9005  OpenAI-shaped, starts a stream, sends one chunk, then goes silent
         (forces the gateway's stream idle timeout); with the model names
         below it is a provider that goes on without its client, or a
         hostile one

Special model names, on the working mocks (9002 and 9003):

  rate-limited-1   always 429 with `retry-after: 7`
  rid-1            answers carry the provider's own request id header
                   (`x-request-id` on 9002, `request-id` on 9003)
  sig-1            (9002) earlier tool calls must carry a thought signature
  no-usage-1       (9002) streams, and ends properly, without ever reporting
                   usage, whatever `stream_options` asks for (as several
                   OpenAI-compatible servers do)

Error bodies that are not the protocol's error envelope, as real providers
send them (the gateway puts them into the envelope), and one that is:

  err-array-1      (9002) 400 with a JSON array around the error, as Google's
                   OpenAI-compatible endpoint answers a bad key
  err-string-1     (9002) 400 with `error` as a string, as xAI answers one
  err-exact-1      (9002) 400 with a well-formed OpenAI error in a spelling of
                   its own (ERR_EXACT): must arrive byte for byte
  err-openai-1     (9003) 404 with an OpenAI-shaped error on the Anthropic API
  err-text-1       (9003) 400 with a plain-text body

Special model names on the stalling mock (9005), by prefix:

  stall-body       not a stream: the head of a JSON answer (200, with a
                   content-length), then nothing
  drip             streams on for a minute and never reports usage
  late-usage       streams for about 2.5 s whoever is listening, then reports
                   usage (prompt 21, completion 34) and ends properly
  flood            sends about 16 MiB of stream as fast as it is taken, then
                   usage (prompt 55, completion 4242) and a proper end
  hostile-chunk-json   a chunked JSON answer whose chunk size is sixteen F's
  hostile-chunk-sse    the same in an event stream, after one good event
  hostile-chunk17      a chunk size of seventeen F's
  hostile-short-json   content-length 500, 20 bytes of body, then a clean close
  hostile-short-sse    an event stream with content-length 5000, two events,
                       then a clean close
  hostile-both         both content-length and transfer-encoding: chunked
  hostile-ctype        a content-type with a bare line feed that smuggles a
                       header (`x-injected: 1`)
  hostile-status       an interim status (103) presented as the final answer
  hostile-long         nothing hostile: a 200 kB JSON answer with a correct
                       content-length (the gateway re-frames it)

A request that offers tools and whose last user message contains the words
"use the tool" is answered with a call to the first tool (JSON or stream);
once the conversation ends with the tool's result, the answer is text again.
A non-streaming request that asks for structured output with a JSON schema
(`response_format` on 9002, `output_config.format` on 9003) is answered with a
JSON object that fits the schema instead of the usual sentence.

Run:  python tools/mock_upstream.py
"""

import base64
import json
import select
import sys
import os
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WORDS = ["Hello", " from", " the", " mock", " upstream", "."]

# What two providers really answer a bad key with on their OpenAI-compatible
# endpoints (texts shortened), and a well-formed error in an unusual spelling.
ERR_ARRAY = [{"error": {"code": 400, "message": "API key not valid. Please pass a valid API key.", "status": "INVALID_ARGUMENT",
                        "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "API_KEY_INVALID"}]}}]
ERR_STRING = {"code": "Client specified an invalid argument",
              "error": "Incorrect API key provided: xa***zz. You can obtain an API key from https://console.x.ai."}
ERR_EXACT = b'{ "error" : {"code":"context_length_exceeded","param":"messages", "type":"invalid_request_error",\n  "message":"This model\'s maximum context length is 8 tokens."} }\n'


class Base(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"[{self.server.server_port}] {fmt % args}", flush=True)

    def read_json(self):
        length = int(self.headers.get("content-length", 0))
        return json.loads(self.rfile.read(length) or b"{}")

    def send_json(self, status, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def send_bytes(self, status, data, content_type="application/json"):
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def start_sse(self, headers=None):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("transfer-encoding", "chunked")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()

    def sse(self, text):
        data = text.encode()
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
        self.wfile.flush()
        time.sleep(0.05)

    def end_sse(self):
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


TOOL_TRIGGER = "use the tool"


def last_user_text(messages):
    """Text of the final message if it is a plain user turn, else "" (e.g. after a tool result)."""
    if not messages or messages[-1].get("role") != "user":
        return ""
    content = messages[-1].get("content")
    if isinstance(content, str):
        return content
    parts = content if isinstance(content, list) else []
    if any(isinstance(part, dict) and part.get("type") == "tool_result" for part in parts):
        return ""
    return " ".join(part.get("text", "") for part in parts if isinstance(part, dict) and part.get("type") == "text")


def example_arguments(schema):
    """Arguments that satisfy a tool's JSON schema: one made-up value per required property."""
    schema = schema if isinstance(schema, dict) else {}
    properties = schema.get("properties") or {}
    names = schema.get("required") or list(properties)
    samples = {"string": "Paris", "integer": 1, "number": 1.5, "boolean": True, "array": [], "object": {}}
    return {name: samples.get((properties.get(name) or {}).get("type"), "Paris") for name in names}


def pieces(text, size=7):
    return [text[i:i + size] for i in range(0, len(text), size)] or [""]


class Flaky(Base):
    def do_POST(self):
        self.read_json()
        self.send_json(503, {"error": {"message": "mock overloaded", "type": "overloaded"}})


OPENAI_ENDPOINTS = ("/chat/completions", "/completions", "/embeddings", "/responses")


class OpenAIOk(Base):
    def do_POST(self):
        req = self.read_json()
        # Served under /v1 and, like Gemini's compatibility layer, under
        # /v1beta/openai. Anything else is a 404, as at a real provider.
        path = self.path.split("?")[0]
        if not any(path == prefix + ep for prefix in ("/v1", "/v1beta/openai") for ep in OPENAI_ENDPOINTS):
            return self.send_json(404, {"error": {"message": f"unknown path {path}", "type": "not_found"}})
        auth = self.headers.get("authorization", "")
        if not auth.startswith("Bearer "):
            return self.send_json(401, {"error": {"message": "missing bearer token"}})
        # The model "sig-1" behaves like Gemini 3: earlier tool calls must carry
        # a thought signature.
        if req.get("model") == "sig-1":
            for message in req.get("messages", []):
                for tool_call in message.get("tool_calls") or []:
                    if not tool_call.get("extra_content", {}).get("google", {}).get("thought_signature"):
                        return self.send_json(400, {"error": {"message": "Function call is missing a thought_signature in functionCall parts.",
                                                              "type": "invalid_request_error"}})
        if req.get("model") == "err-array-1":
            return self.send_json(400, ERR_ARRAY)
        if req.get("model") == "err-string-1":
            return self.send_json(400, ERR_STRING)
        if req.get("model") == "err-exact-1":
            return self.send_bytes(400, ERR_EXACT)
        if req.get("model") == "rate-limited-1":
            return self.send_json(429, {"error": {"message": "Rate limit reached for mock requests.", "type": "requests",
                                                  "param": None, "code": "rate_limit_exceeded"}}, {"retry-after": "7"})
        extra = {"x-request-id": "req_mock_openai_1"} if req.get("model") == "rid-1" else None
        if path.endswith("/embeddings"):
            return self.embeddings_api(req)
        if path.endswith("/responses"):
            return self.responses_api(req)
        usage = {"prompt_tokens": 11, "completion_tokens": len(WORDS), "total_tokens": 11 + len(WORDS)}
        created = int(time.time())
        head = {"id": "chatcmpl-mock", "object": "chat.completion.chunk", "created": created, "model": req.get("model")}
        tools = [t.get("function") or {} for t in req.get("tools") or [] if isinstance(t, dict)]
        if tools and TOOL_TRIGGER in last_user_text(req.get("messages")):
            name, arguments = tools[0].get("name"), json.dumps(example_arguments(tools[0].get("parameters")))
            if not req.get("stream"):
                return self.send_json(200, {
                    "id": "chatcmpl-mock", "object": "chat.completion", "created": created, "model": req.get("model"),
                    "choices": [{"index": 0, "finish_reason": "tool_calls", "message": {
                        "role": "assistant", "content": None,
                        "tool_calls": [{"id": "call_mock_1", "type": "function", "function": {"name": name, "arguments": arguments}}]}}],
                    "usage": usage,
                }, extra)
            # As at the provider: the call's id and name first, then its arguments in fragments.
            deltas = [({"role": "assistant", "content": None, "tool_calls": [
                {"index": 0, "id": "call_mock_1", "type": "function", "function": {"name": name, "arguments": ""}}]}, None)]
            deltas += [({"tool_calls": [{"index": 0, "function": {"arguments": piece}}]}, None) for piece in pieces(arguments)]
            deltas += [({}, "tool_calls")]
            self.start_sse(extra)
            for delta, finish in deltas:
                self.sse(f"data: {json.dumps(dict(head, choices=[{'index': 0, 'delta': delta, 'finish_reason': finish}]))}\n\n")
            if (req.get("stream_options") or {}).get("include_usage"):
                self.sse(f"data: {json.dumps(dict(head, choices=[], usage=usage))}\n\n")
            self.sse("data: [DONE]\n\n")
            return self.end_sse()
        if not req.get("stream"):
            text = "".join(WORDS)
            response_format = req.get("response_format") or {}
            if response_format.get("type") == "json_schema":
                text = json.dumps(example_arguments((response_format.get("json_schema") or {}).get("schema")))
            return self.send_json(200, {
                "id": "chatcmpl-mock", "object": "chat.completion", "created": created, "model": req.get("model"),
                "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                             "finish_reason": "stop"}],
                "usage": usage,
            }, extra)
        # As at the provider: the role first, one chunk per token, then a chunk
        # that carries only the finish_reason, then (if asked for) usage alone.
        deltas = [({"role": "assistant", "content": ""}, None)] + [({"content": w}, None) for w in WORDS] + [({}, "stop")]
        self.start_sse(extra)
        for delta, finish in deltas:
            chunk = dict(head, choices=[{"index": 0, "delta": delta, "finish_reason": finish}])
            self.sse(f"data: {json.dumps(chunk)}\n\n")
        if (req.get("stream_options") or {}).get("include_usage") and req.get("model") != "no-usage-1":
            self.sse(f"data: {json.dumps(dict(head, choices=[], usage=usage))}\n\n")
        self.sse("data: [DONE]\n\n")
        self.end_sse()

    def embeddings_api(self, req):
        """POST /embeddings: one small made-up vector per input, as floats or base64 float32."""
        inputs = req.get("input")
        if isinstance(inputs, str) or (isinstance(inputs, list) and inputs and isinstance(inputs[0], int)):
            inputs = [inputs]
        if not isinstance(inputs, list) or not inputs:
            return self.send_json(400, {"error": {"message": "`input` must be a string or a non-empty array.",
                                                  "type": "invalid_request_error", "param": "input", "code": None}})
        dims = int(req.get("dimensions") or 8)
        data = []
        for i in range(len(inputs)):
            vector = [((i + 1) * (j + 3) % 17) / 16 - 0.5 for j in range(dims)]  # exact in float32
            if req.get("encoding_format") == "base64":
                vector = base64.b64encode(struct.pack(f"<{dims}f", *vector)).decode()
            data.append({"object": "embedding", "index": i, "embedding": vector})
        tokens = 3 * len(inputs)
        self.send_json(200, {"object": "list", "data": data, "model": req.get("model"),
                             "usage": {"prompt_tokens": tokens, "total_tokens": tokens}})

    def responses_api(self, req):
        """POST /responses: the Responses API shape, as JSON or as its typed event stream."""
        text = "".join(WORDS)
        usage = {"input_tokens": 11, "input_tokens_details": {"cached_tokens": 0},
                 "output_tokens": len(WORDS), "output_tokens_details": {"reasoning_tokens": 0},
                 "total_tokens": 11 + len(WORDS)}
        part = {"type": "output_text", "text": text, "annotations": []}
        item = {"id": "msg_mock", "type": "message", "status": "completed", "role": "assistant", "content": [part]}
        base = {"id": "resp_mock", "object": "response", "created_at": int(time.time()), "model": req.get("model"),
                "error": None, "incomplete_details": None, "instructions": req.get("instructions"), "metadata": {},
                "parallel_tool_calls": True, "tool_choice": "auto", "tools": []}
        done = dict(base, status="completed", output=[item], usage=usage)
        if not req.get("stream"):
            return self.send_json(200, done)
        started = dict(base, status="in_progress", output=[], usage=None)
        where = {"item_id": "msg_mock", "output_index": 0, "content_index": 0}
        events = [
            {"type": "response.created", "response": started},
            {"type": "response.in_progress", "response": started},
            {"type": "response.output_item.added", "output_index": 0, "item": dict(item, status="in_progress", content=[])},
            dict(where, type="response.content_part.added", part=dict(part, text="")),
        ] + [dict(where, type="response.output_text.delta", delta=w) for w in WORDS] + [
            dict(where, type="response.output_text.done", text=text),
            dict(where, type="response.content_part.done", part=part),
            {"type": "response.output_item.done", "output_index": 0, "item": item},
            {"type": "response.completed", "response": done},
        ]
        self.start_sse()
        for number, event in enumerate(events):
            self.sse(f"event: {event['type']}\ndata: {json.dumps(dict(event, sequence_number=number))}\n\n")
        self.end_sse()


class AnthropicOk(Base):
    def do_POST(self):
        req = self.read_json()
        if not self.headers.get("x-api-key") or not self.headers.get("anthropic-version"):
            return self.send_json(401, {"type": "error", "error": {"type": "authentication_error",
                                                                  "message": "missing x-api-key or anthropic-version"}})
        if req.get("model") == "err-openai-1":
            return self.send_json(404, {"error": {"message": "no such model here", "type": "invalid_request_error", "code": "model_not_found"}})
        if req.get("model") == "err-text-1":
            return self.send_bytes(400, b"Bad Request: the proxy in front of the provider did not like this\n", "text/plain")
        if "temperature" in req or "top_p" in req:
            # Current Claude models refuse sampling parameters.
            return self.send_json(400, {"type": "error", "error": {"type": "invalid_request_error",
                                                                  "message": "`temperature` is deprecated for this model."}})
        if self.path.split("?")[0].endswith("/messages/count_tokens"):
            return self.send_json(200, {"input_tokens": 13})
        if req.get("model") == "rate-limited-1":
            return self.send_json(429, {"type": "error", "error": {"type": "rate_limit_error",
                                                                  "message": "This request would exceed the mock rate limit."}},
                                  {"retry-after": "7"})
        extra = {"request-id": "req_mock_anthropic_1"} if req.get("model") == "rid-1" else None
        tools = [t for t in req.get("tools") or [] if isinstance(t, dict)]
        if tools and TOOL_TRIGGER in last_user_text(req.get("messages")):
            return self.tool_use(req, tools[0], extra)
        if not req.get("stream"):
            text = "".join(WORDS)
            output_format = (req.get("output_config") or {}).get("format") or {}
            if output_format.get("type") == "json_schema":
                text = json.dumps(example_arguments(output_format.get("schema")))
            return self.send_json(200, {
                "id": "msg_mock", "type": "message", "role": "assistant", "model": req.get("model"),
                "content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "stop_sequence": None,
                "usage": {"input_tokens": 13, "output_tokens": len(WORDS)},
            }, extra)
        # The documented event flow: the empty message, the content block
        # opened, a ping, its text deltas, the block closed, then the stop
        # reason with the final output count.
        events = [
            {"type": "message_start", "message": {
                "id": "msg_mock", "type": "message", "role": "assistant", "model": req.get("model"), "content": [],
                "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 13, "output_tokens": 1}}},
            {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
            {"type": "ping"},
        ] + [
            {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": w}} for w in WORDS
        ] + [
            {"type": "content_block_stop", "index": 0},
            {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
             "usage": {"output_tokens": len(WORDS)}},
            {"type": "message_stop"},
        ]
        self.start_sse(extra)
        for event in events:
            self.sse(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n")
        self.end_sse()

    def tool_use(self, req, tool, extra):
        """Answer with one tool_use block for `tool`, as JSON or as the documented event flow."""
        name, arguments = tool.get("name"), example_arguments(tool.get("input_schema"))
        usage = {"input_tokens": 13, "output_tokens": len(WORDS)}
        if not req.get("stream"):
            return self.send_json(200, {
                "id": "msg_mock", "type": "message", "role": "assistant", "model": req.get("model"),
                "content": [{"type": "tool_use", "id": "toolu_mock_1", "name": name, "input": arguments}],
                "stop_reason": "tool_use", "stop_sequence": None, "usage": usage,
            }, extra)
        events = [
            {"type": "message_start", "message": {
                "id": "msg_mock", "type": "message", "role": "assistant", "model": req.get("model"), "content": [],
                "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 13, "output_tokens": 1}}},
            {"type": "content_block_start", "index": 0,
             "content_block": {"type": "tool_use", "id": "toolu_mock_1", "name": name, "input": {}}},
        ] + [
            {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": piece}}
            for piece in pieces(json.dumps(arguments))
        ] + [
            {"type": "content_block_stop", "index": 0},
            {"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": None},
             "usage": {"output_tokens": len(WORDS)}},
            {"type": "message_stop"},
        ]
        self.start_sse(extra)
        for event in events:
            self.sse(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n")
        self.end_sse()


class Slow(OpenAIOk):
    def do_POST(self):
        time.sleep(3)
        super().do_POST()


CHUNK = 'data: {"id": "chatcmpl-mock", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": "%s"}}]}\n\n'


class Stall(Base):
    def raw(self, data, close=True):
        """Bytes straight onto the socket: for answers no HTTP library would write."""
        self.wfile.write(data)
        self.wfile.flush()
        if close:
            self.close_connection = True

    def hostile(self, model):
        ok_json = json.dumps({"id": "chatcmpl-mock", "object": "chat.completion", "model": model,
                              "choices": [{"index": 0, "message": {"role": "assistant", "content": "x"}, "finish_reason": "stop"}],
                              "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode()
        event = (CHUNK % "Hel").encode()
        chunked_event = b"%x\r\n%s\r\n" % (len(event), event)
        if model.startswith("hostile-chunk-json"):
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\n\r\n"
                            b"FFFFFFFFFFFFFFFF\r\n" + ok_json + b"\r\n0\r\n\r\n")
        if model.startswith("hostile-chunk-sse"):
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n" +
                            chunked_event + b"FFFFFFFFFFFFFFFF\r\n" + event + b"\r\n0\r\n\r\n")
        if model.startswith("hostile-chunk17"):
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\n\r\n"
                            b"FFFFFFFFFFFFFFFFF\r\n" + ok_json + b"\r\n0\r\n\r\n")
        if model.startswith("hostile-short-json"):
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 500\r\n\r\n" + ok_json[:20])
        if model.startswith("hostile-short-sse"):
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: 5000\r\n\r\n" + event + event)
        if model.startswith("hostile-both"):
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: %d\r\ntransfer-encoding: chunked\r\n\r\n" % len(ok_json) +
                            b"%x\r\n%s\r\n0\r\n\r\n" % (len(ok_json), ok_json))
        if model.startswith("hostile-ctype"):
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\nx-injected: 1\r\ncontent-length: %d\r\n\r\n" % len(ok_json) + ok_json)
        if model.startswith("hostile-status"):
            return self.raw(b"HTTP/1.1 103 Early Hints\r\ncontent-type: application/json\r\ncontent-length: %d\r\n\r\n" % len(ok_json) + ok_json)
        if model.startswith("hostile-long"):
            long_json = json.dumps({"id": "chatcmpl-mock", "object": "chat.completion", "model": model,
                                    "choices": [{"index": 0, "message": {"role": "assistant", "content": "y" * 200_000}, "finish_reason": "stop"}],
                                    "usage": {"prompt_tokens": 7, "completion_tokens": 9, "total_tokens": 16}}).encode()
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: %d\r\n\r\n" % len(long_json) + long_json, close=False)
        return self.send_json(400, {"error": {"message": f"unknown hostile mode {model}"}})

    def do_POST(self):
        body = self.read_json()
        model = str(body.get("model", "")) if isinstance(body, dict) else ""
        if model.startswith("hostile-"):
            return self.hostile(model)
        if model.startswith("stall-body"):
            # The head of an ordinary JSON answer, and then nothing: for a
            # minute, or until the gateway gives up and closes.
            self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 2000\r\n\r\n", close=False)
            deadline = time.time() + 60
            while time.time() < deadline and not select.select([self.connection], [], [], 0.5)[0]:
                pass
            self.close_connection = True
            return
        if model.startswith("late-usage") or model.startswith("flood"):
            # A provider that finishes its answer whether or not anyone is
            # still reading, and reports usage at the very end.
            flood = model.startswith("flood")
            usage = {"prompt_tokens": 55, "completion_tokens": 4242} if flood else {"prompt_tokens": 21, "completion_tokens": 34}
            usage["total_tokens"] = usage["prompt_tokens"] + usage["completion_tokens"]
            self.start_sse()
            try:
                if flood:
                    event = (CHUNK % ("w" * 900)).encode()
                    framed = b"%x\r\n%s\r\n" % (len(event), event)
                    for _ in range(16 * 1024):
                        self.wfile.write(framed)
                    self.wfile.flush()
                else:
                    for _ in range(12):
                        self.sse(CHUNK % "lo ")
                        time.sleep(0.15)
                self.sse('data: %s\n\n' % json.dumps({"id": "chatcmpl-mock", "object": "chat.completion.chunk", "choices": [], "usage": usage}))
                self.sse("data: [DONE]\n\n")
                self.end_sse()
            except OSError:
                self.close_connection = True
            return
        self.start_sse()
        self.sse('data: {"id": "chatcmpl-mock", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": "Hel"}}]}\n\n')
        if isinstance(body, dict) and str(body.get("model", "")).startswith("drip"):
            # Keep talking, never report usage: what a provider does when the
            # gateway's client has left and nobody asked it to stop.
            deadline = time.time() + 60
            try:
                while time.time() < deadline:
                    time.sleep(0.2)
                    self.sse('data: {"id": "chatcmpl-mock", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": "lo "}}]}\n\n')
            except OSError:
                pass
            self.close_connection = True
            return
        # Say nothing more; give up after a minute or when the peer goes away.
        deadline = time.time() + 60
        try:
            while time.time() < deadline:
                time.sleep(0.5)
                self.wfile.write(b"")
        except OSError:
            pass
        self.close_connection = True


class Server(ThreadingHTTPServer):
    # The default backlog of 5 makes the mock, not the gateway, the bottleneck
    # as soon as a few dozen connections open at once.
    request_queue_size = 512
    daemon_threads = True


def serve(port, handler):
    # MOCK_BIND=0.0.0.0 lets other containers reach the mocks (container test).
    Server((os.environ.get("MOCK_BIND", "127.0.0.1"), port), handler).serve_forever()


if __name__ == "__main__":
    if "--help" in sys.argv or "-h" in sys.argv:
        print(__doc__)
        raise SystemExit(0)
    # MOCK_PORT_OFFSET shifts every port, so two copies can run side by side.
    offset = int(os.environ.get("MOCK_PORT_OFFSET", "0"))
    for port, handler in [(9001 + offset, Flaky), (9002 + offset, OpenAIOk), (9003 + offset, AnthropicOk), (9004 + offset, Slow), (9005 + offset, Stall)]:
        threading.Thread(target=serve, args=(port, handler), daemon=True).start()
    print("mock upstreams on :%d (503), :%d (openai), :%d (anthropic), :%d (slow openai), :%d (stalling openai)"
          % tuple(9001 + offset + i for i in range(5)), flush=True)
    threading.Event().wait()
