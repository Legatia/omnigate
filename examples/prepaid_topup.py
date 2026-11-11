#!/usr/bin/env python3
"""Credit gateway keys from payments: the skeleton of a prepaid billing service.

omnigate knows nothing about payments. This script stands next to it, hears
of payments from a *source*, and adds each one to a key's budget with
`POST /admin/keys/{name}/topup`. The payment's own id is the `reference`, so
a payment that is seen twice (a retry, a restart, a watcher that rescans) is
credited once: delivery here is at-least-once and omnigate makes it
exactly-once.

The source below reads payments from a JSON-lines file, one per line:

    {"reference": "0xabc...", "key": "customer-42", "amount_usd": 5}

Replace `FileSource` with whatever tells you money arrived (a chain watcher,
a payment provider's webhook queue). It only has to yield the same three
fields, and may yield a payment more than once.

Try it against the dev stack (docs/quickstart.md; control plane on :4000):

    echo '{"reference": "demo-1", "key": "customer-42", "amount_usd": 5}' >> payments.jsonl
    python examples/prepaid_topup.py --payments payments.jsonl --create-keys --once

The first run creates the key `customer-42` with an empty prepaid budget,
prints its secret once, and credits $5. Run it again: nothing is added.

Environment: OMNIGATE_CONTROL (default http://127.0.0.1:4000) and
OMNIGATE_ADMIN_TOKEN (default: the dev token). The admin token can do
everything, so run this next to the control plane, never on a public host.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CONTROL = os.environ.get("OMNIGATE_CONTROL", "http://127.0.0.1:4000").rstrip("/")
TOKEN = os.environ.get("OMNIGATE_ADMIN_TOKEN", "dev-admin-token-change-me")


def admin(method, path, body=None):
    """(status, parsed JSON). Status 0 means the control plane could not be reached."""
    data = None if body is None else json.dumps(body).encode()
    headers = {"authorization": "Bearer " + TOKEN, "content-type": "application/json"}
    request = urllib.request.Request(CONTROL + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {}
    except (urllib.error.URLError, OSError):
        return 0, {}


class FileSource:
    """Payments from a JSON-lines file, from where the last run stopped.

    The position is saved only after a payment is settled, so a crash in
    between hands the same payment out again. That is fine: see `credit`.
    """

    def __init__(self, path, state_path):
        self.path, self.state_path = path, state_path
        try:
            self.offset = json.load(open(state_path))["offset"]
        except (OSError, ValueError, KeyError):
            self.offset = 0

    def pending(self):
        """Yields (payment dict, position after it). Half-written last lines wait for the next poll."""
        try:
            with open(self.path, "rb") as f:
                f.seek(self.offset)
                position = self.offset
                for line in f:
                    if not line.endswith(b"\n"):
                        break
                    position += len(line)
                    if line.strip():
                        yield line, position
        except OSError:
            return

    def settled(self, position):
        self.offset = position
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"offset": position}, f)
        os.replace(tmp, self.state_path)


def credit(payment, create_keys):
    """'done', 'rejected' (will never work: set aside) or 'retry' (try again later)."""
    key, body = payment["key"], {"amount_usd": payment["amount_usd"], "reference": payment["reference"]}
    path = "/admin/keys/" + urllib.parse.quote(str(key), safe="") + "/topup"
    status, answer = admin("POST", path, body)
    if status == 404 and create_keys:
        # A first payment for a new customer: a key with an empty prepaid budget.
        status, created = admin("POST", "/admin/keys", {"name": key, "budget_usd": 0, "budget_period": "total"})
        if status == 201:
            print(f"created key {key}; its secret, shown once: {created['key']}")
        elif status != 409:  # 409: someone else created it just now
            return "retry" if status in (0, 500, 502, 503) else "rejected"
        status, answer = admin("POST", path, body)
    if status == 200:
        done = answer["topup"]
        what = "already credited" if done["replayed"] else "credited"
        print(f"{what}: {done['reference']} -> {key} +${done['amount_usd']:g}, budget now ${done['budget_usd']:g}")
        return "done"
    if status in (0, 500, 502, 503):
        return "retry"
    # 400 (bad amount or reference), 404 (no such key), 409 (not a prepaid key,
    # or the reference was used for another key or amount): a person must look.
    print(f"REJECTED {payment}: {status} {answer.get('error', {}).get('code')}: {answer.get('error', {}).get('message')}", file=sys.stderr)
    return "rejected"


def run_once(source, rejected_path, create_keys):
    """Settle what is pending. False when the control plane was unreachable (nothing is skipped)."""
    for line, position in source.pending():
        try:
            payment = json.loads(line)
            outcome = credit(payment, create_keys) if {"reference", "key", "amount_usd"} <= set(payment) else "rejected"
        except (ValueError, TypeError):
            outcome = "rejected"
        if outcome == "retry":
            return False
        if outcome == "rejected":
            with open(rejected_path, "ab") as f:
                f.write(line)
        source.settled(position)
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--payments", required=True, help="JSON-lines file of payments")
    ap.add_argument("--state", help="where the read position is kept (default: <payments>.state)")
    ap.add_argument("--create-keys", action="store_true", help="create a prepaid key for a payment whose key does not exist")
    ap.add_argument("--once", action="store_true", help="settle what is there and exit (default: keep polling)")
    ap.add_argument("--interval", type=float, default=2.0, help="seconds between polls")
    args = ap.parse_args()
    source = FileSource(args.payments, args.state or args.payments + ".state")
    while True:
        ok = run_once(source, args.payments + ".rejected", args.create_keys)
        if args.once:
            sys.exit(0 if ok else 1)
        time.sleep(args.interval if ok else max(args.interval, 5.0))


if __name__ == "__main__":
    main()
