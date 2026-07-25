---- MODULE MC ----
\* Model checking wrapper for MongoDB MoveRange base spec.
\* Counter-bounds non-deterministic (fault injection) actions.
\* Leaves reactive/deterministic actions unbounded.

EXTENDS base

CONSTANTS
    MaxMigrations,         \* Bound on StartMigration
    MaxStepdowns,          \* Bound on Stepdown (per shard)
    MaxStepUps,            \* Bound on StepUp (per shard)
    MaxAborts,             \* Bound on DecideAbort
    MaxMajorityReplicates  \* Bound on MajorityReplicateForget

VARIABLES
    migrationCount,     \* Total StartMigration actions fired
    stepdownCount,      \* [Shard -> Nat] Stepdown actions per shard
    stepUpCount,        \* [Shard -> Nat] StepUp actions per shard
    abortCount,         \* Total DecideAbort actions fired
    majorityRepCount    \* Total MajorityReplicateForget actions fired

faultVars == <<migrationCount, stepdownCount, stepUpCount,
               abortCount, majorityRepCount>>

mcVars == <<migState, migDonor, migRecipient, coordDoc, rangeDel,
            configOwner, shardData, isPrimary, donorCritSec, recipientCritSec,
            migrationCount, stepdownCount, stepUpCount, abortCount, majorityRepCount>>

\*---------------------------------------------------------------------------
\* Counter-bounded wrappers
\*---------------------------------------------------------------------------

MCStartMigration(donor, recipient, key) ==
    /\ migrationCount < MaxMigrations
    /\ StartMigration(donor, recipient, key)
    /\ migrationCount' = migrationCount + 1
    /\ UNCHANGED <<stepdownCount, stepUpCount, abortCount, majorityRepCount>>

MCStepdown(shard) ==
    /\ stepdownCount[shard] < MaxStepdowns
    /\ Stepdown(shard)
    /\ stepdownCount' = [stepdownCount EXCEPT ![shard] = @ + 1]
    /\ UNCHANGED <<migrationCount, stepUpCount, abortCount, majorityRepCount>>

MCStepUp(shard) ==
    /\ stepUpCount[shard] < MaxStepUps
    /\ StepUp(shard)
    /\ stepUpCount' = [stepUpCount EXCEPT ![shard] = @ + 1]
    /\ UNCHANGED <<migrationCount, stepdownCount, abortCount, majorityRepCount>>

MCDecideAbort(key) ==
    /\ abortCount < MaxAborts
    /\ DecideAbort(key)
    /\ abortCount' = abortCount + 1
    /\ UNCHANGED <<migrationCount, stepdownCount, stepUpCount, majorityRepCount>>

MCMajorityReplicateForget(shard) ==
    /\ majorityRepCount < MaxMajorityReplicates
    /\ MajorityReplicateForget(shard)
    /\ majorityRepCount' = majorityRepCount + 1
    /\ UNCHANGED <<migrationCount, stepdownCount, stepUpCount, abortCount>>

\*---------------------------------------------------------------------------
\* Pass-through wrappers (reactive actions, unbounded)
\*---------------------------------------------------------------------------
UnchangedFaultVars == UNCHANGED faultVars

MCRecipientEnterCriticalSection(s, k) ==
    RecipientEnterCriticalSection(s, k) /\ UnchangedFaultVars

MCDonorEnterCriticalSection(s, k) ==
    DonorEnterCriticalSection(s, k) /\ UnchangedFaultVars

MCCommitOnConfigServer(k) ==
    CommitOnConfigServer(k) /\ UnchangedFaultVars

MCPersistCommitDecision(s) ==
    PersistCommitDecision(s) /\ UnchangedFaultVars

MCCommitReleaseCritSec(s) ==
    CommitReleaseCritSec(s) /\ UnchangedFaultVars

MCCommitBumpRecipientTxn(s) ==
    CommitBumpRecipientTxn(s) /\ UnchangedFaultVars

MCCommitDeleteRecipientRangeDel(s) ==
    CommitDeleteRecipientRangeDel(s) /\ UnchangedFaultVars

MCCommitMarkDonorRangeDelReady(s) ==
    CommitMarkDonorRangeDelReady(s) /\ UnchangedFaultVars

MCCommitForgetMigration(s) ==
    CommitForgetMigration(s) /\ UnchangedFaultVars

MCAbortPersistDecision(s) ==
    AbortPersistDecision(s) /\ UnchangedFaultVars

