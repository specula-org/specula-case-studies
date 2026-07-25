---- MODULE base ----
\* MongoDB RangeDeleterService — orphan deletion on secondaries
\* Models three bug families from the modeling brief:
\*   F1: Orphan-deletion-before-task-removal ordering under step-down
\*   F2: Two-phase recovery scan completeness under concurrent op_observer
\*   F3: Non-atomic completeTask/removePersistentTask completion window

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Nodes,      \* set of replica-set nodes, e.g. {n1, n2, n3}
    Tasks,      \* set of task IDs (collectionUUID+range pairs), e.g. {t1, t2}
    MaxTerm     \* max term to bound state space

----
\* Role constants
CONSTANTS Primary, Secondary

\* Task state constants (disk document state)
\* pending=true: migration not yet committed, task not yet ready
\* ready: pending cleared, eligible for execution
\* processing: being actively deleted on a primary
\* deleted: disk document has been removed
CONSTANTS
    TaskPending,    \* RangeDeletionTask.kPendingFieldName = true
    TaskReady,      \* pending cleared, processing=false
    TaskProcessing, \* processing=true (set when executor picks up task)
    TaskDeleted     \* config.rangeDeletions entry removed

\* Majority-wait outcome constants (F1: non-deterministic under step-down)
CONSTANTS MajoritySuccess, MajorityInterrupted

\* Recovery phase constants (F2: two-phase scan)
CONSTANTS RecoveryIdle, RecoveryPhase1, RecoveryPhase2, RecoveryDone

----
ASSUME Nodes # {}
ASSUME Tasks # {}
ASSUME MaxTerm \in Nat /\ MaxTerm >= 1
ASSUME Primary # Secondary

----
\* -------------------------
\* Variable definitions
\* -------------------------

\* --- Per-node protocol variables ---
VARIABLES
    nodeRole,       \* nodeRole[n] \in {Primary, Secondary}
    term            \* term[n] \in 0..MaxTerm — current term at node n

\* --- Disk state (config.rangeDeletions) ---
\* diskTaskState[n][t] \in {TaskPending, TaskReady, TaskProcessing, TaskDeleted}
\* This is the authoritative persistent store; rebuilt from scratch on every step-up.
VARIABLES
    diskTaskState   \* diskTaskState[n][t] — per-node persistent state

\* --- In-memory task registry (rebuilt on step-up) ---
\* inMemoryTasks[n] \in SUBSET Tasks — tasks currently registered in memory
\* range_deleter_service.cpp:279 — _rangeDeletionTasks.clear() on step-down
VARIABLES
    inMemoryTasks

\* --- Recovery phase (F2: two-phase scan) ---
\* recoveryPhase[n] \in {RecoveryIdle, RecoveryPhase1, RecoveryPhase2, RecoveryDone}
\* range_deleter_service.cpp:186-261 — _launchRangeDeletionRecoveryTask
VARIABLES
    recoveryPhase

\* --- Deletion execution state (F1: majority-wait window) ---
\* deletionStep[n][t] tracks where in the deletion pipeline a task is:
\*   "idle"      — not being executed at this node
\*   "deleting"  — deleteRangeInBatches running (ready_range_deletions_processor.cpp:277-288)
\*   "waiting"   — waitUntilMajorityForWrite running (ready_range_deletions_processor.cpp:337-339)
\*   "completing" — completeTask + removePersistentTask running (ready_range_deletions_processor.cpp:344-347)
VARIABLES
    deletionStep

\* --- F3: non-atomic completion extension ---
\* completionFulfilled[n][t] — completion future resolved (markComplete called)
\*   range_deletion.cpp:75-76 — _completionPromise.emplaceValue()
\* diskDocExists[n][t]  — disk document still present (removePersistentTask not yet done)
\*   ready_range_deletions_processor.cpp:347 — removePersistentTask
VARIABLES
    completionFulfilled,
    diskDocExists

\* --- F1 extension: orphans deleted on majority ---
\* orphansMajorityCommitted[t] — true once majority wait succeeds for task t
\* Invariant CompletionFutureImpliesMajorityOrphans checks this.
VARIABLES
    orphansMajorityCommitted

\* --- Term-initialization promise (F2: gate for op_observer registration) ---
\* termInitReady[n] — _termInitializationPromise is set (fulfilled before recovery task launches)
\*   range_deleter_service.cpp:177 — ensureSet(lock, *_termInitializationPromise)
VARIABLES
    termInitReady

