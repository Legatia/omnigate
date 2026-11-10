"""Mock LLM providers for local end-to-end tests. No network, no API keys.

  :9001  OpenAI-shaped, always answers 503   (forces failover)
  :9002  OpenAI-shaped, works (JSON and SSE)
  :9003  Anthropic-shaped, works (JSON and SSE)
  :9004  OpenAI-shaped, works but waits 3 s before answering (forces a timeout)
  :9005  OpenAI-shaped, starts a stream, sends one chunk, then goes silent
         (forces the gateway's stream idle timeout)

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

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def start_sse(self):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()

    def sse(self, text):
        data = text.encode()
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
        self.wfile.flush()
        time.sleep(0.05)

    def end_sse(self):
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


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
        if path.endswith("/embeddings"):
            return self.embeddings_api(req)
        if path.endswith("/responses"):
            return self.responses_api(req)
        usage = {"prompt_tokens": 11, "completion_tokens": len(WORDS), "total_tokens": 11 + len(WORDS)}
        created = int(time.time())
        if not req.get("stream"):
            return self.send_json(200, {
                "id": "chatcmpl-mock", "object": "chat.completion", "created": created, "model": req.get("model"),
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "".join(WORDS)},
                             "finish_reason": "stop"}],
                "usage": usage,
            })
        # As at the provider: the role first, one chunk per token, then a chunk
        # that carries only the finish_reason, then (if asked for) usage alone.
        head = {"id": "chatcmpl-mock", "object": "chat.completion.chunk", "created": created, "model": req.get("model")}
        deltas = [({"role": "assistant", "content": ""}, None)] + [({"content": w}, None) for w in WORDS] + [({}, "stop")]
        self.start_sse()
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
        if not req.get("stream"):
            return self.send_json(200, {
                "id": "msg_mock", "type": "message", "role": "assistant", "model": req.get("model"),
                "content": [{"type": "text", "text": "".join(WORDS)}], "stop_reason": "end_turn", "stop_sequence": None,
                "usage": {"input_tokens": 13, "output_tokens": len(WORDS)},
            })
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
        self.start_sse()
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
