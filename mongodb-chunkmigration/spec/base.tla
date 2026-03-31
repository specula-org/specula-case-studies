---- MODULE base ----
\* MongoDB Chunk Migration — Full Donor-Recipient Flow
\* Models the complete migration lifecycle including commit/abort cleanup,
\* range deletion task identity, recovery, and back-to-back migration.
\*
\* Source files:
\*   migration_source_manager.cpp (donor lifecycle)
\*   migration_coordinator.cpp (commit/abort cleanup)
\*   range_deletion_util.cpp (range deletion task operations)
\*   migration_util.cpp (recovery, persistence)

EXTENDS Integers, FiniteSets, Sequences, TLC

CONSTANTS
    MigrationId,   \* Set of migration IDs (e.g., {"m1", "m2"})
    Nil            \* Distinguished nil value

\* ==============================================================
\* Phase and decision constants
\* ==============================================================

\* Donor phases (migration_source_manager.cpp state machine)
\* kCreated(295) → kCloning(486) → kCloneCaughtUp(544) → kCriticalSection(568)
\* → kCloneCompleted(620) → kCommittingOnConfig(661) → kDone(974)
Idle               == "idle"
Prepared           == "prepared"              \* Abstraction: kCreated..kCloneCompleted
CommittingOnConfig == "committingOnConfig"     \* kCommittingOnConfig
Cleaning           == "cleaning"              \* Running cleanup sub-steps

\* Decision values (migration_coordinator_document_gen.h)
NoDecision == "none"
Committed  == "committed"
Aborted    == "aborted"

\* Cleanup sub-step constants — commit path
\* migration_coordinator.cpp:231-324 (_commitMigrationOnDonorAndRecipient)
CmtPersist   == "cmtPersist"    \* persistCommitDecision           (line 240)
CmtAdvTxn    == "cmtAdvTxn"     \* advanceTransactionOnRecipient   (line 252)
CmtGetOrph   == "cmtGetOrph"    \* retrieveNumOrphansFromShard     (line 265)
CmtPersOrph  == "cmtPersOrph"   \* persistUpdatedNumOrphans        (line 269)
CmtDelRecip  == "cmtDelRecip"   \* deleteRangeDeletionTaskOnRecip  (line 278)
CmtGetTask   == "cmtGetTask"    \* getRangeDeletionTask            (line 285)
CmtMarkReady == "cmtMarkReady"  \* markAsReadyRangeDeletionTaskLoc (line 320)
CmtForget    == "cmtForget"     \* forgetMigration                 (line 226)

\* Cleanup sub-step constants — abort path
\* migration_coordinator.cpp:326-387 (_abortMigrationOnDonorAndRecipient)
AbtPersist   == "abtPersist"    \* persistAbortDecision             (line 334)
AbtDelLocal  == "abtDelLocal"   \* deleteRangeDeletionTaskLocally   (line 347)
AbtAdvTxn    == "abtAdvTxn"     \* advanceTransactionOnRecipient    (line 361)
AbtMarkRecip == "abtMarkRecip"  \* markAsReadyRangeDeletionTaskOnR  (line 382)
AbtForget    == "abtForget"     \* forgetMigration                  (line 226)

NoCleanup    == "noCleanup"     \* No active cleanup
CleanupDone  == "cleanupDone"   \* Cleanup finished, pending completion

\* ==============================================================
\* Variables
\* ==============================================================

