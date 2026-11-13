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
import csv
import base64
import hashlib
import hmac
import http.client
import json
import os
import re
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
sys.path.insert(0, os.path.join(ROOT, "tools"))
import mock_intents as mock_intents_module  # the payment provider's stand-in: its signing key goes into the config

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fastbind  # noqa: E402,F401  (servers start without a DNS lookup)
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
KEY_SUME = "og-e2e-sume"
KEY_ELEVEN = "og-e2e-eleven"
KEY_LIMITED = "og-e2e-limited"
# Privacy mode: everything on; redaction of two classes only; job outputs
# encrypted to an age recipient.
KEY_PRIVATE = "og-e2e-private"
KEY_REDACT = "og-e2e-redact"
KEY_SEALED = "og-e2e-sealed"
# No privacy mode: the comparison in the privacy checks. (Not the main key,
# whose calls are reconciled against the ledger one by one.)
KEY_PLAIN = "og-e2e-plain"
# Privacy mode with `attested` only: its requests may go to attested providers alone.
KEY_ATTESTED = "og-e2e-attested"
# A second data plane, in front of a control plane played by this script
# (see `attestation_checks`).
# The payment provider's stand-in (tools/mock_intents.py).
INTENTS_PORT = 9120
FAKE_CONTROL_PORT = 14001
GATEWAY2_PORT = 18081
GATEWAY2 = f"http://127.0.0.1:{GATEWAY2_PORT}"
# A second data plane of the real control plane (see `shared_limit_checks`).
GATEWAY3_PORT = 18082
GATEWAY3 = f"http://127.0.0.1:{GATEWAY3_PORT}"
WEBHOOK_SECRET = "e2e-webhook-secret"

# A string that only ever goes into private requests. After the run, no file
# the gateway or the control plane wrote may contain it.
CANARY = "CANARY-e2e-7f3a9c41"
PII = {
    "email": "bob.stone@example.com",
    "phone": "+1 (555) 123-4567",
    "ip": "10.20.30.40",
    "secret": "sk-proj-Abc123Def456Ghi789Jkl012",
    "card": "4111 1111 1111 1111",
}
PRIVATE_TEXT = (f"{CANARY}: mail {PII['email']}, call {PII['phone']}, host {PII['ip']}, "
                f"key {PII['secret']}, card {PII['card']}.")
PLACEHOLDERS = ("[EMAIL_1]", "[PHONE_1]", "[IP_1]", "[SECRET_1]", "[CARD_1]")

# An independent implementation of the age format (the Rust one), to decrypt
# what the gateway encrypted. Optional locally; CI installs it and sets
# OMNIGATE_REQUIRE_PYRAGE=1 so that the check cannot be skipped there.
try:
    import pyrage
except ImportError:
    pyrage = None
if pyrage:
    AGE_IDENTITY = pyrage.x25519.Identity.generate()
    AGE_RECIPIENT = str(AGE_IDENTITY.to_public())
else:
    AGE_IDENTITY = None
    # The example recipient of the age documentation: nobody here can read
    # what is encrypted to it, which is all a run without pyrage needs.
    AGE_RECIPIENT = "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"

results = []
# The run's state directory (set in main).
WORK = ""


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
            {"name": "sume", "key": KEY_SUME},
            {"name": "eleven", "key": KEY_ELEVEN},
            # May use the "direct" route and nothing else.
            {"name": "limited", "key": KEY_LIMITED, "models": ["direct"]},
            {"name": "private", "key": KEY_PRIVATE, "privacy": True, "webhook_secret": WEBHOOK_SECRET},
            {"name": "redact-only", "key": KEY_REDACT, "privacy": {"redact": ["email", "secret"]}},
            {"name": "sealed", "key": KEY_SEALED, "privacy": {"encrypt_to": AGE_RECIPIENT}},
            {"name": "plain", "key": KEY_PLAIN, "webhook_secret": WEBHOOK_SECRET},
            {"name": "attested", "key": KEY_ATTESTED, "privacy": {"attested": True}},
        ],
        "upstreams": [
            {"name": "mock-flaky", "kind": "openai", "base_url": "http://127.0.0.1:9001", "api_key_env": "MOCK_API_KEY"},
            {"name": "mock-ok", "kind": "openai", "base_url": "http://127.0.0.1:9002", "api_key_env": "MOCK_API_KEY"},
            {"name": "mock-anthropic", "kind": "anthropic", "base_url": "http://127.0.0.1:9003", "api_key_env": "MOCK_API_KEY"},
            {"name": "mock-slow", "kind": "openai", "base_url": "http://127.0.0.1:9004", "api_key_env": "MOCK_API_KEY", "timeout_ms": 500},
            # A provider whose OpenAI-compatible API is not under /v1 (Gemini's layout).
            {"name": "mock-compat", "kind": "openai", "base_url": "http://127.0.0.1:9002", "api_key_env": "MOCK_API_KEY", "v1_path": "/v1beta/openai"},
            # Nothing listens here: every call is refused at once.
            {"name": "mock-dead", "kind": "openai", "base_url": "http://127.0.0.1:9", "api_key_env": "MOCK_API_KEY"},
            # The working mock again, declared to take OpenAI's `"store": false`.
            {"name": "mock-store", "kind": "openai", "base_url": "http://127.0.0.1:9002", "api_key_env": "MOCK_API_KEY",
             "privacy_store_flag": True},
            # The working mock once more, as a provider that has to prove what
            # it runs on. Its evidence never verifies (it cannot: see
            # `attestation_report` in tools/mock_upstream.py).
            {"name": "mock-attested", "kind": "openai", "base_url": "http://127.0.0.1:9002", "api_key_env": "MOCK_API_KEY",
             "attestation": {"provider": "near", "gpu": "skip", "max_age_s": 60}},
        ],
        "routes": [
            {"model": "chat", "targets": [dict(upstream="mock-flaky", model="flaky-1", **price),
                                          dict(upstream="mock-ok", model="ok-1", **price)]},
            {"model": "direct", "targets": [dict(upstream="mock-ok", model="ok-1", **price)]},
            {"model": "compat", "targets": [dict(upstream="mock-compat", model="ok-1", **price)]},
            {"model": "signed", "targets": [dict(upstream="mock-ok", model="sig-1", **price)]},
            {"model": "cached", "cache_ttl_s": 60, "targets": [dict(upstream="mock-ok", model="ok-1", **price)]},
            # The first target answers 429 (with retry-after: 7), the second is down.
            {"model": "limited-then-dead", "targets": [dict(upstream="mock-ok", model="rate-limited-1", **price),
                                                       dict(upstream="mock-dead", model="x", **price)]},
            # The same mock under two upstream names, so the response header tells them apart.
            {"model": "spread", "strategy": "round_robin", "targets": [dict(upstream="mock-ok", model="ok-1", **price),
                                                                       dict(upstream="mock-compat", model="ok-1", **price)]},
            {"model": "skewed", "strategy": "weighted", "targets": [dict(upstream="mock-ok", model="ok-1", weight=0, **price),
                                                                    dict(upstream="mock-compat", model="ok-1", weight=5, **price)]},
            {"model": "claude", "targets": [dict(upstream="mock-anthropic", model="mock-claude", **price)]},
            {"model": "slow", "targets": [dict(upstream="mock-slow", model="slow-1", **price),
                                          dict(upstream="mock-ok", model="ok-1", **price)]},
            # Models that answer with what they were sent (see tools/mock_upstream.py).
            {"model": "echo", "targets": [dict(upstream="mock-ok", model="echo-1", **price)]},
            {"model": "echo-claude", "targets": [dict(upstream="mock-anthropic", model="echo-1", **price)]},
            {"model": "echo-store", "targets": [dict(upstream="mock-store", model="echo-1", **price)]},
            {"model": "echo-cached", "cache_ttl_s": 60, "targets": [dict(upstream="mock-ok", model="echo-1", **price)]},
            {"model": "echo-err", "targets": [dict(upstream="mock-ok", model="echo-err-1", **price)]},
            # Attested upstreams whose evidence does not hold, alone and in front of an ordinary target.
            {"model": "tee-only", "targets": [dict(upstream="mock-attested", model="attest-garbage-1", **price),
                                              dict(upstream="mock-attested", model="attest-html-1", **price),
                                              dict(upstream="mock-attested", model="attest-none-1", **price)]},
            {"model": "tee-then-plain", "targets": [dict(upstream="mock-attested", model="attest-stale-1", **price),
                                                    dict(upstream="mock-ok", model="ok-1", **price)]},
        ],
        # Payments for prepaid credit, through the NEAR Intents adapter, with
        # tools/mock_intents.py as the provider (and its key as the one quotes
        # must be signed with).
        "payments": {"provider": "near_intents", "recipient": "operator.near", "base_url": f"http://127.0.0.1:{INTENTS_PORT}",
                     "public_key": mock_intents_module.PUBLIC_KEY, "poll_interval_s": 1, "min_usd": 1, "max_usd": 1000, "quote_ttl_s": 600},
    }


class Stack:
    def __init__(self, work, config, media):
        self.work = work
        self.media = media
        # The payment provider's stand-in runs only for a config that takes payments.
        self.payments = "payments" in config
        self.procs = {}
        # Extra settings for the gateway, kept across its restarts.
        self.gateway_env = {}
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
        ports = [9001, 9002, 9003, 9004, 9005] + (MEDIA_PORTS if self.media else []) + ([INTENTS_PORT] if self.payments else [])
        busy = [p for p in ports + [CONTROL_PORT, GATEWAY_PORT] if not port_free(p)]
        if busy:
            self.fail(f"ports already in use: {busy}. Stop whatever is listening there and rerun.")
        self.start("mock_upstream", [sys.executable, os.path.join(ROOT, "tools", "mock_upstream.py")])
        if self.media:
            self.start_media_mock()
        if self.payments:
            self.start("mock_intents", [sys.executable, os.path.join(ROOT, "tools", "mock_intents.py"), str(INTENTS_PORT)])
            if not wait_port(INTENTS_PORT, 15):
                self.fail("the payment provider mock did not start", "mock_intents")
        for port in [9001, 9002, 9003, 9004, 9005]:
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

    def start_gateway(self, extra_env=None):
        exe = os.path.join(ROOT, "dataplane", "zig-out", "bin", "omnigate-dp" + (".exe" if WINDOWS else ""))
        if not os.path.exists(exe):
            self.fail(f"{exe} not found; run `zig build` in dataplane/ first")
        env = {
            "OMNIGATE_LISTEN": f"127.0.0.1:{GATEWAY_PORT}",
            "OMNIGATE_CONTROL_URL": CONTROL,
            "OMNIGATE_POLL_MS": "300",
            "OMNIGATE_FLUSH_MS": "200",
        }
        env.update(extra_env or self.gateway_env)
        proc = self.start("gateway", [exe], cwd=self.work, env=env)
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


def control_raw(method, path, headers=None, form=None, raw=None):
    """One request to the control plane without following redirects."""
    conn = http.client.HTTPConnection("127.0.0.1", CONTROL_PORT, timeout=15)
    h = dict(headers or {})
    body = raw
    if form is not None:
        body = "&".join(f"{k}={v}" for k, v in form.items())
        h["content-type"] = "application/x-www-form-urlencoded"
    # A request that is refused before its body is read is answered and the
    # connection closed with the body still unread; on some systems that
    # close reaches the client as a reset ahead of the answer. Such a request
    # changed nothing, so it is simply sent again.
    for attempt in range(4):
        try:
            conn.request(method, path, body=body, headers=h)
            resp = conn.getresponse()
            data = resp.read().decode("utf-8", "replace")
            out = (resp.status, {k.lower(): v for k, v in resp.getheaders()}, data)
            conn.close()
            return out
        except (ConnectionResetError, ConnectionAbortedError):
            conn.close()
            if attempt == 3:
                raise
            conn = http.client.HTTPConnection("127.0.0.1", CONTROL_PORT, timeout=15)
            time.sleep(0.1)


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

    codes = [control_raw("GET", path)[0] for path in ("/%61dmin/keys", "/adm%69n/overview", "/%6Detrics", "/%69nternal/config")]
    status, _, body = control_raw("POST", "/%61dmin/keys", {"content-type": "application/json"}, raw=json.dumps({"name": "bypass-probe"}))
    check("percent-encoded spellings of protected paths are refused, not routed",
          codes == [400, 400, 400, 400] and status == 400 and "og-" not in body, (codes, status, body[:80]))

    status, _, _ = control_raw("GET", "/metrics")
    check("metrics refuse anonymous requests (401)", status == 401, status)
    status, headers, text = control_raw("GET", "/metrics", {"authorization": "Bearer " + ADMIN_TOKEN})
    lines = [l for l in text.splitlines() if l and not l.startswith("#")]
    check("metrics are served in Prometheus text format to the admin token",
          status == 200 and headers.get("content-type", "").startswith("text/plain")
          and any(l.startswith("omnigate_build_info") for l in lines) and any('key="main"' in l for l in lines)
          and all(len(l.rsplit(" ", 1)) == 2 for l in lines), (status, headers.get("content-type"), lines[:3]))

    status, _, _ = call("GET", GATEWAY + "/admin/usage", key=KEY_MAIN)
    check("the public gateway port does not serve the admin API", status == 404, status)
    status, _, _ = call("GET", GATEWAY + "/admin/usage", key=ADMIN_TOKEN)
    check("... and the admin token is not a gateway key", status == 401, status)


def admin(method, path, body=None):
    return jcall(method, CONTROL + path, key=ADMIN_TOKEN, body=body)


def key_checks():
    """Gateway keys created, changed and revoked through the admin API, with no config edit."""
    section("key management")
    name = "e2e-managed"
    status, _, created = admin("POST", "/admin/keys", {"name": name, "models": ["direct"]})
    secret = created.get("key", "")
    check("a key can be created through the admin API and is shown once",
          status == 201 and secret.startswith("og-") and len(secret) >= 35 and created.get("source") == "managed", (status, {k: v for k, v in created.items() if k != "key"}))
    usable = wait_until(lambda: chat("direct", key=secret)[0] == 200, 6, 0.2)
    check("the gateway accepts the new key within seconds, without a restart", bool(usable))
    status, _, body = chat("chat", key=secret)
    check("... and enforces the model limit it was created with", status == 403, (status, body))
    status, _, listing = admin("GET", "/admin/keys")
    row = next((k for k in listing.get("keys", []) if k.get("name") == name), {})
    check("the key list shows it with its usage and never its secret",
          status == 200 and row.get("source") == "managed" and row.get("state") == "active"
          and secret not in json.dumps(listing) and "key" not in row and "key_sha256" not in row, row)
    status, _, _ = admin("POST", "/admin/keys", {"name": name})
    check("a duplicate name is refused (409)", status == 409, status)
    status, _, body = admin("PATCH", "/admin/keys/main", {"rpm": 1})
    check("keys from the config file cannot be changed through the API (409)", status == 409, (status, body))

    status, _, rotated = admin("POST", f"/admin/keys/{name}/rotate")
    fresh = rotated.get("key", "")
    check("rotating returns a new secret", status == 200 and fresh.startswith("og-") and fresh != secret, status)
    swapped = wait_until(lambda: chat("direct", key=secret)[0] == 401 and chat("direct", key=fresh)[0] == 200, 6, 0.2)
    check("... after which the old secret stops working and the new one works", bool(swapped))

    status, _, _ = admin("PATCH", f"/admin/keys/{name}", {"disabled": True})
    off = wait_until(lambda: chat("direct", key=fresh)[0] == 401, 6, 0.2)
    check("a disabled key is refused", status == 200 and bool(off), status)
    status, _, _ = admin("PATCH", f"/admin/keys/{name}", {"disabled": False})
    on = wait_until(lambda: chat("direct", key=fresh)[0] == 200, 6, 0.2)
    check("... and works again when re-enabled", status == 200 and bool(on), status)

    status, _, patched = admin("PATCH", f"/admin/keys/{name}", {"budget_usd": 5, "budget_period": "monthly"})
    check("a key can be given a monthly budget, with the reset time shown",
          status == 200 and patched.get("budget_period") == "monthly" and str(patched.get("period_resets_at", "")).endswith("-01T00:00:00Z"), patched)

    status, _, _ = admin("DELETE", f"/admin/keys/{name}")
    gone = wait_until(lambda: chat("direct", key=fresh)[0] == 401, 6, 0.2)
    _, _, listing = admin("GET", "/admin/keys")
    check("a deleted key is gone from the list and refused by the gateway",
          status == 200 and bool(gone) and not any(k.get("name") == name for k in listing.get("keys", [])), status)

    status, _, audit = admin("GET", "/admin/audit?limit=50")
    actions = [(e.get("action"), e.get("target")) for e in audit.get("entries", [])]
    check("every key change is in the admin audit log, without secrets",
          status == 200 and all((a, name) in actions for a in ("key.create", "key.rotate", "key.update", "key.delete"))
          and secret not in json.dumps(audit) and fresh not in json.dumps(audit), actions[:8])

    # A browser session must present a CSRF token for changes; the bearer token above did not need one.
    _, headers, _ = control_raw("POST", "/login", form={"password": ADMIN_TOKEN})
    session = headers.get("set-cookie", "").split(";")[0]
    status, _, body = control_raw("POST", "/admin/keys", {"cookie": session, "content-type": "application/json"}, raw=json.dumps({"name": "csrf-probe"}))
    check("a browser session without a CSRF token cannot change keys (403)", status == 403 and "csrf" in body.lower(), (status, body[:120]))
    status, _, page = control_raw("GET", "/", {"cookie": session})
    check("the dashboard page renders for a session and lists the keys", status == 200 and "Sign out" in page and "main" in page, status)
    status, _, overview = admin("GET", "/admin/overview")
    check("the overview feed the dashboard polls has totals, keys, requests, jobs and config",
          status == 200 and all(k in overview for k in ("totals", "today", "keys", "requests", "jobs", "config")), list(overview)[:8])


