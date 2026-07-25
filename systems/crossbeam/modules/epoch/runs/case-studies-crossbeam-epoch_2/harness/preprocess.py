#!/usr/bin/env python3
"""Merge per-thread NDJSON shards into a single JSON file for Trace.tla.

Output format:
    {"threads": {"t1": [event...], "t2": [event...]}}
where each event has 'event', 'start', 'end', and per-action fields.

Timestamps are compressed: every unique (start, end) value across all threads
is mapped to a dense 1-indexed integer that preserves ordering. This keeps
ViablePIDs cheap and avoids exploding TLC's state hashes on raw rdtsc values.
"""

import json
import sys
from pathlib import Path


def merge(trace_dir: Path, output_path: Path) -> None:
    threads = {}
    timestamps = set()

    # Discover all per-thread shards.
    shards = sorted(trace_dir.glob("trace-*.ndjson"))
    if not shards:
        print(f"warning: no shards found in {trace_dir}", file=sys.stderr)

    for shard in shards:
        # File name like "trace-t1.ndjson" → tid = "t1".
        tid = shard.stem.replace("trace-", "")
        events = []
        with shard.open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError as e:
                    print(f"warning: bad json in {shard}: {e}", file=sys.stderr)
                    continue
                if obj.get("tag") != "trace":
                    continue
                # Drop the envelope's 'tag' / 'thread' fields — Trace.tla
                # accesses events via the per-thread map.
                obj.pop("tag", None)
                obj.pop("thread", None)
                events.append(obj)
                timestamps.add(obj["start"])
                timestamps.add(obj["end"])
        threads[tid] = events

    # Compress timestamps: sorted unique → 1-indexed dense ints.
    sorted_ts = sorted(timestamps)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}
    for tid in threads:
        for ev in threads[tid]:
            ev["start"] = ts_map[ev["start"]]
            ev["end"] = ts_map[ev["end"]]

    output = {"threads": threads}
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w") as f:
        json.dump(output, f, indent=2)

    total = sum(len(v) for v in threads.values())
    print(
        f"merged {total} events from {len(threads)} thread(s); "
        f"{len(sorted_ts)} unique timestamps → {output_path}"
    )


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <trace_dir> <output_path>", file=sys.stderr)
        sys.exit(2)
    merge(Path(sys.argv[1]), Path(sys.argv[2]))
