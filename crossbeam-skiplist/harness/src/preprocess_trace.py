#!/usr/bin/env python3
"""Merge per-thread timebox traces into a single JSON file for TLC.

Usage: python3 preprocess_trace.py <trace_dir> <prefix> <output_path>

Reads: <trace_dir>/<prefix>-thread-*.ndjson
Writes: <output_path> (single JSON with per-thread arrays + compressed timestamps)
"""

import json
import glob
import sys
import os


def merge_and_compress(trace_dir, prefix, output_path):
    pattern = os.path.join(trace_dir, f"{prefix}-thread-*.ndjson")
    files = sorted(glob.glob(pattern))

    if not files:
        print(f"ERROR: No trace files matching {pattern}", file=sys.stderr)
        sys.exit(1)

    # 1. Read all per-thread files
    per_thread = {}
    all_timestamps = set()

    for path in files:
        # Extract tid from filename: prefix-thread-t1.ndjson -> t1
        basename = os.path.basename(path)
        tid = basename.split("-thread-")[1].replace(".ndjson", "")

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

            events.append(event)
            all_timestamps.add(event["start"])
            all_timestamps.add(event["end"])

        if events:
            per_thread[tid] = events
            print(f"  {tid}: {len(events)} events from {os.path.basename(path)}")

    if not per_thread:
        print("ERROR: No trace events found in any file", file=sys.stderr)
        sys.exit(1)

    # 2. Timestamp compression: raw rdtsc -> dense integers
    sorted_ts = sorted(all_timestamps)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}  # 1-indexed for TLA+

    for tid in per_thread:
        for event in per_thread[tid]:
            event["start"] = ts_map[event["start"]]
            event["end"] = ts_map[event["end"]]
            # Remove the "tag" field (not needed in merged output)
            event.pop("tag", None)
            # Remove the "tid" field (implied by position in per-thread array)
            event.pop("tid", None)

    # 3. Check trace quality (concurrent overlap)
    overlap_count = 0
    total_cross_pairs = 0
    tids = sorted(per_thread.keys())
    for i, tid1 in enumerate(tids):
        for tid2 in tids[i+1:]:
            for e1 in per_thread[tid1]:
                for e2 in per_thread[tid2]:
                    total_cross_pairs += 1
                    # Intervals overlap if not (e1.end < e2.start or e2.end < e1.start)
                    if not (e1["end"] < e2["start"] or e2["end"] < e1["start"]):
                        overlap_count += 1

    # 4. Output: structure for TLC ingestion
    output = {}
    for tid in sorted(per_thread.keys()):
        output[tid] = per_thread[tid]

    output["metadata"] = {
        "num_threads": len(per_thread),
        "max_timestamp": len(sorted_ts),
        "total_events": sum(len(v) for v in per_thread.values() if isinstance(v, list)),
        "overlap_pairs": overlap_count,
        "cross_thread_pairs": total_cross_pairs,
    }

    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)

    total_events = sum(len(v) for v in per_thread.values() if isinstance(v, list))
    overlap_pct = (overlap_count / max(total_cross_pairs, 1)) * 100

    print(f"\nMerged {total_events} events from {len(per_thread)} threads")
    print(f"  Unique timestamps: {len(sorted_ts)}")
    print(f"  Cross-thread overlap: {overlap_count}/{total_cross_pairs} pairs ({overlap_pct:.1f}%)")
    print(f"  Output: {output_path}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <trace_dir> <prefix> <output_path>", file=sys.stderr)
        sys.exit(1)

    merge_and_compress(sys.argv[1], sys.argv[2], sys.argv[3])
