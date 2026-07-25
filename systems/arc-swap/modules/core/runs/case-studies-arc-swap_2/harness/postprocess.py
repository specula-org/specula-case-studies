#!/usr/bin/env python3
"""Postprocess raw trace NDJSON: sort events by `seq`.

The instrumentation point writes events under a Mutex, so file order
already approximates seq order, but to be robust against ordering races
we re-sort by the global SEQ counter (which is fetch_add'ed with SeqCst).
"""
import json
import sys


def main(infile: str, outfile: str) -> None:
    events = []
    with open(infile, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError as exc:
                print(f"warn: bad JSON line skipped: {exc}: {line[:120]}", file=sys.stderr)
                continue
            if ev.get("tag") != "trace":
                continue
            events.append(ev)

    events.sort(key=lambda e: e.get("seq", 0))

    with open(outfile, "w") as out:
        for ev in events:
            out.write(json.dumps(ev, separators=(",", ":")))
            out.write("\n")

    print(f"postprocess: {len(events)} events -> {outfile}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <in.ndjson> <out.ndjson>", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2])
