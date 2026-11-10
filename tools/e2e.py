"""End-to-end test: starts the whole stack against mock providers and checks it.

    cd dataplane && zig build && cd ..
    python tools/e2e.py            # text gateway + media jobs
    python tools/e2e.py --only text
    python tools/e2e.py --keep     # leave logs and state in the temp dir

Starts tools/mock_upstream.py, tools/mock_media.py, the Elixir control plane
and the Zig data plane on their own ports (control 14000, gateway 18080) with
state in a fresh temp dir, so it never touches a dev instance's ledger.
Needs: python 3.9+, a built data plane, and `mix` (Erlang/Elixir). No API keys.
Exit code 0 only when every check passes.
"""

import argparse
import base64
import hashlib
import hmac
import http.client
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WINDOWS = os.name == "nt"
CONTROL_PORT = 14000
GATEWAY_PORT = 18080
CONTROL = f"http://127.0.0.1:{CONTROL_PORT}"
GATEWAY = f"http://127.0.0.1:{GATEWAY_PORT}"
TOKEN = "e2e-internal-token"
ADMIN_TOKEN = "e2e-admin-token-0123456789"

KEY_MAIN = "og-e2e-main"
KEY_BUDGET = "og-e2e-budget"
KEY_RPM = "og-e2e-rpm"
KEY_OTHER = "og-e2e-other"
WEBHOOK_SECRET = "e2e-webhook-secret"

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    mark = "PASS" if ok else "FAIL"
    print(f"  {mark}  {name}" + (f"   [{detail}]" if detail and not ok else ""), flush=True)
    return bool(ok)


def section(title):
    print(f"\n== {title}", flush=True)


# --------------------------------------------------------------------------
# processes
# --------------------------------------------------------------------------

