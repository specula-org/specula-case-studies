---- MODULE base ----
\* MongoDB MoveRange: Non-atomic commit protocol with stepdown/recovery and range deletion
\*
\* This spec models the chunk migration COMMIT PROTOCOL with:
\* - Non-atomic commit/abort sub-steps (6 steps each, interruptible by stepdown)
\* - Coordinator recovery that derives decisions from config server state
\* - Range deletion task lifecycle as persistent locks
\* - w:1 vs majority write concern for forgetMigration
\* - Commit/abort path asymmetry in error handling
\*
\* NOT modeled (covered by existing MoveRange.tla):
\* - Read routing, timestamps, placement versions, query execution
\*
\* Differences from existing MoveRange.tla:
\* - Splits MigrateCommitOnConfigShard into 6 non-atomic sub-steps
\* - Adds Stepdown/Recovery actions with persistent vs volatile state
\* - Models range deletion task states (pending/ready) as persistent locks
\* - Models w:1 forgetMigration rollback on stepdown
\* - Separates commit/abort paths to expose asymmetric error handling

EXTENDS Integers, FiniteSets, Sequences, TLC

CONSTANTS
    Shard,      \* Set of shards (e.g., {"s1", "s2"})
    Key,        \* Set of keys/ranges (e.g., {"k1"})
    Nil         \* Null constant

ASSUME Cardinality(Shard) > 1
ASSUME Cardinality(Key) > 0

\*---------------------------------------------------------------------------
\* Variables
\*---------------------------------------------------------------------------
VARIABLES
    \* Per-key migration tracking (volatile: lost on stepdown of donor)
    migState,        \* [Key -> state string]
    migDonor,        \* [Key -> Shard \cup {Nil}]
    migRecipient,    \* [Key -> Shard \cup {Nil}]

    \* Per-shard persistent state (survives stepdown)
    \* Coordinator document: config.migrationCoordinators (one per shard)
    \* migration_coordinator.cpp:91-113
    coordDoc,        \* [Shard -> [exists: BOOL, key: Key|Nil, recipient: Shard|Nil,
                     \*            decision: "none"|"commit"|"abort",
                     \*            forgetPending: BOOL]]

    \* Range deletion tasks: config.rangeDeletions (per shard per key)
    \* range_deleter_service.h:155 — acts as persistent lock
    rangeDel,        \* [Shard -> [Key -> "none"|"pending"|"ready"]]

    \* Config server (authoritative ownership truth)
    configOwner,     \* [Key -> Shard]

    \* Physical data presence on each shard
    shardData,       \* [Shard -> SUBSET Key]

    \* Node state
    isPrimary,       \* [Shard -> BOOL]

    \* Critical sections (recipient is persistent via recovery doc;
    \* donor is volatile, released on stepdown)
    \* migration_destination_manager.cpp:600-654 (recipient recovery)
    donorCritSec,    \* [Shard -> BOOL]
    recipientCritSec \* [Shard -> BOOL]

\*---------------------------------------------------------------------------
\* Variable groups (for UNCHANGED clauses)
\*---------------------------------------------------------------------------
migVars      == <<migState, migDonor, migRecipient>>
coordVars    == <<coordDoc>>
rangeDelVars == <<rangeDel>>
configVars   == <<configOwner>>
dataVars     == <<shardData>>
nodeVars     == <<isPrimary>>
critSecVars  == <<donorCritSec, recipientCritSec>>

vars == <<migState, migDonor, migRecipient, coordDoc, rangeDel,
          configOwner, shardData, isPrimary, donorCritSec, recipientCritSec>>

\*---------------------------------------------------------------------------
\* Helpers
\*---------------------------------------------------------------------------
EmptyCoordDoc == [exists |-> FALSE, key |-> Nil, recipient |-> Nil,
                  decision |-> "none", forgetPending |-> FALSE]

\* ActiveMigrationsRegistry: at most one migration per shard
\* migration_source_manager.cpp:187 (invariant check)
IsMigratingAsDonor(s) ==
    \E k \in Key : migDonor[k] = s /\ migState[k] # "idle"

IsMigratingAsRecipient(s) ==
    \E k \in Key : migRecipient[k] = s /\ migState[k] # "idle"

IsShardBusy(s) == IsMigratingAsDonor(s) \/ IsMigratingAsRecipient(s)

