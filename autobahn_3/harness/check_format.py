#!/usr/bin/env python3
"""Spot-check NDJSON trace format: every line is valid JSON with the
required fields {event, node, ts}.  Exits non-zero on any error.

Usage: check_format.py <trace.ndjson>
"""
import json
import os
import sys


def main(path: str) -> int:
    name = os.path.basename(path)
    ok = 0
    with open(path) as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"  FAIL {name}:{n}: {e}")
                return 1
            for field in ("event", "node", "ts"):
                if field not in obj:
                    print(f"  FAIL {name}:{n}: missing field {field!r}")
                    return 1
            ok += 1
    print(f"  OK   {name} ({ok} events parsed)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
