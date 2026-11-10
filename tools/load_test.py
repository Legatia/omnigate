"""Load and soak test for the omnigate data plane.

Starts nothing itself: point it at a running gateway whose routes lead to the
mock upstreams (tools/mock_upstream.py), and optionally at an endpoint that
tallies the usage events the gateway reports.

    python tools/load_test.py --gateway http://127.0.0.1:8080 --key og-unlimited-key \\
        --model demo-direct --failover-model demo-chat --duration 60

Many kinds of client run at once for --duration seconds:

  chat        keep-alive clients doing non-streaming chat
  stream      streaming clients that read to the end
  hangup      streaming clients that disconnect after the first chunk
  slowbody    clients that send part of a body and then stall
  idle        clients that connect and send nothing
  failover    a route whose first upstream answers 503
  dead        a route whose only upstream refuses connections (expects 502)
  limited     a rate-limited key (expects a mix of 200 and 429)
  oversize    bodies over the 8 MiB limit (expects 413 or a dropped connection)
  badjson     malformed JSON (expects 400)
  pipeline    several requests written at once on one connection
  health      /healthz probed throughout

It passes when: the gateway stays up and answers /healthz throughout; every
completed response is well-formed and has an expected status; the usage
events reported equal the metered requests that were answered (when
--events-url is given); stalled and silent clients are disconnected by the
gateway; and memory, threads and handles do not keep growing and fall back
after the load stops (when the gateway's process id is known).

Standard library only. Exit code 0 on PASS, 1 on FAIL.
"""

import argparse
import json
import os
import socket
import statistics
import subprocess
import sys
import threading
import time
from urllib.parse import urlparse

WINDOWS = os.name == "nt"


# --------------------------------------------------------------------------
# a small raw HTTP/1.1 client, strict about what it accepts
# --------------------------------------------------------------------------

class Malformed(Exception):
    pass