\* All commit sub-step states
CommitStates == {"commitPersistDecision", "commitReleaseCritSec",
                 "commitBumpTxn", "commitDeleteRecipRD",
                 "commitMarkDonorRD", "commitForget"}

\* All abort sub-step states
AbortStates == {"abortPersistDecision", "abortReleaseCritSec",
                "abortDeleteDonorRD", "abortBumpTxn",
                "abortMarkRecipRD", "abortForget"}

\* All non-idle states
ActiveStates == {"cloning", "donorPrepared", "allPrepared",
                 "needsRecovery"} \cup CommitStates \cup AbortStates

\*---------------------------------------------------------------------------
\* Init
\*---------------------------------------------------------------------------
Init ==
    /\ migState = [k \in Key |-> "idle"]
    /\ migDonor = [k \in Key |-> Nil]
    /\ migRecipient = [k \in Key |-> Nil]
    /\ coordDoc = [s \in Shard |-> EmptyCoordDoc]
    /\ rangeDel = [s \in Shard |-> [k \in Key |-> "none"]]
    \* Non-deterministic initial ownership
    /\ configOwner \in [Key -> Shard]
    \* Each shard has exactly its owned keys (no orphans initially)
    /\ shardData = [s \in Shard |-> {k \in Key : configOwner[k] = s}]
    /\ isPrimary = [s \in Shard |-> TRUE]
    /\ donorCritSec = [s \in Shard |-> FALSE]
    /\ recipientCritSec = [s \in Shard |-> FALSE]

\*===========================================================================
\* MIGRATION LIFECYCLE
\*===========================================================================

\* Start a new migration: clone data from donor to recipient
\* migration_coordinator.cpp:147-170 (startMigration)
\* migration_source_manager.cpp:187-380 (createMigrationSourceManager)
StartMigration(donor, recipient, key) ==
    /\ donor # recipient
    /\ isPrimary[donor]
    /\ migState[key] = "idle"
    /\ configOwner[key] = donor                  \* donor must own the key
    /\ key \notin shardData[recipient]           \* no orphans on recipient
    \* Range deletion task acts as persistent lock (Bug Family 2)
    \* range_deleter_service.h:155-156 — overlapping deletion blocks migration
    /\ rangeDel[donor][key] = "none"
    /\ rangeDel[recipient][key] = "none"
    \* ActiveMigrationsRegistry: one migration per shard
    /\ ~IsShardBusy(donor)
    /\ ~IsShardBusy(recipient)
    \* Create coordinator doc (migration_coordinator.cpp:150)
    /\ coordDoc' = [coordDoc EXCEPT ![donor] =
        [exists |-> TRUE, key |-> key, recipient |-> recipient,
         decision |-> "none", forgetPending |-> FALSE]]
    \* Create pending range deletion tasks on both donor and recipient
    \* Donor: migration_coordinator.cpp:158 (createAndPersistRangeDeletionTask)
    \* Recipient: created during _recvChunkStart on the destination manager
    /\ rangeDel' = [rangeDel EXCEPT ![donor][key] = "pending",
                                     ![recipient][key] = "pending"]
    \* Clone data to recipient (simplified: instant clone)
    /\ shardData' = [shardData EXCEPT ![recipient] = @ \cup {key}]
    \* Update migration tracking
    /\ migState' = [migState EXCEPT ![key] = "cloning"]
    /\ migDonor' = [migDonor EXCEPT ![key] = donor]
    /\ migRecipient' = [migRecipient EXCEPT ![key] = recipient]
    /\ UNCHANGED <<configOwner, isPrimary, donorCritSec, recipientCritSec>>

\* Donor enters critical section (blocks writes on donor)
\* migration_source_manager.cpp:559 (_critSec->enterCriticalSection)
\* In the code, the donor enters its critical section FIRST, then the
\* recipient enters after receiving the final batch of data.
DonorEnterCriticalSection(shard, key) ==
    /\ migState[key] = "cloning"
    /\ shard = migDonor[key]
    /\ isPrimary[shard]
    /\ migState' = [migState EXCEPT ![key] = "donorPrepared"]
    /\ donorCritSec' = [donorCritSec EXCEPT ![shard] = TRUE]
    /\ UNCHANGED <<migDonor, migRecipient, coordDoc, rangeDel, configOwner,
                   shardData, isPrimary, recipientCritSec>>

