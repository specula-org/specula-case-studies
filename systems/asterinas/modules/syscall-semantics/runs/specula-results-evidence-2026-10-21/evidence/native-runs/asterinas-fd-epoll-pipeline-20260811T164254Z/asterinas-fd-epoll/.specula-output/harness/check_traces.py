#!/usr/bin/env python3

"""Check structure, exact first-batch coverage, and Category B overlap."""

from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path

EXPECTED = {
    "concurrent_fcntl": collections.Counter(
        {"FcntlSetFlCapture": 2, "FcntlSetFlUse": 2}
    ),
    "dup_replace_flags": collections.Counter(
        {
            "SysDup2Equal": 1,
            "SysDup3Validate": 1,
            "FileTableDupExact": 1,
            "DupReplacementCleanup": 1,
            "FcntlSetFd": 1,
        }
    ),
    "close_reuse": collections.Counter(
        {
            "SysCloseRemove": 1,
            "ClosedFileDrop": 1,
            "FileTableDupCeil": 1,
            "SysCloseRangeCloexec": 1,
        }
    ),
    "readiness_epoll": collections.Counter(
        {
            "SignalfdUpdateMask": 1,
            "EventfdAddCounter": 1,
            "EventfdTryRead": 1,
            "EventfdNotify": 2,
            "EventfdNotifyReturn": 2,
            "EpollControlCaptureTarget": 1,
            "EntryUpdatePoll": 1,
            "EpollAddInterest": 1,
            "EpollControlPushReady": 1,
            "EpollAddNestedInterest": 1,
        }
    ),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace_dir", type=Path)
    return parser.parse_args()


def overlaps(left: dict[str, object], right: dict[str, object]) -> bool:
    return int(left["start"]) <= int(right["end"]) and int(right["start"]) <= int(
        left["end"]
    )


def main() -> None:
    trace_dir = parse_args().trace_dir
    covered: collections.Counter[str] = collections.Counter()

    for scenario, expected in EXPECTED.items():
        path = trace_dir / f"{scenario}.ndjson"
        lines = path.read_text().splitlines()
        if len(lines) != 1:
            raise SystemExit(f"{path}: expected one merged JSON record")
        document = json.loads(lines[0])
        traces = document.get("traces")
        if not isinstance(traces, dict) or set(traces) != {"t1", "t2"}:
            raise SystemExit(f"{path}: traces must contain exactly t1 and t2")
        events = traces["t1"] + traces["t2"]
        actual = collections.Counter(event["event"] for event in events)
        if actual != expected:
            raise SystemExit(f"{path}: event mismatch: expected {expected}, got {actual}")
        for actor, actor_events in traces.items():
            if any(event["tid"] != actor for event in actor_events):
                raise SystemExit(f"{path}: actor list contains another actor")
            if any(
                int(previous["start"]) > int(current["start"])
                for previous, current in zip(actor_events, actor_events[1:])
            ):
                raise SystemExit(f"{path}: {actor} events are not time ordered")
        covered.update(actual)

    instrumented = {
        line.strip()
        for line in (trace_dir.parent / "harness" / "instrumented-events.txt")
        .read_text()
        .splitlines()
        if line.strip()
    }
    if set(covered) != instrumented:
        missing = sorted(instrumented - set(covered))
        unexpected = sorted(set(covered) - instrumented)
        raise SystemExit(f"coverage mismatch: missing={missing}, unexpected={unexpected}")

    concurrent = json.loads((trace_dir / "concurrent_fcntl.ndjson").read_text())["traces"]
    cross_pairs = [(left, right) for left in concurrent["t1"] for right in concurrent["t2"]]
    overlap_count = sum(overlaps(left, right) for left, right in cross_pairs)
    ratio = overlap_count / len(cross_pairs)
    if ratio < 0.20:
        raise SystemExit(
            f"concurrent_fcntl: overlap {overlap_count}/{len(cross_pairs)} "
            f"({ratio:.1%}) is below 20%"
        )

    print(
        f"trace checks passed: {len(instrumented)} event types covered; "
        f"cross-thread overlap {overlap_count}/{len(cross_pairs)} ({ratio:.1%})"
    )


if __name__ == "__main__":
    main()