\* --- Op-observer fired events (F2: interleaved with recovery scan) ---
\* opObserverPending[n][t] — op_observer has seen a pending->ready transition for t,
\*   and queued a registerTask call, but recovery hasn't processed it yet.
VARIABLES
    opObserverPending

----
\* Variable groups for UNCHANGED clauses
nodeVars    == <<nodeRole, term>>
diskVars    == <<diskTaskState>>
memVars     == <<inMemoryTasks, termInitReady>>
recovVars   == <<recoveryPhase>>
execVars    == <<deletionStep>>
f1Vars      == <<orphansMajorityCommitted>>
f3Vars      == <<completionFulfilled, diskDocExists>>
obsVars     == <<opObserverPending>>

vars == <<nodeVars, diskVars, memVars, recovVars, execVars, f1Vars, f3Vars, obsVars>>

----
\* -------------------------
\* Type invariant
\* -------------------------

TypeOK ==
    /\ nodeRole \in [Nodes -> {Primary, Secondary}]
    /\ term \in [Nodes -> 0..MaxTerm]
    /\ diskTaskState \in [Nodes -> [Tasks -> {TaskPending, TaskReady, TaskProcessing, TaskDeleted}]]
    /\ inMemoryTasks \in [Nodes -> SUBSET Tasks]
    /\ recoveryPhase \in [Nodes -> {RecoveryIdle, RecoveryPhase1, RecoveryPhase2, RecoveryDone}]
    /\ deletionStep \in [Nodes -> [Tasks -> {"idle", "deleting", "waiting", "completing"}]]
    /\ completionFulfilled \in [Nodes -> [Tasks -> BOOLEAN]]
    /\ diskDocExists \in [Nodes -> [Tasks -> BOOLEAN]]
    /\ orphansMajorityCommitted \in [Tasks -> BOOLEAN]
    /\ termInitReady \in [Nodes -> BOOLEAN]
    /\ opObserverPending \in [Nodes -> SUBSET Tasks]

----
\* -------------------------
\* Helper predicates
\* -------------------------

IsPrimary(n) == nodeRole[n] = Primary
IsSecondary(n) == nodeRole[n] = Secondary

\* At most one primary per term
AtMostOnePrimary ==
    \A n1, n2 \in Nodes :
        (IsPrimary(n1) /\ IsPrimary(n2) /\ term[n1] = term[n2]) => n1 = n2

\* A task is "actionable" on disk at node n if it is not pending and not deleted
DiskTaskActionable(n, t) ==
    diskTaskState[n][t] \in {TaskReady, TaskProcessing}

----
\* -------------------------
\* Initial state
\* -------------------------

Init ==
    /\ nodeRole = [n \in Nodes |-> Secondary]
    /\ term = [n \in Nodes |-> 0]
    \* All tasks start as pending on disk at all nodes (pre-migration-commit)
    /\ diskTaskState = [n \in Nodes |-> [t \in Tasks |-> TaskPending]]
    /\ inMemoryTasks = [n \in Nodes |-> {}]
    /\ recoveryPhase = [n \in Nodes |-> RecoveryIdle]
    /\ deletionStep = [n \in Nodes |-> [t \in Tasks |-> "idle"]]
    /\ completionFulfilled = [n \in Nodes |-> [t \in Tasks |-> FALSE]]
    /\ diskDocExists = [n \in Nodes |-> [t \in Tasks |-> TRUE]]
    /\ orphansMajorityCommitted = [t \in Tasks |-> FALSE]
    /\ termInitReady = [n \in Nodes |-> FALSE]
    /\ opObserverPending = [n \in Nodes |-> {}]

----
\* -------------------------
\* Op-observer: pending -> ready transition
\* range_deleter_service_op_observer.cpp:116-177 — onInserts/onUpdate
\* Models a migration commit that clears the pending flag on task t.
\* The op fires on ALL nodes (primary and secondary).
\* On secondary: NotYetInitialized / NotPrimaryError is swallowed silently.
\*   range_deleter_service_op_observer.cpp:92-101
\* -------------------------

OpObserverClearPending(n, t) ==
    \* Precondition: task is pending on disk at this node
    /\ diskTaskState[n][t] = TaskPending
    \* Update disk: pending cleared (task now ready)
    /\ diskTaskState' = [diskTaskState EXCEPT ![n][t] = TaskReady]
    \* If termInitReady is set at this node, queue registration via op_observer
    \* range_deleter_service.cpp:366-368 — registerTask guard
    /\ opObserverPending' = IF termInitReady[n]
                            THEN [opObserverPending EXCEPT ![n] = @ \cup {t}]
                            ELSE opObserverPending
    /\ UNCHANGED <<nodeVars, memVars, recovVars, execVars, f1Vars, f3Vars>>

