#!/usr/bin/env python3
"""Merge per-thread timebox traces into a single JSON file for TLC.

Usage: preprocess_trace.py <trace_dir> <output_file>

Reads trace-thread-*.ndjson files from <trace_dir>, merges per-thread events,
compresses timestamps to dense integers, remaps thread/data IDs to TLA+ names,
and outputs a JSON file compatible with Trace.tla.

Output format:
{
  "t1": [{"event": "send_to_queue", "start": 1, "end": 3, "state": {...}}, ...],
  "t2": [...],
  ...
}
"""

import json
import glob
import os
import sys


def merge_and_compress(trace_dir, output_path):
    per_thread = {}
    all_timestamps = set()

    # 1. Read all per-thread files
    pattern = os.path.join(trace_dir, "trace-thread-*.ndjson")
    files = sorted(glob.glob(pattern))
    if not files:
        print(f"WARNING: no trace files matching {pattern}", file=sys.stderr)
        sys.exit(1)

    for path in files:
        # Extract thread number from filename: trace-thread-0.ndjson -> 0
        basename = os.path.basename(path)
        thread_num = int(basename.replace("trace-thread-", "").replace(".ndjson", ""))

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
        per_thread[thread_num] = events

    if not all_timestamps:
        print("WARNING: no trace events found", file=sys.stderr)
        sys.exit(1)

    # 2. Timestamp compression: raw ns -> dense integers (1-indexed for TLA+)
    sorted_ts = sorted(all_timestamps)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}

    # 3. Remap thread numbers to t1, t2, ... (sorted by first appearance order)
    thread_order = sorted(per_thread.keys())
    thread_name_map = {num: f"t{i+1}" for i, num in enumerate(thread_order)}

    # 4. Collect all data values for remapping to d1, d2, ...
    data_values = set()
    for events in per_thread.values():
        for event in events:
            if "data" in event:
                data_values.add(event["data"])
    data_sorted = sorted(data_values)
    data_map = {val: f"d{i+1}" for i, val in enumerate(data_sorted)}

    # 5. Apply compressions
    output = {}
    for thread_num in thread_order:
        events = per_thread[thread_num]
        tla_name = thread_name_map[thread_num]
        processed = []
        for event in events:
            entry = {
                "event": event["event"],
                "start": ts_map[event["start"]],
                "end": ts_map[event["end"]],
            }
            if "state" in event:
                entry["state"] = event["state"]
            if "data" in event:
                entry["data"] = data_map.get(event["data"], event["data"])
            if "signalState" in event:
                entry["signalState"] = event["signalState"]
            processed.append(entry)
        output[tla_name] = processed

    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)

    total_events = sum(len(v) for v in output.values())
    print(
        f"Merged {total_events} events from {len(output)} threads, "
        f"{len(sorted_ts)} unique timestamps -> {output_path}"
    )

    # Print summary per thread
    for name in sorted(output.keys()):
        events = output[name]
        event_types = {}
        for e in events:
            event_types[e["event"]] = event_types.get(e["event"], 0) + 1
        summary = ", ".join(f"{k}={v}" for k, v in sorted(event_types.items()))
        print(f"  {name}: {len(events)} events ({summary})")

    # Check overlap quality
    all_intervals = []
    for name, events in output.items():
        for e in events:
            all_intervals.append((name, e["start"], e["end"]))

    overlap_count = 0
    total_pairs = 0
    for i in range(len(all_intervals)):
        for j in range(i + 1, len(all_intervals)):
            if all_intervals[i][0] == all_intervals[j][0]:
                continue  # same thread
            total_pairs += 1
            a_s, a_e = all_intervals[i][1], all_intervals[i][2]
            b_s, b_e = all_intervals[j][1], all_intervals[j][2]
            if a_s <= b_e and b_s <= a_e:
                overlap_count += 1

    if total_pairs > 0:
        pct = 100.0 * overlap_count / total_pairs
        print(f"Cross-thread overlap: {overlap_count}/{total_pairs} pairs ({pct:.1f}%)")
    else:
        print("WARNING: no cross-thread pairs found (single-thread trace?)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <trace_dir> <output_file>")
        sys.exit(1)

    merge_and_compress(sys.argv[1], sys.argv[2])