def shared_limit_checks(stack):
    """Two data planes of one control plane share a key's requests-per-minute limit."""
    section("rate limit across two data planes")
    status, _, created = admin("POST", "/admin/keys", {"name": "e2e-shared-rpm", "models": ["direct"], "rpm": 6})
    secret = created.get("key", "")
    exe = os.path.join(ROOT, "dataplane", "zig-out", "bin", "omnigate-dp" + (".exe" if WINDOWS else ""))
    work = os.path.join(stack.work, "gateway3")
    os.makedirs(work, exist_ok=True)
    env = {"OMNIGATE_LISTEN": f"127.0.0.1:{GATEWAY3_PORT}", "OMNIGATE_CONTROL_URL": CONTROL, "OMNIGATE_POLL_MS": "300", "OMNIGATE_FLUSH_MS": "200",
           "OMNIGATE_LIMIT_SYNC_MS": "200"}
    env.update(stack.gateway_env)
    proc = stack.start("gateway3", [exe], cwd=work, env=env)
    try:
        if not wait_port(GATEWAY3_PORT, 15, proc):
            stack.fail("the second data plane did not start", "gateway3")
        ask = lambda base: jcall("POST", base + "/v1/chat/completions", key=secret, body=dict(CHAT, model="direct"))
        models = lambda base: call("GET", base + "/v1/models", key=secret)[0] == 200
        ready = wait_until(lambda: models(GATEWAY) and models(GATEWAY3), 15)

        def planes():
            _, _, text = control_raw("GET", "/metrics", {"authorization": "Bearer " + ADMIN_TOKEN})
            return "omnigate_data_planes 2" in text.splitlines() or None
        check("the control plane counts two data planes (omnigate_data_planes)", status == 201 and bool(ready) and bool(wait_until(planes, 10)))

        # Six a minute. Four on the first data plane; the second must hear of
        # them (the first reports once a second) and allow only the other two.
        first = [ask(GATEWAY)[0] for _ in range(4)]
        time.sleep(2.5)
        answers = [ask(GATEWAY3) for _ in range(6)]
        second = [a[0] for a in answers]
        check("a key with rpm 6 gets four requests on one data plane, then two (not six) on the other",
              first == [200] * 4 and second in ([200, 200, 429, 429, 429, 429], [200, 200, 200, 429, 429, 429]), (first, second))
        refusal = next((a for a in answers if a[0] == 429), (0, {}, {}))
        check("... and the refusal there is the usual one: rate_limit_exceeded with Retry-After",
              ((refusal[2] or {}).get("error") or {}).get("code") == "rate_limit_exceeded" and (refusal[1].get("retry-after") or "").isdigit(), (refusal[1].get("retry-after"), refusal[2]))
        # And back: what the second allowed is taken out of the first one's bucket.
        time.sleep(1.5)
        back = [ask(GATEWAY)[0] for _ in range(2)]
        check("the first data plane has heard of those two and allows no more", back == [429, 429], back)
    finally:
        stack.stop("gateway3")
    admin("DELETE", "/admin/keys/e2e-shared-rpm")


def example(script, *args, env=None):
    """Run one of examples/*.py against this stack. Returns (exit code, stdout, stderr)."""
    full_env = dict(os.environ, OMNIGATE_CONTROL=CONTROL, OMNIGATE_GATEWAY=GATEWAY, OMNIGATE_ADMIN_TOKEN=ADMIN_TOKEN, **(env or {}))
    done = subprocess.run([sys.executable, os.path.join(ROOT, "examples", script), *args], env=full_env, capture_output=True, text=True, timeout=120)
    return done.returncode, done.stdout, done.stderr


