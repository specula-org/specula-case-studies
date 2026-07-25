-------------------------------- MODULE base --------------------------------
\* MongoDB Sharding: Range Deletion Protocol
\* Category A — Distributed / Message-Passing
\*
\* Models the range deletion lifecycle across donor shard, recipient shard,
\* and the migration coordinator document in config.migrationCoordinators.
\*
\* Bug families modeled:
\*   Family 1: Non-atomic coordinator + range deletion task initialization
\*   Family 2: Pending-flag activation gaps (stuck pending tasks)
\*   Family 3: Overlapping range deletion TOCTOU gap
\*   Family 4: Recovery scan non-atomicity (coverage spec target)

EXTENDS Naturals, FiniteSets, Sequences, TLC

-----------------------------------------------------------------------------
\* CONSTANTS

CONSTANTS
    MigrationId,     \* set of migration IDs (e.g., {"m1"})
    Range,           \* set of chunk ranges (e.g., {"r1", "r2"})
    Shard            \* set of shard IDs (e.g., {"donor", "recipient"})

ASSUME Cardinality(MigrationId) >= 1
ASSUME Cardinality(Range) >= 1
ASSUME Cardinality(Shard) >= 2

\* Pick canonical donor/recipient from Shard set — MC overrides these
CONSTANTS DonorShard, RecipientShard
ASSUME DonorShard \in Shard /\ RecipientShard \in Shard /\ DonorShard /= RecipientShard

-----------------------------------------------------------------------------
\* TASK DOCUMENT STATE MACHINE
\*
\* Modeled per range_deletion_task.idl:
\*   absent     — document does not exist
\*   pending    — pending:true; blocked, waiting for migration coordinator decision
\*   ready      — pending:false (or unset); eligible for RangeDeleterService processing
\*   processing — processing:true; currently executing deleteRangeInBatches

TaskState == {"absent", "pending", "ready", "processing"}

\* Coordinator document state — config.migrationCoordinators
\* migration_coordinator.cpp:150 (insertMigrationCoordinatorDoc)
CoordDocState == {"absent", "present", "committed", "aborted"}

-----------------------------------------------------------------------------
\* STATE VARIABLES

VARIABLES
    \* ---- Durable (persistent) state ----

    \* Coordinator document in config.migrationCoordinators
    \* Family 1 & 2: non-atomic two-write init; w:1 forgetMigration
    coordDoc,           \* coordDoc[m] \in CoordDocState

    \* Range deletion task document on donor shard (config.rangeDeletions)
    \* All families: the core state machine
    donorTask,          \* donorTask[m] \in TaskState

    \* Range deletion task document on recipient shard
    \* Family 2: recipient task stuck in pending after abort
    recipientTask,      \* recipientTask[m] \in TaskState

    \* ---- In-memory (volatile) state ----

    \* Tasks registered with RangeDeleterService in-memory map
    \* range_deleter_service.cpp:377 (_rangeDeletionTasks.registerTask)
    inMemoryTasks,      \* inMemoryTasks \subseteq MigrationId (registered, non-pending tasks)

    \* Snapshot of in-memory tasks taken by getOverlappingRangeDeletionsFuture
    \* Family 3: TOCTOU gap — snapshot misses post-snapshot registrations
    \* range_deleter_service.h:153
    overlapSnapshot,    \* overlapSnapshot \in SUBSET MigrationId

    \* ---- Fault-injection extension variables ----

    \* Whether recipient shard is reachable (Family 2)
    recipientShardAlive,  \* recipientShardAlive \in BOOLEAN

    \* Whether the coordinator doc write is durable (Family 2: forgetMigration w:1)
    \* migration_coordinator.cpp:396-401
    coordDocDurable,    \* coordDocDurable[m] \in BOOLEAN

    \* Primary term counter — used to model step-up/step-down/crash
    \* Family 1 & 2: crash between writes; recovery re-runs on new primary
    term,               \* term \in Nat

    \* ---- Ghost variables (observability only, not real system state) ----

    \* Tracks whether WriteRangeDeletionTask ever fired for each migration.
    \* Family 1: distinguishes "task absent because never created" (bug) from
    \* "task absent because it completed" (normal). Durable: persists across crashes.
    donorTaskInitialized  \* donorTaskInitialized[m] \in BOOLEAN

