#!/usr/bin/env python3
"""Preprocess raw NDJSON traces from the tokio-broadcast harness into the
schema expected by Trace.tla:

    {
      "threads": ["s1", "s2", "r1", ...],
      "events":  { "s1": [event, ...], "r1": [event, ...] }
    }

Each event keeps `name`, `start`, `end`, `state`, plus action-specific fields
(`sender`, `receiver`, `idx`, `pos`, `value`, `rem`, `nextAfter`, `loaded`,
`wasQueued`, `numTxAfter`, `wasLast`, `triggeredBy`, `closedAfter`, `until`,
`rxCntAfter`, `missed`, `kind`, `parkedAtPos`, `next`, `reopened`).

Timestamps are compressed to dense integers (1-indexed) to keep TLC search
space small.

Usage: preprocess.py <raw.ndjson> <output.json>
"""

import json
import os
import sys


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <raw.ndjson> <output.json>", file=sys.stderr)
        sys.exit(2)

    raw_path = sys.argv[1]
    out_path = sys.argv[2]

    per_thread = {}
    all_ts = set()

    with open(raw_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"warn: skipping malformed line: {e}", file=sys.stderr)
                continue
            if ev.get("tag") != "trace":
                continue
            tid = ev.get("thread")
            if not tid:
                continue
            per_thread.setdefault(tid, []).append(ev)
            all_ts.add(ev.get("start", 0))
            all_ts.add(ev.get("end", 0))

    # Stable order of threads.
    thread_ids = sorted(per_thread.keys())

    # Sort each thread's events by start time.
    for tid in thread_ids:
        per_thread[tid].sort(key=lambda e: (e.get("start", 0), e.get("end", 0)))

    # Dense timestamp compression. Reserve 0 for unmapped/sentinel.
    sorted_ts = sorted(all_ts)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}

    for tid in thread_ids:
        for ev in per_thread[tid]:
            if "start" in ev:
                ev["start"] = ts_map[ev["start"]]
            if "end" in ev:
                ev["end"] = ts_map[ev["end"]]
            ev.pop("tag", None)
            # Drop the redundant `thread` field — it's the dict key.
            ev.pop("thread", None)

    output = {
        "threads": thread_ids,
        "events": {tid: per_thread[tid] for tid in thread_ids},
    }

    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    with open(out_path, "w") as f:
        # Emit as a single JSON line so ndJsonDeserialize sees one record.
        json.dump(output, f, separators=(",", ":"))
        f.write("\n")

    total_events = sum(len(v) for v in per_thread.values())
    print(
        f"preprocess: {raw_path} -> {out_path} "
        f"({len(thread_ids)} threads, {total_events} events, "
        f"{len(sorted_ts)} unique timestamps)"
    )


if __name__ == "__main__":
    main()