def build_around_checks(work):
    """What outside tools build on: top-ups by payment reference, the usage feed, the request tag; and examples/ run for real."""
    section("building around: prepaid keys and top-ups")
    name = "e2e-prepaid"
    status, _, created = admin("POST", "/admin/keys", {"name": name, "budget_usd": 0})
    secret = created.get("key", "")
    blocked = wait_until(lambda: chat("direct", key=secret)[0] == 402, 6, 0.2)
    check("a key created with an empty prepaid budget is known to the gateway and answered 402", status == 201 and bool(blocked), status)

    payments = os.path.join(work, "payments.jsonl")
    with open(payments, "w") as f:
        f.write(json.dumps({"reference": "e2e-pay-1", "key": name, "amount_usd": 0.01}) + "\n")
    code, out, err = example("prepaid_topup.py", "--payments", payments, "--once")
    check("examples/prepaid_topup.py credits the payment", code == 0 and "credited: e2e-pay-1" in out and "already" not in out, (code, out, err))
    unblocked = wait_until(lambda: chat("direct", key=secret)[0] == 200, 6, 0.2)
    check("... and the blocked key works again within seconds, without a restart", bool(unblocked))

    # The same payment seen again (a restarted watcher that lost its place): credited once.
    os.remove(payments + ".state")
    code, out, err = example("prepaid_topup.py", "--payments", payments, "--once")
    _, _, listing = admin("GET", "/admin/keys")
    row = next((k for k in listing.get("keys", []) if k.get("name") == name), {})
    check("the same payment seen a second time is not credited twice", code == 0 and "already credited: e2e-pay-1" in out and row.get("budget_usd") == 0.01, (code, out, row.get("budget_usd")))
    status, _, body = admin("POST", f"/admin/keys/{name}/topup", {"amount_usd": 5, "reference": "e2e-pay-1"})
    check("... and its reference cannot be reused for another amount (409)", status == 409 and body.get("error", {}).get("code") == "reference_conflict", (status, body))

    spent = wait_until(lambda: chat("direct", key=secret)[0] == 402, 15, 0.2)
    status, _, topped = admin("POST", f"/admin/keys/{name}/topup", {"amount_usd": 0.01, "reference": "e2e-pay-2"})
    again = wait_until(lambda: chat("direct", key=secret)[0] == 200, 6, 0.2)
    check("spent again, topped up again: 402, then 200", bool(spent) and status == 200 and topped.get("topup", {}).get("budget_usd") == 0.02 and bool(again), (spent, status, topped.get("topup")))
    status, _, body = admin("POST", "/admin/keys/main/topup", {"amount_usd": 1, "reference": "e2e-pay-3"})
    check("a key from the config file takes no top-up (409)", status == 409, (status, body))

    with open(payments, "a") as f:
        f.write(json.dumps({"reference": "e2e-pay-4", "key": "e2e-customer", "amount_usd": 5}) + "\n")
        f.write("not a payment\n")
        f.write(json.dumps({"reference": "e2e-pay-5", "key": "main", "amount_usd": 1}) + "\n")
    code, out, err = example("prepaid_topup.py", "--payments", payments, "--once", "--create-keys")
    customer = next((line.rsplit(" ", 1)[-1] for line in out.splitlines() if line.startswith("created key e2e-customer")), "")
    rejected = open(payments + ".rejected").read() if os.path.exists(payments + ".rejected") else ""
    check("a first payment for a new customer creates their prepaid key; payments that cannot be credited are set aside, not retried forever",
          code == 0 and customer.startswith("og-") and "credited: e2e-pay-4" in out and "not a payment" in rejected and "e2e-pay-5" in rejected and "e2e-pay-4" not in rejected,
          (code, out, err, rejected))
    status, _, audit = admin("GET", "/admin/audit?limit=100")
    topups = [e.get("topup", {}) for e in audit.get("entries", []) if e.get("action") == "key.topup"]
    check("every top-up is in the audit log with its reference and amount, replays marked",
          status == 200 and any(t.get("reference") == "e2e-pay-1" and t.get("replayed") is True for t in topups)
          and any(t.get("reference") == "e2e-pay-4" and t.get("amount_usd") == 5 and t.get("replayed") is False for t in topups), topups[:6])

    section("building around: an agent on its own key, tagged, and the usage feed")
    usable = wait_until(lambda: chat("direct", key=customer)[0] == 200, 6, 0.2)
    agent_env = {"OMNIGATE_KEY": customer, "OMNIGATE_MODEL": "direct", "OMNIGATE_TAG": "run:e2e-1"}
    code, out, err = example("agent_client.py", "Multiply 6 by 7, use the tool", env=agent_env)
    check("examples/agent_client.py runs its tool loop through the gateway: a tool call, its result, a final answer",
          bool(usable) and code == 0 and out.strip() != "" and "tool multiply(" in err, (code, out, err))
    code, out, err = example("agent_client.py", "hello", env=dict(agent_env, OMNIGATE_KEY=empty_prepaid_key()))
    check("... and stops with a clear message on a key whose budget is spent", code != 0 and "budget is spent" in err, (code, out, err))
    status, _, body = jcall("POST", GATEWAY + "/v1/chat/completions", key=customer, body=dict(CHAT, model="direct"), headers={"x-omnigate-tag": "two words"})
    check("a tag that would not be recorded as sent is refused (400), not dropped", status == 400 and "x-omnigate-tag" in json.dumps(body), (status, body))

    out_csv = os.path.join(work, "usage.csv")

    def exported():
        code, out, err = example("usage_export.py", "--out", out_csv, "--key", "e2e-customer")
        if code != 0:
            return None
        with open(out_csv, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        # The probe call above, then the agent's two model calls.
        return rows if len([r for r in rows if r["tag"] == "run:e2e-1"]) >= 2 else None
    rows = wait_until(exported, 15, 0.5) or []
    tagged = [r for r in rows if r["tag"] == "run:e2e-1"]
    check("examples/usage_export.py writes the key's events to CSV: the agent's two calls with their tag, tokens and cost, and nothing of other keys",
          len(tagged) == 2 and all(r["key"] == "e2e-customer" and r["kind"] == "text" and r["model"] == "direct" and r["upstream"] == "mock-ok"
                                   and int(r["input_tokens"]) > 0 and float(r["cost_usd"]) > 0 and r["status"] == "200" for r in tagged)
          and all(r["key"] == "e2e-customer" for r in rows) and len({r["id"] for r in rows}) == len(rows), rows[:4])
    code, out, err = example("usage_export.py", "--out", out_csv, "--key", "e2e-customer")
    with open(out_csv, newline="", encoding="utf-8") as f:
        after = list(csv.DictReader(f))
    check("... and a second run continues from its saved cursor: nothing is exported twice", code == 0 and "0 event(s)" in out and len(after) == len(rows), (code, out, len(after), len(rows)))

    status, _, first = admin("GET", "/admin/events?limit=3")
    status2, _, second = admin("GET", "/admin/events?limit=1000&after=" + str(first.get("next")))
    ids = [e.get("id") for e in first.get("events", [])] + [e.get("id") for e in second.get("events", [])]
    text = json.dumps([first, second])
    check("GET /admin/events pages through every key's events in order, with no key hash and no content in it",
          status == 200 and status2 == 200 and len(first.get("events", [])) == 3 and first.get("more") is True and len(ids) == len(set(ids))
          and sha(customer) not in text and "key_sha256" not in text and not any(f in e for e in first.get("events", []) + second.get("events", []) for f in ("messages", "content", "prompt", "input")),
          (status, status2, len(ids)))
    status, _, body = admin("GET", "/admin/events?after=nonsense")
    check("a cursor that is not one is refused (400 invalid_cursor)", status == 400 and body.get("error", {}).get("code") == "invalid_cursor", (status, body))
    for key in (name, "e2e-customer", "e2e-empty"):
        admin("DELETE", f"/admin/keys/{key}")


# --------------------------------------------------------------------------
# credit and payments
# --------------------------------------------------------------------------

INTENTS = f"http://127.0.0.1:{INTENTS_PORT}"
# A payment left open on purpose: settled after the control plane's restart (see `text_checks`).
OPEN_PAYMENT = {}


def key_row(name):
    _, _, listing = admin("GET", "/admin/keys")
    return next((k for k in listing.get("keys", []) if k.get("name") == name), {})


def mock_intents(path, body=None):
    return jcall("POST" if body is not None else "GET", INTENTS + path, body=body)


def payment(secret, payment_id):
    return jcall("GET", f"{GATEWAY}/v1/payments/{payment_id}", key=secret)[2] or {}


def payer(name, **attrs):
    """A prepaid managed key with no credit, known to the gateway (which answers it 402). Returns its secret."""
    _, _, created = admin("POST", "/admin/keys", dict({"name": name, "budget_usd": 0}, **attrs))
    secret = created.get("key", "")
    wait_until(lambda: chat("direct", key=secret)[0] == 402, 6, 0.2)
    return secret


def credit_checks():
    """Prepaid credit: what a dollar of provider cost burns (OmnigateControl.Credits)."""
    section("credit: a burn multiplier on a prepaid key")
    status, _, probe = admin("POST", "/admin/keys", {"name": "e2e-credit-probe", "budget_usd": 5, "burn_multiplier": 1.5})
    secret = probe.get("key", "")
    usable = wait_until(lambda: chat("direct", key=secret)[0] == 200, 6, 0.2)
    row = wait_until(lambda: (lambda r: r if r.get("requests") == 1 else None)(key_row("e2e-credit-probe")), 10, 0.2) or {}
    cost = row.get("cost_usd") or 0
    credits = row.get("credits") or {}
    check("a prepaid key with a burn multiplier of 1.5 burns 1.5 times what the provider cost; the listing shows both figures and the balance",
          status == 201 and bool(usable) and cost > 0 and close(row.get("credits_burned_usd"), cost * 1.5) and credits.get("burn_multiplier") == 1.5
          and close(credits.get("balance_usd"), 5 - cost * 1.5) and close(credits.get("burned_usd"), cost * 1.5), row)
    _, _, feed = admin("GET", "/admin/events?limit=100&key=e2e-credit-probe")
    events = feed.get("events", [])
    check("... and so does the usage feed, per event: the provider cost and the credit burned",
          len(events) == 1 and events[0].get("kind") == "text" and close(events[0].get("cost_usd"), cost) and close(events[0].get("credits_usd"), cost * 1.5), events)

    # Credit for exactly two such calls at 1.5 (a shade less, to stay clear of
    # rounding): at the provider's price two calls would not have used it up.
    budget = cost * 3 * 0.999
    status, _, created = admin("POST", "/admin/keys", {"name": "e2e-credit", "budget_usd": budget, "burn_multiplier": 1.5})
    secret = created.get("key", "")
    first = wait_until(lambda: chat("direct", key=secret)[0] == 200, 6, 0.2)
    after_one = wait_until(lambda: (lambda r: r if r.get("requests") == 1 else None)(key_row("e2e-credit")), 10, 0.2) or {}
    second = chat("direct", key=secret)[0]
    blocked = wait_until(lambda: (lambda r: r if r.get("state") == "blocked" else None)(key_row("e2e-credit")), 10, 0.2) or {}
    refused = wait_until(lambda: chat("direct", key=secret)[0] == 402, 6, 0.2)
    check("a prepaid key at 1.5 is blocked once the providers have cost two thirds of its credit: after two calls, which at the provider's price would have left credit for a third",
          bool(first) and after_one.get("state") == "active" and second == 200 and blocked.get("requests") == 2 and close(blocked.get("cost_usd"), cost * 2)
          and blocked.get("credits_burned_usd", 0) >= budget and cost * 2 < budget and bool(refused),
          (first, after_one.get("state"), second, blocked.get("requests"), blocked.get("cost_usd"), blocked.get("credits_burned_usd"), budget))
    status, _, row = admin("PATCH", "/admin/keys/e2e-credit", {"burn_multiplier": 500})
    check("a multiplier outside 0.01 to 100 is refused (400)", status == 400, (status, row))
    for name in ("e2e-credit-probe", "e2e-credit"):
        admin("DELETE", f"/admin/keys/{name}")


def payment_checks():
    """Payments for credit, through the NEAR Intents adapter against tools/mock_intents.py."""
    section("payments: a blocked key pays and is unblocked")
    status, _, created = admin("POST", "/admin/keys", {"name": "e2e-payer", "budget_usd": 0})
    secret = created.get("key", "")
    blocked = wait_until(lambda: chat("direct", key=secret)[0] == 402, 6, 0.2)
    status, _, assets = jcall("GET", GATEWAY + "/v1/payments/assets", key=secret)
    listed = {a.get("symbol"): a for a in assets.get("assets", [])}
    status2, _, eth = jcall("GET", GATEWAY + "/v1/payments/assets?chain=eth", key=secret)
    check("a key with no credit left can still ask what it may pay with: the provider's assets, by chain or symbol",
          bool(blocked) and status == 200 and {"wNEAR", "ETH", "BTC", "USDC"} <= set(listed) and "BROKEN" not in listed
          and listed["wNEAR"].get("asset") == "nep141:wrap.near" and listed["wNEAR"].get("chain") == "near"
          and status2 == 200 and [a.get("symbol") for a in eth.get("assets", [])] == ["ETH"], (status, sorted(listed), status2))

    status, _, pay = jcall("POST", GATEWAY + "/v1/payments", key=secret, body={"amount_usd": 2, "asset": "nep141:wrap.near", "refund_to": "payer.near"})
    deposit = pay.get("deposit", {})
    address = deposit.get("address", "")
    _, _, seen = mock_intents("/__mock/seen")
    asked = (seen.get("quotes") or [{}])[-1]
    check("POST /v1/payments answers with where to send how much, by when; the provider was asked for exactly $2 of the settle asset to the operator's account",
          status == 201 and pay.get("id", "").startswith("pay_") and pay.get("status") == "awaiting_deposit" and len(address) == 64 and deposit.get("symbol") == "wNEAR"
          and float(deposit.get("amount", 0)) > 0 and deposit.get("amount_units", "").isdigit() and pay.get("deadline") and pay.get("credited_usd") is None
          and asked.get("swapType") == "EXACT_OUTPUT" and asked.get("amount") == "2000000" and asked.get("recipient") == "operator.near"
          and asked.get("refundTo") == "payer.near" and asked.get("dry") is False and "key" not in pay, (status, pay, asked))
    time.sleep(2.5)
    still = payment(secret, pay.get("id"))
    check("nothing has arrived: the payment waits, the key stays blocked, nothing is credited",
          still.get("status") == "awaiting_deposit" and still.get("provider_status") == "PENDING_DEPOSIT" and chat("direct", key=secret)[0] == 402 and key_row("e2e-payer").get("budget_usd") == 0,
          still)

    status, _, _ = jcall("POST", f"{GATEWAY}/v1/payments/{pay.get('id')}/tx", key=secret, body={"tx_hash": "0xdeposit-tx-1"})
    _, _, seen = mock_intents("/__mock/seen")
    check("the deposit's transaction hash can be passed on to the provider", status == 200 and {"depositAddress": address, "txHash": "0xdeposit-tx-1"} in seen.get("submitted", []), (status, seen.get("submitted")))
    mock_intents("/__mock/deposit", {"depositAddress": address, "outcome": "success", "steps": True})
    settled = wait_until(lambda: (lambda p: p if p.get("status") == "settled" else None)(payment(secret, pay.get("id"))), 20, 0.3) or {}
    unblocked = wait_until(lambda: chat("direct", key=secret)[0] == 200, 6, 0.2)
    row = key_row("e2e-payer")
    check("the deposit arrives and the swap completes: the payment is settled, the key credited $2 and working again within seconds",
          settled.get("credited_usd") == 2 and len(settled.get("tx", [])) >= 1 and bool(unblocked) and row.get("budget_usd") == 2 and row.get("state") == "active", (settled, row.get("budget_usd")))
    _, _, topups = admin("GET", "/admin/topups?key=e2e-payer")
    reference = "near_intents:" + address
    _, _, feed = admin("GET", "/admin/events?limit=100&key=e2e-payer")
    credit_events = [e for e in feed.get("events", []) if e.get("kind") == "credit"]
    _, _, audit = admin("GET", "/admin/audit?limit=200")
    actions = [(e.get("action"), e.get("target"), (e.get("payment") or {}).get("reference")) for e in audit.get("entries", [])]
    _, _, listing = admin("GET", "/admin/payments")
    credits = row.get("credits") or {}
    check("the credit is credit from near_intents, under a reference made of the deposit address: in the top-up history, the usage feed, the audit log and GET /admin/payments",
          [(t.get("reference"), t.get("amount_usd"), t.get("source")) for t in topups.get("topups", [])] == [(reference, 2, "near_intents")]
          and len(credit_events) == 1 and credit_events[0].get("amount_usd") == 2 and credit_events[0].get("source") == "near_intents"
          and ("payment.create", "e2e-payer", reference) in actions and ("payment.settle", "e2e-payer", reference) in actions
          and any(p.get("id") == pay.get("id") and p.get("key") == "e2e-payer" and p.get("reference") == reference for p in listing.get("payments", []))
          and close(credits.get("balance_usd"), 2 - (row.get("credits_burned_usd") or 0)) and "eligible_usd" not in credits,
          (topups, credit_events, credits))

    # The provider keeps saying SUCCESS for as long as anyone asks.
    _, _, before = mock_intents("/__mock/seen")
    time.sleep(2.5)
    _, _, after = mock_intents("/__mock/seen")
    status, _, replay = admin("POST", "/admin/keys/e2e-payer/topup", {"amount_usd": 50, "reference": reference})
    check("a settled payment is credited once and not asked about again; its reference cannot be used to credit the key by hand",
          key_row("e2e-payer").get("budget_usd") == 2 and after.get("asked", {}).get(address) == before.get("asked", {}).get(address)
          and status == 409 and replay.get("error", {}).get("code") == "reference_conflict", (before.get("asked"), after.get("asked"), status))

    section("payments: refusals, refunds and answers that are not believed")
    # (Several keys: one key may ask the provider for a quote six times a minute.)
    ask = lambda key, **body: jcall("POST", GATEWAY + "/v1/payments", key=key, body=dict({"amount_usd": 2, "asset": "nep141:wrap.near", "refund_to": "payer.near"}, **body))
    new = lambda **body: ask(secret, **body)
    status, _, body = new(refund_to="invalid-address")
    status2, _, body2 = new(asset="nep141:bsc.omft.near", refund_to="0x" + "ab" * 20)
    status3, _, body3 = new(asset="nep141:btc.omft.near", amount_usd=1, refund_to="bc1qpayer")
    check("what the provider refuses reaches the payer in the provider's words (400): a refund address that is not one, a chain's minimum, an amount too low for a bridge",
          status == 400 and body.get("error", {}).get("code") == "payment_quote_refused" and "refundTo is not valid" in body["error"]["message"]
          and status2 == 400 and "$1,000" in body2.get("error", {}).get("message", "") and status3 == 400 and "too low for bridge" in body3.get("error", {}).get("message", ""),
          (status, body, status2, body2, status3, body3))
    codes = [new(amount_usd=0.5)[0], new(amount_usd=1e6)[0], new(asset="not an asset")[0], new(refund_to="")[0],
             jcall("POST", GATEWAY + "/v1/payments", key=KEY_MAIN, body={"amount_usd": 2, "asset": "nep141:wrap.near", "refund_to": "payer.near"})[0],
             jcall("GET", GATEWAY + "/v1/payments/" + pay.get("id", "x"), key=KEY_MAIN)[0], jcall("GET", GATEWAY + "/v1/payments/assets")[0],
             jcall("DELETE", GATEWAY + "/v1/payments/" + pay.get("id", "x"), key=secret)[0]]
    check("an amount outside the bounds, an asset or address that is not one (400); a key that is not prepaid (409); another key's payment (404); no key (401); DELETE (405)",
          codes == [400, 400, 400, 400, 409, 404, 401, 405], codes)

    second = payer("e2e-payer-2")
    refusals = []
    for mode in ("bad_signature", "wrong_recipient", "wrong_amount"):
        mock_intents("/__mock/quotes", {"mode": mode})
        status, _, body = ask(second)
        refusals.append((status, body.get("error", {}).get("code"), "deposit" in body))
    mock_intents("/__mock/quotes", {"mode": None})
    listed = jcall("GET", GATEWAY + "/v1/payments", key=second)[2].get("payments")
    check("a quote that is not signed by the provider's key, or names another recipient or amount, is never shown: 502, no deposit address, nothing stored",
          refusals == [(502, "payment_provider_error", False)] * 3 and listed == [], (refusals, listed))
    status, _, btc = ask(second, asset="nep141:btc.omft.near", refund_to="bc1qpayer")
    mock_intents("/__mock/deposit", {"depositAddress": btc.get("deposit", {}).get("address"), "outcome": "success"})
    paid = wait_until(lambda: (lambda p: p if p.get("status") == "settled" else None)(payment(second, btc.get("id"))), 20, 0.3) or {}
    check("an asset the provider lists twice (Bitcoin), whose quote it signs under the other id: accepted, settled and credited",
          status == 201 and btc.get("deposit", {}).get("symbol") == "BTC" and paid.get("credited_usd") == 2 and key_row("e2e-payer-2").get("budget_usd") == 2, (status, btc, paid))
    status, _, dry = jcall("POST", GATEWAY + "/v1/payments/quote", key=second, body={"amount_usd": 3, "asset": "nep141:eth.omft.near", "refund_to": "0x" + "ab" * 20})
    listed = jcall("GET", GATEWAY + "/v1/payments", key=second)[2].get("payments", [])
    check("POST /v1/payments/quote says what a payment would take without starting one: an amount, no deposit address, nothing stored",
          status == 200 and float(dry.get("amount") or 0) > 0 and dry.get("symbol") == "ETH" and "address" not in json.dumps(dry) and len(listed) == 1, (status, dry, len(listed)))

    # The page a key holder tops up on: public, self-contained, and it asks for no key to load.
    status, heads, raw = call("GET", GATEWAY + "/topup")
    page = raw.decode("utf-8", "replace")
    csp = heads.get("content-security-policy", "")
    credits = jcall("GET", GATEWAY + "/v1/payments", key=second)[2].get("credits") or {}
    check("GET /topup is the top-up page, served without a key: one self-contained page (strict CSP, nothing stored), and the key's own list says what credit is left",
          status == 200 and heads.get("content-type", "").startswith("text/html") and "default-src 'none'" in csp and "script-src 'nonce-" in csp
          and heads.get("cache-control") == "no-store" and "/v1/payments/quote" in page and "qrMatrix" in page and not re.search(r'(src|href)="https?:', page)
          and close(credits.get("balance_usd"), 2 - (key_row("e2e-payer-2").get("credits_burned_usd") or 0)),
          (status, heads, credits, page[:200]))
    check("/topup is a page to read: other methods need a key like everything else",
          call("POST", GATEWAY + "/topup", body={})[0] == 401, call("POST", GATEWAY + "/topup", body={})[0])

    secret = payer("e2e-payer-3")
    new = lambda **body: ask(secret, **body)
    payment_key = "e2e-payer-3"
    budget = key_row(payment_key).get("budget_usd")
    outcomes = {}
    for outcome in ("refund", "fail", "partial"):
        _, _, p = new()
        mock_intents("/__mock/deposit", {"depositAddress": p.get("deposit", {}).get("address"), "outcome": outcome})
        outcomes[outcome] = p.get("id")
    _, _, forged = new()
    mock_intents("/__mock/deposit", {"depositAddress": forged.get("deposit", {}).get("address"), "outcome": "success"})
    mock_intents("/__mock/tamper", {"depositAddress": forged.get("deposit", {}).get("address"), "what": "recipient"})
    ended = wait_until(lambda: payment(secret, outcomes["refund"]).get("status") == "refunded" and payment(secret, outcomes["fail"]).get("status") == "failed"
                       and payment(secret, outcomes["partial"]).get("provider_status") == "INCOMPLETE_DEPOSIT", 20, 0.3)
    time.sleep(2.5)
    partial, lied = payment(secret, outcomes["partial"]), payment(secret, forged.get("id"))
    check("refunded, failed and a deposit that fell short credit nothing; neither does a 'success' about a quote that is not ours (another recipient): that payment stays open",
          bool(ended) and "refunded to the payer" in (payment(secret, outcomes["refund"]).get("detail") or "") and partial.get("status") == "awaiting_deposit" and "less than" in (partial.get("detail") or "")
          and lied.get("status") == "awaiting_deposit" and lied.get("credited_usd") is None and key_row(payment_key).get("budget_usd") == budget,
          (payment(secret, outcomes["refund"]), partial, lied, key_row(payment_key).get("budget_usd"), budget))
    # The provider honest again about that quote: settled after all, and credited what arrived.
    mock_intents("/__mock/tamper", {"depositAddress": forged.get("deposit", {}).get("address"), "what": None})
    mock_intents("/__mock/deposit", {"depositAddress": forged.get("deposit", {}).get("address"), "outcome": "success", "amountOut": "1990000"})
    late = wait_until(lambda: (lambda p: p if p.get("status") == "settled" else None)(payment(secret, forged.get("id"))), 20, 0.3) or {}
    check("what arrived is what is credited: $1.99 delivered for a $2 payment credits $1.99", late.get("credited_usd") == 1.99 and close(key_row(payment_key).get("budget_usd"), budget + 1.99), late)

    fourth = payer("e2e-payer-4")
    status, _, memo = ask(fourth, asset="nep141:stellar.omft.near", refund_to="GPAYERSTELLAR")
    check("a chain that needs a memo with the deposit: the memo is part of the instructions", status == 201 and str(memo.get("deposit", {}).get("memo", "")).isdigit(), (status, memo.get("deposit")))
    waiting = [ask(fourth)[0] for _ in range(4)]
    status, _, sixth = ask(fourth)
    check("a key may have five payments waiting for a deposit; the next is refused (429)",
          waiting == [201] * 4 and status == 429 and sixth.get("error", {}).get("code") == "too_many_open_payments", (waiting, status, sixth))

    section("payments: an agent pays for its own inference (examples/agent_pays.py)")
    agent_key = payer("e2e-agent")
    env = dict(os.environ, OMNIGATE_GATEWAY=GATEWAY, OMNIGATE_KEY=agent_key, OMNIGATE_MODEL="direct", OMNIGATE_PAY_USD="3", OMNIGATE_PAY_SYMBOL="ETH", OMNIGATE_PAY_CHAIN="eth",
               OMNIGATE_REFUND_TO="0x" + "cd" * 20, OMNIGATE_PAY_POLL_S="0.3", OMNIGATE_PAY_WAIT_S="60", PYTHONUNBUFFERED="1")
    agent = subprocess.Popen([sys.executable, os.path.join(ROOT, "examples", "agent_pays.py"), "hi"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    instruction = agent.stdout.readline().strip()
    words = instruction.split()
    # "PAY <amount> ETH on eth to <address> before <deadline> (payment <id>)": the test plays the wallet.
    paid_to = words[6] if len(words) > 6 and words[0] == "PAY" else ""
    mock_intents("/__mock/deposit", {"depositAddress": paid_to, "outcome": "success", "steps": True})
    try:
        out, err = agent.communicate(timeout=90)
    except subprocess.TimeoutExpired:
        agent.kill()
        out, err = agent.communicate()
    check("on 402 the example lists the assets, starts a payment, prints what to send where, waits for the settlement and gets its answer",
          agent.returncode == 0 and words[:1] == ["PAY"] and words[2:5] == ["ETH", "on", "eth"] and paid_to.startswith("0x") and "CREDITED 3" in out and MOCK_TEXT in out
          and "settled" in err and key_row("e2e-agent").get("budget_usd") == 3, (agent.returncode, instruction, out, err[-600:]))
    # A key whose budget is an allowance (monthly), spent: there is nothing to pay into.
    env2 = dict(env, OMNIGATE_KEY=payer("e2e-monthly", budget_period="monthly"))
    done = subprocess.run([sys.executable, os.path.join(ROOT, "examples", "agent_pays.py"), "hi"], env=env2, capture_output=True, text=True, timeout=60)
    check("... and stops with the gateway's reason where the key cannot be paid for (a monthly allowance, not prepaid credit)",
          done.returncode != 0 and "not_prepaid" in done.stderr, (done.returncode, done.stdout[-200:], done.stderr[-300:]))

    # One payment left waiting, for the control plane's restart at the end of the text checks.
    restart_key = payer("e2e-restart-payer")
    _, _, left = ask(restart_key, amount_usd=4, asset="nep141:sol.omft.near", refund_to="PayerSolanaAddress11111111111111111111111111")
    OPEN_PAYMENT.update(secret=restart_key, id=left.get("id"), address=left.get("deposit", {}).get("address"))
    for name in ("e2e-payer", "e2e-payer-2", "e2e-payer-3", "e2e-payer-4", "e2e-agent", "e2e-monthly"):
        admin("DELETE", f"/admin/keys/{name}")


def payment_after_restart_checks():
    """The payment left open before the control plane was stopped and started again."""
    section("payments: a control-plane restart in the middle of a payment")
    secret, payment_id, address = OPEN_PAYMENT.get("secret", ""), OPEN_PAYMENT.get("id"), OPEN_PAYMENT.get("address")
    before = payment(secret, payment_id)
    mock_intents("/__mock/deposit", {"depositAddress": address, "outcome": "success"})
    settled = wait_until(lambda: (lambda p: p if p.get("status") == "settled" else None)(payment(secret, payment_id)), 30, 0.3) or {}
    row = key_row("e2e-restart-payer")
    time.sleep(2.5)
    check("a payment that was waiting when the control plane stopped is still there after the restart, settles when the deposit arrives, and is credited once",
          before.get("status") == "awaiting_deposit" and before.get("deposit", {}).get("address") == address and settled.get("credited_usd") == 4
          and row.get("budget_usd") == 4 and key_row("e2e-restart-payer").get("budget_usd") == 4 and chat("direct", key=secret)[0] == 200, (before, settled, row.get("budget_usd")))
    admin("DELETE", "/admin/keys/e2e-restart-payer")


def empty_prepaid_key():
    """A managed key with nothing in its prepaid budget, known to the gateway."""
    admin("DELETE", "/admin/keys/e2e-empty")
    _, _, created = admin("POST", "/admin/keys", {"name": "e2e-empty", "budget_usd": 0})
    secret = created.get("key", "")
    wait_until(lambda: chat("direct", key=secret)[0] == 402, 6, 0.2)
    return secret


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
    status, headers, body = chat("limited-then-dead")
    main_calls += 1
    check("a provider's 429 reaches the client as 429 with its retry-after, even when a later target was simply down",
          status == 429 and headers.get("retry-after") == "7" and body.get("error", {}).get("code") == "upstream_rate_limited"
          and body["error"].get("type") == "rate_limit_error", (status, headers.get("retry-after"), body))
    t0 = time.time()
    status, headers, _ = chat("slow")
    main_calls += 1
    elapsed = time.time() - t0
    check("an upstream that takes 3 s is abandoned at its 0.5 s timeout",
          status == 200 and headers.get("x-omnigate-upstream") == "mock-ok" and elapsed < 2.5, f"{status} in {elapsed:.2f}s")

    section("load balancing and per-key model limits")
    served = [chat("spread")[1].get("x-omnigate-upstream") for _ in range(4)]
    main_calls += 4
    check("a round-robin route alternates between its targets",
          sorted(served[:2]) == ["mock-compat", "mock-ok"] and served[:2] == served[2:], served)
    served = [chat("skewed")[1].get("x-omnigate-upstream") for _ in range(4)]
    main_calls += 4
    check("a weighted route never starts with a weight-0 target", served == ["mock-compat"] * 4, served)
    status, _, body = chat("chat", key=KEY_LIMITED)
    check("a key limited to one model is refused another (403)",
          status == 403 and body.get("error", {}).get("code") == "model_not_allowed", (status, body))
    status, _, _ = chat("direct", key=KEY_LIMITED)
    check("... and can use the model it is allowed", status == 200, status)
    status, _, body = jcall("GET", GATEWAY + "/v1/models", key=KEY_LIMITED)
    check("... and its model list shows only that model", [m["id"] for m in body.get("data", [])] == ["direct"], body)

    section("response cache")
    # Let earlier calls reach the ledger first, so the difference below is only these two.
    base = wait_until(lambda: main_row_with(main_calls), 10) or usage_row("main")
    before, hits_before = base.get("cost_usd", 0), base.get("cached_responses", 0)
    status, h1, b1 = chat("cached")
    status2, h2, b2 = chat("cached")
    main_calls += 2
    check("on a route with a cache TTL, an identical request is answered from the cache",
          status == 200 and status2 == 200 and h1.get("x-omnigate-cache") == "miss" and h2.get("x-omnigate-cache") == "hit" and b1 == b2,
          (h1.get("x-omnigate-cache"), h2.get("x-omnigate-cache")))
    status, h3, _ = chat("cached", key=KEY_OTHER)
    check("... but never across gateway keys", status == 200 and h3.get("x-omnigate-cache") == "miss", h3.get("x-omnigate-cache"))
    row = wait_until(lambda: main_row_with(main_calls), 10) or usage_row("main")
    check("... and the cached answer is counted but not billed",
          row.get("requests", 0) - row.get("jobs", 0) == main_calls and abs(row.get("cost_usd", 0) - before - 0.0029) < 1e-9
          and row.get("cached_responses", 0) - hits_before == 1, (before, hits_before, row))

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
    # Every call but three used at least 11 input tokens: the one the provider
    # refused with a 400, the one it rate-limited, and the one served from the
    # response cache have none.
    check("tokens and cost are recorded",
          row.get("input_tokens", 0) >= 11 * (main_calls - 3) and row.get("cost_usd", 0) > 0 and row.get("errors", 0) >= 1, row)

    codes = [chat("direct", key=KEY_BUDGET)[0] for _ in range(4)]
    blocked = wait_until(lambda: chat("direct", key=KEY_BUDGET)[0] == 402, 10, 0.3)
    check("a $0.01 budget allows 4 calls, then the key gets 402", codes == [200] * 4 and blocked, codes)
    status, _, _ = chat("direct")
    main_calls += 1
    check("other keys keep working", status == 200)
    status, _, body = jcall("GET", GATEWAY + "/v1/models", key=KEY_BUDGET)
    check("the over-budget key can still read (model list), it just cannot start work", status == 200 and body.get("data"), status)

    def refused():
        _, _, text = control_raw("GET", "/metrics", {"authorization": "Bearer " + ADMIN_TOKEN})
        lines = [l for l in text.splitlines() if l.startswith("omnigate_rejected_requests_total")]
        return lines if any('reason="rate_limit_exceeded"' in l and 'key="rpm"' in l for l in lines) \
            and any('reason="budget_exceeded"' in l and 'key="budget"' in l for l in lines) else None
    lines = wait_until(refused, 10) or []
    check("requests refused before routing are counted per key and reason in the metrics", bool(lines), lines[:4])

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
    payment_after_restart_checks()


# --------------------------------------------------------------------------
# media jobs
# --------------------------------------------------------------------------

MEDIA_PORTS = [9101, 9102, 9103, 9104, 9105, 9106, 9107, 9108, 9109, 9110]
MEDIA_MOCK_ARGS = []
MOCK = {name: f"http://127.0.0.1:{port}" for name, port in [
    ("replicate", 9101), ("replicate_broken", 9102), ("fal", 9103), ("openai_images", 9104),
    ("elevenlabs", 9105), ("s3", 9106), ("webhooks", 9107), ("gemini", 9108), ("xai_video", 9109), ("sume", 9110)]}
TERMINAL = ("succeeded", "failed", "canceled")


# --------------------------------------------------------------------------
# privacy mode
# --------------------------------------------------------------------------

def seen_by(port, model="echo-1"):
    """The last request the mock on `port` received for `model`."""
    return jcall("GET", f"http://127.0.0.1:{port}/__last?model={model}")[2]


def hidden(entry, values=None):
    """True when none of the private values reached the provider in that request."""
    body = entry.get("body", "<nothing received>")
    return all(v not in body for v in (values or PII.values()))


def privacy_text_checks():
    said = "You said: " + PRIVATE_TEXT
    user = [{"role": "user", "content": PRIVATE_TEXT}]
    anthropic = {"anthropic-version": "2023-06-01"}

    section("privacy mode: redaction before the provider, originals back to the client")
    status, headers, body = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PRIVATE, body={"model": "echo", "messages": user})
    text = ((body.get("choices") or [{}])[0].get("message") or {}).get("content")
    check("a private key's request comes back with the client's own values in it", status == 200 and text == said, (status, body))
    check("the response says which protections applied", headers.get("x-omnigate-privacy") == "no-store, redact, unlink", headers.get("x-omnigate-privacy"))
    seen = seen_by(9002)
    check("the provider was sent placeholders and none of the values",
          hidden(seen) and all(p in seen.get("body", "") for p in PLACEHOLDERS), seen.get("body", "")[:400])
    check("everything else reached the provider as written", CANARY in seen.get("body", ""), seen.get("body", "")[:200])

    status, events, _ = sse("/v1/chat/completions", KEY_PRIVATE, {"model": "echo", "messages": user, "stream": True})
    check("streamed in three-character pieces, every placeholder is put back together",
          status == 200 and openai_stream_text(events) == said and events[-1][1] == "[DONE]", (status, openai_stream_text(events)))

    status, _, body = jcall("POST", GATEWAY + "/v1/messages", key=KEY_PRIVATE, headers=anthropic,
                            body={"model": "echo-claude", "max_tokens": 64, "messages": user})
    text = ((body.get("content") or [{}])[0]).get("text")
    check("the same over the Anthropic protocol", status == 200 and text == said and hidden(seen_by(9003)), (status, body))
    status, events, _ = sse("/v1/messages", KEY_PRIVATE, {"model": "echo-claude", "max_tokens": 64, "messages": user, "stream": True}, headers=anthropic)
    check("and as an Anthropic event stream", status == 200 and anthropic_stream_text(events) == said, (status, anthropic_stream_text(events)))

    status, _, body = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PRIVATE, body={"model": "echo-claude", "messages": user})
    text = ((body.get("choices") or [{}])[0].get("message") or {}).get("content")
    check("translated to an Anthropic provider: redacted going out, restored coming back",
          status == 200 and text == said and hidden(seen_by(9003)) and "[EMAIL_1]" in seen_by(9003).get("body", ""), (status, body))
    status, events, _ = sse("/v1/chat/completions", KEY_PRIVATE, {"model": "echo-claude", "messages": user, "stream": True})
    check("translated and streamed", status == 200 and openai_stream_text(events) == said, (status, openai_stream_text(events)))
    status, _, body = jcall("POST", GATEWAY + "/v1/messages", key=KEY_PRIVATE, headers=anthropic,
                            body={"model": "echo", "max_tokens": 64, "messages": user})
    text = ((body.get("content") or [{}])[0]).get("text")
    check("translated the other way (Anthropic client, OpenAI provider)", status == 200 and text == said and hidden(seen_by(9002)), (status, body))
    status, events, _ = sse("/v1/messages", KEY_PRIVATE, {"model": "echo", "max_tokens": 64, "messages": user, "stream": True}, headers=anthropic)
    check("and streamed", status == 200 and anthropic_stream_text(events) == said, (status, anthropic_stream_text(events)))

    section("privacy mode: tool calls, other endpoints, errors")
    ask = "use the tool with " + PRIVATE_TEXT
    tools = [{"type": "function", "function": {"name": "send", "parameters": {"type": "object", "properties": {"text": {"type": "string"}}}}}]
    status, _, body = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PRIVATE,
                            body={"model": "echo", "messages": [{"role": "user", "content": ask}], "tools": tools})
    calls = ((body.get("choices") or [{}])[0].get("message") or {}).get("tool_calls") or [{}]
    arguments = (calls[0].get("function") or {}).get("arguments") or "{}"
    check("a tool call's arguments carry the original values", status == 200 and json.loads(arguments).get("text") == ask and hidden(seen_by(9002)), (status, body))
    status, events, _ = sse("/v1/chat/completions", KEY_PRIVATE, {"model": "echo", "messages": [{"role": "user", "content": ask}], "tools": tools, "stream": True})
    fragments = []
    for _, data in events:
        if data != "[DONE]":
            for choice in json.loads(data).get("choices", []):
                for tc in choice.get("delta", {}).get("tool_calls") or []:
                    fragments.append((tc.get("function") or {}).get("arguments") or "")
    try:
        streamed = json.loads("".join(fragments)).get("text")
    except ValueError:
        streamed = "".join(fragments)
    check("also when the arguments are streamed in fragments", status == 200 and streamed == ask, streamed)
    status, _, body = jcall("POST", GATEWAY + "/v1/messages", key=KEY_PRIVATE, headers=anthropic,
                            body={"model": "echo-claude", "max_tokens": 64, "messages": [{"role": "user", "content": ask}],
                                  "tools": [{"name": "send", "input_schema": {"type": "object", "properties": {"text": {"type": "string"}}}}]})
    block = (body.get("content") or [{}])[0]
    check("an Anthropic tool_use block's input carries them too", status == 200 and (block.get("input") or {}).get("text") == ask, (status, body))
    status, events, _ = sse("/v1/messages", KEY_PRIVATE, {"model": "echo-claude", "max_tokens": 64, "stream": True, "messages": [{"role": "user", "content": ask}],
                                                           "tools": [{"name": "send", "input_schema": {"type": "object", "properties": {"text": {"type": "string"}}}}]}, headers=anthropic)
    partial = "".join(json.loads(d).get("delta", {}).get("partial_json", "") for _, d in events if json.loads(d).get("type") == "content_block_delta")
    try:
        streamed = json.loads(partial).get("text")
    except ValueError:
        streamed = partial
    check("and its streamed partial JSON", status == 200 and streamed == ask, streamed)

    status, _, body = jcall("POST", GATEWAY + "/v1/responses", key=KEY_PRIVATE, body={"model": "echo", "input": PRIVATE_TEXT})
    text = (((body.get("output") or [{}])[0].get("content") or [{}])[0]).get("text")
    check("the Responses API: input redacted, output restored", status == 200 and text == said and hidden(seen_by(9002)), (status, body))
    status, events, _ = sse("/v1/responses", KEY_PRIVATE, {"model": "echo", "input": PRIVATE_TEXT, "stream": True})
    deltas = "".join(json.loads(d).get("delta", "") for e, d in events if e == "response.output_text.delta")
    final = [json.loads(d) for e, d in events if e == "response.completed"]
    final_text = ((((final or [{}])[0].get("response") or {}).get("output") or [{}])[0].get("content") or [{}])[0].get("text")
    check("the Responses API's event stream: the deltas and the closing response", status == 200 and deltas == said and final_text == said, (status, deltas))
    status, _, body = jcall("POST", GATEWAY + "/v1/embeddings", key=KEY_PRIVATE, body={"model": "echo", "input": [PRIVATE_TEXT, "plain"]})
    seen = seen_by(9002)
    check("embeddings: the text is redacted before it is embedded", status == 200 and len(body.get("data", [])) == 2 and hidden(seen) and "[EMAIL_1]" in seen.get("body", ""), (status, seen.get("body", "")[:200]))
    status, _, body = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PRIVATE, body={"model": "echo-err", "messages": user})
    message = (body.get("error") or {}).get("message", "")
    check("a provider's error that quotes the request is restored as well", status == 400 and PII["email"] in message and hidden(seen_by(9002, "echo-err-1")), (status, body))
    literal = "the text [EMAIL_1] is mine, " + PII["email"] + " is real, [EMAIL_2] too"
    status, _, body = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PRIVATE, body={"model": "echo", "messages": [{"role": "user", "content": literal}]})
    text = ((body.get("choices") or [{}])[0].get("message") or {}).get("content")
    check("text of the client's that already looks like a placeholder comes back as it was written", status == 200 and text == "You said: " + literal, (status, text))

    section("privacy mode: unlinking, no retention, the request header")
    linking = {"user": "end-user-8842", "safety_identifier": "sid-5521", "prompt_cache_key": "pck-7719", "metadata": {"customer": "acme-3306"}}
    names = ("end-user-8842", "sid-5521", "pck-7719", "acme-3306")
    status, _, _ = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PRIVATE, body=dict({"model": "echo", "messages": user}, **linking))
    seen = seen_by(9002)
    check("fields that name an end user are not sent on", status == 200 and hidden(seen, names) and not any(k in json.loads(seen.get("body", "{}")) for k in linking), seen.get("body", "")[:300])
    sent_headers = seen.get("headers", {})
    check("nothing in the request to the provider names the key or the client",
          sent_headers.get("authorization") == "Bearer mock-secret" and not any(n.startswith("x-omnigate") or n in ("x-forwarded-for", "forwarded", "cookie", "via") for n in sent_headers)
          and not any("private" in v or KEY_PRIVATE in v for v in sent_headers.values()), sent_headers)
    status, _, _ = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PLAIN, body=dict({"model": "echo", "messages": CHAT["messages"]}, **linking))
    check("a key without privacy mode still sends them (the fields work)", status == 200 and all(n in seen_by(9002).get("body", "") for n in names))
    status, _, _ = jcall("POST", GATEWAY + "/v1/messages", key=KEY_PRIVATE, headers=anthropic,
                         body={"model": "echo-claude", "max_tokens": 64, "messages": user, "metadata": {"user_id": "end-user-8842"},
                               "diagnostics": {"previous_message_id": "msg_prev_sid-5521"}, "user": "kept-for-the-provider-to-refuse"})
    sent = json.loads(seen_by(9003).get("body", "{}"))
    check("Anthropic's metadata.user_id and diagnostics.previous_message_id are removed too; what is not Anthropic's is left alone",
          status == 200 and hidden(seen_by(9003), names) and "metadata" not in sent and "diagnostics" not in sent and "user" in sent, sent)

    def cache_note(key):
        return jcall("POST", GATEWAY + "/v1/chat/completions", key=key, body={"model": "echo-cached", "messages": CHAT["messages"]})[1].get("x-omnigate-cache")
    check("a private key's answers are neither taken from nor put into the response cache", [cache_note(KEY_PRIVATE), cache_note(KEY_PRIVATE)] == [None, None])
    check("the same route still caches for other keys", [cache_note(KEY_PLAIN), cache_note(KEY_PLAIN)] == ["miss", "hit"])

    status, _, _ = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PRIVATE,
                         body={"model": "echo-store", "messages": user, "store": True, "metadata": {"a": "b"}})
    sent = json.loads(seen_by(9002).get("body", "{}"))
    check("an upstream that takes OpenAI's store flag is told \"store\": false, whatever the client said",
          status == 200 and sent.get("store") is False and "metadata" not in sent, sent)
    status, _, _ = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PRIVATE, body={"model": "echo", "messages": user})
    check("an upstream that is not known to take it is not sent the field", status == 200 and "store" not in json.loads(seen_by(9002).get("body", "{}")))
    status, _, _ = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PLAIN, body={"model": "echo-store", "messages": CHAT["messages"], "store": True})
    check("and a key without privacy mode keeps its own \"store\"", status == 200 and json.loads(seen_by(9002).get("body", "{}")).get("store") is True)

    status, headers, body = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PLAIN, headers={"x-omnigate-privacy": "redact"},
                                  body={"model": "echo", "messages": user})
    text = ((body.get("choices") or [{}])[0].get("message") or {}).get("content")
    check("x-omnigate-privacy: redact switches redaction on for one request of any key",
          status == 200 and text == said and headers.get("x-omnigate-privacy") == "redact" and hidden(seen_by(9002)), (status, headers.get("x-omnigate-privacy")))
    status, headers, _ = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PLAIN, headers={"x-omnigate-privacy": "on"}, body={"model": "echo", "messages": user})
    check("x-omnigate-privacy: on switches everything on", status == 200 and headers.get("x-omnigate-privacy") == "no-store, redact, unlink", headers.get("x-omnigate-privacy"))
    for value in ("off", "false", "redact, sometimes"):
        status, _, body = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PRIVATE, headers={"x-omnigate-privacy": value}, body={"model": "echo", "messages": user})
        check(f"x-omnigate-privacy: {value} is refused (the header cannot switch anything off)",
              status == 400 and (body.get("error") or {}).get("code") == "invalid_request", (status, body))
    status, headers, body = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_REDACT, body={"model": "echo", "messages": user})
    seen = seen_by(9002).get("body", "")
    check("a key that redacts only e-mail and secrets leaves the other classes alone",
          status == 200 and headers.get("x-omnigate-privacy") == "redact" and PII["email"] not in seen and PII["secret"] not in seen
          and PII["phone"] in seen and PII["ip"] in seen and PII["card"] in seen, seen[:300])

    def counted():
        _, _, raw = call("GET", CONTROL + "/metrics", key=ADMIN_TOKEN)
        page = raw.decode("utf-8", "replace")
        return all(f'omnigate_redactions_total{{key="private",class="{c}"}}' in page for c in PII) and 'omnigate_key_private{key="private"} 1' in page
    check("redactions are counted per key and class in the metrics (counts only)", wait_until(counted, 10))
    row = usage_row("private")
    check("private requests are metered like any other", row.get("requests", 0) >= 10 and row.get("cost_usd", 0) > 0, row)