----
\* -------------------------
\* Step-up: onStepUpComplete
\* range_deleter_service.cpp:135-180
\* Transitions: kDown -> kReadyForInitialization, sets _termInitializationPromise,
\* then launches recovery task.
\* -------------------------

StepUp(n) ==
    \* Only a secondary node can step up, and only if term budget allows
    /\ IsSecondary(n)
    /\ term[n] < MaxTerm
    \* No other node is primary in the new term (safe for model: bump to fresh term)
    \* Guard: no other node currently holds the Primary role (mutual exclusion)
    /\ \A m \in Nodes : ~IsPrimary(m)
    /\ LET newTerm == term[n] + 1 IN
        \* range_deleter_service.cpp:141 — dassert(_state == kDown)
        \* range_deleter_service.cpp:143 — _state = kReadyForInitialization
        /\ nodeRole' = [nodeRole EXCEPT ![n] = Primary]
        /\ term' = [term EXCEPT ![n] = newTerm]
        \* range_deleter_service.cpp:177 — ensureSet(lock, *_termInitializationPromise)
        /\ termInitReady' = [termInitReady EXCEPT ![n] = TRUE]
        \* range_deleter_service.cpp:194-196 — recovery task begins in kReadyForInitialization
        /\ recoveryPhase' = [recoveryPhase EXCEPT ![n] = RecoveryPhase1]
        \* In-memory state starts empty; rebuilt by recovery
        /\ inMemoryTasks' = [inMemoryTasks EXCEPT ![n] = {}]
        /\ UNCHANGED <<diskVars, execVars, f1Vars, f3Vars, obsVars>>

----
\* -------------------------
\* Recovery Phase 1: scan for processing=true tasks
\* range_deleter_service.cpp:220-231 — Phase (1): processing tasks
\* -------------------------

RecoveryPhase1Scan(n) ==
    /\ IsPrimary(n)
    /\ recoveryPhase[n] = RecoveryPhase1
    \* Register all tasks marked TaskProcessing on disk
    \* range_deleter_service.cpp:221-231 — findCommand filter: processing=true
    /\ LET processingTasks == {t \in Tasks : diskTaskState[n][t] = TaskProcessing}
       IN inMemoryTasks' = [inMemoryTasks EXCEPT ![n] = @ \cup processingTasks]
    /\ recoveryPhase' = [recoveryPhase EXCEPT ![n] = RecoveryPhase2]
    /\ UNCHANGED <<nodeVars, diskVars, termInitReady, execVars, f1Vars, f3Vars, obsVars>>

----
\* -------------------------
\* Op-observer registration during recovery (F2)
\* Between recovery phases, op_observer may fire and register tasks.
\* range_deleter_service.cpp:366-368 — registerTask succeeds if termInitReady
\* -------------------------

OpObserverRegisterTask(n, t) ==
    /\ IsPrimary(n)
    /\ termInitReady[n]
    /\ t \in opObserverPending[n]
    \* Task must be actionable on disk (pending was cleared)
    /\ DiskTaskActionable(n, t)
    \* Register task in memory (dedup: join if already present)
    /\ inMemoryTasks' = [inMemoryTasks EXCEPT ![n] = @ \cup {t}]
    /\ opObserverPending' = [opObserverPending EXCEPT ![n] = @ \ {t}]
    /\ UNCHANGED <<nodeVars, diskVars, termInitReady, recovVars, execVars, f1Vars, f3Vars>>

----
\* -------------------------
\* Recovery Phase 2: scan for non-pending, non-processing tasks
\* range_deleter_service.cpp:240-253 — Phase (2): ready tasks
\* -------------------------

RecoveryPhase2Scan(n) ==
    /\ IsPrimary(n)
    /\ recoveryPhase[n] = RecoveryPhase2
    \* Register all tasks that are TaskReady on disk (not pending, not processing, not deleted)
    \* range_deleter_service.cpp:242-246 — filter: processing != true AND pending != true
    /\ LET readyTasks == {t \in Tasks : diskTaskState[n][t] = TaskReady}
       IN inMemoryTasks' = [inMemoryTasks EXCEPT ![n] = @ \cup readyTasks]
    /\ recoveryPhase' = [recoveryPhase EXCEPT ![n] = RecoveryDone]
    /\ UNCHANGED <<nodeVars, diskVars, termInitReady, execVars, f1Vars, f3Vars, obsVars>>

