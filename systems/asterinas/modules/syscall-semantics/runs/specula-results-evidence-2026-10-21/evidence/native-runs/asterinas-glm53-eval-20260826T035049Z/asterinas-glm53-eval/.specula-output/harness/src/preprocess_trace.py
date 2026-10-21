#!/usr/bin/env python3
"""Extract, remap, and compress Asterinas per-thread timebox traces."""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path


TRACE_MARKER = "SPECULA_TRACE "
CONFIG_MARKER = "SPECULA_CONFIG "
REQUIRED_STATE_FIELDS = {
    "shared_offset",
    "offset_owner",
    "file_size",
    "cache_capacity",
    "adapter_profile",
    "phase",
    "kind",
    "uses_shared_offset",
    "explicit_offset",
    "entry_start",
    "logical_avail",
    "copy_limit",
    "iov_index",
    "requested",
    "entry_copied",
    "entry_returned",
    "copied",
    "committed",
    "reported",
    "offset_advanced",
    "entry_status",
    "result",
    "last_fault_progress",
    "published_eof",
    "read_past_eof",
    "size_at_entry",
    "syscall_id",
    "attempt_id",
    "restart_pending",
    "signal_pending",
    "sa_restart",
    "effect_log_len",
    "commit_log_len",
}


def marker_payload(line: str, marker: str) -> str | None:
    offset = line.find(marker)
    if offset < 0:
        return None
    return line[offset + len(marker) :].strip().rstrip("\r")


def load_log(path: Path) -> tuple[dict[str, list[dict]], list[dict]]:
    events: dict[str, list[dict]] = defaultdict(list)
    configs: list[dict] = []
    for line_number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        trace_payload = marker_payload(line, TRACE_MARKER)
        config_payload = marker_payload(line, CONFIG_MARKER)
        if trace_payload is None and config_payload is None:
            continue
        try:
            record = json.loads(trace_payload or config_payload)
        except json.JSONDecodeError as error:
            raise SystemExit(f"{path}:{line_number}: invalid trace JSON: {error}") from error
        if trace_payload is not None:
            validate_event(record, path, line_number)
            events[record["tid"]].append(record)
        else:
            validate_config(record, path, line_number)
            configs.append(record)
    if not events:
        raise SystemExit(f"{path}: no {TRACE_MARKER.strip()} records found")
    return events, configs


def validate_event(event: dict, path: Path, line_number: int) -> None:
    required = {"tag", "event", "tid", "start", "end", "args", "state"}
    missing = required - event.keys()
    if missing:
        raise SystemExit(f"{path}:{line_number}: event missing {sorted(missing)}")
    if event["tag"] != "trace":
        raise SystemExit(f"{path}:{line_number}: event tag is not 'trace'")
    if not isinstance(event["start"], int) or not isinstance(event["end"], int):
        raise SystemExit(f"{path}:{line_number}: timestamps are not integers")
    if event["start"] <= 1_000_000 or event["end"] < event["start"]:
        raise SystemExit(f"{path}:{line_number}: timestamps are not real ordered TSC values")
    state_missing = REQUIRED_STATE_FIELDS - event["state"].keys()
    if state_missing:
        raise SystemExit(f"{path}:{line_number}: state missing {sorted(state_missing)}")


def validate_config(config: dict, path: Path, line_number: int) -> None:
    if config.get("tag") != "config" or "initial_state" not in config:
        raise SystemExit(f"{path}:{line_number}: malformed config record")
    if config.get("dropped") != 0:
        raise SystemExit(f"{path}:{line_number}: kernel trace buffer dropped events")


def raw_tid_key(raw_tid: str) -> int:
    match = re.fullmatch(r"k(\d+)", raw_tid)
    if not match:
        raise SystemExit(f"invalid raw kernel TID {raw_tid!r}")
    return int(match.group(1))


def verify_config(configs: list[dict], raw_tids: set[str]) -> dict:
    by_tid = {config["raw_tid"]: config for config in configs}
    missing = raw_tids - by_tid.keys()
    if missing:
        raise SystemExit(f"missing config records for {sorted(missing)}")
    initial_states = [by_tid[tid]["initial_state"] for tid in sorted(raw_tids)]
    if any(state != initial_states[0] for state in initial_states[1:]):
        raise SystemExit("per-thread config records disagree on initial state")
    return initial_states[0]


def verify_thread_order(events: dict[str, list[dict]]) -> None:
    for raw_tid, thread_events in events.items():
        previous_end = 0
        for index, event in enumerate(thread_events, 1):
            if event["start"] < previous_end:
                raise SystemExit(
                    f"{raw_tid} event {index} starts before the previous event ended"
                )
            previous_end = event["end"]


