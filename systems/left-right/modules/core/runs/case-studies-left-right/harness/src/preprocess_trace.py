#!/usr/bin/env python3
"""Merge per-thread timebox traces into a single JSON file for TLC.

Reads per-thread NDJSON files from a scenario directory, compresses
timestamps to dense integers, and outputs a merged JSON file with
per-thread event arrays in the format expected by Trace.tla.

Usage: python3 preprocess_trace.py <scenario_dir> <output.json>
"""

import json
import glob
import sys
import os


def merge_and_compress(scenario_dir, output_path):
    per_thread = {}
    all_timestamps = set()

    # Read all per-thread trace files
    pattern = os.path.join(scenario_dir, "trace-*.ndjson")
    for path in sorted(glob.glob(pattern)):
        # Extract thread ID from filename: trace-<tid>.ndjson
        basename = os.path.basename(path)
        tid = basename.replace("trace-", "").replace(".ndjson", "")

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
        print(f"WARNING: No trace events found in {scenario_dir}", file=sys.stderr)
        sys.exit(1)

    # Timestamp compression: raw ns -> dense integers (1-indexed)
    sorted_ts = sorted(all_timestamps)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}

    for tid in per_thread:
        for event in per_thread[tid]:
            event["start"] = ts_map[event["start"]]
            event["end"] = ts_map[event["end"]]
            # Strip tag and thread fields (implicit from key)
            event.pop("tag", None)
            event.pop("thread", None)

    # Build output in Trace.tla expected format
    output = {"threads": per_thread}

    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)

    total_events = sum(len(v) for v in per_thread.values())
    threads = list(per_thread.keys())
    print(f"Merged {total_events} events from {len(per_thread)} threads ({', '.join(threads)})")
    print(f"  Compressed {len(sorted_ts)} timestamps to dense integers")

    # Report overlap statistics
    overlap_count = 0
    total_pairs = 0
    thread_ids = list(per_thread.keys())
    for i, tid1 in enumerate(thread_ids):
        for tid2 in thread_ids[i+1:]:
            for e1 in per_thread[tid1]:
                for e2 in per_thread[tid2]:
                    total_pairs += 1
                    # Overlap: not (e1.end < e2.start or e2.end < e1.start)
                    if not (e1["end"] < e2["start"] or e2["end"] < e1["start"]):
                        overlap_count += 1

    if total_pairs > 0:
        pct = 100.0 * overlap_count / total_pairs
        print(f"  Cross-thread overlap: {overlap_count}/{total_pairs} pairs ({pct:.1f}%)")
    else:
        print("  No cross-thread pairs to check")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <scenario_dir> <output.json>", file=sys.stderr)
        sys.exit(1)
    merge_and_compress(sys.argv[1], sys.argv[2])
