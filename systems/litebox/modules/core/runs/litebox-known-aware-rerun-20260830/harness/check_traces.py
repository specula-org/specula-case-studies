#!/usr/bin/env python3
"""Check LiteBox trace schema, action coverage, and cross-thread overlap."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path


EXPECTED = {
    "ResolverParentDirAndName",
    "InMemRmdirAt",
    "InMemRecreateAt",
    "InMemCreateFileAt",
    "TaskSysChdirValidate",
    "TaskSysChdirPublish",
    "TaskResolvePathRelative",
    "TaskChunkedReadBegin",
    "TaskChunkedReadChunk",
    "TaskChunkedReadFinish",
    "FilesStateCloseSlot",
    "FilesStateReuseSlot",
    "DescriptorsDuplicate",
    "TaskSysGetdirent64Load",
    "TaskSysGetdirent64Produce",
    "TaskSysGetdirent64Store",
    "EpollFileAddInterest",
    "TaskDoMmapFileHost",
    "PageManagerRegisterExistingMapping",
    "TaskSysMunmap",
    "TaskMaybePatchOnMprotectExecCollect",
    "TaskMaybePatchExecSegmentApply",
    "TaskSysMprotectRaw",
    "TaskDoClonePrepare",
    "TaskDoClonePublishParentTid",
    "TaskDoCloneStackValidationSuccess",
    "TaskDoCloneStackValidationFailure",
    "ThreadStateNewThread",
    "TaskDoCloneTransferInit",
    "SnpLinuxKernelSpawnThreadSuccess",
    "SnpLinuxKernelSpawnThreadFailure",
    "ProcessDetachThread",
    "FutexManagerWaitInsert",
    "FutexManagerWaitCompareMatch",
    "FutexManagerWaitCompareMismatch",
    "FutexManagerWakeBegin",
    "FutexManagerWakeSelect",
    "FutexManagerWakeComplete",
    "FutexManagerWaitReturn",
    "FutexSetValue",
}


def overlaps(left: dict[str, object], right: dict[str, object]) -> bool:
    return int(left["start"]) <= int(right["end"]) and int(right["start"]) <= int(left["end"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace_dir", type=Path)
    args = parser.parse_args()

    counts: Counter[str] = Counter()
    overlap_total = 0
    pair_total = 0
    best_overlap = (0.0, "", 0, 0)
    for path in sorted(args.trace_dir.glob("*.ndjson")):
        if path.name == "trace.ndjson":
            continue
        with path.open(encoding="utf-8") as stream:
            records = [json.loads(line) for line in stream if line.strip()]
        if len(records) != 1:
            raise ValueError(f"{path}: expected exactly one preprocessed JSON record")
        record = records[0]
        threads = record["threads"]
        events = record["events"]
        if set(threads) != set(events):
            raise ValueError(f"{path}: threads/events key mismatch")
        for tid in threads:
            for event in events[tid]:
                required = {"tag", "event", "tid", "start", "end", "args", "state"}
                if required - event.keys() or event["tag"] != "trace" or event["tid"] != tid:
                    raise ValueError(f"{path}: malformed event {event}")
                if event["event"] not in EXPECTED:
                    raise ValueError(f"{path}: unknown action {event['event']}")
                counts[event["event"]] += 1
        trace_overlap = 0
        trace_pairs = 0
        for index, left_tid in enumerate(threads):
            for right_tid in threads[index + 1 :]:
                for left in events[left_tid]:
                    for right in events[right_tid]:
                        pair_total += 1
                        trace_pairs += 1
                        did_overlap = overlaps(left, right)
                        overlap_total += did_overlap
                        trace_overlap += did_overlap
        trace_ratio = trace_overlap / trace_pairs if trace_pairs else 0.0
        if trace_ratio > best_overlap[0]:
            best_overlap = (trace_ratio, path.name, trace_overlap, trace_pairs)

    missing = sorted(EXPECTED - counts.keys())
    if missing:
        raise SystemExit("missing event types: " + ", ".join(missing))
    if overlap_total == 0:
        raise SystemExit("no cross-thread timebox overlap found")
    if best_overlap[0] < 0.20:
        raise SystemExit(
            f"best cross-thread overlap ratio is only {best_overlap[0]:.1%} in {best_overlap[1]}"
        )
    ratio = overlap_total / pair_total if pair_total else 0.0
    print(f"coverage: {len(counts)}/{len(EXPECTED)} event types")
    print(f"cross-thread overlap: {overlap_total}/{pair_total} pairs ({ratio:.1%})")
    print(
        f"best overlap trace: {best_overlap[1]} "
        f"{best_overlap[2]}/{best_overlap[3]} pairs ({best_overlap[0]:.1%})"
    )


if __name__ == "__main__":
    main()