\* Recipient enters critical section (blocks reads/writes on recipient)
\* migration_destination_manager.cpp:1857 (entered recipient critical section)
RecipientEnterCriticalSection(shard, key) ==
    /\ migState[key] = "donorPrepared"
    /\ shard = migRecipient[key]
    /\ isPrimary[shard]
    /\ migState' = [migState EXCEPT ![key] = "allPrepared"]
    /\ recipientCritSec' = [recipientCritSec EXCEPT ![shard] = TRUE]
    /\ UNCHANGED <<migDonor, migRecipient, coordDoc, rangeDel, configOwner,
                   shardData, isPrimary, donorCritSec>>

\* Config server atomically commits the ownership change
\* migration_source_manager.cpp:665-671 (runCommand to config shard)
\* Donor also learns the result and releases donor critical section
\* migration_source_manager.cpp:778 (setMigrationDecision) + _cleanup(true)
CommitOnConfigServer(key) ==
    /\ migState[key] = "allPrepared"
    /\ isPrimary[migDonor[key]]
    \* Config server commits: ownership transfers
    /\ configOwner' = [configOwner EXCEPT ![key] = migRecipient[key]]
    \* Donor learns result and enters commit path
    /\ migState' = [migState EXCEPT ![key] = "commitPersistDecision"]
    \* Donor critical section released by _cleanup(true)
    \* migration_source_manager.cpp:794 -> _cleanup -> _critSec.reset()
    /\ donorCritSec' = [donorCritSec EXCEPT ![migDonor[key]] = FALSE]
    /\ UNCHANGED <<migDonor, migRecipient, coordDoc, rangeDel,
                   shardData, isPrimary, recipientCritSec>>

\*===========================================================================
\* COMMIT SUB-STEPS (migration_coordinator.cpp:231-324)
\* Each step can be interrupted by Stepdown. Recovery re-executes from start.
\*===========================================================================

\* Step 1: Persist commit decision in coordinator document
\* migration_util.cpp:282-302 (persistCommitDecision)
\* NOTE: Catches NoMatchingDocument and silently continues (line 291-295)
\* Bug Family 1: DA-5 — proceeds without durable decision
PersistCommitDecision(donor) ==
    \E key \in Key :
        /\ migState[key] = "commitPersistDecision"
        /\ migDonor[key] = donor
        /\ isPrimary[donor]
        /\ coordDoc[donor].exists     \* Doc must exist to update
        /\ coordDoc' = [coordDoc EXCEPT ![donor].decision = "commit"]
        /\ migState' = [migState EXCEPT ![key] = "commitReleaseCritSec"]
        /\ UNCHANGED <<migDonor, migRecipient, rangeDel, configOwner,
                       shardData, isPrimary, donorCritSec, recipientCritSec>>

\* Step 2: Release recipient critical section
\* migration_coordinator.cpp:242 (_waitForReleaseRecipientCriticalSectionFuture)
\* Async launch at line 205, waited here. Catches ShardNotFound.
CommitReleaseCritSec(donor) ==
    \E key \in Key :
        /\ migState[key] = "commitReleaseCritSec"
        /\ migDonor[key] = donor
        /\ isPrimary[donor]
        /\ recipientCritSec' = [recipientCritSec EXCEPT
            ![migRecipient[key]] = FALSE]
        /\ migState' = [migState EXCEPT ![key] = "commitBumpTxn"]
        /\ UNCHANGED <<migDonor, migRecipient, coordDoc, rangeDel, configOwner,
                       shardData, isPrimary, donorCritSec>>

\* Step 3: Advance transaction number on recipient
\* migration_coordinator.cpp:252-255 (advanceTransactionOnRecipient)
\* Bug Family 3: NOT in try-catch for ShardNotFound (unlike abort path line 361)
\* MC-3: If recipient removed, this retries forever
CommitBumpRecipientTxn(donor) ==
    \E key \in Key :
        /\ migState[key] = "commitBumpTxn"
        /\ migDonor[key] = donor
        /\ isPrimary[donor]
        /\ migState' = [migState EXCEPT ![key] = "commitDeleteRecipRD"]
        /\ UNCHANGED <<migDonor, migRecipient, coordDoc, rangeDel, configOwner,
                       shardData, isPrimary, donorCritSec, recipientCritSec>>

