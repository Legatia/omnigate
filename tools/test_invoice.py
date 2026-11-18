#!/usr/bin/env python3
"""Tests of tools/invoice.py against the stand-in chain (tools/mock_solana.py).

    python tools/test_invoice.py

Standard library only. If `node` is on PATH, the QR code is also compared,
module by module, with the one the gateway's top-up page draws.
"""
import contextlib
import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import invoice  # noqa: E402

WALLET = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
TOKEN_ACCOUNT = "7UX2i7SucgLMQcfZ75s3VXmZZY4YRUyJN9X1RgfMoDUi"
RESULTS = []


def check(name, ok, detail=None):
    RESULTS.append(bool(ok))
    print(("  PASS  " if ok else "  FAIL  ") + name + ("" if ok or detail is None else f"   [{str(detail)[:400]}]"))


def run(*argv):
    """Run the tool in process: (exit code, what it printed)."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            code = invoice.main(list(argv))
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else 1
            if isinstance(e.code, str):
                print(e.code)
    return code, out.getvalue()


def post(url, body):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def qr_checks():
    link = "solana:" + WALLET + "?amount=490.00&spl-token=" + invoice.USDC + "&reference=" + invoice.b58encode(bytes(range(32)))
    m = invoice.qr_matrix(link)
    n = len(m) if m else 0
    finder = m and all(m[0][i] and m[6][i] and m[i][0] and m[i][6] for i in range(7)) and not any(m[7][i] for i in range(8))
    check("a payment link fits a QR code: a square of 17 + 4 x version modules, with a finder pattern in the corner",
          m is not None and (n - 17) % 4 == 0 and 21 <= n <= 53 and all(len(row) == n for row in m) and finder and len(link) <= 180, (n, len(link)))
    check("a text that is too long for the code gives none", invoice.qr_matrix("x" * 181) is None and invoice.qr_svg("x" * 181) == "")

    node = shutil.which("node")
    if not node:
        print("  skip  the comparison with the top-up page's code: node is not on PATH")
        return
    with open(os.path.join(HERE, "..", "control", "lib", "omnigate_control", "topup_page.ex"), encoding="utf-8") as f:
        source = f.read()
    js = re.search(r'def qr_js do\s+~S"""\n(.*?)\n\s*"""', source, re.S).group(1)
    js = js[:js.index("function qrSvg")]
    texts = ["a", link, "https://example.com/" + "p" * 60, "solana:" + WALLET, "x" * 180, "ünïcödé ✓"]
    script = js + "\nvar t=JSON.parse(process.argv[2]);console.log(JSON.stringify(t.map(function(s){return qrMatrix(s)})))"
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as f:
        f.write(script)
    try:
        theirs = json.loads(subprocess.run([node, f.name, json.dumps(texts)], capture_output=True, text=True, timeout=60, check=True).stdout)
    finally:
        os.unlink(f.name)
    check("the code is the one the top-up page draws, module for module, for texts of six lengths", theirs == [invoice.qr_matrix(t) for t in texts])


def main():
    qr_checks()
    port = free_port()
    chain = f"http://127.0.0.1:{port}"
    mock = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_solana.py"), str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    folder = tempfile.mkdtemp(prefix="omnigate-invoice-")
    book = os.path.join(folder, "invoices.json")
    tool = lambda *argv: run("--file", book, "--rpc", chain, *argv)  # noqa: E731
    land = lambda **body: post(chain + "/__mock/land", dict({"owner": WALLET, "mint": invoice.USDC}, **body))["signature"]  # noqa: E731
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(chain + "/__mock/seen", timeout=1).read()
                break
            except OSError:
                time.sleep(0.1)

        code, out = tool("new", "--usd", "490", "--to", "Acme GmbH")
        check("the first invoice needs the wallet", code != 0 and "--wallet" in out, (code, out))
        code, out = tool("new", "--usd", "490", "--to", "Acme GmbH", "--wallet", "not-an-address")
        check("a wallet that is not an address is refused", code != 0 and "not a Solana address" in out, (code, out))

        code, out = tool("new", "--usd", "490", "--to", "Acme GmbH <billing@acme.example>", "--wallet", WALLET, "--seller", "Example Ltd, 1 Main St")
        first = json.load(open(book, encoding="utf-8"))["invoices"][0]
        year = time.strftime("%Y")
        page = open(os.path.join(folder, first["number"] + ".html"), encoding="utf-8").read()
        check("a new invoice has a number, a reference of its own and a Solana Pay link for the exact amount; its text and its page say how to pay",
              code == 0 and first["number"] == f"INV-{year}-0001" and first["units"] == 490_000_000 and invoice.is_bytes58(first["reference"], 32)
              and first["url"] == f"solana:{WALLET}?amount=490.00&spl-token={invoice.USDC}&reference={first['reference']}"
              and first["url"] in out and "490.00 USDC" in out and WALLET in out and "Example Ltd" in out
              and "<svg" in page and "Acme GmbH &lt;billing@acme.example&gt;" in page and first["url"].replace("&", "&amp;") in page, (code, out))

        code, out = tool("new", "--usd", "25.5", "--to", "Second Ltd", "--for", "support, one hour", "--days", "0")
        book_now = json.load(open(book, encoding="utf-8"))
        second = book_now["invoices"][1]
        check("the wallet and the seller are remembered; the next invoice has the next number and another reference",
              code == 0 and second["number"] == f"INV-{year}-0002" and second["wallet"] == WALLET and second["seller"] == "Example Ltd, 1 Main St"
              and second["reference"] != first["reference"] and second["units"] == 25_500_000 and second["due"] is None, (code, out))

        code, out = tool("check")
        check("nothing was paid yet: both are open, and the exit code says so", code == 2 and out.count("open") == 2, (code, out))

        # A transaction that names the reference and failed; one that is not final yet; a transfer to the wallet that names no reference.
        land(addresses=[first["reference"]], units=490_000_000, failed=True)
        pending = land(addresses=[first["reference"], TOKEN_ACCOUNT], units=490_000_000, status="confirmed")
        stray = land(addresses=[TOKEN_ACCOUNT], units=490_000_000)
        code, out = tool("check", first["number"])
        check("a failed transaction, one that is not final and a transfer without the reference pay nothing", code == 2 and "open" in out and "paid" not in out, (code, out))

        post(chain + "/__mock/finalize", {})
        code, out = tool("check", first["number"])
        saved = json.load(open(book, encoding="utf-8"))["invoices"][0]
        check("once the transfer with the reference is final the invoice is paid, by that transaction",
              code == 0 and "paid" in out and "paid now" in out and saved["status"] == "paid" and [p["signature"] for p in saved["payments"]] == [pending], (code, out))
        code, out = tool("check")
        check("checked again, it is not asked about any more; the other one is still open", code == 2 and first["number"] not in out and second["number"] in out, (code, out))

        # The second one: less than asked, then the rest by hand without the link.
        land(addresses=[second["reference"]], units=20_000_000)
        code, out = tool("check", second["number"])
        check("less than the amount leaves it open and says how much came", code == 2 and "20.00 of it received" in out, (code, out))
        code, out = tool("paid", second["number"], "--tx", pending)
        check("a transaction that pays another invoice cannot pay this one", code != 0 and f"already pays {first['number']}" in out, (code, out))
        code, out = tool("paid", second["number"], "--tx", "1" * 64)
        check("a signature the chain does not know is refused", code != 0 and "not on the chain" in out, (code, out))
        rest = land(addresses=[TOKEN_ACCOUNT], units=5_500_000)
        code, out = tool("paid", second["number"], "--tx", rest)
        saved = json.load(open(book, encoding="utf-8"))["invoices"][1]
        check("the rest, sent by hand and named by its signature, pays it: the amount is what the chain says the wallet gained",
              code == 0 and saved["status"] == "paid" and sum(p["units"] for p in saved["payments"]) == 25_500_000, (code, out))

        code, out = tool("new", "--usd", "10", "--to", "Third")
        code2, out2 = tool("void", f"INV-{year}-0003")
        code3, out3 = tool("void", first["number"])
        code4, out4 = tool("list")
        check("an open invoice can be withdrawn, a paid one cannot; the list shows all three",
              code == 0 and code2 == 0 and "void" in out2 and code3 != 0 and "is paid" in out3 and code4 == 0 and len(out4.strip().splitlines()) == 3
              and out4.count("paid") == 2, (out2, out3, out4))
        code, out = tool("paid", f"INV-{year}-0003", "--tx", stray)
        check("a void invoice takes no payment", code != 0 and "is void" in out, (code, out))

        mock.terminate()
        mock.wait(timeout=10)
        code, out = tool("new", "--usd", "10", "--to", "Fourth")
        code2, out2 = tool("check")
        check("with the chain unreachable an invoice can still be written, and a check says it could not ask", code == 0 and code2 == 1 and "could not be checked" in out2, (code2, out2))
    finally:
        if mock.poll() is None:
            mock.terminate()
        shutil.rmtree(folder, ignore_errors=True)

    print("ALL PASSED" if all(RESULTS) else "SOME FAILED")
    return 0 if all(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