VARIABLES
    \* --- Core migration lifecycle (migration_source_manager.cpp) ---
    activeMigration,    \* MigrationId ∪ {Nil}: currently active migration
    migrationPhase,     \* Idle | Prepared | CommittingOnConfig | Cleaning

    \* --- Persistent state (survives stepdown) ---
    \* Coordinator documents: [MigrationId -> {NoDecision, Committed, Aborted, Nil}]
    \* Nil = no document exists for this migration
    coordDocs,
    \* Donor range deletion tasks: set of [id: MigrationId, pending: BOOLEAN]
    donorTasks,
    \* Set of MigrationIds that config server committed
    configCommitted,

    \* --- Cleanup tracking (migration_coordinator.cpp) ---
    cleanupPhase,       \* Current cleanup sub-step or NoCleanup
    cleanupMid,         \* MigrationId being cleaned up (or Nil)

    \* --- Durability tracking (Bug Family 5) ---
    \* Saves decision of docs deleted with w:1 forgetMigration; restored on stepdown
    forgetPending,      \* [MigrationId -> {Committed, Aborted, Nil}]
    \* Cumulative orphan count increments (detects non-idempotent $inc)
    orphanDelta,

    \* --- Fault injection ---
    recipientExists,    \* BOOLEAN (Bug Family 2: ShardNotFound)

    \* --- Auxiliary ---
    completedMigrations \* Set of completed MigrationIds

\* Variable groups for UNCHANGED clauses
lifecycleVars == <<activeMigration, migrationPhase>>
persistVars   == <<coordDocs, donorTasks, configCommitted>>
cleanupVars   == <<cleanupPhase, cleanupMid>>
durVars       == <<forgetPending, orphanDelta>>
faultVars     == <<recipientExists>>
auxVars       == <<completedMigrations>>

vars == <<lifecycleVars, persistVars, cleanupVars, durVars, faultVars, auxVars>>

\* ==============================================================
\* Init
\* ==============================================================
Init ==
    /\ activeMigration = Nil
    /\ migrationPhase = Idle
    /\ coordDocs = [m \in MigrationId |-> Nil]
    /\ donorTasks = {}
    /\ configCommitted = {}
    /\ cleanupPhase = NoCleanup
    /\ cleanupMid = Nil
    /\ forgetPending = [m \in MigrationId |-> Nil]
    /\ orphanDelta = 0
    /\ recipientExists = TRUE
    /\ completedMigrations = {}

\* ==============================================================
\* Migration Lifecycle Actions
\* ==============================================================

\* -------------------------------------------------------
\* StartMigration(mid)
\* migration_source_manager.cpp:187-385 (createMigrationSourceManager)
\* migration_coordinator.cpp:147-170 (startMigration)
\* -------------------------------------------------------
StartMigration(mid) ==
    /\ activeMigration = Nil
    /\ migrationPhase = Idle
    /\ mid \notin completedMigrations
    /\ cleanupPhase = NoCleanup
    \* Drain check: no coordinator docs remaining
    \* migration_source_manager.cpp:208-216: drainMigrationsPendingRecovery + invariant
    /\ \A m \in MigrationId : coordDocs[m] = Nil
    \* No conflicting range deletion tasks
    \* migration_source_manager.cpp:346: checkForConflictingDeletions
    /\ donorTasks = {}
    \* Create coordinator document (majority write concern)
    \* migration_coordinator.cpp:150: insertMigrationCoordinatorDoc
    /\ coordDocs' = [coordDocs EXCEPT ![mid] = NoDecision]
    \* Create range deletion task on donor (pending=TRUE, majority WC)
    \* migration_coordinator.cpp:158-169: createAndPersistRangeDeletionTask
    /\ donorTasks' = donorTasks \cup {[id |-> mid, pending |-> TRUE]}
    /\ activeMigration' = mid
    /\ migrationPhase' = Prepared
    /\ UNCHANGED <<configCommitted, cleanupVars, durVars, faultVars, auxVars>>

\* -------------------------------------------------------
\* AdvanceToConfigCommit(mid)
\* Abstraction of clone/catchup/critSec/commitOnRecipient
\* migration_source_manager.cpp:404-623 (startClone..commitChunkOnRecipient)
\* -------------------------------------------------------
AdvanceToConfigCommit(mid) ==
    /\ activeMigration = mid
    /\ migrationPhase = Prepared
    /\ migrationPhase' = CommittingOnConfig
    /\ UNCHANGED <<activeMigration, persistVars, cleanupVars, durVars, faultVars, auxVars>>

