#!/usr/bin/env python3

"""Reconstruct strong post-state snapshots from Asterinas raw trace records."""

from __future__ import annotations

import argparse
import collections
import copy
import json
from pathlib import Path
from typing import Any

PAGE_BYTES = 4096
OWNERS = ("0", "1")
NO_THREAD = "NoThread"

ZERO = "Zero"
POSITIVE = "Positive"
COMPLETE = "Complete"

NO_OP = "NoOp"
SHARED_READ = "SharedRead"
SHARED_WRITE = "SharedWrite"
VECTOR_READ = "VectorRead"
VECTOR_WRITE = "VectorWrite"
POSITIONAL_READ = "PositionalRead"
POSITIONAL_WRITE = "PositionalWrite"

EXT2_BUFFERED = "Ext2Buffered"
EXT2_DIRECT = "Ext2Direct"
RAMFS = "Ramfs"

UP_TO_DATE = "UpToDate"
UNINIT = "Uninit"
IN_PLACE = "InPlace"
EXTENDING = "Extending"

NO_ENTRY_RESULT = "NoEntryResult"
ENTRY_OK = "EntryOk"
ENTRY_FAULT = "EntryFault"
ENTRY_EINTR = "EntryEintr"
ENTRY_RESTART_SYS = "EntryRestartSys"

NO_RESULT = "NoResult"
PENDING = "Pending"
SUCCESS = "Success"
SHORT_SUCCESS = "ShortSuccess"
FAULT = "Fault"
INTERRUPTED = "Interrupted"
RESTARTED = "Restarted"

EVENT_NAMES = {
    1: "SysReadStart",
    2: "SysWriteStart",
    3: "SysPread64Start",
    4: "SysPwrite64Start",
    5: "DoSysReadvStart",
    6: "DoSysWritevStart",
    7: "InodeHandleReadAcquireOffset",
    8: "InodeHandleWriteAcquireOffset",
    9: "InodeHandleReadAtBegin",
    10: "InodeHandleWriteAtBegin",
    11: "InodeHandleWriteChooseAppendStart",
    12: "RamInodeReadAtSnapshotSize",
    13: "Ext2InodeWriteAtZeroLengthReturn",
    14: "FileOpsAcquireData",
    15: "InodeInnerPrepareWrite",
    16: "RamInodeWriteAtPublishMetadata",
    17: "FileOpsReadAtCopyComplete",
    18: "FileOpsReadAtCopyFaultZero",
    19: "FileOpsReadAtCopyFaultPositive",
    20: "FileOpsWriteAtCopyComplete",
    21: "FileOpsWriteAtCopyFaultZero",
    22: "FileOpsWriteAtCopyFaultPositive",
    23: "BioSegmentWriteFallibleComplete",
    24: "BioSegmentWriteFallibleFaultZero",
    25: "BioSegmentWriteFallibleFaultPositive",
    26: "InterruptibleBackendReturnEintr",
    27: "FileOpsReadAtFinish",
    28: "InodeInnerReadDirectAtFinish",
    29: "VmoWritePagesWithBackendFinishSuccess",
    30: "VmoWritePagesWithBackendFaultRetain",
    31: "VmoWritePagesWithBackendFaultDiscard",
    32: "VmoWriteAnonymousPagesFinishSuccess",
    33: "VmoWriteAnonymousPagesFinishFault",
    34: "BioSubmit",
    35: "SubmittedBioComplete",
    36: "IoBatchWaitAll",
    37: "InodeInnerWriteDirectAtCommit",
    38: "InodeInnerWriteDirectAtRollback",
    39: "FileOpsReleaseData",
    40: "InodeHandleReadReturnOk",
    41: "InodeHandleReadReturnError",
    42: "InodeHandleWriteReturnOk",
    43: "InodeHandleWriteReturnError",
    44: "DoSysReadvEntryOkContinue",
    45: "DoSysReadvEntryOkReturn",
    46: "DoSysReadvEntryFaultReturn",
    47: "DoSysWritevEntryOkContinue",
    48: "DoSysWritevEntryOkReturn",
    49: "DoSysWritevEntryFaultReturn",
    50: "SysReadReturn",
    51: "SysWriteReturn",
    52: "SysPread64Return",
    53: "SysPwrite64Return",
    54: "SysReadTranslateEintr",
    55: "SysWriteTranslateEintr",
    56: "HandlePendingSignalClassify",
    57: "HandlePendingSignalRestart",
    58: "HandlePendingSignalNoRestart",
    59: "TaskRestartSyscall",
}

STARTS = {
    "SysReadStart": (SHARED_READ, "AcquireOffset"),
    "SysWriteStart": (SHARED_WRITE, "AcquireOffset"),
    "SysPread64Start": (POSITIONAL_READ, "BeginPositional"),
    "SysPwrite64Start": (POSITIONAL_WRITE, "BeginPositional"),
    "DoSysReadvStart": (VECTOR_READ, "AcquireOffset"),
    "DoSysWritevStart": (VECTOR_WRITE, "AcquireOffset"),
}
READ_KINDS = {SHARED_READ, VECTOR_READ, POSITIONAL_READ}
WRITE_KINDS = {SHARED_WRITE, VECTOR_WRITE, POSITIONAL_WRITE}
SHARED_KINDS = {SHARED_READ, SHARED_WRITE, VECTOR_READ, VECTOR_WRITE}
VECTOR_KINDS = {VECTOR_READ, VECTOR_WRITE}
POSITIONAL_KINDS = {POSITIONAL_READ, POSITIONAL_WRITE}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("scenario")
    parser.add_argument("log", type=Path)
    parser.add_argument("trace_dir", type=Path)
    return parser.parse_args()


