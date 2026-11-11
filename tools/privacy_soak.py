"""Soak test for privacy mode: sustained mixed load through redaction.

Starts its own stack (mock providers, control plane, data plane) in a fresh
temporary directory, like tools/e2e.py, and then keeps many kinds of client
busy for --duration seconds:

    python tools/privacy_soak.py --duration 900 --gateway-exe <path to a ReleaseSafe omnigate-dp>

Half of the clients use a key with `"privacy": true`, half an ordinary key,
interleaved on the same gateway. Every request carries values of its own
(email addresses, IP addresses, card numbers, a secret) that no other request
shares, and the mock providers answer with what they were sent. Requests are
streamed and not, in the OpenAI and the Anthropic protocol, direct and
translated, with and without tool calls, with many values, a few or none;
some clients hang up mid-stream and some read slowly.

It passes when
  - every answer to a private request holds all of that request's own values
    and no placeholder,
  - no answer to any request holds a value of another request,
  - the mock providers never received a private request's value (they count
    request bodies containing the private markers: MOCK_WATCH),
  - the usage the control plane billed each key equals the usage the
    providers reported in the answers that key's clients received,
  - both processes stay up, and the data plane's memory does not keep growing,
  - afterwards, no file either process wrote contains a private value.

It also reports latency percentiles with and without redaction, throughput,
and the memory of both processes over time.

Standard library only (it imports tools/e2e.py and tools/load_test.py).
Exit code 0 on PASS, 1 on FAIL. Not part of tools/check.py: it is meant to
run for a quarter of an hour or more.
"""

import argparse
import json
import os
import random
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e  # noqa: E402
from e2e import CONTROL, GATEWAY, GATEWAY_PORT, CONTROL_PORT, ADMIN_TOKEN, jcall  # noqa: E402
from load_test import Conn, Malformed, find_pid, sample, pct, request_bytes  # noqa: E402

K_PRIV, K_PLAIN, K_PRIV_ABORT, K_PLAIN_ABORT = "og-soak-private", "og-soak-plain", "og-soak-private-abort", "og-soak-plain-abort"
# What marks a private request's values, wherever they appear.
PRIV_WORD, PRIV_IP, PRIV_CARD = "zqpriv", "10.77.", "4777 77"
PLAIN_WORD, PLAIN_IP, PLAIN_CARD = "zqplain", "10.88.", "4888 88"
PLACEHOLDER = re.compile(r"\[(EMAIL|PHONE|IP|CARD|SECRET)_\d+\]")
TOOL_TRIGGER = "use the tool"
AH = b"anthropic-version: 2023-06-01\r\n"


def config():
    price = {"price_in_per_mtok": 1.0, "price_out_per_mtok": 2.0}
    up = lambda name, kind, port: {"name": name, "kind": kind, "base_url": f"http://127.0.0.1:{port}", "api_key_env": "MOCK_API_KEY"}
    return {
        "keys": [{"name": "private", "key": K_PRIV, "privacy": True}, {"name": "plain", "key": K_PLAIN},
                 {"name": "private-abort", "key": K_PRIV_ABORT, "privacy": True}, {"name": "plain-abort", "key": K_PLAIN_ABORT}],
        "upstreams": [up("mock-ok", "openai", 9002), up("mock-anthropic", "anthropic", 9003)],
        "routes": [{"model": "echo", "targets": [dict(upstream="mock-ok", model="echo-1", **price)]},
                   {"model": "echo-claude", "targets": [dict(upstream="mock-anthropic", model="echo-1", **price)]}],
    }


def luhn_card(prefix, n):
    """A 16-digit card number that passes the Luhn check, written in groups of four."""
    digits = [int(c) for c in (prefix.replace(" ", "") + f"{n % 10**9:09d}")]
    total = 0
    for i, d in enumerate(reversed(digits)):
        if i % 2 == 0:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    digits.append((10 - total % 10) % 10)
    s = "".join(map(str, digits))
    return " ".join(s[i:i + 4] for i in range(0, 16, 4))