\* Step 4: Delete range deletion task on recipient
\* migration_coordinator.cpp:278-282 (deleteRangeDeletionTaskOnRecipient)
\* Uses migrationId filter (line 320-322): "resilient to delayed network retries:
\*   only relying on collection's UUID and range may lead to undesired
\*   updates/deletes on tasks created by future migrations."
\* Modeled by only deleting "pending" tasks (state set by this migration's
\* StartMigration). "ready" tasks belong to a different migration's donor
\* cleanup — migrationId mismatch means no-op in real system.
CommitDeleteRecipientRangeDel(donor) ==
    \E key \in Key :
        /\ migState[key] = "commitDeleteRecipRD"
        /\ migDonor[key] = donor
        /\ isPrimary[donor]
        /\ IF rangeDel[migRecipient[key]][key] = "pending"
           THEN rangeDel' = [rangeDel EXCEPT ![migRecipient[key]][key] = "none"]
           ELSE UNCHANGED rangeDel
        /\ migState' = [migState EXCEPT ![key] = "commitMarkDonorRD"]
        /\ UNCHANGED <<migDonor, migRecipient, coordDoc, configOwner,
                       shardData, isPrimary, donorCritSec, recipientCritSec>>

\* Step 5: Mark donor's range deletion task as ready
\* migration_coordinator.cpp:285-295 — checks if task exists first:
\*   if (!_donorRangeDeletionTask) { return Future<void>::makeReady(); }
\* migration_coordinator.cpp:309-321 (registerTask + markAsReadyRangeDeletionTaskLocally)
CommitMarkDonorRangeDelReady(donor) ==
    \E key \in Key :
        /\ migState[key] = "commitMarkDonorRD"
        /\ migDonor[key] = donor
        /\ isPrimary[donor]
        \* Real code checks if task exists (line 289): skip if already cleaned up
        /\ IF rangeDel[donor][key] # "none"
           THEN rangeDel' = [rangeDel EXCEPT ![donor][key] = "ready"]
           ELSE UNCHANGED rangeDel
        /\ migState' = [migState EXCEPT ![key] = "commitForget"]
        /\ UNCHANGED <<migDonor, migRecipient, coordDoc, configOwner,
                       shardData, isPrimary, donorCritSec, recipientCritSec>>

\* Step 6: Delete coordinator document with w:1 write concern
\* migration_coordinator.cpp:389-401 (forgetMigration)
\* Bug Family 1: w:1 means rollback possible on stepdown (MC-2)
\* WriteConcernOptions{1, ...} at line 400
CommitForgetMigration(donor) ==
    \E key \in Key :
        /\ migState[key] = "commitForget"
        /\ migDonor[key] = donor
        /\ isPrimary[donor]
        \* Delete coordDoc with w:1 — keep key/recipient/decision for rollback
        /\ coordDoc' = [coordDoc EXCEPT ![donor] =
            [coordDoc[donor] EXCEPT !.exists = FALSE, !.forgetPending = TRUE]]
        \* Migration complete
        /\ migState' = [migState EXCEPT ![key] = "idle"]
        /\ migDonor' = [migDonor EXCEPT ![key] = Nil]
        /\ migRecipient' = [migRecipient EXCEPT ![key] = Nil]
        /\ UNCHANGED <<rangeDel, configOwner, shardData, isPrimary,
                       donorCritSec, recipientCritSec>>

\*===========================================================================
\* ABORT PATH (migration_coordinator.cpp:326-387)
\* Note asymmetric error handling vs commit path (Bug Family 3)
\*===========================================================================

\* Decide to abort (can happen from cloning, donorPrepared, allPrepared)
\* Abort is decided before config server commit
DecideAbort(key) ==
    /\ migState[key] \in {"cloning", "donorPrepared", "allPrepared"}
    /\ isPrimary[migDonor[key]]
    /\ migState' = [migState EXCEPT ![key] = "abortPersistDecision"]
    \* Release donor critical section if held
    \* migration_source_manager.cpp:794 (_cleanup(false) -> _critSec.reset())
    /\ donorCritSec' = [donorCritSec EXCEPT ![migDonor[key]] = FALSE]
    /\ UNCHANGED <<migDonor, migRecipient, coordDoc, rangeDel, configOwner,
                   shardData, isPrimary, recipientCritSec>>

