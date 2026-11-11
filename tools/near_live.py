#!/usr/bin/env python3
"""The NEAR AI Cloud integration against the real service.

    python tools/near_live.py            # check, then exit
    python tools/near_live.py --serve    # start the gateway with the NEAR config and keep it running

Uses the network (cloud-api.near.ai, Intel's and NVIDIA's attestation
services), so it is not part of tools/check.py or CI. It needs no API key:
an attestation report is public. With NEAR_AI_API_KEY in the environment it
also sends one real private completion through the gateway.

What a run does:

  1. Runs the control plane's own attestation code once from the command
     line (OmnigateControl.Attestation.Live) and prints what was verified.
  2. Starts the control plane and the data plane with config/omnigate.near.json
     on ports of its own, state in a temp directory.
  3. Waits for the attestation manager's verdicts and checks them: the model
     NEAR serves itself verifies, the model it only relays does not.
  4. Checks what the data plane does with them: a request that asks for
     attested providers only is sent to the verified model and refused,
     unsent, on the other two; a dry run shows the placeholders.
  5. With a key: one chat completion with an e-mail address and a card number
     in it. The answer must have the real values, the response must carry
     x-omnigate-attestation, and NEAR must have been sent placeholders.

--serve does step 2 on the usual ports (control plane 4000, gateway 8080),
prints the address of the Private chat page and the admin token, and waits
for Ctrl-C. Build the data plane first: `zig build` in dataplane/
(`mix deps.get` in control/ before the first start).
"""
import argparse
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e  # noqa: E402  (the helpers of the end-to-end test)
from e2e import ROOT, WINDOWS, call, jcall, wait_port, wait_until  # noqa: E402

CONFIG = os.path.join(ROOT, "config", "omnigate.near.json")
MODEL = "z-ai/glm-5.3-flash"
PRIVATE = {"email": "dana.reyes@example.com", "card": "4111 1111 1111 1111"}

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f"\n        {str(detail)[:600]}"), flush=True)


def section(title):
    print(f"\n== {title}", flush=True)


def tool_env():
    env = dict(os.environ)
    if WINDOWS:
        env["PATH"] = os.pathsep.join([r"C:\Program Files\Erlang OTP\bin", r"C:\Program Files\Elixir\bin", env.get("PATH", "")])
    return env


def live_check(env):
    mix = shutil.which("mix", path=env["PATH"])
    if not mix:
        sys.exit("`mix` not found; install Erlang/Elixir or put them on PATH")
    cmd = [mix, "run", "--no-start", "-e", "OmnigateControl.Attestation.Live.main()"]
    proc = subprocess.run(cmd, cwd=os.path.join(ROOT, "control"), env=env, capture_output=True, text=True, timeout=600)
    print(proc.stdout.rstrip())
    if proc.returncode != 0 and proc.stderr.strip():
        print(proc.stderr.rstrip()[-2000:])
    return proc.returncode == 0, proc.stdout


class Stack:
    def __init__(self, work, control_port, gateway_port, admin_token):
        self.work, self.control_port, self.gateway_port = work, control_port, gateway_port
        self.control = f"http://127.0.0.1:{control_port}"
        self.gateway = f"http://127.0.0.1:{gateway_port}"
        self.admin_token = admin_token
        self.procs = []
        self.env = tool_env()
        self.env.update({
            "OMNIGATE_INTERNAL_TOKEN": secrets.token_hex(24),
            "OMNIGATE_ADMIN_TOKEN": admin_token,
            "OMNIGATE_CONFIG": CONFIG,
            "OMNIGATE_CONTROL_PORT": str(control_port),
            "OMNIGATE_GATEWAY_URL": self.gateway,
            "OMNIGATE_LEDGER": os.path.join(work, "ledger.jsonl"),
            "OMNIGATE_KEYS": os.path.join(work, "keys.json"),
            "OMNIGATE_JOBS": os.path.join(work, "jobs.jsonl"),
            "OMNIGATE_AUDIT_LOG": os.path.join(work, "audit.jsonl"),
            "OMNIGATE_MEDIA_DIR": os.path.join(work, "media"),
            "OMNIGATE_LISTEN": f"127.0.0.1:{gateway_port}",
            "OMNIGATE_CONTROL_URL": self.control,
            "OMNIGATE_POLL_MS": "500",
            "PYTHONUNBUFFERED": "1",
        })

    def start(self):
        busy = [p for p in (self.control_port, self.gateway_port) if not e2e.port_free(p)]
        if busy:
            sys.exit(f"ports already in use: {busy}. Stop whatever is listening there and rerun.")
        exe = os.path.join(ROOT, "dataplane", "zig-out", "bin", "omnigate-dp" + (".exe" if WINDOWS else ""))
        if not os.path.exists(exe):
            sys.exit(f"{exe} not found; run `zig build` in dataplane/ first")
        mix = shutil.which("mix", path=self.env["PATH"])
        control = e2e.Proc("control", [mix, "run", "--no-halt"], os.path.join(ROOT, "control"), self.env, self.work)
        self.procs.append(control)
        if not wait_port(self.control_port, 240, control):
            self.fail("the control plane did not start", control)
        gateway = e2e.Proc("gateway", [exe], self.work, self.env, self.work)
        self.procs.append(gateway)
        if not wait_port(self.gateway_port, 20, gateway):
            self.fail("the data plane did not start", gateway)

    def fail(self, message, proc):
        print(message)
        print(proc.tail(40))
        self.stop()
        sys.exit(1)

    def stop(self):
        for proc in reversed(self.procs):
            proc.stop()
        self.procs = []

    def admin(self, method, path, body=None):
        return jcall(method, self.control + path, key=self.admin_token, body=body, timeout=180)


