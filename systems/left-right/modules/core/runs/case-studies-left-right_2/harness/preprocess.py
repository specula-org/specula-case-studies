#!/usr/bin/env python3
"""Merge per-thread NDJSON trace files into one JSON object suitable for
Trace.tla (Category B / timebox) consumption.

Output schema:
    { "threads": { "<tid>": [ {event, start, end, state}, ... ], ... } }

The TLA+ spec accesses traces[tid][pc[tid]] and uses [start, end] intervals
to compute ViablePIDs, so:
  - Thread events stay in per-thread emission order (no global sort).
  - Each event keeps its raw start/end timestamps (relative ns).

Usage:
    preprocess.py <input_dir> <output_file>

<input_dir> contains files named "trace-thread-<tid>.ndjson".
"""

import argparse
import glob
import json
import os
import re
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_dir", help="Directory of per-thread NDJSON files")
    parser.add_argument("output_file", help="Output merged JSON file")
    args = parser.parse_args()

    files = sorted(glob.glob(os.path.join(args.input_dir, "trace-thread-*.ndjson")))
    if not files:
        print(
            f"preprocess: no trace-thread-*.ndjson files in {args.input_dir}",
            file=sys.stderr,
        )
        sys.exit(1)

    threads = {}
    name_re = re.compile(r"trace-thread-(.+)\.ndjson$")

    for path in files:
        m = name_re.search(os.path.basename(path))
        if not m:
            continue
        tid = m.group(1)
        events = []
        with open(path, "r") as f:
            for ln, raw in enumerate(f, 1):
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    obj = json.loads(raw)
                except json.JSONDecodeError as e:
                    print(
                        f"preprocess: {path}:{ln}: bad JSON: {e}",
                        file=sys.stderr,
                    )
                    continue
                if obj.get("tag") != "trace":
                    continue
                # Normalize: keep only the fields the spec consumes.
                events.append(
                    {
                        "event": obj["event"],
                        "start": obj["start"],
                        "end": obj["end"],
                        "state": obj.get("state", {}),
                    }
                )
        if events:
            threads[tid] = events

    if not threads:
        print(
            f"preprocess: no usable events from {args.input_dir}",
            file=sys.stderr,
        )
        sys.exit(1)

    out = {"threads": threads}
    with open(args.output_file, "w") as f:
        json.dump(out, f, indent=2)

    total = sum(len(v) for v in threads.values())
    print(
        f"preprocess: wrote {args.output_file} "
        f"({total} events across {len(threads)} threads: "
        f"{', '.join(f'{k}={len(v)}' for k, v in sorted(threads.items()))})"
    )


if __name__ == "__main__":
    main()