\* Abort Step 1: Persist abort decision
\* migration_util.cpp:304-322 (persistAbortDecision)
AbortPersistDecision(donor) ==
    \E key \in Key :
        /\ migState[key] = "abortPersistDecision"
        /\ migDonor[key] = donor
        /\ isPrimary[donor]
        /\ coordDoc[donor].exists
        /\ coordDoc' = [coordDoc EXCEPT ![donor].decision = "abort"]
        /\ migState' = [migState EXCEPT ![key] = "abortReleaseCritSec"]
        /\ UNCHANGED <<migDonor, migRecipient, rangeDel, configOwner,
                       shardData, isPrimary, donorCritSec, recipientCritSec>>

\* Abort Step 2: Release recipient critical section
\* migration_coordinator.cpp:338 (_waitForReleaseRecipientCriticalSection)
AbortReleaseCritSec(donor) ==
    \E key \in Key :
        /\ migState[key] = "abortReleaseCritSec"
        /\ migDonor[key] = donor
        /\ isPrimary[donor]
        /\ recipientCritSec' = [recipientCritSec EXCEPT
            ![migRecipient[key]] = FALSE]
        /\ migState' = [migState EXCEPT ![key] = "abortDeleteDonorRD"]
        /\ UNCHANGED <<migDonor, migRecipient, coordDoc, rangeDel, configOwner,
                       shardData, isPrimary, donorCritSec>>

\* Abort Step 3: Delete range deletion task on donor locally
\* migration_coordinator.cpp:347-350 (deleteRangeDeletionTaskLocally)
\* Bug Family 3: NOT in try-catch — failure prevents markAsReady on recipient (MC-9)
AbortDeleteDonorRangeDel(donor) ==
    \E key \in Key :
        /\ migState[key] = "abortDeleteDonorRD"
        /\ migDonor[key] = donor
        /\ isPrimary[donor]
        \* Idempotent: no-op if already deleted (recovery re-execution)
        /\ IF rangeDel[donor][key] # "none"
           THEN rangeDel' = [rangeDel EXCEPT ![donor][key] = "none"]
           ELSE UNCHANGED rangeDel
        /\ migState' = [migState EXCEPT ![key] = "abortBumpTxn"]
        /\ UNCHANGED <<migDonor, migRecipient, coordDoc, configOwner,
                       shardData, isPrimary, donorCritSec, recipientCritSec>>

\* Abort Step 4: Advance transaction on recipient
\* migration_coordinator.cpp:361-365 (advanceTransactionOnRecipient)
\* Bug Family 3: IS in try-catch for ShardNotFound (unlike commit path!)
AbortBumpRecipientTxn(donor) ==
    \E key \in Key :
        /\ migState[key] = "abortBumpTxn"
        /\ migDonor[key] = donor
        /\ isPrimary[donor]
        /\ migState' = [migState EXCEPT ![key] = "abortMarkRecipRD"]
        /\ UNCHANGED <<migDonor, migRecipient, coordDoc, rangeDel, configOwner,
                       shardData, isPrimary, donorCritSec, recipientCritSec>>

\* Abort Step 5: Mark range deletion task on recipient as ready
\* migration_coordinator.cpp:382-386 (markAsReadyRangeDeletionTaskOnRecipient)
AbortMarkRecipientRangeDelReady(donor) ==
    \E key \in Key :
        /\ migState[key] = "abortMarkRecipRD"
        /\ migDonor[key] = donor
        /\ isPrimary[donor]
        \* Idempotent: skip if task already cleaned up
        /\ IF rangeDel[migRecipient[key]][key] # "none"
           THEN rangeDel' = [rangeDel EXCEPT ![migRecipient[key]][key] = "ready"]
           ELSE UNCHANGED rangeDel
        /\ migState' = [migState EXCEPT ![key] = "abortForget"]
        /\ UNCHANGED <<migDonor, migRecipient, coordDoc, configOwner,
                       shardData, isPrimary, donorCritSec, recipientCritSec>>

