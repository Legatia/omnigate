#!/usr/bin/env python3
"""A stand-in for the NEAR Intents 1Click API, for the tests of omnigate's payments.

    python tools/mock_intents.py [port]        (default 9120)

It answers the three calls the gateway makes (GET /v0/tokens, POST /v0/quote,
GET /v0/status) and POST /v0/deposit/submit, in the shapes the real service
answered on 11 November 2026, and signs its quotes the way the real one does
(Ed25519 over the Base58 of the SHA-256 of the signed fields) with a key of
its own: PUBLIC_KEY below goes into the gateway's `payments.public_key`.

Nothing here moves anything. A test says what happened to a quote's deposit
address with the control calls under /__mock:

    POST /__mock/deposit   {"depositAddress": "...", "outcome": "success" | "partial" | "refund" | "fail",
                            "amountOut": "<units>" (optional), "steps": true (optional: pass through
                            KNOWN_DEPOSIT_TX and PROCESSING first)}
    POST /__mock/tamper    {"depositAddress": "...", "what": "recipient" | "signature" | "address" | null}
    POST /__mock/quotes    {"mode": "bad_signature" | "wrong_recipient" | "wrong_amount" | null}
    GET  /__mock/seen      what was asked: quote requests and status calls per deposit address
"""
import hashlib
import json
import os
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_receipt as ed  # Ed25519 arithmetic (RFC 8032), standard library only

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fastbind  # noqa: E402,F401  (servers start without a DNS lookup)

USDC = "nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1"
TOKENS = [
    {"assetId": "nep141:wrap.near", "decimals": 24, "blockchain": "near", "symbol": "wNEAR", "price": 3.7, "contractAddress": "wrap.near"},
    {"assetId": USDC, "decimals": 6, "blockchain": "near", "symbol": "USDC", "price": 0.9997, "contractAddress": USDC.split(":")[1]},
    {"assetId": "nep141:eth.omft.near", "decimals": 18, "blockchain": "eth", "symbol": "ETH", "price": 2080.0, "contractAddress": None},
    {"assetId": "nep141:btc.omft.near", "decimals": 8, "blockchain": "btc", "symbol": "BTC", "price": 74000.0, "contractAddress": None},
    # Bitcoin is listed twice by the real service, and a quote asked for under
    # the id above is signed as if it had been asked for under this one.
    {"assetId": "1cs_v1:btc:native:coin", "decimals": 8, "blockchain": "btc", "symbol": "BTC(OMNI)", "price": 74000.0, "contractAddress": None},
    {"assetId": "nep141:sol.omft.near", "decimals": 9, "blockchain": "sol", "symbol": "SOL", "price": 150.0, "contractAddress": None},
    {"assetId": "nep141:bsc.omft.near", "decimals": 18, "blockchain": "bsc", "symbol": "BNB", "price": 600.0, "contractAddress": None},
    {"assetId": "nep141:tron-d28a265909efecdcee7c5028585214ea0b96f015.omft.near", "decimals": 6, "blockchain": "tron", "symbol": "USDT", "price": 0.999,
     "contractAddress": "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"},
    {"assetId": "nep141:stellar.omft.near", "decimals": 7, "blockchain": "stellar", "symbol": "XLM", "price": 0.25, "contractAddress": None},
    # Listed without the fields the gateway needs: it must be left out, not crash the listing.
    {"symbol": "BROKEN"},
]

# ---- Ed25519 signing (the verifier's arithmetic, used the other way round) ----

ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58(data):
    n, out = int.from_bytes(data, "big"), ""
    while n:
        n, r = divmod(n, 58)
        out = ALPHABET[r] + out
    return "1" * (len(data) - len(data.lstrip(b"\0"))) + out


def _compress(point):
    x, y, z, _ = point
    zinv = pow(z, ed.P - 2, ed.P)
    x, y = x * zinv % ed.P, y * zinv % ed.P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def keypair(seed):
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:], _compress(ed._mul(a, ed.BASE))


def sign(seed, message):
    a, prefix, public = keypair(seed)
    r = int.from_bytes(hashlib.sha512(prefix + message).digest(), "little") % ed.L
    big_r = _compress(ed._mul(r, ed.BASE))
    h = int.from_bytes(hashlib.sha512(big_r + public + message).digest(), "little") % ed.L
    return big_r + ((r + h * a) % ed.L).to_bytes(32, "little")


SEED = hashlib.sha256(b"omnigate mock 1Click manager key, for tests only").digest()
PUBLIC_KEY = b58(keypair(SEED)[2])