def wait_private_job(job_id, key):
    """A private job the moment it is terminal: it is erased in the same write, so there is nothing more to wait for."""
    return wait_job(job_id, key=key)


def privacy_media_checks():
    section("privacy mode: media jobs")
    prompt = f"{CANARY} a private lighthouse"
    body = {"model": "image", "input": {"prompt": prompt}, "metadata": {"order": CANARY + "-order"}, "webhook_url": MOCK["webhooks"] + "/hook"}
    status, _, job = jcall("POST", GATEWAY + "/v1/jobs", key=KEY_PLAIN, body=body, headers={"x-omnigate-privacy": "no-store"})
    check("x-omnigate-privacy: no-store makes one job private", status == 202 and job.get("private") is True, (status, job))
    done = wait_private_job(job.get("id", "missing"), KEY_PLAIN)
    check("when it ends, its input and metadata are erased; the result stays",
          done.get("status") == "succeeded" and done.get("input") is None and done.get("metadata") is None
          and done.get("input_erased") is True and len(done.get("outputs") or []) == 1, done)
    def delivered():
        recs = [d for d in jcall("GET", MOCK["webhooks"] + "/received")[2].get("deliveries", []) if d.get("webhook_id") == "msg_" + job.get("id", "")]
        return recs if recs and recs[-1]["responded"] == 200 else None
    recs = wait_until(delivered, 20) or [{}]
    payload = json.dumps(recs[-1].get("payload", {}))
    check("its webhook carries neither", recs[-1].get("responded") == 200 and CANARY not in payload and "input_erased" in payload, payload[:300])
    listed = jcall("GET", GATEWAY + "/v1/jobs?limit=50", key=KEY_PLAIN)[2]
    check("nor does the list of jobs", CANARY not in json.dumps(listed), json.dumps(listed)[:200])

    status, _, job = create_job({"model": "image", "input": {"prompt": prompt}}, key=KEY_PRIVATE)
    done = wait_private_job(job.get("id", "missing"), KEY_PRIVATE)
    check("every job of a private key is private", status == 202 and job.get("private") is True and done.get("input_erased") is True, (status, done))
    status, _, refused = jcall("POST", GATEWAY + "/v1/jobs", key=KEY_PLAIN, body=body, headers={"x-omnigate-privacy": "never"})
    check("a privacy header the gateway does not understand is refused for jobs too", status == 400, (status, refused))

    status, _, job = create_job({"model": "image", "input": {"prompt": "a sealed lighthouse"}}, key=KEY_SEALED)
    done = wait_job(job.get("id", "missing"), key=KEY_SEALED)
    out = (done.get("outputs") or [{}])[0]
    url = out.get("url", "")
    check("a key with encrypt_to gets its output as an age file",
          done.get("status") == "succeeded" and out.get("encryption") == "age" and out.get("content_type") == "application/octet-stream"
          and ".age?" in url and out.get("plaintext_content_type") == "image/png", done)
    st, hdrs, sealed = call("GET", url) if url else (0, {}, b"")
    check("what is stored and served is ciphertext, with the hash the job reports",
          st == 200 and sealed.startswith(b"age-encryption.org/v1\n-> X25519 ") and b"\x89PNG" not in sealed
          and hashlib.sha256(sealed).hexdigest() == out.get("sha256") and len(sealed) == out.get("bytes"), (st, sealed[:60]))
    stored = [os.path.join(d, f) for d, _, fs in os.walk(os.path.join(WORK, "media", done.get("id", "none"))) for f in fs]
    check("on disk there is the encrypted file and nothing else of that job",
          [os.path.basename(f) for f in stored] == ["out-0.png.age"] and all(b"\x89PNG" not in open(f, "rb").read() for f in stored), stored)
    if pyrage:
        try:
            plain = pyrage.decrypt(sealed, [AGE_IDENTITY])
        except Exception as e:  # noqa: BLE001 - whatever the library raises is a failure here
            plain = repr(e).encode()
        check("an independent age implementation (pyrage) decrypts it to the original PNG",
              plain.startswith(b"\x89PNG\r\n\x1a\n") and hashlib.sha256(plain).hexdigest() == out.get("plaintext_sha256")
              and len(plain) == out.get("plaintext_bytes"), plain[:60])
    elif os.environ.get("OMNIGATE_REQUIRE_PYRAGE"):
        check("an independent age implementation (pyrage) decrypts it to the original PNG", False, "pyrage is not installed")
    else:
        print("  note  pyrage is not installed: the decryption check was skipped (pip install pyrage)", flush=True)