\* Abort Step 6: Forget migration (same w:1 concern as commit)
\* migration_coordinator.cpp:389-401
AbortForgetMigration(donor) ==
    \E key \in Key :
        /\ migState[key] = "abortForget"
        /\ migDonor[key] = donor
        /\ isPrimary[donor]
        /\ coordDoc' = [coordDoc EXCEPT ![donor] =
            [coordDoc[donor] EXCEPT !.exists = FALSE, !.forgetPending = TRUE]]
        \* Remove cloned data from recipient (recipient range deletion completes)
        \* In reality this is async; modeled as part of cleanup for simplicity
        /\ migState' = [migState EXCEPT ![key] = "idle"]
        /\ migDonor' = [migDonor EXCEPT ![key] = Nil]
        /\ migRecipient' = [migRecipient EXCEPT ![key] = Nil]
        /\ UNCHANGED <<rangeDel, configOwner, shardData, isPrimary,
                       donorCritSec, recipientCritSec>>

\*===========================================================================
\* STEPDOWN / RECOVERY (Bug Family 1)
\*===========================================================================

\* Shard loses primary status. Volatile state lost, persistent state remains.
\* migration_util.cpp:356 (resumeMigrationCoordinationsOnStepUp — called on step-up)
Stepdown(shard) ==
    /\ isPrimary[shard]
    /\ isPrimary' = [isPrimary EXCEPT ![shard] = FALSE]
    \* Donor critical section is volatile — released on stepdown
    /\ donorCritSec' = [donorCritSec EXCEPT ![shard] = FALSE]
    \* Set migrations where this shard is donor to needsRecovery
    /\ migState' = [k \in Key |->
        IF migDonor[k] = shard /\ migState[k] \in ActiveStates
        THEN "needsRecovery"
        ELSE migState[k]]
    \* w:1 forgetMigration rollback (Bug Family 1, MC-2)
    \* migration_coordinator.cpp:400 — WriteConcernOptions{1,...}
    \* If forget wasn't majority-replicated, coordDoc reappears
    /\ IF coordDoc[shard].forgetPending
       THEN coordDoc' = [coordDoc EXCEPT ![shard] =
            [coordDoc[shard] EXCEPT !.exists = TRUE, !.forgetPending = FALSE]]
       ELSE UNCHANGED coordDoc
    \* Recipient critical section persists (recovery doc)
    \* migration_destination_manager.cpp:600-654
    /\ UNCHANGED <<migDonor, migRecipient, rangeDel, configOwner,
                   shardData, recipientCritSec>>

\* Shard becomes primary again
StepUp(shard) ==
    /\ ~isPrimary[shard]
    /\ isPrimary' = [isPrimary EXCEPT ![shard] = TRUE]
    /\ UNCHANGED <<migState, migDonor, migRecipient, coordDoc, rangeDel,
                   configOwner, shardData, donorCritSec, recipientCritSec>>

\* Recovery: read coordinator doc, derive decision, restart commit/abort
\* shard_filtering_metadata_refresh.cpp:495-635 (_recoverMigrationCoordinations)
\* migration_util.cpp:356-414 (resumeMigrationCoordinationsOnStepUp)
RecoverMigration(shard) ==
    /\ isPrimary[shard]
    /\ coordDoc[shard].exists
    /\ ~coordDoc[shard].forgetPending
    /\ LET key == coordDoc[shard].key
           recip == coordDoc[shard].recipient IN
        \* Only recover if key is available (idle or needsRecovery for this donor)
        /\ \/ migState[key] = "idle"
           \/ (migState[key] = "needsRecovery" /\ migDonor[key] = shard)
        \* Derive decision: from coordDoc if exists, else from config server
        \* shard_filtering_metadata_refresh.cpp:610-633
        /\ LET decision ==
                IF coordDoc[shard].decision # "none"
                THEN coordDoc[shard].decision
                \* Config server query: if key ownership changed, commit; else abort
                ELSE IF configOwner[key] # shard THEN "commit" ELSE "abort"
           IN
            \* Start from beginning of commit/abort path (re-execute all steps)
            \* This relies on idempotency of each sub-step
            /\ migState' = [migState EXCEPT ![key] =
                IF decision = "commit"
                THEN "commitPersistDecision"
                ELSE "abortPersistDecision"]
            /\ migDonor' = [migDonor EXCEPT ![key] = shard]
            /\ migRecipient' = [migRecipient EXCEPT ![key] = recip]
    /\ UNCHANGED <<coordDoc, rangeDel, configOwner, shardData, isPrimary,
                   donorCritSec, recipientCritSec>>

