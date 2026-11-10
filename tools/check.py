"""Run every check a change to omnigate should pass, in order, and summarise.

    python tools/check.py              # everything
    python tools/check.py --quick      # unit tests and formatting only (about a minute)
    python tools/check.py --only e2e sdk
    python tools/check.py --skip malformed
    python tools/check.py --list

Steps, in order:

    build       zig build                      (the gateway binary the later steps start)
    zig-test    zig build test                 (data plane unit tests)
    zig-fmt     zig fmt --check                (data plane formatting)
    mix-format  mix format --check-formatted   (control plane formatting)
    mix-test    mix test                       (control plane unit tests)
    importer    tools/test_import_litellm.py   (LiteLLM config importer)
    e2e         tools/e2e.py                   (whole stack against mock providers)
    sdk         tools/sdk_compat.py            (official OpenAI and Anthropic SDKs as clients;
                                                skipped unless both are importable: pip install openai anthropic)
    malformed   tools/malformed_test.py        (hostile input; the gateway must survive it)

Each step's output goes to a log file; a failing step's last lines are shown.
The container test (tools/container_test.py) is not part of this: it needs
Docker and several minutes. Exit code 0 only if every step that ran passed.

Needs `zig` (0.17) and `mix` (Elixir 1.20 / OTP 29) on PATH. On Windows the
default install folders of Erlang and Elixir are added to PATH for you; set
ZIG to the compiler's full path if it is not on PATH.

Standard library only.
"""

import argparse
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WINDOWS = os.name == "nt"


def environment():
    env = dict(os.environ)
    if WINDOWS:
        extra = [r"C:\Program Files\Erlang OTP\bin", r"C:\Program Files\Elixir\bin"]
        env["PATH"] = os.pathsep.join(extra + [env.get("PATH", "")])
    return env


def find(tool, env, override=None):
    if override and os.environ.get(override):
        return os.environ[override]
    return shutil.which(tool, path=env["PATH"])


def steps(env):
    zig = find("zig", env, "ZIG")
    mix = find("mix", env)
    py = sys.executable
    dp = os.path.join(ROOT, "dataplane")
    cp = os.path.join(ROOT, "control")
    tools = os.path.join(ROOT, "tools")
    have_sdks = all(importlib.util.find_spec(name) for name in ("openai", "anthropic"))

    def need(tool, path):
        return None if path else f"`{tool}` not found on PATH"

    return [
        # name, quick?, command, working directory, reason it cannot run (or None)
        ("build", True, [zig, "build"], dp, need("zig", zig)),
        ("zig-test", True, [zig, "build", "test", "--summary", "all"], dp, need("zig", zig)),
        ("zig-fmt", True, [zig, "fmt", "--check", "src", "build.zig"], dp, need("zig", zig)),
        ("mix-format", True, [mix, "format", "--check-formatted"], cp, need("mix", mix)),
        ("mix-test", True, [mix, "test"], cp, need("mix", mix)),
        ("importer", True, [py, os.path.join(tools, "test_import_litellm.py")], ROOT, None),
        ("e2e", False, [py, os.path.join(tools, "e2e.py")], ROOT, need("mix", mix)),
        ("sdk", False, [py, os.path.join(tools, "sdk_compat.py")], ROOT,
         None if have_sdks else "the openai and anthropic packages are not installed for this Python (optional)"),
        ("malformed", False, [py, os.path.join(tools, "malformed_test.py")], ROOT, need("mix", mix)),
    ]


def tail(path, lines=25):
    try:
        with open(path, "rb") as f:
            return b"\n".join(f.read().splitlines()[-lines:]).decode("utf-8", "replace")
    except OSError:
        return ""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quick", action="store_true", help="unit tests and formatting only")
    ap.add_argument("--only", nargs="+", metavar="STEP", help="run just these steps")
    ap.add_argument("--skip", nargs="+", metavar="STEP", default=[], help="leave these steps out")
    ap.add_argument("--fail-fast", action="store_true", help="stop at the first failing step")
    ap.add_argument("--list", action="store_true", help="list the steps and exit")
    ap.add_argument("-v", "--verbose", action="store_true", help="show each step's output as it runs")
    args = ap.parse_args()

    env = environment()
    plan = steps(env)
    names = [s[0] for s in plan]
    for chosen in (args.only or []) + args.skip:
        if chosen not in names:
            ap.error(f"unknown step {chosen!r}; steps are: {', '.join(names)}")
    if args.list:
        for name, quick, cmd, _, missing in plan:
            note = f"  (cannot run: {missing})" if missing else ""
            print(f"{name:<11} {'quick' if quick else 'full '}  {' '.join(os.path.basename(str(c)) for c in cmd[:3])}{note}")
        return 0

    logs = tempfile.mkdtemp(prefix="omnigate-check-")
    rows = []
    for name, quick, cmd, cwd, missing in plan:
        if args.only and name not in args.only:
            continue
        if name in args.skip or (args.quick and not quick and not args.only):
            continue
        if missing:
            # An optional step that cannot run is skipped; a required tool that is absent is a failure.
            optional = name == "sdk"
            rows.append((name, "skipped" if optional else "FAILED", 0.0, missing))
            print(f"{'skip' if optional else 'FAIL'}  {name}: {missing}", flush=True)
            if not optional and args.fail_fast:
                break
            continue

        if sys.stdout.isatty():
            print(f"....  {name}", end="\r", flush=True)
        log_path = os.path.join(logs, name + ".log")
        started = time.time()
        with open(log_path, "wb") as log:
            if args.verbose:
                code = subprocess.call(cmd, cwd=cwd, env=env)
            else:
                code = subprocess.call(cmd, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        took = time.time() - started
        ok = code == 0
        rows.append((name, "ok" if ok else "FAILED", took, "" if ok else f"exit code {code}, log: {log_path}"))
        print(f"{'ok  ' if ok else 'FAIL'}  {name}  ({took:.0f}s)", flush=True)
        if not ok:
            if not args.verbose:
                print("      " + tail(log_path).replace("\n", "\n      "))
            if args.fail_fast:
                break

    failed = [r for r in rows if r[1] == "FAILED"]
    print("\n" + "-" * 60)
    for name, state, took, note in rows:
        print(f"{name:<11} {state:<8} {took:6.0f}s  {note}")
    print("-" * 60)
    if failed:
        print(f"{len(failed)} of {len(rows)} steps failed: {', '.join(r[0] for r in failed)}")
        return 1
    ran = [r for r in rows if r[1] == "ok"]
    skipped = [r for r in rows if r[1] == "skipped"]
    print(f"all {len(ran)} steps passed" + (f" ({len(skipped)} skipped)" if skipped else ""))
    shutil.rmtree(logs, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
