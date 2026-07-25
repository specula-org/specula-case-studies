-------------------------------- MODULE base --------------------------------
(* MongoDB chunk migration commit and recovery protocol.
   Three-party protocol: Donor shard, Recipient shard, Config server.
   Modeled actions follow migration_coordinator.cpp, migration_source_manager.cpp,
   migration_destination_manager.cpp, migration_util.cpp.

   Bug families covered:
   - Family 1: Async recipient crit-sec release before decision persist
   - Family 2: Recovery kFail/kAbort guard asymmetry on recipient
   - Family 3: Range deletion task lifecycle inconsistency
*)

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Donor,      \* the donor shard node
    Recipient,  \* the recipient shard node
    Config      \* the config server

-----------------------------------------------------------------------------
(* TYPE CONSTANTS *)

\* Donor decision states (coordinatorDocDecision / decisionPersisted)
NONE       == "none"
COMMITTED  == "committed"
ABORTED    == "aborted"

\* Recipient FSM states  (migration_destination_manager.cpp state enum)
kInit          == "kInit"
kCloning       == "kCloning"
kEnteredCritSec == "kEnteredCritSec"
kDone          == "kDone"
kFail          == "kFail"
kAbort         == "kAbort"

\* Range deletion task states
RD_ABSENT  == "absent"
RD_PENDING == "pending"
RD_READY   == "ready"

\* Donor high-level phase (volatile — lost on crash)
D_INIT       == "d_init"
D_CLONING    == "d_cloning"
D_CRITSEC    == "d_critsec"        \* donor holds critical section
D_COMMITTED  == "d_committed"      \* commit path completed
D_ABORTED    == "d_aborted"

-----------------------------------------------------------------------------
(* STATE VARIABLES *)

(* --- Protocol variables --- *)

VARIABLE donorPhase
    \* Volatile donor phase (migration_source_manager.cpp state machine).
    \* Type: D_INIT | D_CLONING | D_CRITSEC | D_COMMITTED | D_ABORTED

VARIABLE recipientState
    \* Recipient FSM state (migration_destination_manager.cpp _state field).
    \* Type: kInit | kCloning | kEnteredCritSec | kDone | kFail | kAbort
    \* Family 2: recovery path may overwrite kAbort with kEnteredCritSec

VARIABLE configCommitted
    \* Whether config server has recorded the chunk ownership transfer.
    \* Type: BOOLEAN
    \* Corresponds to commitChunkMigration RPC result.

(* --- Coordinator document (durable on donor) --- *)

VARIABLE coordinatorDocPresent
    \* Whether MigrationCoordinatorDocument exists in donor's local store.
    \* Type: BOOLEAN
    \* Family 1, 3: recovery branches on this

VARIABLE coordinatorDocDecision
    \* Decision field in coordinator doc. NONE until persisted.
    \* coordinator.cpp:240 persistCommitDecision / coordinator.cpp:334 persistAbortDecision
    \* Type: NONE | COMMITTED | ABORTED
    \* Family 1: crash between async launch (line 205) and persist (line 240)

(* --- Crit-sec release ordering (Family 1) --- *)

VARIABLE critSecReleaseRPCSent
    \* True once launchReleaseRecipientCriticalSection fires the async RPC.
    \* coordinator.cpp:204-206: launched BEFORE persistCommitDecision.
    \* Type: BOOLEAN

VARIABLE recipientCritSecReleased
    \* True once recipient has released its critical section.
    \* Type: BOOLEAN

(* --- Donor crash/recovery (Family 1, 3) --- *)

VARIABLE donorCrashed
    \* True while donor is in crashed state (volatile state gone).
    \* Type: BOOLEAN

(* --- Recovery abort-guard (Family 2) --- *)

VARIABLE recipientAbortSignaled
    \* True if a concurrent abort() call set recipient state to kAbort
    \* BEFORE the recovery thread reached the skipToCritSecTaken branch.
    \* destination_manager.cpp:1897-1902 (normal) vs 1927-1930 (recovery, missing guard).
    \* Type: BOOLEAN