\* w:1 forget becomes majority-replicated (no longer rollbackable)
MajorityReplicateForget(shard) ==
    /\ coordDoc[shard].forgetPending
    /\ coordDoc' = [coordDoc EXCEPT ![shard] = EmptyCoordDoc]
    /\ UNCHANGED <<migState, migDonor, migRecipient, rangeDel, configOwner,
                   shardData, isPrimary, donorCritSec, recipientCritSec>>

\*===========================================================================
\* RANGE DELETION (Bug Family 2)
\*===========================================================================

\* Range deleter processes a ready task: delete orphan data and remove task
\* range_deletion_util.cpp:335-437 (deleteRangeInBatches)
DeleteRange(shard, key) ==
    /\ rangeDel[shard][key] = "ready"
    /\ isPrimary[shard]
    \* Remove physical data
    /\ shardData' = [shardData EXCEPT ![shard] = @ \ {key}]
    \* Remove the range deletion task
    /\ rangeDel' = [rangeDel EXCEPT ![shard][key] = "none"]
    /\ UNCHANGED <<migState, migDonor, migRecipient, coordDoc, configOwner,
                   isPrimary, donorCritSec, recipientCritSec>>

\*===========================================================================
\* Next
\*===========================================================================
Next ==
    \* Migration lifecycle
    \/ \E d \in Shard, r \in Shard, k \in Key : StartMigration(d, r, k)
    \/ \E s \in Shard, k \in Key : RecipientEnterCriticalSection(s, k)
    \/ \E s \in Shard, k \in Key : DonorEnterCriticalSection(s, k)
    \/ \E k \in Key : CommitOnConfigServer(k)
    \* Commit sub-steps
    \/ \E s \in Shard : PersistCommitDecision(s)
    \/ \E s \in Shard : CommitReleaseCritSec(s)
    \/ \E s \in Shard : CommitBumpRecipientTxn(s)
    \/ \E s \in Shard : CommitDeleteRecipientRangeDel(s)
    \/ \E s \in Shard : CommitMarkDonorRangeDelReady(s)
    \/ \E s \in Shard : CommitForgetMigration(s)
    \* Abort path
    \/ \E k \in Key : DecideAbort(k)
    \/ \E s \in Shard : AbortPersistDecision(s)
    \/ \E s \in Shard : AbortReleaseCritSec(s)
    \/ \E s \in Shard : AbortDeleteDonorRangeDel(s)
    \/ \E s \in Shard : AbortBumpRecipientTxn(s)
    \/ \E s \in Shard : AbortMarkRecipientRangeDelReady(s)
    \/ \E s \in Shard : AbortForgetMigration(s)
    \* Stepdown / Recovery
    \/ \E s \in Shard : Stepdown(s)
    \/ \E s \in Shard : StepUp(s)
    \/ \E s \in Shard : RecoverMigration(s)
    \/ \E s \in Shard : MajorityReplicateForget(s)
    \* Range deletion
    \/ \E s \in Shard, k \in Key : DeleteRange(s, k)

\*===========================================================================
\* INVARIANTS
\*===========================================================================

\*--- Standard Safety ---

\* Config server has unique ownership per key (true by construction: configOwner is a function)
\* Additional check: shard data + ownership are consistent outside critical section
ChunkOwnershipConsistent ==
    \A sh1, sh2 \in Shard :
        sh1 # sh2 =>
            \A k \in Key :
                \* If both shards have data for key and neither is in critical section
                \* related to this key's migration, only the owner should have it
                \/ k \notin shardData[sh1]
                \/ k \notin shardData[sh2]
                \/ migState[k] \in ActiveStates  \* Migration in progress — overlap OK
                \/ rangeDel[sh1][k] # "none"       \* Pending deletion — overlap OK
                \/ rangeDel[sh2][k] # "none"

\*--- Bug Family 1: Coordinator Recovery ---

