#!/usr/bin/env python3
"""
Prototype trace generator for mongodb-rangedeletions-secondary.

Produces NDJSON traces that mirror the state transitions of the instrumented
C++ code when it is run against test scenarios.  These traces use the SAME
event names and state fields as the real harness; only the timestamps differ
from wall clock (they use time.time_ns() so they are real, non-sequential).

Protocol note: every event captures the PRE-STATE before the action fires.
This matches how Trace.tla's ValidateNodeState/ValidateDiskTask/ValidateDeletionStep
use unprimed variables to constrain the state at each transition step.

Scenarios produced:
  1. normal_operation.ndjson      -- full happy-path deletion pipeline
  2. stepdown_mid_majority.ndjson -- step-down interrupts majority wait (F1)
  3. recovery_with_opobserver.ndjson -- op_observer fires between recovery phases (F2)
"""

import json
import os
import time

TRACES_DIR = os.path.join(os.path.dirname(__file__), "..", "traces")
os.makedirs(TRACES_DIR, exist_ok=True)

# -------------------------------------------------------------------------
# Emitter
# -------------------------------------------------------------------------

def ts():
    """Real nanosecond timestamp (non-sequential)."""
    return str(time.time_ns())

def emit(event: dict) -> str:
    """Serialise one trace event as an NDJSON line."""
    return json.dumps({"tag": "trace", "ts": ts(), **event})

def write_trace(filename: str, events: list[str]):
    path = os.path.join(TRACES_DIR, filename)
    with open(path, "w") as f:
        for line in events:
            f.write(line + "\n")
    print(f"  wrote {len(events):3d} events  →  {path}")

# -------------------------------------------------------------------------
# Event factories (PRE-STATE capture for each action)
# -------------------------------------------------------------------------

def OpObserverClearPending(node, task, role, term_init_ready, recov_phase, disk_state):
    """Pre-state: diskTaskState=disk_state (always "pending" before clearing)."""
    return emit({
        "event": "OpObserverClearPending",
        "node": node,
        "task": task,
        "state": {
            "role": role,
            "termInitReady": term_init_ready,
            "recoveryPhase": recov_phase,
            "diskTaskState": disk_state,  # "pending"
        }
    })

def StepUp(node, term):
    """Pre-state: Secondary, termInitReady=false, recoveryPhase=idle."""
    return emit({
        "event": "StepUp",
        "node": node,
        "state": {
            "role": "Secondary",
            "termInitReady": False,
            "recoveryPhase": "idle",
            "term": term,
        }
    })

def RecoveryPhase1Scan(node):
    """Pre-state: Primary, termInitReady=true, recoveryPhase=phase1."""
    return emit({
        "event": "RecoveryPhase1Scan",
        "node": node,
        "state": {
            "role": "Primary",
            "termInitReady": True,
            "recoveryPhase": "phase1",
        }
    })

def RecoveryPhase2Scan(node):
    """Pre-state: Primary, termInitReady=true, recoveryPhase=phase2."""
    return emit({
        "event": "RecoveryPhase2Scan",
        "node": node,
        "state": {
            "role": "Primary",
            "termInitReady": True,
            "recoveryPhase": "phase2",
        }
    })

def OpObserverRegisterTask(node, task, recov_phase):
    """Pre-state: Primary, termInitReady=true, current recoveryPhase."""
    return emit({
        "event": "OpObserverRegisterTask",
        "node": node,
        "task": task,
        "state": {
            "role": "Primary",
            "termInitReady": True,
            "recoveryPhase": recov_phase,
        }
    })

def DeleteOrphans(node, task, disk_state, deletion_step):
    """Pre-state: diskTaskState="ready", deletionStep="idle"."""
    return emit({
        "event": "DeleteOrphans",
        "node": node,
        "task": task,
        "state": {
            "diskTaskState": disk_state,   # "ready"
            "deletionStep": deletion_step, # "idle"
        }
    })

