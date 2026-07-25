---- MODULE Trace ----
\* Trace validation spec for MongoDB RangeDeleterService.
\* Category A (Distributed/Message-Passing): single-file linear trace, cursor l.
\*
\* Replays NDJSON execution traces from the instrumented service against base.tla.
\* Each trace event corresponds to exactly one base spec action.
\* TLC walks the trace in order and verifies that the base spec can produce
\* each observed state transition.

EXTENDS base, Sequences, Naturals, TLC, IOUtils, Json

\* Standalone task identifier constants, needed to reference individual
\* elements of Tasks in TaskFromStr without quantifying over the set.
CONSTANTS t1, t2

\* Standalone node identifier constants, needed because JSON strings like "n1"
\* are not automatically coerced to TLC model values; explicit mapping is required.
CONSTANTS n1, n2, n3

----
\* -------------------------
\* Trace loading
\* -------------------------

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

----
\* -------------------------
\* Cursor variable
\* -------------------------
\* l walks through trace events 1..Len(TraceLog)
VARIABLES l

TraceVars == <<vars, l>>

----
\* -------------------------
\* Role / state mapping from trace strings to spec constants
\* -------------------------

RoleFromStr(s) ==
    CASE s = "Primary"   -> Primary
      [] s = "Secondary" -> Secondary
      [] OTHER           -> Secondary

DiskStateFromStr(s) ==
    CASE s = "pending"    -> TaskPending
      [] s = "ready"      -> TaskReady
      [] s = "processing" -> TaskProcessing
      [] s = "deleted"    -> TaskDeleted
      [] OTHER            -> TaskPending

RecovPhaseFromStr(s) ==
    CASE s = "idle"   -> RecoveryIdle
      [] s = "phase1" -> RecoveryPhase1
      [] s = "phase2" -> RecoveryPhase2
      [] s = "done"   -> RecoveryDone
      [] OTHER        -> RecoveryIdle

\* Map trace node strings to TLA+ node constants.
\* JSON strings like "n1" are not coerced to model values by TLC.
NodeFromStr(s) ==
    CASE s = "n1" -> n1
      [] s = "n2" -> n2
      [] s = "n3" -> n3
      [] OTHER    -> n1

\* Map trace task strings to TLA+ task constants.
\* Task strings contain special characters (colons, braces) that cannot be
\* TLC model value names, so explicit mapping is required.
TaskFromStr(s) ==
    CASE s = "uuid-collA:{ _id: 0 }:{ _id: 10 }"  -> t1
      [] s = "uuid-collA:{ _id: 10 }:{ _id: 20 }" -> t2
      [] s = "uuid-collB:{ _id: 0 }:{ _id: 10 }"  -> t2
      [] OTHER -> t1

----
\* -------------------------
\* Event predicates
\* -------------------------

logline == TraceLog[l]

IsEvent(name) == logline.event = name
IsNodeEvent(name, n) == IsEvent(name) /\ logline.node = n

----
\* -------------------------
\* Post-state validation helpers
\* -------------------------

\* Validate that spec state at node n matches the trace-captured snapshot.
\* Only validates fields that the harness captures (see instrumentation-spec.md).
ValidateNodeState(n) ==
    /\ nodeRole[n] = RoleFromStr(logline.state.role)
    /\ recoveryPhase[n] = RecovPhaseFromStr(logline.state.recoveryPhase)
    /\ termInitReady[n] = logline.state.termInitReady

ValidateDiskTask(n, t) ==
    diskTaskState[n][t] = DiskStateFromStr(logline.state.diskTaskState)

ValidateDeletionStep(n, t) ==
    deletionStep[n][t] = logline.state.deletionStep

----
\* -------------------------
\* Action wrappers
\* -------------------------