def signed_text(answer):
    """What 1Click signs for a quote answer (quoteHash in its TypeScript SDK)."""
    request, quote = answer["quoteRequest"], answer["quote"]
    fields = {k: request.get(k) for k in ("dry", "swapType", "slippageTolerance", "originAsset", "depositType", "destinationAsset", "amount",
                                          "refundTo", "refundType", "recipient", "recipientType", "deadline")}
    for k in ("quoteWaitingTimeMs", "referral", "virtualChainRecipient", "virtualChainRefundRecipient", "customRecipientMsg"):
        if request.get(k):
            fields[k] = request[k]
    for k in ("amountIn", "amountInFormatted", "amountInUsd", "minAmountIn", "amountOut", "amountOutFormatted", "amountOutUsd", "minAmountOut"):
        fields[k] = quote.get(k)
    if not request.get("dry"):
        for k in ("depositAddress", "depositMemo", "deadline", "timeWhenInactive", "timeEstimate", "refundFee", "withdrawFee"):
            if quote.get(k):
                fields[k] = quote[k]
    fields["timestamp"] = answer["timestamp"]
    fields = {k: v for k, v in fields.items() if v is not None}
    text = json.dumps(fields, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return b58(hashlib.sha256(text.encode()).digest())


def sign_answer(answer):
    answer["signature"] = "ed25519:" + b58(sign(SEED, signed_text(answer).encode()))
    return answer


# ---- State ------------------------------------------------------------------

LOCK = threading.Lock()
QUOTES = {}      # deposit address -> {"answer": quote answer, "statuses": [...], "details": {...}, "tamper": None, "asked": 0}
SEEN = {"quotes": [], "submitted": []}
QUOTE_MODE = {"mode": None}


def now_iso():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + "000Z"


def fmt(units, decimals):
    text = str(units).rjust(decimals + 1, "0")
    whole, frac = text[:-decimals] if decimals else text, text[-decimals:] if decimals else ""
    return whole + ("." + frac if frac else "")


def make_quote(body):
    """(status, answer) for POST /v0/quote."""
    token = next((t for t in TOKENS if t.get("assetId") == body.get("originAsset")), None)
    refund = body.get("refundTo")
    if body.get("swapType") != "EXACT_OUTPUT" or body.get("depositType") != "ORIGIN_CHAIN" or body.get("recipientType") != "DESTINATION_CHAIN":
        return 400, {"message": "this mock only quotes EXACT_OUTPUT from ORIGIN_CHAIN to DESTINATION_CHAIN"}
    if token is None:
        return 400, {"message": "tokenIn is not valid"}
    if body.get("destinationAsset") != USDC:
        return 400, {"message": "tokenOut is not valid"}
    if not isinstance(refund, str) or not refund or "invalid" in refund:
        return 400, {"message": "refundTo is not valid"}
    if not isinstance(body.get("amount"), str) or not body["amount"].isdigit():
        return 400, {"message": "amount must be a number string"}
    usd = int(body["amount"]) / 10**6
    if token["blockchain"] == "bsc" and usd < 1000:
        return 400, {"message": "Temporary swap limits: minimum swap amount is $1,000"}
    if token["blockchain"] == "tron" and usd < 100:
        return 400, {"message": "Temporary swap limits: minimum swap amount is $100"}
    if token["blockchain"] == "btc" and usd < 2:
        return 400, {"message": "Amount is too low for bridge, try at least 20000"}

    slippage = (body.get("slippageTolerance") or 0) / 10_000
    needed = int(usd / token["price"] * 10 ** token["decimals"])
    amount_in = int(needed * (1 + slippage))
    quote = {
        "amountIn": str(amount_in), "amountInFormatted": fmt(amount_in, token["decimals"]), "amountInUsd": f"{usd * (1 + slippage):.12f}",
        "minAmountIn": str(needed), "amountOut": body["amount"], "amountOutFormatted": fmt(int(body["amount"]), 6),
        "amountOutUsd": f"{usd * 0.9997:.12f}", "minAmountOut": body["amount"], "timeEstimate": 20, "refundFee": "0", "withdrawFee": "4652",
    }
    request = dict(body, depositMode="MEMO" if token["blockchain"] == "stellar" else "SIMPLE", confidentiality="public", quoteWaitingTimeMs=0, insured=False,
                   appFees=[{"recipient": "5880ad2b362620fadf759cbceb1cd5737ce8c6ed7fb8e9942881e6731f9247dd", "fee": 25}])
    mode = QUOTE_MODE["mode"]
    if mode == "wrong_recipient":
        request["recipient"] = "someone-else.near"
    if mode == "wrong_amount":
        quote["amountOut"] = str(int(body["amount"]) - 1)
    if not body.get("dry"):
        address = secrets.token_hex(32) if token["blockchain"] == "near" else "0x" + secrets.token_hex(20)
        quote.update({"depositAddress": address, "deadline": body.get("deadline"), "timeWhenInactive": body.get("deadline")})
        if token["blockchain"] == "stellar":
            quote["depositMemo"] = str(secrets.randbelow(10**8))
    answer = sign_answer({"quote": quote, "quoteRequest": request, "timestamp": now_iso(), "correlationId": secrets.token_hex(8)})
    if body.get("originAsset") == "nep141:btc.omft.near":
        canonical = json.loads(json.dumps(answer))
        canonical["quoteRequest"]["originAsset"] = "1cs_v1:btc:native:coin"
        answer["signature"] = sign_answer(canonical)["signature"]
    if mode == "bad_signature":
        answer["signature"] = "ed25519:" + b58(sign(hashlib.sha256(b"another key").digest(), signed_text(answer).encode()))
    if not body.get("dry"):
        QUOTES[quote["depositAddress"]] = {"answer": answer, "statuses": ["PENDING_DEPOSIT"], "details": {}, "tamper": None, "asked": 0}
    return 201, answer


def status_of(address, memo):
    entry = QUOTES.get(address)
    if entry is None or (entry["answer"]["quote"].get("depositMemo") and entry["answer"]["quote"]["depositMemo"] != memo):
        return 404, {"message": f"Deposit address {address} not found", "error": "Not Found", "statusCode": 404}
    entry["asked"] += 1
    status = entry["statuses"][0]
    if len(entry["statuses"]) > 1:
        entry["statuses"].pop(0)
    answer = json.loads(json.dumps(entry["answer"]))
    if entry["tamper"] == "recipient":
        answer["quoteRequest"]["recipient"] = "someone-else.near"
        sign_answer(answer)
    elif entry["tamper"] == "signature":
        answer["quote"]["amountIn"] = "1"
    elif entry["tamper"] == "address":
        answer["quote"]["depositAddress"] = "0x" + "00" * 20
        sign_answer(answer)
    details = {"intentHashes": [], "nearTxHashes": [], "originChainTxHashes": [], "destinationChainTxHashes": []}
    if status in ("SUCCESS", "REFUNDED"):
        details.update(entry["details"])
    return 200, {"correlationId": secrets.token_hex(8), "quoteResponse": answer, "status": status, "updatedAt": now_iso(), "swapDetails": details}


def deposit(body):
    entry = QUOTES.get(body.get("depositAddress"))
    if entry is None:
        return 404, {"message": "no such quote"}
    quote = entry["answer"]["quote"]
    steps = ["KNOWN_DEPOSIT_TX", "PROCESSING"] if body.get("steps") else []
    outcome = body.get("outcome", "success")
    if outcome == "success":
        entry["statuses"] = steps + ["SUCCESS"]
        entry["details"] = {"amountIn": quote["minAmountIn"], "amountOut": body.get("amountOut", quote["amountOut"]),
                            "amountOutFormatted": fmt(int(body.get("amountOut", quote["amountOut"])), 6),
                            "destinationChainTxHashes": [{"hash": "MockNearTx" + secrets.token_hex(8), "explorerUrl": "https://example.invalid/tx"}],
                            "originChainTxHashes": [{"hash": "0x" + secrets.token_hex(16), "explorerUrl": "https://example.invalid/tx"}]}
    elif outcome == "partial":
        entry["statuses"] = ["INCOMPLETE_DEPOSIT"]
    elif outcome == "refund":
        entry["statuses"] = steps + ["REFUNDED"]
        entry["details"] = {"refundedAmount": quote["amountIn"], "refundReason": "PARTIAL_DEPOSIT"}
    elif outcome == "fail":
        entry["statuses"] = steps + ["FAILED"]
    else:
        return 400, {"message": "unknown outcome"}
    return 200, {"ok": True}


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

    def body(self):
        try:
            return json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)) or b"{}")
        except ValueError:
            return None

    def do_GET(self):
        from urllib.parse import urlparse, parse_qs
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        with LOCK:
            if url.path == "/v0/tokens":
                return self.answer(200, TOKENS)
            if url.path == "/v0/status":
                return self.answer(*status_of(query.get("depositAddress"), query.get("depositMemo")))
            if url.path == "/__mock/seen":
                return self.answer(200, dict(SEEN, asked={k: v["asked"] for k, v in QUOTES.items()}, authorization=SEEN.get("authorization")))
        self.answer(404, {"message": "not found"})

    def do_POST(self):
        body = self.body()
        if body is None:
            return self.answer(400, {"message": "body is not JSON"})
        with LOCK:
            if self.path == "/v0/quote":
                SEEN["quotes"].append(body)
                SEEN["authorization"] = self.headers.get("authorization")
                return self.answer(*make_quote(body))
            if self.path == "/v0/deposit/submit":
                SEEN["submitted"].append(body)
                return self.answer(200 if body.get("depositAddress") in QUOTES else 404, {"ok": body.get("depositAddress") in QUOTES})
            if self.path == "/__mock/deposit":
                return self.answer(*deposit(body))
            if self.path == "/__mock/tamper":
                entry = QUOTES.get(body.get("depositAddress"))
                if entry is None:
                    return self.answer(404, {"message": "no such quote"})
                entry["tamper"] = body.get("what")
                return self.answer(200, {"ok": True})
            if self.path == "/__mock/quotes":
                QUOTE_MODE["mode"] = body.get("mode")
                return self.answer(200, {"ok": True})
        self.answer(404, {"message": "not found"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9120
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"mock 1Click on 127.0.0.1:{port}; signing key ed25519:{PUBLIC_KEY}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
