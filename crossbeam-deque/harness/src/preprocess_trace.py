#!/usr/bin/env python3
"""Merge per-thread timebox traces into a single JSON file for TLC.

Usage: preprocess_trace.py <trace_dir> <output_file> <flavor>

Reads trace-*.ndjson files from <trace_dir>, merges per-thread events,
compresses timestamps to dense integers, and outputs a JSON file compatible
with Trace.tla.

Output format:
{
  "flavor": "FIFO",
  "worker": [{"event": "Push", "start": 1, "end": 2, "state": {...}}, ...],
  "s1": [{"event": "StealBegin", "start": 3, "end": 4, ...}, ...],
  ...
}
"""

import json
import glob
import os
import sys


def merge_and_compress(trace_dir, output_path, flavor):
    per_thread = {}
    all_timestamps = set()

    # 1. Read all per-thread files
    pattern = os.path.join(trace_dir, "trace-*.ndjson")
    files = sorted(glob.glob(pattern))
    if not files:
        print(f"WARNING: no trace files matching {pattern}", file=sys.stderr)
        sys.exit(1)

    for path in files:
        # Extract thread name from filename: trace-worker.ndjson -> "worker"
        basename = os.path.basename(path)
        name = basename.replace("trace-", "").replace(".ndjson", "")

        events = []
        for line_no, line in enumerate(open(path), 1):
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"WARNING: {path}:{line_no}: bad JSON: {e}", file=sys.stderr)
                continue

            if event.get("tag") != "trace":
                continue

            events.append(event)
            all_timestamps.add(event["start"])
            all_timestamps.add(event["end"])

        # Sort by start time within each thread (should already be ordered)
        events.sort(key=lambda e: (e["start"], e["end"]))
        per_thread[name] = events

    if not all_timestamps:
        print("WARNING: no trace events found", file=sys.stderr)
        sys.exit(1)

    # 2. Timestamp compression: raw rdtsc -> dense integers (1-indexed)
    sorted_ts = sorted(all_timestamps)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}

    for name in per_thread:
        for event in per_thread[name]:
            event["start"] = ts_map[event["start"]]
            event["end"] = ts_map[event["end"]]
            # Remove tag field (not needed in merged output)
            event.pop("tag", None)

    # 3. Output: per-thread arrays + metadata
    output = {"flavor": flavor}
    for name, events in sorted(per_thread.items()):
        output[name] = events

    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)

    total_events = sum(len(v) for v in per_thread.values())
    print(
        f"Merged {total_events} events from {len(per_thread)} threads, "
        f"{len(sorted_ts)} unique timestamps -> {output_path}"
    )

    # 4. Print summary
    for name, events in sorted(per_thread.items()):
        event_types = {}
        for e in events:
            event_types[e["event"]] = event_types.get(e["event"], 0) + 1
        summary = ", ".join(f"{k}={v}" for k, v in sorted(event_types.items()))
        print(f"  {name}: {len(events)} events ({summary})")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <trace_dir> <output_file> <flavor>")
        print(f"  flavor: FIFO or LIFO")
        sys.exit(1)

    merge_and_compress(sys.argv[1], sys.argv[2], sys.argv[3])