def error_code(body):
    return (body.get("error") or {}).get("code") or (body.get("error") or {}).get("type")


def run_checks(stack, have_key):
    section("the control plane keeps the attestation verified")

    def settled():
        _, _, body = stack.admin("GET", "/admin/attestations")
        rows = {a["model"]: a for a in body.get("attestations", [])}
        return rows if len(rows) == 2 and all(a["state"] != "pending" for a in rows.values()) else None

    rows = wait_until(settled, 90, 1) or {}
    own, relayed = rows.get(MODEL) or {}, rows.get("openai/gpt-5") or {}
    check(f"{MODEL} (served by NEAR in its own enclaves) is verified", own.get("verified") is True, own.get("reason") or rows)
    evidence = own.get("evidence") or {}
    gateway, models = evidence.get("gateway") or {}, evidence.get("models") or [{}]
    check("... gateway and model: genuine TDX quotes, platform status UpToDate",
          gateway.get("tcb_status") == "UpToDate" and all(m.get("tcb_status") == "UpToDate" for m in models), (gateway.get("tcb_status"), models))
    check("... the model's GPU evidence was accepted by NVIDIA", models[0].get("gpu") == "verified", models[0].get("gpu"))
    check("openai/gpt-5 (relayed by NEAR to a third party) has no attestation and is not verified",
          relayed.get("verified") is False and "attestation" in (relayed.get("reason") or ""), relayed)
    started = time.time()
    status, _, again = stack.admin("POST", "/admin/attestations/verify", {"upstream": "near-ai", "model": MODEL})
    check("\"verify again now\": a second check with a new nonce passes too",
          status == 200 and again.get("verified") is True and (again.get("evidence") or {}).get("nonce") not in (None, evidence.get("nonce")),
          (status, again.get("reason")))
    print(f"        (that check took {time.time() - started:.1f} s; gateway signer {gateway.get('signing_address', '')[:16]}..., "
          f"app_compose sha256 {gateway.get('app_compose_sha256', '')[:16]}...)")

    section("the data plane routes by the verdict")
    status, _, made = stack.admin("POST", "/admin/keys", {"name": "near-live"})
    key = made.get("key")
    check("a gateway key for this run", status == 201 and bool(key), (status, made))
    wait_until(lambda: call("GET", stack.gateway + "/v1/models", key=key)[0] == 200, 20)
    text = f"Reply with exactly this sentence: The contact is {PRIVATE['email']} and the card is {PRIVATE['card']}."
    body = {"model": "private", "messages": [{"role": "user", "content": text}], "max_tokens": 200}
    ask = lambda model, headers: jcall("POST", stack.gateway + "/v1/chat/completions", key=key, headers=headers, body=dict(body, model=model), timeout=180)

    status, headers, dry = ask("private", {"x-omnigate-privacy": "redact, attested", "x-omnigate-dry-run": "privacy"})
    would = dry.get("body") or ""
    check("dry run: the provider would be sent placeholders, not the address or the card number",
          status == 200 and dry.get("sent_upstream") is False and "[EMAIL_1]" in would and "[CARD_1]" in would and not any(v in would for v in PRIVATE.values()),
          (status, dry))
    for model, why in (("unattested", "an upstream without attestation"), ("relayed", "a model whose attestation did not verify")):
        status, headers, answer = ask(model, {"x-omnigate-privacy": "redact, attested"})
        check(f"a request for attested providers only is refused, unsent, on {why}",
              status == 503 and error_code(answer) == "attestation_unverified" and "x-omnigate-upstream" not in headers, (status, answer))

    status, headers, answer = ask("private", {"x-omnigate-privacy": "redact, no-store, unlink, attested"})
    if not have_key:
        check("without NEAR_AI_API_KEY the same request is let through to the verified model, and it is NEAR that refuses it (401, no key)",
              status == 401 and headers.get("x-omnigate-upstream") == "near-ai" and (headers.get("x-omnigate-attestation") or "").startswith("verified;"),
              (status, headers.get("x-omnigate-upstream"), headers.get("x-omnigate-attestation"), answer))
        print("        (set NEAR_AI_API_KEY to run the real private completion; https://cloud.near.ai, or $10 of credits at https://nearbuilders.org/dashboard)")
        return

    section("one real private completion")
    said = ((answer.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
    check("NEAR answered through the gateway", status == 200 and headers.get("x-omnigate-upstream") == "near-ai", (status, answer))
    check("the response says the provider's attestation was verified", (headers.get("x-omnigate-attestation") or "").startswith("verified; tcb=UpToDate"), headers.get("x-omnigate-attestation"))
    check("the response says what was applied", headers.get("x-omnigate-privacy") == "no-store, redact, unlink", headers.get("x-omnigate-privacy"))
    check("the answer has the real address and card number back in it (the model only ever saw placeholders)",
          all(v in said for v in PRIVATE.values()), said[:400])
    print(f"        answer: {said[:200]!r}")
    usage = answer.get("usage") or {}
    print(f"        usage: {usage.get('prompt_tokens')} tokens in, {usage.get('completion_tokens')} out; request id {headers.get('x-omnigate-request-id')}")


def serve():
    token = os.environ.get("OMNIGATE_ADMIN_TOKEN") or secrets.token_urlsafe(18)
    work = tempfile.mkdtemp(prefix="omnigate-near-")
    stack = Stack(work, 4000, 8080, token)
    print("starting the control plane and the data plane with config/omnigate.near.json ...", flush=True)
    stack.start()
    key = "set" if os.environ.get("NEAR_AI_API_KEY") else "NOT set: the verification panel works, chatting needs the key"
    print(f"""
Private chat:  http://127.0.0.1:4000/private-chat
Dashboard:     http://127.0.0.1:4000/
Sign in with the admin token:  {token}
Gateway:       http://127.0.0.1:8080  (OpenAI-compatible; keys are made in the dashboard)
NEAR_AI_API_KEY is {key}.
State and logs: {work}
Ctrl-C stops both.""", flush=True)
    try:
        while all(p.alive() for p in stack.procs):
            time.sleep(1)
        print("a process ended; its last lines:")
        for p in stack.procs:
            if not p.alive():
                print(p.tail(30))
    except KeyboardInterrupt:
        pass
    finally:
        stack.stop()
        print("stopped")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--serve", action="store_true", help="start the gateway with the NEAR config on ports 4000 and 8080 and keep it running")
    ap.add_argument("--skip-cli", action="store_true", help="skip step 1 (the command-line check)")
    ap.add_argument("--keep", action="store_true", help="keep the temp directory (logs, ledger)")
    args = ap.parse_args()
    if args.serve:
        return serve()

    have_key = bool(os.environ.get("NEAR_AI_API_KEY"))
    started = time.time()
    if not args.skip_cli:
        section("the control plane's attestation code, from the command line (no key, no gateway)")
        ok, out = live_check(tool_env())
        check("NEAR AI Cloud's gateway and model verify", ok and "VERIFIED" in out, out[-400:])

    work = tempfile.mkdtemp(prefix="omnigate-near-")
    stack = Stack(work, 14100, 18180, "near-live-admin-" + secrets.token_hex(8))
    try:
        stack.start()
        run_checks(stack, have_key)
    finally:
        stack.stop()

    failed = [name for name, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed in {time.time() - started:.0f}s" + ("" if have_key else " (no NEAR_AI_API_KEY: the real completion was not run)"))
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
