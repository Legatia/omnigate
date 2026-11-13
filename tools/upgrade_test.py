"""Upgrade test: state written by an older commit, read by the current build.

    python tools/upgrade_test.py 6d5ed6e                # stop the old build cleanly, then upgrade
    python tools/upgrade_test.py 10bc009 --variant hard # kill the old build mid-job, then upgrade
    python tools/upgrade_test.py 6d5ed6e --variant both --mixed

What it does, per variant, in a fresh temporary directory:

 1. Checks the old commit out into a temporary git worktree and builds both
    of its programs there (the control plane with this checkout's
    dependencies; `mix.lock` must be the same).
 2. Runs the OLD build against the mock providers and makes it write
    realistic state: managed keys (one rotated twice, one disabled, one
    with a monthly budget), text usage on file and managed keys in both
    protocols, a ledger cut into several segments with a snapshot, media
    jobs that succeeded, failed and were cancelled, one whose webhook cannot
    be delivered yet, one still running at the provider, admin sign-ins in
    the audit log, and usage that the data plane had to spool because the
    control plane was already gone.
 3. Stops the old build: `clean` asks both processes to stop (SIGTERM, or
    its Windows equivalents) and waits; `hard` kills them outright while
    the job is running.
 4. Starts the CURRENT build (this checkout: dataplane/zig-out and control/)
    on the same files and checks that nothing was lost or counted twice:
    every key's usage and cost, the key list, which secrets authenticate,
    every job's state, cost and outputs (downloaded and hashed again), the
    job in flight (finished by the new build), the waiting webhook
    (delivered, signature valid), the spooled usage (counted exactly once),
    a second restart, and the names of the files in the data directory.

`--mixed` then runs the two mixed pairs for as long as an upgrade takes: the
old data plane with the new control plane on the upgraded data, and the new
data plane with the old control plane on fresh data.

It skips (exit code 0, with the reason) when git, the commit, zig or mix are
not available. Exit code 1 when a check fails. Not part of tools/check.py:
building an old commit takes several minutes.

Standard library only (it imports tools/e2e.py).
"""

import argparse
import base64
import glob
import hashlib
import hmac
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e  # noqa: E402
from e2e import CONTROL, CONTROL_PORT, GATEWAY, GATEWAY_PORT, ADMIN_TOKEN, ROOT, WINDOWS, call, jcall, wait_port, wait_until  # noqa: E402
import fastbind  # noqa: E402,F401  (servers start without a DNS lookup)

K_MAIN, K_BUDGET = "og-upgrade-main-key-0001", "og-upgrade-budget-key-0002"
HOOK_SECRET = "upgrade-webhook-secret"
HOOK_PORT = 9199
EXE = "omnigate-dp" + (".exe" if WINDOWS else "")
# A small ledger segment and frequent snapshots, so that a few hundred
# events leave several sealed segments and a snapshot behind.
LEDGER_FLAGS = "-omnigate_control ledger_segment_bytes 6000 -omnigate_control ledger_snapshot_every 40"

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"   [{detail}]" if detail != "" and not ok else ""), flush=True)
    return bool(ok)


def section(title):
    print(f"\n== {title}", flush=True)


def skip(reason):
    print(f"SKIP: {reason}")
    sys.exit(0)


def run(cmd, cwd=None, env=None, timeout=1800):
    return subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)


# --------------------------------------------------------------------------
# builds
# --------------------------------------------------------------------------

class Build:
    """Where one version's two programs are."""

    def __init__(self, name, exe, control_dir, env=None):
        self.name, self.exe, self.control_dir, self.env = name, exe, control_dir, env or {}


def tool_env():
    env = dict(os.environ)
    if WINDOWS:
        extra = [r"C:\Program Files\Erlang OTP\bin", r"C:\Program Files\Elixir\bin"]
        env["PATH"] = os.pathsep.join(extra + [env.get("PATH", "")])
    return env


def current_build():
    exe = os.path.join(ROOT, "dataplane", "zig-out", "bin", EXE)
    if not os.path.exists(exe):
        skip(f"{exe} not found; run `zig build` in dataplane/ first")
    return Build("current", exe, os.path.join(ROOT, "control"))


def old_build(commit, base, env):
    """Check `commit` out into a worktree under `base` and build it there."""
    git = shutil.which("git")
    if not git or run([git, "rev-parse", "--is-inside-work-tree"], cwd=ROOT).returncode != 0:
        skip("this is not a git checkout (or git is not installed): there is no older commit to build")
    resolved = run([git, "rev-parse", "--verify", "--quiet", commit + "^{commit}"], cwd=ROOT)
    if resolved.returncode != 0:
        skip(f"commit {commit} is not in this repository's history (a shallow clone? fetch more history)")
    sha = resolved.stdout.strip()
    zig, mix = shutil.which("zig", path=env["PATH"]), shutil.which("mix", path=env["PATH"])
    if not zig or not mix:
        skip("zig and mix are both needed to build the old commit")
    if run([git, "diff", "--quiet", sha, "HEAD", "--", "control/mix.lock"], cwd=ROOT).returncode != 0:
        skip(f"control/mix.lock differs between {commit} and this checkout: the old control plane cannot be built with these dependencies")

    tree = os.path.join(base, "tree")
    marker = os.path.join(base, "built")
    if os.path.exists(marker) and open(marker).read().strip() == sha and os.path.exists(os.path.join(tree, "dataplane", "zig-out", "bin", EXE)):
        print(f"reusing the build of {commit} in {base}", flush=True)
    else:
        if os.path.exists(tree):
            run([git, "worktree", "remove", "--force", tree], cwd=ROOT)
            shutil.rmtree(tree, ignore_errors=True)
        os.makedirs(base, exist_ok=True)
        print(f"checking out {commit} into {tree} ...", flush=True)
        r = run([git, "worktree", "add", "--detach", tree, sha], cwd=ROOT)
        if r.returncode != 0:
            skip(f"git worktree add failed: {r.stderr.strip()[-300:]}")
        print("building the old data plane ...", flush=True)
        r = run([zig, "build"], cwd=os.path.join(tree, "dataplane"), env=env)
        if r.returncode != 0:
            skip(f"the old data plane does not build with this zig: {(r.stdout + r.stderr)[-600:]}")
        print("building the old control plane ...", flush=True)
        r = run([mix, "compile"], cwd=os.path.join(tree, "control"), env=dict(env, **old_mix_env(base)))
        if r.returncode != 0:
            skip(f"the old control plane does not build: {(r.stdout + r.stderr)[-600:]}")
        with open(marker, "w") as f:
            f.write(sha)
    return Build(commit, os.path.join(tree, "dataplane", "zig-out", "bin", EXE), os.path.join(tree, "control"), old_mix_env(base))


