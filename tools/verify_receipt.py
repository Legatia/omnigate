#!/usr/bin/env python3
"""Check a receipt from omnigate against the bytes it is about, offline.

A receipt (`GET /v1/attestations/<request id>`, or "Download receipt" on the
Private chat page) says: this request body and this response body, exactly,
were signed by this key. This script checks that claim with nothing but the
receipt and the two bodies:

    python tools/verify_receipt.py receipt.json request.bin response.bin

  1. the SHA-256 of `request.bin` and of `response.bin` are the hashes in the
     receipt (the bodies as they crossed the wire: the request as the gateway
     sent it to the provider, the response as the provider sent it back,
     every byte, for a stream every event and blank line);
  2. the signed text is exactly `<model>:<request hash>:<response hash>` for
     a signature by the model's machine (`provider_tee`), or
     `<request hash>:<response hash>` for one by the provider's gateway
     (`gateway`);
  3. the Ed25519 signature over that text verifies under the key the receipt
     names.

It prints VERIFIED and exits 0 only if all three hold; otherwise NOT VERIFIED
with the reason and exit status 1. Without the two files it checks 2 and 3
against the hashes in the receipt and says that the bodies were not checked.

What it cannot check: that the signing key belongs to a machine in a
trusted execution environment. That is what the gateway verified before the
request (the receipt's `attestation` part names the reports and when they
were checked), from a quote signed by the processor; checking it again takes
the provider's attestation report, which is public: `python
tools/near_live.py` fetches and verifies one and prints the signing keys, to
compare with `signature.signing_address` here (pass `--signer <hex>` to have
this script compare).

Standard library only. The Ed25519 verification is RFC 8032's reference
arithmetic; `--self-test` runs it against the RFC's test vectors.
"""
import argparse
import hashlib
import json
import sys

# ---- Ed25519 verification (RFC 8032, section 6) ------------------------------

P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    A, B = (y1 - x1) * (y2 - x2) % P, (y1 + x1) * (y2 + x2) % P
    C, Dd = 2 * t1 * t2 * D % P, 2 * z1 * z2 % P
    E, F, G, H = B - A, Dd - C, Dd + C, B + A
    return E * F % P, G * H % P, F * G % P, E * H % P


def _mul(s, point):
    q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            q = _add(q, point)
        point = _add(point, point)
        s >>= 1
    return q