def units(value: str) -> int:
    return {ZERO: 0, POSITIVE: 1, COMPLETE: 2}[value]


def progress_of_units(value: int) -> str:
    if value == 0:
        return ZERO
    if value == 1:
        return POSITIVE
    return COMPLETE


def progress_of_bytes(value: int, requested: int) -> str:
    if value == 0:
        return ZERO
    if requested > 0 and value >= requested:
        return COMPLETE
    return POSITIVE


def abstract_offset(value: int) -> int:
    if value % PAGE_BYTES:
        raise ValueError(f"offset/size {value} is not page aligned")
    return value // PAGE_BYTES


def backend_for_mode(mode: int) -> str:
    if mode in {1, 5}:
        return RAMFS
    if mode in {2, 4}:
        return EXT2_BUFFERED
    if mode == 3:
        return EXT2_DIRECT
    raise ValueError(f"unknown backend mode {mode}")


def page_state(raw_value: int) -> str:
    return UNINIT if raw_value == 2 else UP_TO_DATE


def initial_state() -> dict[str, Any]:
    per_owner_defaults: dict[str, Any] = {
        "pc": "Idle",
        "op_kind": NO_OP,
        "backend_mode": EXT2_BUFFERED,
        "requested": ZERO,
        "copied": ZERO,
        "committed": ZERO,
        "reported": ZERO,
        "copied_total": 0,
        "committed_total": 0,
        "visible_total": 0,
        "reported_total": 0,
        "result": NO_RESULT,
        "entry_result": NO_ENTRY_RESULT,
        "copy_fault": False,
        "io_offset": 0,
        "explicit_offset": 0,
        "append_mode": False,
        "old_file_size": 2,
        "planned_end": 2,
        "page_state": UP_TO_DATE,
        "range_class": IN_PLACE,
        "file_size_snapshot": 2,
        "entry_data_epoch": 0,
        "buffer_epochs": [],
        "vector_index": 1,
        "vector_intervened": False,
        "attempt_id": 0,
        "effect_token": 0,
        "direct_part": 1,
        "sa_restart": False,
        "restart_pending": False,
        "interruptible_backend": False,
        "raw_requested_bytes": 0,
    }
    state = {
        key: {owner: copy.deepcopy(value) for owner in OWNERS}
        for key, value in per_owner_defaults.items()
    }
    state.update(
        {
            "ofd_offset": 0,
            "expected_offset": 0,
            "offset_owner": NO_THREAD,
            "data_owner": NO_THREAD,
            "file_size": 2,
            "expected_file_size": 2,
            "size_publication_owners": set(),
            "data_epoch": 0,
            "pending_bios": set(),
            "completed_bios": set(),
            "commit_counts": collections.Counter(),
            "positional_ofd_expected": {owner: 0 for owner in OWNERS},
        }
    )
    return state


def active_positional(state: dict[str, Any], owner: str) -> bool:
    return (
        state["op_kind"][owner] in POSITIONAL_KINDS
        and state["pc"][owner] not in {"Idle", "BeginPositional"}
    )


def track_positional(state: dict[str, Any], new_offset: int) -> None:
    for owner in OWNERS:
        if active_positional(state, owner):
            state["positional_ofd_expected"][owner] = new_offset


def vector_offset_gap(state: dict[str, Any], owner: str) -> bool:
    if state["op_kind"][owner] not in VECTOR_KINDS or state["pc"][owner] == "Idle":
        return False
    return (
        state["pc"][owner] == "VectorDispatch"
        and state["vector_index"][owner] < 2
        and state["entry_result"][owner] == ENTRY_OK
        and units(state["reported"][owner]) == units(state["requested"][owner])
    ) or (
        state["pc"][owner] == "AcquireOffset"
        and state["vector_index"][owner] > 1
        and state["offset_owner"] != owner
    )


def vector_data_gap(state: dict[str, Any], owner: str) -> bool:
    if state["op_kind"][owner] not in VECTOR_KINDS or state["pc"][owner] == "Idle":
        return False
    return (
        state["pc"][owner] == "InodeReturn"
        and state["data_owner"] != owner
        and state["vector_index"][owner] < 2
        and state["entry_result"][owner] == ENTRY_OK
        and units(state["reported"][owner]) == units(state["requested"][owner])
    ) or (
        state["pc"][owner] == "VectorDispatch"
        and state["vector_index"][owner] < 2
        and state["entry_result"][owner] == ENTRY_OK
        and units(state["reported"][owner]) == units(state["requested"][owner])
    ) or (
        state["vector_index"][owner] > 1
        and state["pc"][owner] in {"AcquireOffset", "SnapshotSize", "AcquireData"}
        and state["data_owner"] != owner
    )


def vector_range_start(state: dict[str, Any], owner: str) -> int:
    if (
        state["vector_index"][owner] > 1
        and state["pc"][owner] in {"SnapshotSize", "AcquireData"}
    ):
        return state["io_offset"][owner] - state["reported_total"][owner]
    return state["io_offset"][owner]


