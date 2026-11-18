#!/usr/bin/env python3
"""Turn the failures in a test log into GitHub Actions error annotations.

    python tools/ci_annotate.py LOGFILE [TITLE]

A workflow step runs it after a test step failed. An annotation shows on the
run's summary page and can be read without opening the log (and, unlike the
log, without being signed in). GitHub keeps ten per step, so this prints at
most eight failing checks and then the end of the log as one more.

Standard library only. Always exits 0: it reports a failure, it is not one.
"""
import sys


def escape(text):
    return text.replace("%", "%25").replace("\r", "").replace("\n", "%0A")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 0
    title = sys.argv[2] if len(sys.argv) > 2 else "test"
    try:
        with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as e:
        print(f"::error title={title}::no log to read ({e})")
        return 0
    failed = [line.strip() for line in lines if line.lstrip().startswith(("FAIL ", "FAILED:", "failed:"))]
    for line in failed[:8]:
        print(f"::error title={title}::{escape(line[:1500])}")
    if len(failed) > 8:
        print(f"::error title={title}::and {len(failed) - 8} more failing checks")
    tail = "\n".join(line[:300] for line in lines[-25:])
    print(f"::error title={title}: end of the log::{escape(tail[-3500:])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