MCAbortReleaseCritSec(s) ==
    AbortReleaseCritSec(s) /\ UnchangedFaultVars

MCAbortDeleteDonorRangeDel(s) ==
    AbortDeleteDonorRangeDel(s) /\ UnchangedFaultVars

MCAbortBumpRecipientTxn(s) ==
    AbortBumpRecipientTxn(s) /\ UnchangedFaultVars

MCAbortMarkRecipientRangeDelReady(s) ==
    AbortMarkRecipientRangeDelReady(s) /\ UnchangedFaultVars

MCAbortForgetMigration(s) ==
    AbortForgetMigration(s) /\ UnchangedFaultVars

MCRecoverMigration(s) ==
    RecoverMigration(s) /\ UnchangedFaultVars

MCDeleteRange(s, k) ==
    DeleteRange(s, k) /\ UnchangedFaultVars

\*---------------------------------------------------------------------------
\* MCInit / MCNext
\*---------------------------------------------------------------------------

MCInit ==
    /\ Init
    /\ migrationCount = 0
    /\ stepdownCount = [s \in Shard |-> 0]
    /\ stepUpCount = [s \in Shard |-> 0]
    /\ abortCount = 0
    /\ majorityRepCount = 0

MCNext ==
    \* Bounded actions
    \/ \E d \in Shard, r \in Shard, k \in Key : MCStartMigration(d, r, k)
    \/ \E s \in Shard : MCStepdown(s)
    \/ \E s \in Shard : MCStepUp(s)
    \/ \E k \in Key : MCDecideAbort(k)
    \/ \E s \in Shard : MCMajorityReplicateForget(s)
    \* Unbounded reactive actions
    \/ \E s \in Shard, k \in Key : MCRecipientEnterCriticalSection(s, k)
    \/ \E s \in Shard, k \in Key : MCDonorEnterCriticalSection(s, k)
    \/ \E k \in Key : MCCommitOnConfigServer(k)
    \/ \E s \in Shard : MCPersistCommitDecision(s)
    \/ \E s \in Shard : MCCommitReleaseCritSec(s)
    \/ \E s \in Shard : MCCommitBumpRecipientTxn(s)
    \/ \E s \in Shard : MCCommitDeleteRecipientRangeDel(s)
    \/ \E s \in Shard : MCCommitMarkDonorRangeDelReady(s)
    \/ \E s \in Shard : MCCommitForgetMigration(s)
    \/ \E s \in Shard : MCAbortPersistDecision(s)
    \/ \E s \in Shard : MCAbortReleaseCritSec(s)
    \/ \E s \in Shard : MCAbortDeleteDonorRangeDel(s)
    \/ \E s \in Shard : MCAbortBumpRecipientTxn(s)
    \/ \E s \in Shard : MCAbortMarkRecipientRangeDelReady(s)
    \/ \E s \in Shard : MCAbortForgetMigration(s)
    \/ \E s \in Shard : MCRecoverMigration(s)
    \/ \E s \in Shard, k \in Key : MCDeleteRange(s, k)

\*---------------------------------------------------------------------------
\* Symmetry
\*---------------------------------------------------------------------------
ModelSymmetry == Permutations(Shard)

\*---------------------------------------------------------------------------
\* State constraint: prevent unbounded state space
\*---------------------------------------------------------------------------
StateConstraint == TRUE

\*---------------------------------------------------------------------------
\* Structural invariants (always enabled in MC.cfg)
\*---------------------------------------------------------------------------
\* Re-exported from base for cfg reference
MCCoordDocWellFormed == CoordDocWellFormed
MCRangeDelImpliesData == RangeDelImpliesData
MCMigrationParticipantsDistinct == MigrationParticipantsDistinct

\*---------------------------------------------------------------------------
\* Standard safety invariants (always enabled in MC.cfg)
\*---------------------------------------------------------------------------
MCChunkOwnershipConsistent == ChunkOwnershipConsistent
MCRecoveryConsistency == RecoveryConsistency
MCNoOverlappingMigrations == NoOverlappingMigrations

\*---------------------------------------------------------------------------
\* Extension invariants (enabled in hunting configs)
\*---------------------------------------------------------------------------
MCRangeDeletionSafety == RangeDeletionSafety
MCCoordinatorDecisionDurability == CoordinatorDecisionDurability
MCNoOrphanedCriticalSection == NoOrphanedCriticalSection
MCRecoveryConsistencyStrong == RecoveryConsistencyStrong

====
