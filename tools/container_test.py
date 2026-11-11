"""Build the container images and test them behind the TLS proxy.

    python3 tools/container_test.py            # build, run, check, clean up
    python3 tools/container_test.py --no-build # reuse images built earlier
    python3 tools/container_test.py --keep     # leave the containers running
    python3 tools/container_test.py --compose  # start it with compose.yaml instead

Needs a Linux Docker daemon (Docker Desktop, or Docker inside WSL) and
Python 3.9+. By default it uses plain `docker` commands, so the Compose plugin
is not required. With --compose it runs the repository's compose.yaml (plus a
small override that adds the mock providers, moves the published port and
points at a throwaway config), which is how the file itself gets tested.
Either way it starts, on a private Docker network:

    mocks      tools/mock_upstream.py + tools/mock_media.py (fake providers)
    control    the control-plane image
    dataplane  the data-plane image
    proxy      Caddy with deploy/Caddyfile, published on 127.0.0.1:18443
    proxy-locked  the same, with OMNIGATE_ADMIN_ALLOW set to a range nobody
               is in, published on 127.0.0.1:18444 (tests the allow-list)

and talks to them only through the proxy, over TLS, verifying certificates
against the proxy's own CA. Everything it creates is named omnigate-test-*
and removed at the end.
"""

import argparse
import hashlib
import http.client
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = "omnigate-test"                      # prefix of everything we create
NET = P
PORT = 18443
LOCKED_PORT = 18444                      # the proxy whose admin allow-list excludes us
SERVICES = ("mocks", "control", "dataplane", "proxy", "proxy-locked")
API_HOST, ADMIN_HOST = "localhost", "admin.localhost"
INTERNAL, ADMIN = "container-internal-token-0123456789", "container-admin-token-0123456789"
KEY, OTHER, PRIVATE = "og-container-main", "og-container-other", "og-container-private"
HOOK_SECRET = "container-webhook-secret"
IMAGES = {"dataplane": f"{P}-dataplane", "control": f"{P}-control"}
COMPOSE = False                          # set by --compose
NO_BUILD = False                         # set by --no-build
COMPOSE_FILES = []                       # -f arguments, once the override exists


def cname(service):
    """Container name of a service: Compose appends an instance number."""
    return f"{P}-{service}-1" if COMPOSE else f"{P}-{service}"


def compose(*args, check_rc=True):
    return docker("compose", "-p", P, "--project-directory", ROOT, *COMPOSE_FILES, *args, check_rc=check_rc)

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"   [{detail}]" if detail and not ok else ""), flush=True)
    return bool(ok)


def section(title):
    print(f"\n== {title}", flush=True)


def docker(*args, check_rc=True, quiet=True):
    r = subprocess.run(["docker", *args], capture_output=True, text=True)
    if check_rc and r.returncode != 0:
        raise SystemExit(f"docker {' '.join(args[:3])}... failed:\n{r.stderr.strip()[-1500:]}")
    return r.stdout.strip() if quiet else r


def wait_until(fn, timeout, interval=0.3):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        try:
            last = fn()
        except Exception as e:  # noqa: BLE001 - the stack may not be up yet
            last = None
            err = e  # noqa: F841
        if last:
            return last
        time.sleep(interval)
    return last


# --------------------------------------------------------------------------
# https client: always connects to 127.0.0.1:PORT, with the given host as SNI
# --------------------------------------------------------------------------

CTX = None