VARIABLE recipientRecoveryDocPresent
    \* Whether MigrationRecipientRecoveryDocument exists.
    \* Type: BOOLEAN

VARIABLE recipientInRecovery
    \* Whether recipient is currently executing the recovery path.
    \* Type: BOOLEAN

(* --- Range deletion tasks (Family 3) --- *)

VARIABLE donorRDTask
    \* Range deletion task state on donor.
    \* migration_coordinator.cpp:285-294, 320-321, 347-350
    \* Type: RD_ABSENT | RD_PENDING | RD_READY

VARIABLE recipientRDTask
    \* Range deletion task state on recipient.
    \* destination_manager.cpp:1537-1561 (written local WC); coordinator.cpp:278-282, 382-386
    \* Type: RD_ABSENT | RD_PENDING | RD_READY

vars == <<donorPhase, recipientState, configCommitted,
          coordinatorDocPresent, coordinatorDocDecision,
          critSecReleaseRPCSent, recipientCritSecReleased,
          donorCrashed,
          recipientAbortSignaled, recipientRecoveryDocPresent, recipientInRecovery,
          donorRDTask, recipientRDTask>>

donorVars    == <<donorPhase, donorCrashed>>
coordDocVars == <<coordinatorDocPresent, coordinatorDocDecision>>
critSecVars  == <<critSecReleaseRPCSent, recipientCritSecReleased>>
recipientVars == <<recipientState, recipientAbortSignaled,
                   recipientRecoveryDocPresent, recipientInRecovery>>
rdVars       == <<donorRDTask, recipientRDTask>>

-----------------------------------------------------------------------------
(* INITIAL STATE *)

Init ==
    /\ donorPhase                 = D_INIT
    /\ recipientState             = kInit
    /\ configCommitted            = FALSE
    /\ coordinatorDocPresent      = FALSE
    /\ coordinatorDocDecision     = NONE
    /\ critSecReleaseRPCSent      = FALSE
    /\ recipientCritSecReleased   = FALSE
    /\ donorCrashed               = FALSE
    /\ recipientAbortSignaled     = FALSE
    /\ recipientRecoveryDocPresent = FALSE
    /\ recipientInRecovery        = FALSE
    /\ donorRDTask                = RD_ABSENT
    /\ recipientRDTask            = RD_ABSENT

-----------------------------------------------------------------------------
(* DONOR ACTIONS *)

(* migration_source_manager.cpp:472-500
   StartClone registers _cloneDriver on CSR (line 472-487) THEN calls
   coordinator->startMigration (line 500), which persists coordinator doc +
   donor range deletion task.
   Family 3: window between _cloneDriver registration and coordinator doc persist.
   We model the net result: donor enters cloning, coordinator doc written, donor RD task created. *)
StartClone ==
    /\ ~donorCrashed
    /\ donorPhase = D_INIT
    /\ donorPhase'                = D_CLONING
    /\ coordinatorDocPresent'     = TRUE           \* startMigration persists doc
    /\ coordinatorDocDecision'    = NONE
    /\ donorRDTask'               = RD_PENDING     \* startMigration writes donor RD task
    /\ UNCHANGED <<recipientVars, configCommitted, critSecVars,
                   donorCrashed, recipientRDTask>>

(* Recipient receives clone start signal and begins cloning phase.
   destination_manager.cpp:1537-1561: writes recipient RD task with LOCAL WC,
   then waits for majority separately. *)
RecipientBeginClone ==
    /\ ~donorCrashed
    /\ donorPhase = D_CLONING
    /\ recipientState = kInit
    /\ recipientState'            = kCloning
    /\ recipientRDTask'           = RD_PENDING     \* local WC write (destination_manager.cpp:1537)
    /\ recipientRecoveryDocPresent' = TRUE          \* recovery doc written
    /\ UNCHANGED <<donorVars, coordDocVars, configCommitted, critSecVars,
                   recipientAbortSignaled, recipientInRecovery, donorRDTask>>