class Conn:
    def __init__(self, host, port, timeout=30.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.f = self.sock.makefile("rb")

    def close(self):
        try:
            self.f.close()
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass

    def send(self, data):
        self.sock.sendall(data)

    def read_head(self):
        line = self.f.readline(65536)
        if not line:
            raise ConnectionError("connection closed before a response")
        parts = line.split(b" ", 2)
        if len(parts) < 2 or not parts[0].startswith(b"HTTP/1.") or not parts[1][:3].isdigit():
            raise Malformed(f"bad status line {line[:80]!r}")
        headers = {}
        while True:
            h = self.f.readline(65536)
            if h in (b"\r\n", b"\n"):
                break
            if not h:
                raise Malformed("connection closed inside the headers")
            if b":" not in h:
                raise Malformed(f"bad header line {h[:80]!r}")
            k, v = h.split(b":", 1)
            headers[k.strip().lower().decode()] = v.strip().decode("latin-1")
        return int(parts[1][:3]), headers

    def read_body(self, headers, on_chunk=None):
        """Return the whole body; raises Malformed on framing errors."""
        out = []
        if headers.get("transfer-encoding", "").lower() == "chunked":
            while True:
                size_line = self.f.readline(1024)
                if not size_line:
                    raise Malformed("connection closed inside a chunked body")
                try:
                    size = int(size_line.split(b";")[0].strip(), 16)
                except ValueError:
                    raise Malformed(f"bad chunk size {size_line[:40]!r}")
                if size == 0:
                    while True:  # trailers
                        t = self.f.readline(65536)
                        if t in (b"\r\n", b"\n", b""):
                            break
                    return b"".join(out)
                data = self.f.read(size)
                if len(data) != size or self.f.read(2) != b"\r\n":
                    raise Malformed("truncated chunk")
                out.append(data)
                if on_chunk and on_chunk(data) is False:
                    return b"".join(out)
        elif "content-length" in headers:
            n = int(headers["content-length"])
            data = self.f.read(n)
            if len(data) != n:
                raise Malformed(f"body shorter than content-length ({len(data)} < {n})")
            return data
        else:
            return self.f.read()


def request_bytes(host, path, key, body, extra=b""):
    data = body if isinstance(body, bytes) else json.dumps(body).encode()
    return (f"POST {path} HTTP/1.1\r\nHost: {host}\r\nAuthorization: Bearer {key}\r\n"
            f"Content-Type: application/json\r\nContent-Length: {len(data)}\r\n").encode() + extra + b"\r\n" + data


# --------------------------------------------------------------------------
# bookkeeping
# --------------------------------------------------------------------------

class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.counts = {}        # (scenario, outcome) -> n
        self.metered = 0        # answered requests the gateway must have billed
        self.uncertain = 0      # requests sent whose fate is unknown (connection died first)
        self.problems = []      # things that must never happen
        self.latency = {}       # scenario -> [ms]

    def add(self, scenario, outcome, metered=False, ms=None):
        with self.lock:
            self.counts[(scenario, outcome)] = self.counts.get((scenario, outcome), 0) + 1
            if metered:
                self.metered += 1
            if ms is not None:
                self.latency.setdefault(scenario, []).append(ms)

    def maybe(self, n=1):
        with self.lock:
            self.uncertain += n

    def problem(self, scenario, text):
        with self.lock:
            if len(self.problems) < 40:
                self.problems.append(f"{scenario}: {text}")
            self.counts[(scenario, "PROBLEM")] = self.counts.get((scenario, "PROBLEM"), 0) + 1


class Ctx:
    def __init__(self, args):
        u = urlparse(args.gateway)
        self.host, self.port = u.hostname, u.port or 80
        self.args = args
        self.stats = Stats()
        self.stop = threading.Event()

    def conn(self, timeout=30.0):
        return Conn(self.host, self.port, timeout)

    def chat(self, model, stream=False, key=None, content="hi"):
        body = {"model": model, "messages": [{"role": "user", "content": content}]}
        if stream:
            body["stream"] = True
        return request_bytes(self.host, "/v1/chat/completions", key or self.args.key, body)


# --------------------------------------------------------------------------
# scenarios
# --------------------------------------------------------------------------

def keepalive_loop(ctx, name, model, expect, stream=False, key=None, pause=0.0):
    """Shared loop: one keep-alive connection, request after request."""
    c = None
    while not ctx.stop.is_set():
        try:
            if c is None:
                c = ctx.conn()
            t0 = time.perf_counter()
            c.send(ctx.chat(model, stream, key))
        except OSError as e:
            ctx.stats.add(name, "connect_or_send_error")
            ctx.stats.problem(name, f"could not send: {e}")
            if c: c.close()
            c = None
            time.sleep(0.2)
            continue
        try:
            status, headers = c.read_head()
            body = c.read_body(headers)
        except Malformed as e:
            ctx.stats.problem(name, f"malformed response: {e}")
            ctx.stats.maybe()
            c.close(); c = None
            continue
        except (OSError, ConnectionError) as e:
            ctx.stats.add(name, "connection_lost")
            ctx.stats.problem(name, f"connection lost mid-response: {e}")
            ctx.stats.maybe()
            c.close(); c = None
            continue
        ms = (time.perf_counter() - t0) * 1000
        ok = status in expect
        if ok and status == 200:
            if stream:
                ok = body.rstrip().endswith(b"data: [DONE]")
            else:
                try:
                    ok = "choices" in json.loads(body)
                except ValueError:
                    ok = False
            if not ok:
                ctx.stats.problem(name, f"200 with an unexpected body: {body[-120:]!r}")
        elif not ok:
            ctx.stats.problem(name, f"unexpected status {status}: {body[:160]!r}")
        # 200 and 502 from a routed endpoint are billed; 429 and 4xx are not.
        ctx.stats.add(name, str(status), metered=status in (200, 502), ms=ms)
        if headers.get("connection", "").lower() == "close":
            c.close(); c = None
        if pause:
            ctx.stop.wait(pause)
    if c: c.close()


def hangup(ctx):
    """Start a stream, read the first chunk, vanish."""
    while not ctx.stop.is_set():
        try:
            c = ctx.conn()
            c.send(ctx.chat(ctx.args.model, stream=True))
            status, headers = c.read_head()
        except (OSError, ConnectionError, Malformed) as e:
            ctx.stats.problem("hangup", f"no response head: {e}")
            ctx.stats.maybe()
            continue
        try:
            c.read_body(headers, on_chunk=lambda _d: False)
        except (OSError, Malformed):
            pass
        c.close()
        ctx.stats.add("hangup", f"{status}_then_disconnected", metered=status == 200)
        ctx.stop.wait(0.05)


def slowbody(ctx):
    """Promise a body, send a little, stall. The gateway should hang up."""
    while not ctx.stop.is_set():
        try:
            c = ctx.conn(timeout=ctx.args.client_timeout + 15)
            c.send((f"POST /v1/chat/completions HTTP/1.1\r\nHost: {ctx.host}\r\nAuthorization: Bearer {ctx.args.key}\r\n"
                    "Content-Type: application/json\r\nContent-Length: 4096\r\n\r\n").encode() + b'{"model": "')
        except OSError as e:
            ctx.stats.problem("slowbody", f"could not connect: {e}")
            time.sleep(0.5)
            continue
        t0 = time.time()
        outcome = "still_open_at_end"
        try:
            c.sock.settimeout(0.5)
            while not ctx.stop.is_set() and time.time() - t0 < ctx.args.client_timeout + 12:
                try:
                    data = c.sock.recv(4096)
                except socket.timeout:
                    continue
                if not data:
                    outcome = "closed_by_gateway"
                    break
                # A 408/400 answer before closing is fine too.
                outcome = "closed_by_gateway"
            else:
                if not ctx.stop.is_set():
                    outcome = "never_closed"
        except OSError:
            outcome = "closed_by_gateway"
        c.close()
        ctx.stats.add("slowbody", outcome, ms=(time.time() - t0) * 1000 if outcome == "closed_by_gateway" else None)
        if outcome == "never_closed":
            ctx.stats.problem("slowbody", "a stalled request body was never disconnected")


def idle(ctx):
    """Connect and say nothing. The gateway should hang up."""
    while not ctx.stop.is_set():
        try:
            s = socket.create_connection((ctx.host, ctx.port), timeout=10)
        except OSError as e:
            ctx.stats.add("idle", "refused")
            time.sleep(0.5)
            continue
        t0 = time.time()
        outcome = "still_open_at_end"
        s.settimeout(0.5)
        try:
            while not ctx.stop.is_set():
                if time.time() - t0 > ctx.args.client_timeout + 12:
                    outcome = "never_closed"
                    break
                try:
                    data = s.recv(4096)
                except socket.timeout:
                    continue
                outcome = "closed_by_gateway"
                if not data:
                    break
        except OSError:
            outcome = "closed_by_gateway"
        s.close()
        ctx.stats.add("idle", outcome, ms=(time.time() - t0) * 1000 if outcome == "closed_by_gateway" else None)
        if outcome == "never_closed":
            ctx.stats.problem("idle", "a silent connection was never disconnected")


def oversize(ctx):
    """9 MiB of body. Expect 413, or the connection dropped while we are still sending."""
    blob = b'{"model":"x","messages":[{"role":"user","content":"' + b"a" * (9 * 1024 * 1024) + b'"}]}'
    while not ctx.stop.is_set():
        outcome = None
        try:
            c = ctx.conn(timeout=30)
            try:
                c.send(request_bytes(ctx.host, "/v1/chat/completions", ctx.args.key, blob))
            except OSError:
                outcome = "dropped_while_sending"
            if outcome is None or True:
                try:
                    status, headers = c.read_head()
                    c.read_body(headers)
                    outcome = str(status)
                    if status != 413:
                        ctx.stats.problem("oversize", f"expected 413, got {status}")
                except (OSError, ConnectionError):
                    outcome = outcome or "dropped_before_response"
                except Malformed as e:
                    ctx.stats.problem("oversize", f"malformed response: {e}")
                    outcome = "malformed"
            c.close()
        except OSError as e:
            outcome = "connect_error"
        ctx.stats.add("oversize", outcome)
        ctx.stop.wait(2.0)


def badjson(ctx):
    c = None
    while not ctx.stop.is_set():
        try:
            if c is None:
                c = ctx.conn()
            c.send(request_bytes(ctx.host, "/v1/chat/completions", ctx.args.key, b'{"model": "direct", "messages": [oops'))
            status, headers = c.read_head()
            c.read_body(headers)
        except (OSError, ConnectionError, Malformed) as e:
            ctx.stats.problem("badjson", f"no clean answer: {e}")
            if c: c.close()
            c = None
            continue
        if status != 400:
            ctx.stats.problem("badjson", f"expected 400, got {status}")
        ctx.stats.add("badjson", str(status))
        ctx.stop.wait(0.02)
    if c: c.close()


def pipeline(ctx, depth=3):
    """Write several requests in one go; expect as many answers, in order."""
    c = None
    while not ctx.stop.is_set():
        try:
            if c is None:
                c = ctx.conn()
            c.send(ctx.chat(ctx.args.model) * depth)
        except OSError as e:
            ctx.stats.problem("pipeline", f"could not send: {e}")
            if c: c.close()
            c = None
            time.sleep(0.2)
            continue
        got = 0
        try:
            for _ in range(depth):
                status, headers = c.read_head()
                body = c.read_body(headers)
                if status != 200 or b"choices" not in body:
                    ctx.stats.problem("pipeline", f"answer {got + 1} of {depth}: status {status}")
                ctx.stats.add("pipeline", str(status), metered=status in (200, 502))
                got += 1
        except (OSError, ConnectionError, Malformed) as e:
            ctx.stats.problem("pipeline", f"only {got} of {depth} answers: {e}")
            ctx.stats.maybe(depth - got)
            c.close(); c = None
    if c: c.close()


def health(ctx):
    while not ctx.stop.is_set():
        t0 = time.perf_counter()
        try:
            c = ctx.conn(timeout=5)
            c.send(f"GET /healthz HTTP/1.1\r\nHost: {ctx.host}\r\nConnection: close\r\n\r\n".encode())
            status, headers = c.read_head()
            body = c.read_body(headers)
            c.close()
            if status != 200 or body.strip() != b"ok":
                ctx.stats.problem("health", f"status {status} body {body[:40]!r}")
            ctx.stats.add("health", str(status), ms=(time.perf_counter() - t0) * 1000)
        except (OSError, ConnectionError, Malformed) as e:
            ctx.stats.add("health", "failed")
            ctx.stats.problem("health", f"/healthz did not answer: {e}")
        ctx.stop.wait(0.1)


# --------------------------------------------------------------------------
# process sampling
# --------------------------------------------------------------------------

def find_pid(port):
    try:
        if WINDOWS:
            out = subprocess.run(["netstat", "-ano", "-p", "TCP"], capture_output=True, text=True, timeout=20).stdout
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 5 and parts[3] == "LISTENING" and parts[1].endswith(f":{port}"):
                    return int(parts[4])
        else:
            out = subprocess.run(["ss", "-ltnpH", f"sport = :{port}"], capture_output=True, text=True, timeout=20).stdout
            if "pid=" in out:
                return int(out.split("pid=")[1].split(",")[0])
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return None


def sample(pid):
    """(rss MiB, threads, handles or fds) or None."""
    try:
        if WINDOWS:
            out = subprocess.run(["powershell", "-NoProfile", "-Command",
                                  f"$p = Get-Process -Id {pid}; '{{0}} {{1}} {{2}}' -f $p.WorkingSet64, $p.Threads.Count, $p.HandleCount"],
                                 capture_output=True, text=True, timeout=30).stdout.split()
            return int(out[0]) / 2**20, int(out[1]), int(out[2])
        status = open(f"/proc/{pid}/status").read()
        rss = int(status.split("VmRSS:")[1].split()[0]) / 1024
        threads = int(status.split("Threads:")[1].split()[0])
        return rss, threads, len(os.listdir(f"/proc/{pid}/fd"))
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return None


def sampler(ctx, pid, samples, interval):
    while not ctx.stop.is_set():
        s = sample(pid)
        if s:
            samples.append((time.time(), *s))
        ctx.stop.wait(interval)


def fetch_json(url):
    import urllib.request
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.load(r)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * p))] if values else float("nan")


