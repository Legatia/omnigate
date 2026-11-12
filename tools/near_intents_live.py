#!/usr/bin/env python3
"""omnigate's payments against the real NEAR Intents (1Click) API, without funds.

    python tools/near_intents_live.py            # read-only: assets and DRY quotes
    python tools/near_intents_live.py --serve    # start the gateway with config/omnigate.payments.json
                                                 # and a prepaid key, for one real payment by hand

The default run starts a control plane and a data plane on ports of its own,
with a config that takes payments through `near_intents` at the real
https://1click.chaindefuser.com, and asks through the gateway, as a client:

  1. GET  /v1/payments/assets      the real asset list, through the adapter
  2. POST /v1/payments/quote       dry quotes for several chains: what would
                                   have to be sent for $5 of the settle asset.
                                   Each answer passed the adapter's checks: it
                                   is signed by 1Click's key and repeats what
                                   was asked. A dry quote creates nothing.
  3. the provider's refusals       an address that is not one, a chain's
                                   minimum: relayed in the provider's words

No request here creates a deposit address, and nothing is paid: no payment
has been made with this code against the real service. Needs the network,
so it is not part of tools/check.py or CI. Build the data plane first
(`zig build` in dataplane/; `mix deps.get` in control/ before the first run).

--serve is for the one real payment (docs/payments.md, "Trying it with real
funds"): it uses config/omnigate.payments.json as it is (the recipient in it
is the account that receives the funds: check it), on the usual ports,
creates a prepaid key and prints what to run next. It sends nothing itself.
"""
import argparse
import json
import os
import secrets
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import near_live  # noqa: E402  (its Stack: a control plane and a data plane on given ports)
from e2e import ROOT, jcall, wait_until  # noqa: E402

USDC = "nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1"
results = []

# An address in each chain's format to name as the refund address. They are
# the examples of the formats' own specifications (EIP-55, BIP-173) and the
# wrapped-SOL mint: nothing is ever sent to them, a dry quote only checks
# that they are well-formed.
EVM = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
# (what, symbol, chain, refund address, dollars: Bitcoin's bridge takes no less than about $6)
QUOTES = [
    ("NEAR", "wNEAR", "near", "example.near", 5),
    ("Ether on Ethereum", "ETH", "eth", EVM, 5),
    ("Bitcoin", "BTC", "btc", "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", 10),
    ("SOL on Solana", "SOL", "sol", "So11111111111111111111111111111111111111112", 5),
    ("USDC on Base", "USDC", "base", EVM, 5),
    ("USDC on Arbitrum", "USDC", "arb", EVM, 5),
]


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f"\n        {str(detail)[:700]}"), flush=True)


def section(title):
    print(f"\n== {title}", flush=True)


def stack_with(config_path, work, control_port, gateway_port, token):
    near_live.CONFIG = config_path
    stack = near_live.Stack(work, control_port, gateway_port, token)
    stack.env["OMNIGATE_PAYMENTS"] = os.path.join(work, "payments.json")
    return stack


def prepaid_key(stack, name):
    status, _, created = stack.admin("POST", "/admin/keys", {"name": name, "budget_usd": 0})
    key = created.get("key", "")
    if status != 201:
        sys.exit(f"could not create a prepaid key: {status} {created}")
    wait_until(lambda: jcall("GET", stack.gateway + "/v1/models", key=key)[0] == 200, 20, 0.3)
    return key


