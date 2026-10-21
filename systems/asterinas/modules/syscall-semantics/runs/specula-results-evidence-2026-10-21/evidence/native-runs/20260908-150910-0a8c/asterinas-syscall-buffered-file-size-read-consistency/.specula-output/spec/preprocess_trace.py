#!/usr/bin/env python3
"""Group per-thread events and compress timeboxes without imposing total order."""

import argparse
import json
from pathlib import Path


def assemble(bootstrap, paths):
    threads = bootstrap["threads"]
    if not threads or len(set(threads)) != len(threads):
        raise ValueError("bootstrap needs distinct thread IDs")
    traces = {tid: [] for tid in threads}
    times = set()
    for path in paths:
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            if not line.strip():
                continue
            event = json.loads(line)
            if event.get("tag") != "trace" or event.get("tid") not in traces:
                raise ValueError(f"{path}:{line_number}: unexpected event tag/thread")
            start, end = event["start"], event["end"]
            if type(start) is not int or type(end) is not int or not 0 <= start <= end:
                raise ValueError(f"{path}:{line_number}: invalid timebox")
            prior = traces[event["tid"]]
            if prior and prior[-1]["end"] > start:
                raise ValueError(f"{path}:{line_number}: thread order overlaps or reverses")
            prior.append(event)
            times.update((start, end))
    if not times:
        raise ValueError("empty traces cannot validate an implementation")
    compressed = {value: i for i, value in enumerate(sorted(times), 1)}
    for events in traces.values():
        for event in events:
            event["start"] = compressed[event["start"]]
            event["end"] = compressed[event["end"]]
    return dict(bootstrap, traces=traces)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bootstrap", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("raw", type=Path, nargs="+")
    args = parser.parse_args()
    result = assemble(json.loads(args.bootstrap.read_text()), args.raw)
    args.output.write_text(json.dumps(result, separators=(",", ":")) + "\n")
    print(f"Wrote {sum(map(len, result['traces'].values()))} events for {len(result['traces'])} threads")


if __name__ == "__main__":
    main()