def main():
    ap = argparse.ArgumentParser(description="Load and soak test for the omnigate data plane.")
    ap.add_argument("--gateway", default="http://127.0.0.1:8080")
    ap.add_argument("--key", default="og-unlimited-key")
    ap.add_argument("--limited-key", default=None, help="a key with a requests-per-minute limit")
    ap.add_argument("--model", default="demo-direct", help="route with one healthy mock upstream")
    ap.add_argument("--failover-model", default="demo-chat", help="route whose first upstream answers 503")
    ap.add_argument("--dead-model", default=None, help="route whose only upstream refuses connections")
    ap.add_argument("--events-url", default=None, help="URL returning {count, unique, duplicates} of usage events received")
    ap.add_argument("--pid", type=int, default=None, help="gateway process id (found from the port when omitted)")
    ap.add_argument("--duration", type=float, default=60.0)
    ap.add_argument("--client-timeout", type=float, default=30.0, help="the gateway's OMNIGATE_CLIENT_TIMEOUT_MS, in seconds")
    ap.add_argument("--chat-clients", type=int, default=16)
    ap.add_argument("--stream-clients", type=int, default=8)
    ap.add_argument("--idle-clients", type=int, default=50)
    ap.add_argument("--skip", default="", help="comma-separated scenarios to leave out")
    args = ap.parse_args()
    skip = set(filter(None, args.skip.split(",")))
    ctx = Ctx(args)
    st = ctx.stats

    pid = args.pid or find_pid(ctx.port)
    baseline = sample(pid) if pid else None
    events_before = fetch_json(args.events_url) if args.events_url else None
    print(f"gateway {args.gateway} pid {pid}; baseline " + (f"{baseline[0]:.1f} MiB, {baseline[1]} threads, {baseline[2]} handles" if baseline else "unknown"))

    plan = []
    def add(name, n, fn, *a, **kw):
        if name not in skip:
            plan.extend((name, fn, a, kw) for _ in range(n))
    add("chat", args.chat_clients, keepalive_loop, "chat", args.model, (200,))
    add("stream", args.stream_clients, keepalive_loop, "stream", args.model, (200,), True)
    add("hangup", 4, hangup)
    add("slowbody", 2, slowbody)
    add("idle", args.idle_clients, idle)
    add("failover", 4, keepalive_loop, "failover", args.failover_model, (200,))
    if args.dead_model:
        add("dead", 2, keepalive_loop, "dead", args.dead_model, (502,))
    if args.limited_key:
        add("limited", 2, keepalive_loop, "limited", args.model, (200, 429), False, args.limited_key, 0.05)
    add("oversize", 1, oversize)
    add("badjson", 2, badjson)
    add("pipeline", 2, pipeline)
    add("health", 1, health)

    samples = []
    threads = [threading.Thread(target=fn, args=(ctx, *a), kwargs=kw, daemon=True, name=name) for name, fn, a, kw in plan]
    if pid:
        threads.append(threading.Thread(target=sampler, args=(ctx, pid, samples, max(2.0, args.duration / 40)), daemon=True, name="sampler"))
    started = time.time()
    for t in threads:
        t.start()
    print(f"running {len(plan)} clients for {args.duration:.0f}s ...", flush=True)
    try:
        while time.time() - started < args.duration:
            time.sleep(min(10.0, args.duration / 6))
            with st.lock:
                done = sum(n for (s, o), n in st.counts.items() if s in ("chat", "stream"))
            last = samples[-1] if samples else None
            print(f"  {time.time() - started:5.0f}s  chat+stream answered {done}"
                  + (f"   {last[1]:.1f} MiB, {last[2]} threads, {last[3]} handles" if last else ""), flush=True)
    except KeyboardInterrupt:
        print("interrupted")
    ctx.stop.set()
    elapsed = time.time() - started
    for t in threads:
        t.join(timeout=45)
    stuck = [t.name for t in threads if t.is_alive()]

    # Let the gateway settle: flush usage, drop our connections.
    settle = {}
    events_after = None
    if args.events_url:
        deadline = time.time() + 20
        while time.time() < deadline:
            events_after = fetch_json(args.events_url)
            got = events_after["count"] - events_before["count"]
            if st.metered <= got:
                time.sleep(1.0)
                events_after = fetch_json(args.events_url)
                break
            time.sleep(0.5)
    time.sleep(5)
    final = sample(pid) if pid else None
    alive_after = True
    try:
        c = ctx.conn(timeout=5)
        c.send(f"GET /healthz HTTP/1.1\r\nHost: {ctx.host}\r\nConnection: close\r\n\r\n".encode())
        alive_after = c.read_head()[0] == 200
        c.close()
    except (OSError, ConnectionError, Malformed):
        alive_after = False

    # ---------------- report ----------------
    print("\nresults by scenario:")
    names = sorted({s for s, _ in st.counts})
    for name in names:
        outcomes = {o: n for (s, o), n in st.counts.items() if s == name}
        lat = st.latency.get(name)
        extra = f"   p50 {pct(lat, .5):.1f} ms  p99 {pct(lat, .99):.1f} ms" if lat else ""
        print(f"  {name:<9} " + ", ".join(f"{o}={n}" for o, n in sorted(outcomes.items())) + extra)
    total = sum(n for (s, o), n in st.counts.items() if o not in ("PROBLEM",))
    print(f"total outcomes {total} in {elapsed:.0f}s ({total / max(elapsed, 1):.0f}/s)")

    verdicts = []
    def verdict(name, ok, detail):
        verdicts.append(ok)
        print(f"  {'PASS' if ok else 'FAIL'}  {name}: {detail}")

    print("\nchecks:")
    verdict("no malformed or unexpected responses", not st.problems, f"{len(st.problems)} problem(s)")
    for p in st.problems[:12]:
        print(f"          - {p}")
    hl = st.latency.get("health", [])
    failed_health = st.counts.get(("health", "failed"), 0)
    verdict("/healthz answered throughout", failed_health == 0 and alive_after and bool(hl),
            f"{len(hl)} probes, {failed_health} failed, p50 {pct(hl, .5):.1f} ms, p99 {pct(hl, .99):.1f} ms, max {max(hl) if hl else float('nan'):.1f} ms")
    verdict("no client thread stuck", not stuck, f"stuck: {stuck or 'none'}")
    for name in ("idle", "slowbody"):
        if name in skip:
            continue
        closed = st.counts.get((name, "closed_by_gateway"), 0)
        never = st.counts.get((name, "never_closed"), 0)
        lat = st.latency.get(name, [])
        if args.duration > args.client_timeout + 5:
            verdict(f"{name} clients are disconnected by the gateway", closed > 0 and never == 0,
                    f"{closed} disconnected after a median {statistics.median(lat) / 1000 if lat else float('nan'):.1f}s, {never} never")
        else:
            print(f"  ----  {name}: run shorter than the client timeout; {closed} disconnected, {never} never")
    if events_after is not None:
        got = events_after["count"] - events_before["count"]
        dups = events_after["duplicates"] - events_before["duplicates"]
        ok = st.metered <= got <= st.metered + st.uncertain and dups == 0
        verdict("usage events equal metered requests", ok,
                f"{got} events for {st.metered} answered metered requests (+{st.uncertain} of unknown fate), {dups} duplicate ids")
    if samples and baseline:
        half = len(samples) // 2
        warm = samples[max(1, len(samples) // 5):half] or samples[:1]
        late = samples[half:] or samples[-1:]
        med = lambda rows, i: statistics.median(r[i] for r in rows)
        peak = lambda i: max(r[i] for r in samples)
        print(f"          baseline {baseline[0]:.1f} MiB / {baseline[1]} thr / {baseline[2]} handles;"
              f" early median {med(warm, 1):.1f} / {med(warm, 2):.0f} / {med(warm, 3):.0f};"
              f" late median {med(late, 1):.1f} / {med(late, 2):.0f} / {med(late, 3):.0f};"
              f" peak {peak(1):.1f} / {peak(2)} / {peak(3)}")
        verdict("memory does not keep growing", med(late, 1) <= med(warm, 1) * 1.25 + 8,
                f"late median {med(late, 1):.1f} MiB vs early {med(warm, 1):.1f} MiB")
        verdict("threads and handles do not keep growing",
                med(late, 2) <= med(warm, 2) * 1.25 + 8 and med(late, 3) <= med(warm, 3) * 1.25 + 32,
                f"threads {med(warm, 2):.0f} -> {med(late, 2):.0f}, handles {med(warm, 3):.0f} -> {med(late, 3):.0f}")
        if final:
            # Worker threads are pooled and kept; what must go away are the
            # connections (handles), and memory must not sit above its
            # level under load.
            verdict("resources fall back after the load stops",
                    final[0] <= med(late, 1) + 8 and final[1] <= peak(2) and final[2] <= baseline[2] + (med(late, 3) - baseline[2]) * 0.8,
                    f"now {final[0]:.1f} MiB, {final[1]} threads (pooled), {final[2]} handles")
    elif not pid:
        print("  ----  resource checks skipped: gateway process id unknown (pass --pid)")

    ok = all(verdicts)
    print("\n" + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