def _equal(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % P == 0 and (a[1] * b[2] - b[1] * a[2]) % P == 0


def _decompress(raw):
    if len(raw) != 32:
        return None
    y = int.from_bytes(raw, "little")
    sign, y = y >> 255, y & ((1 << 255) - 1)
    if y >= P:
        return None
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    if x2 == 0:
        return None if sign else (0, y, 1, 0)
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P != 0:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P != 0:
        return None
    if (x & 1) != sign:
        x = P - x
    return x, y, 1, x * y % P


BASE = _decompress((4 * pow(5, P - 2, P) % P).to_bytes(32, "little"))


def ed25519_verify(public_key, message, signature):
    """True only for a valid Ed25519 signature (RFC 8032)."""
    if len(public_key) != 32 or len(signature) != 64:
        return False
    a, r = _decompress(public_key), _decompress(signature[:32])
    s = int.from_bytes(signature[32:], "little")
    if a is None or r is None or s >= L:
        return False
    h = int.from_bytes(hashlib.sha512(signature[:32] + public_key + message).digest(), "little") % L
    return _equal(_mul(s, BASE), _add(r, _mul(h, a)))


# RFC 8032, section 7.1: (public key, message, signature), hexadecimal.
VECTORS = [
    ("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
     "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
    ("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
     "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
    ("fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
     "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
]


def self_test():
    ok = True
    for public, message, signature in VECTORS:
        pk, msg, sig = bytes.fromhex(public), bytes.fromhex(message), bytes.fromhex(signature)
        good = ed25519_verify(pk, msg, sig)
        flipped = bytearray(sig)
        flipped[5] ^= 1
        bad = ed25519_verify(pk, msg, bytes(flipped)) or ed25519_verify(pk, msg + b"x", sig)
        print(("  PASS  " if good and not bad else "  FAIL  ") + f"RFC 8032 vector, message {message or '(empty)'}: verifies, and not when altered")
        ok = ok and good and not bad
    return ok


# ---- The receipt -------------------------------------------------------------

def unprefixed(text):
    return text[2:] if text[:2].lower() == "0x" else text


def check(receipt, request=None, response=None, signer=None):
    """(verified, list of lines saying what was checked or what failed)."""
    lines = []
    sig = receipt.get("signature")
    if not isinstance(sig, dict) or not all(isinstance(sig.get(k), str) for k in ("text", "signature", "signing_address")):
        return False, [f"the receipt carries no signature (the gateway's verdict was {receipt.get('verdict')!r}: {receipt.get('reason')})"]
    if sig.get("signing_algo") != "ed25519":
        return False, [f"signing algorithm {sig.get('signing_algo')!r} is not one this script verifies (ed25519 only)"]

    hashes = {}
    for name, data in (("request", request), ("response", response)):
        claimed = receipt.get(name + "_sha256")
        if not isinstance(claimed, str) or len(claimed) != 64:
            return False, [f"the receipt has no {name}_sha256"]
        if data is not None:
            actual = hashlib.sha256(data).hexdigest()
            if actual != claimed:
                return False, [f"the {name} body is not the one the receipt is about: its SHA-256 is {actual}, the receipt says {claimed}"]
            lines.append(f"the {name} body ({len(data)} bytes) has the SHA-256 the receipt names, {claimed[:16]}...")
        hashes[name] = claimed

    kind, model = sig.get("kind"), receipt.get("model")
    pair = hashes["request"] + ":" + hashes["response"]
    if kind == "provider_tee":
        expected = f"{model}:{pair}"
    elif kind == "gateway":
        expected = pair
    else:
        return False, [f"the receipt does not say who signed in a way this script knows (kind {kind!r})"]
    if sig["text"] != expected:
        return False, [f"the signed text is not the hashes of this request and response: signed {sig['text']!r}, expected {expected!r}"]
    lines.append("the signed text is exactly " + ("<model>:<request hash>:<response hash>" if kind == "provider_tee" else "<request hash>:<response hash>"))

    try:
        key = bytes.fromhex(unprefixed(sig["signing_address"]))
        signature = bytes.fromhex(unprefixed(sig["signature"]))
    except ValueError:
        return False, ["the signature or the key in the receipt is not hexadecimal"]
    if not ed25519_verify(key, sig["text"].encode(), signature):
        return False, ["the Ed25519 signature does not verify under the key the receipt names"]
    who = "the model's machine" if kind == "provider_tee" else "the provider's gateway"
    lines.append(f"the Ed25519 signature verifies under {sig['signing_address'][:16]}... ({who})")

    if signer is not None:
        if unprefixed(signer).lower() != unprefixed(sig["signing_address"]).lower():
            return False, [f"the signature's key is {sig['signing_address']}, not the expected {signer}"]
        lines.append("that key is the one given with --signer")
    return True, lines


def main():
    parser = argparse.ArgumentParser(description="Check an omnigate receipt against the request and response bodies it is about.")
    parser.add_argument("receipt", nargs="?", help="the receipt, a JSON file")
    parser.add_argument("request", nargs="?", help="the request body as the gateway sent it to the provider")
    parser.add_argument("response", nargs="?", help="the response body as the provider sent it")
    parser.add_argument("--signer", help="the signing key expected (hexadecimal), e.g. from a freshly verified attestation report")
    parser.add_argument("--self-test", action="store_true", help="run the Ed25519 code against RFC 8032's test vectors and exit")
    args = parser.parse_args()

    if args.self_test:
        sys.exit(0 if self_test() else 1)
    if not args.receipt:
        parser.error("a receipt file is required")
    if bool(args.request) != bool(args.response):
        parser.error("give both the request and the response body, or neither")

    with open(args.receipt, encoding="utf-8") as f:
        receipt = json.load(f)

    def read(path):
        if not path:
            return None
        with open(path, "rb") as body:
            return body.read()

    ok, lines = check(receipt, read(args.request), read(args.response), args.signer)
    for line in lines:
        print(("  ok    " if ok else "  FAIL  ") + line)
    if ok and not args.request:
        print("  note  the bodies were not given: the signature is valid for the hashes in the receipt, whatever bytes those are")
    att = receipt.get("attestation") or {}
    signed = next((r for r in att.get("reports") or [] if r.get("signed_this_answer")), None)
    if ok and signed:
        print(f"  note  the gateway matched this key to the {signed.get('role')} report it verified at {att.get('verified_at')} "
              f"(platform status {signed.get('tcb_status')}); this script cannot check that part offline")
    print("VERIFIED" if ok else "NOT VERIFIED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
