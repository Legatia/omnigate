#!/usr/bin/env python3
"""Fake media providers, object store and webhook receiver for local testing.

Standard library only. Start it with:

    python tools/mock_media.py

Servers (all on 127.0.0.1):

    9101  Replicate-style predictions API that succeeds after ~1 s
    9102  Replicate-style predictions API whose predictions always fail
    9103  fal-style queue API (returns a video file)
    9104  OpenAI-style images API (synchronous, b64_json or url)
    9105  ElevenLabs-style text to speech (synchronous, returns audio bytes)
    9106  S3-compatible object store that verifies AWS SigV4
    9107  Webhook receiver that verifies Standard Webhooks signatures
    9108  Gemini-style generateContent (image, speech) and Interactions API (video)
    9109  xAI-style video generation (submit, then poll by request id)

Every server answers GET /_stats with its counters. Provider mocks insist on
a non-empty API key in the header the real service uses.

Knobs carried in a job's `input` (provider mocks):
    mock_delay_s   seconds until the job completes (default 1.0)
    num_outputs    number of output files (Replicate mock)
    mock_fail      make the fal mock complete with an error result
    mock_output_url   Replicate mock: report this URL as the output (a hostile provider)
    mock_redirect_to  Replicate mock: report an output URL that redirects to this one

Webhook receiver paths:
    POST /hook            always 200
    POST /hook/fail/<n>   first <n> deliveries of each message get a 500
    GET  /received        everything received so far
    POST /reset           forget everything

Environment:
    MOCK_WEBHOOK_SECRET   signing secret (default: the dev config's secret)
    MOCK_S3_ACCESS_KEY    default mock-access-key
    MOCK_S3_SECRET_KEY    default mock-secret-key
"""

import base64
import datetime
import hashlib
import hmac
import json
import os
import struct
import sys
import threading
import time
import urllib.parse
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Where the servers listen, and the host name they put in the URLs they hand
# out. Both default to loopback; the container test sets them so that other
# containers can reach the mocks by name.
BIND = os.environ.get("MOCK_BIND", "127.0.0.1")
HOST = os.environ.get("MOCK_PUBLIC_HOST", BIND)
PORTS = {
    "replicate_ok": 9101,
    "replicate_fail": 9102,
    "fal": 9103,
    "openai_images": 9104,
    "elevenlabs": 9105,
    "s3": 9106,
    "webhooks": 9107,
    "gemini": 9108,
    "xai_video": 9109,
}

# Placeholder shared with config/omnigate.dev.json. Not a real secret.
DEV_WEBHOOK_SECRET = "omnigate-dev-webhook-secret-0001"
WEBHOOK_SECRET = os.environ.get("MOCK_WEBHOOK_SECRET", DEV_WEBHOOK_SECRET)
S3_ACCESS_KEY = os.environ.get("MOCK_S3_ACCESS_KEY", "mock-access-key")
S3_SECRET_KEY = os.environ.get("MOCK_S3_SECRET_KEY", "mock-secret-key")

LOCK = threading.Lock()


def png(seed: int) -> bytes:
    """A small valid PNG whose colour depends on `seed`."""
    width = height = 16
    r, g, b = (seed * 53) % 256, (seed * 97) % 256, (seed * 151) % 256
    raw = b"".join(b"\x00" + bytes([r, g, b]) * width for _ in range(height))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def fake_mp4(seed: str) -> bytes:
    """Not playable, but starts like an MP4 and is a few KiB."""
    return b"\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom" + hashlib.sha256(seed.encode()).digest() * 128


def fake_mp3(text: str) -> bytes:
    return b"ID3\x04\x00\x00\x00\x00\x00\x00" + hashlib.sha256(text.encode()).digest() * 64


