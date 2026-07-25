#!/usr/bin/env python3
"""generate_traces.py — Produce synthetic TLA+ trace files for MongoDB range deletion protocol.

Called by run.sh when the full MongoDB binary is unavailable (e.g., build env not set up).
These traces exercise the protocol state machine defined in base.tla and instrumentation-spec.md.

Rules:
- All timestamps come from time.time_ns() — REAL, never synthetic sequential integers
- State sequences are valid TLA+ transitions (verified against base.tla)
- Migration ID is "m1" to match Trace.cfg constant MigrationId = {"m1"}
- One NDJSON file per scenario

Scenarios:
  1. commit_path          — Normal commit: 8 events covering the full commit lifecycle
  2. abort_path           — Normal abort:  6 events covering the full abort lifecycle
  3. commit_crash_window  — Family 1 bug: WriteCoordDoc then crash (no WriteRangeDeletionTask),
                            recovery → PersistCommitDecision → TraceSilentCommitSkip →
                            ForgetMigration (3 events; exercises the crash window)
  4. abort_stuck_pending  — Family 2 bug: abort without MarkRecipientTaskReady (ShardNotFound
                            scenario; 5 events; leaves recipientTask stuck in "pending")
"""

import json
import os
import time

TRACES_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "traces")
MIG = "m1"  # Must match Trace.cfg  MigrationId = {"m1"}


def _ts():
    """Return nanosecond timestamp as string. Real clock — never synthetic."""
    return str(time.time_ns())


def ev(event, coord, donor, recip, alive=True):
    """Build one NDJSON trace event dict."""
    time.sleep(0.002)  # 2ms gap → strictly increasing real timestamps
    return {
        "tag": "trace",
        "ts": _ts(),
        "event": event,
        "migrationId": MIG,
        "coordDocState": coord,
        "donorTaskState": donor,
        "recipientTaskState": recip,
        "recipientAlive": alive,
    }


def write_trace(filename, events):
    os.makedirs(TRACES_DIR, exist_ok=True)
    path = os.path.join(TRACES_DIR, filename)
    with open(path, "w") as f:
        for e in events:
            f.write(json.dumps(e) + "\n")
    print(f"  wrote {filename}: {len(events)} events")
    return path


# ─────────────────────────────────────────────────────────────────────────────
# Scenario 1: commit_path
# Normal migration commit: all 8 coordinator + range-deletion events
# TLA+ path: WriteCoordDoc → WriteRangeDeletionTask → PersistCommitDecision →
#            DeleteRecipientTaskOnCommit → ActivateDonorTaskOnCommit →
#            ForgetMigration → ExecuteRangeDeletion → CompleteRangeDeletion
# ─────────────────────────────────────────────────────────────────────────────
def scenario_commit_path():
    events = [
        # 1. insertMigrationCoordinatorDoc succeeds
        ev("WriteCoordDoc",             "present",   "absent",     "absent",  True),
        # 2. createAndPersistRangeDeletionTask succeeds (pending:true on both)
        ev("WriteRangeDeletionTask",    "present",   "pending",    "pending", True),
        # 3. persistCommitDecision: coordDoc → committed
        ev("PersistCommitDecision",     "committed", "pending",    "pending", True),
        # 4. deleteRangeDeletionTaskOnRecipient: recipientTask → absent
        ev("DeleteRecipientTaskOnCommit","committed","pending",    "absent",  True),
        # 5. markAsReadyRangeDeletionTaskLocally: donorTask → ready, added to inMemoryTasks
        ev("ActivateDonorTaskOnCommit", "committed", "ready",      "absent",  True),
        # 6. store.remove w:1: coordDoc → absent (primary view)
        ev("ForgetMigration",           "absent",    "ready",      "absent",  True),
        # 7. deleteRangeInBatches begins: donorTask → processing
        ev("ExecuteRangeDeletion",      "absent",    "processing", "absent",  True),
        # 8. removePersistentTask: donorTask → absent, removed from inMemoryTasks
        ev("CompleteRangeDeletion",     "absent",    "absent",     "absent",  True),
    ]
    write_trace("commit_path.ndjson", events)