def remap_and_compress(events: dict[str, list[dict]]) -> tuple[dict, dict[str, str]]:
    raw_tids = sorted(events, key=raw_tid_key)
    if len(raw_tids) != 2:
        raise SystemExit(f"expected exactly two traced threads, found {len(raw_tids)}")
    tid_map = {raw_tid: f"t{index}" for index, raw_tid in enumerate(raw_tids, 1)}
    timestamps = sorted(
        {
            timestamp
            for thread_events in events.values()
            for event in thread_events
            for timestamp in (event["start"], event["end"])
        }
    )
    timestamp_map = {timestamp: index for index, timestamp in enumerate(timestamps, 1)}

    remapped = {}
    for raw_tid in raw_tids:
        thread_events = []
        for original in events[raw_tid]:
            event = json.loads(json.dumps(original))
            event["tid"] = tid_map[raw_tid]
            event["start"] = timestamp_map[event["start"]]
            event["end"] = timestamp_map[event["end"]]
            owner = event["state"]["offset_owner"]
            if owner != "none":
                if owner not in tid_map:
                    raise SystemExit(f"offset owner {owner!r} has no trace stream")
                event["state"]["offset_owner"] = tid_map[owner]
            thread_events.append(event)
        remapped[tid_map[raw_tid]] = thread_events
    return remapped, tid_map


def overlap_stats(events: dict[str, list[dict]]) -> tuple[int, int, float]:
    tids = sorted(events)
    cross_pairs = 0
    overlapping_pairs = 0
    for left_index, left_tid in enumerate(tids):
        for right_tid in tids[left_index + 1 :]:
            for left in events[left_tid]:
                for right in events[right_tid]:
                    cross_pairs += 1
                    if max(left["start"], right["start"]) <= min(
                        left["end"], right["end"]
                    ):
                        overlapping_pairs += 1
    rate = overlapping_pairs / cross_pairs if cross_pairs else 0.0
    return overlapping_pairs, cross_pairs, rate


def vector_scalar_window(events: dict[str, list[dict]]) -> tuple[str, str, int] | None:
    vector_tids = [
        tid
        for tid, thread_events in events.items()
        if any(event["event"] == "DoSysWritevBegin" for event in thread_events)
    ]
    scalar_tids = [
        tid
        for tid, thread_events in events.items()
        if any(event["event"] == "SysWriteBegin" for event in thread_events)
    ]
    if len(vector_tids) != 1 or len(scalar_tids) != 1:
        return None
    vector_tid = vector_tids[0]
    scalar_tid = scalar_tids[0]
    if vector_tid == scalar_tid:
        return None

    vector_events = events[vector_tid]
    scalar_events = events[scalar_tid]
    vector_dispatches = [
        event
        for event in vector_events
        if event["event"] == "DoSysWritevHandleEntry"
        and event["state"]["iov_index"] == 2
    ]
    vector_acquires = [
        event
        for event in vector_events
        if event["event"] == "InodeHandleWriteAcquireOffset"
    ]
    scalar_acquires = [
        event
        for event in scalar_events
        if event["event"] == "InodeHandleWriteAcquireOffset"
    ]
    scalar_commits = [
        event
        for event in scalar_events
        if event["event"] == "InodeHandleCommitOffset"
    ]
    if not vector_dispatches or len(vector_acquires) < 2:
        return None
    if not scalar_acquires or not scalar_commits:
        return None

    first_dispatch = vector_dispatches[0]
    scalar_acquire = scalar_acquires[0]
    scalar_commit = scalar_commits[0]
    second_vector_acquire = vector_acquires[1]
    if not (
        first_dispatch["end"] < scalar_acquire["start"]
        and scalar_commit["end"] < second_vector_acquire["start"]
    ):
        return None
    return vector_tid, scalar_tid, second_vector_acquire["end"]


def trace_stats(events: dict[str, list[dict]], tid_map: dict[str, str]) -> dict:
    overlaps, pairs, rate = overlap_stats(events)
    return {
        "events": sum(len(thread_events) for thread_events in events.values()),
        "threads": len(events),
        "event_types": sorted(
            {
                event["event"]
                for thread_events in events.values()
                for event in thread_events
            }
        ),
        "overlapping_cross_thread_pairs": overlaps,
        "cross_thread_pairs": pairs,
        "overlap_rate": rate,
        "vector_scalar_interleaving": vector_scalar_window(events) is not None,
        "tid_map": tid_map,
    }