vars == <<coordDoc, donorTask, recipientTask, inMemoryTasks, overlapSnapshot,
          recipientShardAlive, coordDocDurable, term, donorTaskInitialized>>

coordVars   == <<coordDoc, coordDocDurable>>
taskVars    == <<donorTask, recipientTask>>
memoryVars  == <<inMemoryTasks, overlapSnapshot>>
faultVars   == <<recipientShardAlive, term>>

-----------------------------------------------------------------------------
\* TYPE INVARIANT

TypeOK ==
    /\ coordDoc \in [MigrationId -> CoordDocState]
    /\ donorTask \in [MigrationId -> TaskState]
    /\ recipientTask \in [MigrationId -> TaskState]
    /\ inMemoryTasks \subseteq MigrationId
    /\ overlapSnapshot \subseteq MigrationId
    /\ recipientShardAlive \in BOOLEAN
    /\ coordDocDurable \in [MigrationId -> BOOLEAN]
    /\ term \in Nat
    /\ donorTaskInitialized \in [MigrationId -> BOOLEAN]

-----------------------------------------------------------------------------
\* INITIAL STATE

Init ==
    /\ coordDoc       = [m \in MigrationId |-> "absent"]
    /\ donorTask      = [m \in MigrationId |-> "absent"]
    /\ recipientTask  = [m \in MigrationId |-> "absent"]
    /\ inMemoryTasks  = {}
    /\ overlapSnapshot = {}
    /\ recipientShardAlive = TRUE
    /\ coordDocDurable = [m \in MigrationId |-> TRUE]   \* TRUE = no pending w:1 deletion
    /\ term = 1
    /\ donorTaskInitialized = [m \in MigrationId |-> FALSE]

-----------------------------------------------------------------------------
\* ACTIONS — MIGRATION START (Family 1: non-atomic two-write init)
\*
\* MigrationCoordinator::startMigration (migration_coordinator.cpp:147-170)
\* is split into two separate TLA+ actions to model the crash window between
\* insertMigrationCoordinatorDoc (line 150) and createAndPersistRangeDeletionTask
\* (line 158-169).

\* Step 1: Write coordinator document
\* migration_coordinator.cpp:150 — migrationutil::insertMigrationCoordinatorDoc
WriteCoordDoc(m) ==
    /\ coordDoc[m] = "absent"                      \* pre: no existing doc
    /\ donorTask[m] = "absent"                     \* pre: clean start
    /\ coordDoc' = [coordDoc EXCEPT ![m] = "present"]
    /\ coordDocDurable' = [coordDocDurable EXCEPT ![m] = TRUE]
    /\ UNCHANGED <<donorTask, recipientTask, inMemoryTasks, overlapSnapshot,
                   recipientShardAlive, term, donorTaskInitialized>>

\* Step 2: Write range deletion task on donor
\* migration_coordinator.cpp:158-169 — createAndPersistRangeDeletionTask
\* Note: task starts as pending:true (last arg 'true' at line 166 maps to pending flag)
\* range_deletion_util.cpp:147-170 — createAndPersistRangeDeletionTask
WriteRangeDeletionTask(m) ==
    /\ coordDoc[m] = "present"                     \* pre: coord doc written
    /\ donorTask[m] = "absent"                     \* pre: task not yet written
    /\ donorTask' = [donorTask EXCEPT ![m] = "pending"]
    \* recipient also gets a pending task (created on recipient during cloning setup)
    /\ recipientTask' = [recipientTask EXCEPT ![m] = "pending"]
    /\ donorTaskInitialized' = [donorTaskInitialized EXCEPT ![m] = TRUE]
    /\ UNCHANGED <<coordDoc, coordDocDurable, inMemoryTasks, overlapSnapshot,
                   recipientShardAlive, term>>