class Values:
    """The values one request carries, all derived from its number."""

    def __init__(self, rid, private, count):
        word = PRIV_WORD if private else PLAIN_WORD
        self.rid = rid
        self.emails = [f"{word}.r{rid}.{i}@soak.example" for i in range(count)]
        self.ips, self.cards, self.secrets = [], [], []
        if count:
            self.ips = [f"{PRIV_IP if private else PLAIN_IP}{(rid >> 8) & 255}.{rid & 255}"]
            self.cards = [luhn_card(PRIV_CARD if private else PLAIN_CARD, rid)]
            self.secrets = [f"sk-proj-{word}R{rid}xAbc123Def456Ghi789Jkl012"]

    def all(self):
        return self.emails + self.ips + self.cards + self.secrets

    def text(self, tool):
        parts = [f"request r{self.rid} says" + (f" {TOOL_TRIGGER}" if tool else "")]
        for i, e in enumerate(self.emails):
            parts.append(f"mail {e}" + ("," if i % 3 else ";"))
        parts += [f"host {ip}" for ip in self.ips] + [f"card {c}" for c in self.cards] + [f"key {s}" for s in self.secrets]
        return " ".join(parts) + " end"


FOREIGN = [re.compile(r"\.r(\d+)\.\d+@soak\.example"), re.compile(r"zq(?:priv|plain)R(\d+)x")]
ANY_IP = re.compile(r"\b10\.(?:77|88)\.\d+\.\d+\b")
ANY_CARD = re.compile(r"\b4(?:777|888) (?:77|88)\d\d \d{4} \d{4}\b")


