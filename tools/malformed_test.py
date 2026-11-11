"""Hostile-input test for the gateway: malformed, ambiguous and oversized requests.

    python tools/malformed_test.py                 # starts its own stack (mocks, control plane, gateway)
    python tools/malformed_test.py --thorough      # the same with many more generated cases
    python tools/malformed_test.py --gateway 127.0.0.1:8080 --key og-unlimited-key --model demo-direct

Without --gateway it needs only a built data plane (`zig build` in
dataplane/) and `mix`: it starts the mock providers, the control plane and
the gateway through the end-to-end harness (tools/e2e.py), on that harness's
ports and with state in a temp dir, and stops them at the end. With --gateway
it tests an instance you started yourself.

Sends, over raw sockets, every request from the security reviews that used to
crash the data plane or slip past a check, a few hundred generated variations
of broken request heads (seeded, so a failure can be replayed with --seed),
deeply nested JSON, request-smuggling attempts and non-canonical paths.

When it started the stack itself it also plays the other side: an upstream
that answers with chunk sizes that overflow, bodies shorter than their
content-length, both framings at once and a header smuggled into the content
type (special model names of tools/mock_upstream.py on :9005), and a control
plane that does the same (a stand-in inside this script on :4300, with a
second gateway on :8190 pointed at it). And it checks the limits that apply
before a request body is read: the per-key concurrency cap, the rate limit,
the size limit.

After EVERY case it asks /healthz on a fresh connection. A panic anywhere in
the gateway ends the whole process, so "still answering" is the property
under test; where a case has one right answer (400, 411, ...) that is checked
too. Exit code 0 only if the gateway survived everything and every expected
status matched.

It also checks that a client which reads the start of a stream and hangs up,
or stops reading without hanging up, is still billed, with the provider's
own figures when the provider goes on to report them: always when it started the stack itself (it then reads the
ledger through the control plane's admin API), and against your own instance
when --events-url names a URL that lists the usage events received.

Standard library only. Point it at a test instance, never at production.
"""

import argparse
import hashlib
import json
import os
import random
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

results = []
ARGS = None
# Set when this script started the stack itself: how to read the ledger.
OVERVIEW = None


# Set while the cases run against the second gateway (the one whose control
# plane is this script's stand-in).
TARGET = None


def host_port():
    if TARGET:
        return TARGET
    host, _, port = ARGS.gateway.rpartition(":")
    return host or "127.0.0.1", int(port)


def exchange(data, read_timeout=0.4, chunks=None, keep_reading=1.5):
    """Send bytes (optionally in pieces), return whatever comes back before the peer closes or goes quiet."""
    out = b""
    try:
        s = socket.create_connection(host_port(), timeout=3)
    except OSError as e:
        return None, f"connect failed: {e}"
    try:
        try:
            for piece in (chunks or [data]):
                s.sendall(piece)
        except OSError:
            pass  # the gateway may close on us mid-send; that is an answer too
        s.settimeout(read_timeout)
        deadline = time.time() + keep_reading
        while time.time() < deadline:
            try:
                got = s.recv(65536)
            except socket.timeout:
                break
            except OSError:
                break
            if not got:
                break
            out += got
            if complete(out):
                break
    finally:
        try:
            s.close()
        except OSError:
            pass
    return out, None


def complete(raw):
    """Is this one whole response (declared length, or chunked to its end)? Then there is nothing more to wait for."""
    if raw.startswith(b"HTTP/1.1 100 "):
        # An interim answer; the real one follows.
        skip = raw.find(b"\r\n\r\n")
        return skip >= 0 and complete(raw[skip + 4:])
    end = raw.find(b"\r\n\r\n")
    if end < 0:
        return False
    for line in raw[:end].split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length" and value.strip().isdigit():
            return len(raw) - end - 4 >= int(value.strip())
        if name.strip().lower() == b"transfer-encoding" and value.strip().lower() == b"chunked":
            return raw.endswith(b"\r\n0\r\n\r\n") or raw[end + 4:] == b"0\r\n\r\n"
    return False


def status_of(raw):
    if not raw or not raw.startswith(b"HTTP/1."):
        return None
    try:
        return int(raw[9:12])
    except ValueError:
        return None


def final_status(raw):
    """The status after any `100 Continue`."""
    if raw and raw.startswith(b"HTTP/1.1 100 "):
        skip = raw.find(b"\r\n\r\n")
        return status_of(raw[skip + 4:]) if skip >= 0 else None
    return status_of(raw)


def body_of(raw):
    """The body of one response, de-chunked if it is chunked; None if it is not whole."""
    end = raw.find(b"\r\n\r\n")
    if end < 0:
        return None
    head, rest = raw[:end].lower(), raw[end + 4:]
    if b"transfer-encoding: chunked" not in head:
        return rest
    out = b""
    while True:
        line_end = rest.find(b"\r\n")
        if line_end < 0:
            return None
        try:
            size = int(rest[:line_end].split(b";")[0], 16)
        except ValueError:
            return None
        if size == 0:
            return out
        chunk = rest[line_end + 2:line_end + 2 + size]
        if len(chunk) < size:
            return None
        out += chunk
        rest = rest[line_end + 2 + size + 2:]


def record(name, ok, detail=""):
    results.append((name, ok))
    if not ok or ARGS.verbose:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"   [{detail}]" if detail and not ok else ""), flush=True)
    return ok


def alive():
    for _ in range(3):
        raw, err = exchange(b"GET /healthz HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n", read_timeout=2.0, keep_reading=3.0)
        if raw and status_of(raw) == 200:
            return True
        time.sleep(0.3)
    return False


def case(name, data, expect=None, forbid=None, chunks=None, read_timeout=0.4, keep_reading=1.5, check=None):
    """Run one case. expect: status or set of statuses (None in the set = no response at all)."""
    raw, err = exchange(data, read_timeout=read_timeout, chunks=chunks, keep_reading=keep_reading)
    status = status_of(raw)
    ok = True
    why = ""
    if expect is not None:
        allowed = expect if isinstance(expect, (set, frozenset, list, tuple)) else {expect}
        if status not in allowed:
            ok, why = False, f"status {status}, wanted {sorted(allowed, key=str)}"
    if ok and forbid and status in forbid:
        ok, why = False, f"status {status} must not happen here"
    if ok and check:
        problem = check(raw or b"", status)
        if problem:
            ok, why = False, problem
    if not alive():
        results.append((name, False))
        print(f"  FAIL  {name}   [the gateway stopped answering after this case]", flush=True)
        print("\nthe gateway is down: stopping. Replay with the same --seed.")
        summary()
        sys.exit(1)
    results.append((name, ok))
    if not ok or ARGS.verbose:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"   [{why}; got {(raw or b'')[:120]!r}]" if not ok else ""), flush=True)
    return raw, status


def section(title):
    print(f"\n== {title}", flush=True)


def summary():
    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} hostile-input cases passed (seed {ARGS.seed})")
    for n in failed[:30]:
        print("  failed:", n)
    return not failed


def post(path, body, key=None, extra=b"", method=b"POST"):
    body = body if isinstance(body, bytes) else body.encode()
    key = (key or ARGS.key).encode()
    return (method + b" " + path.encode() + b" HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer " + key +
            b"\r\nContent-Type: application/json\r\nContent-Length: " + str(len(body)).encode() + b"\r\n" + extra + b"\r\n" + body)