-----------------------------------------------------------------------------
\* ACTIONS — DECISION DELIVERY (commit path)
\*
\* MigrationCoordinator::_commitMigrationOnDonorAndRecipient
\* migration_coordinator.cpp:231-324

\* Persist commit decision in coordinator doc
\* migration_coordinator.cpp:240 — persistCommitDecision
PersistCommitDecision(m) ==
    /\ coordDoc[m] = "present"                     \* pre: migration started
    /\ coordDoc' = [coordDoc EXCEPT ![m] = "committed"]
    /\ UNCHANGED <<donorTask, recipientTask, inMemoryTasks, overlapSnapshot,
                   coordDocDurable, recipientShardAlive, term, donorTaskInitialized>>

\* Delete recipient range deletion task on commit
\* migration_coordinator.cpp:278-282 — deleteRangeDeletionTaskOnRecipient
DeleteRecipientTaskOnCommit(m) ==
    /\ coordDoc[m] = "committed"
    /\ recipientTask[m] \in {"pending", "ready"}
    /\ recipientTask' = [recipientTask EXCEPT ![m] = "absent"]
    /\ UNCHANGED <<coordDoc, coordDocDurable, donorTask, inMemoryTasks,
                   overlapSnapshot, recipientShardAlive, term, donorTaskInitialized>>

\* Activate donor range deletion task on commit
\* migration_coordinator.cpp:285-323
\* Family 1 bug path: if _donorRangeDeletionTask is null (line 289-294),
\* returns makeReady() — silent skip, orphan persists.
\*
\* This action models the SUCCESSFUL path (task exists, gets activated).
\* The early-return (silent-skip) path is modeled separately in CommitSilentSkip.
ActivateDonorTaskOnCommit(m) ==
    /\ coordDoc[m] = "committed"
    /\ donorTask[m] = "pending"                    \* task exists (not absent)
    \* migration_coordinator.cpp:285-288: _donorRangeDeletionTask lookup succeeds
    \* migration_coordinator.cpp:309-311: registerTask with TaskPending::kPending
    /\ inMemoryTasks' = inMemoryTasks \cup {m}
    \* migration_coordinator.cpp:320-321: markAsReadyRangeDeletionTaskLocally
    /\ donorTask' = [donorTask EXCEPT ![m] = "ready"]
    /\ UNCHANGED <<coordDoc, coordDocDurable, recipientTask, overlapSnapshot,
                   recipientShardAlive, term, donorTaskInitialized>>

\* Family 1 — silent skip: donor task absent on commit (crash between two writes)
\* migration_coordinator.cpp:289-294: if !_donorRangeDeletionTask, return makeReady()
\* This is the bug: committed migration, donor range never deleted.
CommitSilentSkip(m) ==
    /\ coordDoc[m] = "committed"
    /\ donorTask[m] = "absent"                     \* task missing — crash window was hit
    \* migration_coordinator.cpp:294: return Future<void>::makeReady()
    \* No donorTask update — task stays absent, range is never cleaned up
    /\ UNCHANGED vars

-----------------------------------------------------------------------------
\* ACTIONS — DECISION DELIVERY (abort path)
\*
\* MigrationCoordinator::_abortMigrationOnDonorAndRecipient
\* migration_coordinator.cpp:326-387

\* Persist abort decision
\* migration_coordinator.cpp:334 — persistAbortDecision
PersistAbortDecision(m) ==
    /\ coordDoc[m] = "present"
    /\ coordDoc' = [coordDoc EXCEPT ![m] = "aborted"]
    /\ UNCHANGED <<donorTask, recipientTask, inMemoryTasks, overlapSnapshot,
                   coordDocDurable, recipientShardAlive, term, donorTaskInitialized>>

\* Delete donor range deletion task on abort
\* migration_coordinator.cpp:347-350 — deleteRangeDeletionTaskLocally
\* (donor keeps no task after abort — the migrated range belongs to recipient)
DeleteDonorTaskOnAbort(m) ==
    /\ coordDoc[m] = "aborted"
    /\ donorTask[m] \in {"pending", "ready"}
    /\ donorTask' = [donorTask EXCEPT ![m] = "absent"]
    /\ UNCHANGED <<coordDoc, coordDocDurable, recipientTask, inMemoryTasks,
                   overlapSnapshot, recipientShardAlive, term, donorTaskInitialized>>