class Base(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    stats: dict = {}

    def log_message(self, fmt, *args):  # quiet by default
        if os.environ.get("MOCK_VERBOSE"):
            sys.stderr.write("[%s] %s\n" % (type(self).__name__, fmt % args))

    def base_url(self) -> str:
        return "http://%s:%d" % (HOST, self.server.server_address[1])

    def body(self) -> bytes:
        length = int(self.headers.get("content-length") or 0)
        return self.rfile.read(length) if length else b""

    def json_body(self) -> dict:
        try:
            value = json.loads(self.body() or b"{}")
            return value if isinstance(value, dict) else {}
        except ValueError:
            return {}

    def send(self, status: int, payload, content_type: str = "application/json", headers=None):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def bump(self, name: str):
        with LOCK:
            self.stats[name] = self.stats.get(name, 0) + 1

    def maybe_stats(self) -> bool:
        if self.path == "/_stats":
            with LOCK:
                self.send(200, dict(self.stats))
            return True
        return False

    def bearer(self, scheme: str = "Bearer") -> bool:
        value = self.headers.get("authorization") or ""
        ok = value.startswith(scheme + " ") and len(value) > len(scheme) + 1
        if not ok:
            self.send(401, {"detail": "missing API key (is the upstream's api_key_env set for the control plane?)"})
        return ok


# --------------------------------------------------------------------------
# Replicate-style
# --------------------------------------------------------------------------

def replicate_handler(always_fail: bool):
    class Replicate(Base):
        stats = {"submits": 0, "polls": 0, "cancels": 0, "downloads": 0, "redirects": 0, "internal_hits": 0}
        predictions: dict = {}

        def view(self, p: dict) -> dict:
            elapsed = time.time() - p["created"]
            status, output, error = p.get("forced"), None, None
            if status is None:
                if elapsed < p["delay"] * 0.3:
                    status = "starting"
                elif elapsed < p["delay"]:
                    status = "processing"
                elif always_fail:
                    status, error = "failed", "mock model crashed"
                else:
                    status = "succeeded"
                    urls = ["%s/files/%s-%d.png" % (self.base_url(), p["id"], i) for i in range(p["n"])]
                    # A hostile (or compromised) provider: its "output" points
                    # wherever the test says, directly or through a redirect.
                    if isinstance(p["input"].get("mock_output_url"), str):
                        urls = [p["input"]["mock_output_url"]]
                    elif isinstance(p["input"].get("mock_redirect_to"), str):
                        urls = ["%s/redirect?to=%s" % (self.base_url(), urllib.parse.quote(p["input"]["mock_redirect_to"], safe=""))]
                    output = urls if p["as_list"] else urls[0]
            return {
                "id": p["id"],
                "model": p["model"],
                "version": p["version"],
                "input": p["input"],
                "status": status,
                "output": output,
                "error": error,
                "logs": "",
                "created_at": datetime.datetime.fromtimestamp(p["created"], datetime.timezone.utc).isoformat(),
                "metrics": {"predict_time": p["delay"]} if status == "succeeded" else {},
                "urls": {
                    "get": "%s/v1/predictions/%s" % (self.base_url(), p["id"]),
                    "cancel": "%s/v1/predictions/%s/cancel" % (self.base_url(), p["id"]),
                },
            }

        def do_POST(self):
            path = self.path.split("?")[0]
            parts = [s for s in path.split("/") if s]
            if not self.bearer():
                return
            if len(parts) == 4 and parts[:2] == ["v1", "predictions"] and parts[3] == "cancel":
                self.body()
                p = self.predictions.get(parts[2])
                if not p:
                    return self.send(404, {"detail": "not found"})
                self.bump("cancels")
                p["forced"] = "canceled"
                return self.send(200, self.view(p))
            is_create = path == "/v1/predictions" or (
                len(parts) == 5 and parts[:2] == ["v1", "models"] and parts[4] == "predictions"
            )
            if not is_create:
                self.body()
                return self.send(404, {"detail": "not found"})
            req = self.json_body()
            inp = req.get("input")
            if not isinstance(inp, dict):
                return self.send(422, {"title": "Input validation failed", "detail": "input must be an object"})
            self.bump("submits")
            pid = uuid.uuid4().hex[:24]
            p = {
                "id": pid,
                "model": "/".join(parts[2:4]) if len(parts) == 5 else "mock/model",
                "version": req.get("version") or "hidden",
                "input": inp,
                "created": time.time(),
                "delay": float(inp.get("mock_delay_s", 1.0)),
                "n": int(inp.get("num_outputs", 1)),
                "as_list": "num_outputs" in inp,
            }
            with LOCK:
                self.predictions[pid] = p
            self.send(201, self.view(p))

        def do_GET(self):
            if self.maybe_stats():
                return
            path = self.path.split("?")[0]
            if path == "/redirect":
                # Sends the downloader somewhere else; counted so a test can
                # tell whether the first hop was fetched at all.
                self.bump("redirects")
                to = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("to", [""])[0]
                self.send_response(302)
                self.send_header("location", to)
                self.send_header("content-length", "0")
                self.end_headers()
                return
            if path == "/internal-only":
                # Stands for something that only exists on the private network.
                self.bump("internal_hits")
                return self.send(200, b"secret", "text/plain")
            if path.startswith("/files/"):
                # Output files are public, like the real delivery URLs.
                self.bump("downloads")
                name = path[len("/files/"):]
                seed = int(hashlib.sha256(name.encode()).hexdigest()[:6], 16)
                if name.startswith("big-"):
                    # Not an image anyone could open: 300 kB, more than the
                    # gateway sends in one piece.
                    return self.send(200, png(seed) + hashlib.sha256(name.encode()).digest() * 9375, "image/png")
                return self.send(200, png(seed), "image/png")
            if not self.bearer():
                return
            parts = [s for s in path.split("/") if s]
            if len(parts) == 3 and parts[:2] == ["v1", "predictions"]:
                p = self.predictions.get(parts[2])
                if not p:
                    return self.send(404, {"detail": "not found"})
                self.bump("polls")
                return self.send(200, self.view(p))
            self.send(404, {"detail": "not found"})

    return Replicate


# --------------------------------------------------------------------------
# fal-style queue
# --------------------------------------------------------------------------

class Fal(Base):
    stats = {"submits": 0, "polls": 0, "results": 0, "cancels": 0, "downloads": 0}
    requests: dict = {}

    def auth(self) -> bool:
        return self.bearer("Key")

    def locate(self, path: str):
        """/<owner>/<app>/requests/<id>[/status|/cancel] -> (request, tail)"""
        parts = [s for s in path.split("/") if s]
        if "requests" not in parts:
            return None, None
        i = parts.index("requests")
        if len(parts) <= i + 1:
            return None, None
        return self.requests.get(parts[i + 1]), (parts[i + 2] if len(parts) > i + 2 else "")

    def state(self, r: dict) -> str:
        if r.get("canceled"):
            return "CANCELED"
        elapsed = time.time() - r["created"]
        if elapsed < r["delay"] * 0.3:
            return "IN_QUEUE"
        if elapsed < r["delay"]:
            return "IN_PROGRESS"
        return "COMPLETED"

    def do_POST(self):
        path = self.path.split("?")[0]
        if not self.auth():
            return
        if "/requests/" in path:
            self.body()
            return self.send(405, {"detail": "method not allowed"})
        inp = self.json_body()
        self.bump("submits")
        rid = str(uuid.uuid4())
        app = "/".join([s for s in path.split("/") if s][:2])
        with LOCK:
            self.requests[rid] = {
                "id": rid,
                "input": inp,
                "created": time.time(),
                "delay": float(inp.get("mock_delay_s", 1.0)),
            }
        root = "%s/%s/requests/%s" % (self.base_url(), app, rid)
        self.send(200, {
            "status": "IN_QUEUE",
            "request_id": rid,
            "response_url": root,
            "status_url": root + "/status",
            "cancel_url": root + "/cancel",
            "queue_position": 0,
        })

    def do_PUT(self):
        self.body()
        if not self.auth():
            return
        r, tail = self.locate(self.path.split("?")[0])
        if not r or tail != "cancel":
            return self.send(404, {"detail": "not found"})
        self.bump("cancels")
        r["canceled"] = True
        self.send(202, {"status": "CANCELLATION_REQUESTED"})

    def do_GET(self):
        if self.maybe_stats():
            return
        path = self.path.split("?")[0]
        if path.startswith("/files/"):
            self.bump("downloads")
            return self.send(200, fake_mp4(path), "video/mp4")
        if not self.auth():
            return
        r, tail = self.locate(path)
        if not r:
            return self.send(404, {"detail": "not found"})
        state = self.state(r)
        if tail == "status":
            self.bump("polls")
            body = {"status": state, "request_id": r["id"]}
            if state == "IN_QUEUE":
                body["queue_position"] = 0
            return self.send(200 if state == "COMPLETED" else 202, body)
        if tail == "":
            if state != "COMPLETED":
                return self.send(400, {"detail": "Request is still in progress"})
            self.bump("results")
            if r["input"].get("mock_fail"):
                return self.send(422, {"detail": [{"loc": ["body", "prompt"], "msg": "mock failure", "type": "mock_error"}]})
            url = "%s/files/%s.mp4" % (self.base_url(), r["id"])
            return self.send(200, {
                "video": {"url": url, "content_type": "video/mp4", "file_name": "output.mp4", "file_size": len(fake_mp4(""))},
                "seed": 42,
            })
        self.send(404, {"detail": "not found"})


# --------------------------------------------------------------------------
# OpenAI-style images
# --------------------------------------------------------------------------

class OpenAIImages(Base):
    stats = {"calls": 0, "downloads": 0}

    def do_GET(self):
        if self.maybe_stats():
            return
        if self.path.startswith("/files/"):
            self.bump("downloads")
            return self.send(200, png(7), "image/png")
        self.send(404, {"error": {"message": "not found", "type": "invalid_request_error"}})

    def do_POST(self):
        if not self.bearer():
            return
        req = self.json_body()
        if self.path.split("?")[0] != "/v1/images/generations":
            return self.send(404, {"error": {"message": "not found", "type": "invalid_request_error"}})
        if not isinstance(req.get("prompt"), str) or not req.get("model"):
            return self.send(400, {"error": {"message": "prompt and model are required", "type": "invalid_request_error"}})
        self.bump("calls")
        n = int(req.get("n", 1))
        if req.get("response_format") == "url":
            data = [{"url": "%s/files/%s.png" % (self.base_url(), uuid.uuid4().hex)} for _ in range(n)]
        else:
            data = [{"b64_json": base64.b64encode(png(i + len(req["prompt"]))).decode()} for i in range(n)]
        self.send(200, {
            "created": int(time.time()),
            "data": data,
            "usage": {"input_tokens": 12, "output_tokens": 1056 * n, "total_tokens": 12 + 1056 * n},
        })


# --------------------------------------------------------------------------
# ElevenLabs-style TTS
# --------------------------------------------------------------------------

class ElevenLabs(Base):
    stats = {"calls": 0, "characters": 0}

    def do_GET(self):
        if self.maybe_stats():
            return
        self.send(404, {"detail": {"status": "not_found", "message": "not found"}})

    def do_POST(self):
        req = self.json_body()
        if not self.headers.get("xi-api-key"):
            return self.send(401, {"detail": {"status": "invalid_api_key", "message": "missing xi-api-key"}})
        parts = [s for s in self.path.split("?")[0].split("/") if s]
        if len(parts) != 3 or parts[:2] != ["v1", "text-to-speech"]:
            return self.send(404, {"detail": {"status": "not_found", "message": "not found"}})
        text = req.get("text")
        if not isinstance(text, str) or not text:
            return self.send(422, {"detail": {"status": "invalid_request", "message": "text is required"}})
        self.bump("calls")
        with LOCK:
            self.stats["characters"] += len(text)
        self.send(200, fake_mp3(parts[2] + ":" + text), "audio/mpeg")


# --------------------------------------------------------------------------
# S3-compatible store with SigV4 verification
# --------------------------------------------------------------------------

def _hmac(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def sigv4_key(secret: str, date: str, region: str, service: str) -> bytes:
    return _hmac(_hmac(_hmac(_hmac(("AWS4" + secret).encode(), date), region), service), "aws4_request")


def _quote(s: str) -> str:
    return urllib.parse.quote(s, safe="-_.~")


def canonical_query(pairs) -> str:
    return "&".join("%s=%s" % (k, v) for k, v in sorted((_quote(k), _quote(v)) for k, v in pairs))


def canonical_path(path: str) -> str:
    return "/".join(_quote(urllib.parse.unquote(seg)) for seg in path.split("/"))


class S3(Base):
    stats = {"puts": 0, "gets": 0, "rejected": 0}
    objects: dict = {}

    def deny(self, code: str, message: str):
        self.bump("rejected")
        xml = "<?xml version=\"1.0\"?><Error><Code>%s</Code><Message>%s</Message></Error>" % (code, message)
        self.send(403, xml.encode(), "application/xml")

    def expected(self, method: str, path: str, query_pairs, signed_headers, payload_hash, amz_date, scope) -> str:
        date, region, service, _ = scope.split("/")
        header_block = ""
        for name in signed_headers:
            value = self.headers.get(name) or ""
            header_block += "%s:%s\n" % (name, " ".join(value.split()))
        canonical = "\n".join([
            method, canonical_path(path), canonical_query(query_pairs), header_block, ";".join(signed_headers), payload_hash,
        ])
        to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
        return hmac.new(sigv4_key(S3_SECRET_KEY, date, region, service), to_sign.encode(), hashlib.sha256).hexdigest()

    def verify_header_auth(self, method: str, body: bytes) -> bool:
        auth = self.headers.get("authorization") or ""
        if not auth.startswith("AWS4-HMAC-SHA256 "):
            self.deny("AccessDenied", "missing SigV4 authorization")
            return False
        fields = dict(p.strip().split("=", 1) for p in auth[len("AWS4-HMAC-SHA256 "):].split(","))
        access, scope = fields["Credential"].split("/", 1)
        signed = fields["SignedHeaders"].split(";")
        payload_hash = self.headers.get("x-amz-content-sha256") or ""
        if access != S3_ACCESS_KEY:
            self.deny("InvalidAccessKeyId", "unknown access key")
            return False
        for required in ("host", "x-amz-content-sha256", "x-amz-date"):
            if required not in signed:
                self.deny("AccessDenied", "%s must be signed" % required)
                return False
        if payload_hash != hashlib.sha256(body).hexdigest():
            self.deny("XAmzContentSHA256Mismatch", "payload hash does not match the body")
            return False
        parsed = urllib.parse.urlsplit(self.path)
        pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        want = self.expected(method, parsed.path, pairs, signed, payload_hash, self.headers.get("x-amz-date") or "", scope)
        if not hmac.compare_digest(want, fields["Signature"]):
            self.deny("SignatureDoesNotMatch", "signature mismatch")
            return False
        return True

    def verify_presigned(self, method: str) -> bool:
        parsed = urllib.parse.urlsplit(self.path)
        pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        q = dict(pairs)
        access, scope = q.get("X-Amz-Credential", "/").split("/", 1)
        if access != S3_ACCESS_KEY or q.get("X-Amz-Algorithm") != "AWS4-HMAC-SHA256":
            self.deny("AccessDenied", "bad presigned credential")
            return False
        signed_at = datetime.datetime.strptime(q["X-Amz-Date"], "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.timezone.utc)
        age = (datetime.datetime.now(datetime.timezone.utc) - signed_at).total_seconds()
        if age > int(q.get("X-Amz-Expires", "0")):
            self.deny("AccessDenied", "Request has expired")
            return False
        unsigned = [(k, v) for k, v in pairs if k != "X-Amz-Signature"]
        want = self.expected(method, parsed.path, unsigned, q["X-Amz-SignedHeaders"].split(";"), "UNSIGNED-PAYLOAD", q["X-Amz-Date"], scope)
        if not hmac.compare_digest(want, q.get("X-Amz-Signature", "")):
            self.deny("SignatureDoesNotMatch", "signature mismatch")
            return False
        return True

    def do_PUT(self):
        body = self.body()
        if not self.verify_header_auth("PUT", body):
            return
        key = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        with LOCK:
            self.objects[key] = (body, self.headers.get("content-type") or "application/octet-stream")
        self.bump("puts")
        self.send(200, b"", "application/xml", {"etag": '"%s"' % hashlib.md5(body).hexdigest()})

    def do_GET(self):
        if self.path == "/_stats":
            with LOCK:
                return self.send(200, dict(self.stats, objects=sorted(self.objects)))
        parsed = urllib.parse.urlsplit(self.path)
        key = urllib.parse.unquote(parsed.path)
        bucket = key.strip("/").split("/")[0]
        if "X-Amz-Signature" in parsed.query:
            if not self.verify_presigned("GET"):
                return
        elif self.headers.get("authorization"):
            if not self.verify_header_auth("GET", b""):
                return
        elif not bucket.startswith("public"):
            # Buckets whose name starts with "public" allow anonymous reads.
            return self.deny("AccessDenied", "anonymous access is not allowed on this bucket")
        obj = self.objects.get(key)
        if not obj:
            return self.send(404, b"<Error><Code>NoSuchKey</Code></Error>", "application/xml")
        self.bump("gets")
        self.send(200, obj[0], obj[1])


# --------------------------------------------------------------------------
# Webhook receiver
# --------------------------------------------------------------------------

def webhook_key(secret: str) -> bytes:
    if secret.startswith("whsec_"):
        try:
            return base64.b64decode(secret[len("whsec_"):], validate=True)
        except ValueError:
            pass
    return secret.encode()


class Webhooks(Base):
    stats = {"deliveries": 0, "accepted": 0, "rejected": 0, "bad_signature": 0}
    received: list = []
    seen: dict = {}

    def do_GET(self):
        if self.maybe_stats():
            return
        if self.path == "/received":
            with LOCK:
                return self.send(200, {"deliveries": list(self.received)})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        body = self.body()
        path = self.path.split("?")[0]
        if path == "/reset":
            with LOCK:
                self.received.clear()
                self.seen.clear()
            return self.send(200, {"ok": True})
        if not path.startswith("/hook"):
            return self.send(404, {"error": "not found"})

        msg_id = self.headers.get("webhook-id") or ""
        timestamp = self.headers.get("webhook-timestamp") or ""
        signature = self.headers.get("webhook-signature") or ""
        signed = ("%s.%s." % (msg_id, timestamp)).encode() + body
        want = "v1," + base64.b64encode(hmac.new(webhook_key(WEBHOOK_SECRET), signed, hashlib.sha256).digest()).decode()
        fresh = timestamp.isdigit() and abs(time.time() - int(timestamp)) < 300
        valid = fresh and any(hmac.compare_digest(want, s) for s in signature.split(" "))

        parts = [s for s in path.split("/") if s]
        fail_first = int(parts[2]) if len(parts) == 3 and parts[1] == "fail" and parts[2].isdigit() else 0
        with LOCK:
            nth = self.seen.get(msg_id, 0) + 1
            self.seen[msg_id] = nth
        if not valid:
            status = 401
        elif nth <= fail_first:
            status = 500
        else:
            status = 200
        try:
            payload = json.loads(body)
        except ValueError:
            payload = None
        with LOCK:
            self.received.append({
                "path": path,
                "webhook_id": msg_id,
                "webhook_timestamp": timestamp,
                "signature_valid": bool(valid),
                "delivery_number": nth,
                "responded": status,
                "received_at": time.time(),
                "payload": payload,
            })
        self.bump("deliveries")
        self.bump("accepted" if status == 200 else "rejected")
        if not valid:
            self.bump("bad_signature")
        self.send(status, {"ok": status == 200})


# --------------------------------------------------------------------------
# Gemini-style generateContent (image and speech models)
# --------------------------------------------------------------------------

class Gemini(Base):
    stats = {"calls": 0, "interactions": 0, "polls": 0}
    interactions: dict = {}

    def interaction_body(self, iid: str, r: dict) -> dict:
        if time.time() < r["ready_at"]:
            return {"id": iid, "object": "interaction", "status": "in_progress", "model": r["model"]}
        return {"id": iid, "object": "interaction", "status": "completed", "model": r["model"], "steps": [
            {"type": "thought", "signature": "mock"},
            {"type": "model_output", "content": [
                {"type": "video", "mime_type": "video/mp4", "data": base64.b64encode(fake_mp4(iid)).decode()}]}]}

    def interaction(self, req: dict):
        """The Interactions API: foreground answers finished, background answers early."""
        if not isinstance(req.get("input"), str) or not req.get("model"):
            return self.send(400, {"error": {"code": 400, "message": "model and input are required", "status": "INVALID_ARGUMENT"}})
        self.bump("interactions")
        iid = "v1_" + hashlib.sha256(("%s%f" % (req["input"], time.time())).encode()).hexdigest()[:24]
        r = {"model": req["model"], "ready_at": time.time() + (1.0 if req.get("background") else 0.0)}
        with LOCK:
            self.interactions[iid] = r
        self.send(200, self.interaction_body(iid, r))

    def do_GET(self):
        if self.maybe_stats():
            return
        path = self.path.split("?")[0]
        with LOCK:
            r = self.interactions.get(path[len("/v1beta/interactions/"):]) if path.startswith("/v1beta/interactions/") else None
        if r is None or not self.headers.get("x-goog-api-key"):
            return self.send(404, {"error": {"code": 404, "message": "not found", "status": "NOT_FOUND"}})
        self.bump("polls")
        self.send(200, self.interaction_body(path[len("/v1beta/interactions/"):], r))

    def do_POST(self):
        req = self.json_body()
        if not self.headers.get("x-goog-api-key"):
            return self.send(401, {"error": {"code": 401, "message": "API key not valid", "status": "UNAUTHENTICATED"}})
        path = self.path.split("?")[0]
        if path == "/v1beta/interactions":
            return self.interaction(req)
        if not (path.startswith("/v1beta/models/") and path.endswith(":generateContent")):
            return self.send(404, {"error": {"code": 404, "message": "not found", "status": "NOT_FOUND"}})
        model = path[len("/v1beta/models/"):-len(":generateContent")]
        if "omni" in model:
            return self.send(400, {"error": {"code": 400, "message": "This model only supports Interactions API.", "status": "INVALID_ARGUMENT"}})
        try:
            text = req["contents"][0]["parts"][0]["text"]
        except (KeyError, IndexError, TypeError):
            return self.send(400, {"error": {"code": 400, "message": "contents is required", "status": "INVALID_ARGUMENT"}})
        self.bump("calls")
        if "blocked" in text:
            # Gemini answers 200 with no file when a prompt is refused.
            return self.send(200, {"promptFeedback": {"blockReason": "SAFETY"}})
        config = req.get("generationConfig") or {}
        if "AUDIO" in (config.get("responseModalities") or []):
            # Headerless PCM, as the older speech models return it.
            data, mime = b"\x00\x01" * 2400, "audio/L16;codec=pcm;rate=24000"
        else:
            data, mime = png(len(text)), "image/png"
        self.send(200, {
            "candidates": [{"content": {"role": "model", "parts": [
                {"inlineData": {"mimeType": mime, "data": base64.b64encode(data).decode()}}]}, "finishReason": "STOP", "index": 0}],
            "usageMetadata": {"promptTokenCount": 5, "candidatesTokenCount": 50, "totalTokenCount": 55},
            "modelVersion": model,
        })


# --------------------------------------------------------------------------
# xAI-style video generation (submit, then poll by request id)
# --------------------------------------------------------------------------

class XaiVideo(Base):
    stats = {"submits": 0, "polls": 0, "downloads": 0}
    requests: dict = {}

    def do_POST(self):
        req = self.json_body()
        if not self.bearer("Bearer"):
            return
        if self.path.split("?")[0] != "/v1/videos/generations":
            return self.send(404, {"error": "not found"})
        if not isinstance(req.get("prompt"), str) or not req.get("model"):
            return self.send(400, {"error": "prompt and model are required"})
        self.bump("submits")
        rid = "vid_" + hashlib.sha256(("%s%f" % (req["prompt"], time.time())).encode()).hexdigest()[:20]
        with LOCK:
            self.requests[rid] = {"ready_at": time.time() + float(req.get("mock_delay_s", 1.0)), "req": req}
        self.send(200, {"request_id": rid})

    def do_GET(self):
        if self.maybe_stats():
            return
        path = self.path.split("?")[0]
        if path.startswith("/files/"):
            self.bump("downloads")
            return self.send(200, fake_mp4(path), "video/mp4")
        if not self.bearer("Bearer"):
            return
        with LOCK:
            r = self.requests.get(path[len("/v1/videos/"):]) if path.startswith("/v1/videos/") else None
        if r is None:
            return self.send(404, {"error": "unknown request id"})
        self.bump("polls")
        if time.time() < r["ready_at"]:
            return self.send(200, {"status": "pending"})
        if "fail" in r["req"]["prompt"]:
            return self.send(200, {"status": "failed", "error": "mock generation failed"})
        rid = path[len("/v1/videos/"):]
        self.send(200, {"status": "done", "model": r["req"]["model"],
                        "video": {"url": "%s/files/%s.mp4" % (self.base_url(), rid), "duration": r["req"].get("duration", 5)}})


def main():
    servers = [
        ("replicate_ok", replicate_handler(False)),
        ("replicate_fail", replicate_handler(True)),
        ("fal", Fal),
        ("openai_images", OpenAIImages),
        ("elevenlabs", ElevenLabs),
        ("s3", S3),
        ("webhooks", Webhooks),
        ("gemini", Gemini),
        ("xai_video", XaiVideo),
    ]
    for name, handler in servers:
        httpd = ThreadingHTTPServer((BIND, PORTS[name]), handler)
        httpd.daemon_threads = True
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        print("mock %-15s http://%s:%d" % (name, HOST, PORTS[name]), flush=True)
    print("ready", flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    if "--help" in sys.argv or "-h" in sys.argv:
        print(__doc__)
        raise SystemExit(0)
    main()