def old_mix_env(base):
    return {"MIX_DEPS_PATH": os.path.join(ROOT, "control", "deps"), "MIX_BUILD_PATH": os.path.join(base, "mix-build")}


def remove_old_build(base):
    git = shutil.which("git")
    tree = os.path.join(base, "tree")
    if git and os.path.exists(tree):
        run([git, "worktree", "remove", "--force", tree], cwd=ROOT)
    shutil.rmtree(base, ignore_errors=True)
    if git:
        run([git, "worktree", "prune"], cwd=ROOT)


# --------------------------------------------------------------------------
# the stack: mocks stay up across the upgrade, the two programs are swapped
# --------------------------------------------------------------------------

def config(work, privacy=False):
    price = {"price_in_per_mtok": 1.0, "price_out_per_mtok": 2.0}
    up = lambda name, kind, port: {"name": name, "kind": kind, "base_url": f"http://127.0.0.1:{port}", "api_key_env": "MOCK_API_KEY"}
    main = {"name": "main", "key": K_MAIN, "webhook_secret": HOOK_SECRET}
    if privacy:
        main["privacy"] = True
    return {
        "keys": [main, {"name": "budgeted", "key": K_BUDGET, "budget_usd": 50, "budget_period": "monthly"}],
        "upstreams": [up("mock-ok", "openai", 9002), up("mock-anthropic", "anthropic", 9003)],
        "routes": [{"model": "direct", "targets": [dict(upstream="mock-ok", model="ok-1", **price)]},
                   {"model": "claude", "targets": [dict(upstream="mock-anthropic", model="mock-claude", **price)]},
                   {"model": "echo", "targets": [dict(upstream="mock-ok", model="echo-1", **price)]}],
        "media": {
            "public_base_url": GATEWAY, "poll_interval_ms": 200,
            "upstreams": [up("replicate", "replicate", 9101), up("replicate-broken", "replicate", 9102), up("openai-images", "openai_images", 9104)],
            "routes": [{"model": "image", "timeout_s": 300, "targets": [{"upstream": "replicate", "model": "mock/image", "price": {"per_output_usd": 0.003}}]},
                       {"model": "broken", "targets": [{"upstream": "replicate-broken", "model": "mock/broken-image", "price": {"per_output_usd": 0.004}}]},
                       {"model": "image-sync", "targets": [{"upstream": "openai-images", "model": "mock-image-1", "price": {"per_output_usd": 0.05}}]}],
            "storage": {"kind": "local", "dir": os.path.join(work, "data", "media"), "url_ttl_s": 3600},
            "webhooks": {"allow_private": True, "retry_schedule_ms": [1000] * 40, "max_attempts": 40, "timeout_ms": 3000},
        },
    }