\* Advance transaction on recipient (abort) — wrapped in try/catch for ShardNotFound
\* migration_coordinator.cpp:352-375 — try block covers advanceTransactionOnRecipient
\* This action models success (recipient shard reachable)
AdvanceTransactionOnRecipientAbort(m) ==
    /\ coordDoc[m] = "aborted"
    /\ recipientShardAlive = TRUE                  \* shard is reachable
    /\ donorTask[m] = "absent"                     \* donor task already deleted
    \* This is a no-op in the spec state — the RPC advances the transaction number
    \* but no spec variable changes at this point
    /\ UNCHANGED vars

\* Family 2 — markAsReadyRangeDeletionTaskOnRecipient is OUTSIDE the try/catch
\* migration_coordinator.cpp:382-386: outside try block at line 352-375
\* If recipientShardAlive = FALSE and we reach here, ShardNotFound propagates uncaught.
\*
\* Successful path: activate recipient task
MarkRecipientTaskReady(m) ==
    /\ coordDoc[m] = "aborted"
    /\ recipientTask[m] = "pending"
    /\ recipientShardAlive = TRUE                  \* shard alive — success path
    \* migration_coordinator.cpp:382-386: markAsReadyRangeDeletionTaskOnRecipient
    /\ recipientTask' = [recipientTask EXCEPT ![m] = "ready"]
    /\ UNCHANGED <<coordDoc, coordDocDurable, donorTask, inMemoryTasks,
                   overlapSnapshot, recipientShardAlive, term, donorTaskInitialized>>

\* Family 2 bug path: ShardNotFound propagates uncaught from markAsReadyRangeDeletionTaskOnRecipient
\* recipient task remains pending indefinitely
\* The action models the failure: shard is gone, line 382 throws, task stays pending.
MarkRecipientTaskReadyFails(m) ==
    /\ coordDoc[m] = "aborted"
    /\ recipientTask[m] = "pending"
    /\ recipientShardAlive = FALSE                 \* shard not found — bug path
    \* migration_coordinator.cpp:382: ShardNotFound propagates uncaught
    \* recipientTask stays "pending" — stuck indefinitely
    /\ UNCHANGED vars

-----------------------------------------------------------------------------
\* ACTIONS — FORGET MIGRATION
\*
\* MigrationCoordinator::forgetMigration (migration_coordinator.cpp:389-401)
\* Family 2: uses WriteConcernOptions{1,...} (w:1), not majority
\* migration_coordinator.cpp:396-401

\* Write coordinator doc deletion with w:1 (non-majority)
\* The deletion goes to primary but may not replicate before stepdown
ForgetMigration(m) ==
    /\ coordDoc[m] \in {"committed", "aborted"}
    \* migration_coordinator.cpp:398-401: store.remove with WriteConcernOptions{1}
    /\ coordDoc' = [coordDoc EXCEPT ![m] = "absent"]
    /\ coordDocDurable' = [coordDocDurable EXCEPT ![m] = FALSE]  \* w:1: not majority-durable
    /\ UNCHANGED <<donorTask, recipientTask, inMemoryTasks, overlapSnapshot,
                   recipientShardAlive, term, donorTaskInitialized>>

-----------------------------------------------------------------------------
\* ACTIONS — RANGE DELETION EXECUTION

\* RangeDeleterService processes a ready task
\* ready_range_deletions_processor.cpp:290-400
ExecuteRangeDeletion(m) ==
    /\ donorTask[m] = "ready"
    /\ m \in inMemoryTasks
    /\ donorTask' = [donorTask EXCEPT ![m] = "processing"]
    /\ UNCHANGED <<coordDoc, coordDocDurable, recipientTask, inMemoryTasks,
                   overlapSnapshot, recipientShardAlive, term, donorTaskInitialized>>