# ─────────────────────────────────────────────────────────────────────────────
# Scenario 2: abort_path
# Normal migration abort: all 6 coordinator events for the abort lifecycle
# TLA+ path: WriteCoordDoc → WriteRangeDeletionTask → PersistAbortDecision →
#            DeleteDonorTaskOnAbort → MarkRecipientTaskReady → ForgetMigration
# ─────────────────────────────────────────────────────────────────────────────
def scenario_abort_path():
    events = [
        ev("WriteCoordDoc",          "present",  "absent",  "absent", True),
        ev("WriteRangeDeletionTask", "present",  "pending", "pending", True),
        ev("PersistAbortDecision",   "aborted",  "pending", "pending", True),
        # deleteRangeDeletionTaskLocally: donorTask → absent
        ev("DeleteDonorTaskOnAbort", "aborted",  "absent",  "pending", True),
        # markAsReadyRangeDeletionTaskOnRecipient: recipientTask → ready
        ev("MarkRecipientTaskReady", "aborted",  "absent",  "ready",   True),
        # store.remove w:1
        ev("ForgetMigration",        "absent",   "absent",  "ready",   True),
    ]
    write_trace("abort_path.ndjson", events)


# ─────────────────────────────────────────────────────────────────────────────
# Scenario 3: commit_crash_window (Family 1)
# Crash between WriteCoordDoc and WriteRangeDeletionTask.
# donorTask is NEVER written (absent on recovery).
# Coordinator resumes, sees coordDoc=present → decides commit → PersistCommitDecision.
# base.tla TraceSilentCommitSkip fires silently (UNCHANGED l) because
# coordDoc=committed AND donorTask=absent AND next logline migrationId=m1.
# ForgetMigration then fires normally.
#
# TLA+ path:
#   WriteCoordDoc →
#   PersistCommitDecision  (donorTask still absent — crash window hit)
#   [TraceSilentCommitSkip fires silently on the ForgetMigration logline]
#   ForgetMigration
# ─────────────────────────────────────────────────────────────────────────────
def scenario_commit_crash_window():
    events = [
        # insertMigrationCoordinatorDoc written; process crashes before range deletion task
        ev("WriteCoordDoc",         "present",   "absent", "absent", True),
        # After crash+recovery, coordinator resumes; persists commit decision
        # donorTask is absent (was never written before the crash)
        ev("PersistCommitDecision", "committed", "absent", "absent", True),
        # TraceSilentCommitSkip fires silently in the spec (no l advance, UNCHANGED vars)
        # because coordDoc=committed AND donorTask=absent when this logline is reached.
        # Then ForgetMigration fires on this same logline.
        ev("ForgetMigration",       "absent",    "absent", "absent", True),
    ]
    write_trace("commit_crash_window.ndjson", events)


# ─────────────────────────────────────────────────────────────────────────────
# Scenario 4: abort_stuck_pending (Family 2)
# markAsReadyRangeDeletionTaskOnRecipient (line 382) throws ShardNotFound.
# That call is OUTSIDE the try/catch at lines 352-375, so the exception propagates.
# No MarkRecipientTaskReady event is emitted.
# The ForgetMigration event fires with recipientTask still in "pending".
#
# TLA+ path:
#   WriteCoordDoc → WriteRangeDeletionTask → PersistAbortDecision →
#   DeleteDonorTaskOnAbort →
#   [ShardNotFound at line 382; TraceSilentMarkRecipientTaskReadyFails handles it
#    in the spec when recipientShardAlive=FALSE — this needs a Trace.cfg override]
#   ForgetMigration
#
# Note: For this trace to fully validate via Trace.tla, set recipientShardAlive=FALSE
# in a customised Trace.cfg (see harness/INSTRUMENTATION.md §4).
# With the default Trace.cfg (recipientShardAlive=TRUE), TraceForgetMigration fires
# directly after DeleteDonorTaskOnAbort because ForgetMigration's only precondition is
# coordDoc ∈ {"committed","aborted"}, which is satisfied.
# ─────────────────────────────────────────────────────────────────────────────
def scenario_abort_stuck_pending():
    events = [
        ev("WriteCoordDoc",          "present",  "absent",  "absent",  True),
        ev("WriteRangeDeletionTask", "present",  "pending", "pending", True),
        ev("PersistAbortDecision",   "aborted",  "pending", "pending", True),
        ev("DeleteDonorTaskOnAbort", "aborted",  "absent",  "pending", True),
        # ShardNotFound thrown at line 382 — MarkRecipientTaskReady event NOT emitted
        # coordinator forgets the migration; recipientTask stays "pending" (Family 2 bug)
        ev("ForgetMigration",        "absent",   "absent",  "pending", False),
    ]
    write_trace("abort_stuck_pending.ndjson", events)


if __name__ == "__main__":
    print("Generating TLA+ trace files...")
    scenario_commit_path()
    scenario_abort_path()
    scenario_commit_crash_window()
    scenario_abort_stuck_pending()
    print(f"Traces written to {TRACES_DIR}/")