(* Donor enters critical section (migration_source_manager.cpp critical section acquisition).
   Prerequisites: cloning phase complete and recipient in critical section. *)
DonorEnterCriticalSection ==
    /\ ~donorCrashed
    /\ donorPhase = D_CLONING
    /\ recipientState = kEnteredCritSec
    /\ donorPhase'                = D_CRITSEC
    /\ UNCHANGED <<recipientVars, coordDocVars, configCommitted,
                   critSecVars, donorCrashed, rdVars>>

(* Recipient enters critical section (destination_manager.cpp:1896-1903, normal path).
   Normal path DOES check _state != kFail && _state != kAbort (line 1899).
   Family 2: this guard is ABSENT in recovery path (line 1927-1930). *)
RecipientEnterCriticalSection ==
    /\ ~donorCrashed
    /\ recipientState = kCloning
    /\ ~recipientAbortSignaled          \* destination_manager.cpp:1899 guard
    /\ ~recipientInRecovery
    /\ recipientState'            = kEnteredCritSec
    /\ UNCHANGED <<donorVars, coordDocVars, configCommitted, critSecVars,
                   recipientAbortSignaled, recipientRecoveryDocPresent,
                   recipientInRecovery, rdVars>>

(* Config server commit: migration_source_manager.cpp commitChunkMetadataOnConfig.
   Called with RetryPolicy::kIdempotent (coordinator.cpp:252 comment context).
   We model as single atomic action (modeling brief §3.1: idempotent, no need to split).
   Guard: coordinatorDocDecision = NONE enforces mutual exclusivity with the abort path —
   once abort is decided (ABORTED), the config server commit cannot happen. *)
CommitChunkMigrationOnConfigServer ==
    /\ ~donorCrashed
    /\ donorPhase = D_CRITSEC
    /\ recipientState = kEnteredCritSec
    /\ ~configCommitted
    /\ coordinatorDocDecision = NONE     \* abort and commit paths are mutually exclusive
    /\ configCommitted'           = TRUE
    /\ UNCHANGED <<donorVars, coordDocVars, critSecVars,
                   recipientVars, rdVars>>

(* --- FAMILY 1 SPLIT: async crit-sec release BEFORE decision persist ---
   coordinator.cpp:204-206: launchReleaseRecipientCriticalSection fires async RPC.
   coordinator.cpp:240: persistCommitDecision writes decision to coordinator doc.
   BUG: RPC send precedes durable write. Crash in this window = crit sec released, no decision. *)

(* Step 1: Donor fires async crit-sec release RPC (coordinator.cpp:204-206).
   This happens BEFORE the decision is persisted to the coordinator doc. *)
LaunchReleaseRecipientCritSec ==
    /\ ~donorCrashed
    /\ donorPhase = D_CRITSEC
    /\ configCommitted = TRUE
    /\ ~critSecReleaseRPCSent
    /\ critSecReleaseRPCSent'     = TRUE
    /\ UNCHANGED <<donorVars, coordDocVars, configCommitted,
                   recipientCritSecReleased, recipientVars, rdVars>>

(* Recipient processes the async RPC and releases its critical section. *)
RecipientReleaseCritSec ==
    /\ critSecReleaseRPCSent = TRUE
    /\ ~recipientCritSecReleased
    /\ recipientCritSecReleased'  = TRUE
    /\ UNCHANGED <<donorVars, coordDocVars, configCommitted,
                   critSecReleaseRPCSent, recipientVars, rdVars>>

(* Step 2: Donor persists commit decision to coordinator doc (coordinator.cpp:240).
   Uses majority write concern. This is the durable decision write. *)