\* Range deletion completes — task removed from disk and in-memory map
\* ready_range_deletions_processor.cpp: completeTask
CompleteRangeDeletion(m) ==
    /\ donorTask[m] = "processing"
    /\ m \in inMemoryTasks
    /\ donorTask' = [donorTask EXCEPT ![m] = "absent"]
    /\ inMemoryTasks' = inMemoryTasks \ {m}
    /\ UNCHANGED <<coordDoc, coordDocDurable, recipientTask, overlapSnapshot,
                   recipientShardAlive, term, donorTaskInitialized>>

\* Execute recipient range deletion (after it becomes ready)
ExecuteRecipientRangeDeletion(m) ==
    /\ recipientTask[m] = "ready"
    /\ recipientTask' = [recipientTask EXCEPT ![m] = "processing"]
    /\ UNCHANGED <<coordDoc, coordDocDurable, donorTask, inMemoryTasks,
                   overlapSnapshot, recipientShardAlive, term, donorTaskInitialized>>

CompleteRecipientRangeDeletion(m) ==
    /\ recipientTask[m] = "processing"
    /\ recipientTask' = [recipientTask EXCEPT ![m] = "absent"]
    /\ UNCHANGED <<coordDoc, coordDocDurable, donorTask, inMemoryTasks,
                   overlapSnapshot, recipientShardAlive, term, donorTaskInitialized>>

-----------------------------------------------------------------------------
\* ACTIONS — OVERLAP SNAPSHOT (Family 3: TOCTOU gap)
\*
\* CollectionShardingRuntime::getOverlappingRangeDeletionsFuture
\* range_deleter_service.h:153-158
\* range_deleter_service.cpp:506-528

\* Take a point-in-time snapshot of in-memory tasks
\* Family 3: any task registered AFTER this snapshot is invisible to the caller
GetOverlapSnapshot ==
    \* range_deleter_service.cpp:506: takes lock, collects in-memory tasks, returns
    /\ overlapSnapshot' = inMemoryTasks            \* snapshot at this instant
    /\ UNCHANGED <<coordDoc, coordDocDurable, donorTask, recipientTask,
                   inMemoryTasks, recipientShardAlive, term, donorTaskInitialized>>

\* A new task is registered AFTER the snapshot (post-snapshot registration)
\* Family 3 bug path: new task is not in overlapSnapshot, migration proceeds
\* without waiting for this new deletion task
RegisterTaskPostSnapshot(m) ==
    /\ donorTask[m] = "ready"                      \* task exists and is ready
    /\ m \notin overlapSnapshot                    \* not in the snapshot
    /\ m \notin inMemoryTasks                      \* not yet registered
    /\ inMemoryTasks' = inMemoryTasks \cup {m}
    /\ UNCHANGED <<coordDoc, coordDocDurable, donorTask, recipientTask,
                   overlapSnapshot, recipientShardAlive, term, donorTaskInitialized>>

-----------------------------------------------------------------------------
\* ACTIONS — CRASH AND RECOVERY (Families 1, 2)
\*
\* Crash: discard all in-memory state, retain durable state.
\* In-memory state: inMemoryTasks, overlapSnapshot
\* The crash can happen between any two sequential persistent writes.

Crash ==
    \* Discard volatile in-memory state; persistent state survives
    /\ inMemoryTasks' = {}
    /\ overlapSnapshot' = {}
    /\ term' = term + 1                            \* new term on step-up
    /\ UNCHANGED <<coordDoc, coordDocDurable, donorTask, recipientTask,
                   recipientShardAlive, donorTaskInitialized>>

\* Step-up recovery: RangeDeleterService._launchRangeDeletionRecoveryTask
\* range_deleter_service.cpp:200-261
\*
\* Pass 1 (line 221-231): register tasks with processing == true
\* Pass 2 (line 241-254): register tasks with processing != true AND pending != true
\*
\* Note: pending == true tasks are EXCLUDED from both passes (by design).
\* This is the correct protocol behavior, not a bug.
Recovery ==
    /\ inMemoryTasks = {}                          \* guard: only after crash/step-up
    \* Pass 1: re-register processing tasks
    \* Pass 2: re-register ready tasks (non-pending, non-processing)
    \* range_deleter_service.cpp:243-246: filter $ne processing, $ne pending
    /\ LET recoveredTasks == {m \in MigrationId :
                                donorTask[m] \in {"ready", "processing"}}
       IN inMemoryTasks' = recoveredTasks
    /\ UNCHANGED <<coordDoc, coordDocDurable, donorTask, recipientTask,
                   overlapSnapshot, recipientShardAlive, term, donorTaskInitialized>>

