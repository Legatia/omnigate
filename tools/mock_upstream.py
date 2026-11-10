"""Mock LLM providers for local end-to-end tests. No network, no API keys.

  :9001  OpenAI-shaped, always answers 503   (forces failover)
  :9002  OpenAI-shaped, works (JSON and SSE)
  :9003  Anthropic-shaped, works (JSON and SSE)
  :9004  OpenAI-shaped, works but waits 3 s before answering (forces a timeout)

Run:  python tools/mock_upstream.py
"""

import json
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


class OpenAIOk(Base):
    def do_POST(self):
        req = self.read_json()
        auth = self.headers.get("authorization", "")
        if not auth.startswith("Bearer "):
            return self.send_json(401, {"error": {"message": "missing bearer token"}})
        usage = {"prompt_tokens": 11, "completion_tokens": len(WORDS), "total_tokens": 11 + len(WORDS)}
        if not req.get("stream"):
            return self.send_json(200, {
                "id": "chatcmpl-mock", "object": "chat.completion", "model": req.get("model"),
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "".join(WORDS)},
                             "finish_reason": "stop"}],
                "usage": usage,
            })
        self.start_sse()
        for w in WORDS:
            chunk = {"id": "chatcmpl-mock", "object": "chat.completion.chunk",
                     "choices": [{"index": 0, "delta": {"content": w}}]}
            self.sse(f"data: {json.dumps(chunk)}\n\n")
        if (req.get("stream_options") or {}).get("include_usage"):
            self.sse(f"data: {json.dumps({'id': 'chatcmpl-mock', 'choices': [], 'usage': usage})}\n\n")
        self.sse("data: [DONE]\n\n")
        self.end_sse()


class AnthropicOk(Base):
    def do_POST(self):
        req = self.read_json()
        if not self.headers.get("x-api-key") or not self.headers.get("anthropic-version"):
            return self.send_json(401, {"type": "error", "error": {"type": "authentication_error",
                                                                  "message": "missing x-api-key or anthropic-version"}})
        if not req.get("stream"):
            return self.send_json(200, {
                "id": "msg_mock", "type": "message", "role": "assistant", "model": req.get("model"),
                "content": [{"type": "text", "text": "".join(WORDS)}], "stop_reason": "end_turn",
                "usage": {"input_tokens": 13, "output_tokens": len(WORDS)},
            })
        self.start_sse()
        start = {"type": "message_start", "message": {"id": "msg_mock", "role": "assistant",
                                                      "usage": {"input_tokens": 13, "output_tokens": 1}}}
        self.sse(f"event: message_start\ndata: {json.dumps(start)}\n\n")
        for w in WORDS:
            delta = {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": w}}
            self.sse(f"event: content_block_delta\ndata: {json.dumps(delta)}\n\n")
        end = {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": len(WORDS)}}
        self.sse(f"event: message_delta\ndata: {json.dumps(end)}\n\n")
        self.sse('event: message_stop\ndata: {"type":"message_stop"}\n\n')
        self.end_sse()


class Slow(OpenAIOk):
    def do_POST(self):
        time.sleep(3)
        super().do_POST()


def serve(port, handler):
    ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()


if __name__ == "__main__":
    for port, handler in [(9001, Flaky), (9002, OpenAIOk), (9003, AnthropicOk), (9004, Slow)]:
        threading.Thread(target=serve, args=(port, handler), daemon=True).start()
    print("mock upstreams on :9001 (503), :9002 (openai), :9003 (anthropic), :9004 (slow openai)", flush=True)
    threading.Event().wait()