\* -------------------------------------------------------
\* ConfigCommitSucceed(mid)
\* Config server commits; donor receives success response
\* migration_source_manager.cpp:665-671 (commit RPC succeeds)
\* migration_source_manager.cpp:778 (setMigrationDecision kCommitted)
\* migration_source_manager.cpp:794 → _cleanup(true) → completeMigration
\* -------------------------------------------------------
ConfigCommitSucceed(mid) ==
    /\ activeMigration = mid
    /\ migrationPhase = CommittingOnConfig
    \* Config server records the commit
    /\ configCommitted' = configCommitted \cup {mid}
    \* Donor sets decision to committed
    \* migration_source_manager.cpp:778: setMigrationDecision(kCommitted)
    /\ coordDocs' = [coordDocs EXCEPT ![mid] = Committed]
    \* Enter commit cleanup
    \* _cleanup(true) → completeMigration → _commitMigrationOnDonorAndRecipient
    /\ migrationPhase' = Cleaning
    /\ cleanupPhase' = CmtPersist
    /\ cleanupMid' = mid
    /\ UNCHANGED <<activeMigration, donorTasks, durVars, faultVars, auxVars>>

\* -------------------------------------------------------
\* ConfigCommitFail(mid)
\* Config commit RPC fails; donor enters limbo (Bug Family 3)
\* migration_source_manager.cpp:681-698: error handling
\* _cleanup(false) at line 694:
\*   state = kCommittingOnConfig → NOT < kCommittingOnConfig → decision NOT set (953-955)
\*   completeMigration = false → NOT called (966)
\* Coordinator doc persists with NoDecision — LIMBO STATE
\* -------------------------------------------------------
ConfigCommitFail(mid) ==
    /\ activeMigration = mid
    /\ migrationPhase = CommittingOnConfig
    \* Bug Family 3: coordinator doc persists with no decision
    \* coordDocs[mid] remains NoDecision
    /\ activeMigration' = Nil
    /\ migrationPhase' = Idle
    /\ UNCHANGED <<persistVars, cleanupVars, durVars, faultVars, auxVars>>

\* -------------------------------------------------------
\* ConfigServerCommitAsync(mid)
\* Config server commits independently of donor knowledge
\* The commit RPC may have reached config even though donor got error
\* Relevant for Bug Family 3: limbo resolution
\* -------------------------------------------------------
ConfigServerCommitAsync(mid) ==
    /\ coordDocs[mid] /= Nil
    /\ mid \notin configCommitted
    /\ configCommitted' = configCommitted \cup {mid}
    /\ UNCHANGED <<lifecycleVars, coordDocs, donorTasks, cleanupVars, durVars, faultVars, auxVars>>

\* -------------------------------------------------------
\* AbortBeforeConfigCommit(mid)
\* Abort during prepared phase (before config commit)
\* migration_source_manager.cpp:832-853: _cleanupOnError → _cleanup(true)
\* _cleanup(true): state < kCommittingOnConfig → decision = kAborted (953-954)
\* completeMigration(true) → _abortMigrationOnDonorAndRecipient (966-970)
\* -------------------------------------------------------
AbortBeforeConfigCommit(mid) ==
    /\ activeMigration = mid
    /\ migrationPhase = Prepared
    \* migration_source_manager.cpp:954: setMigrationDecision(kAborted)
    /\ coordDocs' = [coordDocs EXCEPT ![mid] = Aborted]
    /\ migrationPhase' = Cleaning
    /\ cleanupPhase' = AbtPersist
    /\ cleanupMid' = mid
    /\ UNCHANGED <<activeMigration, donorTasks, configCommitted, durVars, faultVars, auxVars>>

\* ==============================================================
\* Commit Cleanup Sub-Steps
\* migration_coordinator.cpp:231-324 (_commitMigrationOnDonorAndRecipient)
\* ==============================================================