\* Fault injection: shard removal (models ShardNotFound for recipient)
\* Family 2: enables MarkRecipientTaskReadyFails path
RemoveRecipientShard ==
    /\ recipientShardAlive = TRUE
    /\ recipientShardAlive' = FALSE
    /\ UNCHANGED <<coordDoc, coordDocDurable, donorTask, recipientTask,
                   inMemoryTasks, overlapSnapshot, term, donorTaskInitialized>>

\* Fault injection: recipient shard rejoins
\* Family 2: shard rejoins but coordinator already completed — task stays stuck
RecipientShardRejoins ==
    /\ recipientShardAlive = FALSE
    /\ recipientShardAlive' = TRUE
    /\ UNCHANGED <<coordDoc, coordDocDurable, donorTask, recipientTask,
                   inMemoryTasks, overlapSnapshot, term, donorTaskInitialized>>

\* Fault injection: stepdown before forgetMigration replicates (w:1 write lost)
\* Family 2: coordinator doc reappears after rollback; recovery re-runs
\* migration_coordinator.cpp:396-401: w:1 write not replicated before stepdown
RollbackForgetMigration(m) ==
    /\ coordDoc[m] = "absent"                      \* was deleted with w:1
    /\ coordDocDurable[m] = FALSE                  \* deletion not yet majority-durable
    \* Rollback: coordinator doc reappears with its last decision
    \* On recovery, completeMigration will be re-called
    /\ coordDoc' = [coordDoc EXCEPT ![m] = "committed"]  \* or aborted; model committed
    /\ coordDocDurable' = [coordDocDurable EXCEPT ![m] = TRUE]
    /\ UNCHANGED <<donorTask, recipientTask, inMemoryTasks, overlapSnapshot,
                   recipientShardAlive, term, donorTaskInitialized>>

-----------------------------------------------------------------------------
\* NEXT STATE

Next ==
    \/ \E m \in MigrationId :
        \/ WriteCoordDoc(m)
        \/ WriteRangeDeletionTask(m)
        \/ PersistCommitDecision(m)
        \/ DeleteRecipientTaskOnCommit(m)
        \/ ActivateDonorTaskOnCommit(m)
        \/ CommitSilentSkip(m)
        \/ PersistAbortDecision(m)
        \/ DeleteDonorTaskOnAbort(m)
        \/ AdvanceTransactionOnRecipientAbort(m)
        \/ MarkRecipientTaskReady(m)
        \/ MarkRecipientTaskReadyFails(m)
        \/ ForgetMigration(m)
        \/ ExecuteRangeDeletion(m)
        \/ CompleteRangeDeletion(m)
        \/ ExecuteRecipientRangeDeletion(m)
        \/ CompleteRecipientRangeDeletion(m)
        \/ RegisterTaskPostSnapshot(m)
        \/ RollbackForgetMigration(m)
    \/ GetOverlapSnapshot
    \/ Crash
    \/ Recovery
    \/ RemoveRecipientShard
    \/ RecipientShardRejoins

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* FAIRNESS (for liveness properties)

Fairness ==
    /\ WF_vars(Recovery)
    /\ \A m \in MigrationId :
        /\ WF_vars(WriteCoordDoc(m))
        /\ WF_vars(WriteRangeDeletionTask(m))
        /\ WF_vars(ActivateDonorTaskOnCommit(m))
        /\ WF_vars(MarkRecipientTaskReady(m))
        /\ WF_vars(ExecuteRangeDeletion(m))
        /\ WF_vars(CompleteRangeDeletion(m))
        /\ WF_vars(ExecuteRecipientRangeDeletion(m))
        /\ WF_vars(CompleteRecipientRangeDeletion(m))