def chat_body(extra=None):
    body = {"model": ARGS.model, "messages": [{"role": "user", "content": "hi"}]}
    body.update(extra or {})
    return json.dumps(body)


# --------------------------------------------------------------------------

def known_crashers():
    section("requests that used to end the process")
    case("header line without a colon (std's header iterator unwrapped a null)", b"GET / HTTP/1.1\r\nX\r\n", expect={400, None})
    case("... after a valid header", b"GET /healthz HTTP/1.1\r\nHost: a\r\nX\r\n", expect={400, None})
    case("... with a proper end of head", b"GET /healthz HTTP/1.1\r\nHost: a\r\nX\r\n\r\n", expect=400)
    case("POST with no content-length and no chunked encoding (std asserted on it)", b"POST / HTTP/1.1\r\n\r\n", expect=411)
    case("PUT with no length", b"PUT /v1/x HTTP/1.1\r\nHost: a\r\n\r\n", expect=411)
    case("POST with no length to a real endpoint, with a key",
         b"POST /v1/chat/completions HTTP/1.1\r\nHost: a\r\nAuthorization: Bearer " + ARGS.key.encode() + b"\r\n\r\n", expect=411)

    for depth in (65, 256, 257, 300, 5000, 100000):
        nested = "[" * depth + "]" * depth
        case(f"JSON nested {depth} deep, with a valid key (the serialiser indexed past its stack at 256)",
             post("/v1/chat/completions", '{"model":"%s","messages":[],"x":%s}' % (ARGS.model, nested)), expect=400, keep_reading=4)
        case(f"... as objects, {depth} deep",
             post("/v1/chat/completions", '{"model":"%s","messages":[],"x":%s1%s}' % (ARGS.model, '{"a":' * depth, "}" * depth)), expect=400, keep_reading=4)
    case("... on the Anthropic endpoint", post("/v1/messages", '{"model":"%s","max_tokens":5,"messages":[],"x":%s}' % (ARGS.model, "[" * 300 + "]" * 300)), expect=400)
    case("... in a job request", post("/v1/jobs", '{"model":"m","input":%s}' % ("[" * 300 + "]" * 300)), expect=400)
    case("nesting just inside the limit is still served",
         post("/v1/chat/completions", '{"model":"%s","messages":[{"role":"user","content":"hi"}],"metadata":%s}' % (ARGS.model, '{"a":' * 60 + "1" + "}" * 60)),
         forbid={None, 500}, read_timeout=5, keep_reading=8)
    deep_args = json.dumps("[" * 300 + "]" * 300)
    case("deep JSON hidden in a tool call's arguments string",
         post("/v1/chat/completions", '{"model":"%s","messages":[{"role":"assistant","tool_calls":[{"id":"c","type":"function","function":{"name":"f","arguments":%s}}]}]}'
              % (ARGS.model, deep_args)), forbid={None}, read_timeout=5, keep_reading=8)


def smuggling():
    section("request smuggling and header injection")
    inner = b'{"events":[{"key_sha256":"' + b"0" * 64 + b'","status":200,"input_tokens":1,"output_tokens":1}]}'
    smuggled = (b"POST /v1/jobs?a=1 HTTP/1.1\nhost: c\ncontent-length: 0\n\nPOST /internal/usage/batch HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer " +
                ARGS.key.encode() + b"\r\nContent-Length: " + str(len(inner)).encode() + b"\r\n\r\n" + inner)
    case("a second request hidden in the request line with bare line feeds", smuggled, expect={400, None})
    case("a space in the request target", post("/v1/jobs?a=1 x", "{}"), expect=400)
    case("a tab in the request target", post("/v1/jobs?a=1\tx", "{}"), expect=400)
    case("a header value with a bare line feed carrying an internal header",
         post("/v1/jobs", "{}", extra=b"Idempotency-Key: a\nx-omnigate-key-sha256: " + b"0" * 64 + b"\r\n"), expect={400, None})
    case("an idempotency key with characters outside the allowed set", post("/v1/jobs", "{}", extra=b"Idempotency-Key: a b;c\r\n"), expect=400)
    case("an anthropic-version header that is not a version", post("/v1/messages", chat_body({"max_tokens": 5}), extra=b"anthropic-version: 2023-06-01, x: y\r\n"), expect=400)
    case("an anthropic-beta header with a control byte", post("/v1/messages", chat_body({"max_tokens": 5}), extra=b"anthropic-beta: a\x01b\r\n"), expect={400, None})
    case("a query string trying to name another endpoint", b"GET /v1/files/job_1/a.png?sig=1&x=/../../internal/config HTTP/1.1\r\nHost: t\r\n\r\n", expect=400)
    case("a query string with an encoded line break", b"GET /v1/files/job_1/a.png?sig=1%0d%0ax-omnigate-internal:%20t HTTP/1.1\r\nHost: t\r\n\r\n", expect=400)

    hidden = b"GET /v1/models HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer " + ARGS.key.encode() + b"\r\n\r\n"
    case("a body on a GET is not read as the next request",
         b"GET /healthz HTTP/1.1\r\nHost: t\r\nContent-Length: " + str(len(hidden)).encode() + b"\r\n\r\n" + hidden, expect=400, check=one_response)
    case("content-length and chunked together", post("/v1/chat/completions", chat_body(), extra=b"Transfer-Encoding: chunked\r\n"), expect=400, check=one_response)
    body = chat_body().encode()
    case("two different content-lengths",
         b"POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer " + ARGS.key.encode() + b"\r\nContent-Length: " + str(len(body)).encode() +
         b"\r\nContent-Length: 5\r\n\r\n" + body, expect=400, check=one_response)
    case("an expectation other than 100-continue (std hung up without a word)",
         post("/v1/chat/completions", chat_body(), extra=b"Expect: a-miracle\r\n"), expect=417, check=one_response)
    case("an early error does not leave the unread body to be parsed as a request",
         b"POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer not-a-key\r\nContent-Length: " + str(len(hidden)).encode() + b"\r\n\r\n" + hidden,
         expect=401, check=one_response)
    big = b"x" * (9 * 1024 * 1024)
    case("an oversized body gets one 413 and the connection is closed, not re-read", post("/v1/chat/completions", big) + hidden,
         expect={413, None}, check=one_response, keep_reading=6)


def paths():
    section("one spelling per path")
    for path in ("/v1/jobs/", "//v1/jobs", "/v1//jobs", "/v1/./jobs", "/v1/jobs/../jobs", "/%76%31/jobs", "/v1/jobs%2f", "/v1/jobs/.", "/v1\\jobs", "/v1/jobs;x=1"):
        case(f"POST {path} is refused, not treated as a job request", post(path, '{"model":"m","input":{}}'), expect=400, forbid={200, 202})
    for path in ("/v1/chat/completions/", "/v1//chat/completions", "/v1/models/", "/v1/models/..", "/v1/files/a/../../jobs"):
        case(f"{path} is refused", post(path, chat_body()) if "chat" in path else
             b"GET " + path.encode() + b" HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer " + ARGS.key.encode() + b"\r\n\r\n", expect=400)
    if ARGS.rpm_key:
        codes = [status_of(exchange(post("/v1/jobs/", '{"model":"m","input":{}}', key=ARGS.rpm_key), keep_reading=3)[0]) for _ in range(12)]
        ok = all(c == 400 for c in codes)
        results.append(("the trailing-slash spelling cannot be used to create jobs past the rate limit", ok))
        print(f"  {'PASS' if ok else 'FAIL'}  the trailing-slash spelling cannot be used to create jobs past the rate limit" + ("" if ok else f"   [{codes}]"), flush=True)