def contention_prefix(events: dict[str, list[dict]]) -> tuple[dict[str, list[dict]], int]:
    window = vector_scalar_window(events)
    if window is None:
        raise SystemExit("no scalar commit occurs between the two vector entries")
    _, _, cutoff = window
    prefix = {
        tid: [event for event in thread_events if event["end"] <= cutoff]
        for tid, thread_events in events.items()
    }
    return prefix, cutoff


def write_raw_threads(raw_dir: Path, events: dict[str, list[dict]]) -> None:
    raw_dir.mkdir(parents=True, exist_ok=True)
    for raw_tid, thread_events in events.items():
        path = raw_dir / f"trace-thread-{raw_tid}.ndjson"
        with path.open("w") as output:
            for event in thread_events:
                output.write(json.dumps(event, separators=(",", ":")) + "\n")


def write_cfg(template: Path, output: Path, initial_state: dict, tids: list[str]) -> None:
    text = template.read_text()
    replacements = {
        r"(?m)^\s*Thread = .*$": f'    Thread = {{{", ".join(json.dumps(tid) for tid in tids)}}}',
        r"(?m)^\s*InitialSharedOffset = .*$": (
            f'    InitialSharedOffset = {initial_state["shared_offset"]}'
        ),
        r"(?m)^\s*InitialFileSize = .*$": (
            f'    InitialFileSize = {initial_state["file_size"]}'
        ),
        r"(?m)^\s*InitialCacheCapacity = .*$": (
            f'    InitialCacheCapacity = {initial_state["cache_capacity"]}'
        ),
    }
    for pattern, replacement in replacements.items():
        text, count = re.subn(pattern, replacement, text)
        if count != 1:
            raise SystemExit(f"could not replace cfg field matching {pattern!r}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--raw-dir", required=True, type=Path)
    parser.add_argument("--cfg-template", required=True, type=Path)
    parser.add_argument("--cfg-output", required=True, type=Path)
    parser.add_argument("--stats-output", required=True, type=Path)
    parser.add_argument("--contention-prefix-output", type=Path)
    parser.add_argument("--contention-prefix-cfg-output", type=Path)
    parser.add_argument("--contention-prefix-stats-output", type=Path)
    args = parser.parse_args()

    prefix_outputs = (
        args.contention_prefix_output,
        args.contention_prefix_cfg_output,
        args.contention_prefix_stats_output,
    )
    if any(prefix_outputs) and not all(prefix_outputs):
        parser.error("all contention-prefix outputs must be specified together")

    events, configs = load_log(args.log)
    verify_thread_order(events)
    initial_state = verify_config(configs, set(events))
    write_raw_threads(args.raw_dir, events)
    remapped, tid_map = remap_and_compress(events)
    output = {"initial_state": initial_state, "traces": remapped}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, separators=(",", ":")) + "\n")
    write_cfg(args.cfg_template, args.cfg_output, initial_state, sorted(remapped))

    stats = trace_stats(remapped, tid_map)
    args.stats_output.parent.mkdir(parents=True, exist_ok=True)
    args.stats_output.write_text(json.dumps(stats, indent=2, sort_keys=True) + "\n")
    print(
        f"{args.output.name}: {stats['events']} events, "
        f"{len(stats['event_types'])} types, "
        f"{stats['overlapping_cross_thread_pairs']}/{stats['cross_thread_pairs']} "
        f"overlapping cross-thread pairs ({stats['overlap_rate']:.1%})"
    )

    if all(prefix_outputs):
        prefix, cutoff = contention_prefix(remapped)
        prefix_data = {"initial_state": initial_state, "traces": prefix}
        args.contention_prefix_output.parent.mkdir(parents=True, exist_ok=True)
        args.contention_prefix_output.write_text(
            json.dumps(prefix_data, separators=(",", ":")) + "\n"
        )
        write_cfg(
            args.cfg_template,
            args.contention_prefix_cfg_output,
            initial_state,
            sorted(prefix),
        )
        prefix_stats = trace_stats(prefix, tid_map)
        prefix_stats["prefix_cutoff"] = cutoff
        prefix_stats["source_trace"] = args.output.name
        args.contention_prefix_stats_output.parent.mkdir(parents=True, exist_ok=True)
        args.contention_prefix_stats_output.write_text(
            json.dumps(prefix_stats, indent=2, sort_keys=True) + "\n"
        )
        print(
            f"{args.contention_prefix_output.name}: "
            f"{prefix_stats['events']} events through timestamp {cutoff}, "
            f"{prefix_stats['overlap_rate']:.1%} overlap"
        )


if __name__ == "__main__":
    main()