class FakeControl:
    """A control plane played by this script, for one question the real one
    cannot be asked in a test: what does the data plane do with a target
    whose attestation IS verified? (The real control plane only says so after
    verifying a quote signed by an Intel processor, and nothing here can make
    one.) It serves a snapshot and takes usage reports; `answering = False`
    makes it refuse everything, like a control plane that is down."""

    def __init__(self, snapshot):
        import http.server
        import threading
        fake = self
        self.snapshot = snapshot
        self.answering = True
        # Usage events the data plane reported, by request id.
        self.events = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def answer(self):
                length = int(self.headers.get("content-length") or 0)
                sent = self.rfile.read(length) if length else b""
                if self.headers.get("x-omnigate-internal") != TOKEN or not fake.answering:
                    status, body = 503, b'{"error":{"message":"not now"}}'
                elif self.path == "/internal/config":
                    status, body = 200, json.dumps(fake.snapshot).encode()
                else:
                    if self.path == "/internal/usage/batch":
                        for event in json.loads(sent).get("events", []):
                            fake.events[event.get("id")] = event
                    status, body = 200, b'{"accepted":0,"duplicates":0}'
                self.send_response(status)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(body)))
                self.send_header("connection", "close")
                self.end_headers()
                self.wfile.write(body)
                self.close_connection = True

            do_GET = do_POST = answer

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", FAKE_CONTROL_PORT), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


