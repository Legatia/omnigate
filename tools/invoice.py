#!/usr/bin/env python3
"""Payment requests in USDC on Solana for things you sell by hand (a commercial license), and a check of whether they were paid.

    python tools/invoice.py new --wallet ADDRESS --usd 490 --to "Acme GmbH" [--for TEXT] [--days 30] [--seller TEXT]
    python tools/invoice.py check [NUMBER ...]         ask the chain about the open ones (or the ones named)
    python tools/invoice.py list
    python tools/invoice.py show NUMBER                the text of one, again
    python tools/invoice.py paid NUMBER --tx SIGNATURE  a transfer made without the link: read it on the chain and mark the invoice
    python tools/invoice.py void NUMBER

`new` gives the invoice a number and a reference of its own (32 random bytes,
written like an address) and builds a Solana Pay link from it: a wallet that
opens the link or scans its QR code sends the amount to your wallet and
names the reference in the transfer. `check` asks a Solana RPC endpoint for
final transactions that name the reference and reads from each how much of
the token your wallet gained. An invoice is paid when that reaches its
amount. It is the same reading the gateway's `solana` payment provider does
(docs/payments.md); the two do not know of each other.

`new` also writes NUMBER.html next to the invoice file: the request as a page
with the QR code, to send or print. It is a request for payment. Whether it
is an invoice in the sense of your tax law depends on what that law wants on
one; put it in --seller and --for.

Nothing here holds a key, signs or sends anything. The invoices are kept in
one JSON file (--file, or OMNIGATE_INVOICES, default ./invoices.json). It
names your customers: keep it out of a public repository.

The RPC endpoint (--rpc, or OMNIGATE_SOLANA_RPC, default Solana's public
mainnet endpoint) is believed: use one you trust.

Standard library only.
"""
import argparse
import datetime
import html
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

USDC = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
RPC = "https://api.mainnet-beta.solana.com"
ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


# ---- Base58 -------------------------------------------------------------------------

def b58encode(data):
    n, out = int.from_bytes(data, "big"), ""
    while n:
        n, r = divmod(n, 58)
        out = ALPHABET[r] + out
    return "1" * (len(data) - len(data.lstrip(b"\0"))) + out


def b58decode(text):
    n = 0
    for ch in text:
        if ch not in ALPHABET:
            raise ValueError("not Base58")
        n = n * 58 + ALPHABET.index(ch)
    zeros = len(text) - len(text.lstrip("1"))
    return b"\0" * zeros + (n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b"")


def is_bytes58(text, size):
    try:
        return isinstance(text, str) and len(b58decode(text)) == size
    except ValueError:
        return False


# ---- The file -----------------------------------------------------------------------

def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            book = json.load(f)
    except FileNotFoundError:
        return {"version": 1, "invoices": []}
    if not isinstance(book, dict) or not isinstance(book.get("invoices"), list):
        sys.exit(f"{path} is not an invoice file")
    return book


def save(path, book):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(book, f, indent=2, ensure_ascii=False)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def find(book, number):
    for invoice in book["invoices"]:
        if invoice["number"].lower() == number.lower():
            return invoice
    sys.exit(f"no invoice {number}")


def formatted(units, decimals):
    scale = 10 ** decimals
    fraction = str(units % scale).rjust(decimals, "0").rstrip("0").ljust(2, "0")
    return f"{units // scale}.{fraction}"


# ---- The chain ----------------------------------------------------------------------