def ranges_overlap(left_start: int, left_units: int, right_start: int, right_units: int) -> bool:
    return (
        left_units > 0
        and right_units > 0
        and left_start < right_start + right_units
        and right_start < left_start + left_units
    )


def mark_vector_intervened(
    state: dict[str, Any],
    actor: str,
    actor_attempt: int,
    kind: str,
    start: int,
    effect_units: int,
) -> None:
    for owner in OWNERS:
        data_conflict = kind in WRITE_KINDS or (
            kind in READ_KINDS and state["op_kind"][owner] == VECTOR_WRITE
        )
        conflict = (
            kind in SHARED_KINDS and vector_offset_gap(state, owner)
        ) or (
            data_conflict
            and vector_data_gap(state, owner)
            and ranges_overlap(start, effect_units, vector_range_start(state, owner), 4)
        )
        if conflict and not (
            owner == actor and state["attempt_id"][owner] == actor_attempt
        ):
            state["vector_intervened"][owner] = True


def mark_vector_offset(state: dict[str, Any], actor: str, actor_attempt: int) -> None:
    for owner in OWNERS:
        if vector_offset_gap(state, owner) and not (
            owner == actor and state["attempt_id"][owner] == actor_attempt
        ):
            state["vector_intervened"][owner] = True


def bio_effect(bio: tuple[Any, ...]) -> tuple[str, int, int]:
    owner, _attempt, effect, entry, segment, _range_start = bio
    part = segment if entry == 0 else (entry - 1) * 2 + segment
    return owner, effect, part


def bio_base_start(bio: tuple[Any, ...]) -> int:
    return int(bio[5]) - (int(bio[4]) - 1)


def bio_at_segment(bio: tuple[Any, ...], segment: int) -> tuple[Any, ...]:
    return (bio[0], bio[1], bio[2], bio[3], segment, bio_base_start(bio) + segment - 1)


def snapshot(state: dict[str, Any], owner: str) -> dict[str, Any]:
    result = {
        key: copy.deepcopy(state[key][owner])
        for key in (
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
            "attempt_id",
            "effect_token",
            "direct_part",
            "sa_restart",
            "restart_pending",
            "interruptible_backend",
        )
    }
    result["vector_intervened_all"] = copy.deepcopy(state["vector_intervened"])
    result.update(
        {
            "ofd_offset": state["ofd_offset"],
            "expected_offset": state["expected_offset"],
            "offset_owner": state["offset_owner"],
            "data_owner": state["data_owner"],
            "file_size": state["file_size"],
            "expected_file_size": state["expected_file_size"],
            "size_publication_owners": sorted(state["size_publication_owners"]),
            "data_epoch": state["data_epoch"],
            "pending_bios": [list(value) for value in sorted(state["pending_bios"])],
            "completed_bios": [list(value) for value in sorted(state["completed_bios"])],
            "positional_ofd_expected_all": copy.deepcopy(
                state["positional_ofd_expected"]
            ),
            "commit_counts": [
                {"key": list(key), "count": count}
                for key, count in sorted(state["commit_counts"].items())
                if count
            ],
        }
    )
    return result


def require(condition: bool, raw_event: dict[str, Any], message: str) -> None:
    if not condition:
        name = EVENT_NAMES.get(int(raw_event["kind"]), raw_event["kind"])
        raise ValueError(
            f"shadow reconstruction rejected {name} order={raw_event['shadow_order']}: {message}"
        )


def start_page_states(events: list[dict[str, Any]]) -> dict[tuple[str, int], str]:
    result: dict[tuple[str, int], str] = {}
    for event in events:
        if int(event["kind"]) in {21, 22}:
            result[(str(event["tid"]), int(event["attempt"]))] = page_state(
                int(event["raw"][2])
            )
    return result


def restart_flags(events: list[dict[str, Any]]) -> dict[tuple[str, int], bool]:
    result: dict[tuple[str, int], bool] = {}
    for event in events:
        if int(event["kind"]) in {57, 58}:
            result[(str(event["tid"]), int(event["attempt"]))] = bool(event["raw"][0])
    return result


