#!/usr/bin/env python3
"""Merge per-thread timebox traces into a single JSON file for TLC.

Usage:
    python3 preprocess_trace.py <trace_dir> <output_file> [--scenario <name>]

If --scenario is given, only thread files matching that scenario prefix are merged.
Otherwise, all trace-thread-*.ndjson files in trace_dir are merged.
"""

import json
import glob
import sys
import os


def merge_and_compress(trace_dir, output_path, scenario=None):
    pattern = os.path.join(trace_dir, "trace-thread-*.ndjson")
    files = sorted(glob.glob(pattern))
    if not files:
        print(f"ERROR: No trace files found matching {pattern}", file=sys.stderr)
        sys.exit(1)

    per_thread = {}
    all_timestamps = set()

    for path in files:
        tid_str = os.path.basename(path).split("-thread-")[1].split(".")[0]
        tid = int(tid_str)
        events = []
        for line in open(path):
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
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

    # Timestamp compression: raw rdtsc -> dense integers (1-indexed)
    sorted_ts = sorted(all_timestamps)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}

    # Remap thread IDs to t1, t2, ... (in order of tid)
    tid_map = {}
    for idx, tid in enumerate(sorted(per_thread.keys())):
        tid_map[tid] = f"t{idx + 1}"

    output = {}
    for tid in sorted(per_thread.keys()):
        tla_tid = tid_map[tid]
        compressed_events = []
        for event in per_thread[tid]:
            compressed = {
                "event": event["event"],
                "start": ts_map[event["start"]],
                "end": ts_map[event["end"]],
            }
            # Copy optional fields
            if "state" in event:
                compressed["state"] = event["state"]
            if "key" in event:
                compressed["key"] = event["key"]
            if "bin" in event:
                compressed["bin"] = event["bin"]
            if "bin_type" in event:
                compressed["bin_type"] = event["bin_type"]
            if "bound" in event:
                compressed["bound"] = event["bound"]
            if "i" in event:
                compressed["i"] = event["i"]
            if "finishing" in event:
                compressed["finishing"] = event["finishing"]
            if "result" in event:
                compressed["result"] = event["result"]
            if "unparked" in event:
                compressed["unparked"] = event["unparked"]
            compressed_events.append(compressed)
        output[tla_tid] = compressed_events

    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)

    total_events = sum(len(v) for v in output.values())
    print(f"Merged {total_events} events from {len(output)} threads, "
          f"{len(sorted_ts)} unique timestamps -> {output_path}")

    # Print overlap stats
    all_events = []
    for tla_tid, events in output.items():
        for e in events:
            all_events.append((tla_tid, e["start"], e["end"]))

    overlap_count = 0
    total_pairs = 0
    for i in range(len(all_events)):
        for j in range(i + 1, len(all_events)):
            t1, s1, e1 = all_events[i]
            t2, s2, e2 = all_events[j]
            if t1 == t2:
                continue
            total_pairs += 1
            # Intervals overlap if s1 <= e2 and s2 <= e1
            if s1 <= e2 and s2 <= e1:
                overlap_count += 1
    if total_pairs > 0:
        pct = 100 * overlap_count / total_pairs
        print(f"Cross-thread overlap: {overlap_count}/{total_pairs} pairs ({pct:.1f}%)")
    else:
        print("WARNING: No cross-thread event pairs (single-thread trace)")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <trace_dir> <output_file>")
        sys.exit(1)
    merge_and_compress(sys.argv[1], sys.argv[2])