def attestation_checks(stack):
    error_code = lambda body: (body.get("error") or {}).get("code") or (body.get("error") or {}).get("type")
    ask = lambda model, key, headers=None, base=GATEWAY: jcall("POST", base + "/v1/chat/completions", key=key, headers=headers,
                                                             body={"model": model, "messages": [{"role": "user", "content": "hi"}]})

    section("attested upstreams: evidence that does not hold is refused")
    def settled():
        _, _, listed = admin("GET", "/admin/attestations")
        rows = {(a["upstream"], a["model"]): a for a in listed.get("attestations", [])}
        return rows if len(rows) == 4 and all(a["state"] == "failed" for a in rows.values()) else None
    rows = wait_until(settled, 20) or {}
    reason = lambda model: (rows.get(("mock-attested", model)) or {}).get("reason") or ""
    code = lambda model: (rows.get(("mock-attested", model)) or {}).get("reason_code")
    check("every routed model of the attested upstream was checked and none passed",
          len(rows) == 4 and not any(a["verified"] for a in rows.values()), rows)
    check("a report whose quote is not an Intel quote: refused as such", code("attest-garbage-1") in ("bad_quote", "unsupported_quote"), (code("attest-garbage-1"), reason("attest-garbage-1")))
    check("a report that answers another nonce: refused as not fresh, before anything is fetched for it",
          code("attest-stale-1") == "nonce_mismatch" and "nonce" in reason("attest-stale-1"), (code("attest-stale-1"), reason("attest-stale-1")))
    check("a web page instead of a report: refused", code("attest-html-1") == "bad_report", (code("attest-html-1"), reason("attest-html-1")))
    check("a model the provider cannot attest: refused, with the provider's words",
          code("attest-none-1") == "report_unavailable" and "HTTP 503" in reason("attest-none-1"), (code("attest-none-1"), reason("attest-none-1")))

    status, _, body = ask("tee-only", KEY_PLAIN)
    check("a model whose targets are all unverified answers 503 attestation_unverified", status == 503 and error_code(body) == "attestation_unverified", (status, body))
    check("nothing of that request reached the provider",
          all(jcall("GET", f"http://127.0.0.1:9002/__last?model={m}")[0] == 404 for m in ("attest-garbage-1", "attest-html-1", "attest-none-1")))
    status, headers, body = ask("tee-then-plain", KEY_PLAIN)
    check("an unverified target is passed over like one that is down: the next target answers",
          status == 200 and headers.get("x-omnigate-upstream") == "mock-ok" and "x-omnigate-attestation" not in headers, (status, headers.get("x-omnigate-upstream"), body))

    section("privacy mode: attested providers only")
    status, _, body = ask("tee-then-plain", KEY_ATTESTED)
    check("a key that asks for attested providers is not failed over to an ordinary one", status == 503 and error_code(body) == "attestation_unverified", (status, body))
    status, _, body = ask("direct", KEY_ATTESTED)
    check("... and is refused on a model that has none", status == 503 and error_code(body) == "attestation_unverified", (status, body))
    before = jcall("GET", "http://127.0.0.1:9002/__watch")[2].get("requests")
    status, _, body = ask("direct", KEY_PLAIN, headers={"x-omnigate-privacy": "attested"})
    check("the request header asks for the same", status == 503 and error_code(body) == "attestation_unverified", (status, body))
    status, _, body = ask("direct", KEY_PLAIN, headers={"x-omnigate-privacy": "redact, attested, no-store"})
    check("... also next to the other parts", status == 503 and error_code(body) == "attestation_unverified", (status, body))
    check("none of those requests was sent anywhere", jcall("GET", "http://127.0.0.1:9002/__watch")[2].get("requests") == before)
    status, headers, _ = ask("direct", KEY_PLAIN, headers={"x-omnigate-privacy": "on"})
    check("\"on\" does not include it: a gateway without attested upstreams keeps working", status == 200 and headers.get("x-omnigate-privacy") == "no-store, redact, unlink", (status, headers.get("x-omnigate-privacy")))
    status, _, _ = ask("direct", KEY_PLAIN, headers={"x-omnigate-privacy": "attest"})
    check("a misspelt part is still a 400", status == 400, status)
    status, _, body = jcall("POST", GATEWAY + "/v1/jobs", key=KEY_ATTESTED, body={"model": "image", "input": {"prompt": "x"}})
    check("a media job is refused: no media provider is attested", status == 503 and error_code(body) == "attestation_unverified", (status, body))
    status, _, body = jcall("POST", GATEWAY + "/v1/jobs", key=KEY_PLAIN, headers={"x-omnigate-privacy": "attested"}, body={"model": "image", "input": {"prompt": "x"}})
    check("... also when only the header asks", status == 503 and error_code(body) == "attestation_unverified", (status, body))

    status, _, body = jcall("GET", GATEWAY + "/v1/attestations/req_does-not-exist", key=KEY_PLAIN)
    check("the receipt of a request that has none is a 404", status == 404 and error_code(body) == "receipt_not_found", (status, body))
    codes = [jcall(method, GATEWAY + path, key=key)[0] for method, path, key in (
        ("GET", "/v1/attestations/req_x", None), ("GET", "/v1/attestations/req_x", "og-not-a-key"), ("POST", "/v1/attestations/req_x", KEY_PLAIN),
        ("GET", "/v1/attestations/a%2Fb", KEY_PLAIN), ("GET", "/v1/attestations/" + "a" * 129, KEY_PLAIN))]
    check("... it needs a gateway key, is read-only, and takes nothing but a request id", codes == [401, 401, 405, 400, 404], codes)
    status, _, listed = admin("GET", "/admin/receipts")
    check("no receipt exists while no attestation verifies: nothing is claimed for an unverified provider",
          status == 200 and listed.get("receipts") == [] and listed.get("counts") == {"verified": 0, "not_verified": 0, "pending": 0}, (status, listed))

    status, _, verdict = admin("POST", "/admin/attestations/verify", {"upstream": "mock-attested", "model": "attest-stale-1"})
    check("\"verify now\" runs a fresh check and reports the verdict", status == 200 and verdict.get("state") == "failed" and verdict.get("checks", 0) >= 2, (status, verdict))
    status, _, _ = admin("POST", "/admin/attestations/verify", {"upstream": "mock-ok", "model": "ok-1"})
    check("... and knows no attestation for an ordinary upstream", status == 404, status)
    _, _, metrics = call("GET", CONTROL + "/metrics", headers={"authorization": "Bearer " + ADMIN_TOKEN})
    metrics = metrics.decode()
    check("metrics: the gauge is 0 for each unverified model, and failed checks are counted",
          'omnigate_attestation_verified{upstream="mock-attested",model="attest-stale-1"} 0' in metrics
          and 'omnigate_attestation_checks_total{outcome="failed"}' in metrics, [l for l in metrics.splitlines() if "attestation" in l and not l.startswith("#")])
    def refusals():
        _, _, overview = admin("GET", "/admin/overview")
        return next((r for r in overview.get("rejected", []) if r["key"] == "attested" and r["reason"] == "attestation_unverified"), None)
    check("the refusals are counted per key", bool(wait_until(lambda: (refusals() or {}).get("count", 0) >= 3, 10)), refusals())

    section("privacy dry run and the Private chat page")
    user = [{"role": "user", "content": PRIVATE_TEXT}]
    before = jcall("GET", "http://127.0.0.1:9002/__watch")[2].get("requests")
    status, headers, dry = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PLAIN, headers={"x-omnigate-privacy": "redact, unlink", "x-omnigate-dry-run": "privacy"},
                                 body={"model": "echo", "user": "customer-42", "messages": user})
    would = dry.get("body") or ""
    check("a dry run answers with the request as privacy mode left it",
          status == 200 and dry.get("object") == "omnigate.privacy_dry_run" and dry.get("sent_upstream") is False and headers.get("x-omnigate-dry-run") == "privacy"
          and all(p in would for p in PLACEHOLDERS) and not any(v in would for v in PII.values()) and "customer-42" not in would and CANARY in would, (status, dry))
    check("... says how many values of each class it replaced",
          dry.get("replaced") == {"email": 1, "phone": 1, "card": 1, "ip": 1, "secret": 1} and dry.get("protections") == "redact, unlink", dry.get("replaced"))
    check("... and sends nothing to any provider", jcall("GET", "http://127.0.0.1:9002/__watch")[2].get("requests") == before)
    status, _, plain = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PLAIN, headers={"x-omnigate-dry-run": "privacy"}, body={"model": "echo", "messages": user})
    check("without privacy mode the dry run shows the request unchanged", status == 200 and PII["email"] in (plain.get("body") or "") and plain.get("protections") == "", (status, plain))
    status, _, _ = jcall("POST", GATEWAY + "/v1/chat/completions", key=KEY_PLAIN, headers={"x-omnigate-dry-run": "yes"}, body={"model": "echo", "messages": user})
    check("a dry-run value that is not understood is a 400, never a real request",
          status == 400 and jcall("GET", "http://127.0.0.1:9002/__watch")[2].get("requests") == before, status)
    status, _, _ = jcall("POST", GATEWAY + "/v1/chat/completions", key="og-not-a-key", headers={"x-omnigate-dry-run": "privacy"}, body={"model": "echo", "messages": user})
    check("a dry run needs a gateway key like any request", status == 401, status)

    status, headers, page = control_raw("GET", "/private-chat", {"authorization": "Bearer " + ADMIN_TOKEN})
    check("the Private chat page is served to a signed-in operator, with nothing loaded from elsewhere",
          status == 200 and "Private chat" in page and "What left this machine" in page and "default-src 'none'" in headers.get("content-security-policy", "")
          and "http://" not in page.replace("http://www.w3.org", "") and "https://" not in page, (status, headers.get("content-security-policy")))
    status, headers, _ = control_raw("GET", "/private-chat")
    check("... and sends anyone else to the login form", status == 302 and headers.get("location") == "/login", (status, headers.get("location")))
    status, _, state = admin("GET", "/admin/private-chat/state")
    by_model = {m["model"]: m for m in state.get("models", [])}
    check("its state lists the text models and which targets are attested",
          status == 200 and state.get("gateway_url") == GATEWAY and by_model.get("echo", {}).get("targets", [{}])[0].get("attested") is False
          and (by_model.get("tee-then-plain", {}).get("targets") or [{}])[0].get("attested") is True
          and ((by_model.get("tee-then-plain", {}).get("targets") or [{}])[0].get("attestation") or {}).get("verified") is False, (status, list(by_model)))
    status, _, turn = admin("POST", "/admin/private-chat/send", {"model": "echo", "messages": user, "redact": True, "attested": False})
    shown = (turn.get("dry_run") or {}).get("body") or ""
    answer = turn.get("response") or {}
    check("a message sent from the page: the answer has the real values, the panel shows the placeholders the provider got",
          status == 200 and answer.get("ok") is True and answer.get("text") == "You said: " + PRIVATE_TEXT and all(p in shown for p in PLACEHOLDERS)
          and not any(v in shown for v in PII.values()) and hidden(seen_by(9002)), (status, turn))
    check("... sent with the page's own managed key, as no-store",
          answer.get("privacy") == "no-store, redact, unlink" and answer.get("upstream") == "mock-ok" and any(k.get("name") == "private-chat" and k.get("source") == "managed" for k in admin("GET", "/admin/keys")[2].get("keys", [])),
          (answer.get("privacy"), answer.get("upstream")))
    status, _, turn = admin("POST", "/admin/private-chat/send", {"model": "echo", "messages": user, "redact": True, "attested": True})
    answer = turn.get("response") or {}
    check("with \"attested providers only\" the same message is refused, unsent, and the page is told why",
          status == 200 and answer.get("ok") is False and answer.get("status") == 503 and (answer.get("error") or {}).get("code") == "attestation_unverified"
          and answer.get("upstream") is None and (turn.get("dry_run") or {}).get("ok") is True, (status, turn))
    codes = [admin("POST", "/admin/private-chat/send", body)[0] for body in (
        {"model": "no-such-model", "messages": user}, {"model": "echo", "messages": []}, {"model": "echo", "messages": [{"role": "system", "content": "x"}]},
        {"model": "echo", "messages": [{"role": "user", "content": "x" * 40000}]})]
    check("the page's endpoint refuses what it does not send: unknown models, empty or oversized conversations, other roles", codes == [400, 400, 400, 400], codes)
    status, _, _ = control_raw("POST", "/admin/private-chat/send", {"content-type": "application/json", "cookie": "omnigate_session=forged"}, raw=json.dumps({"model": "echo", "messages": user}))
    check("... and anyone without the admin token or a session", status in (401, 403), status)

    section("attested upstreams: a verified target, and a control plane that goes quiet")
    # The data plane on its own, in front of a control plane played by this
    # script: the only way to show it a target that IS verified.
    key = lambda name, secret, privacy=None: {"key_sha256": sha(secret), "name": name, "blocked": False, "rpm": 0, "max_concurrent": 0, "models": None, "privacy": privacy}
    verified = {"verified": True, "max_age_s": 3, "tcb": "UpToDate", "since": 1762850000}
    fake = FakeControl({
        "version": "fake-1",
        "keys": [key("plain", KEY_PLAIN), key("attested", KEY_ATTESTED, {"no_store": False, "redact": [], "unlink": False, "attested": True})],
        "upstreams": [{"name": "tee", "kind": "openai", "base_url": "http://127.0.0.1:9002", "api_key_env": "MOCK_API_KEY", "timeout_ms": 0},
                      {"name": "open", "kind": "openai", "base_url": "http://127.0.0.1:9002", "api_key_env": "MOCK_API_KEY", "timeout_ms": 0}],
        "routes": [{"model": "tee", "strategy": "failover", "cache_ttl_s": 0, "targets": [{"upstream": "tee", "model": "ok-1", "weight": 1, "attestation": verified}]},
                   {"model": "tee-withdrawn", "strategy": "failover", "cache_ttl_s": 0,
                    "targets": [{"upstream": "tee", "model": "ok-1", "weight": 1, "attestation": dict(verified, verified=False, tcb=None, since=0)}]},
                   {"model": "open", "strategy": "failover", "cache_ttl_s": 0, "targets": [{"upstream": "open", "model": "ok-1", "weight": 1}]}],
        "media_models": [],
    })
    second = os.path.join(stack.work, "gateway2")
    os.makedirs(second, exist_ok=True)
    exe = os.path.join(ROOT, "dataplane", "zig-out", "bin", "omnigate-dp" + (".exe" if WINDOWS else ""))
    proc = stack.start("gateway2", [exe], cwd=second, env={"OMNIGATE_LISTEN": f"127.0.0.1:{GATEWAY2_PORT}", "OMNIGATE_CONTROL_URL": f"http://127.0.0.1:{FAKE_CONTROL_PORT}",
                                                           "OMNIGATE_POLL_MS": "300", "OMNIGATE_FLUSH_MS": "200"})
    try:
        if not wait_port(GATEWAY2_PORT, 15, proc):
            stack.fail("the second gateway did not start", "gateway2")
        wait_until(lambda: call("GET", GATEWAY2 + "/v1/models", key=KEY_PLAIN)[0] == 200, 15)
        status, headers, body = ask("tee", KEY_ATTESTED, base=GATEWAY2)
        check("a request for attested providers goes to a target whose attestation is verified", status == 200 and headers.get("x-omnigate-upstream") == "tee", (status, body))
        check("the response says so: x-omnigate-attestation", headers.get("x-omnigate-attestation") == "verified; tcb=UpToDate; since=1762850000", headers.get("x-omnigate-attestation"))
        status, headers, _ = ask("tee", KEY_PLAIN, base=GATEWAY2)
        check("any request to that target carries the header", status == 200 and (headers.get("x-omnigate-attestation") or "").startswith("verified;"), headers.get("x-omnigate-attestation"))
        status, headers, _ = ask("open", KEY_PLAIN, base=GATEWAY2)
        check("a response from an ordinary target does not", status == 200 and "x-omnigate-attestation" not in headers, headers.get("x-omnigate-attestation"))
        status, _, body = ask("tee-withdrawn", KEY_PLAIN, base=GATEWAY2)
        check("a target the control plane calls unverified is not used", status == 503 and error_code(body) == "attestation_unverified", (status, body))
        status, _, body = ask("open", KEY_ATTESTED, base=GATEWAY2)
        check("the attested key is refused on the ordinary model here too", status == 503 and error_code(body) == "attestation_unverified", (status, body))

        # What the data plane reports for an answer's receipt: hashes of the
        # exact bytes it sent and received, and the provider's id. (The
        # signature check on them is the control plane's; `receipts_test.exs`.)
        reported = lambda headers: wait_until(lambda: fake.events.get(headers.get("x-omnigate-request-id")), 10) or {}
        mock_saw = lambda: jcall("GET", "http://127.0.0.1:9002/__last?model=ok-1")[2]
        status, headers, body = ask("tee", KEY_PLAIN, base=GATEWAY2)
        seen, receipt = mock_saw(), reported(headers).get("receipt") or {}
        check("an answer from a verified target is reported with the SHA-256 of the request body as the provider received it",
              status == 200 and receipt.get("request_sha256") == seen.get("body_sha256") == sha(seen.get("body", "")), (receipt, seen.get("body_sha256")))
        check("... the SHA-256 of the response body as the provider sent it, and the provider's id for it",
              receipt.get("response_sha256") == seen.get("response_sha256") and receipt.get("completion_id") == body.get("id") == "chatcmpl-mock", (receipt, seen.get("response_sha256")))
        check("... and the provider was asked not to substitute another model", seen.get("headers", {}).get("x-no-aliasing") == "true", seen.get("headers"))
        conn = http.client.HTTPConnection("127.0.0.1", GATEWAY2_PORT, timeout=30)
        conn.request("POST", "/v1/chat/completions", body=json.dumps({"model": "tee", "stream": True, "messages": [{"role": "user", "content": "hi"}]}),
                     headers={"content-type": "application/json", "authorization": f"Bearer {KEY_PLAIN}"})
        resp = conn.getresponse()
        streamed = resp.read()
        conn.close()
        seen, receipt = mock_saw(), reported({"x-omnigate-request-id": resp.getheader("x-omnigate-request-id")}).get("receipt") or {}
        check("a streamed answer is hashed as it arrived, every event and blank line of it",
              resp.status == 200 and b"[DONE]" in streamed and receipt.get("response_sha256") == seen.get("response_sha256")
              and receipt.get("request_sha256") == seen.get("body_sha256") and receipt.get("completion_id") == "chatcmpl-mock", (receipt, seen.get("response_sha256")))
        status, headers, _ = ask("open", KEY_PLAIN, base=GATEWAY2)
        check("an answer from an ordinary target carries none of this",
              status == 200 and "id" in reported(headers) and reported(headers).get("receipt") is None and "x-no-aliasing" not in mock_saw().get("headers", {}), reported(headers))

        fake.answering = False
        time.sleep(4.5)
        status, _, body = ask("tee", KEY_ATTESTED, base=GATEWAY2)
        check("once the control plane has been quiet for longer than max_age_s, \"verified\" no longer counts", status == 503 and error_code(body) == "attestation_unverified", (status, body))
        status, _, _ = ask("open", KEY_PLAIN, base=GATEWAY2)
        check("... while everything else keeps being served from the last config", status == 200, status)
        fake.answering = True
        back = wait_until(lambda: ask("tee", KEY_ATTESTED, base=GATEWAY2)[0] == 200, 10)
        check("and it counts again when the control plane answers", bool(back))
    finally:
        stack.stop("gateway2")
        fake.stop()