def run_checks(stack, recipient):
    key = prepaid_key(stack, "live-payer")
    gw = stack.gateway

    section("what can be paid with (the real list, through the adapter)")
    status, _, body = jcall("GET", gw + "/v1/payments/assets", key=key, timeout=90)
    assets = body.get("assets", []) if isinstance(body, dict) else []
    chains = sorted({a.get("chain") for a in assets})
    usdc = next((a for a in assets if a.get("asset") == USDC), {})
    print(f"        {len(assets)} assets on {len(chains)} chains: {', '.join(chains)}")
    check("GET /v1/payments/assets lists what 1Click accepts", status == 200 and len(assets) >= 50 and len(chains) >= 10, (status, str(body)[:300]))
    check("the settle asset (native USDC on NEAR) is among them, with 6 decimals", usdc.get("symbol") == "USDC" and usdc.get("chain") == "near" and usdc.get("decimals") == 6, usdc)
    status, _, only = jcall("GET", gw + "/v1/payments/assets?chain=near&symbol=wNEAR", key=key, timeout=60)
    check("... and the list can be narrowed by chain and symbol", status == 200 and [a.get("asset") for a in only.get("assets", [])] == ["nep141:wrap.near"], only)

    section(f"dry quotes: what must be sent so that $5 (Bitcoin: $10) of USDC reaches {recipient} (nothing is created)")
    for what, symbol, chain, refund_to, usd in QUOTES:
        asset = next((a for a in assets if a.get("symbol") == symbol and a.get("chain") == chain), None)
        if asset is None:
            check(f"{what}: listed by the provider", False, f"no {symbol} on {chain} in the list")
            continue
        status, _, quote = jcall("POST", gw + "/v1/payments/quote", key=key, body={"amount_usd": usd, "asset": asset["asset"], "refund_to": refund_to}, timeout=90)
        ok = status == 200 and float(quote.get("amount") or 0) > 0 and str(quote.get("amount_units", "")).isdigit() and "address" not in json.dumps(quote)
        if ok:
            print(f"        {what}: ${usd} takes {quote['amount']} {symbol} (about ${quote.get('deposit_usd')}), about {quote.get('time_estimate_s')} s")
        check(f"{what}: a signed quote that repeats what was asked, with no deposit address", ok, (status, quote))
        # One key may ask the provider six times a minute.
        time.sleep(11)

    section("what the provider refuses reaches the payer in its words")
    status, _, body = jcall("POST", gw + "/v1/payments/quote", key=key, body={"amount_usd": 5, "asset": "nep141:wrap.near", "refund_to": "not/a/near/account"}, timeout=90)
    check("a refund address that is not one on the paying chain: 400 payment_quote_refused", status == 400 and (body.get("error") or {}).get("code") == "payment_quote_refused", (status, body))
    print(f"        the provider said: {(body.get('error') or {}).get('message')}")
    time.sleep(11)
    status, _, body = jcall("POST", gw + "/v1/payments/quote", key=key, body={"amount_usd": 1, "asset": next(a["asset"] for a in assets if a.get("symbol") == "BTC" and a.get("chain") == "btc"),
                                                                                "refund_to": "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"}, timeout=90)
    check("$1 in Bitcoin is less than its bridge takes: refused with the provider's reason", status == 400 and "too low" in json.dumps(body).lower(), (status, body))
    print(f"        the provider said: {(body.get('error') or {}).get('message')}")
    time.sleep(11)
    bnb = next((a for a in assets if a.get("chain") == "bsc"), None)
    if bnb:
        status, _, body = jcall("POST", gw + "/v1/payments/quote", key=key, body={"amount_usd": 5, "asset": bnb["asset"], "refund_to": EVM}, timeout=90)
        # What the provider does with this pair has changed over time (a $1,000
        # minimum, no quote, a quote): either answer is fine, as long as it is
        # the provider's own and reaches the payer intact.
        refused = status == 400 and (body.get("error") or {}).get("code") == "payment_quote_refused"
        check("$5 from BNB Chain: a quote, or a refusal with the provider's reason", refused or (status == 200 and body.get("provider") == "near_intents" and "deposit" not in body), (status, body))
        print(f"        the provider said: {(body.get('error') or {}).get('message') if refused else 'quoted: ' + str(body.get('amount')) + ' ' + str(body.get('symbol'))}")

    section("nothing was started")
    status, _, listed = jcall("GET", gw + "/v1/payments", key=key)
    status2, _, admin_list = stack.admin("GET", "/admin/payments")
    check("no payment exists after all of this: dry quotes create none", status == 200 and listed.get("payments") == [] and status2 == 200 and admin_list.get("payments") == [], (listed, admin_list))


def serve():
    config = os.path.join(ROOT, "config", "omnigate.payments.json")
    recipient = json.load(open(config, encoding="utf-8"))["payments"]["recipient"]
    token = os.environ.get("OMNIGATE_ADMIN_TOKEN") or secrets.token_urlsafe(18)
    work = tempfile.mkdtemp(prefix="omnigate-payments-")
    stack = stack_with(config, work, 4000, 8080, token)
    print("starting the control plane and the data plane with config/omnigate.payments.json ...", flush=True)
    stack.start()
    key = prepaid_key(stack, "payer")
    print(f"""
Payments go to the account in the config:  {recipient}   <- check this before sending anything
Gateway:        http://127.0.0.1:8080
A prepaid key with no credit:  {key}
Admin token (dashboard http://127.0.0.1:4000/):  {token}
State and logs: {work}

One real payment, by hand (docs/payments.md, "Trying it with real funds"):

  1. What it would take, without starting anything:
       curl -s http://127.0.0.1:8080/v1/payments/quote -H "authorization: Bearer {key}" -H "content-type: application/json" \\
         -d '{{"amount_usd": 1, "asset": "nep141:wrap.near", "refund_to": "<your NEAR account>"}}'
  2. Start the payment (this creates a deposit address at NEAR Intents):
       curl -s http://127.0.0.1:8080/v1/payments -H "authorization: Bearer {key}" -H "content-type: application/json" \\
         -d '{{"amount_usd": 1, "asset": "nep141:wrap.near", "refund_to": "<your NEAR account>"}}'
  3. From your own wallet, send exactly deposit.amount of the asset to deposit.address before the deadline.
  4. Watch it settle and the key being credited:
       curl -s http://127.0.0.1:8080/v1/payments/<id> -H "authorization: Bearer {key}"
       curl -s http://127.0.0.1:4000/admin/keys -H "authorization: Bearer {token}"

This script sends nothing. Ctrl-C stops both processes; a payment that is still open is kept in
{os.path.join(work, 'payments.json')} only for as long as that directory exists.""", flush=True)
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
    ap.add_argument("--serve", action="store_true", help="start the gateway with config/omnigate.payments.json on ports 4000 and 8080 and keep it running")
    ap.add_argument("--recipient", default="example.near", help="the account named as recipient in the dry quotes (default example.near; nothing is sent to it)")
    ap.add_argument("--keep", action="store_true", help="keep the temp directory (logs, ledger)")
    args = ap.parse_args()
    if args.serve:
        return serve()

    started = time.time()
    work = tempfile.mkdtemp(prefix="omnigate-intents-")
    config = os.path.join(work, "omnigate.intents.json")
    with open(config, "w", encoding="utf-8") as f:
        json.dump({"keys": [], "upstreams": [], "routes": [], "payments": {"provider": "near_intents", "recipient": args.recipient}}, f)
    stack = stack_with(config, work, 14120, 18190, "intents-live-admin-" + secrets.token_hex(8))
    try:
        stack.start()
        run_checks(stack, args.recipient)
    finally:
        stack.stop()

    failed = [name for name, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed in {time.time() - started:.0f}s (dry quotes only: no payment was made)")
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