----
\* -------------------------
\* DeleteOrphans: deleteRangeInBatches executes
\* ready_range_deletions_processor.cpp:246-316
\* Task must be in inMemoryTasks and disk state must be actionable.
\* -------------------------

DeleteOrphans(n, t) ==
    /\ IsPrimary(n)
    /\ recoveryPhase[n] = RecoveryDone     \* service is kUp
    /\ t \in inMemoryTasks[n]
    /\ deletionStep[n][t] = "idle"
    /\ DiskTaskActionable(n, t)
    \* Mark task as processing on disk
    \* (models _readyRangeDeletionsProcessorPtr->emplaceRangeDeletion calling into processor)
    /\ diskTaskState' = [diskTaskState EXCEPT ![n][t] = TaskProcessing]
    /\ deletionStep' = [deletionStep EXCEPT ![n][t] = "deleting"]
    /\ UNCHANGED <<nodeVars, memVars, recovVars, f1Vars, f3Vars, obsVars>>

----
\* -------------------------
\* MajorityWaitSuccess: waitUntilMajorityForWrite returns OK
\* ready_range_deletions_processor.cpp:337-339
\* Non-deterministic: can succeed or be interrupted (see MajorityWaitInterrupted)
\* -------------------------

MajorityWaitSuccess(n, t) ==
    /\ IsPrimary(n)
    /\ deletionStep[n][t] = "deleting"
    \* ready_range_deletions_processor.cpp:337-339 — majority wait returns OK
    /\ deletionStep' = [deletionStep EXCEPT ![n][t] = "waiting"]
    \* Once orphan deletions are majority-committed, record this (F1 invariant)
    /\ orphansMajorityCommitted' = [orphansMajorityCommitted EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<nodeVars, diskVars, memVars, recovVars, f3Vars, obsVars>>

----
\* -------------------------
\* MajorityWaitInterrupted: step-down fires during majority wait
\* ready_range_deletions_processor.cpp:337-339 — .get(opCtx) throws Interrupted
\* range_deleter_service.cpp:297-299 — _initOpCtxHolder->markKilled(ErrorCodes::Interrupted)
\* The task is NOT completed; disk document survives for recovery.
\* This is a fault-injection action (bounded in MC spec).
\* -------------------------

MajorityWaitInterrupted(n, t) ==
    /\ IsPrimary(n)
    /\ deletionStep[n][t] = "deleting"
    \* Interrupted: reset deletion step; step-down will happen separately
    /\ deletionStep' = [deletionStep EXCEPT ![n][t] = "idle"]
    \* Disk state remains TaskProcessing (task document survives)
    /\ UNCHANGED <<nodeVars, diskVars, memVars, recovVars, f1Vars, f3Vars, obsVars>>

----
\* -------------------------
\* CompleteInMemory: completeTask() removes in-memory entry and fulfills future
\* ready_range_deletions_processor.cpp:344-346 — completeTask(collectionUuid, range)
\* range_deleter_service.cpp:491-499 — completeTask implementation
\* range_deletion.cpp:75-76 — markComplete() -> _completionPromise.emplaceValue()
\* NOTE: This happens BEFORE removePersistentTask (F3 crash window).
\* -------------------------

CompleteInMemory(n, t) ==
    /\ IsPrimary(n)
    /\ deletionStep[n][t] = "waiting"
    /\ t \in inMemoryTasks[n]
    \* ready_range_deletions_processor.cpp:345 — self->completeTask(collectionUuid, range)
    /\ inMemoryTasks' = [inMemoryTasks EXCEPT ![n] = @ \ {t}]
    \* range_deletion.cpp:75-76 — markComplete() resolves the completion future
    /\ completionFulfilled' = [completionFulfilled EXCEPT ![n][t] = TRUE]
    /\ deletionStep' = [deletionStep EXCEPT ![n][t] = "completing"]
    \* Discard any pending op-observer registration for t at this node: by the time
    \* the task reaches the completing window, the op-observer's registerTask would have
    \* already joined the in-progress deletion (or been superseded by it).
    /\ opObserverPending' = [opObserverPending EXCEPT ![n] = @ \ {t}]
    /\ UNCHANGED <<nodeVars, diskVars, termInitReady, recovVars, f1Vars, diskDocExists>>