def MajorityWaitSuccess(node, task):
    """Pre-state: deletionStep="deleting"."""
    return emit({
        "event": "MajorityWaitSuccess",
        "node": node,
        "task": task,
        "state": {
            "deletionStep": "deleting",
        }
    })

def MajorityWaitInterrupted(node, task):
    """Pre-state: deletionStep="deleting", diskTaskState="processing"."""
    return emit({
        "event": "MajorityWaitInterrupted",
        "node": node,
        "task": task,
        "state": {
            "deletionStep": "deleting",
            "diskTaskState": "processing",
        }
    })

def CompleteInMemory(node, task):
    """Pre-state: deletionStep="waiting"."""
    return emit({
        "event": "CompleteInMemory",
        "node": node,
        "task": task,
        "state": {
            "deletionStep": "waiting",
            "completionFulfilled": False,  # pre-state; post-state=true checked by spec
        }
    })

def RemovePersistentTask(node, task):
    """Pre-state: deletionStep="completing", diskTaskState="processing"."""
    return emit({
        "event": "RemovePersistentTask",
        "node": node,
        "task": task,
        "state": {
            "deletionStep": "completing",
            "diskTaskState": "processing",
        }
    })

def StepDown(node, recov_phase):
    """Pre-state: Primary, termInitReady=true, current recoveryPhase."""
    return emit({
        "event": "StepDown",
        "node": node,
        "state": {
            "role": "Primary",
            "termInitReady": True,
            "recoveryPhase": recov_phase,
        }
    })

def ReplicateDiskState(primary, secondary, task, secondary_pre_state):
    """Secondary's pre-state disk state before replication catches up."""
    return emit({
        "event": "ReplicateDiskState",
        "primary": primary,
        "secondary": secondary,
        "task": task,
        "state": {
            "diskTaskState": secondary_pre_state,
        }
    })

# -------------------------------------------------------------------------
# Scenario 1: Normal operation
#
# Flow (n1=primary, n2=secondary, t1 = one task):
#   OpObserverClearPending(n1,t1)   -- migration commits on primary
#   OpObserverClearPending(n2,t1)   -- secondary applies the same oplog entry
#   StepUp(n1)                       -- n1 becomes primary
#   RecoveryPhase1Scan(n1)           -- no processing tasks
#   RecoveryPhase2Scan(n1)           -- finds t1 (ready), adds to in-memory
#   DeleteOrphans(n1,t1)             -- start deletion
#   ReplicateDiskState(n1,n2,t1)    -- secondary sees processing state
#   MajorityWaitSuccess(n1,t1)       -- majority wait succeeds
#   CompleteInMemory(n1,t1)          -- complete task in-memory
#   RemovePersistentTask(n1,t1)      -- delete disk document
#   ReplicateDiskState(n1,n2,t1)    -- secondary sees deleted state
# -------------------------------------------------------------------------