PersistCommitDecision ==
    /\ ~donorCrashed
    /\ donorPhase = D_CRITSEC
    /\ configCommitted = TRUE
    /\ critSecReleaseRPCSent = TRUE     \* async launch already fired (coordinator.cpp:204-206 before 240)
    /\ coordinatorDocDecision = NONE
    /\ coordinatorDocDecision'    = COMMITTED   \* coordinator.cpp:240
    /\ UNCHANGED <<donorVars, coordinatorDocPresent, configCommitted,
                   critSecVars, recipientVars, rdVars>>

(* Donor deletes recipient range deletion task on commit path.
   coordinator.cpp:278-282 (no ShardNotFound guard — Family 5, code-review only). *)
DeleteRecipientRangeDeletionTask ==
    /\ ~donorCrashed
    /\ coordinatorDocDecision = COMMITTED
    /\ recipientRDTask /= RD_ABSENT
    /\ recipientRDTask'           = RD_ABSENT   \* coordinator.cpp:278-282
    /\ UNCHANGED <<donorVars, coordDocVars, configCommitted,
                   critSecVars, recipientVars, donorRDTask>>

(* Donor marks its own range deletion task as ready on commit path.
   coordinator.cpp:318-321: markAsReadyRangeDeletionTaskLocally *)
MarkDonorRangeDeletionTaskReady ==
    /\ ~donorCrashed
    /\ coordinatorDocDecision = COMMITTED
    /\ recipientRDTask = RD_ABSENT              \* must delete recipient task first
    /\ donorRDTask = RD_PENDING
    /\ donorRDTask'               = RD_READY    \* coordinator.cpp:320-321
    /\ UNCHANGED <<donorVars, coordDocVars, configCommitted,
                   critSecVars, recipientVars, recipientRDTask>>

(* Donor persists ABORT decision (coordinator.cpp:334).
   NOTE: abort path correctly persists decision BEFORE waiting for crit-sec release (line 334 before 338).
   This is the CORRECT ordering — contrast with commit path (Family 1 asymmetry).
   Guard: ~configCommitted enforces that commit/abort paths are mutually exclusive — once the
   config server has committed the chunk transfer, only the commit path can run. *)
PersistAbortDecision ==
    /\ ~donorCrashed
    /\ donorPhase = D_CRITSEC
    /\ coordinatorDocDecision = NONE
    /\ ~configCommitted                          \* commit/abort paths are mutually exclusive
    /\ coordinatorDocDecision'    = ABORTED     \* coordinator.cpp:334
    /\ UNCHANGED <<donorVars, coordinatorDocPresent, configCommitted,
                   critSecVars, recipientVars, rdVars>>

(* Abort path: delete donor range deletion task (coordinator.cpp:347-350, majority WC). *)
DeleteDonorRangeDeletionTaskOnAbort ==
    /\ ~donorCrashed
    /\ coordinatorDocDecision = ABORTED
    /\ donorRDTask /= RD_ABSENT
    /\ donorRDTask'               = RD_ABSENT   \* coordinator.cpp:347-350
    /\ UNCHANGED <<donorVars, coordDocVars, configCommitted,
                   critSecVars, recipientVars, recipientRDTask>>

(* Abort path: mark recipient range deletion task ready (coordinator.cpp:382-386).
   NOTE: called OUTSIDE the ShardNotFound try/catch (Family 5, code-review). *)
MarkRecipientRangeDeletionTaskReadyOnAbort ==
    /\ ~donorCrashed
    /\ coordinatorDocDecision = ABORTED
    /\ donorRDTask = RD_ABSENT                  \* donor task deleted first
    /\ recipientRDTask = RD_PENDING
    /\ recipientRDTask'           = RD_READY    \* coordinator.cpp:382-386
    /\ UNCHANGED <<donorVars, coordDocVars, configCommitted,
                   critSecVars, recipientVars, donorRDTask>>

