#!/usr/bin/env python3
"""Merge per-thread NDJSON trace files into a single JSON file consumed
by Trace.tla.

Trace.tla expects `JsonDeserialize(<file>)` to be a function from tid
(string) to an array of trace records. The records have fields
`event`, `start`, `end`, `pre`, `post`.

Usage:
    preprocess_trace.py <scenario>-thread-*.ndjson [...]  <output.ndjson>

The first N arguments are per-thread NDJSON inputs; the last argument
is the output path. Each input filename must contain `-thread-<tid>.ndjson`
where <tid> is one of `t1`, `t2`, ..., `e1`, ...

Timestamps in the output are dense integers preserving ordering.
"""

import json
import os
import re
import sys


def parse_tid(path):
    m = re.search(r'-thread-([a-z][0-9]+)\.ndjson$', os.path.basename(path))
    if not m:
        raise ValueError(f"Cannot extract tid from {path!r}")
    return m.group(1)


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    inputs = sys.argv[1:-1]
    output = sys.argv[-1]

    per_thread = {}
    all_ts = set()
    total = 0

    for path in inputs:
        tid = parse_tid(path)
        events = []
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except Exception as ex:
                    print(f"WARN: skipping invalid JSON in {path}: {ex}",
                          file=sys.stderr)
                    continue
                if e.get("tag") != "trace":
                    continue
                events.append(e)
                all_ts.add(int(e["start"]))
                all_ts.add(int(e["end"]))
        per_thread.setdefault(tid, []).extend(events)
        total += len(events)

    if not all_ts:
        # No trace data — still emit an empty per-thread map so Trace.tla
        # can deserialize without complaining.
        out = {tid: [] for tid in per_thread}
        with open(output, "w") as f:
            json.dump(out, f, separators=(",", ":"))
        print(f"WARNING: no events; wrote empty trace to {output}")
        return

    sorted_ts = sorted(all_ts)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}

    out = {}
    for tid, events in per_thread.items():
        # Stable order by start time, then end time, then original order.
        events.sort(key=lambda e: (int(e["start"]), int(e["end"])))
        for e in events:
            e["start"] = ts_map[int(e["start"])]
            e["end"] = ts_map[int(e["end"])]
            # Drop tag / tid fields — Trace.tla doesn't read them.
            e.pop("tag", None)
            e.pop("tid", None)
        out[tid] = events

    # Trace.tla expects PIDS = {"t1", "t2", "e1"} from Trace.cfg; make sure
    # those keys exist so JsonDeserialize gives a complete function.
    for required in ("t1", "t2", "e1"):
        out.setdefault(required, [])

    with open(output, "w") as f:
        json.dump(out, f, separators=(",", ":"))

    print(f"Wrote {output}: {total} events across {len(per_thread)} threads, "
          f"{len(sorted_ts)} unique timestamps")


if __name__ == "__main__":
    main()