def scenario_normal_operation():
    """
    Full two-task normal-operation trace.
    Covers all spec actions except MajorityWaitInterrupted.
    n1 = primary, n2 = secondary, t1 and t2 = two deletion tasks.
    """
    T1 = "uuid-collA:{ _id: 0 }:{ _id: 10 }"
    T2 = "uuid-collA:{ _id: 10 }:{ _id: 20 }"

    events = []

    # --- Pre-StepUp: migration commits, clearing pending on both nodes ---
    events.append(OpObserverClearPending("n1", T1, "Secondary", False, "idle", "pending"))
    time.sleep(0.001)
    events.append(OpObserverClearPending("n2", T1, "Secondary", False, "idle", "pending"))
    time.sleep(0.001)
    events.append(OpObserverClearPending("n1", T2, "Secondary", False, "idle", "pending"))
    time.sleep(0.001)
    events.append(OpObserverClearPending("n2", T2, "Secondary", False, "idle", "pending"))
    time.sleep(0.001)
    events.append(OpObserverClearPending("n3", T2, "Secondary", False, "idle", "pending"))
    time.sleep(0.001)

    # --- n1 steps up to primary ---
    events.append(StepUp("n1", 1))
    time.sleep(0.001)

    # --- Recovery phase 1: no processing tasks ---
    events.append(RecoveryPhase1Scan("n1"))
    time.sleep(0.001)

    # --- Recovery phase 2: finds t1 and t2 (both ready), registers both ---
    events.append(RecoveryPhase2Scan("n1"))
    time.sleep(0.001)

    # --- Task t1 deletion pipeline ---
    events.append(DeleteOrphans("n1", T1, "ready", "idle"))
    time.sleep(0.001)
    # Secondary replicates the processing flag for t1
    events.append(ReplicateDiskState("n1", "n2", T1, "ready"))
    time.sleep(0.001)
    events.append(MajorityWaitSuccess("n1", T1))
    time.sleep(0.001)
    events.append(CompleteInMemory("n1", T1))
    time.sleep(0.001)
    events.append(RemovePersistentTask("n1", T1))
    time.sleep(0.001)
    # Secondary replicates the deletion of t1
    events.append(ReplicateDiskState("n1", "n2", T1, "processing"))
    time.sleep(0.001)

    # --- Task t2 deletion pipeline ---
    events.append(DeleteOrphans("n1", T2, "ready", "idle"))
    time.sleep(0.001)
    # Secondary replicates the processing flag for t2
    events.append(ReplicateDiskState("n1", "n2", T2, "ready"))
    time.sleep(0.001)
    events.append(MajorityWaitSuccess("n1", T2))
    time.sleep(0.001)
    events.append(CompleteInMemory("n1", T2))
    time.sleep(0.001)
    events.append(RemovePersistentTask("n1", T2))
    time.sleep(0.001)
    # Secondary replicates the deletion of t2
    events.append(ReplicateDiskState("n1", "n2", T2, "processing"))
    time.sleep(0.001)

    return events

# -------------------------------------------------------------------------
# Scenario 2: Step-down during majority wait (F1 bug family)
#
# This scenario exercises the F1 safety property:
#   OrphanDeletionBeforeTaskDocRemoval
#
# Flow:
#   OpObserverClearPending(n1,t1)   -- migration commits
#   StepUp(n1)                       -- n1 becomes primary
#   RecoveryPhase1Scan(n1)
#   RecoveryPhase2Scan(n1)           -- t1 found and registered
#   DeleteOrphans(n1,t1)             -- start deletion
#   MajorityWaitInterrupted(n1,t1)  -- majority wait interrupted by step-down
#   StepDown(n1)                     -- n1 steps down
#   ReplicateDiskState(n1,n2,t1)    -- secondary sees processing state
#   (Second attempt after re-elect)
#   StepUp(n1)                       -- n1 re-elected
#   RecoveryPhase1Scan(n1)           -- finds t1 in processing state (from disk)
#   RecoveryPhase2Scan(n1)           -- no new ready tasks
#   DeleteOrphans(n1,t1)             -- retry deletion (diskTaskState=processing pre-state)
#   MajorityWaitSuccess(n1,t1)
#   CompleteInMemory(n1,t1)
#   RemovePersistentTask(n1,t1)
#   ReplicateDiskState(n1,n2,t1)    -- secondary sees deleted state
# -------------------------------------------------------------------------