class Soak:
    def __init__(self, args):
        self.args = args
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.next_rid = 0
        self.counts = {}            # (scenario, outcome) -> n
        self.lat = {}               # scenario -> [ms]
        self.problems = []
        self.usage = {K_PRIV: [0, 0, 0], K_PLAIN: [0, 0, 0]}      # requests, tokens in, tokens out as the clients saw them
        self.rng = random.Random(7)

    def rid(self):
        with self.lock:
            self.next_rid += 1
            return self.next_rid

    def add(self, scenario, outcome, ms=None):
        with self.lock:
            self.counts[(scenario, outcome)] = self.counts.get((scenario, outcome), 0) + 1
            if ms is not None:
                self.lat.setdefault(scenario, []).append(ms)

    def problem(self, scenario, text):
        with self.lock:
            if len(self.problems) < 40:
                self.problems.append(f"{scenario}: {text}")
            self.counts[(scenario, "PROBLEM")] = self.counts.get((scenario, "PROBLEM"), 0) + 1

    def billed(self, key, tin, tout):
        with self.lock:
            u = self.usage[key]
            u[0] += 1
            u[1] += tin
            u[2] += tout

    # -- one request ------------------------------------------------------

    def body(self, protocol, model, values, stream, tool):
        text = values.text(tool)
        b = {"model": model, "messages": [{"role": "user", "content": text}]}
        if protocol == "anthropic":
            b["max_tokens"] = 4096
            if tool:
                b["tools"] = [{"name": "note", "description": "Take a note.", "input_schema": {"type": "object", "properties": {"text": {"type": "string"}}}}]
        elif tool:
            b["tools"] = [{"type": "function", "function": {"name": "note", "description": "Take a note.", "parameters": {"type": "object", "properties": {"text": {"type": "string"}}}}}]
        if stream:
            b["stream"] = True
            if protocol == "openai":
                b["stream_options"] = {"include_usage": True}
        return json.dumps(b).encode()

    def check_answer(self, scenario, private, values, text):
        """Everything the answer must and must not contain."""
        ok = True
        if private and PLACEHOLDER.search(text):
            self.problem(scenario, f"placeholder left in the answer to r{values.rid}: {PLACEHOLDER.search(text).group(0)}")
            ok = False
        missing = [v for v in values.all() if v not in text]
        if missing:
            self.problem(scenario, f"r{values.rid}: {len(missing)} of {len(values.all())} own values missing, e.g. {missing[0]!r}; answer starts {text[:160]!r}")
            ok = False
        for pattern in FOREIGN:
            for other in pattern.findall(text):
                if int(other) != values.rid:
                    self.problem(scenario, f"CROSS-REQUEST LEAK: the answer to r{values.rid} holds a value of r{other}")
                    ok = False
        own = set(values.ips)
        for ip in ANY_IP.findall(text):
            if ip not in own:
                self.problem(scenario, f"CROSS-REQUEST LEAK: the answer to r{values.rid} holds the address {ip}")
                ok = False
        own = set(values.cards)
        for card in ANY_CARD.findall(text):
            if card not in own:
                self.problem(scenario, f"CROSS-REQUEST LEAK: the answer to r{values.rid} holds the card {card}")
                ok = False
        return ok

    def one(self, conn, scenario, key, private, protocol, model, stream, tool, count, slow=False):
        values = Values(self.rid(), private, count)
        path = "/v1/messages" if protocol == "anthropic" else "/v1/chat/completions"
        started = time.perf_counter()
        conn.send(request_bytes("127.0.0.1", path, key, self.body(protocol, model, values, stream, tool), AH if protocol == "anthropic" else b""))
        status, headers = conn.read_head()
        body = conn.read_body(headers, (lambda _data: time.sleep(0.02)) if slow else None)
        ms = (time.perf_counter() - started) * 1000
        raw = body.decode("utf-8", "replace")
        if status != 200:
            self.problem(scenario, f"r{values.rid}: status {status}: {raw[:200]!r}")
            return False
        if private and "redact" not in headers.get("x-omnigate-privacy", ""):
            self.problem(scenario, f"r{values.rid}: no x-omnigate-privacy: redact on a private answer")
        try:
            text, tin, tout = (self.read_stream if stream else self.read_whole)(protocol, raw)
        except (ValueError, KeyError, TypeError) as e:
            self.problem(scenario, f"r{values.rid}: unreadable answer ({e}): {raw[:200]!r}")
            return False
        self.check_answer(scenario, private, values, text)
        if key in self.usage:
            if tin is None:
                self.problem(scenario, f"r{values.rid}: the answer carried no usage")
            else:
                self.billed(key, tin, tout)
        self.add(scenario, "ok", ms)
        return headers.get("connection", "").lower() != "close"

    @staticmethod
    def read_whole(protocol, raw):
        obj = json.loads(raw)
        leaves = []

        def walk(x):
            if isinstance(x, str):
                leaves.append(x)
            elif isinstance(x, dict):
                for v in x.values():
                    walk(v)
            elif isinstance(x, list):
                for v in x:
                    walk(v)

        walk(obj)
        u = obj.get("usage") or {}
        if protocol == "anthropic":
            return "\n".join(leaves), u.get("input_tokens"), u.get("output_tokens")
        return "\n".join(leaves), u.get("prompt_tokens"), u.get("completion_tokens")

    @staticmethod
    def read_stream(protocol, raw):
        text, args, tin, tout = [], [], None, None
        for line in raw.split("\n"):
            line = line.rstrip("\r")
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                continue
            obj = json.loads(data)
            if protocol == "anthropic":
                kind = obj.get("type")
                if kind == "message_start":
                    tin = obj["message"]["usage"].get("input_tokens")
                elif kind == "content_block_delta":
                    text.append(obj["delta"].get("text", ""))
                    args.append(obj["delta"].get("partial_json", ""))
                elif kind == "message_delta":
                    tout = (obj.get("usage") or {}).get("output_tokens", tout)
                    if (obj.get("usage") or {}).get("input_tokens") is not None:
                        tin = obj["usage"]["input_tokens"]
            else:
                for choice in obj.get("choices") or []:
                    delta = choice.get("delta") or {}
                    text.append(delta.get("content") or "")
                    for tc in delta.get("tool_calls") or []:
                        args.append((tc.get("function") or {}).get("arguments") or "")
                if obj.get("usage"):
                    tin, tout = obj["usage"].get("prompt_tokens"), obj["usage"].get("completion_tokens")
        return "".join(text) + "\n" + "".join(args), tin, tout

    # -- clients ----------------------------------------------------------

    def loop(self, scenario, key, private, protocol, model, stream, tool=False, counts=None, slow=False, pause=0.0):
        counts = counts or ((1, 2, 3) if stream else (1, 3, 8, 20))
        conn = None
        rng = random.Random(hash(scenario) & 0xffff)
        while not self.stop.is_set():
            try:
                if conn is None:
                    conn = Conn("127.0.0.1", GATEWAY_PORT, timeout=60)
                if not self.one(conn, scenario, key, private, protocol, model, stream, tool, rng.choice(counts), slow):
                    conn.close()
                    conn = None
            except (OSError, Malformed, socket.timeout) as e:
                self.problem(scenario, f"connection: {type(e).__name__}: {e}")
                if conn:
                    conn.close()
                conn = None
                time.sleep(0.2)
            if pause:
                self.stop.wait(pause)
        if conn:
            conn.close()

    def hangup(self, scenario, key, private):
        """Streams, reads the head and one chunk, then disconnects."""
        rng = random.Random(hash(scenario) & 0xffff)
        while not self.stop.is_set():
            values = Values(self.rid(), private, 40)
            protocol, model = rng.choice([("openai", "echo"), ("anthropic", "echo-claude"), ("openai", "echo-claude")])
            path = "/v1/messages" if protocol == "anthropic" else "/v1/chat/completions"
            try:
                conn = Conn("127.0.0.1", GATEWAY_PORT, timeout=30)
                conn.send(request_bytes("127.0.0.1", path, key, self.body(protocol, model, values, True, False), AH if protocol == "anthropic" else b""))
                status, _ = conn.read_head()
                data = conn.f.read1(256)
                conn.close()
                text = data.decode("utf-8", "replace")
                if status != 200:
                    self.problem(scenario, f"status {status}")
                elif private and PLACEHOLDER.search(text):
                    self.problem(scenario, "placeholder in the first bytes of an aborted stream")
                else:
                    self.add(scenario, "hung up")
            except (OSError, Malformed, socket.timeout) as e:
                self.problem(scenario, f"connection: {type(e).__name__}: {e}")
            self.stop.wait(0.05)

    def health(self):
        while not self.stop.is_set():
            status, _, _ = e2e.call("GET", GATEWAY + "/healthz", timeout=5)
            self.add("health", "ok" if status == 200 else f"status {status}")
            if status != 200:
                self.problem("health", f"/healthz answered {status}")
            self.stop.wait(1.0)


