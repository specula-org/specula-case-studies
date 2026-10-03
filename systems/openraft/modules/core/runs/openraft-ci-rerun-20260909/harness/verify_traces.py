#!/usr/bin/env python3
"""Structural and coverage checks for OpenRaft Specula NDJSON traces."""

from __future__ import annotations

import json
import sys
from pathlib import Path


COMMON_FIELDS = {
    "online",
    "role",
    "recovery_stage",
    "recovery_ready",
    "vote",
    "persistent_vote",
    "accepted_vote",
    "accepted_log",
    "submitted_vote",
    "submitted_log",
    "durable_vote",
    "durable_log",
    "flushed_vote",
    "flushed_log",
    "cluster_committed",
    "local_committed",
    "persisted_committed",
    "apply_submitted",
    "sm_applied",
    "committed_membership",
    "effective_membership",
    "candidate_granted",
    "match_index",
    "replication_session",
    "clock",
    "clock_acks",
    "lease_until",
    "read",
    "read_epoch",
    "last_read_observed",
    "last_read_required",
    "build_phase",
    "build_target",
    "build_membership",
    "snapshot_meta_last",
    "snapshot_meta_membership",
    "snapshot_accepted",
    "snapshot_submitted",
    "snapshot_flushed",
    "snapshot_last",
    "snapshot_membership",
    "install_done",
    "purge_upto",
    "purge_command",
    "durable_purged",
    "client_completed",
}

EXPECTED_EVENTS = {
    "HandleElectionTimeout",
    "EngineHandleVoteRequest",
    "SnapshotHandlerTriggerSnapshot",
}


def verify(path: Path) -> set[str]:
    events: set[str] = set()
    previous_timestamp = 0
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines:
        raise AssertionError(f"{path}: empty trace")

    for line_no, line in enumerate(lines, 1):
        record = json.loads(line)
        assert record.get("tag") == "trace", f"{path}:{line_no}: missing trace tag"
        timestamp = record.get("timestamp")
        assert isinstance(timestamp, int) and timestamp > 1_000_000_000_000, (
            f"{path}:{line_no}: timestamp is not a real clock reading"
        )
        assert timestamp >= previous_timestamp, f"{path}:{line_no}: timestamp regressed"
        previous_timestamp = timestamp

        event = record.get("event")
        assert isinstance(event, dict), f"{path}:{line_no}: missing event"
        name = event.get("name")
        assert name in EXPECTED_EVENTS, f"{path}:{line_no}: unknown event {name!r}"
        events.add(name)

        nid = event.get("nid")
        state = event.get("state")
        assert isinstance(nid, int) and nid > 0, f"{path}:{line_no}: invalid nid"
        assert isinstance(state, dict), f"{path}:{line_no}: missing state"
        missing = sorted(COMMON_FIELDS - state.keys())
        assert not missing, f"{path}:{line_no}: missing state fields: {missing}"
        assert len(state["match_index"]) == 3, f"{path}:{line_no}: wrong node count"
        assert isinstance(event.get("details"), dict), f"{path}:{line_no}: missing details"

    return events


def main() -> int:
    paths = [Path(arg) for arg in sys.argv[1:]]
    if not paths:
        raise SystemExit("usage: verify_traces.py TRACE.ndjson...")

    covered: set[str] = set()
    for path in paths:
        covered.update(verify(path))
        print(f"verified {path}: {sum(1 for _ in path.open(encoding='utf-8'))} events")

    missing = EXPECTED_EVENTS - covered
    if missing:
        raise AssertionError(f"instrumented events missing from all traces: {sorted(missing)}")
    print(f"instrumented event coverage: {', '.join(sorted(covered))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