def reconstruct(
    state: dict[str, Any],
    event: dict[str, Any],
    pages: dict[tuple[str, int], str],
    restarts: dict[tuple[str, int], bool],
) -> dict[str, Any]:
    kind = int(event["kind"])
    name = EVENT_NAMES[kind]
    raw = [int(value) for value in event["raw"]]
    owner = str(raw[0]) if kind == 35 else str(event["tid"])
    attempt = int(event["attempt"])
    effect = int(event["effect"])
    require(owner in OWNERS, event, f"invalid owner {owner}")

    args: dict[str, Any] = {"owner": owner}

    if name in STARTS:
        op_kind, next_pc = STARTS[name]
        require(state["pc"][owner] == "Idle", event, "start while owner is not idle")
        mode = raw[0]
        request = ZERO if raw[1] == 0 else COMPLETE
        explicit = abstract_offset(raw[2])
        observed_size = abstract_offset(raw[4])
        require(observed_size == state["file_size"], event, "unmodeled file-size change")
        require(attempt == state["attempt_id"][owner] + 1, event, "attempt id mismatch")
        require(effect == attempt, event, "fresh effect token mismatch")
        initial_page = pages.get((owner, attempt), UP_TO_DATE)
        restartable = restarts.get((owner, attempt), False)

        state["pc"][owner] = next_pc
        state["op_kind"][owner] = op_kind
        state["backend_mode"][owner] = backend_for_mode(mode)
        state["requested"][owner] = COMPLETE if name in {"SysReadStart", "SysPread64Start", "DoSysReadvStart"} else request
        state["explicit_offset"][owner] = explicit
        state["append_mode"][owner] = bool(raw[3]) if name == "SysWriteStart" else False
        state["sa_restart"][owner] = restartable
        state["interruptible_backend"][owner] = mode == 4
        state["attempt_id"][owner] = attempt
        state["effect_token"][owner] = effect
        state["restart_pending"][owner] = False
        state["copied"][owner] = ZERO
        state["committed"][owner] = ZERO
        state["reported"][owner] = ZERO
        state["copied_total"][owner] = 0
        state["committed_total"][owner] = 0
        state["visible_total"][owner] = 0
        state["reported_total"][owner] = 0
        state["result"][owner] = PENDING
        state["entry_result"][owner] = NO_ENTRY_RESULT
        state["copy_fault"][owner] = False
        state["io_offset"][owner] = 0
        state["old_file_size"][owner] = state["file_size"]
        state["planned_end"][owner] = state["file_size"]
        state["page_state"][owner] = initial_page
        state["range_class"][owner] = IN_PLACE
        state["file_size_snapshot"][owner] = state["file_size"]
        state["entry_data_epoch"][owner] = state["data_epoch"]
        state["buffer_epochs"][owner] = []
        state["vector_index"][owner] = 1
        state["vector_intervened"][owner] = False
        state["direct_part"][owner] = 1
        state["raw_requested_bytes"][owner] = raw[1]

        backend = state["backend_mode"][owner]
        if name == "SysReadStart":
            args.update({"backend": backend, "restartable": restartable})
        elif name == "SysWriteStart":
            args.update(
                {
                    "backend": backend,
                    "requested": request,
                    "append_mode": bool(raw[3]),
                    "restartable": restartable,
                    "page_state": initial_page,
                }
            )
        elif name == "SysPread64Start":
            args.update({"backend": backend, "explicit_offset": explicit})
        elif name == "SysPwrite64Start":
            args.update(
                {
                    "backend": backend,
                    "requested": request,
                    "explicit_offset": explicit,
                    "page_state": initial_page,
                }
            )
        elif name == "DoSysReadvStart":
            args["backend"] = backend
        elif name == "DoSysWritevStart":
            args.update({"backend": backend, "page_state": initial_page})

    elif name in {"InodeHandleReadAcquireOffset", "InodeHandleWriteAcquireOffset"}:
        require(state["pc"][owner] == "AcquireOffset", event, "bad acquire pc")
        observed = abstract_offset(raw[0])
        require(observed == state["ofd_offset"], event, "observed OFD offset diverged")
        require(state["offset_owner"] == NO_THREAD, event, "OFD lock already owned")
        state["offset_owner"] = owner
        state["io_offset"][owner] = observed
        if name == "InodeHandleReadAcquireOffset":
            state["pc"][owner] = (
                "SnapshotSize" if state["backend_mode"][owner] == RAMFS else "AcquireData"
            )
        else:
            state["pc"][owner] = "ChooseAppendStart" if state["append_mode"][owner] else "AcquireData"

    elif name in {"InodeHandleReadAtBegin", "InodeHandleWriteAtBegin"}:
        require(state["pc"][owner] == "BeginPositional", event, "bad positional pc")
        actual_offset = abstract_offset(raw[0])
        observed_ofd = abstract_offset(raw[1])
        state["io_offset"][owner] = actual_offset
        state["positional_ofd_expected"][owner] = observed_ofd
        state["pc"][owner] = (
            "SnapshotSize"
            if name == "InodeHandleReadAtBegin" and state["backend_mode"][owner] == RAMFS
            else "AcquireData"
        )

    elif name == "InodeHandleWriteChooseAppendStart":
        require(state["pc"][owner] == "ChooseAppendStart", event, "bad append pc")
        old_offset = abstract_offset(raw[0])
        new_offset = abstract_offset(raw[1])
        require(old_offset == state["ofd_offset"], event, "append old offset mismatch")
        if new_offset != old_offset:
            mark_vector_offset(state, owner, state["attempt_id"][owner])
        state["ofd_offset"] = new_offset
        state["io_offset"][owner] = new_offset
        track_positional(state, new_offset)
        state["pc"][owner] = "AcquireData"

    elif name == "RamInodeReadAtSnapshotSize":
        require(state["pc"][owner] == "SnapshotSize", event, "bad snapshot pc")
        state["file_size_snapshot"][owner] = abstract_offset(raw[0])
        state["pc"][owner] = "AcquireData"

    elif name == "FileOpsAcquireData":
        require(state["pc"][owner] == "AcquireData", event, "bad data-acquire pc")
        require(state["data_owner"] == NO_THREAD, event, "data guard already owned")
        state["data_owner"] = owner
        state["pc"][owner] = "CopyRead" if state["op_kind"][owner] in READ_KINDS else "PrepareWrite"

    elif name == "Ext2InodeWriteAtZeroLengthReturn":
        require(state["pc"][owner] == "AcquireData", event, "bad zero-write pc")
        state["reported"][owner] = ZERO
        state["entry_result"][owner] = ENTRY_OK
        state["pc"][owner] = "InodeReturn"

    elif name == "InodeInnerPrepareWrite":
        require(state["pc"][owner] == "PrepareWrite", event, "bad prepare pc")
        old_size = abstract_offset(raw[0])
        planned_end = abstract_offset(raw[1])
        state["old_file_size"][owner] = old_size
        state["planned_end"][owner] = planned_end
        state["range_class"][owner] = EXTENDING if planned_end > old_size else IN_PLACE
        state["entry_result"][owner] = NO_ENTRY_RESULT
        state["reported"][owner] = ZERO
        state["pc"][owner] = "DirectCopy" if state["backend_mode"][owner] == EXT2_DIRECT else "CopyWrite"

    elif name == "RamInodeWriteAtPublishMetadata":
        require(state["pc"][owner] == "PrepareWrite", event, "bad ramfs metadata pc")
        old_size = abstract_offset(raw[0])
        planned_end = abstract_offset(raw[1])
        post_size = abstract_offset(raw[2])
        state["old_file_size"][owner] = old_size
        state["planned_end"][owner] = planned_end
        state["range_class"][owner] = EXTENDING if planned_end > old_size else IN_PLACE
        if post_size > state["file_size"]:
            mark_vector_intervened(
                state,
                owner,
                state["attempt_id"][owner],
                state["op_kind"][owner],
                state["io_offset"][owner],
                units(state["requested"][owner]),
            )
            state["size_publication_owners"].add(owner)
        state["file_size"] = post_size
        state["pc"][owner] = "CopyWrite"

    elif name in {
        "FileOpsReadAtCopyComplete",
        "FileOpsReadAtCopyFaultZero",
        "FileOpsReadAtCopyFaultPositive",
    }:
        require(state["pc"][owner] == "CopyRead", event, "bad read-copy pc")
        copied = progress_of_bytes(raw[1], raw[0])
        state["raw_requested_bytes"][owner] = raw[0]
        state["copied"][owner] = copied
        state["copy_fault"][owner] = name != "FileOpsReadAtCopyComplete"
        state["entry_data_epoch"][owner] = raw[4]
        if raw[1] > 0:
            mark_vector_intervened(
                state,
                owner,
                state["attempt_id"][owner],
                state["op_kind"][owner],
                state["io_offset"][owner],
                units(copied),
            )
        state["pc"][owner] = "BackendFinish"

    elif name in {
        "FileOpsWriteAtCopyComplete",
        "FileOpsWriteAtCopyFaultZero",
        "FileOpsWriteAtCopyFaultPositive",
    }:
        require(state["pc"][owner] == "CopyWrite", event, "bad write-copy pc")
        copied = progress_of_bytes(raw[1], raw[0])
        state["raw_requested_bytes"][owner] = raw[0]
        state["copied"][owner] = copied
        state["copy_fault"][owner] = name != "FileOpsWriteAtCopyComplete"
        state["page_state"][owner] = page_state(raw[2])
        if name == "FileOpsWriteAtCopyFaultPositive":
            state["committed"][owner] = ZERO if raw[3] == 0 else POSITIVE
            args["retained_prefix"] = state["committed"][owner]
        state["pc"][owner] = "BackendFinish"

    elif name in {
        "BioSegmentWriteFallibleComplete",
        "BioSegmentWriteFallibleFaultZero",
        "BioSegmentWriteFallibleFaultPositive",
    }:
        require(state["pc"][owner] == "DirectCopy", event, "bad direct-copy pc")
        part = raw[3]
        state["direct_part"][owner] = part
        if name == "BioSegmentWriteFallibleComplete":
            state["copied"][owner] = POSITIVE if part == 1 else COMPLETE
            state["copy_fault"][owner] = False
            state["pc"][owner] = "DirectSubmit"
        elif name == "BioSegmentWriteFallibleFaultZero":
            state["copied"][owner] = ZERO if part == 1 else POSITIVE
            state["copy_fault"][owner] = True
            state["pc"][owner] = "DirectRollback"
        else:
            state["copied"][owner] = POSITIVE
            state["copy_fault"][owner] = True
            state["pc"][owner] = "DirectRollback"

    elif name == "InterruptibleBackendReturnEintr":
        require(state["pc"][owner] == "BackendFinish", event, "bad EINTR pc")
        if raw[1] and units(state["copied"][owner]) > 0:
            state["committed"][owner] = state["copied"][owner]
            state["data_epoch"] = raw[2]
            key = (owner, state["effect_token"][owner], state["vector_index"][owner] if state["op_kind"][owner] in VECTOR_KINDS else 0)
            state["commit_counts"][key] += 1
            mark_vector_intervened(
                state,
                owner,
                state["attempt_id"][owner],
                state["op_kind"][owner],
                state["io_offset"][owner],
                units(state["copied"][owner]),
            )
        state["size_publication_owners"].discard(owner)
        state["entry_result"][owner] = ENTRY_EINTR
        state["reported"][owner] = ZERO
        state["pc"][owner] = "ReleaseData"

    elif name in {"FileOpsReadAtFinish", "InodeInnerReadDirectAtFinish"}:
        require(state["pc"][owner] == "BackendFinish", event, "bad read-finish pc")
        state["reported"][owner] = (
            progress_of_bytes(raw[1], state["raw_requested_bytes"][owner])
            if raw[0]
            else ZERO
        )
        state["entry_result"][owner] = ENTRY_OK if raw[0] else ENTRY_FAULT
        state["file_size"] = abstract_offset(raw[2])
        state["pc"][owner] = "ReleaseData"

    elif name in {
        "VmoWritePagesWithBackendFinishSuccess",
        "VmoWritePagesWithBackendFaultRetain",
        "VmoWritePagesWithBackendFaultDiscard",
        "VmoWriteAnonymousPagesFinishSuccess",
        "VmoWriteAnonymousPagesFinishFault",
    }:
        require(state["pc"][owner] == "BackendFinish", event, "bad write-finish pc")
        is_success = name in {
            "VmoWritePagesWithBackendFinishSuccess",
            "VmoWriteAnonymousPagesFinishSuccess",
        }
        is_retained = name in {
            "VmoWritePagesWithBackendFinishSuccess",
            "VmoWritePagesWithBackendFaultRetain",
            "VmoWriteAnonymousPagesFinishSuccess",
            "VmoWriteAnonymousPagesFinishFault",
        } and units(state["copied"][owner]) > 0
        if name == "VmoWritePagesWithBackendFaultDiscard":
            state["committed"][owner] = ZERO
        else:
            state["committed"][owner] = state["copied"][owner]
        if is_retained:
            state["data_epoch"] = (
                raw[2]
                if name.startswith("VmoWriteAnonymous")
                or name == "VmoWritePagesWithBackendFinishSuccess"
                else raw[1]
            )
            key = (owner, state["effect_token"][owner], state["vector_index"][owner] if state["op_kind"][owner] in VECTOR_KINDS else 0)
            state["commit_counts"][key] += 1
            mark_vector_intervened(
                state,
                owner,
                state["attempt_id"][owner],
                state["op_kind"][owner],
                state["io_offset"][owner],
                units(state["committed"][owner]),
            )
        if name.startswith("VmoWriteAnonymous"):
            state["file_size"] = abstract_offset(raw[1])
        else:
            state["file_size"] = abstract_offset(raw[1] if name == "VmoWritePagesWithBackendFinishSuccess" else raw[0])
        if is_success and units(state["copied"][owner]) > 0:
            state["expected_file_size"] = max(
                state["expected_file_size"], state["planned_end"][owner]
            )
        if name.startswith("VmoWriteAnonymous"):
            state["size_publication_owners"].discard(owner)
        state["reported"][owner] = state["copied"][owner] if is_success else ZERO
        state["entry_result"][owner] = ENTRY_OK if is_success else ENTRY_FAULT
        state["pc"][owner] = "ReleaseData"

    elif name == "BioSubmit":
        require(state["pc"][owner] == "DirectSubmit", event, "bad submit pc")
        bio = (
            owner,
            raw[1],
            raw[2],
            raw[3],
            raw[4],
            abstract_offset(raw[5]),
        )
        state["pending_bios"].add(bio)
        state["direct_part"][owner] = raw[4]
        state["pc"][owner] = "DirectCopy" if raw[4] == 1 else "DirectWait"
        if raw[4] == 1:
            state["direct_part"][owner] = 2

    elif name == "SubmittedBioComplete":
        bio = (
            owner,
            raw[1],
            raw[2],
            raw[3],
            raw[4],
            abstract_offset(raw[5]),
        )
        require(bio in state["pending_bios"], event, "completion without pending BIO")
        state["pending_bios"].remove(bio)
        state["completed_bios"].add(bio)
        state["data_epoch"] = raw[6]
        state["commit_counts"][bio_effect(bio)] += 1
        mark_vector_intervened(state, owner, int(bio[1]), POSITIONAL_WRITE, int(bio[5]), 1)
        if (
            state["attempt_id"][owner] == bio[1]
            and state["effect_token"][owner] == bio[2]
        ):
            all_complete = all(
                bio_at_segment(bio, segment) in state["completed_bios"]
                for segment in (1, 2)
            )
            state["committed"][owner] = COMPLETE if all_complete else POSITIVE
        args["bio"] = list(bio)

    elif name == "IoBatchWaitAll":
        require(state["pc"][owner] == "DirectWait", event, "bad wait pc")
        state["pc"][owner] = "DirectMetadata"

    elif name == "InodeInnerWriteDirectAtCommit":
        require(state["pc"][owner] == "DirectMetadata", event, "bad direct commit pc")
        state["committed"][owner] = COMPLETE
        state["file_size"] = abstract_offset(raw[1])
        state["expected_file_size"] = max(
            state["expected_file_size"], state["planned_end"][owner]
        )
        state["reported"][owner] = COMPLETE
        state["entry_result"][owner] = ENTRY_OK
        state["pc"][owner] = "ReleaseData"

    elif name == "InodeInnerWriteDirectAtRollback":
        require(state["pc"][owner] == "DirectRollback", event, "bad direct rollback pc")
        state["file_size"] = abstract_offset(raw[0])
        state["reported"][owner] = ZERO
        state["entry_result"][owner] = ENTRY_FAULT
        state["pc"][owner] = "ReleaseData"

    elif name == "FileOpsReleaseData":
        require(state["pc"][owner] == "ReleaseData", event, "bad release pc")
        require(state["data_owner"] == owner, event, "wrong data owner")
        state["data_owner"] = NO_THREAD
        state["pc"][owner] = "InodeReturn"

    elif name in {
        "InodeHandleReadReturnOk",
        "InodeHandleReadReturnError",
        "InodeHandleWriteReturnOk",
        "InodeHandleWriteReturnError",
    }:
        require(state["pc"][owner] == "InodeReturn", event, "bad inode-return pc")
        success = name.endswith("Ok")
        positional = bool(raw[3])
        observed_ofd = abstract_offset(raw[2])
        if not positional:
            state["ofd_offset"] = observed_ofd
            state["offset_owner"] = NO_THREAD
        if success and not positional:
            reported_units = units(state["reported"][owner])
            if name == "InodeHandleWriteReturnOk" and state["append_mode"][owner]:
                state["expected_offset"] = state["io_offset"][owner] + reported_units
            else:
                state["expected_offset"] += reported_units
            track_positional(state, observed_ofd)
        state["pc"][owner] = (
            "VectorDispatch"
            if state["op_kind"][owner] in VECTOR_KINDS
            else "SyscallDispatch"
        )

    elif name in {
        "DoSysReadvEntryOkContinue",
        "DoSysReadvEntryOkReturn",
        "DoSysReadvEntryFaultReturn",
        "DoSysWritevEntryOkContinue",
        "DoSysWritevEntryOkReturn",
        "DoSysWritevEntryFaultReturn",
    }:
        require(state["pc"][owner] == "VectorDispatch", event, "bad vector-dispatch pc")
        is_read = name.startswith("DoSysReadv")
        is_fault = name.endswith("FaultReturn")
        is_continue = name.endswith("OkContinue")
        state["copied_total"][owner] += units(state["copied"][owner])
        state["committed_total"][owner] += units(state["committed"][owner])
        if is_read:
            state["visible_total"][owner] += units(state["copied"][owner])
            state["buffer_epochs"][owner].append(state["entry_data_epoch"][owner])
        if not is_fault:
            state["reported_total"][owner] += units(state["reported"][owner])
        if is_continue:
            state["vector_index"][owner] += 1
            state["copied"][owner] = ZERO
            state["committed"][owner] = ZERO
            state["reported"][owner] = ZERO
            state["entry_result"][owner] = NO_ENTRY_RESULT
            state["copy_fault"][owner] = False
            state["entry_data_epoch"][owner] = state["data_epoch"]
            state["direct_part"][owner] = 1
            state["pc"][owner] = "AcquireOffset"
        else:
            if is_fault:
                state["result"][owner] = (
                    SHORT_SUCCESS if state["reported_total"][owner] > 0 else FAULT
                )
            else:
                state["result"][owner] = (
                    SUCCESS
                    if state["reported_total"][owner] == 4
                    else SHORT_SUCCESS
                )
            state["pc"][owner] = "Idle"

    elif name in {"SysReadReturn", "SysWriteReturn", "SysPread64Return", "SysPwrite64Return"}:
        require(state["pc"][owner] == "SyscallDispatch", event, "bad syscall-return pc")
        state["copied_total"][owner] = units(state["copied"][owner])
        state["committed_total"][owner] = units(state["committed"][owner])
        if name in {"SysReadReturn", "SysPread64Return"}:
            state["visible_total"][owner] = units(state["copied"][owner])
        state["reported_total"][owner] = units(state["reported"][owner])
        state["result"][owner] = SUCCESS if raw[0] else FAULT
        state["pc"][owner] = "Idle"

    elif name in {"SysReadTranslateEintr", "SysWriteTranslateEintr"}:
        require(state["pc"][owner] == "SyscallDispatch", event, "bad EINTR translate pc")
        state["entry_result"][owner] = ENTRY_RESTART_SYS
        state["pc"][owner] = "SignalClassify"

    elif name == "HandlePendingSignalClassify":
        require(state["pc"][owner] == "SignalClassify", event, "bad signal classify pc")
        state["result"][owner] = INTERRUPTED
        state["pc"][owner] = "SignalDeliver"

    elif name == "HandlePendingSignalRestart":
        require(state["pc"][owner] == "SignalDeliver", event, "bad signal restart pc")
        require(bool(raw[0]), event, "restart event without SA_RESTART")
        state["restart_pending"][owner] = True
        state["result"][owner] = RESTARTED
        state["pc"][owner] = "RestartReady"

    elif name == "HandlePendingSignalNoRestart":
        require(state["pc"][owner] == "SignalDeliver", event, "bad no-restart pc")
        require(not bool(raw[0]), event, "no-restart event with SA_RESTART")
        state["copied_total"][owner] = units(state["copied"][owner])
        state["visible_total"][owner] = units(state["copied"][owner]) if state["op_kind"][owner] in READ_KINDS else 0
        state["committed_total"][owner] = units(state["committed"][owner]) if state["op_kind"][owner] in WRITE_KINDS else 0
        state["reported_total"][owner] = 0
        state["pc"][owner] = "Idle"

    elif name == "TaskRestartSyscall":
        require(state["pc"][owner] == "RestartReady", event, "bad task-restart pc")
        require(state["restart_pending"][owner], event, "restart not pending")
        require(attempt == state["attempt_id"][owner] + 1, event, "restart attempt mismatch")
        require(effect == state["effect_token"][owner], event, "restart changed effect token")
        state["attempt_id"][owner] = attempt
        state["restart_pending"][owner] = False
        state["result"][owner] = PENDING
        state["entry_result"][owner] = NO_ENTRY_RESULT
        state["pc"][owner] = "AcquireOffset"
        state["copied"][owner] = ZERO
        state["committed"][owner] = ZERO
        state["reported"][owner] = ZERO
        state["copied_total"][owner] = 0
        state["committed_total"][owner] = 0
        state["visible_total"][owner] = 0
        state["reported_total"][owner] = 0
        state["copy_fault"][owner] = False
        state["io_offset"][owner] = 0
        state["old_file_size"][owner] = state["file_size"]
        state["planned_end"][owner] = state["file_size"]
        state["file_size_snapshot"][owner] = state["file_size"]
        state["entry_data_epoch"][owner] = state["data_epoch"]
        state["buffer_epochs"][owner] = []
        state["vector_index"][owner] = 1
        state["vector_intervened"][owner] = False
        state["direct_part"][owner] = 1

    else:
        raise ValueError(f"unhandled event {name}")

    final = {
        "tag": "trace",
        "event": name,
        "tid": str(event["tid"]),
        "start": int(event["start"]),
        "end": int(event["end"]),
        "shadow_order": int(event["shadow_order"]),
        "args": args,
        "state": snapshot(state, owner),
    }
    return final


