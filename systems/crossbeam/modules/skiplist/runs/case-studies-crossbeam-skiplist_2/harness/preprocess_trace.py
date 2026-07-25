#!/usr/bin/env python3
"""Merge per-thread NDJSON timebox traces into a single JSON file for TLC.

Input layout:
    <trace_dir>/thread_1.ndjson
    <trace_dir>/thread_2.ndjson
    ...

Output: a JSON object whose keys are TLA+ thread IDs ("t1", "t2", ...)
mapping to arrays of trace events. Timestamps are compressed to dense
integers (1..N) preserving ordering. Keys/values in events are remapped
to TLA+ symbols (k1/k2/k3, v1/v2/v3) so Trace.cfg's CONSTANTS line up.

Run:
    python3 preprocess_trace.py <trace_dir> <output.json>
"""

from __future__ import annotations

import glob
import json
import os
import sys
from typing import Any


def remap_key(k: int) -> str:
    return f"k{k}" if 1 <= k <= 9 else f"k{((k - 1) % 3) + 1}"


def remap_value(v: int) -> str:
    return f"v{v}" if 1 <= v <= 9 else f"v{((v - 1) % 3) + 1}"


def transform_event(ev: dict[str, Any]) -> dict[str, Any]:
    """Remap implementation-typed fields into TLA+ string symbols."""
    out = dict(ev)
    if isinstance(ev.get("key"), int) and ev["key"] != 0:
        out["key"] = remap_key(ev["key"])
    if isinstance(ev.get("value"), int) and ev["value"] != 0:
        out["value"] = remap_value(ev["value"])
    return out


def merge(trace_dir: str, output_path: str) -> None:
    files = sorted(glob.glob(os.path.join(trace_dir, "thread_*.ndjson")))
    if not files:
        raise SystemExit(f"No thread_*.ndjson files in {trace_dir}")

    per_thread: dict[str, list[dict[str, Any]]] = {}
    all_ts: set[int] = set()

    # Map raw thread id (1-indexed) to TLA+ slot ("t1", "t2", "t3").
    # If more than 3 threads appear, we wrap modulo 3 — Trace.cfg defines
    # Thread = {"t1","t2","t3"}.
    for path in files:
        # filename is thread_<N>.ndjson
        fname = os.path.basename(path)
        raw_tid = int(fname[len("thread_"):-len(".ndjson")])

        # ALWAYS map to t1/t2/t3 by raw_tid mod 3. The instrumentation may
        # produce raw tids > 3 because each thread that touches `tla_trace`
        # increments the global counter, including occasional helpers from
        # the test runner. Empirically the *test threads* are usually 1..N.
        tid = f"t{((raw_tid - 1) % 3) + 1}"

        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if ev.get("tag") != "trace":
                    continue
                ev = transform_event(ev)
                # Force the slot to match the file's owning thread.
                ev["thread"] = tid
                per_thread.setdefault(tid, []).append(ev)
                all_ts.add(int(ev["start"]))
                all_ts.add(int(ev["end"]))

    if not per_thread:
        raise SystemExit("No trace events found.")

    # Compress timestamps to dense 1-indexed integers.
    sorted_ts = sorted(all_ts)
    ts_map = {ts: idx + 1 for idx, ts in enumerate(sorted_ts)}

    # Within a single thread, preserve emission order via a stable sort by
    # (start, end) — events from the same thread don't overlap in real
    # execution because tla_trace.rs writes them sequentially per-thread
    # under the BufWriter lock.
    output: dict[str, Any] = {}
    for tid, events in per_thread.items():
        events.sort(key=lambda e: (int(e["start"]), int(e["end"])))
        for ev in events:
            ev["start"] = ts_map[int(ev["start"])]
            ev["end"] = ts_map[int(ev["end"])]
        output[tid] = events

    # If Trace.cfg expects t1/t2/t3, also emit empty arrays for missing slots
    # so DOMAIN traces is complete.
    for slot in ("t1", "t2", "t3"):
        output.setdefault(slot, [])

    output["meta"] = {
        "num_threads": sum(1 for s in ("t1", "t2", "t3") if output[s]),
        "max_timestamp": len(sorted_ts),
        "total_events": sum(len(v) for k, v in output.items() if k != "meta"),
    }

    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)

    print(
        f"merged {output['meta']['total_events']} events from "
        f"{output['meta']['num_threads']} threads "
        f"({len(sorted_ts)} unique timestamps) -> {output_path}"
    )


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <trace_dir> <output.json>", file=sys.stderr)
        sys.exit(2)
    merge(sys.argv[1], sys.argv[2])