(* forgetMigration: delete coordinator doc (coordinator.cpp:389-401).
   Uses w:1 WriteConcern (line 400 WriteConcernOptions{1,...}).
   Family 5: all other coordinator ops use majority. Modeled but no invariant added
   (modeling brief §3.2: idempotent re-execution is intended design). *)
ForgetMigration ==
    /\ ~donorCrashed
    /\ coordinatorDocPresent = TRUE
    /\ coordinatorDocDecision /= NONE           \* decision must be set before cleanup
    /\ \/ (coordinatorDocDecision = COMMITTED /\ donorRDTask = RD_READY /\ recipientRDTask = RD_ABSENT)
       \/ (coordinatorDocDecision = ABORTED /\ donorRDTask = RD_ABSENT /\ recipientRDTask = RD_READY)
    /\ coordinatorDocPresent'     = FALSE       \* coordinator.cpp:398-400
    /\ donorPhase'                = IF coordinatorDocDecision = COMMITTED THEN D_COMMITTED ELSE D_ABORTED
    /\ UNCHANGED <<coordinatorDocDecision, configCommitted,
                   critSecVars, recipientVars, donorCrashed, rdVars>>

-----------------------------------------------------------------------------
(* CRASH AND RECOVERY ACTIONS — Family 1, Family 3 *)

(* Donor crash: resets all volatile state. Coordinator doc (durable) survives.
   critSecReleaseRPCSent is volatile — the async future is lost. *)
CrashDonor ==
    /\ ~donorCrashed
    /\ donorPhase /= D_INIT             \* migration must have started
    /\ donorCrashed'                    = TRUE
    /\ donorPhase'                      = D_INIT    \* volatile phase reset
    /\ UNCHANGED <<coordDocVars, configCommitted, critSecVars,
                   recipientVars, rdVars>>

(* Donor recovery: new primary reads coordinator doc and re-drives migration.
   migration_util.cpp:543-561 drainMigrationsPendingRecovery -> completeMigration.
   KEY: coordinator.cpp:183-196 — if no decision in coordinator doc, returns early (no-op).
   Family 1: if crash happened between LaunchReleaseRecipientCritSec and PersistCommitDecision,
   the new primary finds coordinatorDocDecision == NONE and calls completeMigration which
   hits the no-decision early-return path (coordinator.cpp:186-196), leaving migration in
   an inconsistent state (recipient crit sec released, no committed decision on donor). *)
RecoverDonor ==
    /\ donorCrashed = TRUE
    /\ coordinatorDocPresent = TRUE
    /\ donorCrashed'                    = FALSE
    /\ donorPhase'                      = D_CRITSEC     \* recovery re-enters the decision phase
    /\ UNCHANGED <<coordDocVars, configCommitted, critSecVars,
                   recipientVars, rdVars>>

(* Recovery: donor finds coordinator doc with no decision (Family 1 bug trigger).
   coordinator.cpp:186-196: completeMigration with no decision → early return without
   finalizing donor or recipient state. *)
RecoverDonorNoDecision ==
    /\ donorCrashed = TRUE
    /\ coordinatorDocPresent = TRUE
    /\ coordinatorDocDecision = NONE    \* no decision persisted before crash
    /\ donorCrashed'                    = FALSE
    /\ donorPhase'                      = D_ABORTED     \* effectively abandons migration
    \* NOTE: coordinator doc is NOT deleted here (no-decision path returns early)
    /\ UNCHANGED <<coordDocVars, configCommitted, critSecVars,
                   recipientVars, rdVars>>

-----------------------------------------------------------------------------
(* RECIPIENT RECOVERY ACTIONS — Family 2 *)

(* Concurrent abort signal arrives while recipient is in recovery.
   destination_manager.cpp: abort() sets _state = kAbort.
   This models a concurrent abort() call arriving before the recovery thread
   sets skipToCritSecTaken state. *)