\* Step: persistCommitDecision
\* migration_util.cpp:282-302
\* Idempotent: NoMatchingDocument silently caught (line 291)
DoCommitPersist(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = CmtPersist
    \* migration_util.cpp:289: updateMigrationCoordinatorDoc
    /\ coordDocs' = [coordDocs EXCEPT ![mid] = Committed]
    /\ cleanupPhase' = CmtAdvTxn
    /\ UNCHANGED <<lifecycleVars, donorTasks, configCommitted, cleanupMid, durVars, faultVars, auxVars>>

\* Step: advanceTransactionOnRecipient (commit path)
\* migration_util.cpp:324-354
\* Bug Family 2: NOT in try-catch for ShardNotFound
\* migration_coordinator.cpp:252-255 (no try-catch)
\* Compare abort path: migration_coordinator.cpp:365-375 (has try-catch)
DoCommitAdvanceTxn(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = CmtAdvTxn
    /\ recipientExists  \* Bug Family 2: No ShardNotFound handling → stuck if FALSE
    /\ cleanupPhase' = CmtGetOrph
    /\ UNCHANGED <<lifecycleVars, persistVars, cleanupMid, durVars, faultVars, auxVars>>

\* Step: retrieveNumOrphansFromShard
\* range_deletion_util.cpp:631-656
\* Bug Family 2: NOT in try-catch for ShardNotFound
\* migration_coordinator.cpp:265-266
DoCommitRetrieveOrphans(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = CmtGetOrph
    /\ recipientExists  \* Bug Family 2: No ShardNotFound handling
    /\ cleanupPhase' = CmtPersOrph
    /\ UNCHANGED <<lifecycleVars, persistVars, cleanupMid, durVars, faultVars, auxVars>>

\* Step: persistUpdatedNumOrphans
\* range_deletion_util.cpp:535-557
\* Bug Family 1: uses getQueryFilterForRangeDeletionTask (no migrationId, line 539)
\* Bug Family 5: uses non-idempotent $inc (line 549)
DoCommitPersistOrphans(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = CmtPersOrph
    \* range_deletion_util.cpp:539: filter = getQueryFilterForRangeDeletionTask(collUuid, range)
    \* Bug Family 1: no migrationId in filter — may update wrong task
    \* range_deletion_util.cpp:549: BSON("$inc" << ...) — non-idempotent
    \* Bug Family 5: recovery replay doubles orphan count
    /\ orphanDelta' = orphanDelta + 1
    /\ cleanupPhase' = CmtDelRecip
    /\ UNCHANGED <<lifecycleVars, persistVars, cleanupMid, forgetPending, faultVars, auxVars>>

\* Step: deleteRangeDeletionTaskOnRecipient
\* range_deletion_util.cpp:659-700
\* Bug Family 2: NOT in try-catch for ShardNotFound
\* migration_coordinator.cpp:278-282
DoCommitDeleteRecipientTask(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = CmtDelRecip
    /\ recipientExists  \* Bug Family 2: No ShardNotFound handling
    /\ cleanupPhase' = CmtGetTask
    /\ UNCHANGED <<lifecycleVars, persistVars, cleanupMid, durVars, faultVars, auxVars>>

\* Step: getRangeDeletionTask
\* range_deletion_util.cpp:835-848
\* Bug Family 1: uses getQueryFilterForRangeDeletionTask (no migrationId, line 841)
\* migration_coordinator.cpp:285-294: if no task found, return immediately
DoCommitGetDonorTask(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = CmtGetTask
    \* range_deletion_util.cpp:841: filter without migrationId
    \* Bug Family 1: may read wrong migration's task
    /\ IF donorTasks /= {}
       THEN cleanupPhase' = CmtMarkReady  \* Found a task (may be wrong one)
       ELSE cleanupPhase' = CmtForget     \* No task, skip markReady (line 289-294)
    /\ UNCHANGED <<lifecycleVars, persistVars, cleanupMid, durVars, faultVars, auxVars>>

\* Step: markAsReadyRangeDeletionTaskLocally
\* range_deletion_util.cpp:717-741
\* Bug Family 1: builds own query WITHOUT migrationId (line 721-725)
\* Uses {collectionUuid, range.min, range.max} only
DoCommitMarkReady(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = CmtMarkReady
    /\ donorTasks /= {}
    \* range_deletion_util.cpp:721-725: query = {collUuid, range.min, range.max}
    \* Bug Family 1: no migrationId — matches ANY task for this range
    \* Non-deterministic choice models MongoDB picking first matching document
    /\ \E t \in donorTasks :
        donorTasks' = (donorTasks \ {t}) \cup {[id |-> t.id, pending |-> FALSE]}
    /\ cleanupPhase' = CmtForget
    /\ UNCHANGED <<lifecycleVars, coordDocs, configCommitted, cleanupMid, durVars, faultVars, auxVars>>

\* Step: forgetMigration (commit path)
\* migration_coordinator.cpp:389-401
\* Bug Family 5: uses WriteConcernOptions{1} (w:1, line 400)
DoCommitForget(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = CmtForget
    \* migration_coordinator.cpp:398-400: store.remove with WriteConcernOptions{1}
    \* Bug Family 5: w:1 write may be rolled back on stepdown
    /\ forgetPending' = [forgetPending EXCEPT ![mid] = coordDocs[mid]]
    /\ coordDocs' = [coordDocs EXCEPT ![mid] = Nil]
    /\ cleanupPhase' = CleanupDone
    /\ UNCHANGED <<lifecycleVars, donorTasks, configCommitted, cleanupMid, orphanDelta, faultVars, auxVars>>

\* ==============================================================
\* Abort Cleanup Sub-Steps
\* migration_coordinator.cpp:326-387 (_abortMigrationOnDonorAndRecipient)
\* ==============================================================

\* Step: persistAbortDecision
\* migration_util.cpp:304-322
\* Idempotent: NoMatchingDocument silently caught
DoAbortPersist(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = AbtPersist
    \* migration_util.cpp:308-309: updateMigrationCoordinatorDoc
    /\ coordDocs' = [coordDocs EXCEPT ![mid] = Aborted]
    /\ cleanupPhase' = AbtDelLocal
    /\ UNCHANGED <<lifecycleVars, donorTasks, configCommitted, cleanupMid, durVars, faultVars, auxVars>>

\* Step: deleteRangeDeletionTaskLocally
\* range_deletion_util.cpp:702-715
\* Bug Family 1: uses getQueryFilterForRangeDeletionTask (no migrationId, line 707)
\* Uses majority write concern (line 350 in migration_coordinator.cpp)
DoAbortDeleteLocal(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = AbtDelLocal
    \* range_deletion_util.cpp:707: query = getQueryFilterForRangeDeletionTask(collUuid, range)
    \* Bug Family 1: no migrationId — matches ANY task for this range
    /\ IF donorTasks /= {}
       THEN \E t \in donorTasks :
                donorTasks' = donorTasks \ {t}
       ELSE UNCHANGED donorTasks
    /\ cleanupPhase' = AbtAdvTxn
    /\ UNCHANGED <<lifecycleVars, coordDocs, configCommitted, cleanupMid, durVars, faultVars, auxVars>>

\* Step: advanceTransactionOnRecipient (abort path)
\* migration_util.cpp:324-354
\* CORRECTLY handles ShardNotFound: try-catch at migration_coordinator.cpp:365-375
DoAbortAdvanceTxn(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = AbtAdvTxn
    \* migration_coordinator.cpp:365-375: try-catch ShardNotFound → continues
    \* Safe regardless of recipientExists
    /\ cleanupPhase' = AbtMarkRecip
    /\ UNCHANGED <<lifecycleVars, persistVars, cleanupMid, durVars, faultVars, auxVars>>

\* Step: markAsReadyRangeDeletionTaskOnRecipient
\* range_deletion_util.cpp:743-785
\* CORRECTLY uses migrationId in filter (line 750: getQueryFilterForRangeDeletionTaskOnRecipient)
\* CORRECTLY handles ShardNotFound (line 768-776)
DoAbortMarkRecipient(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = AbtMarkRecip
    \* range_deletion_util.cpp:750: uses getQueryFilterForRangeDeletionTaskOnRecipient
    \* Includes migrationId — correct filter
    \* range_deletion_util.cpp:768: ShardNotFound caught — safe
    /\ cleanupPhase' = AbtForget
    /\ UNCHANGED <<lifecycleVars, persistVars, cleanupMid, durVars, faultVars, auxVars>>

\* Step: forgetMigration (abort path)
\* migration_coordinator.cpp:389-401
\* Bug Family 5: uses WriteConcernOptions{1} (w:1, line 400)
DoAbortForget(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = AbtForget
    \* migration_coordinator.cpp:398-400: w:1 write concern
    /\ forgetPending' = [forgetPending EXCEPT ![mid] = coordDocs[mid]]
    /\ coordDocs' = [coordDocs EXCEPT ![mid] = Nil]
    /\ cleanupPhase' = CleanupDone
    /\ UNCHANGED <<lifecycleVars, donorTasks, configCommitted, cleanupMid, orphanDelta, faultVars, auxVars>>

\* ==============================================================
\* Cleanup Completion
\* ==============================================================

CleanupComplete(mid) ==
    /\ cleanupMid = mid
    /\ cleanupPhase = CleanupDone
    /\ IF activeMigration = mid
       THEN /\ activeMigration' = Nil
            /\ migrationPhase' = Idle
       ELSE UNCHANGED lifecycleVars
    /\ cleanupPhase' = NoCleanup
    /\ cleanupMid' = Nil
    /\ completedMigrations' = completedMigrations \cup {mid}
    /\ UNCHANGED <<persistVars, durVars, faultVars>>

\* ==============================================================
\* Range Deleter (background thread)
\* Processes ready tasks by deleting orphaned data + task document
\* ==============================================================

RangeDeleterProcessTask ==
    /\ cleanupPhase = NoCleanup  \* Simplified: not during active cleanup
    /\ \E t \in donorTasks :
        /\ t.pending = FALSE     \* Task must be ready (not pending)
        /\ donorTasks' = donorTasks \ {t}
    /\ UNCHANGED <<lifecycleVars, coordDocs, configCommitted, cleanupVars, durVars, faultVars, auxVars>>

\* ==============================================================
\* Stepdown and Recovery
\* ==============================================================

\* -------------------------------------------------------
\* Stepdown
\* Donor primary steps down; volatile state lost, w:1 writes rolled back
\* -------------------------------------------------------
Stepdown ==
    \* Guard: something is happening (migration active, cleanup running, or forget pending)
    /\ \/ activeMigration /= Nil
       \/ cleanupPhase /= NoCleanup
       \/ \E m \in MigrationId : forgetPending[m] /= Nil
    \* Reset volatile state
    /\ activeMigration' = Nil
    /\ migrationPhase' = Idle
    /\ cleanupPhase' = NoCleanup
    /\ cleanupMid' = Nil
    \* Bug Family 5: restore w:1 forgotten coordinator docs
    \* migration_coordinator.cpp:400: WriteConcernOptions{1} — not majority-acked
    /\ coordDocs' = [m \in MigrationId |->
        IF forgetPending[m] /= Nil THEN forgetPending[m]
        ELSE coordDocs[m]]
    /\ forgetPending' = [m \in MigrationId |-> Nil]
    \* donorTasks, configCommitted: persistent with majority WC — survive stepdown
    /\ UNCHANGED <<donorTasks, configCommitted, orphanDelta, recipientExists, completedMigrations>>

\* -------------------------------------------------------
\* RecoverMigration(mid)
\* New primary recovers a migration with a durable decision
\* migration_util.cpp:356-414 (resumeMigrationCoordinationsOnStepUp)
\* -------------------------------------------------------
RecoverMigration(mid) ==
    /\ coordDocs[mid] \in {Committed, Aborted}
    /\ cleanupPhase = NoCleanup
    /\ activeMigration = Nil
    /\ migrationPhase = Idle
    /\ cleanupMid' = mid
    /\ IF coordDocs[mid] = Committed
       THEN cleanupPhase' = CmtPersist
       ELSE cleanupPhase' = AbtPersist
    /\ UNCHANGED <<lifecycleVars, persistVars, durVars, faultVars, auxVars>>

\* -------------------------------------------------------
\* RecoverFromLimbo(mid)
\* New primary finds coordinator doc with no decision (Bug Family 3)
\* Queries config server for authoritative outcome
\* -------------------------------------------------------
RecoverFromLimbo(mid) ==
    /\ coordDocs[mid] = NoDecision
    /\ cleanupPhase = NoCleanup
    /\ activeMigration = Nil
    /\ migrationPhase = Idle
    \* Query config server for the truth
    /\ IF mid \in configCommitted
       THEN \* Config committed — set decision and run commit cleanup
            /\ coordDocs' = [coordDocs EXCEPT ![mid] = Committed]
            /\ cleanupPhase' = CmtPersist
       ELSE \* Config did NOT commit — abort
            /\ coordDocs' = [coordDocs EXCEPT ![mid] = Aborted]
            /\ cleanupPhase' = AbtPersist
    /\ cleanupMid' = mid
    /\ UNCHANGED <<lifecycleVars, donorTasks, configCommitted, durVars, faultVars, auxVars>>

\* ==============================================================
\* Fault Injection Actions
\* ==============================================================

\* Bug Family 2: remove recipient shard
RemoveRecipientShard ==
    /\ recipientExists = TRUE
    /\ recipientExists' = FALSE
    /\ UNCHANGED <<lifecycleVars, persistVars, cleanupVars, durVars, auxVars>>

\* Restore recipient shard (for continued exploration)
RestoreRecipientShard ==
    /\ recipientExists = FALSE
    /\ recipientExists' = TRUE
    /\ UNCHANGED <<lifecycleVars, persistVars, cleanupVars, durVars, auxVars>>

\* w:1 forgetMigration write becomes majority-committed (durable)
ForgetBecomeDurable(mid) ==
    /\ forgetPending[mid] /= Nil
    /\ forgetPending' = [forgetPending EXCEPT ![mid] = Nil]
    /\ UNCHANGED <<lifecycleVars, persistVars, cleanupVars, orphanDelta, faultVars, auxVars>>

\* ==============================================================
\* Next and Spec
\* ==============================================================

Next ==
    \/ \E mid \in MigrationId :
        \* Lifecycle
        \/ StartMigration(mid)
        \/ AdvanceToConfigCommit(mid)
        \/ ConfigCommitSucceed(mid)
        \/ ConfigCommitFail(mid)
        \/ ConfigServerCommitAsync(mid)
        \/ AbortBeforeConfigCommit(mid)
        \* Commit cleanup sub-steps
        \/ DoCommitPersist(mid)
        \/ DoCommitAdvanceTxn(mid)
        \/ DoCommitRetrieveOrphans(mid)
        \/ DoCommitPersistOrphans(mid)
        \/ DoCommitDeleteRecipientTask(mid)
        \/ DoCommitGetDonorTask(mid)
        \/ DoCommitMarkReady(mid)
        \/ DoCommitForget(mid)
        \* Abort cleanup sub-steps
        \/ DoAbortPersist(mid)
        \/ DoAbortDeleteLocal(mid)
        \/ DoAbortAdvanceTxn(mid)
        \/ DoAbortMarkRecipient(mid)
        \/ DoAbortForget(mid)
        \* Completion and recovery
        \/ CleanupComplete(mid)
        \/ RecoverMigration(mid)
        \/ RecoverFromLimbo(mid)
        \/ ForgetBecomeDurable(mid)
    \* Background
    \/ RangeDeleterProcessTask
    \* Fault injection
    \/ Stepdown
    \/ RemoveRecipientShard
    \/ RestoreRecipientShard

Spec == Init /\ [][Next]_vars

\* ==============================================================
\* Invariants
\* ==============================================================

\* --- Bug Family 1: Task Identity ---

\* NoPrematureRangeDeletion: a task marked ready (pending=FALSE) must belong
\* to a migration that was committed on config server or fully completed.
\* Violated when cleanup marks the wrong migration's task as ready.
NoPrematureRangeDeletion ==
    \A t \in donorTasks :
        t.pending = FALSE =>
            \/ t.id \in configCommitted
            \/ t.id \in completedMigrations

\* ActiveMigrationHasTask: if a migration has a coordinator doc and is not
\* being cleaned up, its range deletion task must still exist.
\* Violated when abort cleanup deletes the wrong migration's task.
ActiveMigrationHasTask ==
    \A mid \in MigrationId :
        /\ coordDocs[mid] /= Nil
        /\ mid \notin completedMigrations
        /\ cleanupMid /= mid
        => \E t \in donorTasks : t.id = mid

\* --- Bug Family 2: Missing ShardNotFound Handling ---

\* CommitPathHandlesRecipientRemoval: the commit cleanup path should never
\* be stuck at a step requiring the recipient when recipient doesn't exist.
\* The abort path handles this (try-catch); the commit path does NOT.
CommitPathHandlesRecipientRemoval ==
    ~recipientExists =>
        cleanupPhase \notin {CmtAdvTxn, CmtGetOrph, CmtDelRecip}

\* --- Bug Family 3: Limbo Coordinator Doc ---

\* NoLimboCoordinatorDoc: a coordinator doc with NoDecision must only exist
\* while a migration is actively in progress for that migration.
\* Violated when ConfigCommitFail leaves a doc with no decision and no active migration.
NoLimboCoordinatorDoc ==
    \A mid \in MigrationId :
        coordDocs[mid] = NoDecision =>
            /\ activeMigration = mid
            /\ migrationPhase \in {Prepared, CommittingOnConfig}

\* --- Bug Family 5: Non-Idempotent Recovery ---

\* OrphanCountBounded: orphan delta should not exceed the number of committed
\* migrations. Violated when non-idempotent $inc doubles on recovery replay.
OrphanCountBounded ==
    orphanDelta <= Cardinality(configCommitted)

\* --- Structural Invariants ---

\* Cleanup phase and cleanupMid must be consistent
CleanupConsistency ==
    /\ (cleanupPhase = NoCleanup) <=> (cleanupMid = Nil)

\* ForgetPending consistency: if forgetPending is set, coordDoc must be Nil
ForgetPendingConsistency ==
    \A mid \in MigrationId :
        forgetPending[mid] /= Nil => coordDocs[mid] = Nil

\* CoordDoc values are valid
CoordDocValidity ==
    \A mid \in MigrationId :
        coordDocs[mid] \in {Nil, NoDecision, Committed, Aborted}

\* TypeOK
TypeOK ==
    /\ activeMigration \in MigrationId \cup {Nil}
    /\ migrationPhase \in {Idle, Prepared, CommittingOnConfig, Cleaning}
    /\ cleanupPhase \in {NoCleanup, CleanupDone,
        CmtPersist, CmtAdvTxn, CmtGetOrph, CmtPersOrph,
        CmtDelRecip, CmtGetTask, CmtMarkReady, CmtForget,
        AbtPersist, AbtDelLocal, AbtAdvTxn, AbtMarkRecip, AbtForget}
    /\ cleanupMid \in MigrationId \cup {Nil}
    /\ recipientExists \in BOOLEAN
    /\ orphanDelta \in Nat
    /\ configCommitted \subseteq MigrationId
    /\ completedMigrations \subseteq MigrationId

====