def extract_raw(log: Path, scenario: str) -> list[dict[str, Any]]:
    text = log.read_text(errors="replace")
    if f"SPECULA_SCENARIO_PASS {scenario}" not in text:
        raise SystemExit(f"{log}: scenario did not report success")
    errors = [line for line in text.splitlines() if "SPECULA_TRACE_ERROR" in line]
    if errors:
        raise SystemExit(f"{log}: trace producer errors: {errors}")
    if "SPECULA_TRACE_BEGIN" not in text or "SPECULA_TRACE_END" not in text:
        raise SystemExit(f"{log}: incomplete trace fence")

    events: list[dict[str, Any]] = []
    prefix = "SPECULA_RAW "
    for sequence, line in enumerate(text.splitlines()):
        marker = line.find(prefix)
        if marker < 0:
            continue
        event = json.loads(line[marker + len(prefix) :])
        if event.get("tag") != "raw" or int(event.get("kind", 0)) not in EVENT_NAMES:
            raise SystemExit(f"{log}: malformed raw event: {event}")
        raw = event.get("raw")
        if not isinstance(raw, list) or len(raw) not in {8, 16}:
            raise SystemExit(f"{log}: raw event fields must contain 8 or 16 integers")
        if len(raw) == 8:
            event["raw"] = raw + [0] * 8
        event["_sequence"] = sequence
        events.append(event)
    if not events:
        raise SystemExit(f"{log}: no raw events")
    return events