ConcurrentAbortSignalDuringRecovery ==
    /\ recipientInRecovery = TRUE
    /\ ~recipientAbortSignaled
    /\ recipientAbortSignaled'    = TRUE
    /\ recipientState'            = kAbort      \* abort() call sets _state = kAbort
    /\ UNCHANGED <<donorVars, coordDocVars, configCommitted, critSecVars,
                   recipientRecoveryDocPresent, recipientInRecovery, rdVars>>

(* Start recipient recovery path on step-up.
   migration_util.cpp:495-541 resumeMigrationRecipientsOnStepUp.
   Triggers when recovery doc is present and we're on new primary. *)
StartRecipientRecovery ==
    /\ recipientRecoveryDocPresent = TRUE
    /\ ~recipientInRecovery
    /\ recipientInRecovery'       = TRUE
    /\ UNCHANGED <<donorVars, coordDocVars, configCommitted, critSecVars,
                   recipientState, recipientAbortSignaled,
                   recipientRecoveryDocPresent, rdVars>>

(* Recovery path sets kEnteredCritSec WITHOUT checking kFail/kAbort.
   destination_manager.cpp:1927-1930: _state = kEnteredCritSec unconditionally.
   BUG: Normal path at 1899 checks _state != kFail && _state != kAbort.
   Recovery path OMITS this guard, silently overwriting kAbort → kEnteredCritSec.
   Family 2: if concurrentAbortSignaled is TRUE, this causes incorrect state. *)
RecoverySetsCritSecState ==
    /\ recipientInRecovery = TRUE
    /\ recipientState \in {kInit, kCloning, kAbort, kFail}  \* recovery can reach this from any state
    (* destination_manager.cpp:1929: unconditional assignment — NO kFail/kAbort guard *)
    /\ recipientState'            = kEnteredCritSec     \* BUG: overwrites kAbort if present
    /\ recipientInRecovery'       = FALSE
    /\ UNCHANGED <<donorVars, coordDocVars, configCommitted, critSecVars,
                   recipientAbortSignaled, recipientRecoveryDocPresent, rdVars>>

(* For completeness: a correct recovery path would be:
   if ~(recipientState \in {kFail, kAbort}) then set kEnteredCritSec
   This action models what SHOULD happen vs RecoverySetsCritSecState above. *)
RecoverySetsCritSecStateCorrect ==
    /\ recipientInRecovery = TRUE
    /\ ~recipientAbortSignaled                  \* correct guard (as in normal path at line 1899)
    /\ recipientState \notin {kFail, kAbort}
    /\ recipientState'            = kEnteredCritSec
    /\ recipientInRecovery'       = FALSE
    /\ UNCHANGED <<donorVars, coordDocVars, configCommitted, critSecVars,
                   recipientAbortSignaled, recipientRecoveryDocPresent, rdVars>>

-----------------------------------------------------------------------------
(* NEXT STATE *)

Next ==
    \* Donor normal flow
    \/ StartClone
    \/ RecipientBeginClone
    \/ DonorEnterCriticalSection
    \/ RecipientEnterCriticalSection
    \/ CommitChunkMigrationOnConfigServer
    \* Family 1: split commit sequence
    \/ LaunchReleaseRecipientCritSec
    \/ RecipientReleaseCritSec
    \/ PersistCommitDecision
    \* Commit cleanup
    \/ DeleteRecipientRangeDeletionTask
    \/ MarkDonorRangeDeletionTaskReady
    \/ ForgetMigration
    \* Abort path
    \/ PersistAbortDecision
    \/ DeleteDonorRangeDeletionTaskOnAbort
    \/ MarkRecipientRangeDeletionTaskReadyOnAbort
    \* Family 1: crash/recovery
    \/ CrashDonor
    \/ RecoverDonor
    \/ RecoverDonorNoDecision
    \* Family 2: recipient recovery
    \/ StartRecipientRecovery
    \/ ConcurrentAbortSignalDuringRecovery
    \/ RecoverySetsCritSecState

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* INVARIANTS *)

(* --- Structural invariants --- *)

