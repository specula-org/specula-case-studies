#!/usr/bin/env python3
"""Structural, schema, timestamp, and event-coverage checks for generated traces."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


POST_FIELDS = {
    "FastReboot_Request": {"request_kind", "phase", "attempt_outcome"},
    "CheckWarmRestartInProgress_Admit": {"checked", "phase"},
    "CheckWarmRestartInProgress_Reject": {"phase", "attempt_outcome"},
    "EnableWarmRestart": {
        "epoch",
        "owner",
        "flags",
        "phase",
        "checked",
        "admitted",
        "attempt_epoch",
        "attempt_outcome",
        "cancelled",
    },
    "ClearBoot": {
        "owner",
        "cleanup_owner",
        "flags",
        "phase",
        "cancelled",
        "snapshot_present",
        "snapshot_valid",
        "snapshot_stage",
    },
    "FastReboot_ContinueAfterSignal": {"phase", "cancelled"},
    "PauseOrchagent_IgnoreFailure": {"ready_consumed", "freeze_result"},
    "FastReboot_PauseOrchagentComplete": {"phase"},
    "FastReboot_BeginIrreversibleWork": {"phase", "irreversible_started"},
    "StopSystemdService_Success": {"writer_stopped", "shutdown_status"},
    "StopSystemdService_MaskedFailure": {"writer_stopped", "shutdown_status"},
}

TRACE_NAMES = (
    "normal_admission.ndjson",
    "signal_cancellation.ndjson",
    "two_owner_rejection.ndjson",
    "multi_asic_masked_stops.ndjson",
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace_dir", type=Path)
    args = parser.parse_args()

    covered = set()
    total = 0
    for trace_name in TRACE_NAMES:
        path = args.trace_dir / trace_name
        if not path.is_file():
            raise SystemExit(f"missing trace: {path}")
        timestamps = []
        with path.open(encoding="utf-8") as stream:
            for expected_seq, line in enumerate(stream, start=1):
                envelope = json.loads(line)
                if envelope.get("tag") != "warmreboot":
                    raise SystemExit(f"{path}:{expected_seq}: incorrect trace tag")
                if envelope.get("seq") != expected_seq:
                    raise SystemExit(f"{path}:{expected_seq}: non-contiguous collector sequence")
                timestamp = envelope.get("ts_ns")
                if not isinstance(timestamp, int) or timestamp < 1_000_000_000_000_000_000:
                    raise SystemExit(f"{path}:{expected_seq}: timestamp is not real epoch nanoseconds")
                timestamps.append(timestamp)
                event = envelope.get("event", {})
                name = event.get("name")
                if name not in POST_FIELDS:
                    raise SystemExit(f"{path}:{expected_seq}: unknown event {name!r}")
                actual_fields = set(event.get("post", {}))
                if actual_fields != POST_FIELDS[name]:
                    raise SystemExit(
                        f"{path}:{expected_seq}: {name} post fields {sorted(actual_fields)} "
                        f"do not exactly match {sorted(POST_FIELDS[name])}"
                    )
                covered.add(name)
                total += 1
        if timestamps != sorted(timestamps) or len(timestamps) != len(set(timestamps)):
            raise SystemExit(f"{path}: collector timestamps are duplicate or non-monotonic")

    missing = set(POST_FIELDS) - covered
    if missing:
        raise SystemExit(f"instrumented event types missing from traces: {sorted(missing)}")
    print(f"Verified {total} NDJSON events and {len(covered)}/{len(POST_FIELDS)} instrumented event types.")
    for name in sorted(covered):
        print(f"  {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
