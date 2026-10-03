#!/usr/bin/env python3
"""Merge one LiteBox scenario's per-thread NDJSON files and compress timestamps."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("raw_dir", type=Path)
    parser.add_argument("scenario")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    per_thread: dict[str, list[dict[str, object]]] = {}
    timestamps: set[int] = set()
    for path in sorted(args.raw_dir.glob(f"{args.scenario}-t*.ndjson")):
        tid = path.stem.removeprefix(f"{args.scenario}-")
        events: list[dict[str, object]] = []
        with path.open(encoding="utf-8") as stream:
            for line_number, line in enumerate(stream, 1):
                line = line.strip()
                if not line:
                    continue
                event = json.loads(line)
                if event.get("tag") != "trace":
                    continue
                if event.get("tid") != tid:
                    raise ValueError(f"{path}:{line_number}: tid does not match filename")
                start = event.get("start")
                end = event.get("end")
                if not isinstance(start, int) or not isinstance(end, int) or start > end:
                    raise ValueError(f"{path}:{line_number}: invalid timebox")
                events.append(event)
                timestamps.update((start, end))
        if events:
            per_thread[tid] = events

    if not per_thread:
        raise SystemExit(f"no trace events found for {args.scenario}")

    dense = {timestamp: index for index, timestamp in enumerate(sorted(timestamps), 1)}
    for events in per_thread.values():
        for event in events:
            event["start"] = dense[event["start"]]
            event["end"] = dense[event["end"]]

    output = {
        "threads": sorted(per_thread),
        "events": {tid: per_thread[tid] for tid in sorted(per_thread)},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as stream:
        json.dump(output, stream, separators=(",", ":"), sort_keys=True)
        stream.write("\n")

    count = sum(map(len, per_thread.values()))
    print(
        f"{args.scenario}: {count} events, {len(per_thread)} threads, "
        f"{len(timestamps)} timestamps -> {args.output}"
    )


if __name__ == "__main__":
    main()