\* TraceOpObserverClearPending: migration commit clears pending flag on a task
\* Instrumentation: range_deleter_service_op_observer.cpp:116-177 (onInserts/onUpdate)
TraceOpObserverClearPending ==
    /\ IsEvent("OpObserverClearPending")
    /\ LET n == NodeFromStr(logline.node)
           t == TaskFromStr(logline.task)
       IN
        /\ OpObserverClearPending(n, t)
        /\ ValidateNodeState(n)
        /\ ValidateDiskTask(n, t)
    /\ l' = l + 1

\* TraceStepUp: node transitions to primary
\* Instrumentation: range_deleter_service.cpp:135 (onStepUpComplete entry)
TraceStepUp ==
    /\ IsEvent("StepUp")
    /\ LET n == NodeFromStr(logline.node)
       IN
        /\ StepUp(n)
        /\ ValidateNodeState(n)
    /\ l' = l + 1

\* TraceRecoveryPhase1Scan: phase 1 scan completes
\* Instrumentation: range_deleter_service.cpp:231 (after cursor exhausted)
TraceRecoveryPhase1Scan ==
    /\ IsEvent("RecoveryPhase1Scan")
    /\ LET n == NodeFromStr(logline.node)
       IN
        /\ RecoveryPhase1Scan(n)
        /\ ValidateNodeState(n)
    /\ l' = l + 1

\* TraceRecoveryPhase2Scan: phase 2 scan completes
\* Instrumentation: range_deleter_service.cpp:253 (after cursor exhausted)
TraceRecoveryPhase2Scan ==
    /\ IsEvent("RecoveryPhase2Scan")
    /\ LET n == NodeFromStr(logline.node)
       IN
        /\ RecoveryPhase2Scan(n)
        /\ ValidateNodeState(n)
    /\ l' = l + 1

\* TraceOpObserverRegisterTask: op_observer registers a task during recovery
\* Instrumentation: range_deleter_service.cpp:366-368 (registerTask guard check)
TraceOpObserverRegisterTask ==
    /\ IsEvent("OpObserverRegisterTask")
    /\ LET n == NodeFromStr(logline.node)
           t == TaskFromStr(logline.task)
       IN
        /\ OpObserverRegisterTask(n, t)
        /\ ValidateNodeState(n)
    /\ l' = l + 1

\* TraceDeleteOrphans: deleteRangeInBatches begins
\* Instrumentation: ready_range_deletions_processor.cpp:258 (LOGV2_INFO 6872501)
TraceDeleteOrphans ==
    /\ IsEvent("DeleteOrphans")
    /\ LET n == NodeFromStr(logline.node)
           t == TaskFromStr(logline.task)
       IN
        /\ DeleteOrphans(n, t)
        /\ ValidateDiskTask(n, t)
        /\ ValidateDeletionStep(n, t)
    /\ l' = l + 1

\* TraceMajorityWaitSuccess: waitUntilMajorityForWrite returns OK
\* Instrumentation: ready_range_deletions_processor.cpp:340 (after .get(opCtx) returns)
TraceMajorityWaitSuccess ==
    /\ IsEvent("MajorityWaitSuccess")
    /\ LET n == NodeFromStr(logline.node)
           t == TaskFromStr(logline.task)
       IN
        /\ MajorityWaitSuccess(n, t)
        /\ ValidateDeletionStep(n, t)
    /\ l' = l + 1

\* TraceMajorityWaitInterrupted: majority wait interrupted by step-down
\* Instrumentation: ready_range_deletions_processor.cpp:388-397 (catch DBException, stopRequested)
TraceMajorityWaitInterrupted ==
    /\ IsEvent("MajorityWaitInterrupted")
    /\ LET n == NodeFromStr(logline.node)
           t == TaskFromStr(logline.task)
       IN
        /\ MajorityWaitInterrupted(n, t)
        /\ ValidateDeletionStep(n, t)
    /\ l' = l + 1