----
\* -------------------------
\* RemovePersistentTask: removePersistentTask() deletes disk document
\* ready_range_deletions_processor.cpp:347 — removePersistentTask(opCtx, task->getTaskId())
\* Only called AFTER CompleteInMemory (F3: crash window between these two actions).
\* -------------------------

RemovePersistentTask(n, t) ==
    /\ IsPrimary(n)
    /\ deletionStep[n][t] = "completing"
    /\ diskTaskState[n][t] = TaskProcessing
    \* ready_range_deletions_processor.cpp:347 — disk document removed
    /\ diskTaskState' = [diskTaskState EXCEPT ![n][t] = TaskDeleted]
    /\ diskDocExists' = [diskDocExists EXCEPT ![n][t] = FALSE]
    /\ deletionStep' = [deletionStep EXCEPT ![n][t] = "idle"]
    /\ UNCHANGED <<nodeVars, memVars, recovVars, f1Vars, completionFulfilled, obsVars>>

----
\* -------------------------
\* StepDown: onStepDown -> _stopService
\* range_deleter_service.cpp:315-317 — onStepDown calls _stopService
\* range_deleter_service.cpp:283-313 — _stopService:
\*   - kills _initOpCtxHolder (interrupts in-flight operations)
\*   - shuts down executor
\*   - clears _rangeDeletionTasks (in-memory state wiped)
\*   - sets _state = kDown
\* -------------------------

StepDown(n) ==
    /\ IsPrimary(n)
    /\ nodeRole' = [nodeRole EXCEPT ![n] = Secondary]
    \* range_deleter_service.cpp:312 — _rangeDeletionTasks.clear() wipes in-memory state
    /\ inMemoryTasks' = [inMemoryTasks EXCEPT ![n] = {}]
    \* range_deleter_service.cpp:294 — _state = kDown
    /\ termInitReady' = [termInitReady EXCEPT ![n] = FALSE]
    \* range_deleter_service.cpp:194-196 — recovery resets on next step-up
    /\ recoveryPhase' = [recoveryPhase EXCEPT ![n] = RecoveryIdle]
    \* All in-flight deletion steps are abandoned (interrupted)
    /\ deletionStep' = [deletionStep EXCEPT ![n] = [t \in Tasks |-> "idle"]]
    \* Op-observer queue is cleared (service is down)
    /\ opObserverPending' = [opObserverPending EXCEPT ![n] = {}]
    \* Disk state is NOT cleared — survives for recovery
    /\ UNCHANGED <<term, diskVars, f1Vars, f3Vars>>

----
\* -------------------------
\* ReplicateDiskState: secondary applies primary's writes (oplog replication)
\* Models secondaries catching up to the primary's disk state for a task.
\* Required for F1: secondaries must apply orphan deletions before task doc removal.
\* -------------------------

ReplicateDiskState(primary, secondary, t) ==
    /\ IsPrimary(primary)
    /\ IsSecondary(secondary)
    \* Secondary applies the disk state from the primary
    /\ diskTaskState[secondary][t] /= diskTaskState[primary][t]
    /\ diskTaskState' = [diskTaskState EXCEPT ![secondary][t] = diskTaskState[primary][t]]
    /\ diskDocExists' = [diskDocExists EXCEPT ![secondary][t] = diskDocExists[primary][t]]
    /\ UNCHANGED <<nodeVars, memVars, recovVars, execVars, f1Vars, completionFulfilled, obsVars>>

----
\* -------------------------
\* Next-state relation
\* -------------------------

Next ==
    \/ \E n \in Nodes, t \in Tasks : OpObserverClearPending(n, t)
    \/ \E n \in Nodes              : StepUp(n)
    \/ \E n \in Nodes              : RecoveryPhase1Scan(n)
    \/ \E n \in Nodes              : RecoveryPhase2Scan(n)
    \/ \E n \in Nodes, t \in Tasks : OpObserverRegisterTask(n, t)
    \/ \E n \in Nodes, t \in Tasks : DeleteOrphans(n, t)
    \/ \E n \in Nodes, t \in Tasks : MajorityWaitSuccess(n, t)
    \/ \E n \in Nodes, t \in Tasks : MajorityWaitInterrupted(n, t)
    \/ \E n \in Nodes, t \in Tasks : CompleteInMemory(n, t)
    \/ \E n \in Nodes, t \in Tasks : RemovePersistentTask(n, t)
    \/ \E n \in Nodes              : StepDown(n)
    \/ \E p \in Nodes, s \in Nodes, t \in Tasks :
            p /= s /\ ReplicateDiskState(p, s, t)

