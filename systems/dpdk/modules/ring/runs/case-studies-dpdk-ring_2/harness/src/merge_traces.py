#!/usr/bin/env python3
"""Merge per-thread NDJSON trace files into a single per-tid JSON file
for Trace.tla validation.

Each input file is `<prefix>-thread-<tid>.ndjson`.  The output is a JSON
record:

    { "<tid>": [event...], "<tid>": [event...], ... }

The "tag":"trace" envelope is stripped and only event objects are kept.
Timestamps are compressed from raw rdtsc values to dense integers
preserving ordering and overlap.

Usage:
    merge_traces.py <prefix> <output.json>

Example:
    merge_traces.py traces/trace_mt traces/trace_mt.json
"""
import glob
import json
import os
import sys


def merge(prefix: str, out_path: str) -> int:
    pattern = f"{prefix}-thread-*.ndjson"
    files = sorted(glob.glob(pattern))
    if not files:
        print(f"  no files matching {pattern}", file=sys.stderr)
        # Still emit an empty trace file so Trace.tla can run.
        with open(out_path, "w") as f:
            json.dump({}, f)
        return 0

    per_thread: dict[str, list] = {}
    all_ts: set[int] = set()
    total = 0

    for path in files:
        # Extract tid from filename suffix.
        base = os.path.basename(path)
        # Format: <name>-thread-<tid>.ndjson
        try:
            tid_str = base.rsplit("-thread-", 1)[1].rsplit(".", 1)[0]
            tid = int(tid_str)
        except (IndexError, ValueError):
            continue

        events = []
        with open(path, "r") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError as e:
                    print(f"  bad json in {path}: {e}", file=sys.stderr)
                    continue
                if ev.get("tag") != "trace":
                    continue
                ev.pop("tag", None)
                events.append(ev)
                if "start" in ev:
                    all_ts.add(int(ev["start"]))
                if "end" in ev:
                    all_ts.add(int(ev["end"]))
        if events:
            # Trace.cfg defines `Thread = {t1, t2}` — JSON keys must
            # match those TLA+ identifiers (not bare ints).
            per_thread[f"t{tid}"] = events
            total += len(events)

    # Compress timestamps to dense 1-indexed integers.
    sorted_ts = sorted(all_ts)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}
    for events in per_thread.values():
        for ev in events:
            if "start" in ev:
                ev["start"] = ts_map[int(ev["start"])]
            if "end" in ev:
                ev["end"] = ts_map[int(ev["end"])]

    with open(out_path, "w") as f:
        json.dump(per_thread, f, indent=2)

    print(
        f"  merged {total} events from {len(per_thread)} threads, "
        f"{len(sorted_ts)} unique timestamps  →  {out_path}"
    )
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    sys.exit(merge(sys.argv[1], sys.argv[2]))
