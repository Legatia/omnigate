#!/usr/bin/env python3
"""An agent that pays for its own inference, standard library only.

When the gateway answers 402 (the key's prepaid credit is spent), this
script does what a person would do at a checkout, through the gateway's
payment endpoints (docs/payments.md; they exist only on a gateway whose
config has a "payments" section):

    1. GET  /v1/payments/assets    what can be paid with
    2. POST /v1/payments           "I want to add N dollars, paying with this
                                   asset; refund to this address if it fails"
                                   -> a deposit address and the exact amount
    3. the deposit itself          NOT done here: this script holds no wallet.
                                   It prints the instructions and waits; an
                                   agent with a wallet sends the funds at
                                   this point, a person does it by hand
    4. GET  /v1/payments/{id}      until the payment is settled (the gateway
                                   credits the key) or has failed
    5. the request again

Nothing on the gateway's side signs or moves anything either: the funds go
from the payer to the payment provider's deposit address and from there to
the gateway operator's account.

    python examples/agent_pays.py "Say hello"

Environment:
    OMNIGATE_GATEWAY      default http://127.0.0.1:8080
    OMNIGATE_KEY          a prepaid gateway key (required)
    OMNIGATE_MODEL        default demo-direct
    OMNIGATE_PAY_USD      how much to add when the credit is spent (default 5)
    OMNIGATE_PAY_ASSET    the asset id to pay with; or leave unset and give
    OMNIGATE_PAY_SYMBOL   a symbol (default wNEAR) and
    OMNIGATE_PAY_CHAIN    a chain (default near) to pick the first match
    OMNIGATE_REFUND_TO    the paying address, which gets the funds back if
                          the payment fails (required to pay)
    OMNIGATE_PAY_WAIT_S   how long to wait for the payment (default 1800)
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

GATEWAY = os.environ.get("OMNIGATE_GATEWAY", "http://127.0.0.1:8080").rstrip("/")
KEY = os.environ.get("OMNIGATE_KEY", "")
MODEL = os.environ.get("OMNIGATE_MODEL", "demo-direct")


def call(method, path, body=None):
    """(status, decoded JSON) for one request to the gateway."""
    request = urllib.request.Request(GATEWAY + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"authorization": "Bearer " + KEY, "content-type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.status, json.loads(response.read() or b"null")
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw)
        except ValueError:
            return error.code, {"error": {"message": raw.decode("utf-8", "replace")[:200]}}


def reason(body):
    error = (body or {}).get("error") or {}
    return f"{error.get('code') or error.get('type')}: {error.get('message')}"


def pick_asset():
    """The asset id to pay with: the one named, or the first that matches a symbol and a chain."""
    if os.environ.get("OMNIGATE_PAY_ASSET"):
        return os.environ["OMNIGATE_PAY_ASSET"]
    query = urllib.parse.urlencode({"symbol": os.environ.get("OMNIGATE_PAY_SYMBOL", "wNEAR"), "chain": os.environ.get("OMNIGATE_PAY_CHAIN", "near")})
    status, body = call("GET", "/v1/payments/assets?" + query)
    if status == 404:
        sys.exit("this gateway takes no payments (its config has no \"payments\" section); ask its operator to top the key up")
    if status != 200 or not body.get("assets"):
        sys.exit(f"no asset to pay with ({status}: {reason(body) if status != 200 else 'none matches the symbol and chain asked for'})")
    return body["assets"][0]["asset"]


def pay():
    """Start a payment, say what to send where, and wait until it has an end. True when the key was credited."""
    refund_to = os.environ.get("OMNIGATE_REFUND_TO")
    if not refund_to:
        sys.exit("the key's credit is spent. To pay, set OMNIGATE_REFUND_TO to the address you pay from (it gets the funds back if the payment fails)")
    status, payment = call("POST", "/v1/payments", {"amount_usd": float(os.environ.get("OMNIGATE_PAY_USD", "5")), "asset": pick_asset(), "refund_to": refund_to})
    if status != 201:
        sys.exit(f"the payment could not be started ({status} {reason(payment)})")

    deposit = payment["deposit"]
    memo = f" with memo {deposit['memo']}" if deposit.get("memo") else ""
    # One line an agent with a wallet (or a test) can act on.
    print(f"PAY {deposit['amount']} {deposit['symbol']} on {deposit['chain']} to {deposit['address']}{memo} before {payment['deadline']} (payment {payment['id']})", flush=True)
    print(f"  that is about ${deposit.get('amount_usd')} for ${payment['amount_usd']} of credit; anything the swap does not need is refunded to {payment['refund_to']}",
          file=sys.stderr, flush=True)

    deadline = time.time() + float(os.environ.get("OMNIGATE_PAY_WAIT_S", "1800"))
    last = None
    while time.time() < deadline:
        status, payment = call("GET", "/v1/payments/" + payment["id"])
        if status != 200:
            sys.exit(f"the payment cannot be read ({status} {reason(payment)})")
        if payment["status"] != last:
            last = payment["status"]
            print(f"  payment {payment['id']}: {last}" + (f" ({payment['detail']})" if payment.get("detail") else ""), file=sys.stderr, flush=True)
        if last == "settled":
            if payment.get("credited_usd"):
                print(f"CREDITED {payment['credited_usd']} (payment {payment['id']})", flush=True)
                return True
            sys.exit(f"the payment settled but the key was not credited: {payment.get('detail')}")
        if last in ("refunded", "failed", "expired"):
            sys.exit(f"the payment ended as {last}; nothing was credited")
        time.sleep(float(os.environ.get("OMNIGATE_PAY_POLL_S", "5")))
    sys.exit("gave up waiting for the payment; it is still open on the gateway, and settles if the deposit arrives before its deadline")


def complete(prompt):
    """The model's answer to `prompt`, paying once if the key's credit is spent."""
    paid = False
    for attempt in range(40):
        status, body = call("POST", "/v1/chat/completions", {"model": MODEL, "messages": [{"role": "user", "content": prompt}]})
        if status == 200:
            return body["choices"][0]["message"].get("content") or ""
        if status == 402 and not paid:
            paid = pay()
            continue
        if status == 402:
            # Credited a moment ago: the gateway learns of it with its next config poll.
            time.sleep(0.5)
            continue
        if status == 429 or status >= 500:
            time.sleep(min(2 ** attempt, 20))
            continue
        sys.exit(f"the request failed ({status} {reason(body)})")
    sys.exit("the key was credited, but the gateway kept refusing it")


def main():
    if not KEY:
        sys.exit("set OMNIGATE_KEY to a prepaid gateway key")
    print(complete(" ".join(sys.argv[1:]) or "Say hello"))


if __name__ == "__main__":
    main()