class Runner:
    def __init__(self, work, cfg):
        self.work = work
        self.data = os.path.join(work, "data")           # the control plane's data directory
        self.dp = os.path.join(work, "dataplane")        # the data plane's working directory
        os.makedirs(self.data, exist_ok=True)
        os.makedirs(self.dp, exist_ok=True)
        self.stack = e2e.Stack(work, cfg, True)
        self.stack.env["MOCK_WEBHOOK_SECRET"] = HOOK_SECRET
        self.node = 0

    def control_env(self):
        return {
            "OMNIGATE_CONTROL_PORT": str(CONTROL_PORT), "OMNIGATE_CONFIG": self.stack.config_path,
            "OMNIGATE_LEDGER": os.path.join(self.data, "ledger.jsonl"), "OMNIGATE_JOBS": os.path.join(self.data, "jobs.jsonl"),
            "OMNIGATE_KEYS": os.path.join(self.data, "keys.json"), "OMNIGATE_AUDIT_LOG": os.path.join(self.data, "audit.jsonl"),
            "OMNIGATE_MEDIA_DIR": os.path.join(self.data, "media"), "ERL_FLAGS": LEDGER_FLAGS,
        }

    def start_control(self, build):
        """As a named Erlang node, so that it can be asked to stop the way SIGTERM does."""
        env = self.stack.env
        self.node += 1
        self.node_name = f"og_upgrade_{os.getpid()}_{self.node}"
        elixir = shutil.which("elixir", path=env["PATH"])
        cmd = [elixir, "--sname", self.node_name, "--cookie", "og_upgrade_cookie", "-S", "mix", "run", "--no-halt"]
        proc = self.stack.start("control", cmd, cwd=build.control_dir, env=dict(self.control_env(), **build.env))
        if not wait_port(CONTROL_PORT, 300, proc):
            self.stack.fail(f"the {build.name} control plane did not start", "control")
        wait_until(lambda: call("GET", CONTROL + "/readyz")[0] == 200, 60)

    def start_gateway(self, build):
        env = {"OMNIGATE_LISTEN": f"127.0.0.1:{GATEWAY_PORT}", "OMNIGATE_CONTROL_URL": CONTROL, "OMNIGATE_POLL_MS": "300", "OMNIGATE_FLUSH_MS": "200"}
        proc = self.stack.start("gateway", [build.exe], cwd=self.dp, env=env)
        if not wait_port(GATEWAY_PORT, 30, proc):
            self.stack.fail(f"the {build.name} data plane did not start", "gateway")

    def stop_control(self, hard):
        proc = self.stack.procs.get("control")
        if not proc:
            return True
        clean = False
        if not hard:
            if WINDOWS:
                # No SIGTERM on Windows: ask the node to stop itself, which runs
                # the same orderly shutdown (`init:stop/0`) a SIGTERM starts.
                host = run(["hostname"]).stdout.strip().split(".")[0]
                erl = shutil.which("erl", path=self.stack.env["PATH"])
                run([erl, "-noshell", "-sname", f"{self.node_name}_stop", "-setcookie", "og_upgrade_cookie", "-eval",
                     f"rpc:call('{self.node_name}@{host}', init, stop, []), init:stop()."], env=self.stack.env, timeout=60)
            else:
                os.killpg(proc.p.pid, signal.SIGTERM)
            clean = bool(wait_until(lambda: e2e.port_free(CONTROL_PORT), 30, 0.2))
        self.stack.stop("control")
        wait_until(lambda: e2e.port_free(CONTROL_PORT), 15, 0.2)
        return clean

    def stop_gateway(self, hard, patience=25):
        proc = self.stack.procs.get("gateway")
        if not proc:
            return True
        clean = False
        if not hard:
            proc.p.send_signal(signal.CTRL_BREAK_EVENT if WINDOWS else signal.SIGTERM)
            try:
                code = proc.p.wait(timeout=patience)
                clean = code == 0
                if not clean:
                    print(f"      the data plane exited with status {code}: {proc.tail(4)!r}")
            except subprocess.TimeoutExpired:
                print(f"      the data plane did not exit within {patience} s: {proc.tail(3)!r}")
        self.stack.stop("gateway")
        wait_until(lambda: e2e.port_free(GATEWAY_PORT), 15, 0.2)
        return clean

    def log(self, name):
        try:
            return open(os.path.join(self.work, f"{name}.log"), "rb").read().decode("utf-8", "replace")
        except OSError:
            return ""


# --------------------------------------------------------------------------
# a webhook receiver that is only started after the upgrade
# --------------------------------------------------------------------------

