#!/usr/bin/env python3
"""Check trace schema, action coverage, concurrency, and L2 state coverage."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from preprocess_trace import REQUIRED_STATE_FIELDS


EXPECTED_EVENTS = {
    "SysReadBegin",
    "SysWriteBegin",
    "SysPread64Begin",
    "SysPwrite64Begin",
    "DoSysReadvBegin",
    "DoSysWritevBegin",
    "InodeHandleReadAcquireOffset",
    "InodeHandleWriteAcquireOffset",
    "InodeHandleReadAtStart",
    "InodeHandleWriteAtStart",
    "Ext2VirtioFsReadComputeLimit",
    "RamFsExfatReadComputeLimit",
    "RamFsWritePublishRequestedEnd",
    "DeferredWritePrepare",
    "VmoRead",
    "VmoWrite",
    "ErrorFromTuple",
    "FileOpsReadReturn",
    "FileOpsWriteReturn",
    "InodeHandleCommitOffset",
    "InodeHandlePropagateError",
    "InodeHandlePositionalReturn",
    "InodeHandleReleaseOffset",
    "DoSysReadvHandleEntry",
    "DoSysWritevHandleEntry",
    "SysReadFinish",
    "SysWriteFinish",
    "SysPread64Finish",
    "SysPwrite64Finish",
    "SysReadvFinish",
    "SysWritevFinish",
    "HandlePendingSignal",
    "RestartSyscall",
}
PERMITTED_UNCOVERED = {
    "RestartSyscall": (
        "The real kernel has no confirmed regular-file post-progress EINTR producer; "
        "the harness does not inject a synthetic restart."
    )
}
VALIDATION_HELPERS = {
    "offset_owner": "TraceOffsetOwner",
}


def load_trace(path: Path) -> dict:
    lines = [line for line in path.read_text().splitlines() if line.strip()]
    if len(lines) != 1:
        raise SystemExit(f"{path}: expected one preprocessed JSON record, found {len(lines)}")
    trace = json.loads(lines[0])
    if set(trace) != {"initial_state", "traces"}:
        raise SystemExit(f"{path}: unexpected top-level fields {sorted(trace)}")
    if set(trace["traces"]) != {"t1", "t2"}:
        raise SystemExit(f"{path}: trace keys must be exactly t1 and t2")
    return trace


def check_l2(trace_spec: Path) -> None:
    text = trace_spec.read_text()
    match = re.search(
        r"ValidatePostState\(t, event\) ==(?P<body>.*?)(?=\n\(\*{20,}|\nMatchEvent)",
        text,
        flags=re.DOTALL,
    )
    if not match:
        raise SystemExit(f"{trace_spec}: ValidatePostState body not found")
    body = match.group("body")
    if re.fullmatch(r"\s*TRUE\s*", body):
        raise SystemExit(f"{trace_spec}: ValidatePostState is a TRUE stub")
    missing = set()
    for field in REQUIRED_STATE_FIELDS:
        reference = f"event.state.{field}"
        if reference in body:
            continue
        helper = VALIDATION_HELPERS.get(field)
        helper_match = None
        if helper and f"{helper}(event)" in body:
            helper_match = re.search(
                rf"(?m)^{re.escape(helper)}\(event\) ==(?P<body>.*?)(?=^\(\*{{20,}})",
                text,
                flags=re.DOTALL,
            )
        if not helper_match or reference not in helper_match.group("body"):
            missing.add(field)
    if missing:
        raise SystemExit(f"{trace_spec}: L2 does not validate {sorted(missing)}")


def check_module_events(module: Path) -> None:
    text = module.read_text()
    missing = {
        event
        for event in EXPECTED_EVENTS
        if f'"{event}"' not in text
    }
    if missing:
        raise SystemExit(f"{module}: instrumentation omits {sorted(missing)}")
    if "Mutex" in text or "fetch_add(1, Ordering::SeqCst)" in text:
        raise SystemExit(f"{module}: hot-path serialization primitive found")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--traces-dir", required=True, type=Path)
    parser.add_argument("--stats-dir", required=True, type=Path)
    parser.add_argument("--trace-spec", required=True, type=Path)
    parser.add_argument("--module", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    check_l2(args.trace_spec)
    check_module_events(args.module)
    traces = sorted(args.traces_dir.glob("specula-*.ndjson"))
    if not traces:
        raise SystemExit(f"{args.traces_dir}: no preprocessed traces")

    observed = set()
    trace_summaries = {}
    for trace_path in traces:
        trace = load_trace(trace_path)
        events = [
            event
            for thread_events in trace["traces"].values()
            for event in thread_events
        ]
        observed.update(event["event"] for event in events)
        for event in events:
            if set(event["state"]) != REQUIRED_STATE_FIELDS:
                raise SystemExit(
                    f"{trace_path}: {event['event']} captured unexpected state fields"
                )
        stats_path = args.stats_dir / f"{trace_path.stem}.json"
        stats = json.loads(stats_path.read_text())
        trace_summaries[trace_path.name] = stats

    unexpected = observed - EXPECTED_EVENTS
    if unexpected:
        raise SystemExit(f"unexpected event types: {sorted(unexpected)}")
    missing = EXPECTED_EVENTS - observed
    unsupported_missing = missing - PERMITTED_UNCOVERED.keys()
    if unsupported_missing:
        raise SystemExit(f"instrumented event types lack trace coverage: {sorted(unsupported_missing)}")

    best_overlap = max(stats["overlap_rate"] for stats in trace_summaries.values())
    interleaving_traces = sorted(
        name
        for name, stats in trace_summaries.items()
        if stats.get("vector_scalar_interleaving", False)
    )
    if not interleaving_traces:
        raise SystemExit("no trace commits a scalar operation between vector entries")

    report = {
        "expected_event_types": sorted(EXPECTED_EVENTS),
        "observed_event_types": sorted(observed),
        "uncovered": {event: PERMITTED_UNCOVERED[event] for event in sorted(missing)},
        "best_overlap_rate": best_overlap,
        "vector_scalar_interleaving_traces": interleaving_traces,
        "l2_state_fields": sorted(REQUIRED_STATE_FIELDS),
        "traces": trace_summaries,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        f"coverage: {len(observed)}/{len(EXPECTED_EVENTS)} event types; "
        f"best overlap {best_overlap:.1%}; "
        f"vector/scalar interleaving {', '.join(interleaving_traces)}; "
        f"L2 fields {len(REQUIRED_STATE_FIELDS)}"
    )


if __name__ == "__main__":
    main()