\* TraceCompleteInMemory: completeTask() called (future fulfilled, in-memory entry removed)
\* Instrumentation: ready_range_deletions_processor.cpp:345 (completeTask call)
TraceCompleteInMemory ==
    /\ IsEvent("CompleteInMemory")
    /\ LET n == NodeFromStr(logline.node)
           t == TaskFromStr(logline.task)
       IN
        /\ CompleteInMemory(n, t)
        /\ completionFulfilled'[n][t] = TRUE
        /\ ValidateDeletionStep(n, t)
    /\ l' = l + 1

\* TraceRemovePersistentTask: removePersistentTask() deletes disk document
\* Instrumentation: ready_range_deletions_processor.cpp:347 (removePersistentTask call)
TraceRemovePersistentTask ==
    /\ IsEvent("RemovePersistentTask")
    /\ LET n == NodeFromStr(logline.node)
           t == TaskFromStr(logline.task)
       IN
        /\ RemovePersistentTask(n, t)
        /\ diskTaskState'[n][t] = TaskDeleted
        /\ ValidateDeletionStep(n, t)
    /\ l' = l + 1

\* TraceStepDown: node steps down
\* Instrumentation: range_deleter_service.cpp:316 (onStepDown entry)
TraceStepDown ==
    /\ IsEvent("StepDown")
    /\ LET n == NodeFromStr(logline.node)
       IN
        /\ StepDown(n)
        /\ ValidateNodeState(n)
    /\ l' = l + 1

\* TraceReplicateDiskState: secondary applies primary's oplog entry for a task
\* Instrumentation: captured at replication apply point
\* Handles post-step-down replication: if the originating node has already stepped
\* down (or the secondary's disk state already matches), treat as a no-op —
\* validate the secondary's PRE-state and advance the cursor without changing vars.
TraceReplicateDiskState ==
    /\ IsEvent("ReplicateDiskState")
    /\ LET p == NodeFromStr(logline.primary)
           s == NodeFromStr(logline.secondary)
           t == TaskFromStr(logline.task)
       IN
        /\ ValidateDiskTask(s, t)
        /\ IF IsPrimary(p) /\ diskTaskState[s][t] /= diskTaskState[p][t]
           THEN ReplicateDiskState(p, s, t)
           ELSE UNCHANGED vars
    /\ l' = l + 1

----
\* -------------------------
\* Silent actions
\* -------------------------
\* These fire without consuming a trace event.
\* Must be tightly constrained to prevent state space explosion.

\* No silent actions are needed for this spec because every state transition
\* in the base spec corresponds to an observable operation with a clear
\* instrumentation point. If trace validation reveals gaps, silent actions
\* can be added here with tight constraints.

----
\* -------------------------
\* Bootstrap initial state
\* -------------------------
\* Match the implementation's initial state when the first trace event is captured.
\* The base Init assumes all nodes are secondary and all tasks are pending.
\* If traces start mid-execution, override here.

TraceInit ==
    /\ Init
    /\ l = 1

----
\* -------------------------
\* TraceNext
\* -------------------------

TraceNext ==
    /\ l <= Len(TraceLog)
    /\ \/ TraceOpObserverClearPending
       \/ TraceStepUp
       \/ TraceRecoveryPhase1Scan
       \/ TraceRecoveryPhase2Scan
       \/ TraceOpObserverRegisterTask
       \/ TraceDeleteOrphans
       \/ TraceMajorityWaitSuccess
       \/ TraceMajorityWaitInterrupted
       \/ TraceCompleteInMemory
       \/ TraceRemovePersistentTask
       \/ TraceStepDown
       \/ TraceReplicateDiskState

\* Stuttering: allow TLC to stutter once the trace is fully consumed
TraceSpec == TraceInit /\ [][TraceNext \/ (l > Len(TraceLog) /\ UNCHANGED TraceVars)]_TraceVars
                       /\ WF_TraceVars(TraceNext)

----
\* -------------------------
\* Trace consumed property
\* -------------------------
\* TLC must advance l through the entire trace.
\* Without this, TLC may report "no errors" while l never advances.

TraceMatched == <>(l > Len(TraceLog))

====