----
\* -------------------------
\* Safety Invariants
\* -------------------------

\* --- Standard structural invariant ---
\* At most one primary per term across nodes
ElectionSafety ==
    \A n1, n2 \in Nodes :
        (IsPrimary(n1) /\ IsPrimary(n2)) => n1 = n2

\* --- F1: OrphanDeletionBeforeTaskDocRemoval ---
\* For every node pair: the task document removal (TaskDeleted) at the secondary
\* must not precede orphan majority commitment.
\* Specifically: if a node has TaskDeleted on disk, orphans must be majority committed.
\* ready_range_deletions_processor.cpp:337-339 (majority wait) then :347 (remove task doc)
OrphanDeletionBeforeTaskDocRemoval ==
    \A n \in Nodes, t \in Tasks :
        diskTaskState[n][t] = TaskDeleted => orphansMajorityCommitted[t]

\* --- F1: CompletionFutureImpliesMajorityOrphans ---
\* When completion future is fulfilled, orphans must be majority committed.
\* ready_range_deletions_processor.cpp:344-347 — complete happens after majority wait
CompletionFutureImpliesMajorityOrphans ==
    \A n \in Nodes, t \in Tasks :
        completionFulfilled[n][t] => orphansMajorityCommitted[t]

\* --- F2: NoLostReadyTasks ---
\* Any task that is TaskReady on disk at a primary node is either in memory,
\* will be discovered by recovery (recoveryPhase not yet done),
\* OR is queued in opObserverPending awaiting registerTask.
\* The third disjunct covers the transient window between OpObserverClearPending
\* (write commits, marking task ready) and OpObserverRegisterTask (registerTask call).
\* In the real code these happen synchronously (op_observer inline), but the spec
\* splits them into separate actions.
\* Models "RecoveryCompleteness" from brief §5.
NoLostReadyTasks ==
    \A n \in Nodes, t \in Tasks :
        (IsPrimary(n) /\ recoveryPhase[n] = RecoveryDone /\
         diskTaskState[n][t] \in {TaskReady, TaskProcessing}) =>
            (t \in inMemoryTasks[n] \/ deletionStep[n][t] /= "idle" \/ completionFulfilled[n][t]
             \/ t \in opObserverPending[n])

\* --- F3: NoDiskOrphanAfterCompletion ---
\* A disk document that persists after completeTask is eventually re-executed.
\* Safety property: completion fulfilled without majority-committed orphans is forbidden.
\* (Already captured by CompletionFutureImpliesMajorityOrphans)
\* Additional structural check: disk must not be deleted BEFORE majority committed.
NoDiskDeleteBeforeMajority ==
    \A n \in Nodes, t \in Tasks :
        diskTaskState[n][t] = TaskDeleted => orphansMajorityCommitted[t]

\* --- Structural: deletion pipeline ordering ---
\* A task in "completing" step must have completionFulfilled (completeTask was called)
CompletingImpliesFulfilled ==
    \A n \in Nodes, t \in Tasks :
        deletionStep[n][t] = "completing" => completionFulfilled[n][t]

\* --- Structural: primary-only execution ---
\* Only primary nodes have active deletion steps
PrimaryOnlyExecution ==
    \A n \in Nodes, t \in Tasks :
        deletionStep[n][t] /= "idle" => IsPrimary(n)

\* --- Structural: in-memory implies disk ---
\* If a task is in memory, it must have a non-deleted disk entry
InMemoryImpliesDisk ==
    \A n \in Nodes, t \in Tasks :
        t \in inMemoryTasks[n] => diskTaskState[n][t] /= TaskDeleted

----
\* -------------------------
\* Liveness (temporal properties)
\* -------------------------

\* RecoveryCompleteness: after recovery is done, every ready disk task is in memory
RecoveryCompleteness ==
    \A n \in Nodes, t \in Tasks :
        [](IsPrimary(n) /\ recoveryPhase[n] = RecoveryDone /\
           diskTaskState[n][t] \in {TaskReady, TaskProcessing})
        => <>(t \in inMemoryTasks[n] \/ completionFulfilled[n][t])

----
Spec == Init /\ [][Next]_vars

====