def one_response(raw, status):
    return None if raw.count(b"HTTP/1.1 ") <= 1 else f"{raw.count(b'HTTP/1.1 ')} responses to one request: the body was read as a second request"


def second_review():
    section("second review: chunked request bodies, Expect, idempotency keys")
    body = chat_body().encode()
    head = (b"POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer " + ARGS.key.encode() +
            b"\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n")
    case("a chunked request body whose chunk size is sixteen F's (std's chunked reader overflowed)",
         head + b"FFFFFFFFFFFFFFFF\r\n" + body + b"\r\n0\r\n\r\n", expect=411, check=one_response)
    case("... seventeen F's", head + b"FFFFFFFFFFFFFFFFF\r\n" + body + b"\r\n0\r\n\r\n", expect=411, check=one_response)
    case("... and a well-formed chunked body is asked for a length as well",
         head + b"%x\r\n%s\r\n0\r\n\r\n" % (len(body), body), expect=411, check=one_response)
    case("... on a job request", b"POST /v1/jobs HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer " + ARGS.key.encode() +
         b"\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFF\r\n{}\r\n0\r\n\r\n", expect=411, check=one_response)

    def continued(raw, status):
        if b"HTTP/1.1 100 Continue\r\n\r\n" not in raw:
            return "no 100 Continue"
        return None if final_status(raw) == 200 else f"final status {final_status(raw)}"
    for spelling in (b"100-continue", b"100-Continue", b"100-CONTINUE"):
        case(f"Expect: {spelling.decode()} is honoured (other letter cases used to get no answer at all)",
             post("/v1/chat/completions", chat_body(), extra=b"Expect: " + spelling + b"\r\n"), expect=100, check=continued, read_timeout=5, keep_reading=8)
    case("... also when the request is refused before its body is read",
         b"POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer not-a-key\r\nContent-Length: 5\r\nExpect: 100-Continue\r\n\r\n",
         expect={100, 401}, check=lambda raw, status: None if final_status(raw) == 401 else f"final status {final_status(raw)}")

    idem = b"Idempotency-Key: dGhpcyBpcyBhIGtleQ+/aGk=\r\n"
    case("a base64 Idempotency-Key on chat completions is the client's business (it used to be a 400)",
         post("/v1/chat/completions", chat_body(), extra=idem), expect=200, read_timeout=5, keep_reading=8)
    case("... any bytes at all there, as long as the head is well-formed",
         post("/v1/chat/completions", chat_body(), extra=b"Idempotency-Key: a b;c \xc3\xa9\r\n"), expect=200, read_timeout=5, keep_reading=8)
    case("... and on a job request a base64 key is accepted",
         post("/v1/jobs", '{"model":"m","input":{}}', extra=idem), forbid={None, 500}, read_timeout=5, keep_reading=8,
         check=lambda raw, status: "refused for its idempotency key" if b"idempotency-key" in raw.lower() else None)


def limits_before_body():
    section("limits that apply before a body is read")
    host, port = host_port()

    def head_only(key, declared, model=None):
        return (b"POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer " + key.encode() +
                b"\r\nContent-Type: application/json\r\nContent-Length: " + str(declared).encode() + b"\r\n\r\n")

    def answer_without_body(key, declared, wait=3.0):
        """Send only a head that promises `declared` bytes; what comes back without sending any of them?"""
        s = socket.create_connection((host, port), timeout=5)
        try:
            s.sendall(head_only(key, declared))
            s.settimeout(wait)
            try:
                return s.recv(65536)
            except (socket.timeout, OSError):
                return b""
        finally:
            s.close()

    raw = answer_without_body(ARGS.key, 9 * 1024 * 1024)
    record("a body declared larger than the limit is refused (413) before any of it is sent", status_of(raw) == 413, raw[:120])

    if ARGS.rpm_key:
        # As many requests as the key may make in a minute (--rpm, 3 unless
        # told otherwise), none of which ever sends its body ...
        waiting = []
        for _ in range(ARGS.rpm):
            s = socket.create_connection((host, port), timeout=5)
            s.sendall(head_only(ARGS.rpm_key, 8_000_000))
            waiting.append(s)
        time.sleep(0.5)
        # ... and the next one is told no without the gateway reading eight megabytes first.
        started = time.time()
        raw = answer_without_body(ARGS.rpm_key, 8_000_000)
        took = time.time() - started
        record("a key over its rate limit is refused (429) before its body is read",
               status_of(raw) == 429 and b"rate_limit_exceeded" in raw and took < 2.5, (status_of(raw), round(took, 1), raw[-160:]))
        for s in waiting:
            s.close()

    cap = ARGS.concurrency_cap
    if cap:
        # `cap` requests in flight (each stuck sending its body) ...
        waiting = []
        for _ in range(cap):
            s = socket.create_connection((host, port), timeout=5)
            s.sendall(head_only(ARGS.key, 1000) + b'{"model":"')
            waiting.append(s)
        time.sleep(0.6)
        raw, _ = exchange(post("/v1/chat/completions", chat_body()), read_timeout=3, keep_reading=5)
        record(f"with {cap} requests in flight the key's next one is refused (429 concurrency_limit_exceeded, retry-after)",
               status_of(raw) == 429 and b"concurrency_limit_exceeded" in raw and b"retry-after: 1" in raw.lower(), (status_of(raw), (raw or b"")[-200:]))
        raw, _ = exchange(b"GET /v1/models HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer " + ARGS.key.encode() + b"\r\n\r\n", read_timeout=3, keep_reading=5)
        record("... reading (the model list) is not counted", status_of(raw) == 200, status_of(raw))
        if ARGS.other_key:
            raw, _ = exchange(post("/v1/chat/completions", chat_body(), key=ARGS.other_key), read_timeout=5, keep_reading=8)
            record("... and another key is unaffected", status_of(raw) == 200, status_of(raw))
        for s in waiting:
            s.close()
        ok = False
        for _ in range(20):
            time.sleep(0.25)
            raw, _ = exchange(post("/v1/chat/completions", chat_body()), read_timeout=5, keep_reading=8)
            if status_of(raw) == 200:
                ok = True
                break
        record("... once they are gone the key is served again", ok, status_of(raw))
    if not alive():
        print("the gateway stopped answering")
        sys.exit(1)


