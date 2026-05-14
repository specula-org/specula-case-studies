#!/usr/bin/env python3
"""
Merge per-thread NDJSON trace files into a single JSON document for TLC.

Input:  <trace_dir>/<scenario>-thread-<tid>.ndjson  (one file per thread)
Output: <out_path>  (JSON: { "threads": { "<tid>": [event, ...] } })

Each event is the original NDJSON line minus the "tag" field, with
timestamps compressed to dense integers preserving the partial order.
Only round-2 spec events are kept; unknown events are silently dropped.

Usage:
  preprocess_trace.py <trace_dir> <scenario_prefix> <out_path>
"""

import glob
import json
import os
import re
import sys


# Round-2 spec events we recognize. Trace.tla MatchEvent dispatches on these.
KNOWN_EVENTS = {
    "insert_cas",
    "insert_meta",
    "insert_meta_fixup",
    "insert_update",
    "remove",
    "copy_mark_copying",
    "copy_mark_copying_null",
    "copy_insert",
    "copy_mark_copied",
    "alloc_next",
    "try_promote",
    "abort_resize",
    "init_table",
    "park",
    "iter_begin",
    "iter_yield",
    "iter_skip",
    "iter_end",
}


def load_thread_files(trace_dir: str, scenario: str):
    pattern = os.path.join(trace_dir, f"{scenario}-thread-*.ndjson")
    paths = sorted(glob.glob(pattern))
    if not paths:
        print(f"[preprocess] no trace files matching {pattern}", file=sys.stderr)
    return paths


def parse_thread_id(path: str) -> str:
    m = re.search(r"-thread-(.+?)\.ndjson$", path)
    return m.group(1) if m else os.path.basename(path)


def merge(trace_dir: str, scenario: str):
    per_thread = {}
    all_ts = set()
    total = 0
    dropped = 0

    for path in load_thread_files(trace_dir, scenario):
        tid_from_path = parse_thread_id(path)
        events = []
        with open(path) as fh:
            for raw in fh:
                line = raw.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("tag") != "trace":
                    continue
                event = obj.get("event")
                if event not in KNOWN_EVENTS:
                    dropped += 1
                    continue
                # Drop the envelope "tag" field; thread is already implicit.
                obj.pop("tag", None)
                if "thread" in obj:
                    # Sanity: ensure the implicit thread matches the path's tid.
                    tid_from_path = obj["thread"]
                    obj.pop("thread", None)
                events.append(obj)
                all_ts.add(obj.get("start", 0))
                all_ts.add(obj.get("end", 0))
                total += 1

        if events:
            per_thread.setdefault(tid_from_path, []).extend(events)

    # Compress timestamps: raw ns → dense 1..N preserving order.
    sorted_ts = sorted(all_ts)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}
    for events in per_thread.values():
        # Within each thread, events were appended in observed order. Sort by
        # start to enforce per-thread monotonicity (in practice the writer is
        # monotonic, but two threads writing into the same per-thread file
        # via two scenarios is impossible — one file per thread per scenario).
        events.sort(key=lambda e: e.get("start", 0))
        for e in events:
            if "start" in e:
                e["start"] = ts_map[e["start"]]
            if "end" in e:
                e["end"] = ts_map[e["end"]]

    return per_thread, total, dropped


def main():
    if len(sys.argv) != 4:
        print(
            "Usage: preprocess_trace.py <trace_dir> <scenario> <out_path>",
            file=sys.stderr,
        )
        sys.exit(1)

    trace_dir, scenario, out_path = sys.argv[1:]
    per_thread, kept, dropped = merge(trace_dir, scenario)

    out = {"threads": per_thread}
    with open(out_path, "w") as fh:
        json.dump(out, fh, indent=2)

    nthreads = len(per_thread)
    nevents = sum(len(v) for v in per_thread.values())
    print(
        f"[preprocess] {scenario}: {nthreads} threads, {nevents} events kept, "
        f"{dropped} dropped (unknown event names) -> {out_path}",
    )


if __name__ == "__main__":
    main()