\* If a commit decision is recorded, config server agrees
\* shard_filtering_metadata_refresh.cpp:610-633
\* Weak version: allows stale ghost coordDocs from w:1 forgetMigration rollback.
\* A ghost may have decision=commit but configOwner reversed by a subsequent migration.
\* In that case configOwner = donor (ownership went back to the original shard).
RecoveryConsistency ==
    \A s \in Shard :
        (/\ coordDoc[s].exists
         /\ coordDoc[s].decision = "commit"
         /\ ~\E s2 \in Shard :
                s2 # s /\ coordDoc[s2].exists /\ coordDoc[s2].key = coordDoc[s].key)
        => \/ configOwner[coordDoc[s].key] = coordDoc[s].recipient  \* Normal: commit reflected
           \/ configOwner[coordDoc[s].key] = s  \* Ghost: ownership reversed by back-to-back migration

\* Strong version for hunting: fails on SERVER-46395 pattern
RecoveryConsistencyStrong ==
    \A s \in Shard :
        (coordDoc[s].exists /\ coordDoc[s].decision = "commit")
        => configOwner[coordDoc[s].key] = coordDoc[s].recipient

\* If commit side-effects are being executed, the decision must be durable
\* (i.e., recorded in coordDoc OR recoverable from config server)
CoordinatorDecisionDurability ==
    \A k \in Key :
        migState[k] \in (CommitStates \ {"commitPersistDecision"})
        => \/ (coordDoc[migDonor[k]].exists /\
               coordDoc[migDonor[k]].decision = "commit")
           \/ configOwner[k] = migRecipient[k]  \* Recoverable from config server

\*--- Bug Family 2: Range Deletion Safety ---

\* Range deletion task marked ready only when shard is NOT the owner
\* Violation means range deletion would delete owned data
RangeDeletionSafety ==
    \A s \in Shard, k \in Key :
        rangeDel[s][k] = "ready" => configOwner[k] # s

\* No two FRESH coordinator docs reference the same key.
\* A ghost from w:1 forgetMigration rollback (decision # "none") may coexist
\* with a fresh doc (decision = "none") — this is the SERVER-46395 pattern.
\* Ghost recovery is blocked while the active migration runs (migState check).
NoOverlappingMigrations ==
    \A sh1, sh2 \in Shard :
        (sh1 # sh2 /\ coordDoc[sh1].exists /\ coordDoc[sh2].exists
         /\ coordDoc[sh1].key = coordDoc[sh2].key)
        \* At least one must be a ghost (decision already set from completed migration)
        => ~(coordDoc[sh1].decision = "none" /\ coordDoc[sh2].decision = "none")

\*--- Bug Family 3: Commit/Abort Asymmetry ---

\* No shard holds a recipient critical section without a coordinator doc
\* to eventually release it. Detects orphaned critical sections (MC-4).
NoOrphanedCriticalSection ==
    \A s \in Shard :
        recipientCritSec[s] =>
            \* Either an active migration references this recipient
            \/ \E k \in Key : migRecipient[k] = s /\ migState[k] \in ActiveStates
            \* Or a coordinator doc exists that will drive release
            \/ \E d \in Shard :
                coordDoc[d].exists /\ coordDoc[d].recipient = s

\*--- Structural Invariants (sanity checks) ---

\* CoordDoc is well-formed when it exists
CoordDocWellFormed ==
    \A s \in Shard :
        coordDoc[s].exists =>
            /\ coordDoc[s].key \in Key
            /\ coordDoc[s].recipient \in Shard
            /\ coordDoc[s].recipient # s

\* Range deletion tasks only exist for keys physically present
RangeDelImpliesData ==
    \A s \in Shard, k \in Key :
        rangeDel[s][k] \in {"pending", "ready"} => k \in shardData[s]

\* Migration donor and recipient are different shards
MigrationParticipantsDistinct ==
    \A k \in Key :
        migState[k] # "idle" =>
            /\ migDonor[k] \in Shard
            /\ migRecipient[k] \in Shard
            /\ migDonor[k] # migRecipient[k]

\* Only primary shards perform migration actions
PrimaryDonorInvariant ==
    \A k \in Key :
        migState[k] \in (CommitStates \cup AbortStates)
        => isPrimary[migDonor[k]]

\*--- Liveness (temporal properties, require fairness) ---

\* Every started migration eventually completes
MigrationEventuallyCompletes ==
    \A k \in Key :
        (migState[k] # "idle") ~> (migState[k] = "idle")

\* Every ready range deletion eventually completes
RangeDeletionEventuallyCompletes ==
    \A s \in Shard, k \in Key :
        (rangeDel[s][k] = "ready") ~> (rangeDel[s][k] = "none")

====