def expensive_bodies():
    section("bodies that are cheap to send and used to be expensive to parse")
    served = {"read_timeout": 30, "keep_reading": 40}

    def big(model, filler):
        prefix = '{"model":"%s","messages":[{"role":"user","content":"hi"}],"max_tokens":16,"x":' % model
        return prefix + filler + "}"

    zeros = "[" + "0," * (4 * 1024 * 1024 - 64) + "0]"  # just under 8 MiB of text; a tree of it took 2.3 GB
    case("8 MiB of tiny values, same protocol: forwarded as it is, no tree built",
         post("/v1/chat/completions", big(ARGS.model, zeros)), expect=200, **served)
    many = "{" + ",".join('"k%d":0' % i for i in range(70_000)) + "}"
    case("an object with 70,000 members is refused outright",
         post("/v1/chat/completions", big(ARGS.model, many)), expect=400, read_timeout=10, keep_reading=15)
    some = "{" + ",".join('"k%d":0' % i for i in range(2_000)) + "}"
    case("an object with 2,000 members is fine when nothing has to parse it",
         post("/v1/chat/completions", big(ARGS.model, some)), expect=200, **served)
    case("a `model` written with an escaped slash still routes",
         post("/v1/chat/completions", '{"model":"no\\/such","messages":[]}'), expect=404, read_timeout=5, keep_reading=8)
    case("`model` given twice is refused (parsers disagree on which one counts)",
         post("/v1/chat/completions", '{"model":"%s","messages":[],"model":"other"}' % ARGS.model), expect=400)
    case("`model` spelled with an escape is refused",
         post("/v1/chat/completions", '{"mod\\u0065l":"%s","messages":[]}' % ARGS.model), expect=400)
    if ARGS.translated_model:
        def too_complex(raw, status):
            return None if b"request_too_complex" in raw else "not refused as too complex"
        started = time.time()
        case("8 MiB of tiny values to a model of the other protocol: refused (400), the tree is never completed",
             post("/v1/chat/completions", big(ARGS.translated_model, zeros)), expect=400, check=too_complex, read_timeout=30, keep_reading=40)
        took = time.time() - started
        record("... within a few seconds", took < 8, round(took, 1))
        case("an object with 2,000 members to a model of the other protocol: refused (hash collisions are bounded by count)",
             post("/v1/chat/completions", big(ARGS.translated_model, some)), expect=400, check=too_complex, read_timeout=10, keep_reading=15)
        ordinary = "{" + ",".join('"k%d":{"a":[1,2,3],"b":"text"}' % i for i in range(900)) + "}"
        case("an ordinary large request to a model of the other protocol is still translated",
             post("/v1/chat/completions", big(ARGS.translated_model, ordinary)), expect=200, **served)
        image = '[{"type":"text","text":"%s"}]' % ("A" * (8 * 1024 * 1024 - 400))
        case("... and so is one of the largest size there is (8 MiB), mostly one long string",
             post("/v1/chat/completions", '{"model":"%s","max_tokens":16,"messages":[{"role":"user","content":%s}]}' % (ARGS.translated_model, image)),
             expect=200, **served)


def hostile_upstream():
    section("an upstream that answers like an attacker")
    def ask(model, stream=False):
        return post("/v1/chat/completions", json.dumps({"model": model, "stream": stream, "messages": [{"role": "user", "content": "hi"}]}))

    def cut_short(raw, status):
        if b"0\r\n\r\n" in raw[-7:]:
            return "the response was ended properly, as if it were complete"
        return None

    def no_injection(raw, status):
        return "the smuggled header reached the client" if b"x-injected" in raw.lower() else None

    case("a chunk size of sixteen F's in a JSON answer (std's reader overflowed): a failed upstream, 502",
         ask("hostile-chunk-json"), expect=502, read_timeout=5, keep_reading=8)
    case("... of seventeen F's", ask("hostile-chunk17"), expect=502, read_timeout=5, keep_reading=8)
    case("... in the middle of a stream: the client's stream is cut, never ended as if complete",
         ask("hostile-chunk-sse", stream=True), expect=200, check=cut_short, read_timeout=3, keep_reading=6)
    case("a JSON answer shorter than its content-length, then a clean close (std asserted): 502, not half an answer",
         ask("hostile-short-json"), expect=502, read_timeout=5, keep_reading=8)
    case("... a stream shorter than its content-length: cut, not ended",
         ask("hostile-short-sse", stream=True), expect=200, check=cut_short, read_timeout=3, keep_reading=6)
    case("both content-length and transfer-encoding: refused, 502", ask("hostile-both"), expect=502, read_timeout=5, keep_reading=8)
    case("a content-type with a bare line feed carrying another header: 502, and the header goes nowhere",
         ask("hostile-ctype"), expect=502, check=no_injection, read_timeout=5, keep_reading=8)

    case("an interim status (103) presented as the final answer: 502", ask("hostile-status"), expect=502, read_timeout=5, keep_reading=8)

    def whole(raw, status):
        body = body_of(raw)
        if body is None:
            return "the body is not whole"
        try:
            text = json.loads(body)["choices"][0]["message"]["content"]
        except (ValueError, KeyError, IndexError, TypeError):
            return "the body is not the JSON that was sent"
        if len(text) != 200_000:
            return f"{len(text)} characters of 200000"
        head = raw[:raw.find(b"\r\n\r\n")].lower()
        return None if b"transfer-encoding: chunked" in head and b"content-length" not in head else "the upstream's length was passed on"
    case("a long honest answer arrives whole, framed by the gateway and not with the upstream's length",
         ask("hostile-long"), expect=200, check=whole, read_timeout=10, keep_reading=15)

    def counted(raw, status):
        end = raw.find(b"\r\n\r\n")
        head = raw[:end].lower()
        for line in head.split(b"\r\n"):
            if line.startswith(b"content-length:"):
                return None if int(line.split(b":")[1]) == len(raw) - end - 4 else "content-length does not match the body"
        return "a short answer should carry a length"
    case("a short answer carries a length the gateway counted itself", ask(ARGS.model), expect=200, check=counted, read_timeout=5, keep_reading=8)

    # A 200 head and then silence, on an answer that is not a stream: nothing
    # has been sent to the client yet, so after the idle timeout the request
    # goes to the next upstream (or fails with a 502), and the connection it
    # came in on is as good as before.
    idle = ARGS.idle_s

    def timed(name, data, expect, check):
        started = time.time()

        def within(raw, status):
            took = time.time() - started
            if not idle - 0.5 <= took <= 2 * idle + 3:
                return f"answered after {took:.1f} s; the idle timeout is {idle:g} s"
            return check(raw, status)
        case(name, data, expect=expect, check=within, read_timeout=3 * idle + 5, keep_reading=3 * idle + 6)

    def second_upstream(raw, status):
        head = raw[:raw.find(b"\r\n\r\n")].lower()
        if b"x-omnigate-upstream: mock-ok" not in head or b"x-omnigate-attempts: 2" not in head:
            return "not answered by the second upstream on the second attempt"
        return None if b"Hello from the mock upstream." in raw else "not the second upstream's answer"
    timed("a 200 head and then no body: after the idle timeout the next upstream answers", ask("stall-body"), 200, second_upstream)
    timed("... the same when the answer would have been translated (an Anthropic client)",
          post("/v1/messages", json.dumps({"model": "stall-body", "max_tokens": 16, "messages": [{"role": "user", "content": "hi"}]})), 200,
          lambda raw, status: None if b"Hello from the mock upstream." in raw and b'"type":"message"' in raw else "not a translated answer")
    timed("... and with no other upstream: 502, with the timeout named among the attempts", ask("stall-body-only"), 502,
          lambda raw, status: None if b"all_upstreams_failed" in raw and b"StreamIdleTimeout" in raw else "not the gateway's 502 for a silent upstream")

    # The same connection goes on to serve the next request: the timeout did
    # not end (or wound) the task that serves it.
    s = socket.create_connection(host_port(), timeout=5)
    try:
        s.settimeout(3 * idle + 5)
        answers = []
        for data in (ask("stall-body-only"), ask(ARGS.model)):
            s.sendall(data)
            got = b""
            while not complete(got):
                more = s.recv(65536)
                if not more:
                    break
                got += more
            answers.append(status_of(got))
    except OSError as e:
        answers.append(str(e))
    finally:
        s.close()
    record("after such a 502 the same keep-alive connection serves the next request", answers == [502, 200], answers)