class Conn(http.client.HTTPSConnection):
    def connect(self):
        sock = socket.create_connection(("127.0.0.1", PORT), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def req(method, host, path, key=None, body=None, headers=None, form=None, timeout=30):
    h = dict(headers or {})
    if key:
        h["authorization"] = f"Bearer {key}"
    data = None
    if body is not None:
        data = json.dumps(body)
        h["content-type"] = "application/json"
    if form is not None:
        data = "&".join(f"{k}={v}" for k, v in form.items())
        h["content-type"] = "application/x-www-form-urlencoded"
    c = Conn(host, PORT, context=CTX, timeout=timeout)
    c.request(method, path, body=data, headers=h)
    r = c.getresponse()
    raw = r.read()
    out = (r.status, {k.lower(): v for k, v in r.getheaders()}, raw)
    c.close()
    return out


def jreq(*a, **k):
    s, h, raw = req(*a, **k)
    try:
        return s, h, json.loads(raw)
    except ValueError:
        return s, h, {"_raw": raw[:200].decode("utf-8", "replace")}


def stream(path, body, key=None):
    """POST to the gateway; return (status, joined text, seconds between first and last data line)."""
    c = Conn(API_HOST, PORT, context=CTX, timeout=30)
    c.request("POST", path, body=json.dumps(body), headers={"content-type": "application/json", "authorization": f"Bearer {key or KEY}"})
    r = c.getresponse()
    text, first, last = [], None, None
    while True:
        line = r.readline()
        if not line:
            break
        line = line.decode().strip()
        if not line.startswith("data:") or line == "data: [DONE]":
            continue
        now = time.perf_counter()
        first, last = first or now, now
        for choice in json.loads(line[5:]).get("choices", []):
            text.append(choice.get("delta", {}).get("content") or "")
    c.close()
    return r.status, "".join(text), (last - first) if first else 0.0


def raw(host, payload, port=None, verify=True, timeout=8):
    """Send bytes exactly as given over TLS (nothing normalises them) and
    return (status, response bytes). Status 0: the peer closed or stayed
    silent without answering."""
    ctx = CTX
    if not verify:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    data = b""
    try:
        sock = socket.create_connection(("127.0.0.1", port or PORT), timeout)
    except OSError:
        return 0, b""
    try:
        tls = ctx.wrap_socket(sock, server_hostname=host)
        tls.sendall(payload)
        # The head is all we need; do not wait for a body or for the close.
        while b"\r\n\r\n" not in data:
            chunk = tls.recv(65536)
            if not chunk:
                break
            data += chunk
    except (OSError, ssl.SSLError):
        pass
    finally:
        sock.close()
    parts = data.split(b" ", 2)
    status = int(parts[1]) if data.startswith(b"HTTP/") and len(parts) > 1 and parts[1].isdigit() else 0
    return status, data


def get_raw(host, path, headers=(), **kw):
    """A GET whose path reaches the proxy byte for byte."""
    head = [f"GET {path} HTTP/1.1", f"Host: {host}:{kw.get('port') or PORT}", "Connection: close", *headers]
    return raw(host, ("\r\n".join(head) + "\r\n\r\n").encode("latin-1"), **kw)


def alive(service):
    """Is the container running, and has it never been restarted or killed?"""
    state = docker("inspect", cname(service), "--format", "{{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}}", check_rc=False)
    return state == "true 0 false", state


def usage(name):
    _, _, body = jreq("GET", ADMIN_HOST, "/admin/usage", key=ADMIN)
    return next((r for r in body.get("keys", []) if r.get("name") == name), {})


# --------------------------------------------------------------------------
# stack
# --------------------------------------------------------------------------

def config():
    price = {"price_in_per_mtok": 100.0, "price_out_per_mtok": 300.0}
    up = lambda name, kind, port: {"name": name, "kind": kind, "base_url": f"http://mocks:{port}", "api_key_env": "MOCK_API_KEY"}
    return {
        "keys": [{"name": "main", "key": KEY, "webhook_secret": HOOK_SECRET}, {"name": "other", "key": OTHER},
                 # Privacy mode on: what the optimized build in the image does with it.
                 {"name": "private", "key": PRIVATE, "privacy": True}],
        "upstreams": [up("mock-flaky", "openai", 9001), up("mock-ok", "openai", 9002), up("mock-anthropic", "anthropic", 9003)],
        "routes": [
            {"model": "chat", "targets": [dict(upstream="mock-flaky", model="f", **price), dict(upstream="mock-ok", model="ok-1", **price)]},
            {"model": "claude", "targets": [dict(upstream="mock-anthropic", model="mock-claude", **price)]},
            # Answers with what it was sent (tools/mock_upstream.py).
            {"model": "echo", "targets": [dict(upstream="mock-ok", model="echo-1", **price)]},
        ],
        "media": {
            # The address clients use, i.e. the proxy's.
            "public_base_url": f"https://{API_HOST}:{PORT}",
            "poll_interval_ms": 200,
            "upstreams": [up("replicate-broken", "replicate", 9102), up("replicate", "replicate", 9101)],
            "routes": [{"model": "image", "targets": [
                {"upstream": "replicate-broken", "model": "mock/broken-image", "price": {"per_output_usd": 0.004}},
                {"upstream": "replicate", "model": "mock/image", "price": {"per_output_usd": 0.003}}]}],
            "storage": {"kind": "local"},
            "webhooks": {"allow_private": True, "retry_schedule_ms": [300, 600], "max_attempts": 4},
        },
    }


def names():
    return [cname(n) for n in SERVICES]


def cleanup():
    if COMPOSE and COMPOSE_FILES:
        compose("down", "-v", "--remove-orphans", check_rc=False)
    # Leftovers of either mode, e.g. from an interrupted earlier run.
    services = SERVICES
    docker("rm", "-f", *[f"{P}-{n}" for n in services], *[f"{P}-{n}-1" for n in services], check_rc=False)
    docker("volume", "rm", "-f", *[f"{P}{sep}{v}" for sep in ("-", "_") for v in ("control-data", "dataplane-data", "caddy-data", "caddy-config")], check_rc=False)
    docker("network", "rm", NET, f"{P}_default", check_rc=False)


def run(name, image, *args, cmd=()):
    docker("run", "-d", "--name", f"{P}-{name}", "--network", NET, "--network-alias", name, *args, image, *cmd)


def start(work):
    cfg_path = os.path.join(work, "omnigate.json")
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(config(), f, indent=2)
    os.chmod(cfg_path, 0o644)

    if COMPOSE:
        return start_compose(work, cfg_path)

    docker("network", "create", NET)
    run("mocks", "python:3.12-alpine", "-v", f"{ROOT}/tools:/tools:ro",
        "-e", "MOCK_BIND=0.0.0.0", "-e", "MOCK_PUBLIC_HOST=mocks", "-e", f"MOCK_WEBHOOK_SECRET={HOOK_SECRET}", "-e", "PYTHONUNBUFFERED=1",
        cmd=("sh", "-c", "python /tools/mock_upstream.py & exec python /tools/mock_media.py"))
    run("control", IMAGES["control"], "-v", f"{cfg_path}:/config/omnigate.json:ro", "-v", f"{P}-control-data:/data",
        "-e", f"OMNIGATE_INTERNAL_TOKEN={INTERNAL}", "-e", f"OMNIGATE_ADMIN_TOKEN={ADMIN}", "-e", "MOCK_API_KEY=mock-secret",
        "-e", "OMNIGATE_TRUST_FORWARDED=1")
    run("dataplane", IMAGES["dataplane"], "-v", f"{P}-dataplane-data:/data",
        "-e", f"OMNIGATE_INTERNAL_TOKEN={INTERNAL}", "-e", "MOCK_API_KEY=mock-secret",
        "-e", "OMNIGATE_POLL_MS=300", "-e", "OMNIGATE_FLUSH_MS=200")
    run("proxy", "caddy:2.11-alpine", "-p", f"127.0.0.1:{PORT}:443",
        "-v", f"{ROOT}/deploy/Caddyfile:/etc/caddy/Caddyfile:ro", "-v", f"{P}-caddy-data:/data")
    run("proxy-locked", "caddy:2.11-alpine", "-p", f"127.0.0.1:{LOCKED_PORT}:443", "-e", f"OMNIGATE_ADMIN_ALLOW={LOCKED_ALLOW}",
        "-v", f"{ROOT}/deploy/Caddyfile:/etc/caddy/Caddyfile:ro")


# Documentation ranges (RFC 5737, RFC 3849): no client is ever in them.
LOCKED_ALLOW = "192.0.2.0/24 2001:db8::/32"


def start_compose(work, cfg_path):
    """Bring up the repository's compose.yaml, changed only where a test must differ."""
    # Two files, as in a real deployment: what one container gets, the other does not.
    control_env, dataplane_env = os.path.join(work, "control.env"), os.path.join(work, "dataplane.env")
    with open(control_env, "w", encoding="utf-8") as f:
        f.write(f"OMNIGATE_INTERNAL_TOKEN={INTERNAL}\nOMNIGATE_ADMIN_TOKEN={ADMIN}\nMOCK_API_KEY=mock-secret\n")
    with open(dataplane_env, "w", encoding="utf-8") as f:
        f.write(f"OMNIGATE_INTERNAL_TOKEN={INTERNAL}\nMOCK_API_KEY=mock-secret\n")
    override = os.path.join(work, "compose.test.yaml")
    with open(override, "w", encoding="utf-8") as f:
        f.write(f"""\
services:
  control:
    env_file: !override ["{control_env}"]
    volumes: !override
      - "{cfg_path}:/config/omnigate.json:ro"
      - control-data:/data
  dataplane:
    env_file: !override ["{dataplane_env}"]
    environment:
      OMNIGATE_POLL_MS: "300"
      OMNIGATE_FLUSH_MS: "200"
  proxy:
    ports: !override ["127.0.0.1:{PORT}:443"]
  proxy-locked:
    image: caddy:2.11-alpine
    ports: ["127.0.0.1:{LOCKED_PORT}:443"]
    environment:
      OMNIGATE_ADMIN_ALLOW: "{LOCKED_ALLOW}"
    volumes: ["{ROOT}/deploy/Caddyfile:/etc/caddy/Caddyfile:ro"]
  mocks:
    image: python:3.12-alpine
    volumes: ["{ROOT}/tools:/tools:ro"]
    environment:
      MOCK_BIND: 0.0.0.0
      MOCK_PUBLIC_HOST: mocks
      MOCK_WEBHOOK_SECRET: {HOOK_SECRET}
      PYTHONUNBUFFERED: "1"
    command: ["sh", "-c", "python /tools/mock_upstream.py & exec python /tools/mock_media.py"]
""")
    COMPOSE_FILES[:] = ["-f", os.path.join(ROOT, "compose.yaml"), "-f", override]
    # Compose names its images <project>-<service>, the same names the plain
    # mode uses, so --no-build reuses whatever either mode built earlier.
    print("docker compose up" + ("" if NO_BUILD else " --build") + " ...", flush=True)
    compose("up", "-d", "--no-build" if NO_BUILD else "--build")


def load_ca(work):
    """Trust exactly the proxy's local CA, nothing else."""
    global CTX
    ca = os.path.join(work, "caddy-root.crt")
    ok = wait_until(lambda: docker("cp", f"{cname('proxy')}:/data/caddy/pki/authorities/local/root.crt", ca, check_rc=False, quiet=False).returncode == 0, 30)
    if not ok:
        raise SystemExit("the proxy never created its local CA:\n" + docker("logs", "--tail", "20", cname("proxy"), check_rc=False))
    CTX = ssl.create_default_context(cafile=ca)


def logs(name, lines=25):
    r = docker("logs", "--tail", str(lines), cname(name), check_rc=False, quiet=False)
    return (r.stdout + r.stderr).strip()


# --------------------------------------------------------------------------
# checks
# --------------------------------------------------------------------------

CHAT = {"messages": [{"role": "user", "content": "hi"}]}
MOCK_TEXT = "Hello from the mock upstream."


def chat(model="chat", key=KEY, **extra):
    return jreq("POST", API_HOST, "/v1/chat/completions", key=key, body=dict(CHAT, model=model, **extra))


def checks():
    section("images")
    for name, image in IMAGES.items():
        size = int(docker("image", "inspect", image, "--format", "{{.Size}}")) / 1e6
        user = docker("image", "inspect", image, "--format", "{{.Config.User}}")
        print(f"      {name}: {size:.1f} MB compressed, runs as user {user}", flush=True)
        check(f"{name} image does not run as root", user.startswith("10001"), user)

    section("gateway over TLS")
    s, _, raw = req("GET", API_HOST, "/healthz")
    check("TLS handshake verifies against the proxy's CA and health answers", s == 200 and raw.strip() == b"ok", s)
    s, h, b = chat()
    check("chat with failover works through the proxy",
          s == 200 and h.get("x-omnigate-upstream") == "mock-ok" and b["choices"][0]["message"]["content"] == MOCK_TEXT, (s, b))
    s, text, spread = stream("/v1/chat/completions", dict(CHAT, model="chat", stream=True))
    check("streaming stays incremental through the proxy", s == 200 and text == MOCK_TEXT and spread > 0.2, (s, text, f"{spread:.3f}s"))
    s, h, b = chat("claude")
    check("protocol translation works", s == 200 and h.get("x-omnigate-upstream") == "mock-anthropic" and b.get("object") == "chat.completion", (s, b))
    s, _, _ = chat(key="og-wrong")
    check("unknown key is refused", s == 401, s)

    section("privacy mode in the built images")
    secret_text = "mail bob.stone@example.com from 10.20.30.40 with key sk-proj-Abc123Def456Ghi789Jkl012"
    said = "You said: " + secret_text
    s, h, b = jreq("POST", API_HOST, "/v1/chat/completions", key=PRIVATE, body={"model": "echo", "messages": [{"role": "user", "content": secret_text}]})
    check("a private key's request comes back with its values, and the response says what applied",
          s == 200 and b["choices"][0]["message"]["content"] == said and h.get("x-omnigate-privacy") == "no-store, redact, unlink", (s, h.get("x-omnigate-privacy"), b))
    # Asked from inside the mocks' container: what the provider was sent.
    seen = docker("exec", cname("mocks"), "python", "-c",
                  "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:9002/__last?model=echo-1').read().decode())", check_rc=False)
    check("the provider received placeholders, none of the values",
          "[EMAIL_1]" in seen and "[IP_1]" in seen and "[SECRET_1]" in seen and "bob.stone" not in seen and "10.20.30.40" not in seen and "sk-proj" not in seen, seen[:300])
    s, text, _ = stream("/v1/chat/completions", {"model": "echo", "stream": True, "messages": [{"role": "user", "content": secret_text}]}, key=PRIVATE)
    check("streamed in three-character pieces through the proxy, every placeholder is put back", s == 200 and text == said, (s, text))
    s, _, _ = req("GET", API_HOST, "/admin/usage", key=ADMIN)
    check("the gateway host does not serve the admin API", s in (401, 404), s)
    calls = 3

    section("media job")
    s, _, job = jreq("POST", API_HOST, "/v1/jobs", key=KEY, body={"model": "image", "input": {"prompt": "x"},
                                                                 "webhook_url": "http://mocks:9107/hook/fail/1"})
    jid = job.get("id", "missing")
    done = wait_until(lambda: (lambda j: j if j.get("status") in ("succeeded", "failed") else None)(jreq("GET", API_HOST, f"/v1/jobs/{jid}", key=KEY)[2]), 30) or {}
    out = (done.get("outputs") or [{}])[0]
    check("job fails over between providers and succeeds", s == 202 and done.get("status") == "succeeded" and done.get("upstream") == "replicate", (s, done))
    url = out.get("url", "")
    check("output URL is an https URL on the public host", url.startswith(f"https://{API_HOST}:{PORT}/v1/files/"), url)
    s, h, data = req("GET", API_HOST, url.split(f":{PORT}", 1)[-1] if url else "/none")
    check("signed URL downloads the re-hosted file over TLS",
          s == 200 and hashlib.sha256(data).hexdigest() == out.get("sha256"), (s, len(data)))
    # The file name shows the header comes from the gateway itself (it relays
    # what the control plane set), not from a default added by the proxy.
    check("the stored file is served as a download in a sandbox, never as a page on this origin",
          h.get("content-disposition", "").startswith("attachment; filename=") and h.get("x-content-type-options") == "nosniff"
          and "sandbox" in h.get("content-security-policy", ""), h)
    hook = wait_until(lambda: (lambda w: w if w.get("status") == "delivered" else None)(
        jreq("GET", API_HOST, f"/v1/jobs/{jid}", key=KEY)[2].get("webhook", {})), 20) or {}
    check("webhook is retried and delivered", hook.get("status") == "delivered" and hook.get("attempts") == 2, hook)

    section("dashboard over TLS")
    s, h, _ = req("GET", ADMIN_HOST, "/")
    check("anonymous browser is redirected to the login page", s == 302 and h.get("location") == "/login", (s, h))
    s, h, _ = req("POST", ADMIN_HOST, "/login", form={"password": ADMIN})
    cookie = h.get("set-cookie", "")
    check("login sets a session cookie marked Secure", s == 302 and "Secure" in cookie.title() and "HttpOnly" in cookie, (s, cookie))
    s, _, page = req("GET", ADMIN_HOST, "/", headers={"cookie": cookie.split(";")[0]})
    check("the session opens the dashboard", s == 200 and b"Sign out" in page, s)
    s, _, _ = req("GET", ADMIN_HOST, "/internal/config", headers={"x-omnigate-internal": INTERNAL})
    check("the internal API is not reachable through the proxy, even with its token", s == 404, s)
    row = wait_until(lambda: (lambda r: r if r.get("requests", 0) - r.get("jobs", 0) == calls else None)(usage("main")), 10) or usage("main")
    check("usage reached the ledger", row.get("requests", 0) - row.get("jobs", 0) == calls and row.get("jobs") == 1 and row.get("cost_usd", 0) > 0, row)

    section("restarts and persistence")
    docker("stop", cname("control"))
    codes = [chat()[0] for _ in range(2)]
    calls += 2
    check("the gateway keeps serving with the control plane stopped", codes == [200, 200], codes)
    docker("restart", cname("dataplane"))
    ok = wait_until(lambda: chat()[0] == 200, 20)
    calls += 1
    check("a restarted gateway container serves from its cached config (volume)", bool(ok), logs("dataplane", 8))
    docker("start", cname("control"))
    row = wait_until(lambda: (lambda r: r if r.get("requests", 0) - r.get("jobs", 0) == calls else None)(usage("main")), 40, 0.5) or {}
    check("ledger survived the control-plane restart and the outage calls were billed once",
          row.get("requests", 0) - row.get("jobs", 0) == calls and row.get("jobs") == 1, (row, calls))
    s, _, again = jreq("GET", API_HOST, f"/v1/jobs/{jid}", key=KEY)
    check("the job and its file survived too", s == 200 and again.get("status") == "succeeded"
          and req("GET", API_HOST, again["outputs"][0]["url"].split(f":{PORT}", 1)[-1])[0] == 200, (s, again.get("status")))
    health = wait_until(lambda: docker("inspect", cname("control"), "--format", "{{.State.Health.Status}}") == "healthy", 40, 1.0)
    check("the control-plane container reports healthy", bool(health), docker("inspect", cname("control"), "--format", "{{.State.Health.Status}}"))

    hardening()

    # `docker stop` sends SIGTERM to PID 1: the gateway must drain and exit by itself.
    t0 = time.time()
    docker("stop", "-t", "25", cname("dataplane"))
    took = time.time() - t0
    code = docker("inspect", cname("dataplane"), "--format", "{{.State.ExitCode}}")
    check("the gateway container shuts down cleanly on SIGTERM (exit 0, no kill)", code == "0" and took < 20, (code, f"{took:.1f}s"))


def hardening():
    """What the security review asked to see hold in a real deployment: the
    requests go through the real proxy, byte for byte as written here."""
    section("guarded paths, spelled oddly")
    token = [f"Authorization: Bearer {ADMIN}"]
    s, _ = get_raw(ADMIN_HOST, "/admin/keys", token)
    check("the plain admin path works with the admin token (the control for the checks below)", s == 200, s)
    odd = ["/%61dmin/keys", "/admin%2Fkeys", "/admin/%6beys", "/%2e/admin/keys", "/admin/./keys", "//admin/keys", "/admin//keys",
           "/x/../admin/keys", "/admin;x/keys", "/admin/keys%00", "/%6detrics", "//metrics"]
    got = {p: get_raw(ADMIN_HOST, p)[0] for p in odd}
    check("no spelling of an admin path answers without credentials", all(400 <= s < 500 for s in got.values()), got)
    s, data = get_raw(ADMIN_HOST, "/%61dmin/keys", token)
    check("a percent-encoded admin path is refused outright, even with the admin token", s == 400 and b"og-container" not in data, s)

    internal = [f"x-omnigate-internal: {INTERNAL}"]
    odd = ["/internal/config", "/internal", "/%69nternal/config", "/internal%2Fconfig", "/%2finternal/config", "//internal/config",
           "/./internal/config", "/internal/./config", "/x/../internal/config", "/INTERNAL/config", "/internal;/config", "/internal/config/"]
    got = {p: get_raw(ADMIN_HOST, p, internal) for p in odd}
    leaks = {p: s for p, (s, data) in got.items() if not 400 <= s < 500 or b'"upstreams"' in data}
    check("no spelling of /internal/config gets through the proxy, even with the internal token", not leaks, leaks)
    s, _, _ = req("POST", API_HOST, "/v1/jobs/", key=OTHER, body={"model": "image", "input": {"prompt": "x"}})
    check("a job path with a trailing slash does not create a job", 400 <= s < 500, s)

    section("admin allow-list")
    up = wait_until(lambda: get_raw(API_HOST, "/healthz", port=LOCKED_PORT, verify=False)[0] == 200, 40, 0.5)
    check("a proxy with an allow-list still serves the gateway to everyone", bool(up), logs("proxy-locked", 8))
    got = {p: get_raw(ADMIN_HOST, p, token, port=LOCKED_PORT, verify=False)[0] for p in ("/", "/login", "/admin/keys", "/healthz")}
    check("outside the allow-list the admin host answers 403 to everything, token or not", set(got.values()) == {403}, got)

    section("secrets and shutdown, per container")
    env = json.loads(docker("inspect", cname("dataplane"), "--format", "{{json .Config.Env}}"))
    held = {e.split("=", 1)[0] for e in env}
    check("the gateway container holds the internal token and no admin token",
          "OMNIGATE_INTERNAL_TOKEN" in held and "OMNIGATE_ADMIN_TOKEN" not in held and ADMIN not in " ".join(env), sorted(held))
    if COMPOSE:
        grace = {s: docker("inspect", cname(s), "--format", "{{.Config.StopTimeout}}") for s in ("control", "dataplane")}
        check("compose.yaml gives both services time to stop cleanly", grace == {"control": "30", "dataplane": "20"}, grace)
        limit = {s: int(docker("inspect", cname(s), "--format", "{{.HostConfig.Memory}}") or 0) for s in ("control", "dataplane")}
        check("compose.yaml gives both services a memory limit (1 GiB unless .env says otherwise)",
              limit == {"control": 1 << 30, "dataplane": 1 << 30}, limit)

    section("malformed requests over raw TLS")
    host, auth = f"Host: {API_HOST}:{PORT}", f"Authorization: Bearer {OTHER}"
    post = f"POST /v1/chat/completions HTTP/1.1\r\n{host}\r\n{auth}\r\nContent-Type: application/json\r\n"
    cases = {
        "bodiless POST": post + "Connection: close\r\n\r\n",
        "bodiless POST to /v1/jobs": post.replace("/v1/chat/completions", "/v1/jobs") + "Connection: close\r\n\r\n",
        "header line without a colon": f"GET /healthz HTTP/1.1\r\n{host}\r\nthis line has no colon\r\n\r\n",
        "no request line": "\r\n\r\nGARBAGE\r\n\r\n",
        "unknown method and version": f"FROB /healthz HTTP/9.9\r\n{host}\r\n\r\n",
        "two content lengths": post + "Content-Length: 2\r\nContent-Length: 7\r\n\r\n{}",
        "length and chunked together": post + "Content-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        "broken chunk size": post + "Transfer-Encoding: chunked\r\n\r\nZZZ\r\n{}\r\n",
        "body shorter than declared": post + 'Content-Length: 5000\r\n\r\n{"model":',
        "64 kB header": f"GET /healthz HTTP/1.1\r\n{host}\r\nX-Pad: {'a' * 65536}\r\nConnection: close\r\n\r\n",
        "600 headers": f"GET /healthz HTTP/1.1\r\n{host}\r\n" + "".join(f"X-N-{i}: v\r\n" for i in range(600)) + "Connection: close\r\n\r\n",
        "bare line feeds": f"GET /healthz HTTP/1.1\n{host}\n\n",
    }
    got = {name: raw(API_HOST, payload.encode("latin-1"), timeout=3)[0] for name, payload in cases.items()}
    print("      answers: " + ", ".join(f"{name} -> {s or 'closed'}" for name, s in got.items()), flush=True)
    check("a bodiless POST gets a client-error answer, not a crash or a hang", 400 <= got["bodiless POST"] < 500, got["bodiless POST"])
    # 502 (a body the proxy could not read) and 505 are the proxy's own answers.
    # Bare line feeds are tolerated by the proxy, which forwards a clean request.
    served = {n: s for n, s in got.items() if n != "bare line feeds" and (200 <= s < 400 or s in (500, 503, 504))}
    check("malformed requests are refused or dropped, never served and never an internal error", not served, got)
    s, _, _ = req("GET", API_HOST, "/healthz")
    ok, state = alive("dataplane")
    check("the gateway is still up after all of it (same process, never restarted)", s == 200 and ok and chat(key=OTHER)[0] == 200, (s, state))

    host = f"Host: {ADMIN_HOST}:{PORT}"
    login = f"POST /login HTTP/1.1\r\n{host}\r\nContent-Type: application/x-www-form-urlencoded\r\n"
    cases = {
        "bodiless login": login + "Connection: close\r\n\r\n",
        # Sent in full: the proxy cannot relay an answer while it waits for a
        # body the client declared and never sends.
        "8 kB login body": login + "Content-Length: 8192\r\nConnection: close\r\n\r\n" + "password=" + "a" * 8183,
        "login with a broken chunk": login + "Transfer-Encoding: chunked\r\n\r\nZZZ\r\nx\r\n",
        "bodiless admin POST": f"POST /admin/keys HTTP/1.1\r\n{host}\r\nAuthorization: Bearer {ADMIN}\r\nConnection: close\r\n\r\n",
        "64 kB header": f"GET /healthz HTTP/1.1\r\n{host}\r\nX-Pad: {'a' * 65536}\r\nConnection: close\r\n\r\n",
    }
    got = {name: raw(ADMIN_HOST, payload.encode("latin-1"), timeout=3)[0] for name, payload in cases.items()}
    print("      answers: " + ", ".join(f"{name} -> {s or 'closed'}" for name, s in got.items()), flush=True)
    check("an oversized login body is refused, not parsed", got["8 kB login body"] == 413, got)
    s, _, _ = req("GET", ADMIN_HOST, "/healthz")
    ok, state = alive("control")
    check("the control plane is still up after malformed requests", s == 200 and ok, (s, state, got))

    forwarded_for()


def forwarded_for():
    """The control plane counts failed logins per address, and reads the
    address from X-Forwarded-For because the proxy is the only way in. So the
    proxy must write that header itself, whatever the client put there."""
    section("X-Forwarded-For through the proxy")
    host = f"Host: {ADMIN_HOST}:{PORT}"
    body = "password=definitely-not-the-token"

    def login(forwarded):
        head = f"POST /login HTTP/1.1\r\n{host}\r\nContent-Type: application/x-www-form-urlencoded\r\n" \
               f"X-Forwarded-For: {forwarded}\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n{body}"
        return raw(ADMIN_HOST, head.encode("latin-1"), timeout=5)[0]

    # A different claimed address on every attempt. If the claim chose the
    # bucket, each attempt would be the first from its address and none would
    # ever be throttled; the limit is five failures per address a minute.
    codes = [login(f"203.0.113.{i}") for i in range(1, 9)]
    check("a client cannot pick the address its failed logins are counted under",
          set(codes) <= {401, 429} and codes[-1] == 429 and codes.count(401) <= 5, codes)

    # Bytes that are not text, a line break smuggled in as an obsolete header
    # fold, and a long value: none of it may reach the audit log as written,
    # and none of it may stop the process that writes the log.
    codes = [login(v) for v in ("203.0.113.77, \xff\xfe", "\xff", "203.0.113.78,\r\n forged", "9" * 3000)]
    ok, state = alive("control")
    s, _, audit = jreq("GET", ADMIN_HOST, "/admin/audit?limit=200", key=ADMIN)
    logins = [e for e in audit.get("entries", []) if e.get("action") == "login"]
    claimed = [e.get("forwarded_for") for e in logins if "203.0.113." in str(e.get("forwarded_for")) or "forged" in str(e.get("forwarded_for"))]
    plain = all(str(e.get("forwarded_for", "0")).replace(".", "").replace(":", "").isalnum() for e in logins)
    check("odd X-Forwarded-For values are answered, not fatal: the control plane is the same process and still logs",
          all(c in (400, 401, 429) for c in codes) and ok and s == 200 and len(logins) >= 2, (codes, state, s, len(logins)))
    check("the audit log holds the address the proxy saw, never the one the client claimed",
          not claimed and plain and any(e.get("forwarded_for") for e in logins), (claimed, [e.get("forwarded_for") for e in logins][:5]))
    summary = [e for e in logins if e.get("outcome") in ("denied", "throttled")]
    check("a dozen failed logins from one address are a few audit lines, not a dozen", 1 <= len(summary) <= 4, len(summary))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--compose", action="store_true", help="start the stack with compose.yaml (needs the Compose plugin)")
    args = ap.parse_args()

    global COMPOSE, NO_BUILD
    COMPOSE, NO_BUILD = args.compose, args.no_build
    if COMPOSE and docker("compose", "version", check_rc=False, quiet=False).returncode != 0:
        raise SystemExit("--compose needs the Docker Compose plugin (`docker compose version` failed)")

    if not args.no_build and not COMPOSE:
        for name, image in IMAGES.items():
            print(f"building {image} ...", flush=True)
            r = subprocess.run(["docker", "build", "-q", "-t", image, os.path.join(ROOT, name)], capture_output=True, text=True)
            if r.returncode != 0:
                raise SystemExit(f"build of {name} failed:\n{(r.stdout + r.stderr)[-3000:]}")

    cleanup()
    work = tempfile.mkdtemp(prefix="omnigate-container-")
    os.chmod(work, 0o755)
    started = time.time()
    try:
        start(work)
        load_ca(work)
        if not wait_until(lambda: req("GET", API_HOST, "/v1/models", key=KEY)[0] == 200, 60, 0.5):
            for n in ("control", "dataplane", "proxy", "mocks"):
                print(f"--- {n} ---\n{logs(n)}")
            raise SystemExit("the stack did not come up")
        checks()
    finally:
        failed = [n for n, ok in results if not ok]
        if failed:
            for n in ("control", "dataplane"):
                print(f"--- last log lines of {n} ---\n{logs(n, 15)}")
        if args.keep:
            print(f"\nleft running: {', '.join(names())}  (https://localhost:{PORT})")
        else:
            cleanup()

    failed = [n for n, ok in results if not ok]
    mode = "compose.yaml" if COMPOSE else "plain docker"
    print(f"\n{len(results) - len(failed)}/{len(results)} container checks passed in {time.time() - started:.0f}s ({mode})")
    for n in failed:
        print("  failed:", n)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
