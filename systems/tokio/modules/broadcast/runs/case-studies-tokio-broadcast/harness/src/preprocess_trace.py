#!/usr/bin/env python3
"""Merge per-thread timebox traces into a single JSON file for TLC.

Usage: python3 preprocess_trace.py <trace_dir> <output_file>

Reads trace-thread-*.ndjson from trace_dir, compresses timestamps to dense
integers, and outputs a JSON file with per-thread event arrays.
"""

import json
import glob
import sys
import os
import re


def merge_and_compress(trace_dir, output_path):
    # 1. Read all per-thread files
    per_thread = {}
    all_timestamps = set()

    pattern = os.path.join(trace_dir, "trace-thread-*.ndjson")
    files = sorted(glob.glob(pattern))

    if not files:
        print(f"ERROR: No trace files found matching {pattern}", file=sys.stderr)
        sys.exit(1)

    # Collect thread ID mapping (assign t1, t2, ... in order of appearance)
    raw_tid_to_tla = {}
    tid_counter = 1

    for path in files:
        # Extract thread number from filename
        match = re.search(r'trace-thread-(\d+)\.ndjson', path)
        if not match:
            continue
        raw_tid = match.group(1)

        events = []
        for line_num, line in enumerate(open(path), 1):
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"WARNING: {path}:{line_num}: invalid JSON: {e}", file=sys.stderr)
                continue
            if event.get("tag") != "trace":
                continue

            # Map thread ID to TLA+ name
            raw_thread = event.get("thread", f"t{raw_tid}")
            if raw_thread not in raw_tid_to_tla:
                raw_tid_to_tla[raw_thread] = f"t{tid_counter}"
                tid_counter += 1
            event["thread"] = raw_tid_to_tla[raw_thread]

            events.append(event)
            all_timestamps.add(event["start"])
            all_timestamps.add(event["end"])

        if events:
            tla_tid = events[0]["thread"]
            per_thread[tla_tid] = events

    if not per_thread:
        print("ERROR: No trace events found in any file", file=sys.stderr)
        sys.exit(1)

    # 2. Timestamp compression: raw nanos -> dense integers (1-indexed)
    sorted_ts = sorted(all_timestamps)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}

    for tid in per_thread:
        for event in per_thread[tid]:
            event["start"] = ts_map[event["start"]]
            event["end"] = ts_map[event["end"]]

    # 3. Compute overlap statistics
    overlap_count = 0
    total_cross_pairs = 0
    tids = sorted(per_thread.keys())
    for i, t1 in enumerate(tids):
        for t2 in tids[i+1:]:
            for e1 in per_thread[t1]:
                for e2 in per_thread[t2]:
                    total_cross_pairs += 1
                    # Intervals overlap if not (e1.end < e2.start or e2.end < e1.start)
                    if not (e1["end"] < e2["start"] or e2["end"] < e1["start"]):
                        overlap_count += 1

    # 4. Build output: structure matching Trace.tla expectations
    # Trace.tla expects: { "threads": { "t1": [...], "t2": [...] }, ... }
    output = {
        "threads": {tid: events for tid, events in sorted(per_thread.items())},
        "meta": {
            "num_threads": len(per_thread),
            "total_events": sum(len(v) for v in per_thread.values()),
            "max_timestamp": len(sorted_ts),
            "cross_thread_overlap": overlap_count,
            "cross_thread_pairs": total_cross_pairs,
        }
    }

    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)

    pct = (overlap_count / total_cross_pairs * 100) if total_cross_pairs > 0 else 0
    print(f"Merged {output['meta']['total_events']} events from "
          f"{output['meta']['num_threads']} threads, "
          f"{len(sorted_ts)} unique timestamps, "
          f"{overlap_count}/{total_cross_pairs} cross-thread overlaps ({pct:.0f}%)")

    # 5. Print event type coverage
    event_types = set()
    for tid in per_thread:
        for event in per_thread[tid]:
            event_types.add(event["event"])
    print(f"Event types: {sorted(event_types)}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <trace_dir> <output_file>", file=sys.stderr)
        sys.exit(1)
    merge_and_compress(sys.argv[1], sys.argv[2])