def own_answers_stall():
    """A client that sends requests and never reads the answers. The answers
    here are the gateway's own (the model list), which used to be written
    under the long idle timeout instead of the stall timeout."""
    section("a client that takes none of the gateway's own answers")
    request = b"GET /v1/models HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer " + ARGS.key.encode() + b"\r\n\r\n"
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    s.settimeout(5)
    s.connect(host_port())
    s.settimeout(0.2)
    batch = request * 200
    started = time.time()
    ended = None
    try:
        while time.time() - started < ARGS.idle_s + 6:
            try:
                s.sendall(batch)
            except socket.timeout:
                continue  # every buffer is full: the gateway has stopped reading, as it should
            except OSError:
                ended = time.time() - started
                break
    finally:
        s.close()
    # The stall timeout plus the time it takes to fill the buffers; well
    # short of the idle timeout, which is what applied before.
    limit = ARGS.client_stall_s + 2.0
    record(f"the connection is dropped after the client stall timeout ({ARGS.client_stall_s:g} s), not the idle timeout ({ARGS.idle_s:g} s)",
           ended is not None and ended < min(limit, ARGS.idle_s - 0.4), f"dropped after {ended}" if ended else "never dropped")
    if not alive():
        print("the gateway stopped answering")
        sys.exit(1)


# --------------------------------------------------------------------------
# a hostile control plane: a stand-in here, and a second gateway that uses it

STANDIN_PORT = 4300
SECOND_GATEWAY_PORT = 8190
STANDIN_KEY = "og-standin-key"
STANDIN_TOKEN = "standin-internal-token"
STANDIN = {"config_mode": "ok"}


