#!/usr/bin/env python3
"""Merge per-thread timebox traces into a single JSON file for TLC.

Usage: python3 preprocess_trace.py <trace_dir> <output_file>

Input:  per-thread NDJSON files (trace-thread-{tid}.ndjson)
Output: JSON with per-thread arrays and compressed timestamps:
  {
    "threads": {
      "0": [ {event, start, end, ...}, ... ],
      "1": [ {event, start, end, ...}, ... ]
    }
  }
"""

import json
import glob
import sys
import os


def merge_and_compress(trace_dir, output_path):
    per_thread = {}
    all_timestamps = set()

    # Read all per-thread files
    pattern = os.path.join(trace_dir, "trace-thread-*.ndjson")
    for path in sorted(glob.glob(pattern)):
        tid = path.split("-thread-")[1].split(".")[0]
        events = []
        for line in open(path):
            line = line.strip()
            if not line:
                continue
            event = json.loads(line)
            if event.get("tag") != "trace":
                continue
            events.append(event)
            all_timestamps.add(event["start"])
            all_timestamps.add(event["end"])
        if events:
            per_thread[tid] = events

    if not per_thread:
        print("ERROR: No trace events found", file=sys.stderr)
        sys.exit(1)

    # Timestamp compression: raw rdtsc -> dense integers (1-indexed for TLA+)
    sorted_ts = sorted(all_timestamps)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}

    for tid in per_thread:
        for event in per_thread[tid]:
            event["start"] = ts_map[event["start"]]
            event["end"] = ts_map[event["end"]]
            # Remove the tag field (TLC doesn't need it in merged format)
            event.pop("tag", None)

    # Check for cross-thread interval overlap
    overlap_count = 0
    tids = sorted(per_thread.keys())
    for i, t1 in enumerate(tids):
        for t2 in tids[i + 1 :]:
            for e1 in per_thread[t1]:
                for e2 in per_thread[t2]:
                    if e1["end"] >= e2["start"] and e2["end"] >= e1["start"]:
                        overlap_count += 1

    # Output for TLC ingestion
    output = {"threads": per_thread}

    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)

    total_events = sum(len(v) for v in per_thread.values())
    print(
        f"Merged {total_events} events from {len(per_thread)} threads, "
        f"{len(sorted_ts)} unique timestamps, "
        f"{overlap_count} cross-thread overlaps"
    )


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <trace_dir> <output_file>", file=sys.stderr)
        sys.exit(1)
    merge_and_compress(sys.argv[1], sys.argv[2])