\* Coordinator doc decision is only set when doc is present, or migration is in a terminal
\* phase (ForgetMigration deletes the doc but keeps coordinatorDocDecision set so that
\* DonorRDTaskRequiresCoordDoc can still verify range-deletion task consistency).
\* A crash after ForgetMigration is valid: donorPhase resets to D_INIT but doc is already gone.
CoordDocConsistency ==
    (coordinatorDocDecision /= NONE /\ coordinatorDocPresent = FALSE /\ ~donorCrashed) =>
        donorPhase \in {D_COMMITTED, D_ABORTED}

\* Config commit only after donor in critical section
ConfigCommitOrdering ==
    configCommitted => donorPhase \in {D_CRITSEC, D_COMMITTED, D_ABORTED} \/ donorCrashed

\* Donor range deletion task pending/ready only after coordinator doc created
DonorRDTaskRequiresCoordDoc ==
    donorRDTask /= RD_ABSENT => coordinatorDocPresent = TRUE \/ coordinatorDocDecision /= NONE

(* --- Family 1: Commit decision durability before crit-sec release ---
   modeling-brief.md §5: CommitDecisionDurabilityBeforeRelease
   If recipient crit-sec was released AND donor crashed AND recovery found no decision,
   the migration is in an irrecoverable inconsistent state. *)
CommitDecisionDurabilityBeforeRelease ==
    \* When donor has crashed AND crit-sec was released but no decision persisted,
    \* the recovery must not be able to produce a committed outcome without a decision.
    ~(recipientCritSecReleased = TRUE
      /\ donorCrashed = FALSE
      /\ donorPhase = D_ABORTED
      /\ coordinatorDocDecision = NONE
      /\ configCommitted = TRUE)

(* --- Family 3: Range deletion consistency after decision ---
   modeling-brief.md §5: RangeDeletionConsistency
   After commit decision: donor task ready, recipient task absent.
   After abort decision: donor task absent, recipient task ready. *)
RangeDeletionConsistency ==
    \/ coordinatorDocDecision = NONE
    \/ (coordinatorDocDecision = COMMITTED =>
           (donorRDTask /= RD_READY \/ recipientRDTask = RD_ABSENT))
    \/ (coordinatorDocDecision = ABORTED =>
           (donorRDTask /= RD_ABSENT \/ recipientRDTask = RD_PENDING))

\* Stronger form: once final state reached (coordinator doc gone), tasks must be consistent
RangeDeletionConsistencyFinal ==
    coordinatorDocPresent = FALSE =>
        \/ (donorPhase = D_COMMITTED => donorRDTask = RD_READY /\ recipientRDTask = RD_ABSENT)
        \/ (donorPhase = D_ABORTED => donorRDTask = RD_ABSENT /\ recipientRDTask = RD_READY)
        \/ donorPhase \in {D_INIT, D_CLONING, D_CRITSEC}

(* --- Family 2: Recovery honors abort signal ---
   modeling-brief.md §5: RecoveryHonorsAbort
   If abort was signaled before recovery completed, recipient state must not be kEnteredCritSec. *)
RecoveryHonorsAbort ==
    ~(recipientAbortSignaled = TRUE
      /\ recipientInRecovery = FALSE
      /\ recipientState = kEnteredCritSec)

(* --- Family 3: No orphan after commit ---
   modeling-brief.md §5: NoOrphanAfterCommit
   If config server committed the migration, recipient RD task must not be ready-to-delete
   (which would delete documents that now legitimately belong to the recipient). *)
NoOrphanAfterCommit ==
    configCommitted = TRUE =>
        recipientRDTask /= RD_READY

(* --- Liveness property (temporal) ---
   modeling-brief.md §5: CoordinatorDocEventuallyGone
   After migration decision, coordinator doc must eventually be deleted. *)
CoordinatorDocEventuallyGone ==
    [](coordinatorDocDecision /= NONE => <>(coordinatorDocPresent = FALSE))

=============================================================================
