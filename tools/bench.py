"""Measure what the gateway adds on top of an upstream, on localhost.

Sends the same non-streaming chat request N times over keep-alive
connections, first straight to the mock upstream and then through the
gateway, and prints latency percentiles for both plus the difference.

The mock upstream is a Python thread-per-connection server, so absolute
numbers say more about Python than about the gateway. The difference between
the two rows is the part that belongs to the gateway.

    python tools/bench.py --gateway http://127.0.0.1:8080 --key og-unlimited-key --model demo-direct
"""

import argparse
import http.client
import json
import statistics
import threading
import time
from urllib.parse import urlparse


def worker(url, headers, body, count, out):
    u = urlparse(url)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=30)
    for _ in range(count):
        t0 = time.perf_counter()
        try:
            conn.request("POST", u.path, body=body, headers=headers)
            resp = conn.getresponse()
            resp.read()
            ok = resp.status == 200
        except Exception:
            ok = False
            conn.close()
            conn = http.client.HTTPConnection(u.hostname, u.port, timeout=30)
        out.append(((time.perf_counter() - t0) * 1000.0, ok))


def run(name, url, headers, body, total, concurrency):
    results = []
    per = total // concurrency
    threads = [threading.Thread(target=worker, args=(url, headers, body, per, results)) for _ in range(concurrency)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t0
    lat = sorted(ms for ms, _ in results)
    errors = sum(1 for _, ok in results if not ok)

    def pct(p):
        return lat[min(len(lat) - 1, int(len(lat) * p))]

    row = {
        "name": name,
        "requests": len(lat),
        "errors": errors,
        "rps": len(lat) / wall,
        "p50": pct(0.50),
        "p95": pct(0.95),
        "p99": pct(0.99),
        "mean": statistics.fmean(lat),
    }
    print(f"{name:<10} n={row['requests']:<6} errors={errors:<3} {row['rps']:8.0f} req/s   "
          f"p50 {row['p50']:6.2f} ms   p95 {row['p95']:6.2f} ms   p99 {row['p99']:6.2f} ms")
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gateway", default="http://127.0.0.1:8080")
    ap.add_argument("--upstream", default="http://127.0.0.1:9002")
    ap.add_argument("--key", default="og-unlimited-key")
    ap.add_argument("--model", default="demo-direct", help="a route whose first target is the mock on --upstream")
    ap.add_argument("-n", type=int, default=4000)
    ap.add_argument("-c", type=int, default=16)
    args = ap.parse_args()

    body = json.dumps({"model": args.model, "messages": [{"role": "user", "content": "hi"}]})
    direct_headers = {"content-type": "application/json", "authorization": "Bearer mock-secret"}
    gw_headers = {"content-type": "application/json", "authorization": f"Bearer {args.key}"}

    # Warm both paths (connection setup, first config load).
    run("warmup", args.gateway + "/v1/chat/completions", gw_headers, body, args.c * 5, args.c)
    direct = run("direct", args.upstream + "/v1/chat/completions", direct_headers, body, args.n, args.c)
    gw = run("gateway", args.gateway + "/v1/chat/completions", gw_headers, body, args.n, args.c)
    print(f"added by the gateway: p50 {gw['p50'] - direct['p50']:+.2f} ms, "
          f"p95 {gw['p95'] - direct['p95']:+.2f} ms, p99 {gw['p99'] - direct['p99']:+.2f} ms")
    if direct["errors"] or gw["errors"]:
        raise SystemExit("errors during the run; numbers are not trustworthy")


if __name__ == "__main__":
    main()
