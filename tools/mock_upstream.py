"""Mock LLM providers for local end-to-end tests. No network, no API keys.

  :9001  OpenAI-shaped, always answers 503   (forces failover)
  :9002  OpenAI-shaped, works (JSON and SSE)
  :9003  Anthropic-shaped, works (JSON and SSE)
  :9004  OpenAI-shaped, works but waits 3 s before answering (forces a timeout)
  :9005  OpenAI-shaped, starts a stream, sends one chunk, then goes silent
         (forces the gateway's stream idle timeout)

Special model names, on the working mocks (9002 and 9003):

  rate-limited-1   always 429 with `retry-after: 7`
  rid-1            answers carry the provider's own request id header
                   (`x-request-id` on 9002, `request-id` on 9003)
  sig-1            (9002) earlier tool calls must carry a thought signature

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
import os
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WORDS = ["Hello", " from", " the", " mock", " upstream", "."]


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
        if (req.get("stream_options") or {}).get("include_usage"):
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


class Stall(Base):
    def do_POST(self):
        self.read_json()
        self.start_sse()
        self.sse('data: {"id": "chatcmpl-mock", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": "Hel"}}]}\n\n')
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
    # MOCK_PORT_OFFSET shifts every port, so two copies can run side by side.
    offset = int(os.environ.get("MOCK_PORT_OFFSET", "0"))
    for port, handler in [(9001 + offset, Flaky), (9002 + offset, OpenAIOk), (9003 + offset, AnthropicOk), (9004 + offset, Slow), (9005 + offset, Stall)]:
        threading.Thread(target=serve, args=(port, handler), daemon=True).start()
    print("mock upstreams on :%d (503), :%d (openai), :%d (anthropic), :%d (slow openai), :%d (stalling openai)"
          % tuple(9001 + offset + i for i in range(5)), flush=True)
    threading.Event().wait()