class StandIn(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def raw(self, data):
        self.wfile.write(data)
        self.wfile.flush()
        self.close_connection = True

    def good(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def hostile(self, mode):
        ok = json.dumps({"id": "job_1", "status": "succeeded"}).encode()
        if mode == "chunk":
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFF\r\n" + ok + b"\r\n0\r\n\r\n")
        if mode == "short":
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 500\r\n\r\n" + ok[:10])
        if mode == "both":
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: %d\r\ntransfer-encoding: chunked\r\n\r\n%x\r\n%s\r\n0\r\n\r\n" % (len(ok), len(ok), ok))
        if mode == "ctype":
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\nx-injected: 1\r\ncontent-length: %d\r\n\r\n" % len(ok) + ok)
        if mode == "long":
            data = b"\x89PNG" + b"p" * 300_000
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: image/png\r\ncontent-length: %d\r\n\r\n" % len(data) + data)
        if mode == "longshort":
            return self.raw(b"HTTP/1.1 200 OK\r\ncontent-type: image/png\r\ncontent-length: 300000\r\n\r\n" + b"p" * 100_000)
        if mode == "stall":
            # The head of a job, and then nothing until the gateway hangs up.
            self.wfile.write(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 30\r\n\r\n")
            self.wfile.flush()
            deadline = time.time() + 30
            while time.time() < deadline and not select.select([self.connection], [], [], 0.5)[0]:
                pass
            self.close_connection = True
            return
        return self.good(200, {"id": "job_1", "status": "succeeded"})

    def do_GET(self):
        if self.path == "/internal/config":
            if STANDIN["config_mode"] != "ok":
                return self.hostile(STANDIN["config_mode"])
            return self.good(200, {
                "version": "standin-1",
                "keys": [{"key_sha256": hashlib.sha256(STANDIN_KEY.encode()).hexdigest(), "name": "standin"}],
                # One route, to the mock that sends the head of an answer and then nothing (tools/mock_upstream.py).
                "upstreams": [{"name": "silent", "kind": "openai", "base_url": "http://127.0.0.1:9005", "api_key_env": "MOCK_API_KEY"}],
                "routes": [{"model": "stall-body", "targets": [{"upstream": "silent", "model": "stall-body-1"}]}],
            })
        if self.path.startswith("/internal/v1/jobs/"):
            return self.hostile(self.path.rsplit("/", 1)[1])
        self.good(200, {})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        self.good(200, {"accepted": 0})


def hostile_control(stack):
    global TARGET
    section("a control plane that answers like an attacker (stand-in on :%d, second gateway on :%d)" % (STANDIN_PORT, SECOND_GATEWAY_PORT))
    server = ThreadingHTTPServer(("127.0.0.1", STANDIN_PORT), StandIn)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    exe = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "dataplane", "zig-out", "bin",
                       "omnigate-dp" + (".exe" if os.name == "nt" else ""))
    work = os.path.join(stack.work, "second")
    os.makedirs(work, exist_ok=True)
    stack.start("gateway2", [exe], cwd=work, env={
        "OMNIGATE_LISTEN": f"127.0.0.1:{SECOND_GATEWAY_PORT}", "OMNIGATE_CONTROL_URL": f"http://127.0.0.1:{STANDIN_PORT}",
        "OMNIGATE_INTERNAL_TOKEN": STANDIN_TOKEN, "OMNIGATE_POLL_MS": "200", "OMNIGATE_FLUSH_MS": "200",
        "OMNIGATE_SPOOL": "off", "OMNIGATE_CONFIG_CACHE": "off",
        # Short, for the control plane that sends a head and no body, and for
        # the check after it that deadlines are still being enforced.
        "OMNIGATE_STREAM_IDLE_TIMEOUT_MS": "2000", "OMNIGATE_CLIENT_TIMEOUT_MS": "3000",
    })
    TARGET = ("127.0.0.1", SECOND_GATEWAY_PORT)
    try:
        models = b"GET /v1/models HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer " + STANDIN_KEY.encode() + b"\r\n\r\n"
        ready = False
        for _ in range(60):
            raw, _ = exchange(models, read_timeout=1, keep_reading=2)
            if status_of(raw) == 200:
                ready = True
                break
            time.sleep(0.25)
        if not record("the second gateway took its config from the stand-in", ready):
            return

        def job(mode):
            return b"GET /v1/jobs/" + mode.encode() + b" HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer " + STANDIN_KEY.encode() + b"\r\n\r\n"

        def no_injection(raw, status):
            return "the smuggled header reached the client" if b"x-injected" in raw.lower() else None

        def cut_short(raw, status):
            return "the response was ended properly, as if it were complete" if b"0\r\n\r\n" in raw[-7:] else None

        def whole_file(raw, status):
            body = body_of(raw)
            if body is None or len(body) != 300_004:
                return "the file did not arrive whole"
            head = raw[:raw.find(b"\r\n\r\n")].lower()
            return None if b"content-length: 300004" in head and b"transfer-encoding" not in head else "the file lost its content-length"

        def cut_file(raw, status):
            end = raw.find(b"\r\n\r\n")
            if b"content-length: 300000" not in raw[:end].lower():
                return "the declared length was not passed on"
            return None if len(raw) - end - 4 < 300_000 else "more arrived than the control plane sent"

        case("an honest job answer is relayed, with a length the gateway counted", job("fine"), expect=200, read_timeout=5, keep_reading=8,
             check=lambda raw, status: None if b"content-length: " in raw.lower() and b'"job_1"' in raw else "not relayed as it was")
        case("a chunk size of sixteen F's from the control plane: 502", job("chunk"), expect=502, read_timeout=5, keep_reading=8)
        case("an answer shorter than its content-length: 502, not half an answer", job("short"), expect=502, read_timeout=5, keep_reading=8)
        case("both framings: 502", job("both"), expect=502, read_timeout=5, keep_reading=8)
        case("a content-type that smuggles a header: 502, and the header goes nowhere", job("ctype"), expect=502, check=no_injection, read_timeout=5, keep_reading=8)
        case("a long honest answer (a file) arrives whole, with the control plane's content-length and not chunked",
             job("long"), expect=200, check=whole_file, read_timeout=10, keep_reading=15)
        case("a long answer cut short by the control plane is cut for the client too: fewer bytes than the length promised",
             job("longshort"), expect=200, check=cut_file, read_timeout=3, keep_reading=6)

        def silent_peer(what, request):
            """`request` is answered by a peer that sends a head and then nothing. The connection it came
            in on is kept open afterwards, and a second client checks that deadlines are still enforced:
            before the close-out commit the watchdog cancelled the first connection's task, waited for it
            for as long as that connection stayed open, and served nobody else in the meantime."""
            a = socket.create_connection(TARGET, timeout=5)
            try:
                a.settimeout(9)
                started = time.time()
                a.sendall(request)
                got = b""
                try:
                    while not complete(got):
                        more = a.recv(65536)
                        if not more:
                            break
                        got += more
                except OSError:
                    pass
                took = time.time() - started
                record(f"a head and then no body from {what}: 502 after the idle timeout (2 s here)",
                       status_of(got) == 502 and 1.5 <= took <= 7, (status_of(got), round(took, 1), got[-160:]))
                b = socket.create_connection(TARGET, timeout=5)
                try:
                    b.sendall(b"GET /v1/models HTTP/1.1\r\nHost: t\r\n")
                    b.settimeout(8)
                    started = time.time()
                    try:
                        b.recv(4096)
                        dropped = time.time() - started
                    except socket.timeout:
                        dropped = None
                    except OSError:
                        dropped = time.time() - started
                finally:
                    b.close()
                record("... and while that connection stays open the gateway goes on enforcing deadlines "
                       "(a client that sends half a head is dropped at the client timeout, 3 s here)",
                       dropped is not None and 2.0 <= dropped <= 6.5, dropped)
            finally:
                a.close()
            if not alive():
                print("the gateway stopped answering")
                sys.exit(1)

        silent_peer("the control plane", job("stall"))
        silent_peer("an upstream", post("/v1/chat/completions", json.dumps({"model": "stall-body", "messages": [{"role": "user", "content": "hi"}]}),
                                         key=STANDIN_KEY))

        # The config poll itself (every 200 ms) gets the same treatment.
        for mode in ("chunk", "short", "both"):
            STANDIN["config_mode"] = mode
            time.sleep(0.9)
            raw, _ = exchange(models, read_timeout=2, keep_reading=3)
            record(f"a config poll answered with '{mode}' is a failed poll: the gateway keeps its config and keeps serving",
                   alive() and status_of(raw) == 200, status_of(raw))
        STANDIN["config_mode"] = "ok"
    finally:
        TARGET = None
        stack.stop("gateway2")
        server.shutdown()
        server.server_close()


def healthcheck_command():
    section("the healthcheck subcommand")
    exe = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "dataplane", "zig-out", "bin",
                       "omnigate-dp" + (".exe" if os.name == "nt" else ""))

    def run_it(listen, *args):
        env = dict(os.environ, OMNIGATE_LISTEN=listen)
        started = time.time()
        code = subprocess.run([exe, *args], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20).returncode
        return code, time.time() - started
    code, took = run_it(ARGS.gateway, "healthcheck")
    record("exit 0 against a gateway that answers", code == 0 and took < 3, (code, round(took, 1)))
    code, took = run_it("127.0.0.1:1", "healthcheck")
    record("exit 1 when nothing listens", code == 1 and took < 5, (code, round(took, 1)))
    # Something that accepts and then says nothing: the check gives up by itself.
    silent = socket.socket()
    silent.bind(("127.0.0.1", 0))
    silent.listen(4)
    code, took = run_it("127.0.0.1:%d" % silent.getsockname()[1], "healthcheck")
    silent.close()
    record("exit 1, after about three seconds, when the listener never answers", code == 1 and 2 < took < 8, (code, round(took, 1)))
    code, took = run_it(ARGS.gateway, "no-such-command")
    record("an unknown subcommand is an error, not a second server", code == 2, code)


BASES = None


def mutate(rng, data):
    """One random way of breaking a request."""
    data = bytearray(data)
    head_end = data.find(b"\r\n\r\n")
    head_end = len(data) if head_end < 0 else head_end
    kind = rng.randrange(16)
    pos = rng.randrange(max(1, head_end + 4))
    junk = [b"\r", b"\n", b"\x00", b" ", b":", b"\t", b"\xff", b"\x7f", b"\x0b", b"%00", b"\r\n", b"\n\n"]
    if kind == 0 and data:
        del data[min(pos, len(data) - 1)]
    elif kind == 1:
        data[pos:pos] = rng.choice(junk)
    elif kind == 2:
        data = bytearray(bytes(data).replace(b"\r\n", b"\n", rng.randrange(1, 4)))
    elif kind == 3:
        data = data[:pos]
    elif kind == 4:
        data[head_end:head_end] = b"\r\nX-Big: " + b"a" * rng.choice([100, 5000, 17000, 70000])
    elif kind == 5:
        data[head_end:head_end] = b"\r\n" + rng.choice([b"nocolon", b": novalue", b" folded: x", b"a b: c", b"", b"\x00: x", b"x:\x00"])
    elif kind == 6:
        data[head_end:head_end] = b"".join(b"\r\nx-%d: %d" % (i, i) for i in range(rng.choice([50, 101, 400])))
    elif kind == 7:
        data[head_end:head_end] = b"\r\nContent-Length: " + rng.choice([b"-1", b"+5", b"0x10", b"1e3", b"99999999999999999999999", b"5, 5", b"", b" ", b"5\x00", b"18446744073709551615"])
    elif kind == 8:
        data[head_end:head_end] = b"\r\nTransfer-Encoding: " + rng.choice([b"chunked", b"gzip", b"chunked, chunked", b"identity", b"xchunked", b"CHUNKED", b" chunked ", b"chunked\x00"])
    elif kind == 9:
        line_end = data.find(b"\r\n")
        data[:line_end] = rng.choice([b"GET", b"GET /", b"GET / HTTP/9.9", b"GET / HTTP/1.1 x", b" / HTTP/1.1", b"G\x00T / HTTP/1.1", b"GET http://a/ HTTP/1.1", b"GET * HTTP/1.1",
                                      b"POST /v1/chat/completions HTTP/1.0", b"CONNECT a:1 HTTP/1.1", b"GET /" + b"a" * 20000 + b" HTTP/1.1", b"\r\n", b"\x16\x03\x01\x02\x00\x01"])
    elif kind == 10:
        data[head_end:head_end] = b"\r\nExpect: " + rng.choice([b"100-continue", b"200-ok", b""])
    elif kind == 11:
        for _ in range(rng.randrange(1, 6)):
            p = rng.randrange(len(data))
            data[p] = rng.randrange(256)
    elif kind == 12:
        data[head_end:head_end] = b"\r\nHost: a\r\nHost: b\r\nAuthorization: Bearer x\r\nAuthorization: Bearer y"
    elif kind == 13:
        data = data + bytes(data)  # pipelined copy
    elif kind == 14:
        data[head_end:head_end] = b"\r\nConnection: " + rng.choice([b"close", b"keep-alive, upgrade", b"Upgrade\r\nUpgrade: websocket"])
    else:
        body = rng.choice([b"", b"{", b"[1,2", b'{"model":1}', b'{"model":"' + ARGS.model.encode() + b'","messages":"x","stream":"yes","stream_options":7}', b"\xff\xfe\x00", b"null", b'"x"'])
        data = bytearray(post(rng.choice(["/v1/chat/completions", "/v1/messages", "/v1/embeddings", "/v1/responses", "/v1/messages/count_tokens", "/v1/jobs"]), body))
    return bytes(data)


def generated(rng, count):
    section(f"{count} generated malformed requests (seed {ARGS.seed})")
    bases = [
        b"GET /healthz HTTP/1.1\r\nHost: t\r\n\r\n",
        b"GET /v1/models HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer " + ARGS.key.encode() + b"\r\n\r\n",
        post("/v1/chat/completions", chat_body()),
        post("/v1/chat/completions", chat_body({"stream": True})),
        post("/v1/messages", chat_body({"max_tokens": 16}), extra=b"anthropic-version: 2023-06-01\r\n"),
        post("/v1/jobs", '{"model":"m","input":{"prompt":"x"}}', extra=b"Idempotency-Key: abc\r\n"),
        b"GET /v1/files/job_1/out-0.png?exp=1&sig=00 HTTP/1.1\r\nHost: t\r\n\r\n",
    ]
    before = len([1 for _, ok in results if not ok])
    for i in range(count):
        data = rng.choice(bases)
        for _ in range(rng.randrange(1, 4)):
            data = mutate(rng, data)
        chunks = None
        if rng.random() < 0.2 and len(data) > 4:
            cut = sorted(rng.sample(range(1, len(data)), min(3, len(data) - 1)))
            chunks = [data[a:b] for a, b in zip([0] + cut, cut + [len(data)])]
        # Any answer or none is acceptable; a 5xx other than "upstream failed"/"not ready" is not.
        case(f"generated #{i}", data, forbid={500}, chunks=chunks, read_timeout=0.25, keep_reading=0.8)
    failed = len([1 for _, ok in results if not ok]) - before
    print(f"  {count - failed}/{count} survived without a 500", flush=True)


def events():
    """Recent usage events as dicts with id, input_tokens, output_tokens, estimated."""
    if OVERVIEW:
        url, token = OVERVIEW
        req = urllib.request.Request(url, headers={"authorization": "Bearer " + token})
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.load(r).get("requests", [])
    with urllib.request.urlopen(ARGS.events_url, timeout=5) as r:
        return json.load(r)


OWN_CONCURRENCY_CAP = 8


def start_own_stack():
    """Mocks, control plane and gateway through the end-to-end harness. Returns the stack to stop."""
    global OVERVIEW
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import e2e

    config = e2e.text_config()
    price = {"price_in_per_mtok": 100.0, "price_out_per_mtok": 300.0}
    # The mock on :9005 starts a stream and then either goes on for ever
    # without reporting usage (model names starting with "drip") or goes silent.
    config["upstreams"].append({"name": "mock-stall", "kind": "openai", "base_url": "http://127.0.0.1:9005", "api_key_env": "MOCK_API_KEY"})
    for name in ("drip", "stall", "late-usage", "flood", "hostile-chunk-json", "hostile-chunk-sse", "hostile-chunk17",
                 "hostile-short-json", "hostile-short-sse", "hostile-both", "hostile-ctype", "hostile-status", "hostile-long"):
        config["routes"].append({"model": name, "targets": [dict(upstream="mock-stall", model=name + "-1", **price)]})
    # An upstream that sends the head of a JSON answer and then nothing: alone, and in front of one that works.
    # (Under names of their own: the hostile answers above put "mock-stall" into its cooldown, where it would be tried last.)
    for name in ("mock-silent-a", "mock-silent-b"):
        config["upstreams"].append({"name": name, "kind": "openai", "base_url": "http://127.0.0.1:9005", "api_key_env": "MOCK_API_KEY"})
    config["routes"].append({"model": "stall-body-only", "targets": [dict(upstream="mock-silent-a", model="stall-body-1", **price)]})
    config["routes"].append({"model": "stall-body", "targets": [dict(upstream="mock-silent-b", model="stall-body-1", **price),
                                                               dict(upstream="mock-ok", model="ok-1", **price)]})

    work = tempfile.mkdtemp(prefix="omnigate-malformed-")
    stack = e2e.Stack(work, config, False)
    # Short enough that the "estimated" cases finish within the default wait
    # (and long enough for the provider that reports late); a small cap on
    # concurrent requests, so that reaching it takes a handful of sockets.
    stack.gateway_env = {"OMNIGATE_STREAM_IDLE_TIMEOUT_MS": "4000", "OMNIGATE_ABORT_DRAIN_MS": "5000",
                         "OMNIGATE_CLIENT_STALL_TIMEOUT_MS": "1500", "OMNIGATE_MAX_CONCURRENT_PER_KEY": str(OWN_CONCURRENCY_CAP)}
    stack.start_mocks()
    stack.start_control()
    stack.start_gateway()
    if not e2e.wait_until(lambda: e2e.call("GET", e2e.GATEWAY + "/v1/models", key=e2e.KEY_MAIN)[0] == 200, 15):
        stack.fail("gateway never received its config from the control plane", "gateway")

    ARGS.gateway = f"127.0.0.1:{e2e.GATEWAY_PORT}"
    ARGS.key, ARGS.model, ARGS.rpm_key = e2e.KEY_MAIN, "direct", e2e.KEY_RPM
    ARGS.other_key, ARGS.translated_model, ARGS.concurrency_cap = e2e.KEY_OTHER, "claude", OWN_CONCURRENCY_CAP
    ARGS.drip_model, ARGS.stall_model, ARGS.late_model, ARGS.flood_model = "drip", "stall", "late-usage", "flood"
    ARGS.idle_s, ARGS.client_stall_s = 4.0, 1.5  # the two timeouts set above
    OVERVIEW = (e2e.CONTROL + "/admin/overview", e2e.ADMIN_TOKEN)
    return stack, work


def billing_on_disconnect():
    section("a client that hangs up mid-stream is still billed")
    host, port = host_port()

    def start_and_leave(model):
        s = socket.create_connection((host, port), timeout=5)
        s.sendall(post("/v1/chat/completions", json.dumps({"model": model, "stream": True, "messages": [{"role": "user", "content": "hi"}]})))
        s.settimeout(5)
        got = b""
        while b"data:" not in got:
            more = s.recv(4096)
            if not more:
                break
            got += more
        rid = None
        for line in got.split(b"\r\n"):
            if line.lower().startswith(b"x-omnigate-request-id:"):
                rid = line.split(b":", 1)[1].strip().decode()
        # Hang up for real: a reset, as a client that crashed would.
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
        s.close()
        return rid

    def event_for(rid, wait):
        end = time.time() + wait
        while time.time() < end:
            for e in events():
                if e.get("id") == rid:
                    return e
            time.sleep(0.3)
        return None

    rid = start_and_leave(ARGS.model)
    e = event_for(rid, 10) or {}
    ok = e.get("output_tokens", 0) > 0 and e.get("input_tokens", 0) > 0 and not e.get("estimated")
    results.append(("left after the first chunk of a normal stream: billed the provider's real figures", ok))
    print(f"  {'PASS' if ok else 'FAIL'}  left after the first chunk of a normal stream: billed the provider's real figures" + ("" if ok else f"   [{e}]"), flush=True)

    def estimated_case(model, name):
        rid = start_and_leave(model)
        e = event_for(rid, ARGS.drain_wait) or {}
        ok = e.get("estimated") is True and e.get("output_tokens", 0) > 0 and e.get("input_tokens", 0) > 0
        results.append((name, ok))
        print(f"  {'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f"   [{e}]"), flush=True)

    if ARGS.late_model:
        # The provider goes on for 2.5 s after we left, then says what it cost.
        rid = start_and_leave(ARGS.late_model)
        e = event_for(rid, ARGS.drain_wait) or {}
        ok = e.get("output_tokens") == 34 and e.get("input_tokens") == 21 and not e.get("estimated")
        record("left a stream whose provider reports usage seconds later: read to its end, billed the provider's real figures", ok, e)

    if ARGS.flood_model:
        # Stay connected, read the start, then take nothing more: the kernel
        # buffers fill, the gateway's write stalls, and after the stall
        # timeout the answer is read on without us.
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        s.settimeout(5)
        s.connect((host, port))
        s.sendall(post("/v1/chat/completions", json.dumps({"model": ARGS.flood_model, "stream": True, "messages": [{"role": "user", "content": "hi"}]})))
        got = b""
        while b"data:" not in got:
            more = s.recv(2048)
            if not more:
                break
            got += more
        rid = None
        for line in got.split(b"\r\n"):
            if line.lower().startswith(b"x-omnigate-request-id:"):
                rid = line.split(b":", 1)[1].strip().decode()
        e = event_for(rid, ARGS.drain_wait) or {}
        s.close()
        ok = e.get("output_tokens") == 4242 and e.get("input_tokens") == 55 and not e.get("estimated")
        record("stopped reading without hanging up: given up on after the stall timeout, the answer read to its end, billed the real figures", ok, e)

    if ARGS.drip_model:
        estimated_case(ARGS.drip_model, "left a stream that goes on without ever reporting usage: billed an estimate, marked as one")
    if ARGS.stall_model:
        estimated_case(ARGS.stall_model, "left a stream that then went silent: billed an estimate when the idle timeout ends it")
    if not alive():
        print("the gateway stopped answering")
        sys.exit(1)


def main():
    global ARGS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gateway", help="host:port of a data plane you started; without it the script starts its own stack")
    ap.add_argument("--key", help="a valid gateway key (with --gateway)")
    ap.add_argument("--model", help="a text route that key may use (with --gateway)")
    ap.add_argument("--rpm-key", help="a rate-limited key, to check the trailing-slash bypass and the limit before the body")
    ap.add_argument("--rpm", type=int, default=3, help="the requests per minute --rpm-key allows (default 3; the dev config's og-ratelimited-key allows 5)")
    ap.add_argument("--other-key", help="a second valid key, to check that one key's concurrency cap leaves others alone")
    ap.add_argument("--concurrency-cap", type=int, default=0, help="the instance's OMNIGATE_MAX_CONCURRENT_PER_KEY, if it is small enough to reach with sockets")
    ap.add_argument("--translated-model", help="a chat route served by an Anthropic-style upstream (so the request is translated)")
    ap.add_argument("--late-model", help="a route whose upstream finishes its stream and reports usage whoever is listening")
    ap.add_argument("--flood-model", help="a route whose upstream sends megabytes of stream at once, then usage (prompt 55, completion 4242)")
    ap.add_argument("--seed", type=int, default=20261110)
    ap.add_argument("--count", type=int, default=None, help="generated cases (default 250, or 1500 with --thorough)")
    ap.add_argument("--thorough", action="store_true", help="many more generated cases; takes several minutes")
    ap.add_argument("--events-url", help="URL listing the usage events a stand-in control plane received")
    ap.add_argument("--drip-model", help="a route whose upstream streams on and on without ever reporting usage "
                                         "(the gateway reads on for OMNIGATE_ABORT_DRAIN_MS, then estimates)")
    ap.add_argument("--stall-model", help="a route whose upstream starts a stream and then goes silent (the gateway "
                                          "notices at OMNIGATE_STREAM_IDLE_TIMEOUT_MS: start it with a short one)")
    ap.add_argument("--drain-wait", type=float, default=15, help="seconds to wait for the estimated event")
    ap.add_argument("--verbose", action="store_true")
    ARGS = ap.parse_args()
    if ARGS.count is None:
        ARGS.count = 1500 if ARGS.thorough else 250

    stack = work = None
    if ARGS.gateway is None:
        ARGS.late_model = ARGS.flood_model = None
        stack, work = start_own_stack()
    elif not (ARGS.key and ARGS.model):
        ap.error("--gateway needs --key and --model")
    good = False
    try:
        good = run(stack)
    finally:
        if stack:
            stack.stop_all()
            if good_enough_to_clean(stack):
                shutil.rmtree(work, ignore_errors=True)
    sys.exit(0 if good else 1)


def good_enough_to_clean(stack):
    """Keep the logs when something failed, so the gateway's last words can be read."""
    failed = [name for name, ok in results if not ok]
    if failed:
        print(f"logs kept in {stack.work}")
    return not failed


def run(stack=None):
    if not alive():
        raise SystemExit(f"nothing answers /healthz at {ARGS.gateway}")
    raw, _ = exchange(post("/v1/chat/completions", chat_body()), read_timeout=5, keep_reading=8)
    if status_of(raw) != 200:
        raise SystemExit(f"a plain request with --key/--model does not work ({status_of(raw)}): fix that first\n{(raw or b'')[:300]!r}")

    started = time.time()
    known_crashers()
    smuggling()
    second_review()
    paths()
    expensive_bodies()
    generated(random.Random(ARGS.seed), ARGS.count)
    limits_before_body()
    if stack:
        hostile_upstream()
        own_answers_stall()
        hostile_control(stack)
        healthcheck_command()
    if ARGS.events_url or OVERVIEW:
        billing_on_disconnect()

    raw, _ = exchange(post("/v1/chat/completions", chat_body()), read_timeout=5, keep_reading=8)
    ok = status_of(raw) == 200
    results.append(("after all of that, a normal request still works", ok))
    print(f"\n  {'PASS' if ok else 'FAIL'}  after all of that, a normal request still works", flush=True)
    good = summary()
    print(f"({time.time() - started:.0f}s)")
    return good


if __name__ == "__main__":
    main()