def scenario_stepdown_mid_majority():
    """
    F1 scenario: step-down interrupts majority wait, task survives on disk,
    then completes on re-election.  Two tasks (t1, t2) to exercise more paths.
    """
    T1 = "uuid-collA:{ _id: 0 }:{ _id: 10 }"
    T2 = "uuid-collB:{ _id: 0 }:{ _id: 10 }"

    events = []

    # Pre-StepUp: both tasks pending on both nodes
    events.append(OpObserverClearPending("n1", T1, "Secondary", False, "idle", "pending"))
    time.sleep(0.001)
    events.append(OpObserverClearPending("n2", T1, "Secondary", False, "idle", "pending"))
    time.sleep(0.001)
    events.append(OpObserverClearPending("n1", T2, "Secondary", False, "idle", "pending"))
    time.sleep(0.001)

    events.append(StepUp("n1", 1))
    time.sleep(0.001)

    events.append(RecoveryPhase1Scan("n1"))
    time.sleep(0.001)

    events.append(RecoveryPhase2Scan("n1"))  # finds t1 and t2 as ready
    time.sleep(0.001)

    # t2 completes normally before step-down
    events.append(DeleteOrphans("n1", T2, "ready", "idle"))
    time.sleep(0.001)
    events.append(MajorityWaitSuccess("n1", T2))
    time.sleep(0.001)
    events.append(CompleteInMemory("n1", T2))
    time.sleep(0.001)
    events.append(RemovePersistentTask("n1", T2))
    time.sleep(0.001)

    # t1 starts but is interrupted during majority wait
    events.append(DeleteOrphans("n1", T1, "ready", "idle"))
    time.sleep(0.001)
    events.append(ReplicateDiskState("n1", "n2", T1, "ready"))
    time.sleep(0.001)

    # F1: majority wait interrupted by step-down
    events.append(MajorityWaitInterrupted("n1", T1))
    time.sleep(0.001)

    events.append(StepDown("n1", "done"))
    time.sleep(0.001)

    # Secondary sees processing state survived step-down
    events.append(ReplicateDiskState("n1", "n2", T1, "processing"))
    time.sleep(0.001)

    # --- Second election: n1 re-elected ---
    events.append(StepUp("n1", 2))
    time.sleep(0.001)

    # Phase 1 recovers t1 from disk (processing flag survived step-down)
    events.append(RecoveryPhase1Scan("n1"))
    time.sleep(0.001)

    # Phase 2: no new ready tasks
    events.append(RecoveryPhase2Scan("n1"))
    time.sleep(0.001)

    # Retry: t1 disk state is "processing" from the first attempt
    events.append(DeleteOrphans("n1", T1, "processing", "idle"))
    time.sleep(0.001)

    events.append(MajorityWaitSuccess("n1", T1))
    time.sleep(0.001)

    events.append(CompleteInMemory("n1", T1))
    time.sleep(0.001)

    events.append(RemovePersistentTask("n1", T1))
    time.sleep(0.001)

    events.append(ReplicateDiskState("n1", "n2", T1, "processing"))
    time.sleep(0.001)

    return events

# -------------------------------------------------------------------------
# Scenario 3: Recovery with concurrent op_observer (F2 bug family)
#
# Exercises the case where a task's pending flag is cleared by an op_observer
# that fires BETWEEN recovery phases, so the task might be missed by phase 2.
# The spec's OpObserverRegisterTask action handles this by registering the
# task via opObserverPending, ensuring it is not lost.
#
# Flow:
#   StepUp(n1)                           -- n1 primary, termInitReady=true, phase1
#   RecoveryPhase1Scan(n1)               -- no processing tasks; → phase2
#   OpObserverClearPending(n1,t1)        -- fires BETWEEN phase1 and phase2
#                                            (termInitReady=true → adds to opObserverPending)
#   OpObserverRegisterTask(n1,t1)        -- registers t1 from opObserverPending (phase=phase2)
#   OpObserverClearPending(n1,t2)        -- second task also arrives
#   RecoveryPhase2Scan(n1)               -- t1 already in memory (dedup); t2 added
#   OpObserverRegisterTask(n1,t2)        -- t2 registered (fires after phase2 scan starts)
#   DeleteOrphans(n1,t1)                 -- start deletion of t1
#   DeleteOrphans(n1,t2)                 -- start deletion of t2
#   MajorityWaitSuccess(n1,t1)
#   CompleteInMemory(n1,t1)
#   RemovePersistentTask(n1,t1)
#   MajorityWaitSuccess(n1,t2)
#   CompleteInMemory(n1,t2)
#   RemovePersistentTask(n1,t2)
# -------------------------------------------------------------------------