class Proc:
    def __init__(self, name, cmd, cwd, env, log_dir):
        self.name = name
        self.log_path = os.path.join(log_dir, f"{name}.log")
        self.log = open(self.log_path, "ab")
        flags = subprocess.CREATE_NEW_PROCESS_GROUP if WINDOWS else 0
        self.p = subprocess.Popen(
            cmd, cwd=cwd, env=env, stdout=self.log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            creationflags=flags, start_new_session=not WINDOWS,
        )

    def alive(self):
        return self.p.poll() is None

    def stop(self):
        if self.p.poll() is None:
            if WINDOWS:
                # mix is a .bat that starts erl.exe: kill the whole tree.
                subprocess.run(["taskkill", "/F", "/T", "/PID", str(self.p.pid)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            else:
                try:
                    os.killpg(self.p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                self.p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
        self.log.close()

    def tail(self, lines=25):
        try:
            with open(self.log_path, "rb") as f:
                return b"\n".join(f.read().splitlines()[-lines:]).decode("utf-8", "replace")
        except OSError:
            return ""


def port_free(port):
    with socket.socket() as s:
        s.settimeout(0.3)
        return s.connect_ex(("127.0.0.1", port)) != 0


def wait_port(port, timeout, proc=None):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not port_free(port):
            return True
        if proc is not None and not proc.alive():
            return False
        time.sleep(0.15)
    return False


def wait_until(fn, timeout, interval=0.2):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(interval)
    return last


# --------------------------------------------------------------------------
# http
# --------------------------------------------------------------------------

def call(method, url, key=None, body=None, headers=None, timeout=30):
    """Returns (status, headers dict lower-cased, body bytes). Never raises on HTTP errors."""
    h = dict(headers or {})
    if key:
        h.setdefault("authorization", f"Bearer {key}")
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        h.setdefault("content-type", "application/json")
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()
    except (urllib.error.URLError, ConnectionError, socket.timeout) as e:
        return 0, {}, str(e).encode()


def jcall(method, url, **kw):
    status, headers, raw = call(method, url, **kw)
    try:
        return status, headers, json.loads(raw)
    except ValueError:
        return status, headers, {"_raw": raw[:300].decode("utf-8", "replace")}


def sse(url, key, body, headers=None):
    """POST and return (status, list of (event, data) pairs, seconds between first and last chunk)."""
    conn = http.client.HTTPConnection("127.0.0.1", GATEWAY_PORT, timeout=30)
    h = {"content-type": "application/json", "authorization": f"Bearer {key}"}
    h.update(headers or {})
    conn.request("POST", url, body=json.dumps(body), headers=h)
    resp = conn.getresponse()
    events, event, first, last = [], None, None, None
    while True:
        line = resp.readline()
        if not line:
            break
        now = time.perf_counter()
        first = first or now
        last = now
        line = line.decode("utf-8", "replace").rstrip("\r\n")
        if line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            events.append((event, line[5:].strip()))
            event = None
    conn.close()
    return resp.status, events, (last - first) if first else 0.0


def openai_stream_text(events):
    out = []
    for _, data in events:
        if data == "[DONE]":
            continue
        for choice in json.loads(data).get("choices", []):
            out.append(choice.get("delta", {}).get("content") or "")
    return "".join(out)


def anthropic_stream_text(events):
    out = []
    for _, data in events:
        obj = json.loads(data)
        if obj.get("type") == "content_block_delta":
            out.append(obj["delta"].get("text", ""))
    return "".join(out)


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def usage_row(key_name):
    _, _, body = jcall("GET", CONTROL + "/admin/usage", key=ADMIN_TOKEN)
    for row in body.get("keys", []):
        if row.get("name") == key_name:
            return row
    return {}


# --------------------------------------------------------------------------
# stack
# --------------------------------------------------------------------------

def text_config():
    price = {"price_in_per_mtok": 100.0, "price_out_per_mtok": 300.0}
    return {
        "keys": [
            {"name": "main", "key": KEY_MAIN, "webhook_secret": WEBHOOK_SECRET},
            {"name": "budget", "key": KEY_BUDGET, "budget_usd": 0.01},
            {"name": "rpm", "key": KEY_RPM, "rpm": 3},
            {"name": "other", "key": KEY_OTHER},
        ],
        "upstreams": [
            {"name": "mock-flaky", "kind": "openai", "base_url": "http://127.0.0.1:9001", "api_key_env": "MOCK_API_KEY"},
            {"name": "mock-ok", "kind": "openai", "base_url": "http://127.0.0.1:9002", "api_key_env": "MOCK_API_KEY"},
            {"name": "mock-anthropic", "kind": "anthropic", "base_url": "http://127.0.0.1:9003", "api_key_env": "MOCK_API_KEY"},
            {"name": "mock-slow", "kind": "openai", "base_url": "http://127.0.0.1:9004", "api_key_env": "MOCK_API_KEY", "timeout_ms": 500},
            # A provider whose OpenAI-compatible API is not under /v1 (Gemini's layout).
            {"name": "mock-compat", "kind": "openai", "base_url": "http://127.0.0.1:9002", "api_key_env": "MOCK_API_KEY", "v1_path": "/v1beta/openai"},
        ],
        "routes": [
            {"model": "chat", "targets": [dict(upstream="mock-flaky", model="flaky-1", **price),
                                          dict(upstream="mock-ok", model="ok-1", **price)]},
            {"model": "direct", "targets": [dict(upstream="mock-ok", model="ok-1", **price)]},
            {"model": "compat", "targets": [dict(upstream="mock-compat", model="ok-1", **price)]},
            {"model": "signed", "targets": [dict(upstream="mock-ok", model="sig-1", **price)]},
            {"model": "claude", "targets": [dict(upstream="mock-anthropic", model="mock-claude", **price)]},
            {"model": "slow", "targets": [dict(upstream="mock-slow", model="slow-1", **price),
                                          dict(upstream="mock-ok", model="ok-1", **price)]},
        ],
    }


class Stack:
    def __init__(self, work, config, media):
        self.work = work
        self.media = media
        self.procs = {}
        self.config_path = os.path.join(work, "omnigate.e2e.json")
        with open(self.config_path, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=2)

        self.env = dict(os.environ)
        if WINDOWS:
            extra = [r"C:\Program Files\Erlang OTP\bin", r"C:\Program Files\Elixir\bin"]
            self.env["PATH"] = os.pathsep.join(extra + [self.env.get("PATH", "")])
        self.env.update({
            "OMNIGATE_INTERNAL_TOKEN": TOKEN,
            "OMNIGATE_ADMIN_TOKEN": ADMIN_TOKEN,
            "MOCK_API_KEY": "mock-secret",
            "MOCK_WEBHOOK_SECRET": WEBHOOK_SECRET,  # read by tools/mock_media.py
            "PYTHONUNBUFFERED": "1",
        })

    def start(self, name, cmd, cwd=ROOT, env=None):
        full = dict(self.env)
        full.update(env or {})
        self.procs[name] = Proc(name, cmd, cwd, full, self.work)
        return self.procs[name]

    def stop(self, name):
        proc = self.procs.pop(name, None)
        if proc:
            proc.stop()

    def stop_all(self):
        for name in list(self.procs):
            self.stop(name)

    def fail(self, message, name=None):
        print(f"\nFATAL: {message}")
        if name and name in self.procs:
            print(f"--- last lines of {name}.log ---\n{self.procs[name].tail()}")
        self.stop_all()
        sys.exit(2)

    # -- individual services --------------------------------------------

    def start_mocks(self):
        ports = [9001, 9002, 9003, 9004] + (MEDIA_PORTS if self.media else [])
        busy = [p for p in ports + [CONTROL_PORT, GATEWAY_PORT] if not port_free(p)]
        if busy:
            self.fail(f"ports already in use: {busy}. Stop whatever is listening there and rerun.")
        self.start("mock_upstream", [sys.executable, os.path.join(ROOT, "tools", "mock_upstream.py")])
        if self.media:
            self.start_media_mock()
        for port in [9001, 9002, 9003, 9004]:
            if not wait_port(port, 15):
                self.fail(f"mock on port {port} did not start", "mock_upstream")

    def start_media_mock(self):
        self.start("mock_media", [sys.executable, os.path.join(ROOT, "tools", "mock_media.py")] + MEDIA_MOCK_ARGS)
        for port in MEDIA_PORTS:
            if not wait_port(port, 15):
                self.fail(f"media mock on port {port} did not start", "mock_media")

    def start_control(self):
        mix = shutil.which("mix", path=self.env["PATH"])
        if not mix:
            self.fail("`mix` not found; install Erlang/Elixir or put them on PATH")
        env = {
            "OMNIGATE_CONTROL_PORT": str(CONTROL_PORT),
            "OMNIGATE_CONFIG": self.config_path,
            "OMNIGATE_LEDGER": os.path.join(self.work, "ledger.jsonl"),
        }
        env.update(control_env(self.work))
        proc = self.start("control", [mix, "run", "--no-halt"], cwd=os.path.join(ROOT, "control"), env=env)
        if not wait_port(CONTROL_PORT, 240, proc):
            self.fail("control plane did not start", "control")

    def start_gateway(self):
        exe = os.path.join(ROOT, "dataplane", "zig-out", "bin", "omnigate-dp" + (".exe" if WINDOWS else ""))
        if not os.path.exists(exe):
            self.fail(f"{exe} not found; run `zig build` in dataplane/ first")
        proc = self.start("gateway", [exe], cwd=self.work, env={
            "OMNIGATE_LISTEN": f"127.0.0.1:{GATEWAY_PORT}",
            "OMNIGATE_CONTROL_URL": CONTROL,
            "OMNIGATE_POLL_MS": "300",
            "OMNIGATE_FLUSH_MS": "200",
        })
        if not wait_port(GATEWAY_PORT, 15, proc):
            self.fail("gateway did not start", "gateway")


# --------------------------------------------------------------------------
# text gateway
# --------------------------------------------------------------------------

CHAT = {"messages": [{"role": "user", "content": "hi"}]}
MOCK_TEXT = "Hello from the mock upstream."


def chat(model, key=KEY_MAIN, **extra):
    return jcall("POST", GATEWAY + "/v1/chat/completions", key=key, body=dict(CHAT, model=model, **extra))


def main_row_with(requests):
    """The main key's ledger row once it shows exactly `requests` text calls."""
    row = usage_row("main")
    # Media jobs are counted in `requests` too; leave them out.
    return row if row.get("requests", 0) - row.get("jobs", 0) == requests else None


def control_raw(method, path, headers=None, form=None):
    """One request to the control plane without following redirects."""
    conn = http.client.HTTPConnection("127.0.0.1", CONTROL_PORT, timeout=15)
    h = dict(headers or {})
    body = None
    if form is not None:
        body = "&".join(f"{k}={v}" for k, v in form.items())
        h["content-type"] = "application/x-www-form-urlencoded"
    conn.request(method, path, body=body, headers=h)
    resp = conn.getresponse()
    data = resp.read().decode("utf-8", "replace")
    out = (resp.status, {k.lower(): v for k, v in resp.getheaders()}, data)
    conn.close()
    return out


def login_checks():
    section("control-plane login")
    status, _, _ = control_raw("GET", "/healthz")
    check("health endpoint needs no credentials", status == 200)
    status, _, _ = control_raw("GET", "/admin/usage")
    check("the admin API refuses anonymous requests (401)", status == 401, status)
    status, _, _ = control_raw("GET", "/admin/usage", {"authorization": "Bearer " + TOKEN})
    check("the data planes' internal token is not an admin credential", status == 401, status)
    status, _, body = control_raw("GET", "/admin/usage", {"authorization": "Bearer " + ADMIN_TOKEN})
    check("the admin token opens the admin API", status == 200 and "keys" in body, status)

    status, headers, _ = control_raw("GET", "/")
    check("an anonymous browser is sent to the login page", status == 302 and headers.get("location") == "/login", (status, headers))
    status, headers, _ = control_raw("POST", "/login", form={"password": "wrong-token"})
    check("a wrong token gets no session", status == 401 and "set-cookie" not in headers, (status, headers))
    status, headers, _ = control_raw("POST", "/login", form={"password": ADMIN_TOKEN})
    cookie = headers.get("set-cookie", "")
    check("the right token gets a session cookie that scripts cannot read",
          status == 302 and "HttpOnly" in cookie and "SameSite=Strict" in cookie and ADMIN_TOKEN not in cookie, (status, cookie))
    session = cookie.split(";")[0]
    status, _, page = control_raw("GET", "/", {"cookie": session})
    check("the session opens the dashboard", status == 200 and "Sign out" in page, status)
    status, _, _ = control_raw("GET", "/", {"cookie": session + "x"})
    check("an altered session cookie is refused", status == 302, status)

    status, _, _ = call("GET", GATEWAY + "/admin/usage", key=KEY_MAIN)
    check("the public gateway port does not serve the admin API", status == 404, status)
    status, _, _ = call("GET", GATEWAY + "/admin/usage", key=ADMIN_TOKEN)
    check("... and the admin token is not a gateway key", status == 401, status)


def text_checks(stack):
    section("basics")
    status, _, raw = call("GET", GATEWAY + "/healthz")
    check("health endpoint answers", status == 200 and raw.strip() == b"ok")
    status, _, body = jcall("POST", GATEWAY + "/v1/chat/completions", body=dict(CHAT, model="chat"))
    check("no key is rejected with 401", status == 401, body)
    status, _, body = chat("chat", key="og-not-a-key")
    check("unknown key is rejected with 401", status == 401, body)
    status, _, body = jcall("GET", GATEWAY + "/v1/models", key=KEY_MAIN)
    check("model list shows the routes", status == 200 and {"chat", "claude"} <= {m["id"] for m in body.get("data", [])}, body)
    status, _, body = chat("no-such-model")
    check("unknown model is a 404", status == 404, body)

    main_calls = 0  # metered calls made with KEY_MAIN, to reconcile against the ledger

    section("failover and timeouts")
    status, headers, body = chat("chat")
    main_calls += 1
    check("503 from the first upstream fails over to the second",
          status == 200 and headers.get("x-omnigate-upstream") == "mock-ok", (status, headers))
    check("answer is intact and has a request id",
          body.get("choices", [{}])[0].get("message", {}).get("content") == MOCK_TEXT
          and len(headers.get("x-omnigate-request-id", "")) == 32, body)
    status, headers, body = chat("compat")
    main_calls += 1
    check("an upstream whose API is not under /v1 is reached at its own path (v1_path)",
          status == 200 and headers.get("x-omnigate-upstream") == "mock-compat", (status, body))
    t0 = time.time()
    status, headers, _ = chat("slow")
    main_calls += 1
    elapsed = time.time() - t0
    check("an upstream that takes 3 s is abandoned at its 0.5 s timeout",
          status == 200 and headers.get("x-omnigate-upstream") == "mock-ok" and elapsed < 2.5, f"{status} in {elapsed:.2f}s")

    section("streaming")
    status, events, spread = sse("/v1/chat/completions", KEY_MAIN, dict(CHAT, model="chat", stream=True))
    main_calls += 1
    check("OpenAI stream arrives complete",
          status == 200 and openai_stream_text(events) == MOCK_TEXT and events[-1][1] == "[DONE]", events[-3:])
    check("tokens arrive spread out, not in one burst", spread > 0.2, f"{spread:.3f}s")
    check("usage-only chunk is hidden from a client that did not ask for it",
          not any(d != "[DONE]" and json.loads(d).get("choices") == [] for _, d in events))
    status, events, _ = sse("/v1/chat/completions", KEY_MAIN,
                            dict(CHAT, model="chat", stream=True, stream_options={"include_usage": True}))
    main_calls += 1
    check("usage chunk is kept for a client that asked for it",
          any(d != "[DONE]" and json.loads(d).get("usage") for _, d in events))

    section("Anthropic protocol")
    msg = {"model": "claude", "max_tokens": 64, "messages": [{"role": "user", "content": "hi"}]}
    status, _, body = jcall("POST", GATEWAY + "/v1/messages", headers={"x-api-key": KEY_MAIN}, body=msg)
    main_calls += 1
    check("Anthropic messages passthrough works with x-api-key",
          status == 200 and body.get("content", [{}])[0].get("text") == MOCK_TEXT, body)
    status, events, _ = sse("/v1/messages", KEY_MAIN, dict(msg, stream=True))
    main_calls += 1
    check("Anthropic stream arrives complete",
          status == 200 and anthropic_stream_text(events) == MOCK_TEXT and events[-1][0] == "message_stop", events[-2:])
    status, _, body = jcall("POST", GATEWAY + "/v1/messages/count_tokens", key=KEY_MAIN, body=msg)
    check("token counting is forwarded (and not billed)", status == 200, body)

    section("protocol translation")
    status, headers, body = chat("claude")
    main_calls += 1
    check("OpenAI client reaches an Anthropic upstream",
          status == 200 and headers.get("x-omnigate-upstream") == "mock-anthropic"
          and body.get("object") == "chat.completion"
          and body["choices"][0]["message"]["content"] == MOCK_TEXT
          and body["choices"][0]["finish_reason"] == "stop"
          and body["usage"]["completion_tokens"] == 6 and body["model"] == "claude", body)
    status, events, _ = sse("/v1/chat/completions", KEY_MAIN, dict(CHAT, model="claude", stream=True))
    main_calls += 1
    check("... and streams from it in the OpenAI format",
          status == 200 and openai_stream_text(events) == MOCK_TEXT and events[-1][1] == "[DONE]", events[-2:])
    status, headers, body = chat("claude", temperature=0.2)
    main_calls += 1
    check("a parameter the other provider refuses (temperature) is dropped and the call retried",
          status == 200 and body["choices"][0]["message"]["content"] == MOCK_TEXT
          and headers.get("x-omnigate-attempts") == "1", (status, headers, body))
    status, _, body = jcall("POST", GATEWAY + "/v1/messages", key=KEY_MAIN, body=dict(msg, temperature=0.2))
    main_calls += 1
    check("... but a same-protocol client gets the provider's own error, untouched",
          status == 400 and body.get("type") == "error", (status, body))
    history = [{"role": "user", "content": "weather?"},
               {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_1", "name": "get_weather", "input": {"city": "Paris"}}]},
               {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_1", "content": "21C"}]}]
    status, _, body = jcall("POST", GATEWAY + "/v1/messages", key=KEY_MAIN, body=dict(msg, model="signed", messages=history))
    main_calls += 1
    check("a model that demands thought signatures on tool calls gets placeholders and answers",
          status == 200 and body.get("content", [{}])[0].get("text") == MOCK_TEXT, (status, body))
    amsg = dict(msg, model="direct")
    status, headers, body = jcall("POST", GATEWAY + "/v1/messages", key=KEY_MAIN, body=amsg)
    main_calls += 1
    check("Anthropic client reaches an OpenAI upstream",
          status == 200 and headers.get("x-omnigate-upstream") == "mock-ok" and body.get("type") == "message"
          and body["content"][0]["text"] == MOCK_TEXT and body["stop_reason"] == "end_turn"
          and body["usage"]["output_tokens"] == 6, body)
    status, events, _ = sse("/v1/messages", KEY_MAIN, dict(amsg, stream=True))
    main_calls += 1
    names = [e for e, _ in events]
    check("... and streams from it in the Anthropic format",
          status == 200 and anthropic_stream_text(events) == MOCK_TEXT
          and names[0] == "message_start" and names[-1] == "message_stop" and "message_delta" in names, names)

    section("rate limits")
    codes = [chat("direct", key=KEY_RPM)[0] for _ in range(3)]
    status, headers, body = chat("direct", key=KEY_RPM)
    check("a 3-per-minute key gets 3 calls, then 429 with Retry-After",
          codes == [200, 200, 200] and status == 429 and int(headers.get("retry-after", "0")) >= 1, (codes, status, headers))
    status, _, _ = chat("direct", key=KEY_OTHER)
    check("other keys are unaffected", status == 200)

    section("usage ledger and budgets")
    row = wait_until(lambda: main_row_with(main_calls), 10)
    check(f"ledger has exactly the {main_calls} metered calls of the main key", bool(row), usage_row("main"))
    row = row or usage_row("main")
    # Every call but one used at least 11 input tokens; the call the provider
    # refused with a 400 is in the ledger with none.
    check("tokens and cost are recorded",
          row.get("input_tokens", 0) >= 11 * (main_calls - 1) and row.get("cost_usd", 0) > 0 and row.get("errors", 0) >= 1, row)

    codes = [chat("direct", key=KEY_BUDGET)[0] for _ in range(4)]
    blocked = wait_until(lambda: chat("direct", key=KEY_BUDGET)[0] == 402, 10, 0.3)
    check("a $0.01 budget allows 4 calls, then the key gets 402", codes == [200] * 4 and blocked, codes)
    status, _, _ = chat("direct")
    main_calls += 1
    check("other keys keep working", status == 200)

    section("control-plane outage")
    stack.stop("control")
    wait_until(lambda: port_free(CONTROL_PORT), 10)
    codes = [chat("chat")[0] for _ in range(3)]
    main_calls += 3
    check("the gateway keeps serving while the control plane is down", codes == [200] * 3, codes)
    status, _, body = jcall("GET", GATEWAY + "/v1/jobs", key=KEY_MAIN)
    check("job requests say clearly that the control plane is unavailable (503)", status == 503, (status, body))

    # Restart the gateway too: it must come back from its cached config and
    # still hold the three unbilled calls in its spool.
    stack.stop("gateway")
    wait_until(lambda: port_free(GATEWAY_PORT), 10)
    stack.start_gateway()
    status, _, _ = chat("chat")
    main_calls += 1
    check("a gateway restarted during the outage serves from its cached config", status == 200, status)
    status, _, body = chat("direct", key=KEY_BUDGET)
    check("... and still refuses the over-budget key", status == 402, (status, body))

    stack.start_control()
    row = wait_until(lambda: main_row_with(main_calls), 30)
    check(f"after recovery every outage call is billed exactly once ({main_calls} total)", bool(row), usage_row("main"))


# --------------------------------------------------------------------------
# media jobs
# --------------------------------------------------------------------------

MEDIA_PORTS = [9101, 9102, 9103, 9104, 9105, 9106, 9107, 9108, 9109]
MEDIA_MOCK_ARGS = []
MOCK = {name: f"http://127.0.0.1:{port}" for name, port in [
    ("replicate", 9101), ("replicate_broken", 9102), ("fal", 9103), ("openai_images", 9104),
    ("elevenlabs", 9105), ("s3", 9106), ("webhooks", 9107), ("gemini", 9108), ("xai_video", 9109)]}
TERMINAL = ("succeeded", "failed", "canceled")


def control_env(work):
    return {
        "OMNIGATE_JOBS": os.path.join(work, "jobs.jsonl"),
        "E2E_S3_ACCESS_KEY": "mock-access-key",
        "E2E_S3_SECRET_KEY": "mock-secret-key",
    }


def media_config(work, storage="local"):
    stores = {
        "local": {"kind": "local", "dir": os.path.join(work, "media"), "url_ttl_s": 3600},
        "s3": {"kind": "s3", "endpoint": MOCK["s3"], "bucket": "e2e-bucket", "region": "us-east-1",
               "prefix": "outputs", "access_key_env": "E2E_S3_ACCESS_KEY", "secret_key_env": "E2E_S3_SECRET_KEY"},
    }
    up = lambda name, kind, url: {"name": name, "kind": kind, "base_url": url, "api_key_env": "MOCK_API_KEY"}
    return {
        "public_base_url": GATEWAY,
        "poll_interval_ms": 200,
        "upstreams": [
            up("replicate-broken", "replicate", MOCK["replicate_broken"]),
            up("replicate", "replicate", MOCK["replicate"]),
            up("fal", "fal", MOCK["fal"]),
            up("openai-images", "openai_images", MOCK["openai_images"]),
            up("elevenlabs", "elevenlabs", MOCK["elevenlabs"]),
            up("gemini", "gemini", MOCK["gemini"]),
            up("xai-video", "xai_video", MOCK["xai_video"]),
            up("gemini-interactions", "gemini_interactions", MOCK["gemini"]),
        ],
        "routes": [
            {"model": "image", "targets": [
                {"upstream": "replicate-broken", "model": "mock/broken-image", "price": {"per_output_usd": 0.004}},
                {"upstream": "replicate", "model": "mock/image", "price": {"per_output_usd": 0.003}}]},
            {"model": "video", "timeout_s": 120, "targets": [
                {"upstream": "fal", "model": "mock/video/text-to-video", "price": {"per_second_usd": 0.1}}]},
            {"model": "image-sync", "targets": [
                {"upstream": "openai-images", "model": "mock-image-1", "price": {"per_output_usd": 0.05}}]},
            {"model": "grok-video", "timeout_s": 60, "targets": [
                {"upstream": "xai-video", "model": "mock-imagine-video", "price": {"per_second_usd": 0.05}}]},
            {"model": "gemini-video", "timeout_s": 60, "targets": [
                {"upstream": "gemini-interactions", "model": "mock-omni-flash", "price": {"per_job_usd": 0.3}}]},
            {"model": "gemini-image", "targets": [
                {"upstream": "gemini", "model": "mock-flash-image", "price": {"per_output_usd": 0.02}}]},
            {"model": "gemini-speech", "targets": [
                {"upstream": "gemini", "model": "mock-flash-tts", "price": {"per_input_char_usd": 0.00001}}]},
            {"model": "tts", "cache_ttl_s": 3600, "targets": [
                {"upstream": "elevenlabs", "model": "mock_multilingual_v2", "price": {"per_input_char_usd": 0.00003}}]},
        ],
        "storage": stores[storage],
        "webhooks": {"allow_private": True, "retry_schedule_ms": [300, 300, 600, 1000], "max_attempts": 5},
    }


def create_job(body, key=KEY_MAIN, idem=None):
    headers = {"idempotency-key": idem} if idem else None
    return jcall("POST", GATEWAY + "/v1/jobs", key=key, body=body, headers=headers)


def get_job(job_id, key=KEY_MAIN):
    return jcall("GET", f"{GATEWAY}/v1/jobs/{job_id}", key=key)[2]


def wait_job(job_id, timeout=30, until=TERMINAL):
    return wait_until(lambda: (lambda j: j if j.get("status") in until else None)(get_job(job_id)), timeout, 0.2) or get_job(job_id)


def stats(name):
    return jcall("GET", MOCK[name] + "/_stats")[2]


def close(a, b):
    return a is not None and abs(a - b) < 1e-9


def media_checks(stack):
    section("media job: failover, re-hosting, idempotency")
    before = {n: stats(n) for n in ("replicate", "replicate_broken")}
    body = {"model": "image", "input": {"prompt": "a lighthouse at dusk"},
            "webhook_url": MOCK["webhooks"] + "/hook/fail/2", "metadata": {"order": "A-17"}}
    status, _, job = create_job(body, idem="e2e-image-1")
    check("job is accepted with 202", status == 202 and str(job.get("id", "")).startswith("job_")
          and job.get("status") in ("queued", "running"), (status, job))
    job_id = job.get("id", "missing")
    status, _, again = create_job(body, idem="e2e-image-1")
    check("same Idempotency-Key returns the same job, not a second one", status == 200 and again.get("id") == job_id, (status, again))
    status, _, conflict = create_job(dict(body, input={"prompt": "something else"}), idem="e2e-image-1")
    check("same Idempotency-Key with a different body is a 409", status == 409, (status, conflict))

    job = wait_job(job_id)
    outcomes = [(a["upstream"], a["outcome"]) for a in job.get("attempts", [])]
    check("job succeeds on the second provider after the first one fails",
          job.get("status") == "succeeded" and job.get("upstream") == "replicate"
          and len(outcomes) == 2 and outcomes[0][0] == "replicate-broken" and outcomes[0][1] != "ok", job)
    check("each provider was submitted to exactly once",
          stats("replicate")["submits"] - before["replicate"]["submits"] == 1
          and stats("replicate_broken")["submits"] - before["replicate_broken"]["submits"] == 1)
    check("metadata is echoed and the cost is the price of the provider that delivered",
          job.get("metadata") == {"order": "A-17"} and close(job.get("cost_usd"), 0.003), job.get("cost_usd"))

    out = (job.get("outputs") or [{}])[0]
    url = out.get("url", "")
    check("output URL points at the gateway, not at the provider", url.startswith(GATEWAY + "/v1/files/"), url)
    status, headers, data = call("GET", url)
    check("signed URL downloads the re-hosted file without a gateway key",
          status == 200 and hashlib.sha256(data).hexdigest() == out.get("sha256") and len(data) == out.get("bytes")
          and headers.get("content-type", "").startswith("image/png"), (status, len(data), out))
    status, _, _ = call("GET", url[:-4] + "0000")
    check("a tampered signature is refused (403)", status == 403, status)
    plain = url.split("?")[0]
    status, _, _ = call("GET", plain)
    check("no signature and no key is refused (401)", status == 401, status)
    status, _, data2 = call("GET", plain, key=KEY_MAIN)
    check("the owning key can download without a signature", status == 200 and data2 == data, status)
    status, _, _ = call("GET", plain, key=KEY_OTHER)
    check("another key cannot download it (404)", status == 404, status)
    status, _, other = jcall("GET", f"{GATEWAY}/v1/jobs/{job_id}", key=KEY_OTHER)
    check("another key cannot see the job (404)", status == 404, (status, other))

    section("webhooks")
    def delivered():
        recs = [d for d in jcall("GET", MOCK["webhooks"] + "/received")[2].get("deliveries", [])
                if d.get("webhook_id") == "msg_" + job_id]
        return recs if recs and recs[-1]["responded"] == 200 else None
    recs = wait_until(delivered, 20) or []
    check("webhook is retried after two 500s and then delivered",
          [d["responded"] for d in recs] == [500, 500, 200], [d.get("responded") for d in recs])
    check("every delivery carries a valid signature and the same message id",
          bool(recs) and all(d["signature_valid"] for d in recs))
    payload = recs[-1].get("payload", {}) if recs else {}
    check("payload names the event and carries the finished job",
          payload.get("type") == "job.succeeded" and payload.get("data", {}).get("id") == job_id, payload)
    hook = wait_until(lambda: (lambda w: w if w.get("status") == "delivered" else None)(get_job(job_id).get("webhook", {})), 10) or {}
    check("the job records the delivery (3 attempts)", hook.get("status") == "delivered" and hook.get("attempts") == 3, hook)
    status, _, refused = create_job({"model": "image", "input": {"prompt": "x"}, "webhook_url": "file:///etc/passwd"})
    check("a non-http webhook URL is refused at submit time", status == 400, (status, refused))

    section("other providers, cost and cache")
    status, _, video = create_job({"model": "video", "input": {"prompt": "waves", "duration": 5}})
    video = wait_job(video.get("id", "missing"))
    check("queue-style provider (fal shape) completes, billed per second",
          video.get("status") == "succeeded" and close(video.get("cost_usd"), 0.5) and video.get("outputs"), video)
    status, _, sync = create_job({"model": "image-sync", "input": {"prompt": "a red cube"}})
    sync = wait_job(sync.get("id", "missing"))
    check("synchronous provider (OpenAI images shape) is wrapped in the same job API",
          sync.get("status") == "succeeded" and close(sync.get("cost_usd"), 0.05) and sync.get("outputs"), sync)

    _, _, gimg = create_job({"model": "gemini-image", "input": {"prompt": "a green cube"}})
    gimg = wait_job(gimg.get("id", "missing"))
    data = call("GET", gimg["outputs"][0]["url"])[2] if gimg.get("outputs") else b""
    check("inline-file provider (Gemini shape) returns an image through the same job API",
          gimg.get("status") == "succeeded" and close(gimg.get("cost_usd"), 0.02) and data[:8] == b"\x89PNG\r\n\x1a\n", gimg)
    phrase = "Good morning."
    _, _, gtts = create_job({"model": "gemini-speech", "input": {"text": phrase, "voice": "Kore"}})
    gtts = wait_job(gtts.get("id", "missing"))
    data = call("GET", gtts["outputs"][0]["url"])[2] if gtts.get("outputs") else b""
    check("... and its raw PCM speech is stored as a playable WAV, billed per character",
          gtts.get("status") == "succeeded" and close(gtts.get("cost_usd"), len(phrase) * 0.00001)
          and data[:4] == b"RIFF" and data[8:12] == b"WAVE" and gtts["outputs"][0]["content_type"] == "audio/wav", (gtts, data[:12]))
    _, _, gblk = create_job({"model": "gemini-image", "input": {"prompt": "something blocked"}})
    gblk = wait_job(gblk.get("id", "missing"))
    check("a refused prompt fails the job with the reason and no charge",
          gblk.get("status") == "failed" and "SAFETY" in json.dumps(gblk.get("attempts")) and close(gblk.get("cost_usd") or 0.0, 0.0), gblk)
    _, _, gvid = create_job({"model": "grok-video", "input": {"prompt": "a wave", "duration": 4}})
    gvid = wait_job(gvid.get("id", "missing"))
    data = call("GET", gvid["outputs"][0]["url"])[2] if gvid.get("outputs") else b""
    check("request-id video provider (xAI shape) is polled to completion and billed per second",
          gvid.get("status") == "succeeded" and close(gvid.get("cost_usd"), 0.2) and data[4:8] == b"ftyp"
          and gvid["outputs"][0]["content_type"] == "video/mp4", gvid)
    _, _, gvf = create_job({"model": "grok-video", "input": {"prompt": "please fail", "duration": 4}})
    gvf = wait_job(gvf.get("id", "missing"))
    check("... and a generation the provider reports as failed fails the job unbilled",
          gvf.get("status") == "failed" and "mock generation failed" in json.dumps(gvf.get("attempts")) and close(gvf.get("cost_usd") or 0.0, 0.0), gvf)
    _, _, gomni = create_job({"model": "gemini-video", "input": {"prompt": "a short clip"}})
    gomni = wait_job(gomni.get("id", "missing"))
    data = call("GET", gomni["outputs"][0]["url"])[2] if gomni.get("outputs") else b""
    check("interactions-style provider (Gemini omni shape) returns a video in one call",
          gomni.get("status") == "succeeded" and close(gomni.get("cost_usd"), 0.3) and data[4:8] == b"ftyp"
          and gomni["outputs"][0]["content_type"] == "video/mp4", gomni)
    polls_before = stats("gemini")["polls"]
    _, _, gbg = create_job({"model": "gemini-video", "input": {"input": "a longer clip", "background": True}})
    gbg = wait_job(gbg.get("id", "missing"))
    check("... and a background interaction is polled until it completes",
          gbg.get("status") == "succeeded" and gbg.get("outputs") and stats("gemini")["polls"] > polls_before, (gbg, stats("gemini")))
    gemini_cost = 0.02 + len(phrase) * 0.00001 + 0.2 + 0.3 + 0.3

    text = "Your order has shipped and will arrive on Thursday."
    calls_before = stats("elevenlabs")["calls"]
    tts_body = {"model": "tts", "input": {"text": text, "voice_id": "mock-voice"}}
    _, _, first = create_job(tts_body)
    first = wait_job(first.get("id", "missing"))
    check("text-to-speech job completes, billed per character",
          first.get("status") == "succeeded" and not first.get("cached") and close(first.get("cost_usd"), len(text) * 0.00003), first)
    _, _, second = create_job(tts_body)
    second = wait_job(second.get("id", "missing"))
    check("an identical request is served from cache: no provider call, no charge",
          second.get("status") == "succeeded" and second.get("cached") is True and close(second.get("cost_usd"), 0.0)
          and stats("elevenlabs")["calls"] - calls_before == 1, (second, stats("elevenlabs")))
    a = call("GET", first["outputs"][0]["url"])[2] if first.get("outputs") else b"a"
    b = call("GET", second["outputs"][0]["url"])[2] if second.get("outputs") else b"b"
    check("the cached job has its own downloadable copy of the audio", a == b and len(a) > 0)

    _, _, listing = jcall("GET", GATEWAY + "/v1/jobs?limit=50", key=KEY_MAIN)
    ids = [j["id"] for j in listing.get("data", [])]
    check("job list shows this key's jobs, newest first", ids[:1] == [second.get("id")] and job_id in ids, ids)
    _, _, other_list = jcall("GET", GATEWAY + "/v1/jobs", key=KEY_OTHER)
    check("another key's job list is empty", other_list.get("data") == [], other_list)

    expected = 0.003 + 0.5 + 0.05 + len(text) * 0.00003 + gemini_cost
    row = wait_until(lambda: (lambda r: r if close(r.get("cost_usd"), expected) else None)(usage_row("main")), 10) or usage_row("main")
    check("the ledger total equals the sum of the job costs", close(row.get("cost_usd"), expected), (row, expected))

    section("cancel")
    _, _, slow = create_job({"model": "video", "input": {"prompt": "slow", "duration": 5, "mock_delay_s": 20}})
    wait_job(slow.get("id", "missing"), 10, until=("running",) + TERMINAL)
    status, _, canceled = jcall("POST", f"{GATEWAY}/v1/jobs/{slow.get('id')}/cancel", key=KEY_MAIN, body={})
    canceled = wait_job(slow.get("id", "missing"), 10)
    check("a running job can be canceled and is not billed",
          canceled.get("status") == "canceled" and close(canceled.get("cost_usd") or 0.0, 0.0), canceled)

    section("control-plane restart in the middle of a job")
    submits_before = stats("fal")["submits"]
    hooks_before = len(jcall("GET", MOCK["webhooks"] + "/received")[2].get("deliveries", []))
    _, _, long_job = create_job({"model": "video", "input": {"prompt": "long", "duration": 4, "mock_delay_s": 6},
                                 "webhook_url": MOCK["webhooks"] + "/hook"})
    long_id = long_job.get("id", "missing")
    wait_job(long_id, 10, until=("running",) + TERMINAL)
    time.sleep(1.0)  # let the provider-side id reach disk
    stack.stop("control")
    wait_until(lambda: port_free(CONTROL_PORT), 10)
    stack.start_control()
    resumed = wait_job(long_id, 40)
    check("the job survives the restart and succeeds", resumed.get("status") == "succeeded", resumed)
    check("it was not submitted to the provider a second time", stats("fal")["submits"] - submits_before == 1, stats("fal"))
    check("it is billed once", close(resumed.get("cost_usd"), 0.4), resumed.get("cost_usd"))
    def long_hooks():
        recs = [d for d in jcall("GET", MOCK["webhooks"] + "/received")[2].get("deliveries", [])[hooks_before:]
                if d.get("webhook_id") == "msg_" + long_id]
        return recs or None
    recs = wait_until(long_hooks, 15) or []
    time.sleep(1.0)
    recs = long_hooks() or []
    check("its webhook arrives exactly once", len(recs) == 1 and recs[0]["responded"] == 200, recs)
    row = wait_until(lambda: (lambda r: r if close(r.get("cost_usd"), expected + 0.4) else None)(usage_row("main")), 10) or usage_row("main")
    check("the ledger was rebuilt correctly after the restart", close(row.get("cost_usd"), expected + 0.4), row)
    wait_until(lambda: call("GET", GATEWAY + "/v1/models", key=KEY_MAIN)[0] == 200, 10)

    section("outputs in the customer's own bucket (S3 API)")
    config = text_config()
    config["media"] = media_config(stack.work, storage="s3")
    with open(stack.config_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)
    s3_before = stats("s3")
    def s3_job():
        _, _, j = create_job({"model": "image", "input": {"prompt": "bucket test " + str(time.time())}})
        j = wait_job(j.get("id", "missing"))
        url = (j.get("outputs") or [{}])[0].get("url", "")
        return j if url.startswith(MOCK["s3"]) else None
    s3 = wait_until(s3_job, 20, 1.0) or {}
    out = (s3.get("outputs") or [{}])[0]
    check("after a config hot reload, outputs are written to the bucket",
          s3.get("status") == "succeeded" and out.get("url", "").startswith(MOCK["s3"] + "/e2e-bucket/"), s3)
    s3_after = stats("s3")
    check("the bucket accepted the signed upload (SigV4 verified by the mock)",
          s3_after["puts"] > s3_before["puts"] and s3_after["rejected"] == s3_before["rejected"], (s3_before, s3_after))
    status, _, data = call("GET", out.get("url", MOCK["s3"]))
    check("the presigned URL downloads the same bytes",
          status == 200 and hashlib.sha256(data).hexdigest() == out.get("sha256"), (status, data[:300], out.get("url")))
    status, _, _ = call("GET", out.get("url", MOCK["s3"]).split("?")[0])
    check("the bucket refuses an unsigned download", status == 403, status)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="omnigate end-to-end test against mock providers")
    ap.add_argument("--only", choices=["text", "media"], help="run one half only")
    ap.add_argument("--keep", action="store_true", help="keep the temp dir (logs, ledger, outputs)")
    args = ap.parse_args()
    run_text = args.only in (None, "text")
    run_media = args.only in (None, "media")

    work = tempfile.mkdtemp(prefix="omnigate-e2e-")
    config = text_config()
    if run_media:
        config["media"] = media_config(work)
    stack = Stack(work, config, run_media)
    print(f"state and logs: {work}")
    started = time.time()
    try:
        stack.start_mocks()
        stack.start_control()
        stack.start_gateway()
        if not wait_until(lambda: call("GET", GATEWAY + "/v1/models", key=KEY_MAIN)[0] == 200, 15):
            stack.fail("gateway never received its config from the control plane", "gateway")
        login_checks()
        if run_media:
            media_checks(stack)
        if run_text:
            text_checks(stack)
    finally:
        stack.stop_all()

    failed = [name for name, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed in {time.time() - started:.0f}s")
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