LiveSpec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* INVARIANTS

\* -- Structural invariants --

\* A pending task implies the coordinator document is present (or the coord doc
\* was deleted before the task was activated — both valid states)
PendingImpliesCoordOrDecisionDelivered(m) ==
    donorTask[m] = "pending" =>
        coordDoc[m] \in {"present", "committed", "aborted", "absent"}

\* A processing task must be in the in-memory task map
\* Exception: the post-crash transient window (inMemoryTasks = {}) before Recovery runs.
ProcessingImpliesInMemory ==
    \A m \in MigrationId :
        donorTask[m] = "processing" =>
            (m \in inMemoryTasks \/ inMemoryTasks = {})

\* -- Safety invariants (Bug Family targets) --

\* Family 1 — OrphanEventualCleanup (Safety component):
\* If the migration is committed, the donor task must have been initialized at some point
\* (WriteRangeDeletionTask fired) OR must still be present on disk (non-absent).
\* Violation: coordDoc=committed AND donorTask=absent AND task was NEVER initialized.
\* This catches the crash-between-writes bug: WriteCoordDoc fired but WriteRangeDeletionTask
\* did not, and then the migration was committed — CommitSilentSkip silently skips cleanup,
\* leaving the donor range as a permanent orphan.
\* Ghost variable donorTaskInitialized distinguishes "task completed" (initialized=TRUE)
\* from "task never created" (initialized=FALSE).
NoOrphanOnCommit ==
    \A m \in MigrationId :
        coordDoc[m] = "committed" =>
            (donorTask[m] /= "absent" \/ donorTaskInitialized[m])

\* Family 3 — NoSimultaneousOverlappingDeletions:
\* No two range deletion tasks for the same range proceed simultaneously.
\* In this single-range model, at most one task should be in "processing" state.
NoSimultaneousDonorProcessing ==
    Cardinality({m \in MigrationId : donorTask[m] = "processing"}) <= 1

\* Family 2 — safety component:
\* An aborted migration's coordinator doc should not persist after forgetMigration
\* while the recipient task is stuck in pending with no activation path.
NoAbortedCoordWithStuckPendingRecipient ==
    \A m \in MigrationId :
        ~ (coordDoc[m] = "absent"
           /\ recipientTask[m] = "pending"
           /\ recipientShardAlive = FALSE)

\* Family 4 — RecoveryCompleteness (Safety):
\* After recovery, every ready/processing task on disk has a corresponding in-memory registration.
\* The post-crash transient window (inMemoryTasks = {}) before Recovery runs is excluded —
\* the invariant applies only to the steady state after recovery has executed.
\* range_deleter_service.cpp:220-254
RecoveryCompleteness ==
    \A m \in MigrationId :
        donorTask[m] \in {"ready", "processing"} =>
            (m \in inMemoryTasks \/ inMemoryTasks = {})

-----------------------------------------------------------------------------
\* LIVENESS PROPERTIES

\* Family 1 — OrphanEventualCleanup (Liveness):
\* After a committed migration, the donor range deletion task is eventually absent
\* (meaning it was activated and executed, not silently skipped).
OrphanEventualCleanup ==
    \A m \in MigrationId :
        [](coordDoc[m] = "committed" => <>(donorTask[m] = "absent"))

\* Family 2 — AbortedMigrationRecipientCleanup (Liveness):
\* After an aborted migration with recipient alive, the recipient task eventually executes.
AbortedMigrationRecipientCleanup ==
    \A m \in MigrationId :
        [](coordDoc[m] = "aborted" /\ recipientShardAlive => <>(recipientTask[m] = "absent"))

\* Family 2 — NoPermanentPendingTask (Liveness):
\* No task remains pending indefinitely if its coordinator has reached a decision.
NoPermanentPendingTask ==
    \A m \in MigrationId :
        [](coordDoc[m] \in {"committed", "aborted"} /\ donorTask[m] = "pending"
            => <>(donorTask[m] /= "pending"))

=============================================================================
