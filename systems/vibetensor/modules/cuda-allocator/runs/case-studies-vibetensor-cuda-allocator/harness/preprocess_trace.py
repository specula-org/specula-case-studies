#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Merge per-thread NDJSON timebox traces into a single JSON file that
Trace.tla consumes.

Input:  <traces_dir>/<scenario>-thread-<N>.ndjson
Output: <traces_dir>/<scenario>.json

Output schema (matches Trace.tla expectations):
  {
    "num_threads": N,
    "max_timestamp": M,
    "traces": {"0": [events...], "1": [events...], ...},
    "tidMap": {"0": "t1", "1": "t2", ...}
  }

Each event carries: name, tid, start, end, state, fields.  Timestamps are
compressed to dense 1-based integers preserving ordering.

Usage:  preprocess_trace.py <traces_dir>
"""
import glob
import json
import os
import re
import sys
from collections import defaultdict


def merge_scenario(scenario_prefix: str):
    thread_files = sorted(glob.glob(f"{scenario_prefix}-thread-*.ndjson"))
    if not thread_files:
        return None

    per_thread = defaultdict(list)
    all_timestamps = set()

    tid_re = re.compile(r"-thread-(\d+)\.ndjson$")
    for path in thread_files:
        m = tid_re.search(path)
        if not m:
            continue
        tid = int(m.group(1))
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError as e:
                    print(f"warn: {path}: skipping malformed line: {e}",
                          file=sys.stderr)
                    continue
                if ev.get("tag") != "trace":
                    continue
                # Drop the envelope "tag" once validated.
                ev.pop("tag", None)
                # Normalize start/end ints.
                ev["start"] = int(ev.get("start", 0))
                ev["end"]   = int(ev.get("end", 0))
                per_thread[tid].append(ev)
                all_timestamps.add(ev["start"])
                all_timestamps.add(ev["end"])

    if not per_thread:
        return None

    sorted_ts = sorted(all_timestamps)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}
    for tid, events in per_thread.items():
        for ev in events:
            ev["start"] = ts_map[ev["start"]]
            ev["end"]   = ts_map[ev["end"]]
        events.sort(key=lambda e: (e["start"], e["end"]))

    # Map numeric tids to t1..tN as Trace.cfg expects.
    sorted_tids = sorted(per_thread.keys())
    tid_map = {tid: f"t{idx+1}" for idx, tid in enumerate(sorted_tids)}

    output_traces = {tid_map[t]: per_thread[t] for t in sorted_tids}

    return {
        "num_threads": len(per_thread),
        "max_timestamp": len(sorted_ts),
        "traces": output_traces,
        "tidMap": {str(t): tid_map[t] for t in sorted_tids},
    }


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <traces_dir>", file=sys.stderr)
        sys.exit(2)
    traces_dir = sys.argv[1]

    scenario_prefixes = set()
    for path in glob.glob(os.path.join(traces_dir, "*-thread-*.ndjson")):
        base = os.path.basename(path)
        prefix = re.sub(r"-thread-\d+\.ndjson$", "", base)
        scenario_prefixes.add(prefix)

    if not scenario_prefixes:
        print("preprocess_trace: no thread files found in", traces_dir)
        return

    for prefix in sorted(scenario_prefixes):
        full_prefix = os.path.join(traces_dir, prefix)
        merged = merge_scenario(full_prefix)
        if merged is None:
            continue
        out_path = os.path.join(traces_dir, f"{prefix}.json")
        with open(out_path, "w") as fh:
            json.dump(merged, fh, indent=2)
        nevents = sum(len(v) for v in merged["traces"].values())
        print(f"preprocess_trace: {prefix}: {merged['num_threads']} threads, "
              f"{nevents} events, {merged['max_timestamp']} timestamps -> "
              f"{out_path}")


if __name__ == "__main__":
    main()
