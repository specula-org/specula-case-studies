#!/usr/bin/env python3
"""Merge per-thread NDJSON trace files into a single JSON document for TLC.

The instrumented `scc::tla_trace` writes:
    <SCC_TRACE_DIR>/<scenario>.t<TID>.ndjson

This script merges all `<scenario>.t*.ndjson` for a given scenario into:
    <out_dir>/<scenario>.json

Output format (matches `Trace.tla`'s expectation):

    {
      "threads": ["t1", "t2", ...],
      "events": {
        "t1": [ {start, end, event, ...}, ... ],
        "t2": [ ... ],
        ...
      }
    }

`start` / `end` are compressed from raw rdtsc to dense u32 indices while
preserving ordering and overlap relationships.

Usage:
    python3 preprocess.py <raw_dir> <out_dir>
        merge every scenario found in <raw_dir>
"""

from __future__ import annotations

import json
import sys
import re
from collections import defaultdict
from pathlib import Path


PER_THREAD_RE = re.compile(r"^(?P<scenario>.+)\.t(?P<tid>\d+)\.ndjson$")


def load_per_thread(raw_dir: Path) -> dict[str, dict[int, list[dict]]]:
    """Group per-thread NDJSON files by scenario → tid → events."""
    by_scenario: dict[str, dict[int, list[dict]]] = defaultdict(dict)
    for path in sorted(raw_dir.iterdir()):
        m = PER_THREAD_RE.match(path.name)
        if not m:
            continue
        scenario = m.group("scenario")
        tid = int(m.group("tid"))
        events: list[dict] = []
        for ln in path.read_text().splitlines():
            ln = ln.strip()
            if not ln:
                continue
            try:
                ev = json.loads(ln)
            except json.JSONDecodeError as e:
                print(f"warn: bad JSON in {path}: {e}", file=sys.stderr)
                continue
            if ev.get("tag") != "trace":
                continue
            events.append(ev)
        # Sort by start within thread (rdtsc may not be perfectly monotonic
        # across CPUs, but per-thread it is on stable hardware).
        events.sort(key=lambda e: (e["start"], e["end"]))
        by_scenario[scenario][tid] = events

    # Pad each scenario so every thread mentioned in EXPECTED_THREADS has a
    # (possibly empty) entry. Trace.tla uses `Thread = {"t1","t2"}` and
    # references `traces[tid]` for every thread — a missing key would raise
    # "Attempted to access nonexistent field" at TLC initial state.
    for per_tid in by_scenario.values():
        for tid in EXPECTED_THREADS:
            per_tid.setdefault(tid, [])
    return by_scenario


# Threads referenced in Trace.cfg's `Thread` constant. Keep in sync.
EXPECTED_THREADS: set[int] = {1, 2}


def compress_timestamps(per_tid: dict[int, list[dict]]) -> tuple[int, dict[int, list[dict]]]:
    """Replace raw rdtsc values with dense u32 indices preserving ordering."""
    # Collect every distinct timestamp value across threads.
    raw_ts: set[int] = set()
    for evs in per_tid.values():
        for e in evs:
            raw_ts.add(int(e["start"]))
            raw_ts.add(int(e["end"]))
    sorted_ts = sorted(raw_ts)
    ts_map = {ts: i + 1 for i, ts in enumerate(sorted_ts)}  # 1-indexed (TLA+)

    out: dict[int, list[dict]] = {}
    for tid, evs in per_tid.items():
        new_evs = []
        for e in evs:
            e2 = dict(e)
            e2["start"] = ts_map[int(e["start"])]
            e2["end"] = ts_map[int(e["end"])]
            new_evs.append(e2)
        out[tid] = new_evs
    return len(sorted_ts), out


def emit_scenario(scenario: str, per_tid: dict[int, list[dict]], out_path: Path) -> int:
    """Write the merged JSON for one scenario. Returns total event count."""
    max_ts, compressed = compress_timestamps(per_tid)
    threads = [f"t{tid}" for tid in sorted(compressed)]
    events = {f"t{tid}": compressed[tid] for tid in sorted(compressed)}
    doc = {
        "scenario": scenario,
        "threads": threads,
        "max_timestamp": max_ts,
        "events": events,
    }
    # NDJSON: one JSON object per line. Trace.tla reads via ndJsonDeserialize
    # and pulls TraceData[1] (the sole record).
    out_path.write_text(json.dumps(doc) + "\n")
    return sum(len(v) for v in events.values())


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <raw_dir> <out_dir>", file=sys.stderr)
        return 2
    raw_dir = Path(argv[1])
    out_dir = Path(argv[2])
    if not raw_dir.is_dir():
        print(f"error: raw dir not found: {raw_dir}", file=sys.stderr)
        return 2
    out_dir.mkdir(parents=True, exist_ok=True)

    by_scenario = load_per_thread(raw_dir)
    if not by_scenario:
        print(f"warn: no per-thread NDJSON files found in {raw_dir}",
              file=sys.stderr)
        return 1
    for scenario in sorted(by_scenario):
        per_tid = by_scenario[scenario]
        if not per_tid:
            continue
        out_path = out_dir / f"{scenario}.ndjson"
        n = emit_scenario(scenario, per_tid, out_path)
        nthreads = len(per_tid)
        print(f"  {scenario}: {nthreads} threads, {n} events → {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
