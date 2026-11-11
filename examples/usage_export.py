#!/usr/bin/env python3
"""Export omnigate's usage to CSV, continuing where the last run stopped.

`GET /admin/events` is the feed for billing and analytics tools: every text
request and media job the gateway metered, oldest first, with a cursor. This
script pages through it and appends one CSV row per event. The cursor is
saved after each page is on disk, so the script can be stopped and started at
any time; a crash between the two repeats at most one page, and every event
has a unique `id` to drop the repeats by.

Try it against the dev stack (docs/quickstart.md; control plane on :4000):

    python examples/usage_export.py --out usage.csv            # everything so far
    python examples/usage_export.py --out usage.csv --follow   # and keep going
    python examples/usage_export.py --out acme.csv --key dev   # one key only

Environment: OMNIGATE_CONTROL (default http://127.0.0.1:4000) and
OMNIGATE_ADMIN_TOKEN (default: the dev token).

What you can rely on: `cost_usd` is what omnigate charged the key's budget
(from the prices in its config); `tag` is the `x-omnigate-tag` the caller
sent, if any; `estimated` marks token counts the gateway had to estimate. No
prompt or answer is in the feed, because none is in the ledger.
"""
import argparse
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CONTROL = os.environ.get("OMNIGATE_CONTROL", "http://127.0.0.1:4000").rstrip("/")
TOKEN = os.environ.get("OMNIGATE_ADMIN_TOKEN", "dev-admin-token-change-me")
# `cost_usd` is what the provider cost, `credits_usd` what the event burned of
# a prepaid key's credit (the same unless a burn multiplier applies). Rows of
# kind "credit" are top-ups and bonuses: `amount_usd`, `source`, `reference`.
COLUMNS = ["id", "kind", "ts", "key", "tag", "model", "upstream", "target_model", "status", "input_tokens", "cached_input_tokens",
           "cache_write_input_tokens", "output_tokens", "outputs", "cached", "estimated", "cost_usd", "credits_usd",
           "amount_usd", "source", "reference"]


def page(cursor, key, limit):
    query = {"limit": limit}
    if cursor:
        query["after"] = cursor
    if key:
        query["key"] = key
    request = urllib.request.Request(CONTROL + "/admin/events?" + urllib.parse.urlencode(query), headers={"authorization": "Bearer " + TOKEN})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read())


def load_cursor(path):
    try:
        return json.load(open(path))["cursor"]
    except (OSError, ValueError, KeyError):
        return None


def save_cursor(path, cursor):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"cursor": cursor}, f)
    os.replace(tmp, path)


def export(out, state, key, limit):
    """Append everything after the saved cursor. Returns the number of rows written."""
    cursor, written = load_cursor(state), 0
    new_file = not os.path.exists(out) or os.path.getsize(out) == 0
    with open(out, "a", newline="", encoding="utf-8") as f:
        rows = csv.DictWriter(f, COLUMNS, extrasaction="ignore")
        if new_file:
            rows.writeheader()
        while True:
            result = page(cursor, key, limit)
            if result["gap"]:
                # The ledger's retention (retention.ledger_days) deleted events
                # this export had not read yet. Totals per key are still exact
                # in GET /admin/keys; the single events are gone.
                print("warning: events between the saved cursor and the oldest one left were deleted by retention", file=sys.stderr)
            rows.writerows(result["events"])
            f.flush()
            os.fsync(f.fileno())
            written += len(result["events"])
            cursor = result["next"]
            save_cursor(state, cursor)
            if not result["more"]:
                return written


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True, help="CSV file to append to")
    ap.add_argument("--state", help="where the cursor is kept (default: <out>.cursor)")
    ap.add_argument("--key", help="only this key's events (by name)")
    ap.add_argument("--limit", type=int, default=500, help="events per request (at most 1000)")
    ap.add_argument("--follow", action="store_true", help="keep polling for new events")
    ap.add_argument("--interval", type=float, default=5.0, help="seconds between polls with --follow")
    args = ap.parse_args()
    state = args.state or args.out + ".cursor"
    while True:
        try:
            written = export(args.out, state, args.key, args.limit)
            print(f"{written} event(s) appended to {args.out}")
        except urllib.error.HTTPError as e:
            # 400 invalid_cursor: the state file is not from this ledger. 404: no such key.
            sys.exit(f"the control plane refused: {e.code} {e.read().decode('utf-8', 'replace')[:300]}")
        except (urllib.error.URLError, OSError) as e:
            if not args.follow:
                sys.exit(f"cannot reach the control plane at {CONTROL}: {e}")
            print(f"cannot reach the control plane ({e}); trying again", file=sys.stderr)
        if not args.follow:
            return
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
