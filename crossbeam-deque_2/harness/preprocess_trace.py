#!/usr/bin/env python3
"""Merge per-thread NDJSON traces into a single JSON file for Trace.tla.

Input:   <dir>/trace-<name>.ndjson    (one file per thread)
Output:  <out_path>                   (single JSON, see structure below)

Output structure:
{
  "flavor": "FIFO" | "LIFO",          # taken from --flavor argument
  "worker": [event, event, ...],
  "s1":     [event, ...],
  "s2":     [event, ...],
  ...
}

Timestamps (start, end) across all events are compressed to a dense integer
range so TLC's state space stays small. Order and overlap are preserved.
"""

import argparse
import glob
import json
import os
import sys


def load_ndjson(path: str) -> list[dict]:
    events: list[dict] = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as exc:
                print(f"warn: skip malformed line in {path}: {exc}", file=sys.stderr)
                continue
            if obj.get("tag") != "trace":
                continue
            events.append(obj)
    return events


def merge(trace_dir: str, out_path: str, flavor: str) -> None:
    pattern = os.path.join(trace_dir, "trace-*.ndjson")
    files = sorted(glob.glob(pattern))
    if not files:
        sys.exit(f"no trace-*.ndjson files in {trace_dir}")

    per_thread: dict[str, list[dict]] = {}
    all_ts: set[int] = set()

    for fp in files:
        name = os.path.basename(fp)
        # trace-<thread>.ndjson
        thread = name[len("trace-"):-len(".ndjson")]
        events = load_ndjson(fp)
        # Sort by start so ordering is canonical within thread.
        events.sort(key=lambda e: (e.get("start", 0), e.get("end", 0)))
        per_thread[thread] = events
        for e in events:
            if "start" in e:
                all_ts.add(int(e["start"]))
            if "end" in e:
                all_ts.add(int(e["end"]))

    sorted_ts = sorted(all_ts)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}

    for thread, events in per_thread.items():
        for e in events:
            if "start" in e:
                e["start"] = ts_map[int(e["start"])]
            if "end" in e:
                e["end"] = ts_map[int(e["end"])]
            # Drop the redundant `tag` and `thread` keys; not needed in the
            # per-thread array form.
            e.pop("tag", None)
            e.pop("thread", None)

    output: dict = {"flavor": flavor}
    for thread, events in sorted(per_thread.items()):
        output[thread] = events

    with open(out_path, "w") as f:
        json.dump(output, f, indent=2)

    total = sum(len(v) for v in per_thread.values())
    overlap = count_overlap(per_thread)
    print(
        f"wrote {out_path}: {total} events, {len(sorted_ts)} unique timestamps, "
        f"{len(per_thread)} threads, {overlap} cross-thread overlapping pairs"
    )


def count_overlap(per_thread: dict[str, list[dict]]) -> int:
    """Count pairs of events from different threads with overlapping intervals."""
    threads = list(per_thread.keys())
    overlap = 0
    for i in range(len(threads)):
        for j in range(i + 1, len(threads)):
            for e1 in per_thread[threads[i]]:
                for e2 in per_thread[threads[j]]:
                    s1, e1_ = e1.get("start"), e1.get("end")
                    s2, e2_ = e2.get("start"), e2.get("end")
                    if None in (s1, e1_, s2, e2_):
                        continue
                    if not (e1_ < s2 or e2_ < s1):
                        overlap += 1
    return overlap


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("trace_dir")
    ap.add_argument("out_path")
    ap.add_argument("--flavor", choices=["FIFO", "LIFO"], required=True)
    args = ap.parse_args()
    merge(args.trace_dir, args.out_path, args.flavor)


if __name__ == "__main__":
    main()
