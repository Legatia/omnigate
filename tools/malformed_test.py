"""Hostile-input test for the gateway: malformed, ambiguous and oversized requests.

    python tools/malformed_test.py --gateway 127.0.0.1:8080 --key og-unlimited-key --model demo-direct

Sends, over raw sockets, every request from the security review that used to
crash the data plane or slip past a check, a few hundred generated variations
of broken request heads (seeded, so a failure can be replayed with --seed),
deeply nested JSON, request-smuggling attempts and non-canonical paths.

After EVERY case it asks /healthz on a fresh connection. A panic anywhere in
the gateway ends the whole process, so "still answering" is the property
under test; where a case has one right answer (400, 411, ...) that is checked
too. Exit code 0 only if the gateway survived everything and every expected
status matched.

Optional, with a stand-in control plane that lists the usage events it got
(--events-url): checks that a client which reads the start of a stream and
hangs up is still billed.

Standard library only. Point it at a test instance, never at production.
"""

import argparse
import json
import random
import socket
import sys
import time
import urllib.request

results = []
ARGS = None


def host_port():
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
    """Is this one whole response with a declared length? Then there is nothing more to wait for."""
    end = raw.find(b"\r\n\r\n")
    if end < 0:
        return False
    for line in raw[:end].split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length" and value.strip().isdigit():
            return len(raw) - end - 4 >= int(value.strip())
    return False


def status_of(raw):
    if not raw or not raw.startswith(b"HTTP/1."):
        return None
    try:
        return int(raw[9:12])
    except ValueError:
        return None


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

    def one_response(raw, status):
        return None if raw.count(b"HTTP/1.1 ") <= 1 else f"{raw.count(b'HTTP/1.1 ')} responses to one request: the body was read as a second request"
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
    with urllib.request.urlopen(ARGS.events_url, timeout=5) as r:
        return json.load(r)


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

    if ARGS.drip_model:
        estimated_case(ARGS.drip_model, "left a stream that goes on without ever reporting usage: billed an estimate, marked as one")
    if ARGS.stall_model:
        estimated_case(ARGS.stall_model, "left a stream that then went silent: billed an estimate when the idle timeout ends it")
    if not alive():
        print("the gateway stopped answering")
        sys.exit(1)


def main():
    global ARGS
    ap = argparse.ArgumentParser(description="Hostile-input test for the omnigate data plane.")
    ap.add_argument("--gateway", default="127.0.0.1:8080", help="host:port of the data plane")
    ap.add_argument("--key", required=True, help="a valid gateway key")
    ap.add_argument("--model", required=True, help="a text route that key may use")
    ap.add_argument("--rpm-key", help="a rate-limited key, to check the trailing-slash bypass")
    ap.add_argument("--seed", type=int, default=20261110)
    ap.add_argument("--count", type=int, default=400, help="generated cases")
    ap.add_argument("--events-url", help="URL listing the usage events a stand-in control plane received")
    ap.add_argument("--drip-model", help="a route whose upstream streams on and on without ever reporting usage "
                                         "(the gateway reads on for OMNIGATE_ABORT_DRAIN_MS, then estimates)")
    ap.add_argument("--stall-model", help="a route whose upstream starts a stream and then goes silent (the gateway "
                                          "notices at OMNIGATE_STREAM_IDLE_TIMEOUT_MS: start it with a short one)")
    ap.add_argument("--drain-wait", type=float, default=15, help="seconds to wait for the estimated event")
    ap.add_argument("--verbose", action="store_true")
    ARGS = ap.parse_args()

    if not alive():
        raise SystemExit(f"nothing answers /healthz at {ARGS.gateway}")
    raw, _ = exchange(post("/v1/chat/completions", chat_body()), read_timeout=5, keep_reading=8)
    if status_of(raw) != 200:
        raise SystemExit(f"a plain request with --key/--model does not work ({status_of(raw)}): fix that first\n{(raw or b'')[:300]!r}")

    started = time.time()
    known_crashers()
    smuggling()
    paths()
    generated(random.Random(ARGS.seed), ARGS.count)
    if ARGS.events_url:
        billing_on_disconnect()

    raw, _ = exchange(post("/v1/chat/completions", chat_body()), read_timeout=5, keep_reading=8)
    ok = status_of(raw) == 200
    results.append(("after all of that, a normal request still works", ok))
    print(f"\n  {'PASS' if ok else 'FAIL'}  after all of that, a normal request still works", flush=True)
    good = summary()
    print(f"({time.time() - started:.0f}s)")
    sys.exit(0 if good else 1)


if __name__ == "__main__":
    main()