def usage_row(name):
    _, _, body = jcall("GET", CONTROL + "/admin/usage", key=ADMIN_TOKEN)
    for row in body.get("keys", []):
        if row.get("name") == name:
            return row
    return {}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--duration", type=float, default=900.0)
    ap.add_argument("--gateway-exe", default=None, help="the data plane binary to test (default: dataplane/zig-out/bin, usually a Debug build)")
    ap.add_argument("--gateway-wsl", default=None, metavar="PATH",
                    help="on Windows: run this Linux build of the data plane inside WSL instead (needs WSL's mirrored networking, "
                         "so that both sides share 127.0.0.1); its memory, threads and memory mappings are read from /proc")
    ap.add_argument("--gateway-port", type=int, default=None, help="port for the data plane, when the usual one cannot be bound where it runs")
    ap.add_argument("--clients", type=int, default=2, help="clients per scenario")
    ap.add_argument("--only", choices=("private", "plain"), default=None, help="run only one kind of key (to compare memory and latency)")
    ap.add_argument("--scenarios", default=None, help="a regular expression: run only the scenarios whose name it matches (e.g. 'hangup', ':chat$')")
    ap.add_argument("--keep", action="store_true", help="keep the working directory")
    args = ap.parse_args()
    if args.gateway_port:
        global GATEWAY_PORT, GATEWAY
        GATEWAY_PORT, GATEWAY = args.gateway_port, f"http://127.0.0.1:{args.gateway_port}"

    work = tempfile.mkdtemp(prefix="omnigate-soak-")
    stack = e2e.Stack(work, config(), False)
    stack.env["MOCK_WATCH"] = ",".join([PRIV_WORD, PRIV_IP, PRIV_CARD, PLAIN_WORD])
    soak = Soak(args)
    verdicts = []

    def verdict(name, ok, detail=""):
        verdicts.append((name, bool(ok)))
        print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"   [{detail}]" if detail else ""), flush=True)

    try:
        stack.start_mocks()
        stack.start_control()
        wsl_dir = "/tmp/omnigate-soak-dataplane"
        if args.gateway_wsl:
            subprocess.run(["wsl", "-e", "sh", "-c", f"rm -rf {wsl_dir} && mkdir -p {wsl_dir}"], check=True)
            cmd = ["wsl", "--cd", wsl_dir, "-e", "env", f"OMNIGATE_LISTEN=127.0.0.1:{GATEWAY_PORT}", f"OMNIGATE_CONTROL_URL={CONTROL}",
                   "OMNIGATE_POLL_MS=300", "OMNIGATE_FLUSH_MS=200", f"OMNIGATE_INTERNAL_TOKEN={e2e.TOKEN}", "MOCK_API_KEY=mock-secret", args.gateway_wsl]
            proc = stack.start("gateway", cmd, cwd=work)
            if not e2e.wait_port(GATEWAY_PORT, 20, proc):
                stack.fail("the gateway did not start inside WSL", "gateway")
        elif args.gateway_exe:
            env = {"OMNIGATE_LISTEN": f"127.0.0.1:{GATEWAY_PORT}", "OMNIGATE_CONTROL_URL": CONTROL, "OMNIGATE_POLL_MS": "300", "OMNIGATE_FLUSH_MS": "200"}
            proc = stack.start("gateway", [args.gateway_exe], cwd=work, env=env)
            if not e2e.wait_port(GATEWAY_PORT, 15, proc):
                stack.fail("gateway did not start", "gateway")
        else:
            stack.start_gateway()
        e2e.wait_until(lambda: e2e.call("GET", GATEWAY + "/v1/models", key=K_PRIV)[0] == 200, 20)
        gw_pid, cp_pid = find_pid(GATEWAY_PORT), find_pid(CONTROL_PORT)
        sample_gw = sample
        if args.gateway_wsl:
            def sample_gw(_pid, name=os.path.basename(args.gateway_wsl)):
                """(rss MiB, threads, memory mappings) of the Linux process, from /proc."""
                try:
                    script = f"p=$(pidof {name} | cut -d' ' -f1); grep -E 'VmRSS|Threads' /proc/$p/status; wc -l < /proc/$p/maps"
                    out = subprocess.run(["wsl", "-e", "sh", "-c", script], capture_output=True, text=True, timeout=30).stdout
                    rss = int(out.split("VmRSS:")[1].split()[0]) / 1024
                    return rss, int(out.split("Threads:")[1].split()[0]), int(out.strip().splitlines()[-1])
                except (OSError, ValueError, IndexError, subprocess.SubprocessError):
                    return None
            gw_pid = gw_pid or -1
        print(f"work dir {work}; gateway pid {gw_pid}, control plane pid {cp_pid}; running for {args.duration:.0f} s", flush=True)

        threads = []

        def start(fn, *a, **kw):
            name = a[0] if a else "health"
            if args.scenarios and name != "health" and not re.search(args.scenarios, name):
                return
            t = threading.Thread(target=fn, args=a, kwargs=kw, daemon=True)
            t.start()
            threads.append(t)

        kinds = [(True, K_PRIV, "priv"), (False, K_PLAIN, "plain")]
        kinds = [k for k in kinds if args.only is None or (args.only == "private") == k[0]]
        for private, key, tag in kinds:
            for _ in range(args.clients):
                start(soak.loop, f"{tag}:chat", key, private, "openai", "echo", False)
                start(soak.loop, f"{tag}:chat-stream", key, private, "openai", "echo", True)
                start(soak.loop, f"{tag}:messages", key, private, "anthropic", "echo-claude", False)
                start(soak.loop, f"{tag}:messages-stream", key, private, "anthropic", "echo-claude", True)
                start(soak.loop, f"{tag}:translated-to-anthropic", key, private, "openai", "echo-claude", False)
                start(soak.loop, f"{tag}:translated-to-anthropic-stream", key, private, "openai", "echo-claude", True)
                start(soak.loop, f"{tag}:translated-to-openai", key, private, "anthropic", "echo", False)
                start(soak.loop, f"{tag}:translated-to-openai-stream", key, private, "anthropic", "echo", True)
            start(soak.loop, f"{tag}:tool", key, private, "openai", "echo", False, tool=True)
            start(soak.loop, f"{tag}:tool-stream", key, private, "openai", "echo", True, tool=True)
            start(soak.loop, f"{tag}:tool-claude", key, private, "anthropic", "echo-claude", False, tool=True)
            start(soak.loop, f"{tag}:tool-claude-stream", key, private, "anthropic", "echo-claude", True, tool=True)
            start(soak.loop, f"{tag}:no-values", key, private, "openai", "echo", False, counts=(0,))
            start(soak.loop, f"{tag}:no-values-stream", key, private, "anthropic", "echo-claude", True, counts=(0,))
            start(soak.loop, f"{tag}:many-values", key, private, "openai", "echo", False, counts=(200, 600), pause=0.05)
            # The mock streams three characters every 50 ms: keep streamed bodies short enough to finish.
            start(soak.loop, f"{tag}:many-values-stream", key, private, "openai", "echo", True, counts=(10, 25))
            start(soak.loop, f"{tag}:slow-reader", key, private, "openai", "echo", True, counts=(5,), slow=True)
        if args.only != "plain":
            start(soak.hangup, "priv:hangup", K_PRIV_ABORT, True)
        if args.only != "private":
            start(soak.hangup, "plain:hangup", K_PLAIN_ABORT, False)
        start(soak.health)

        samples = []            # (seconds, gateway (rss, threads, handles), control (rss, ...))
        began = time.time()
        next_report = began + 60
        while time.time() - began < args.duration:
            samples.append((time.time() - began, sample_gw(gw_pid) if gw_pid else None, sample(cp_pid) if cp_pid else None))
            if time.time() >= next_report:
                next_report += 60
                with soak.lock:
                    done = sum(n for (_, o), n in soak.counts.items() if o in ("ok", "hung up"))
                    bad = sum(n for (_, o), n in soak.counts.items() if o == "PROBLEM")
                g, c = samples[-1][1], samples[-1][2]
                print(f"  t={time.time() - began:5.0f}s  requests {done}  problems {bad}  gateway rss {g[0] if g else -1:.1f} MiB thr {g[1] if g else -1}  control rss {c[0] if c else -1:.1f} MiB", flush=True)
            for name in ("gateway", "control", "mock_upstream"):
                if not stack.procs[name].alive():
                    soak.problem(name, "the process died")
                    soak.stop.set()
            if soak.stop.is_set():
                break
            time.sleep(10)
        elapsed = time.time() - began
        soak.stop.set()
        for t in threads:
            t.join(90)
        time.sleep(3)
        samples.append((time.time() - began, sample_gw(gw_pid) if gw_pid else None, sample(cp_pid) if cp_pid else None))

        # ---- report
        print("\nscenario                                   ok/hung-up  problems   p50 ms   p95 ms   p99 ms")
        scenarios = sorted({s for s, _ in soak.counts})
        for s in scenarios:
            ok = soak.counts.get((s, "ok"), 0) + soak.counts.get((s, "hung up"), 0)
            lat = soak.lat.get(s, [])
            row = f"{pct(lat, 0.50):8.1f} {pct(lat, 0.95):8.1f} {pct(lat, 0.99):8.1f}" if lat else ""
            print(f"  {s:40s} {ok:10d} {soak.counts.get((s, 'PROBLEM'), 0):9d} {row}")
        total = sum(n for (_, o), n in soak.counts.items() if o in ("ok", "hung up"))
        print(f"\n{total} requests in {elapsed:.0f} s: {total / elapsed:.1f} per second")
        for tag in ("priv", "plain"):
            lat = [ms for s, v in soak.lat.items() if s.startswith(tag + ":") and "many" not in s and "slow" not in s for ms in v]
            if lat:
                print(f"  latency, {tag} (ordinary bodies): p50 {pct(lat, 0.50):.1f} ms, p95 {pct(lat, 0.95):.1f} ms, p99 {pct(lat, 0.99):.1f} ms over {len(lat)} requests")
        print("\nmemory over time (MiB): seconds, gateway rss/threads/handles (memory mappings with --gateway-wsl), control plane rss")
        step = max(1, len(samples) // 16)
        for t, g, c in samples[::step] + [samples[-1]]:
            print(f"  {t:6.0f}s   gateway {g[0] if g else -1:7.1f} / {g[1] if g else -1} / {g[2] if g else -1}   control {c[0] if c else -1:7.1f}")

        print("\nverdicts")
        problems = sum(n for (_, o), n in soak.counts.items() if o == "PROBLEM")
        verdict("every answer was well-formed, restored and free of other requests' values", problems == 0, f"{problems} problems" if problems else f"{total} requests")
        for p in soak.problems[:15]:
            print("      " + p)

        _, _, watch = jcall("GET", "http://127.0.0.1:9002/__watch")
        seen = watch.get("seen", {})
        verdict("the providers never received a private request's value",
                all(seen.get(k) == 0 for k in (PRIV_WORD, PRIV_IP, PRIV_CARD)) and watch.get("requests", 0) > 0, json.dumps(watch))
        if args.only != "private":
            verdict("... and did receive the ordinary key's values (so the watch works)", seen.get(PLAIN_WORD, 0) > 0, seen.get(PLAIN_WORD))

        for name, key in (("private", K_PRIV), ("plain", K_PLAIN)):
            want = soak.usage[key]
            row = e2e.wait_until(lambda: (lambda r: r if r.get("requests") == want[0] else None)(usage_row(name)), 60, 1.0) or usage_row(name)
            got = [row.get("requests"), row.get("input_tokens"), row.get("output_tokens")]
            verdict(f"billed usage of key {name!r} equals what the providers reported to its clients (requests, tokens in, tokens out)",
                    got == want, f"billed {got}, clients saw {want}")
        for name in ("private-abort", "plain-abort"):
            row = usage_row(name)
            print(f"      {name}: {row.get('requests')} requests billed, {row.get('input_tokens')} in / {row.get('output_tokens')} out (aborted streams: estimates allowed)")

        g = [s[1] for s in samples if s[1]]
        c = [s[2] for s in samples if s[2]]
        if len(g) >= 8:
            third = len(g) // 3
            early, late = max(x[0] for x in g[third:2 * third]), max(x[0] for x in g[2 * third:])
            timed = [(s[0], s[1][0]) for s in samples if s[1]]
            last = timed[2 * len(timed) // 3:]
            slope = (last[-1][1] - last[0][1]) / max(1.0, (last[-1][0] - last[0][0]) / 60)
            print(f"      data plane rss: start {g[0][0]:.1f}, peak middle third {early:.1f}, peak last third {late:.1f}, end {g[-1][0]:.1f} MiB; last third {slope:+.2f} MiB per minute")
            verdict("the data plane's memory levels off (last third within 15% of the middle third)", late <= early * 1.15 + 2, f"peak {early:.1f} MiB in the middle third, {late:.1f} MiB in the last")
            # The data plane keeps the threads it started for the busiest moment; what must not happen is that they keep multiplying.
            t_early, t_late = max(x[1] for x in g[third:2 * third]), max(x[1] for x in g[2 * third:])
            h_early, h_late = max(x[2] for x in g[third:2 * third]), max(x[2] for x in g[2 * third:])
            verdict("the data plane's threads and handles do not keep growing", t_late <= t_early * 1.05 + 8 and h_late <= h_early * 1.05 + 40,
                    f"threads {t_early} -> {t_late}, handles {h_early} -> {h_late}")
        if len(c) >= 8:
            third = len(c) // 3
            early, late = max(x[0] for x in c[third:2 * third]), max(x[0] for x in c[2 * third:])
            print(f"      control plane rss: start {c[0][0]:.1f}, peak middle third {early:.1f}, peak last third {late:.1f}, end {c[-1][0]:.1f} MiB")
            verdict("the control plane's memory does not keep growing (last third within 25% of the middle third)", late <= early * 1.25 + 10, f"{early:.1f} -> {late:.1f} MiB")

        gw_log = open(stack.procs["gateway"].log_path, "rb").read().decode("utf-8", "replace")
        trips = [l for l in gw_log.splitlines() if "watchdog" in l.lower() or "panic" in l.lower()]
        verdict("no watchdog trip and no panic in the data plane's log", not trips, trips[:3])
        verdict("all three processes are still running", all(stack.procs[n].alive() for n in ("gateway", "control", "mock_upstream")))
    finally:
        stack.stop_all()

    hits = []
    needles = [PRIV_WORD.encode(), PRIV_CARD.encode()]
    for d, _, files in os.walk(work):
        for f in files:
            try:
                blob = open(os.path.join(d, f), "rb").read()
            except OSError:
                continue
            for n in needles:
                if n in blob:
                    hits.append((os.path.relpath(os.path.join(d, f), work), n.decode()))
    if args.gateway_wsl:
        script = f"grep -rl -e '{PRIV_WORD}' -e '{PRIV_CARD}' {wsl_dir}; rm -rf {wsl_dir}"
        found = subprocess.run(["wsl", "-e", "sh", "-c", script], capture_output=True, text=True).stdout.split()
        hits += [(f, "in the data plane's directory inside WSL") for f in found]
    verdict("no file written during the run contains a private request's value", not hits, hits[:5])
    if not args.keep:
        shutil.rmtree(work, ignore_errors=True)
    bad = [n for n, ok in verdicts if not ok]
    print(f"\n{'PASS' if not bad else 'FAIL'}: {len(verdicts) - len(bad)}/{len(verdicts)} verdicts")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