class Hooks:
    def __init__(self):
        self.received = []
        hooks = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("content-length", 0)))
                msg_id, ts = self.headers.get("webhook-id") or "", self.headers.get("webhook-timestamp") or ""
                signed = f"{msg_id}.{ts}.".encode() + body
                want = "v1," + base64.b64encode(hmac.new(HOOK_SECRET.encode(), signed, hashlib.sha256).digest()).decode()
                valid = any(hmac.compare_digest(want, s) for s in (self.headers.get("webhook-signature") or "").split(" "))
                try:
                    payload = json.loads(body)
                except ValueError:
                    payload = {}
                hooks.received.append({"id": msg_id, "valid": valid, "payload": payload})
                self.send_response(200)
                self.send_header("content-length", "0")
                self.end_headers()

        self.server = ThreadingHTTPServer(("127.0.0.1", HOOK_PORT), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()

    def for_job(self, job_id):
        return [r for r in self.received if job_id in r["id"] or (r["payload"].get("data") or r["payload"]).get("id") == job_id]


# --------------------------------------------------------------------------
# requests
# --------------------------------------------------------------------------

def admin(method, path, body=None):
    return jcall(method, CONTROL + path, key=ADMIN_TOKEN, body=body)


def chat(key, model="direct", stream=False):
    body = {"model": model, "messages": [{"role": "user", "content": "hello"}]}
    if stream:
        s, events, _ = e2e.sse("/v1/chat/completions", key, dict(body, stream=True))
        return s
    return call("POST", GATEWAY + "/v1/chat/completions", key=key, body=body)[0]


def messages(key):
    return call("POST", GATEWAY + "/v1/messages", key=key, headers={"anthropic-version": "2023-06-01"},
                body={"model": "claude", "max_tokens": 64, "messages": [{"role": "user", "content": "hello"}]})[0]


def usage_rows():
    _, _, body = admin("GET", "/admin/usage")
    return {r.get("name"): r for r in body.get("keys", [])}


def money(x):
    return round(float(x or 0), 9)


USAGE_FIELDS = ("requests", "input_tokens", "output_tokens", "jobs")


def usage_view(rows):
    return {name: dict({f: r.get(f) for f in USAGE_FIELDS if f in r}, cost_usd=money(r.get("cost_usd"))) for name, r in rows.items()}


def job(key, jid):
    return jcall("GET", f"{GATEWAY}/v1/jobs/{jid}", key=key)[2]


def create_job(key, model, input_, **extra):
    s, _, j = jcall("POST", GATEWAY + "/v1/jobs", key=key, body=dict({"model": model, "input": input_}, **extra))
    return s, j.get("id", ""), j


def download(url, key):
    s, _, data = call("GET", url, key=key, timeout=60)
    return s, hashlib.sha256(data).hexdigest()


TERMINAL = ("succeeded", "failed", "canceled")
# Every name the two programs may leave in their directories, as the docs list them.
KNOWN_FILES = [r"ledger\.jsonl$", r"ledger\.\d{6}\.jsonl$", r"ledger\.snapshot(\.prev|\.tmp)?$", r"ledger\.ids\.\d{4}-\d\d-\d\d$",
               r"jobs\.jsonl$", r"jobs\.jsonl\.inputs/", r"keys\.json$", r"audit\.jsonl$", r"media/",
               r"omnigate-usage\.spool$", r"omnigate-config\.cache\.json$"]


def listing(root):
    out = []
    for d, _, files in os.walk(root):
        for f in files:
            out.append(os.path.relpath(os.path.join(d, f), root).replace("\\", "/"))
    return sorted(out)


# --------------------------------------------------------------------------
# one variant
# --------------------------------------------------------------------------

def write_state(r, old):
    """Everything the old build is made to write. Returns what was observed."""
    seen = {"secrets": {}}

    section(f"state written by the old build ({old.name})")
    # Admin sign-ins, good and bad, for the audit log.
    e2e.control_raw("POST", "/login", {"content-type": "application/x-www-form-urlencoded"}, raw="token=wrong-token-wrong-token")
    e2e.control_raw("POST", "/login", {"content-type": "application/x-www-form-urlencoded"}, raw="token=" + ADMIN_TOKEN)

    # Managed keys.
    for name, body in (("m-one", {}), ("m-rot", {}), ("m-off", {}), ("m-budget", {"budget_usd": 5, "budget_period": "monthly"})):
        s, _, created = admin("POST", "/admin/keys", dict(body, name=name))
        if s != 201:
            r.stack.fail(f"the old build refused to create key {name}: {s} {created}")
        seen["secrets"][name] = created["key"]
    first = seen["secrets"]["m-rot"]
    wait_until(lambda: chat(first) == 200, 10)
    for name in ("m-one", "m-rot", "m-budget", "m-off"):
        wait_until(lambda: chat(seen["secrets"][name]) == 200, 10)
    middle = admin("POST", "/admin/keys/m-rot/rotate")[2].get("key", "")
    wait_until(lambda: chat(middle) == 200, 10)
    last = admin("POST", "/admin/keys/m-rot/rotate")[2].get("key", "")
    wait_until(lambda: chat(last) == 200 and chat(first) == 401 and chat(middle) == 401, 10)
    seen["secrets"].update({"m-rot": last, "m-rot (first secret)": first, "m-rot (second secret)": middle})
    admin("PATCH", "/admin/keys/m-off", {"disabled": True})
    wait_until(lambda: chat(seen["secrets"]["m-off"]) == 401, 10)

    # Text usage: enough events for several ledger segments.
    for i in range(60):
        chat(K_MAIN, stream=(i % 10 == 0))
        messages(K_MAIN)
        chat(K_BUDGET)
        chat(seen["secrets"]["m-one"])
        chat(seen["secrets"]["m-rot"])
        chat(seen["secrets"]["m-budget"])

    # Media jobs.
    jobs = {}
    for label in ("done-1", "done-2"):
        _, jobs[label], _ = create_job(K_MAIN, "image", {"prompt": label})
    _, jobs["sync"], _ = create_job(K_BUDGET, "image-sync", {"prompt": "sync"})
    _, jobs["failed"], _ = create_job(K_MAIN, "broken", {"prompt": "fails"})
    _, jobs["canceled"], _ = create_job(K_MAIN, "image", {"prompt": "cancel me", "mock_delay_s": 60})
    call("POST", f"{GATEWAY}/v1/jobs/{jobs['canceled']}/cancel", key=K_MAIN)
    # Its webhook has nowhere to go until after the upgrade.
    _, jobs["hook"], _ = create_job(K_MAIN, "image", {"prompt": "hook"}, webhook_url=f"http://127.0.0.1:{HOOK_PORT}/hook")
    owner = {"sync": K_BUDGET}
    for label in ("done-1", "done-2", "sync", "failed", "canceled", "hook"):
        wait_until(lambda: job(owner.get(label, K_MAIN), jobs[label]).get("status") in TERMINAL, 60, 0.3)
    # Still running at the provider when the old build goes away; it too has a webhook.
    _, jobs["in-flight"], _ = create_job(K_MAIN, "image", {"prompt": "in flight", "mock_delay_s": 45}, webhook_url=f"http://127.0.0.1:{HOOK_PORT}/hook")
    wait_until(lambda: job(K_MAIN, jobs["in-flight"]).get("status") == "running", 15, 0.2)
    seen["jobs"], seen["owner"] = jobs, owner

    # Let the ledger catch up, then note what the old build reports.
    time.sleep(1.5)
    stable = wait_until(lambda: (lambda a: a if a == usage_view(usage_rows()) else None)(usage_view(usage_rows())), 20, 0.7)
    seen["usage"] = stable or usage_view(usage_rows())
    seen["keys"] = {k.get("name"): k for k in admin("GET", "/admin/keys")[2].get("keys", [])}
    seen["auth"] = {label: call("GET", GATEWAY + "/v1/models", key=secret)[0] for label, secret in seen["secrets"].items()}
    seen["auth"]["main"] = call("GET", GATEWAY + "/v1/models", key=K_MAIN)[0]
    seen["job_view"], seen["hashes"] = {}, {}
    for label, jid in jobs.items():
        j = job(owner.get(label, K_MAIN), jid)
        seen["job_view"][label] = j
        for i, out in enumerate(j.get("outputs") or []):
            s, digest = download(out["url"], owner.get(label, K_MAIN))
            seen["hashes"][(label, i)] = (s, digest, out.get("sha256"))
    states = {label: j.get("status") for label, j in seen["job_view"].items()}
    print(f"      usage: { {k: v.get('requests') for k, v in seen['usage'].items()} }")
    print(f"      jobs: {states}")
    check("the old build wrote the state the test needs (finished, failed, cancelled and running jobs; usage on six keys)",
          states.get("done-1") == "succeeded" and states.get("failed") == "failed" and states.get("canceled") == "canceled"
          and states.get("hook") == "succeeded" and states.get("in-flight") == "running" and len(seen["usage"]) >= 6
          and all(s == 200 and d == h for s, d, h in seen["hashes"].values()), (states, seen["hashes"]))
    seen["audit_lines"] = len(open(os.path.join(r.data, "audit.jsonl"), "rb").read().splitlines()) if os.path.exists(os.path.join(r.data, "audit.jsonl")) else 0
    return seen


def one_variant(old, new, hard, mixed, keep):
    label = "killed mid-job" if hard else "stopped cleanly"
    print(f"\n######## {old.name} -> current, old build {label}", flush=True)
    work = tempfile.mkdtemp(prefix="omnigate-upgrade-")
    r = Runner(work, config(work))
    hooks = None
    try:
        r.stack.start_mocks()
        r.start_control(old)
        r.start_gateway(old)
        wait_until(lambda: call("GET", GATEWAY + "/v1/models", key=K_MAIN)[0] == 200, 20)
        seen = write_state(r, old)

        section(f"the old build goes away ({label})")
        # The control plane first, so that the data plane has usage it cannot deliver.
        clean_cp = r.stop_control(hard)
        spooled = 0
        for _ in range(12):
            spooled += chat(K_MAIN) == 200
            spooled += messages(K_MAIN) == 200
        time.sleep(1.0)        # past one flush interval: the events are in the spool file, not only in memory
        clean_dp = r.stop_gateway(hard, patience=12)
        spool = os.path.join(r.dp, "omnigate-usage.spool")
        spool_lines = len(open(spool, "rb").read().splitlines()) if os.path.exists(spool) else 0
        if not hard:
            check("the old control plane stopped by itself when asked", clean_cp)
            if not clean_dp:
                # Not a check: commits before 0.1.0-rc.1 do not finish stopping when the control plane
                # is gone and slow to refuse (the bug is theirs); the test kills the process instead.
                print("      note: the old data plane did not stop by itself without its control plane, and was killed")
        check(f"the old data plane answered {spooled} requests without its control plane and left their usage in the spool",
              spooled == 24 and spool_lines >= 24, (spooled, spool_lines))
        before = listing(r.data)
        print(f"      data directory after the old build: {len(before)} files; ledger: {[f for f in before if f.startswith('ledger')]}")
        check("the old build left a ledger in several segments with a snapshot",
              sum(1 for f in before if re.match(r"ledger\.\d{6}\.jsonl$", f)) >= 2 and "ledger.snapshot" in before, [f for f in before if f.startswith("ledger")])
        snapshot_before = open(os.path.join(r.data, "ledger.snapshot"), "rb").read()[:300]

        section("the current build on the same files")
        hooks = Hooks()
        r.start_control(new)
        r.start_gateway(new)
        up = wait_until(lambda: call("GET", GATEWAY + "/v1/models", key=K_MAIN)[0] == 200, 30)
        check("both current programs start on the old files", bool(up) and call("GET", CONTROL + "/readyz")[0] == 200)

        expected = json.loads(json.dumps(seen["usage"]))
        expected["main"]["requests"] += spooled
        want_main = expected["main"]["requests"]
        rows = wait_until(lambda: (lambda u: u if u.get("main", {}).get("requests", 0) >= want_main else None)(usage_view(usage_rows())), 30, 0.5) or usage_view(usage_rows())
        time.sleep(2.0)         # anything counted twice would show up now
        rows = usage_view(usage_rows())
        others_same = all(rows.get(name) == view for name, view in seen["usage"].items() if name != "main")
        check("every other key's usage and cost are exactly what the old build reported", others_same,
              {n: (seen["usage"][n], rows.get(n)) for n in seen["usage"] if n != "main" and rows.get(n) != seen["usage"][n]})
        check(f"the main key has its old usage plus the {spooled} spooled requests, counted once",
              rows.get("main", {}).get("requests") == want_main and rows["main"].get("jobs") == seen["usage"]["main"].get("jobs"),
              (seen["usage"].get("main"), rows.get("main"), spooled))
        tokens_ok = rows.get("main", {}).get("input_tokens", 0) > seen["usage"]["main"].get("input_tokens", 0) and money(rows["main"]["cost_usd"]) > money(seen["usage"]["main"]["cost_usd"])
        check("... with their tokens and cost added", tokens_ok, rows.get("main"))
        spool_after = open(spool, "rb").read() if os.path.exists(spool) else b""
        check("the spool is empty once its events were delivered", wait_until(lambda: not os.path.exists(spool) or os.path.getsize(spool) == 0, 15, 0.5), len(spool_after))

        keys_now = {k.get("name"): k for k in admin("GET", "/admin/keys")[2].get("keys", [])}
        skip_fields = {"requests", "input_tokens", "output_tokens", "cached_input_tokens", "cache_write_input_tokens", "cost_usd", "spend_usd", "period_spend_usd",
                       "last_used_at", "jobs", "spend", "usage", "period", "lifetime"}
        diffs = {}
        for name, old_row in seen["keys"].items():
            now = keys_now.get(name)
            if now is None:
                diffs[name] = "missing"
                continue
            # The main key took the spooled requests in the meantime; every other key must read the same in every field.
            ignore = skip_fields if name == "main" else {"last_used_at"}
            changed = {f: (v, now.get(f)) for f, v in old_row.items() if f not in ignore and not isinstance(v, (dict, list)) and now.get(f) != v
                       and not (isinstance(v, float) and isinstance(now.get(f), (int, float)) and abs(v - now.get(f)) < 1e-9)}
            if changed:
                diffs[name] = changed
        check("the key list shows every key as before: settings, state, dates, and (the main key apart) spend and period spend", not diffs, diffs)
        auth_now = {lbl: call("GET", GATEWAY + "/v1/models", key=secret)[0] for lbl, secret in seen["secrets"].items()}
        auth_now["main"] = call("GET", GATEWAY + "/v1/models", key=K_MAIN)[0]
        check("every secret is accepted or refused exactly as before (rotated-away and disabled ones stay refused)", auth_now == seen["auth"], (seen["auth"], auth_now))

        jobs, owner = seen["jobs"], seen["owner"]
        same, moved = [], {}
        for lbl, jid in jobs.items():
            if lbl == "in-flight":
                continue
            was, now = seen["job_view"][lbl], job(owner.get(lbl, K_MAIN), jid)
            fields = ("status", "model", "cost_usd", "created_at", "finished_at", "upstream", "target_model")
            ok = all(was.get(f) == now.get(f) for f in fields) and [o.get("sha256") for o in was.get("outputs") or []] == [o.get("sha256") for o in now.get("outputs") or []]
            ok = ok and (was.get("error") or {}).get("code") == (now.get("error") or {}).get("code")
            same.append(ok)
            if not ok:
                moved[lbl] = ({f: was.get(f) for f in fields}, {f: now.get(f) for f in fields}, now.get("error"))
        check("finished, failed and cancelled jobs read the same as before (state, cost, times, outputs, error)", all(same), moved)
        s, _, lst = jcall("GET", GATEWAY + "/v1/jobs?limit=50", key=K_MAIN)
        listed = {j.get("id") for j in lst.get("data", lst.get("jobs", []))}
        mine = {jid for lbl, jid in jobs.items() if owner.get(lbl, K_MAIN) == K_MAIN}
        check("the job list of the key holds all of its jobs", s == 200 and mine <= listed, (s, len(listed), len(mine)))
        redone = {}
        for (lbl, i), (_, digest, _) in seen["hashes"].items():
            out = (job(owner.get(lbl, K_MAIN), jobs[lbl]).get("outputs") or [])[i]
            s, again = download(out["url"], owner.get(lbl, K_MAIN))
            if s != 200 or again != digest:
                redone[(lbl, i)] = (s, again[:12], digest[:12])
        check(f"all {len(seen['hashes'])} stored outputs download again with the same hashes", not redone and len(seen["hashes"]) >= 4, redone)

        flying = wait_until(lambda: (lambda j: j if j.get("status") in TERMINAL else None)(job(K_MAIN, jobs["in-flight"])), 120, 0.5) or job(K_MAIN, jobs["in-flight"])
        print(f"      the job that was running: {flying.get('status')}, cost {flying.get('cost_usd')}, error {flying.get('error')}, attempts {flying.get('attempts')}")
        check("the job that was running at the provider is finished by the current build, with its output and its price",
              flying.get("status") == "succeeded" and len(flying.get("outputs") or []) == 1 and money(flying.get("cost_usd")) == 0.003, flying.get("error"))
        if flying.get("outputs"):
            s, digest = download(flying["outputs"][0]["url"], K_MAIN)
            check("... and that output downloads with its recorded hash", s == 200 and digest == flying["outputs"][0].get("sha256"), s)
        rows = wait_until(lambda: (lambda u: u if u.get("main", {}).get("jobs") == seen["usage"]["main"].get("jobs", 0) + 1 else None)(usage_view(usage_rows())), 20, 0.5) or usage_view(usage_rows())
        check("... and it is billed once", rows.get("main", {}).get("jobs") == seen["usage"]["main"].get("jobs", 0) + 1, rows.get("main"))

        got = wait_until(lambda: hooks.for_job(jobs["hook"]) and hooks.for_job(jobs["in-flight"]), 90, 0.5)
        a, b = hooks.for_job(jobs["hook"]), hooks.for_job(jobs["in-flight"])
        check("the webhook that could not be delivered before the upgrade arrives after it, correctly signed", bool(a) and all(x["valid"] for x in a), a[:1])
        check("the job finished after the upgrade sends its webhook too", bool(b) and all(x["valid"] for x in b), b[:1])
        print(f"      webhook deliveries: waiting one {len(a)}, new one {len(b)}; any other: {len(hooks.received) - len(a) - len(b)}")
        check("no webhook is delivered twice, and none for jobs that asked for none", len(a) == 1 and len(b) == 1 and len(hooks.received) == 2, [x["id"] for x in hooks.received])

        s, _, audit = admin("GET", "/admin/audit?limit=200")
        entries = audit.get("entries", [])
        check("the audit log still shows what happened under the old build (sign-ins, key changes)",
              s == 200 and any(e.get("action") == "login" for e in entries) and any("m-rot" == e.get("target") for e in entries), (s, len(entries)))
        errors = [l for l in r.log("control").splitlines() if "[error]" in l][-5:]
        check("the control plane logged no error on the way", not errors, errors)
        dp_bad = [l for l in r.log("gateway").splitlines() if l.startswith("error") or "panic" in l.lower()][-5:]
        check("the data plane logged no error or panic on the way", not dp_bad, dp_bad)

        section("a second restart of the current build")
        final = usage_view(usage_rows())
        clean_cp = r.stop_control(False)
        # Again with usage that cannot be delivered: the current data plane must stop by itself all the same.
        late = sum(chat(K_BUDGET) == 200 for _ in range(5))
        time.sleep(1.0)
        began = time.time()
        clean_dp = r.stop_gateway(False)
        check("both current processes stop by themselves when asked, the data plane with undelivered usage and no control plane",
              clean_cp and clean_dp and late == 5, (clean_cp, clean_dp, late, round(time.time() - began, 1)))
        r.start_control(new)
        r.start_gateway(new)
        wait_until(lambda: call("GET", GATEWAY + "/v1/models", key=K_MAIN)[0] == 200, 30)
        final["budgeted"]["requests"] += late
        now = wait_until(lambda: (lambda u: u if u.get("budgeted", {}).get("requests") == final["budgeted"]["requests"] else None)(usage_view(usage_rows())), 20, 0.5) or usage_view(usage_rows())
        time.sleep(1.0)
        now = usage_view(usage_rows())
        same = all(now.get(n) == v for n, v in final.items() if n != "budgeted") and now.get("budgeted", {}).get("requests") == final["budgeted"]["requests"]
        check("totals are unchanged after restarting on the files the current build wrote, plus that usage, once", same, (final, now))
        check("jobs are unchanged too", all(job(owner.get(lbl, K_MAIN), jid).get("status") == (seen["job_view"][lbl].get("status") if lbl != "in-flight" else "succeeded") for lbl, jid in jobs.items()))

        after = listing(r.data)
        dp_files = listing(r.dp)
        unknown = [f for f in after + dp_files if not any(re.match(p, f) for p in KNOWN_FILES)]
        new_files = sorted({re.sub(r"\d{4}-\d\d-\d\d", "<day>", re.sub(r"\d{6}", "<n>", re.sub(r"job_[0-9a-f]+", "<job>", f))) for f in after if f not in before})
        print(f"      new kinds of file since the upgrade: {new_files}")
        check("every file in the two data directories is one the upgrade guide names", not unknown, unknown[:8])
        snapshot_after = open(os.path.join(r.data, "ledger.snapshot"), "rb").read()[:300]
        print(f"      ledger snapshot before: {snapshot_before[:90]!r}\n      ledger snapshot after:  {snapshot_after[:90]!r}")

        if mixed:
            mixed_old_dataplane(r, old, new, seen)
    finally:
        if hooks:
            hooks.stop()
        r.stack.stop_all()
        if keep:
            print(f"kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


# --------------------------------------------------------------------------
# mixed pairs, for as long as an upgrade takes
# --------------------------------------------------------------------------

def text_and_jobs(tag, key, expect_jobs=True):
    """Text in both protocols and one media job through whatever pair is running."""
    before = usage_view(usage_rows()).get("main", {})
    n = sum(chat(key, stream=(i == 0)) == 200 for i in range(4)) + sum(messages(key) == 200 for _ in range(3))
    check(f"{tag}: text requests are answered in both protocols, streamed and not", n == 7, n)
    rows = wait_until(lambda: (lambda u: u if u.get("requests", 0) >= before.get("requests", 0) + 7 else None)(usage_view(usage_rows()).get("main", {})), 20, 0.5) or {}
    time.sleep(1.0)
    rows = usage_view(usage_rows()).get("main", {})
    check(f"{tag}: their usage reaches the ledger, once", rows.get("requests") == before.get("requests", 0) + 7 and rows.get("input_tokens", 0) > before.get("input_tokens", 0), (before, rows))
    if expect_jobs:
        s, jid, _ = create_job(key, "image", {"prompt": tag})
        done = wait_until(lambda: (lambda j: j if j.get("status") in TERMINAL else None)(job(key, jid)), 60, 0.3) or {}
        ok = s == 202 and done.get("status") == "succeeded"
        if ok:
            st, digest = download(done["outputs"][0]["url"], key)
            ok = st == 200 and digest == done["outputs"][0].get("sha256")
        check(f"{tag}: a media job is created, runs and its output downloads through the data plane", ok, (s, done.get("status"), done.get("error")))
    s = call("GET", GATEWAY + "/v1/models", key="og-not-a-key-at-all-000000")[0]
    check(f"{tag}: an unknown key is refused", s == 401, s)


def mixed_old_dataplane(r, old, new, seen):
    section(f"mixed pair: data plane {old.name}, control plane current (on the upgraded data)")
    r.stop_gateway(False)
    r.start_gateway(old)
    ok = wait_until(lambda: call("GET", GATEWAY + "/v1/models", key=K_MAIN)[0] == 200, 30)
    check("the old data plane starts on the spool and config cache the current one left, and takes the current control plane's config", bool(ok))
    text_and_jobs("old data plane + current control plane", K_MAIN)
    # Counters are flushed every few seconds; give a refusal count time to arrive.
    time.sleep(6)
    errors = [l for l in r.log("control").splitlines() if "[error]" in l][-5:]
    check("the current control plane logs no error about what the old data plane sends (config polls, usage, refusal counts)", not errors, errors)
    # What docs/upgrading.md says about privacy with this pair: the control plane knows the
    # setting, the old data plane ignores it, so nothing is redacted until it is upgraded.
    s, _, created = admin("POST", "/admin/keys", {"name": "m-private", "privacy": True})
    secret = created.get("key", "")
    wait_until(lambda: call("GET", GATEWAY + "/v1/models", key=secret)[0] == 200, 10)
    email = "upgrade.mixed@example.com"
    ask = {"model": "echo", "messages": [{"role": "user", "content": f"mail {email} now"}]}
    st, h, _ = jcall("POST", GATEWAY + "/v1/chat/completions", key=secret, body=ask)
    last = jcall("GET", "http://127.0.0.1:9002/__last?model=echo-1")[2]
    # control_dir is <worktree>/control; redact.zig came with privacy mode.
    if os.path.exists(os.path.join(os.path.dirname(old.control_dir), "dataplane", "src", "redact.zig")):
        print("      (the old data plane already knows privacy mode: nothing to show here)")
    else:
        check("a key made private on the current control plane is NOT private through the old data plane, as the upgrade guide warns: no redaction, no privacy header",
              s == 201 and st == 200 and "x-omnigate-privacy" not in h and email in last.get("body", ""), (s, st, h.get("x-omnigate-privacy"), last.get("body", "")[:100]))
    r.stop_gateway(False)
    r.start_gateway(new)
    wait_until(lambda: call("GET", GATEWAY + "/v1/models", key=K_MAIN)[0] == 200, 30)
    wait_until(lambda: call("GET", GATEWAY + "/v1/models", key=secret)[0] == 200, 10)
    st, h, body = jcall("POST", GATEWAY + "/v1/chat/completions", key=secret, body=ask)
    last = jcall("GET", "http://127.0.0.1:9002/__last?model=echo-1")[2]
    check("... and is private as soon as the data plane is the current one: the provider gets a placeholder, the client its address",
          st == 200 and "redact" in h.get("x-omnigate-privacy", "") and email not in last.get("body", email) and email in json.dumps(body), (st, h.get("x-omnigate-privacy"), last.get("body", "")[:100]))


def mixed_new_dataplane(old, new, keep):
    print(f"\n######## mixed pair: data plane current, control plane {old.name} (fresh data)", flush=True)
    work = tempfile.mkdtemp(prefix="omnigate-upgrade-mixed-")
    r = Runner(work, config(work))
    try:
        r.stack.start_mocks()
        r.start_control(old)
        r.start_gateway(new)
        ok = wait_until(lambda: call("GET", GATEWAY + "/v1/models", key=K_MAIN)[0] == 200, 30)
        section("the current data plane with the old control plane")
        check("the current data plane takes the old control plane's config", bool(ok))
        text_and_jobs("current data plane + old control plane", K_MAIN)
        # What docs/upgrading.md says about privacy with this pair: no key has
        # the setting, but the request header works for text requests.
        email = "upgrade.mixed@example.com"
        s, h, body = jcall("POST", GATEWAY + "/v1/chat/completions", key=K_MAIN, headers={"x-omnigate-privacy": "redact"},
                           body={"model": "echo", "messages": [{"role": "user", "content": f"mail {email} now"}]})
        _, _, last = jcall("GET", "http://127.0.0.1:9002/__last?model=echo-1")
        check("the privacy request header redacts on the current data plane even though the old control plane knows no privacy setting",
              s == 200 and "redact" in h.get("x-omnigate-privacy", "") and email in json.dumps(body) and email not in last.get("body", email), (s, h.get("x-omnigate-privacy"), last.get("body", "")[:120]))
        time.sleep(6)
        errors = [l for l in r.log("control").splitlines() if "[error]" in l][-5:]
        check("the old control plane logs no error about what the current data plane sends (usage, refusal and redaction counts)", not errors, errors)
        dp_bad = [l for l in r.log("gateway").splitlines() if l.startswith("error") or "panic" in l.lower()][-5:]
        check("the current data plane logs no error about what the old control plane answers", not dp_bad, dp_bad)
    finally:
        r.stack.stop_all()
        if keep:
            print(f"kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("commit", help="the older commit to upgrade from, e.g. 6d5ed6e")
    ap.add_argument("--variant", choices=("clean", "hard", "both"), default="clean")
    ap.add_argument("--mixed", action="store_true", help="also run the two mixed pairs")
    ap.add_argument("--build-dir", default=None, help="where to keep the old commit's worktree and build (kept for the next run; default: a temporary directory, removed afterwards)")
    ap.add_argument("--keep", action="store_true", help="keep the working directories")
    args = ap.parse_args()

    env = tool_env()
    os.environ["PATH"] = env["PATH"]
    new = current_build()
    base = args.build_dir or tempfile.mkdtemp(prefix="omnigate-old-")
    started = time.time()
    try:
        old = old_build(args.commit, os.path.abspath(base), env)
        for hard in {"clean": [False], "hard": [True], "both": [False, True]}[args.variant]:
            one_variant(old, new, hard, args.mixed and not hard or (args.mixed and args.variant == "hard"), args.keep)
        if args.mixed:
            mixed_new_dataplane(old, new, args.keep)
    finally:
        if not args.build_dir:
            remove_old_build(base)
        if WINDOWS:
            # The named nodes made Erlang start its port mapper (epmd), which stays
            # behind listening on port 4369. It only goes away if no node is using it.
            erl = shutil.which("erl", path=env["PATH"])
            found = glob.glob(os.path.join(os.path.dirname(os.path.dirname(erl)), "erts-*", "bin", "epmd.exe")) if erl else []
            if found:
                run([found[0], "-kill"], env=env, timeout=30)
    bad = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(bad)}/{len(results)} upgrade checks passed in {time.time() - started:.0f}s (from {args.commit})")
    for n in bad:
        print("  FAILED:", n)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
