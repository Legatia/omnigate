#!/usr/bin/env python3
"""A stand-in for a Solana JSON-RPC endpoint, for the tests of omnigate's `solana` payments.

    python tools/mock_solana.py [port]        (default 9121)

It answers the three methods the gateway calls (getSignaturesForAddress,
getTransaction with jsonParsed encoding, getTokenAccountsByOwner) in the
shapes the public mainnet endpoint answered on 14 November 2026, cut down to
the fields the gateway reads.

Nothing here moves anything. A test puts a transaction on this chain with the
control calls under /__mock:

    POST /__mock/land      {"addresses": ["..."], "owner": "...", "mint": "...", "units": 5004217,
                            "status": "finalized" | "confirmed" (default finalized),
                            "failed": true (optional), "age_s": 0 (optional: how long ago)}
                           -> {"signature": "..."}: a transaction that the given addresses are part of
                           and that moves `units` of `mint` to a token account owned by `owner`
    POST /__mock/finalize  {}   every transaction becomes final
    POST /__mock/accounts  {"accounts": ["..."]}   the token accounts every wallet is said to have
    GET  /__mock/seen      how often each method was called
"""
import json
import os
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fastbind  # noqa: E402,F401  (servers start without a DNS lookup)

ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
# The token account every wallet has here until a test says otherwise.
TOKEN_ACCOUNT = "7UX2i7SucgLMQcfZ75s3VXmZZY4YRUyJN9X1RgfMoDUi"

LOCK = threading.Lock()
SIGNATURES = {}  # address -> entries, newest first
TRANSACTIONS = {}
ACCOUNTS = [TOKEN_ACCOUNT]
SEEN = {}


def b58(data):
    n, out = int.from_bytes(data, "big"), ""
    while n:
        n, r = divmod(n, 58)
        out = ALPHABET[r] + out
    return "1" * (len(data) - len(data.lstrip(b"\0"))) + out


def balance(index, owner, mint, units):
    return {"accountIndex": index, "mint": mint, "owner": owner, "programId": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
            "uiTokenAmount": {"amount": str(units), "decimals": 6, "uiAmount": units / 1e6, "uiAmountString": str(units / 1e6)}}


def land(body):
    signature = b58(secrets.token_bytes(64))
    at = int(time.time()) - int(body.get("age_s", 0))
    err = {"InstructionError": [0, {"Custom": 1}]} if body.get("failed") else None
    owner, mint, units = body.get("owner"), body.get("mint"), int(body.get("units", 0))
    entry = {"signature": signature, "slot": 300000000 + len(TRANSACTIONS), "err": err, "memo": None, "blockTime": at,
             "confirmationStatus": body.get("status", "finalized")}
    TRANSACTIONS[signature] = {
        "slot": entry["slot"], "blockTime": at, "version": 0,
        "meta": {"err": err, "fee": 5000,
                 "preTokenBalances": [balance(1, "PayerWa11et1111111111111111111111111111111111", mint, 900000000), balance(2, owner, mint, 250000)],
                 "postTokenBalances": [balance(1, "PayerWa11et1111111111111111111111111111111111", mint, 900000000 - units), balance(2, owner, mint, 250000 + units)]},
        "transaction": {"signatures": [signature], "message": {"accountKeys": [{"pubkey": a, "signer": False, "writable": False} for a in body.get("addresses", [])]}},
    }
    for address in body.get("addresses", []):
        SIGNATURES.setdefault(address, []).insert(0, entry)
    return 200, {"signature": signature}


def rpc(body):
    method, params = body.get("method"), body.get("params") or []
    SEEN[method] = SEEN.get(method, 0) + 1
    if method == "getSignaturesForAddress" and params:
        limit = (params[1] if len(params) > 1 else {}).get("limit", 1000)
        return {"result": SIGNATURES.get(params[0], [])[:limit]}
    if method == "getTransaction" and params:
        return {"result": TRANSACTIONS.get(params[0])}
    if method == "getTokenAccountsByOwner" and params:
        return {"result": {"context": {"slot": 300000000}, "value": [{"pubkey": a, "account": {"owner": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"}} for a in ACCOUNTS]}}
    return {"error": {"code": -32601, "message": "Method not found"}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def answer(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        with LOCK:
            if self.path == "/__mock/seen":
                return self.answer(200, dict(SEEN))
        self.answer(404, {"message": "not found"})

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)) or b"{}")
        except ValueError:
            return self.answer(400, {"message": "body is not JSON"})
        with LOCK:
            if self.path == "/":
                return self.answer(200, dict({"jsonrpc": "2.0", "id": body.get("id")}, **rpc(body)))
            if self.path == "/__mock/land":
                return self.answer(*land(body))
            if self.path == "/__mock/finalize":
                for entries in SIGNATURES.values():
                    for entry in entries:
                        entry["confirmationStatus"] = "finalized"
                return self.answer(200, {"ok": True})
            if self.path == "/__mock/accounts":
                ACCOUNTS[:] = body.get("accounts", [])
                return self.answer(200, {"ok": True})
        self.answer(404, {"message": "not found"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9121
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"mock Solana RPC on 127.0.0.1:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