def receipt_tool_checks(work):
    """tools/verify_receipt.py against a receipt whose signatures were made
    with Erlang's own Ed25519 (the control plane's), so that the script's
    pure-Python verification is checked against another implementation."""
    section("receipts: checked offline with tools/verify_receipt.py")
    tool = os.path.join(ROOT, "tools", "verify_receipt.py")
    request = b'{"model":"vendor/tee-model-1","messages":[{"role":"user","content":"hi"}]}'
    response = b'data: {"id":"chatcmpl-vector","choices":[{"delta":{"content":"hello"}}]}\n\ndata: [DONE]\n\n'
    public = "3c403e79e5471b95fb743cc42f5c4d25de2e400d861613a0ef1be976c1ca746e"
    pair = hashlib.sha256(request).hexdigest() + ":" + hashlib.sha256(response).hexdigest()
    signatures = {
        "provider_tee": ("vendor/tee-model-1:" + pair, "8f5965b5f7e4022a28f1328a6750e3534da994eef0df459a53b41397d5557a065ca0a181fd49d0c03cdf142703b9eec529ae242cb15014896f941f9fb1c0b208"),
        "gateway": (pair, "eddac1ed2ae26791d311958a5339123edb5052aaffb07cfd9567e559e5306b77ad827b1ddb1aa5ea884f3839ff023a21f761ff57cfdb7a03a081e67f5e789801"),
    }

    def receipt(kind, **changes):
        text, signature = signatures[kind]
        r = {"object": "attestation.receipt", "id": "req_vector", "model": "vendor/tee-model-1", "verdict": "verified",
             "request_sha256": hashlib.sha256(request).hexdigest(), "response_sha256": hashlib.sha256(response).hexdigest(),
             "signature": {"kind": kind, "text": text, "signature": signature, "signing_address": public, "signing_algo": "ed25519"},
             "attestation": {"verified_at": 1762850000, "reports": [{"role": "model", "tcb_status": "UpToDate", "signed_this_answer": True}]}}
        r.update(changes)
        return r

    def run(r, req=request, resp=response, extra=()):
        paths = [os.path.join(work, name) for name in ("receipt.json", "request.bin", "response.bin")]
        for path, data in zip(paths, (json.dumps(r).encode(), req or b"", resp or b"")):
            with open(path, "wb") as f:
                f.write(data)
        p = subprocess.run([sys.executable, tool, *(paths if req is not None else paths[:1]), *extra], capture_output=True, text=True, timeout=120)
        return p.returncode, p.stdout.strip().splitlines()[-1] if p.stdout.strip() else p.stderr.strip()

    p = subprocess.run([sys.executable, tool, "--self-test"], capture_output=True, text=True, timeout=120)
    check("its Ed25519 code passes the RFC 8032 test vectors", p.returncode == 0 and p.stdout.count("PASS") == 3, p.stdout + p.stderr)
    check("a model-signed receipt with its two bodies: VERIFIED", run(receipt("provider_tee")) == (0, "VERIFIED"), run(receipt("provider_tee")))
    check("a gateway-signed receipt: VERIFIED", run(receipt("gateway")) == (0, "VERIFIED"), run(receipt("gateway")))
    check("... and with the expected signer named", run(receipt("gateway"), extra=("--signer", public)) == (0, "VERIFIED"))
    flipped = bytearray(response)
    flipped[10] ^= 1
    outcomes = {
        "one byte of the response changed": run(receipt("provider_tee"), resp=bytes(flipped)),
        "one byte of the request changed": run(receipt("provider_tee"), req=request + b" "),
        "the signature altered": run(receipt("provider_tee", signature=dict(receipt("provider_tee")["signature"], signature="9" + signatures["provider_tee"][1][1:]))),
        "a gateway signature passed off as the model's": run(receipt("provider_tee", signature=dict(receipt("gateway")["signature"], kind="provider_tee"))),
        "another model named": run(receipt("provider_tee", model="vendor/other-model")),
        "the hashes in the receipt swapped for others": run(receipt("gateway", response_sha256="0" * 64), req=None, resp=None),
        "another key named": run(receipt("gateway", signature=dict(receipt("gateway")["signature"], signing_address="d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))),
        "an unexpected signer": run(receipt("gateway"), extra=("--signer", "00" * 32)),
        "no signature at all": run(receipt("gateway", signature=None, verdict="not_verified")),
        "an unknown kind of signer": run(receipt("gateway", signature=dict(receipt("gateway")["signature"], kind="relay"))),
    }
    check("anything else is NOT VERIFIED, with exit status 1: a changed byte, a changed signature, the wrong signer, the wrong model",
          all(o == (1, "NOT VERIFIED") for o in outcomes.values()), {k: v for k, v in outcomes.items() if v != (1, "NOT VERIFIED")})
    check("without the bodies it says so, and checks the signature against the hashes alone", run(receipt("gateway"), req=None, resp=None) == (0, "VERIFIED"))


def leftovers(work):
    """Files the stack wrote that still contain the private canary."""
    found = []
    for folder, _, names in os.walk(work):
        for name in names:
            # The mocks are the providers: they are meant to see the prompt.
            if name in ("mock_upstream.log", "mock_media.log"):
                continue
            path = os.path.join(folder, name)
            try:
                with open(path, "rb") as f:
                    if CANARY.encode() in f.read():
                        found.append(os.path.relpath(path, work))
            except OSError:
                pass
    return found



def control_env(work):
    return {
        "OMNIGATE_JOBS": os.path.join(work, "jobs.jsonl"),
        # Managed keys (with the top-up references) and the audit log of this
        # run only: a payment reference used here must not be known already.
        "OMNIGATE_KEYS": os.path.join(work, "keys.json"),
        "OMNIGATE_AUDIT_LOG": os.path.join(work, "audit.jsonl"),
        "OMNIGATE_PAYMENTS": os.path.join(work, "payments.json"),
        # Where the control plane reaches the data plane (the Private chat page).
        "OMNIGATE_GATEWAY_URL": GATEWAY,
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
        # Small enough for one mock file ("huge", 3 MiB) to be over it.
        "max_output_bytes": 2 * 1024 * 1024,
        "upstreams": [
            up("replicate-broken", "replicate", MOCK["replicate_broken"]),
            up("replicate", "replicate", MOCK["replicate"]),
            up("fal", "fal", MOCK["fal"]),
            up("openai-images", "openai_images", MOCK["openai_images"]),
            up("elevenlabs", "elevenlabs", MOCK["elevenlabs"]),
            up("gemini", "gemini", MOCK["gemini"]),
            up("xai-video", "xai_video", MOCK["xai_video"]),
            up("gemini-interactions", "gemini_interactions", MOCK["gemini"]),
            up("sume", "sume", MOCK["sume"]),
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
            # Sume: which router a model is on is said; the image route fails
            # over to another provider, the video one is priced by request.
            {"model": "sume-image", "timeout_s": 60, "targets": [
                {"upstream": "sume", "model": "mock-image", "router": "image", "price": {"per_output_usd": 0.04}},
                {"upstream": "replicate", "model": "mock/image", "price": {"per_output_usd": 0.003}}]},
            {"model": "sume-video", "timeout_s": 60, "targets": [
                {"upstream": "sume", "model": "mock-video", "router": "video", "price": {"variants": [
                    {"when": {"resolution": "720p", "generate_audio": False}, "per_second_usd": 0.08},
                    {"when": {"resolution": "720p", "generate_audio": True}, "per_second_usd": 0.10},
                    {"when": {"resolution": "720p", "generate_audio": None}, "per_second_usd": 0.10}]}}]},
            {"model": "tts", "cache_ttl_s": 3600, "targets": [
                {"upstream": "elevenlabs", "model": "mock_multilingual_v2", "price": {"per_input_char_usd": 0.00003}}]},
            # ElevenLabs beyond speech: which product a target uses is said.
            {"model": "el-sound", "targets": [
                {"upstream": "elevenlabs", "model": "eleven_text_to_sound_v2", "api": "sound", "default_seconds": 5, "max_seconds": 30, "price": {"per_second_usd": 0.01}}]},
            {"model": "el-music", "timeout_s": 60, "targets": [
                {"upstream": "elevenlabs", "model": "music_v1", "api": "music", "default_seconds": 30, "price": {"per_second_usd": 0.02}}]},
            {"model": "el-image", "timeout_s": 60, "targets": [
                {"upstream": "elevenlabs", "model": "mock-image-model", "api": "image", "price": {"per_output_usd": 0.05}},
                {"upstream": "replicate", "model": "mock/image", "price": {"per_output_usd": 0.003}}]},
            {"model": "el-video", "timeout_s": 60, "targets": [
                {"upstream": "elevenlabs", "model": "mock-video-model", "api": "video", "max_seconds": 10, "price": {"variants": [
                    {"when": {"resolution": "480p"}, "per_second_usd": 0.05},
                    {"when": {"resolution": "720p"}, "per_second_usd": 0.10}]}}]},
        ],
        "storage": stores[storage],
        "webhooks": {"allow_private": True, "retry_schedule_ms": [300, 300, 600, 1000], "max_attempts": 5},
    }


def create_job(body, key=KEY_MAIN, idem=None, tag=None):
    headers = {"idempotency-key": idem} if idem else {}
    if tag:
        headers["x-omnigate-tag"] = tag
    return jcall("POST", GATEWAY + "/v1/jobs", key=key, body=body, headers=headers)


def get_job(job_id, key=KEY_MAIN):
    return jcall("GET", f"{GATEWAY}/v1/jobs/{job_id}", key=key)[2]


def wait_job(job_id, timeout=30, until=TERMINAL, key=KEY_MAIN):
    return wait_until(lambda: (lambda j: j if j.get("status") in until else None)(get_job(job_id, key)), timeout, 0.2) or get_job(job_id, key)


def stats(name):
    return jcall("GET", MOCK[name] + "/_stats")[2]


def close(a, b):
    return a is not None and abs(a - b) < 1e-9


def sume_checks():
    """The Sume adapter against tools/mock_media.py, which follows Sume's
    public documentation. None of this has met the real service."""
    def run(body, key=KEY_SUME, timeout=30):
        status, _, job = create_job(body, key=key)
        return status, wait_job(job.get("id", "missing"), timeout, key=key) if status == 202 else job
    outcome = lambda job, i=0: ((job.get("attempts") or [{}] * (i + 1))[i]).get("outcome", "")

    section("Sume: image and video routers, prices that follow the request")
    before = stats("sume")
    status, job = run({"model": "sume-image", "input": {"prompt": "a ceramic cup", "num_images": 2, "mode": "sync", "webhook_url": "https://example.com/hook"},
                       "metadata": {"order": "S-1"}})
    check("an image job runs on Sume's image router and is billed per image",
          status == 202 and job.get("status") == "succeeded" and job.get("upstream") == "sume" and len(job.get("outputs") or []) == 2
          and close(job.get("cost_usd"), 0.08), job)
    last = jcall("GET", MOCK["sume"] + "/_last")[2]
    check("Sume was sent the input with the model filled in, always async, without a webhook or metadata",
          last.get("path") == "/v1/image-router/generate"
          and last.get("body") == {"prompt": "a ceramic cup", "num_images": 2, "model": "mock-image", "mode": "async"}
          and str(last.get("idempotency_key", "")).startswith("og-") and stats("sume")["leaked_fields"] == before["leaked_fields"], last)
    st, _, data = call("GET", (job.get("outputs") or [{}])[0].get("url", GATEWAY))
    check("its output was fetched from Sume's media host and re-hosted", st == 200 and data[:8] == b"\x89PNG\r\n\x1a\n", (st, data[:40]))

    status, job = run({"model": "sume-video", "input": {"prompt": "short clip of steam", "duration": 6, "resolution": "720p", "generate_audio": False}})
    check("a video job is billed for the seconds Sume reports (3 of the 6 asked for), at the rate of its resolution without audio",
          job.get("status") == "succeeded" and close(job.get("cost_usd"), 3 * 0.08)
          and jcall("GET", MOCK["sume"] + "/_last")[2].get("path") == "/v1/video-router/generate", job)
    status, job = run({"model": "sume-video", "input": {"prompt": "steam with sound", "duration": 4, "resolution": "720p", "generate_audio": True}})
    check("with audio, the same resolution costs its own rate", job.get("status") == "succeeded" and close(job.get("cost_usd"), 4 * 0.10), job)
    submits = stats("sume")["submits"]
    status, _, refused = create_job({"model": "sume-video", "input": {"prompt": "x", "duration": 4, "resolution": "1080p"}}, key=KEY_SUME)
    check("a combination the operator has set no price for is refused before anything is sent",
          status == 400 and "no price for this combination" in json.dumps(refused) and stats("sume")["submits"] == submits, (status, refused))

    section("Sume: one charge per job, failover, failures")
    before = stats("sume")
    status, job = run({"model": "sume-image", "input": {"prompt": "drop first answer"}})
    after = stats("sume")
    check("a submit whose answer is lost is sent again with the same Idempotency-Key: one provider job, billed once",
          job.get("status") == "succeeded" and job.get("upstream") == "sume" and close(job.get("cost_usd"), 0.04)
          and after["jobs_created"] == before["jobs_created"] + 1 and after["idempotency_hits"] == before["idempotency_hits"] + 1, (job, before, after))
    status, job = run({"model": "sume-image", "input": {"prompt": "busy once please"}})
    check("a refusal Sume calls retryable, with a short wait, is retried on Sume", job.get("status") == "succeeded" and job.get("upstream") == "sume", job)
    status, job = run({"model": "sume-image", "input": {"prompt": "no funds today"}})
    check("insufficient funds at Sume moves the job to the route's next provider",
          job.get("status") == "succeeded" and job.get("upstream") == "replicate" and outcome(job).startswith("sume_insufficient_funds")
          and close(job.get("cost_usd"), 0.003), job)
    status, job = run({"model": "sume-image", "input": {"prompt": "rate limited for long"}})
    check("so does a rate limit that asks for a long wait",
          job.get("status") == "succeeded" and job.get("upstream") == "replicate" and outcome(job).startswith("sume_rate_limited"), job)
    status, job = run({"model": "sume-video", "input": {"prompt": "fail this one", "duration": 4, "resolution": "720p"}})
    check("a job Sume fails is reported with Sume's reason and is not billed",
          job.get("status") == "failed" and outcome(job).startswith("sume_content_policy_rejected: ") and not job.get("cost_usd"), job)
    status, job = run({"model": "sume-video", "input": {"prompt": "throttle slowpoll", "duration": 4, "resolution": "720p"}})
    check("a 429 on a poll and a longer poll interval asked for by Sume are honoured, and the job still finishes",
          job.get("status") == "succeeded" and close(job.get("cost_usd"), 0.40), job)

    section("Sume: cancel, before and after generation starts")
    before = stats("sume")
    _, _, queued = create_job({"model": "sume-image", "input": {"prompt": "long queue ahead"}}, key=KEY_SUME)
    wait_until(lambda: (get_job(queued.get("id", "missing"), KEY_SUME).get("status") == "running" and stats("sume")["polls"] > before["polls"]) or None, 10)
    jcall("POST", f"{GATEWAY}/v1/jobs/{queued.get('id')}/cancel", key=KEY_SUME, body={})
    done = wait_until(lambda: (lambda j: j if j.get("status") == "canceled" and not j.get("provider_pending") else None)(get_job(queued.get("id", "missing"), KEY_SUME)), 10) or {}
    check("while Sume says the job is cancelable, a cancel stops it there and nothing is owed",
          done.get("status") == "canceled" and not done.get("cost_usd") and wait_until(lambda: stats("sume")["canceled"] == before["canceled"] + 1 or None, 5), (done, stats("sume")))
    before = stats("sume")
    _, _, started = create_job({"model": "sume-image", "input": {"prompt": "slow render"}}, key=KEY_SUME)
    wait_job(started.get("id", "missing"), 10, until=("running",) + TERMINAL, key=KEY_SUME)
    time.sleep(1.0)  # past the queue: generation has started
    _, _, at_once = jcall("POST", f"{GATEWAY}/v1/jobs/{started.get('id')}/cancel", key=KEY_SUME, body={})
    billed = wait_until(lambda: (lambda j: j if close(j.get("cost_usd"), 0.04) else None)(get_job(started.get("id", "missing"), KEY_SUME)), 15) or {}
    after = stats("sume")
    check("once generation has started the job is canceled here at once, and billed when Sume completes it; nothing is fetched",
          at_once.get("status") == "canceled" and billed.get("status") == "canceled" and close(billed.get("cost_usd"), 0.04) and billed.get("outputs") == []
          and after["canceled"] == before["canceled"] and after["downloads"] == before["downloads"], (at_once, billed, before, after))
    # 0.08 + 0.24 + 0.40 + 0.04 + 0.04 + 0.003 + 0.003 + 0.40 + 0.04
    row = wait_until(lambda: (lambda r: r if close(r.get("cost_usd"), 1.246) else None)(usage_row("sume")), 10) or usage_row("sume")
    check("the key's ledger holds exactly what these jobs cost", close(row.get("cost_usd"), 1.246), row)

    section("Sume: privacy mode")
    status, _, job = create_job({"model": "sume-video", "input": {"prompt": f"{CANARY} fail", "duration": 4, "resolution": "720p"}}, key=KEY_PRIVATE)
    job = wait_job(job.get("id", "missing"), key=KEY_PRIVATE)
    check("a private job that fails at Sume keeps Sume's reason and none of the provider's words",
          job.get("status") == "failed" and outcome(job) == "sume_content_policy_rejected" and job.get("input_erased") is True, job)
    status, _, job = create_job({"model": "sume-image", "input": {"prompt": "a sealed cup"}}, key=KEY_SEALED)
    job = wait_job(job.get("id", "missing"), key=KEY_SEALED)
    out = (job.get("outputs") or [{}])[0]
    st, _, sealed = call("GET", out.get("url", GATEWAY))
    check("a key with encrypt_to gets a Sume output as an age file",
          job.get("status") == "succeeded" and job.get("upstream") == "sume" and out.get("encryption") == "age"
          and st == 200 and sealed.startswith(b"age-encryption.org/v1\n") and b"\x89PNG" not in sealed, (job, sealed[:40]))


def elevenlabs_checks():
    """ElevenLabs beyond speech against tools/mock_media.py, which follows
    ElevenLabs' public documentation."""
    def run(body, key=KEY_ELEVEN, timeout=30):
        status, _, job = create_job(body, key=key)
        return status, wait_job(job.get("id", "missing"), timeout, key=key) if status == 202 else job
    outcome = lambda job, i=0: ((job.get("attempts") or [{}] * (i + 1))[i]).get("outcome", "")
    last = lambda: jcall("GET", MOCK["elevenlabs"] + "/_last")[2]
    fetch = lambda job: call("GET", ((job.get("outputs") or [{}])[0]).get("url", GATEWAY))
    leaked = stats("elevenlabs")["leaked_fields"]

    section("ElevenLabs: sound effects and music, one call each, billed by the second")
    status, job = run({"model": "el-sound", "input": {"text": "glass breaking", "duration": 2, "loop": True, "voice_id": "ignored"}})
    st, _, audio = fetch(job)
    check("a sound effect is one call that answers with audio, re-hosted and billed for the seconds asked for",
          status == 202 and job.get("status") == "succeeded" and job.get("upstream") == "elevenlabs" and close(job.get("cost_usd"), 0.02)
          and st == 200 and audio[:3] == b"ID3" and (job.get("outputs") or [{}])[0].get("content_type") == "audio/mpeg", (job, audio[:20]))
    seen = last()
    check("the provider got the length under its own name, the model as model_id, and no field of another product",
          seen.get("path") == "/v1/sound-generation" and seen.get("query") == "output_format=mp3_44100_128"
          and seen.get("body") == {"text": "glass breaking", "loop": True, "duration_seconds": 2, "model_id": "eleven_text_to_sound_v2"}, seen)
    status, job = run({"model": "el-sound", "input": {"text": "rain on a roof", "duration_seconds": 30}})
    check("the provider's own name for the length is not taken from the request: no length is sent, and the default is billed",
          job.get("status") == "succeeded" and close(job.get("cost_usd"), 0.05) and "duration_seconds" not in last().get("body", {}), (job, last()))
    status, _, refused = create_job({"model": "el-sound", "input": {"text": "x", "duration": 45}}, key=KEY_ELEVEN)
    check("a length above the target's max_seconds is refused before anything is sent", status == 400 and "at most 30" in json.dumps(refused), (status, refused))
    status, job = run({"model": "el-sound", "input": {"text": "x", "duration": 0.2}})
    check("a length the product does not take fails the job with a reason, unbilled",
          job.get("status") == "failed" and outcome(job).startswith("invalid_input") and not job.get("cost_usd"), job)

    status, job = run({"model": "el-music", "input": {"prompt": "a slow piano waltz", "duration": 3, "force_instrumental": True, "store_for_inpainting": True}})
    seen = last()
    check("music from a prompt: the length goes out in milliseconds, and the song is not kept at the provider",
          job.get("status") == "succeeded" and close(job.get("cost_usd"), 0.06) and fetch(job)[2][:3] == b"ID3" and seen.get("path") == "/v1/music"
          and seen.get("body") == {"prompt": "a slow piano waltz", "force_instrumental": True, "music_length_ms": 3000, "model_id": "music_v1"}
          and seen.get("query") == "" and stats("elevenlabs")["leaked_fields"] == leaked, (job, seen))
    plan = {"positive_global_styles": ["waltz"], "negative_global_styles": [], "sections": [
        {"section_name": "a", "positive_local_styles": [], "negative_local_styles": [], "duration_ms": 3000, "lines": []},
        {"section_name": "b", "positive_local_styles": [], "negative_local_styles": [], "duration_ms": 4000, "lines": []}]}
    status, job = run({"model": "el-music", "input": {"composition_plan": plan}})
    check("music from a composition plan is billed for the sum of its sections", job.get("status") == "succeeded" and close(job.get("cost_usd"), 0.14), job)
    status, job = run({"model": "el-music", "input": {"prompt": "x", "composition_plan": plan}})
    check("a prompt and a plan together are refused by the adapter", job.get("status") == "failed" and outcome(job).startswith("invalid_input"), job)
    status, job = run({"model": "el-music", "input": {"prompt": "a paid plan please", "duration": 3}})
    check("a refusal for lack of a paid plan fails the job with the provider's code and words, unbilled",
          job.get("status") == "failed" and outcome(job) == "elevenlabs_paid_plan_required: The Music API requires a paid plan." and not job.get("cost_usd"), job)

    section("ElevenLabs: images and videos, started and asked about until they end")
    before = stats("elevenlabs")
    status, job = run({"model": "el-image", "input": {"prompt": "a ceramic cup", "aspect_ratio": "1:1", "webhook": {"url": "https://example.com/hook"}, "model_id": "something-else"}})
    st, _, image = fetch(job)
    after = stats("elevenlabs")
    check("an image job is created, polled, and its file fetched from the signed link and re-hosted",
          job.get("status") == "succeeded" and job.get("upstream") == "elevenlabs" and close(job.get("cost_usd"), 0.05) and st == 200 and image[:8] == b"\x89PNG\r\n\x1a\n"
          and after["image"] == before["image"] + 1 and after["polls"] > before["polls"] and after["downloads"] == before["downloads"] + 1, (job, before, after))
    seen = last()
    check("the provider got the target's model and never the caller's webhook",
          seen.get("path") == "/v1/flows/image" and seen.get("body") == {"prompt": "a ceramic cup", "aspect_ratio": "1:1", "model_id": "mock-image-model"}
          and after["leaked_fields"] == before["leaked_fields"], seen)
    status, job = run({"model": "el-image", "input": {"prompt": "needs a paid plan"}})
    check("402 paid_plan_required moves the job to the route's next provider, with the provider's words in the attempt",
          job.get("status") == "succeeded" and job.get("upstream") == "replicate" and close(job.get("cost_usd"), 0.003)
          and outcome(job) == "elevenlabs_paid_plan_required: This endpoint requires a Pro plan or above.", job)
    status, job = run({"model": "el-image", "input": {"prompt": "fail this one"}})
    check("a generation the provider fails is reported with its reason, and the next provider runs the job",
          job.get("status") == "succeeded" and job.get("upstream") == "replicate" and outcome(job) == "elevenlabs_moderated: The prompt was flagged by moderation.", job)
    status, job = run({"model": "el-image", "input": {"prompt": "a huge poster"}})
    check("an output over media.max_output_bytes is not stored; the next provider runs the job",
          job.get("status") == "succeeded" and job.get("upstream") == "replicate" and outcome(job).startswith("output_fetch_failed"), job)

    status, job = run({"model": "el-video", "input": {"prompt": "steam over a cup", "duration": 4, "resolution": "480p", "duration_secs": 60}})
    st, _, clip = fetch(job)
    seen = last()
    check("a video job is billed for the seconds asked for at the rate of its resolution",
          job.get("status") == "succeeded" and close(job.get("cost_usd"), 0.20) and st == 200 and clip[4:8] == b"ftyp"
          and seen.get("path") == "/v1/flows/video" and seen.get("body") == {"prompt": "steam over a cup", "resolution": "480p", "duration_secs": 4, "model_id": "mock-video-model"}, (job, seen))
    status, _, refused = create_job({"model": "el-video", "input": {"prompt": "x", "duration": 12, "resolution": "480p"}}, key=KEY_ELEVEN)
    check("a video longer than max_seconds is refused at once", status == 400 and "at most 10" in json.dumps(refused), (status, refused))
    status, _, refused = create_job({"model": "el-video", "input": {"prompt": "x", "duration": 4, "resolution": "4k"}}, key=KEY_ELEVEN)
    check("a resolution without a price is refused at once", status == 400 and "no price for this combination" in json.dumps(refused), (status, refused))
    status, job = run({"model": "el-video", "input": {"prompt": "x", "duration": 4.5, "resolution": "480p"}})
    check("a fraction of a second fails the job: the provider takes whole seconds", job.get("status") == "failed" and outcome(job).startswith("invalid_input"), job)
    status, job = run({"model": "el-video", "input": {"prompt": "too short for this model", "duration": 2, "resolution": "480p"}})
    check("a request the provider's validation refuses fails the job with the field and what is wrong with it",
          job.get("status") == "failed" and outcome(job) == "elevenlabs_validation_error: duration_secs: Input should be greater than or equal to 4", job)

    before = stats("elevenlabs")
    _, _, started = create_job({"model": "el-video", "input": {"prompt": "to be canceled", "duration": 2, "resolution": "720p"}}, key=KEY_ELEVEN)
    wait_until(lambda: stats("elevenlabs")["video"] > before["video"] or None, 10)
    _, _, at_once = jcall("POST", f"{GATEWAY}/v1/jobs/{started.get('id')}/cancel", key=KEY_ELEVEN, body={})
    billed = wait_until(lambda: (lambda j: j if close(j.get("cost_usd"), 0.20) else None)(get_job(started.get("id", "missing"), KEY_ELEVEN)), 15) or {}
    check("a cancel ends the job here at once; the provider has no cancel, so the generation is billed when it completes, and nothing is fetched",
          at_once.get("status") == "canceled" and billed.get("status") == "canceled" and close(billed.get("cost_usd"), 0.20) and billed.get("outputs") == []
          and stats("elevenlabs")["downloads"] == before["downloads"], (at_once, billed))
    # 0.02 + 0.05 + 0.06 + 0.14 + 0.05 + 0.003 + 0.003 + 0.003 + 0.20 + 0.20
    row = wait_until(lambda: (lambda r: r if close(r.get("cost_usd"), 0.729) else None)(usage_row("eleven")), 10) or usage_row("eleven")
    check("the key's ledger holds exactly what these jobs cost", close(row.get("cost_usd"), 0.729), row)

    section("ElevenLabs: privacy mode")
    status, _, job = create_job({"model": "el-video", "input": {"prompt": f"{CANARY} fail", "duration": 2, "resolution": "480p"}}, key=KEY_PRIVATE)
    job = wait_job(job.get("id", "missing"), key=KEY_PRIVATE)
    check("a private job that fails keeps the provider's reason and none of its words",
          job.get("status") == "failed" and outcome(job) == "elevenlabs_moderated" and job.get("input_erased") is True, job)
    status, _, job = create_job({"model": "el-image", "input": {"prompt": "a sealed cup"}}, key=KEY_SEALED)
    job = wait_job(job.get("id", "missing"), key=KEY_SEALED)
    out = (job.get("outputs") or [{}])[0]
    st, _, sealed = call("GET", out.get("url", GATEWAY))
    check("a key with encrypt_to gets the image as an age file",
          job.get("status") == "succeeded" and job.get("upstream") == "elevenlabs" and out.get("encryption") == "age"
          and st == 200 and sealed.startswith(b"age-encryption.org/v1\n") and b"\x89PNG" not in sealed, (job, sealed[:40]))


def media_checks(stack):
    privacy_media_checks()
    section("media job: failover, re-hosting, idempotency")
    before = {n: stats(n) for n in ("replicate", "replicate_broken")}
    body = {"model": "image", "input": {"prompt": "a lighthouse at dusk"},
            "webhook_url": MOCK["webhooks"] + "/hook/fail/2", "metadata": {"order": "A-17"}}
    status, _, job = create_job(body, idem="e2e-image-1", tag="order:A-17")
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

    def job_event():
        _, _, feed = admin("GET", "/admin/events?key=main&limit=1000")
        return next((e for e in feed.get("events", []) if e.get("id") == job_id), None)
    event = wait_until(job_event, 10) or {}
    check("the job is in the usage feed as a media event, with its tag (x-omnigate-tag) and its cost",
          event.get("kind") == "media" and event.get("tag") == "order:A-17" and event.get("key") == "main" and event.get("upstream") == "replicate"
          and event.get("cost_usd") == job.get("cost_usd") and event.get("outputs") == len(job.get("outputs", [])), event)
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

    # One error shape for the jobs API, whichever process refuses: the
    # control plane (no such job, bad model) or the data plane (bad method).
    shapes = []
    for method, path, body_ in (("GET", "/v1/jobs/job_does_not_exist", None), ("POST", "/v1/jobs", {"model": "no-such-model", "input": {}}),
                                ("DELETE", f"/v1/jobs/{job_id}", None)):
        status, headers, err = jcall(method, GATEWAY + path, key=KEY_MAIN, body=body_)
        e = err.get("error", {})
        shapes.append((status, sorted(e), e.get("code"), e.get("type"), len(headers.get("x-request-id", "")) == 32))
    check("job errors have one shape whichever plane refuses: message, type, param, code, and a request id header",
          shapes == [(404, ["code", "message", "param", "type"], "job_not_found", "invalid_request_error", True),
                     (404, ["code", "message", "param", "type"], "model_not_found", "invalid_request_error", True),
                     (405, ["code", "message", "param", "type"], "method_not_allowed", "invalid_request_error", True)], shapes)
    status, headers, _ = call("GET", plain, key=KEY_MAIN)
    check("a stored file is served as a download the browser must not sniff or run",
          status == 200 and headers.get("content-disposition", "").startswith("attachment")
          and headers.get("x-content-type-options") == "nosniff" and "sandbox" in headers.get("content-security-policy", ""),
          {k: headers.get(k) for k in ("content-disposition", "x-content-type-options", "content-security-policy")})

    status, _, refused = create_job({"model": "image", "input": {"prompt": "x"}}, key=KEY_LIMITED)
    check("a key limited to other models cannot create this job (403)",
          status == 403 and refused.get("error", {}).get("code") == "model_not_allowed", (status, refused))

    _, _, models = jcall("GET", GATEWAY + "/v1/models", key=KEY_MAIN)
    ids = {m["id"] for m in models.get("data", [])}
    check("job models are listed next to text models", {"image", "video", "tts", "chat"} <= ids, sorted(ids))

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
    status, _, refused = create_job({"model": "image", "input": {"prompt": "x"}, "webhook_url": MOCK["webhooks"] + "/hook?" + "a" * 2100})
    check("a webhook URL longer than 2,048 bytes is refused (400 invalid_webhook_url)",
          status == 400 and (refused.get("error") or {}).get("code") == "invalid_webhook_url", (status, refused))
    status, _, refused = create_job({"model": "image", "input": {"prompt": "x"}, "metadata": {"note": "m" * 17000}})
    check("metadata over 16 KiB is refused (413 payload_too_large)",
          status == 413 and (refused.get("error") or {}).get("code") == "payload_too_large", (status, refused))

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

    # A file larger than the gateway relays in one piece (64 KiB). Created
    # with another key, so that the totals checked below stay as they are.
    _, _, big = create_job({"model": "image", "input": {"prompt": "big", "mock_output_url": MOCK["replicate"] + "/files/big-1.png"}}, key=KEY_OTHER)
    big = wait_job(big.get("id", "missing"), key=KEY_OTHER)
    out = (big.get("outputs") or [{}])[0]
    status, headers, data = call("GET", out.get("url", GATEWAY + "/v1/files/missing"))
    check("a 300 kB file comes through the gateway whole, with its Content-Length and not chunked",
          status == 200 and len(data) == out.get("bytes") and len(data) > 300_000 and hashlib.sha256(data).hexdigest() == out.get("sha256")
          and headers.get("content-length") == str(len(data)) and "transfer-encoding" not in headers,
          (status, len(data), out.get("bytes"), headers.get("content-length"), headers.get("transfer-encoding"), big.get("status")))

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
    # (Under another key, so that the main key's sums stay what they were.)
    _, _, noted = create_job({"model": "image", "input": {"prompt": "listed"}, "metadata": {"note": "m" * 4000}}, key=KEY_OTHER)
    listed = next((j for j in jcall("GET", GATEWAY + "/v1/jobs?limit=5", key=KEY_OTHER)[2].get("data", []) if j.get("id") == noted.get("id")), {})
    check("a list of jobs leaves out metadata over 1 KiB and says so; the job itself shows it",
          listed.get("metadata") is None and listed.get("metadata_omitted") is True
          and get_job(noted.get("id", "missing"), KEY_OTHER).get("metadata") == {"note": "m" * 4000}, listed)
    wait_job(noted.get("id", "missing"), key=KEY_OTHER)
    # A provider that answers a request with the result cannot be told to stop: the
    # call completes and is paid for, whatever the client does in the meantime.
    spent = usage_row("other").get("cost_usd") or 0.0
    files_before = stats("openai_images").get("downloads", 0)
    _, _, costly = create_job({"model": "image-sync", "input": {"prompt": "mock-slow cube"}}, key=KEY_OTHER)
    wait_job(costly.get("id", "missing"), 10, until=("running",) + TERMINAL, key=KEY_OTHER)
    time.sleep(0.5)  # the provider call is in flight now
    _, _, at_once = jcall("POST", f"{GATEWAY}/v1/jobs/{costly.get('id')}/cancel", key=KEY_OTHER, body={})
    check("a job canceled while its provider is working is canceled at once ...", at_once.get("status") == "canceled", at_once)
    billed = wait_until(lambda: (lambda j: j if close(j.get("cost_usd"), 0.05) else None)(get_job(costly.get("id", "missing"), KEY_OTHER)), 10) or {}
    check("... and billed when the provider completes the call all the same (canceling is not free media)",
          billed.get("status") == "canceled" and close(billed.get("cost_usd"), 0.05) and billed.get("outputs") == [], billed or get_job(costly.get("id", "missing"), KEY_OTHER))
    row = wait_until(lambda: (lambda r: r if close((r.get("cost_usd") or 0.0) - spent, 0.05) else None)(usage_row("other")), 10) or usage_row("other")
    check("... the key's spend in the ledger went up by the job's price, and nothing was fetched or stored",
          close((row.get("cost_usd") or 0.0) - spent, 0.05) and stats("openai_images").get("downloads", 0) == files_before, (row, spent))

    sume_checks()
    elevenlabs_checks()

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
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", choices=["text", "media"], help="run one half only")
    ap.add_argument("--keep", action="store_true", help="keep the temp dir (logs, ledger, outputs)")
    args = ap.parse_args()
    run_text = args.only in (None, "text")
    run_media = args.only in (None, "media")

    global WORK
    work = WORK = tempfile.mkdtemp(prefix="omnigate-e2e-")
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
        key_checks()
        if run_text:
            shared_limit_checks(stack)
            build_around_checks(work)
            credit_checks()
            payment_checks()
            privacy_text_checks()
            attestation_checks(stack)
            receipt_tool_checks(work)
        if run_media:
            media_checks(stack)
        if run_text:
            text_checks(stack)
    finally:
        stack.stop_all()

    # Everything is stopped and flushed: look through what was left behind.
    section("privacy mode: nothing of a private request is left on disk")
    left = leftovers(work)
    check("no log, spool, ledger, job store or cache file holds the private prompt or metadata", left == [], left)

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
