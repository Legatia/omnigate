#!/usr/bin/env python3
"""Check the `solana` payment provider's reading of the chain against a real Solana RPC endpoint.

    python tools/solana_live.py [--rpc URL] [--wallet ADDRESS] [--mint MINT]

Read-only and free: it sends nothing and needs no key. It makes the three
calls the gateway makes (getSignaturesForAddress, getTransaction with
jsonParsed encoding, getTokenAccountsByOwner) and checks that the answers
have the fields `control/lib/omnigate_control/payments/solana.ex` reads.

Without --wallet it takes a wallet from a recent transfer of the mint
(USDC by default), so that there is something to read. With your own wallet
it also prints the latest transfers the gateway would see: what arrived,
when, and whether it is final.
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.request

USDC = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
RESULTS = []


def rpc(url, method, params, tries=4):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    for attempt in range(tries):
        req = urllib.request.Request(url, data=body, headers={"content-type": "application/json", "accept": "application/json", "user-agent": "omnigate-solana-live"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                answer = json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt + 1 < tries:
                time.sleep(3 * (attempt + 1))
                continue
            raise
        if "error" in answer:
            raise RuntimeError(f"{method}: {answer['error']}")
        return answer["result"]


def check(name, ok, detail=None):
    RESULTS.append(bool(ok))
    print(("  PASS  " if ok else "  FAIL  ") + name + ("" if ok or detail is None else f"   [{str(detail)[:300]}]"))


def owned(balances, wallet, mint):
    return sum(int(b["uiTokenAmount"]["amount"]) for b in balances or [] if b.get("owner") == wallet and b.get("mint") == mint)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rpc", default="https://api.mainnet-beta.solana.com")
    ap.add_argument("--wallet")
    ap.add_argument("--mint", default=USDC)
    args = ap.parse_args()
    mint = args.mint
    options = {"encoding": "jsonParsed", "commitment": "confirmed", "maxSupportedTransactionVersion": 1}

    wallet = args.wallet
    if not wallet:
        # Someone who received the token a moment ago.
        for entry in rpc(args.rpc, "getSignaturesForAddress", [mint, {"limit": 12, "commitment": "finalized"}]):
            if entry.get("err") is not None:
                continue
            meta = (rpc(args.rpc, "getTransaction", [entry["signature"], options]) or {}).get("meta") or {}
            gained = [b.get("owner") for b in meta.get("postTokenBalances") or [] if b.get("mint") == mint and b.get("owner")
                      and owned(meta.get("postTokenBalances"), b["owner"], mint) > owned(meta.get("preTokenBalances"), b["owner"], mint)]
            if gained:
                wallet = gained[0]
                break
            time.sleep(0.5)
        check("a recent transfer of the mint names who received it", bool(wallet))
        if not wallet:
            return 1
    print(f"wallet {wallet}, mint {mint}, endpoint {args.rpc}")

    accounts = rpc(args.rpc, "getTokenAccountsByOwner", [wallet, {"mint": mint}, {"encoding": "jsonParsed", "commitment": "confirmed"}])
    listed = [a.get("pubkey") for a in (accounts or {}).get("value", [])]
    check("getTokenAccountsByOwner answers {value: [{pubkey}]}", isinstance(accounts, dict) and isinstance(accounts.get("value"), list)
          and all(isinstance(p, str) and 32 <= len(p) <= 44 for p in listed), accounts)
    if not listed:
        print("  this wallet holds no account for the mint yet: the first payment creates it, and until then only payments with a reference are found")
        return 0 if all(RESULTS) else 1

    entries = rpc(args.rpc, "getSignaturesForAddress", [listed[0], {"limit": 10, "commitment": "confirmed"}])
    check("getSignaturesForAddress answers a list of {signature, err, blockTime, confirmationStatus}, newest first",
          isinstance(entries, list) and all(isinstance(e.get("signature"), str) and "err" in e and "confirmationStatus" in e for e in entries)
          and [e.get("blockTime") or 0 for e in entries] == sorted([e.get("blockTime") or 0 for e in entries], reverse=True), entries[:2] if isinstance(entries, list) else entries)

    read = 0
    for entry in entries[:5]:
        tx = rpc(args.rpc, "getTransaction", [entry["signature"], options])
        meta = (tx or {}).get("meta") or {}
        shaped = isinstance(tx, dict) and "err" in meta and isinstance(meta.get("preTokenBalances"), list) and isinstance(meta.get("postTokenBalances"), list) \
            and all(isinstance(b.get("owner"), str) and isinstance(b.get("mint"), str) and str((b.get("uiTokenAmount") or {}).get("amount", "")).isdigit()
                    for b in meta["preTokenBalances"] + meta["postTokenBalances"])
        if not shaped:
            check("getTransaction (jsonParsed) carries meta.err and token balances with owner, mint and uiTokenAmount.amount", False, tx)
            break
        read += 1
        delta = owned(meta["postTokenBalances"], wallet, mint) - owned(meta["preTokenBalances"], wallet, mint) if meta["err"] is None else 0
        at = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(entry["blockTime"])) if entry.get("blockTime") else "?"
        print(f"    {at} UTC  {entry['confirmationStatus']:<9}  {delta / 1e6:+.6f}  {entry['signature'][:20]}…" + ("  (failed)" if meta["err"] is not None else ""))
        time.sleep(0.5)
    else:
        check("getTransaction (jsonParsed) carries meta.err and token balances with owner, mint and uiTokenAmount.amount", read > 0, read)

    print("ALL PASSED" if all(RESULTS) else "SOME FAILED")
    return 0 if all(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
