---- MODULE MC ----
\* Model checking wrapper for base spec.
\* Bounds fault-injection actions with counters; passes deterministic/reactive
\* actions through unchanged.
\*
\* Fault-injection actions (bounded):
\*   MCMajorityWaitInterrupted — step-down mid-majority-wait (F1)
\*   MCStepDown                — step-down at any point (F1, F2, F3)
\*   MCOpObserverClearPending  — migration commits (bounded to control explosion)
\*
\* Non-fault actions (pass-through, UNCHANGED faultVars):
\*   StepUp, RecoveryPhase1Scan, RecoveryPhase2Scan, OpObserverRegisterTask,
\*   DeleteOrphans, MajorityWaitSuccess, CompleteInMemory, RemovePersistentTask,
\*   ReplicateDiskState

EXTENDS base

CONSTANTS
    MaxStepDowns,       \* bound on StepDown firings per node
    MaxInterrupts,      \* bound on MajorityWaitInterrupted firings
    MaxMigrations       \* bound on OpObserverClearPending firings (pending->ready transitions)

\* --- Fault counter record ---
VARIABLES faultVars

MCTypeOK ==
    /\ faultVars.stepDowns  \in [Nodes -> 0..MaxStepDowns]
    /\ faultVars.interrupts \in [Nodes -> [Tasks -> 0..MaxInterrupts]]
    /\ faultVars.migrations \in [Nodes -> [Tasks -> 0..MaxMigrations]]

----
\* -------------------------
\* Fault-injection wrappers
\* -------------------------

\* MCStepDown: bounded step-down
\* Injects the step-down fault (F1, F2, F3 trigger path)
MCStepDown(n) ==
    /\ faultVars.stepDowns[n] < MaxStepDowns
    /\ StepDown(n)
    /\ faultVars' = [faultVars EXCEPT !.stepDowns[n] = @ + 1]

\* MCMajorityWaitInterrupted: bounded interrupt during majority wait (F1)
\* ready_range_deletions_processor.cpp:337-339 — .get(opCtx) throws Interrupted
MCMajorityWaitInterrupted(n, t) ==
    /\ faultVars.interrupts[n][t] < MaxInterrupts
    /\ MajorityWaitInterrupted(n, t)
    /\ faultVars' = [faultVars EXCEPT !.interrupts[n][t] = @ + 1]

\* MCOpObserverClearPending: bounded migration commit
\* Bounds the number of pending->ready transitions to keep state space finite.
MCOpObserverClearPending(n, t) ==
    /\ faultVars.migrations[n][t] < MaxMigrations
    /\ OpObserverClearPending(n, t)
    /\ faultVars' = [faultVars EXCEPT !.migrations[n][t] = @ + 1]

----
\* -------------------------
\* Pass-through wrappers (no faultVars change)
\* -------------------------

MCStepUp(n) ==
    /\ StepUp(n)
    /\ UNCHANGED faultVars

MCRecoveryPhase1Scan(n) ==
    /\ RecoveryPhase1Scan(n)
    /\ UNCHANGED faultVars

MCRecoveryPhase2Scan(n) ==
    /\ RecoveryPhase2Scan(n)
    /\ UNCHANGED faultVars

MCOpObserverRegisterTask(n, t) ==
    /\ OpObserverRegisterTask(n, t)
    /\ UNCHANGED faultVars

MCDeleteOrphans(n, t) ==
    /\ DeleteOrphans(n, t)
    /\ UNCHANGED faultVars

MCMajorityWaitSuccess(n, t) ==
    /\ MajorityWaitSuccess(n, t)
    /\ UNCHANGED faultVars

MCCompleteInMemory(n, t) ==
    /\ CompleteInMemory(n, t)
    /\ UNCHANGED faultVars

MCRemovePersistentTask(n, t) ==
    /\ RemovePersistentTask(n, t)
    /\ UNCHANGED faultVars

MCReplicateDiskState(p, s, t) ==
    /\ ReplicateDiskState(p, s, t)
    /\ UNCHANGED faultVars

----
\* -------------------------
\* MC Init / Next
\* -------------------------

MCInit ==
    /\ Init
    /\ faultVars = [
            stepDowns  |-> [n \in Nodes |-> 0],
            interrupts |-> [n \in Nodes |-> [t \in Tasks |-> 0]],
            migrations |-> [n \in Nodes |-> [t \in Tasks |-> 0]]
       ]

MCNext ==
    \/ \E n \in Nodes, t \in Tasks : MCOpObserverClearPending(n, t)
    \/ \E n \in Nodes              : MCStepUp(n)
    \/ \E n \in Nodes              : MCRecoveryPhase1Scan(n)
    \/ \E n \in Nodes              : MCRecoveryPhase2Scan(n)
    \/ \E n \in Nodes, t \in Tasks : MCOpObserverRegisterTask(n, t)
    \/ \E n \in Nodes, t \in Tasks : MCDeleteOrphans(n, t)
    \/ \E n \in Nodes, t \in Tasks : MCMajorityWaitSuccess(n, t)
    \/ \E n \in Nodes, t \in Tasks : MCMajorityWaitInterrupted(n, t)
    \/ \E n \in Nodes, t \in Tasks : MCCompleteInMemory(n, t)
    \/ \E n \in Nodes, t \in Tasks : MCRemovePersistentTask(n, t)
    \/ \E n \in Nodes              : MCStepDown(n)
    \/ \E p \in Nodes, s \in Nodes, t \in Tasks :
            p /= s /\ MCReplicateDiskState(p, s, t)

----
\* Symmetry reduction: permute nodes (not tasks — task IDs differ in semantics)
Symmetry == Permutations(Nodes)

\* View: exclude fault counters from the state view to reduce distinct states
MCView == <<nodeRole, term, diskTaskState, inMemoryTasks, recoveryPhase,
            deletionStep, completionFulfilled, diskDocExists,
            orphansMajorityCommitted, termInitReady, opObserverPending>>

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

====