def rpc(url, method, params, tries=4):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    for attempt in range(tries):
        req = urllib.request.Request(url, data=body, headers={"content-type": "application/json", "accept": "application/json", "user-agent": "omnigate-invoice"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                answer = json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt + 1 < tries:
                time.sleep(3 * (attempt + 1))
                continue
            raise RuntimeError(f"{method}: HTTP {e.code} from the RPC endpoint")
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise RuntimeError(f"{method}: the RPC endpoint could not be asked ({e})")
        if "error" in answer:
            raise RuntimeError(f"{method}: {str(answer['error'])[:200]}")
        return answer.get("result")


def owned(balances, wallet, mint):
    total = 0
    for b in balances or []:
        amount = (b.get("uiTokenAmount") or {}).get("amount")
        if b.get("owner") == wallet and b.get("mint") == mint and isinstance(amount, str) and amount.isdigit():
            total += int(amount)
    return total


def gained(url, signature, wallet, mint):
    """What a final transaction moved to the wallet: (units, block time), or None for one that is not there, not final, or failed."""
    tx = rpc(url, "getTransaction", [signature, {"encoding": "jsonParsed", "commitment": "finalized", "maxSupportedTransactionVersion": 1}])
    meta = (tx or {}).get("meta")
    if not isinstance(meta, dict) or meta.get("err") is not None:
        return None
    return owned(meta.get("postTokenBalances"), wallet, mint) - owned(meta.get("preTokenBalances"), wallet, mint), tx.get("blockTime")


def used(book, signature, but=None):
    for other in book["invoices"]:
        if other is not but and signature in [p["signature"] for p in other.get("payments", [])]:
            return other["number"]
    return None


def credit(book, invoice, signature, units, at):
    """Add one transfer to an invoice; True when that pays it."""
    if signature not in [p["signature"] for p in invoice.setdefault("payments", [])]:
        invoice["payments"].append({"signature": signature, "units": units, "at": at})
    received = sum(p["units"] for p in invoice["payments"])
    if received >= invoice["units"] and invoice["status"] == "open":
        invoice["status"] = "paid"
        invoice["paid_at"] = max((p["at"] or 0) for p in invoice["payments"]) or int(time.time())
        return True
    return False


def check_one(url, book, invoice):
    """Look for final transfers that name the invoice's reference. Returns a line to print."""
    entries = rpc(url, "getSignaturesForAddress", [invoice["reference"], {"limit": 25, "commitment": "finalized"}]) or []
    for entry in reversed(entries):
        signature = entry.get("signature")
        if entry.get("err") is not None or not isinstance(signature, str) or used(book, signature):
            continue
        moved = gained(url, signature, invoice["wallet"], invoice["mint"])
        if moved and moved[0] > 0:
            credit(book, invoice, signature, moved[0], moved[1])
    return line(invoice)


def line(invoice):
    received = sum(p["units"] for p in invoice.get("payments", []))
    amount = f"{formatted(invoice['units'], invoice['decimals'])} {invoice['symbol']}"
    state = invoice["status"]
    if state == "open" and received:
        state = f"open, {formatted(received, invoice['decimals'])} of it received"
    elif state == "open" and invoice.get("due") and invoice["due"] < datetime.date.today().isoformat():
        state = "open, past due"
    elif state == "paid":
        state = "paid " + time.strftime("%Y-%m-%d", time.gmtime(invoice.get("paid_at") or 0))
        if received > invoice["units"]:
            state += f" ({formatted(received, invoice['decimals'])} received)"
    return f"{invoice['number']}  {amount:>16}  {state:<34}  {invoice['to']}"


# ---- The request as text and as a page ------------------------------------------------

def as_text(invoice):
    amount = f"{formatted(invoice['units'], invoice['decimals'])} {invoice['symbol']}"
    rows = [f"Invoice {invoice['number']}", f"Date: {invoice['date']}" + (f"    Due: {invoice['due']}" if invoice.get("due") else "")]
    if invoice.get("seller"):
        rows += ["", "From: " + invoice["seller"]]
    rows += ["To:   " + invoice["to"], "", f"For:  {invoice['what']}", f"Amount: {amount} (USD {formatted(invoice['units'], invoice['decimals'])}), on Solana", "",
             "To pay, open this link in a Solana wallet or scan the QR code of the attached page:", "", "  " + invoice["url"], "",
             "The link fills in the amount and a reference that tells us the payment is yours.",
             f"Paying by hand instead: send exactly {amount} to", "", "  " + invoice["wallet"], "",
             "and send us the signature of the transaction, so that we can find it."]
    return "\n".join(rows)


def as_page(invoice):
    e = html.escape
    amount = f"{formatted(invoice['units'], invoice['decimals'])} {invoice['symbol']}"
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Invoice {e(invoice['number'])}</title><style>
body{{font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;color:#16181d;background:#fff;margin:0;padding:32px 16px}}
main{{max-width:680px;margin:0 auto}}h1{{font-size:26px;margin:0 0 4px}}.muted{{color:#5c6470}}
dl{{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:6px 20px;margin:24px 0}}dt{{color:#5c6470}}dd{{margin:0;overflow-wrap:anywhere}}
.amount{{font-size:22px;font-weight:650}}.pay{{display:flex;flex-wrap:wrap;gap:24px;align-items:flex-start;border-top:1px solid #d9dde3;padding-top:24px}}
.pay svg{{width:220px;height:220px;flex:0 0 auto}}.pay div{{flex:1 1 280px;min-width:0}}code{{font:13.5px ui-monospace,Consolas,monospace;overflow-wrap:anywhere}}
p{{margin:0 0 12px}}@media print{{body{{padding:0}}a{{color:inherit}}}}
</style></head><body><main>
<h1>Invoice {e(invoice['number'])}</h1><div class="muted">{e(invoice['date'])}{' · due ' + e(invoice['due']) if invoice.get('due') else ''}</div>
<dl>{'<dt>From</dt><dd>' + e(invoice['seller']) + '</dd>' if invoice.get('seller') else ''}<dt>To</dt><dd>{e(invoice['to'])}</dd>
<dt>For</dt><dd>{e(invoice['what'])}</dd><dt>Amount</dt><dd><span class="amount">{e(amount)}</span> <span class="muted">on Solana</span></dd></dl>
<div class="pay">{qr_svg(invoice['url'])}<div>
<p><b>To pay,</b> scan the code with a Solana wallet, or <a href="{e(invoice['url'])}">open the payment link</a> on a device that has one.
It fills in the amount and a reference that tells us the payment is yours.</p>
<p><b>Paying by hand instead:</b> send exactly {e(amount)} to</p><p><code>{e(invoice['wallet'])}</code></p>
<p>and send us the signature of the transaction, so that we can find it.</p></div></div>
</main></body></html>
"""


# ---- A QR code (byte mode, error correction level M, versions 1 to 9: up to 180 bytes) ------
# The same construction as the gateway's top-up page (control/lib/omnigate_control/topup_page.ex).

_V = [None, (26, 10, 1, 16, 0, 0), (44, 16, 1, 28, 0, 0), (70, 26, 1, 44, 0, 0), (100, 18, 2, 32, 0, 0), (134, 24, 2, 43, 0, 0),
      (172, 16, 4, 27, 0, 0), (196, 18, 4, 31, 0, 0), (242, 22, 2, 38, 2, 39), (292, 22, 3, 36, 2, 37)]
_AL = [None, [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46]]


def _mul(x, y):
    z = 0
    for i in range(7, -1, -1):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z


def _divisor(degree):
    r, root = [0] * (degree - 1) + [1], 1
    for _ in range(degree):
        for j in range(degree):
            r[j] = _mul(r[j], root)
            if j + 1 < degree:
                r[j] ^= r[j + 1]
        root = _mul(root, 2)
    return r


def _remainder(data, divisor):
    r = [0] * len(divisor)
    for b in data:
        f = b ^ r.pop(0)
        r.append(0)
        for i, c in enumerate(divisor):
            r[i] ^= _mul(c, f)
    return r


def qr_matrix(text):
    """The modules of the QR code for `text`, as rows of booleans; None when it is too long."""
    data_in = text.encode("utf-8")
    for v in range(1, 10):
        spec = _V[v]
        cap = spec[2] * spec[3] + spec[4] * spec[5]
        if len(data_in) + 2 <= cap:
            break
    else:
        return None
    bits = []

    def put(value, length):
        for i in range(length - 1, -1, -1):
            bits.append((value >> i) & 1)

    put(4, 4)
    put(len(data_in), 8)
    for b in data_in:
        put(b, 8)
    put(0, min(4, cap * 8 - len(bits)))
    while len(bits) % 8:
        bits.append(0)
    data = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = 0xEC
    while len(data) < cap:
        data.append(pad)
        pad ^= 0xEC ^ 0x11
    divisor, blocks, at = _divisor(spec[1]), [], 0
    for count, size in ((spec[2], spec[3]), (spec[4], spec[5])):
        for _ in range(count):
            d = data[at:at + size]
            at += size
            blocks.append((d, _remainder(d, divisor)))
    codewords = []
    for i in range(max(spec[3], spec[5])):
        codewords += [d[i] for d, _ in blocks if i < len(d)]
    for i in range(spec[1]):
        codewords += [e[i] for _, e in blocks]

    n = 17 + 4 * v
    m = [[False] * n for _ in range(n)]
    fn = [[False] * n for _ in range(n)]

    def mark(px, py, dark):
        m[py][px] = bool(dark)
        fn[py][px] = True

    def finder(cx, cy):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                d, px, py = max(abs(dx), abs(dy)), cx + dx, cy + dy
                if 0 <= px < n and 0 <= py < n:
                    mark(px, py, d not in (2, 4))

    def fmt(mask):
        rem = mask
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        f = ((mask << 10) | rem) ^ 0x5412

        def bit(q):
            return (f >> q) & 1

        for k in range(6):
            mark(8, k, bit(k))
        mark(8, 7, bit(6))
        mark(8, 8, bit(7))
        mark(7, 8, bit(8))
        for k in range(9, 15):
            mark(14 - k, 8, bit(k))
        for k in range(8):
            mark(n - 1 - k, 8, bit(k))
        for k in range(8, 15):
            mark(8, n - 15 + k, bit(k))
        mark(8, n - 8, 1)

    for i in range(n):
        mark(6, i, i % 2 == 0)
        mark(i, 6, i % 2 == 0)
    finder(3, 3)
    finder(n - 4, 3)
    finder(3, n - 4)
    al, last = _AL[v], len(_AL[v]) - 1
    for i in range(len(al)):
        for j in range(len(al)):
            if (i, j) in ((0, 0), (0, last), (last, 0)):
                continue
            for ay in range(-2, 3):
                for ax in range(-2, 3):
                    mark(al[i] + ax, al[j] + ay, max(abs(ax), abs(ay)) != 1)
    fmt(0)
    if v >= 7:
        rem = v
        for _ in range(12):
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
        vb = (v << 12) | rem
        for i in range(18):
            a, c, on = n - 11 + i % 3, i // 3, (vb >> i) & 1
            mark(a, c, on)
            mark(c, a, on)

    k, right = 0, n - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(n):
            for j in range(2):
                x = right - j
                y = n - 1 - vert if ((right + 1) & 2) == 0 else vert
                if not fn[y][x] and k < len(codewords) * 8:
                    m[y][x] = ((codewords[k >> 3] >> (7 - (k & 7))) & 1) == 1
                    k += 1
        right -= 2

    def masked(mask, px, py):
        return [(px + py) % 2 == 0, py % 2 == 0, px % 3 == 0, (px + py) % 3 == 0, (px // 3 + py // 2) % 2 == 0, px * py % 2 + px * py % 3 == 0,
                (px * py % 2 + px * py % 3) % 2 == 0, ((px + py) % 2 + px * py % 3) % 2 == 0][mask]

    def apply(mask):
        for py in range(n):
            for px in range(n):
                if not fn[py][px] and masked(mask, px, py):
                    m[py][px] = not m[py][px]

    def penalty():
        p = 0
        for rows in (m, [list(col) for col in zip(*m)]):
            for row in rows:
                run = 1
                for i in range(1, n):
                    if row[i] == row[i - 1]:
                        run += 1
                        p += 3 if run == 5 else 1 if run > 5 else 0
                    else:
                        run = 1
        for py in range(n - 1):
            for px in range(n - 1):
                if m[py][px] == m[py][px + 1] == m[py + 1][px] == m[py + 1][px + 1]:
                    p += 3
        dark = sum(sum(row) for row in m)
        return p + (abs(dark * 20 - n * n * 10) // (n * n)) * 10

    best, least = 0, None
    for i in range(8):
        apply(i)
        fmt(i)
        pen = penalty()
        if least is None or pen < least:
            best, least = i, pen
        apply(i)
    apply(best)
    fmt(best)
    return m


def qr_svg(text):
    m = qr_matrix(text)
    if m is None:
        return ""
    n, q = len(m), 4
    path = "".join(f"M{x + q} {y + q}h1v1h-1z" for y in range(n) for x in range(n) if m[y][x])
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {n + 2 * q} {n + 2 * q}" shape-rendering="crispEdges" role="img" aria-label="The payment link as a QR code">'
            f'<rect width="100%" height="100%" fill="#fff"/><path d="{path}" fill="#000"/></svg>')


# ---- Commands -----------------------------------------------------------------------

def cmd_new(args, book, path):
    settings = book.setdefault("settings", {})
    wallet = args.wallet or settings.get("wallet")
    if not wallet:
        sys.exit("--wallet is required the first time: your Solana wallet address (it is remembered in the invoice file)")
    if not is_bytes58(wallet, 32):
        sys.exit("--wallet is not a Solana address (32 bytes in Base58)")
    mint = args.mint or settings.get("mint") or USDC
    if not is_bytes58(mint, 32):
        sys.exit("--mint is not a token mint address")
    decimals = args.decimals if args.decimals is not None else settings.get("decimals", 6)
    symbol = args.symbol or settings.get("symbol") or "USDC"
    seller = args.seller if args.seller is not None else settings.get("seller", "")
    if not 0 < args.usd <= 1e9:
        sys.exit("--usd must be above 0")
    units = round(args.usd * 10 ** decimals)
    today = datetime.date.today()
    year = [i for i in book["invoices"] if i["number"].startswith(f"INV-{today.year}-")]
    number = f"INV-{today.year}-{len(year) + 1:04d}"
    reference = b58encode(secrets.token_bytes(32))
    query = urllib.parse.urlencode([("amount", formatted(units, decimals)), ("spl-token", mint), ("reference", reference)])
    invoice = {
        "number": number, "date": today.isoformat(), "due": (today + datetime.timedelta(days=args.days)).isoformat() if args.days else None,
        "to": args.to, "what": args.what, "seller": seller, "amount_usd": args.usd, "units": units, "decimals": decimals, "symbol": symbol,
        "mint": mint, "wallet": wallet, "reference": reference, "url": f"solana:{wallet}?{query}", "status": "open", "payments": [],
    }
    book["invoices"].append(invoice)
    settings.update({"wallet": wallet, "mint": mint, "decimals": decimals, "symbol": symbol, "seller": seller})
    save(path, book)
    page = os.path.join(os.path.dirname(os.path.abspath(path)), number + ".html")
    with open(page, "w", encoding="utf-8") as f:
        f.write(as_page(invoice))
    print(as_text(invoice))
    print(f"\n(kept in {path}; the page with the QR code is {page})")
    return 0


def cmd_check(args, book, path):
    chosen = [find(book, n) for n in args.numbers] if args.numbers else [i for i in book["invoices"] if i["status"] == "open"]
    if not chosen:
        print("no open invoice")
        return 0
    failed = False
    for invoice in chosen:
        was = invoice["status"]
        try:
            print(check_one(args.rpc, book, invoice) + ("   <- paid now" if was == "open" and invoice["status"] == "paid" else ""))
        except RuntimeError as e:
            failed = True
            print(f"{invoice['number']}  could not be checked: {e}")
        time.sleep(args.pause)
    save(path, book)
    # 0: all of them are paid; 2: at least one is still open; 1: the chain could not be asked.
    return 1 if failed else 0 if all(i["status"] != "open" for i in chosen) else 2


def cmd_list(args, book, path):
    for invoice in book["invoices"]:
        print(line(invoice))
    if not book["invoices"]:
        print("no invoice yet")
    return 0


def cmd_show(args, book, path):
    invoice = find(book, args.number)
    print(as_text(invoice))
    print("\n" + line(invoice))
    for p in invoice.get("payments", []):
        print(f"  {formatted(p['units'], invoice['decimals'])} {invoice['symbol']}  {time.strftime('%Y-%m-%d %H:%M', time.gmtime(p['at'] or 0))} UTC  {p['signature']}")
    return 0


def cmd_paid(args, book, path):
    invoice = find(book, args.number)
    if invoice["status"] == "void":
        sys.exit(f"{invoice['number']} is void")
    if not is_bytes58(args.tx, 64):
        sys.exit("--tx is not a transaction signature (64 bytes in Base58)")
    other = used(book, args.tx, but=invoice)
    if other:
        sys.exit(f"that transaction already pays {other}")
    try:
        moved = gained(args.rpc, args.tx, invoice["wallet"], invoice["mint"])
    except RuntimeError as e:
        sys.exit(str(e))
    if moved is None:
        sys.exit("that transaction is not on the chain, is not final yet, or failed")
    if moved[0] <= 0:
        sys.exit(f"that transaction does not move {invoice['symbol']} to {invoice['wallet']}")
    credit(book, invoice, args.tx, moved[0], moved[1])
    save(path, book)
    print(line(invoice))
    return 0 if invoice["status"] == "paid" else 2


def cmd_void(args, book, path):
    invoice = find(book, args.number)
    if invoice["status"] == "paid":
        sys.exit(f"{invoice['number']} is paid")
    invoice["status"] = "void"
    save(path, book)
    print(line(invoice))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", default=os.environ.get("OMNIGATE_INVOICES", "invoices.json"), help="the invoice file (default ./invoices.json)")
    ap.add_argument("--rpc", default=os.environ.get("OMNIGATE_SOLANA_RPC", RPC), help="the Solana JSON-RPC endpoint")
    sub = ap.add_subparsers(dest="command", required=True)
    new = sub.add_parser("new", help="a new invoice")
    new.add_argument("--usd", type=float, required=True, help="the amount in US dollars")
    new.add_argument("--to", required=True, help="who it is for")
    new.add_argument("--for", dest="what", default="omnigate commercial license, one year", help="what it is for")
    new.add_argument("--days", type=int, default=30, help="days until it is due (0: no due date)")
    new.add_argument("--wallet", help="your wallet address (remembered)")
    new.add_argument("--seller", help="your name and address as they should appear (remembered)")
    new.add_argument("--mint", help="the token's mint (default USDC; remembered)")
    new.add_argument("--decimals", type=int, help="the mint's decimals (default 6)")
    new.add_argument("--symbol", help="the token's name (default USDC)")
    new.set_defaults(run=cmd_new)
    check = sub.add_parser("check", help="ask the chain whether invoices were paid")
    check.add_argument("numbers", nargs="*")
    check.add_argument("--pause", type=float, default=0.5, help="seconds between invoices (the public endpoint is rate limited)")
    check.set_defaults(run=cmd_check)
    sub.add_parser("list", help="every invoice").set_defaults(run=cmd_list)
    show = sub.add_parser("show", help="one invoice")
    show.add_argument("number")
    show.set_defaults(run=cmd_show)
    paid = sub.add_parser("paid", help="mark an invoice paid by a transaction made without the link")
    paid.add_argument("number")
    paid.add_argument("--tx", required=True, help="the transaction's signature")
    paid.set_defaults(run=cmd_paid)
    void = sub.add_parser("void", help="withdraw an invoice")
    void.add_argument("number")
    void.set_defaults(run=cmd_void)
    args = ap.parse_args(argv)
    return args.run(args, load(args.file), args.file)


if __name__ == "__main__":
    sys.exit(main())