def validate_raw(events: list[dict[str, Any]]) -> None:
    orders: set[int] = set()
    by_actor: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    for event in events:
        start = int(event["start"])
        end = int(event["end"])
        order = int(event["shadow_order"])
        if start > end or order <= 0 or order in orders:
            raise ValueError(f"invalid raw interval/order: {event}")
        orders.add(order)
        by_actor[str(event["tid"])].append(event)
    for actor, actor_events in by_actor.items():
        actor_orders = [int(event["shadow_order"]) for event in actor_events]
        if actor_orders != sorted(actor_orders):
            raise ValueError(f"{actor}: shadow order is not monotonic")
    for left in events:
        for right in events:
            if int(left["end"]) < int(right["start"]) and int(
                left["shadow_order"]
            ) >= int(right["shadow_order"]):
                raise ValueError(
                    "semantic order contradicts nonoverlapping intervals: "
                    f"{left['shadow_order']} !< {right['shadow_order']}"
                )


def compress_timestamps(events: list[dict[str, Any]]) -> None:
    boundaries = sorted(
        {int(event[key]) for event in events for key in ("start", "end")}
    )
    compressed = {value: index + 1 for index, value in enumerate(boundaries)}
    for event in events:
        event["start"] = compressed[int(event["start"])]
        event["end"] = compressed[int(event["end"])]