def scenario_recovery_with_opobserver():
    """
    F2 scenario: two tasks arrive via op_observer between recovery phases.
    Exercises OpObserverRegisterTask deduplication with RecoveryPhase2Scan.
    Includes secondary replication of disk state changes.
    """
    T1 = "uuid-collA:{ _id: 0 }:{ _id: 10 }"
    T2 = "uuid-collA:{ _id: 10 }:{ _id: 20 }"

    events = []

    # Both tasks start as pending on both nodes
    events.append(OpObserverClearPending("n2", T1, "Secondary", False, "idle", "pending"))
    time.sleep(0.001)
    events.append(OpObserverClearPending("n2", T2, "Secondary", False, "idle", "pending"))
    time.sleep(0.001)

    # n1 steps up
    events.append(StepUp("n1", 1))
    time.sleep(0.001)

    # Phase 1: no processing tasks (t1, t2 are both pending; phase1 looks for processing)
    events.append(RecoveryPhase1Scan("n1"))
    time.sleep(0.001)

    # --- Between phase 1 and phase 2: op_observer fires for t1 ---
    # Migration commits WHILE recovery is progressing; termInitReady=true so
    # t1 is added to opObserverPending.
    events.append(OpObserverClearPending("n1", T1, "Primary", True, "phase2", "pending"))
    time.sleep(0.001)

    # t1 immediately registered via opObserverPending path
    events.append(OpObserverRegisterTask("n1", T1, "phase2"))
    time.sleep(0.001)

    # Second migration also commits between phases
    events.append(OpObserverClearPending("n1", T2, "Primary", True, "phase2", "pending"))
    time.sleep(0.001)

    # Phase 2 scan: t1 already in memory (dedup), t2 found from disk (now ready)
    events.append(RecoveryPhase2Scan("n1"))
    time.sleep(0.001)

    # t2 registered via opObserverPending (fires after recovery is done)
    events.append(OpObserverRegisterTask("n1", T2, "done"))
    time.sleep(0.001)

    # --- Deletion pipelines ---
    events.append(DeleteOrphans("n1", T1, "ready", "idle"))
    time.sleep(0.001)

    events.append(ReplicateDiskState("n1", "n2", T1, "ready"))
    time.sleep(0.001)

    events.append(DeleteOrphans("n1", T2, "ready", "idle"))
    time.sleep(0.001)

    events.append(ReplicateDiskState("n1", "n2", T2, "ready"))
    time.sleep(0.001)

    events.append(MajorityWaitSuccess("n1", T1))
    time.sleep(0.001)

    events.append(CompleteInMemory("n1", T1))
    time.sleep(0.001)

    events.append(RemovePersistentTask("n1", T1))
    time.sleep(0.001)

    events.append(ReplicateDiskState("n1", "n2", T1, "processing"))
    time.sleep(0.001)

    events.append(MajorityWaitSuccess("n1", T2))
    time.sleep(0.001)

    events.append(CompleteInMemory("n1", T2))
    time.sleep(0.001)

    events.append(RemovePersistentTask("n1", T2))
    time.sleep(0.001)

    events.append(ReplicateDiskState("n1", "n2", T2, "processing"))
    time.sleep(0.001)

    return events

# -------------------------------------------------------------------------
# Main
# -------------------------------------------------------------------------

if __name__ == "__main__":
    print("Generating prototype TLA+ traces...")

    print("\nScenario 1: Normal operation")
    write_trace("normal_operation.ndjson", scenario_normal_operation())

    print("\nScenario 2: Step-down during majority wait")
    write_trace("stepdown_mid_majority.ndjson", scenario_stepdown_mid_majority())

    print("\nScenario 3: Recovery with concurrent op_observer")
    write_trace("recovery_with_opobserver.ndjson", scenario_recovery_with_opobserver())

    print("\nDone.")
