#!/usr/bin/env python3

"""Check schema, exact action coverage, and Category B trace quality."""

from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path
from typing import Any

SCENARIOS = (
    "ramfs_normal",
    "ramfs_faults",
    "ramfs_zero_append",
    "ext2_buffered",
    "ext2_direct",
    "overlap_prefix",
    "reference_restart",
)
REFERENCE_EVENTS = {
    "InterruptibleBackendReturnEintr",
    "SysReadTranslateEintr",
    "SysWriteTranslateEintr",
    "HandlePendingSignalClassify",
    "HandlePendingSignalRestart",
    "HandlePendingSignalNoRestart",
    "TaskRestartSyscall",
}
STATE_FIELDS = {
    "pc",
    "op_kind",
    "backend_mode",
    "requested",
    "copied",
    "committed",
    "reported",
    "copied_total",
    "committed_total",
    "visible_total",
    "reported_total",
    "result",
    "entry_result",
    "copy_fault",
    "io_offset",
    "explicit_offset",
    "append_mode",
    "old_file_size",
    "planned_end",
    "page_state",
    "range_class",
    "file_size_snapshot",
    "entry_data_epoch",
    "buffer_epochs",
    "vector_index",
    "vector_intervened_all",
    "attempt_id",
    "effect_token",
    "direct_part",
    "sa_restart",
    "restart_pending",
    "interruptible_backend",
    "ofd_offset",
    "expected_offset",
    "offset_owner",
    "data_owner",
    "file_size",
    "expected_file_size",
    "size_publication_owners",
    "data_epoch",
    "pending_bios",
    "completed_bios",
    "positional_ofd_expected_all",
    "commit_counts",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace_dir", type=Path)
    return parser.parse_args()


def load_events(path: Path) -> list[dict[str, Any]]:
    events = [json.loads(line) for line in path.read_text().splitlines() if line]
    if not events:
        raise SystemExit(f"{path}: empty trace")
    return events


def overlaps(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return int(left["start"]) <= int(right["end"]) and int(right["start"]) <= int(
        left["end"]
    )


def main() -> None:
    trace_dir = parse_args().trace_dir
    instrumented = {
        line.strip()
        for line in (trace_dir.parent / "harness" / "instrumented-events.txt")
        .read_text()
        .splitlines()
        if line.strip()
    }
    covered: collections.Counter[str] = collections.Counter()
    pinned_covered: set[str] = set()
    reference_covered: set[str] = set()
    scenario_events: dict[str, list[dict[str, Any]]] = {}

    for scenario in SCENARIOS:
        path = trace_dir / f"{scenario}.ndjson"
        events = load_events(path)
        scenario_events[scenario] = events
        if len(events) > 200:
            raise SystemExit(f"{path}: {len(events)} events exceeds the focused-trace cap")
        owners = {str(event["args"].get("owner")) for event in events}
        if owners != {"0", "1"}:
            raise SystemExit(f"{path}: logical owners are {sorted(owners)}, expected 0 and 1")

        orders: set[int] = set()
        last_by_actor: dict[str, int] = {}
        for event in events:
            if event.get("tag") != "trace" or event.get("event") not in instrumented:
                raise SystemExit(f"{path}: invalid tag/event: {event}")
            if set(event.get("state", {})) != STATE_FIELDS:
                missing = sorted(STATE_FIELDS - set(event.get("state", {})))
                extra = sorted(set(event.get("state", {})) - STATE_FIELDS)
                raise SystemExit(f"{path}: state schema mismatch missing={missing} extra={extra}")
            if not isinstance(event.get("args"), dict):
                raise SystemExit(f"{path}: args is not an object")
            start = event.get("start")
            end = event.get("end")
            order = event.get("shadow_order")
            if not all(isinstance(value, int) for value in (start, end, order)):
                raise SystemExit(f"{path}: noninteger interval/order")
            if start > end or order <= 0 or order in orders:
                raise SystemExit(f"{path}: invalid or duplicate interval/order")
            orders.add(order)
            actor = str(event["tid"])
            if actor in last_by_actor and order <= last_by_actor[actor]:
                raise SystemExit(f"{path}: {actor} order is not monotonic")
            last_by_actor[actor] = order
            covered[event["event"]] += 1
            if scenario == "reference_restart":
                reference_covered.add(event["event"])
            else:
                pinned_covered.add(event["event"])

        raw_files = list((trace_dir / "raw").glob(f"{scenario}-*.ndjson"))
        raw_events = [
            json.loads(line)
            for raw_file in raw_files
            for line in raw_file.read_text().splitlines()
            if line
        ]
        if not raw_events or max(int(event["start"]) for event in raw_events) < 1_000_000:
            raise SystemExit(f"{path}: raw trace lacks real TSC timestamps")

    if set(covered) != instrumented:
        raise SystemExit(
            "coverage mismatch: "
            f"missing={sorted(instrumented - set(covered))} "
            f"unexpected={sorted(set(covered) - instrumented)}"
        )
    pinned_required = instrumented - REFERENCE_EVENTS
    if not pinned_required <= pinned_covered:
        raise SystemExit(
            f"pinned ext2/ramfs coverage missing {sorted(pinned_required - pinned_covered)}"
        )
    if not REFERENCE_EVENTS <= reference_covered:
        raise SystemExit(
            f"reference coverage missing {sorted(REFERENCE_EVENTS - reference_covered)}"
        )
    if REFERENCE_EVENTS & pinned_covered:
        raise SystemExit(
            f"pinned traces emitted reference-only events {sorted(REFERENCE_EVENTS & pinned_covered)}"
        )

    overlap = scenario_events["overlap_prefix"]
    left = [event for event in overlap if event["tid"] == "0"]
    right = [event for event in overlap if event["tid"] == "1"]
    pairs = [(first, second) for first in left for second in right]
    overlap_count = sum(overlaps(first, second) for first, second in pairs)
    ratio = overlap_count / len(pairs) if pairs else 0.0
    if ratio < 0.20:
        raise SystemExit(
            f"overlap_prefix: overlap {overlap_count}/{len(pairs)} ({ratio:.1%}) is below 20%"
        )

    print(
        f"trace checks passed: {len(instrumented)} event types; "
        f"overlap {overlap_count}/{len(pairs)} ({ratio:.1%})"
    )


if __name__ == "__main__":
    main()