def main() -> None:
    args = parse_args()
    raw_events = extract_raw(args.log, args.scenario)
    validate_raw(raw_events)

    args.trace_dir.mkdir(parents=True, exist_ok=True)
    raw_dir = args.trace_dir / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    for actor in sorted({str(event["tid"]) for event in raw_events}):
        path = raw_dir / f"{args.scenario}-{actor}.ndjson"
        path.write_text(
            "".join(
                json.dumps(
                    {key: value for key, value in event.items() if key != "_sequence"},
                    separators=(",", ":"),
                )
                + "\n"
                for event in raw_events
                if str(event["tid"]) == actor
            )
        )

    ordered = sorted(raw_events, key=lambda event: int(event["shadow_order"]))
    pages = start_page_states(ordered)
    restarts = restart_flags(ordered)
    state = initial_state()
    final_by_sequence: dict[int, dict[str, Any]] = {}
    for event in ordered:
        final_by_sequence[int(event["_sequence"])] = reconstruct(
            state, event, pages, restarts
        )

    final_events = [
        final_by_sequence[int(event["_sequence"])]
        for event in sorted(raw_events, key=lambda item: int(item["_sequence"]))
    ]
    compress_timestamps(final_events)
    output = args.trace_dir / f"{args.scenario}.ndjson"
    output.write_text(
        "".join(
            json.dumps(event, separators=(",", ":"), sort_keys=True) + "\n"
            for event in final_events
        )
    )
    print(f"collected {len(final_events)} events in {output}")


if __name__ == "__main__":
    main()
