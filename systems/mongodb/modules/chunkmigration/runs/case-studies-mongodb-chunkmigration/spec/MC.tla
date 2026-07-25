---- MODULE MC ----
\* Model checking wrapper for MongoDB chunk migration spec.
\* Counter-bounds fault injection actions; reactive actions pass through.

EXTENDS base

B == INSTANCE base

CONSTANTS
    MaxStepdownLimit,          \* Bound on stepdown events
    MaxAbortLimit,             \* Bound on abort events
    MaxConfigFailLimit,        \* Bound on config commit failures (Bug Family 3)
    MaxConfigAsyncLimit,       \* Bound on async config commits
    MaxRemoveRecipientLimit,   \* Bound on recipient removal (Bug Family 2)
    MaxRestoreRecipientLimit,  \* Bound on recipient restoration
    MaxForgetDurableLimit,     \* Bound on forget-become-durable events
    MaxRangeDeleterLimit       \* Bound on range deleter processing

VARIABLE constraintCounters
faultVars_mc == <<constraintCounters>>
allVars == <<vars, constraintCounters>>

\* ==============================================================
\* Counter-bounded wrappers
\* ==============================================================

MCStepdown ==
    /\ constraintCounters.stepdown < MaxStepdownLimit
    /\ B!Stepdown
    /\ constraintCounters' = [constraintCounters EXCEPT !.stepdown = @ + 1]

MCAbortBeforeConfigCommit(mid) ==
    /\ constraintCounters.abort < MaxAbortLimit
    /\ B!AbortBeforeConfigCommit(mid)
    /\ constraintCounters' = [constraintCounters EXCEPT !.abort = @ + 1]

MCConfigCommitFail(mid) ==
    /\ constraintCounters.configFail < MaxConfigFailLimit
    /\ B!ConfigCommitFail(mid)
    /\ constraintCounters' = [constraintCounters EXCEPT !.configFail = @ + 1]

MCConfigServerCommitAsync(mid) ==
    /\ constraintCounters.configAsync < MaxConfigAsyncLimit
    /\ B!ConfigServerCommitAsync(mid)
    /\ constraintCounters' = [constraintCounters EXCEPT !.configAsync = @ + 1]

MCRemoveRecipientShard ==
    /\ constraintCounters.removeRecipient < MaxRemoveRecipientLimit
    /\ B!RemoveRecipientShard
    /\ constraintCounters' = [constraintCounters EXCEPT !.removeRecipient = @ + 1]

MCRestoreRecipientShard ==
    /\ constraintCounters.restoreRecipient < MaxRestoreRecipientLimit
    /\ B!RestoreRecipientShard
    /\ constraintCounters' = [constraintCounters EXCEPT !.restoreRecipient = @ + 1]

MCForgetBecomeDurable(mid) ==
    /\ constraintCounters.forgetDurable < MaxForgetDurableLimit
    /\ B!ForgetBecomeDurable(mid)
    /\ constraintCounters' = [constraintCounters EXCEPT !.forgetDurable = @ + 1]

MCRangeDeleterProcessTask ==
    /\ constraintCounters.rangeDeleter < MaxRangeDeleterLimit
    /\ B!RangeDeleterProcessTask
    /\ constraintCounters' = [constraintCounters EXCEPT !.rangeDeleter = @ + 1]

\* ==============================================================
\* Unconstrained wrappers (reactive/deterministic actions)
\* ==============================================================

MCStartMigration(mid) ==
    /\ B!StartMigration(mid) /\ UNCHANGED constraintCounters

MCAdvanceToConfigCommit(mid) ==
    /\ B!AdvanceToConfigCommit(mid) /\ UNCHANGED constraintCounters

MCConfigCommitSucceed(mid) ==
    /\ B!ConfigCommitSucceed(mid) /\ UNCHANGED constraintCounters

MCDoCommitPersist(mid) ==
    /\ B!DoCommitPersist(mid) /\ UNCHANGED constraintCounters

MCDoCommitAdvanceTxn(mid) ==
    /\ B!DoCommitAdvanceTxn(mid) /\ UNCHANGED constraintCounters

MCDoCommitRetrieveOrphans(mid) ==
    /\ B!DoCommitRetrieveOrphans(mid) /\ UNCHANGED constraintCounters

MCDoCommitPersistOrphans(mid) ==
    /\ B!DoCommitPersistOrphans(mid) /\ UNCHANGED constraintCounters

MCDoCommitDeleteRecipientTask(mid) ==
    /\ B!DoCommitDeleteRecipientTask(mid) /\ UNCHANGED constraintCounters

MCDoCommitGetDonorTask(mid) ==
    /\ B!DoCommitGetDonorTask(mid) /\ UNCHANGED constraintCounters

MCDoCommitMarkReady(mid) ==
    /\ B!DoCommitMarkReady(mid) /\ UNCHANGED constraintCounters

MCDoCommitForget(mid) ==
    /\ B!DoCommitForget(mid) /\ UNCHANGED constraintCounters

MCDoAbortPersist(mid) ==
    /\ B!DoAbortPersist(mid) /\ UNCHANGED constraintCounters

MCDoAbortDeleteLocal(mid) ==
    /\ B!DoAbortDeleteLocal(mid) /\ UNCHANGED constraintCounters

MCDoAbortAdvanceTxn(mid) ==
    /\ B!DoAbortAdvanceTxn(mid) /\ UNCHANGED constraintCounters

MCDoAbortMarkRecipient(mid) ==
    /\ B!DoAbortMarkRecipient(mid) /\ UNCHANGED constraintCounters

MCDoAbortForget(mid) ==
    /\ B!DoAbortForget(mid) /\ UNCHANGED constraintCounters

MCCleanupComplete(mid) ==
    /\ B!CleanupComplete(mid) /\ UNCHANGED constraintCounters

MCRecoverMigration(mid) ==
    /\ B!RecoverMigration(mid) /\ UNCHANGED constraintCounters

MCRecoverFromLimbo(mid) ==
    /\ B!RecoverFromLimbo(mid) /\ UNCHANGED constraintCounters

\* ==============================================================
\* MCInit and MCNext
\* ==============================================================

MCInit ==
    /\ B!Init
    /\ constraintCounters = [
        stepdown         |-> 0,
        abort            |-> 0,
        configFail       |-> 0,
        configAsync      |-> 0,
        removeRecipient  |-> 0,
        restoreRecipient |-> 0,
        forgetDurable    |-> 0,
        rangeDeleter     |-> 0
       ]

MCNext ==
    \/ \E mid \in MigrationId :
        \* Lifecycle (unconstrained)
        \/ MCStartMigration(mid)
        \/ MCAdvanceToConfigCommit(mid)
        \/ MCConfigCommitSucceed(mid)
        \* Lifecycle (bounded)
        \/ MCConfigCommitFail(mid)
        \/ MCConfigServerCommitAsync(mid)
        \/ MCAbortBeforeConfigCommit(mid)
        \* Commit cleanup (unconstrained)
        \/ MCDoCommitPersist(mid)
        \/ MCDoCommitAdvanceTxn(mid)
        \/ MCDoCommitRetrieveOrphans(mid)
        \/ MCDoCommitPersistOrphans(mid)
        \/ MCDoCommitDeleteRecipientTask(mid)
        \/ MCDoCommitGetDonorTask(mid)
        \/ MCDoCommitMarkReady(mid)
        \/ MCDoCommitForget(mid)
        \* Abort cleanup (unconstrained)
        \/ MCDoAbortPersist(mid)
        \/ MCDoAbortDeleteLocal(mid)
        \/ MCDoAbortAdvanceTxn(mid)
        \/ MCDoAbortMarkRecipient(mid)
        \/ MCDoAbortForget(mid)
        \* Completion and recovery (unconstrained)
        \/ MCCleanupComplete(mid)
        \/ MCRecoverMigration(mid)
        \/ MCRecoverFromLimbo(mid)
        \* Durability (bounded)
        \/ MCForgetBecomeDurable(mid)
    \* Background (bounded)
    \/ MCRangeDeleterProcessTask
    \* Fault injection (bounded)
    \/ MCStepdown
    \/ MCRemoveRecipientShard
    \/ MCRestoreRecipientShard

MCSpec == MCInit /\ [][MCNext]_allVars

\* ==============================================================
\* View (exclude counters from state fingerprint)
\* ==============================================================

MCView == vars

\* ==============================================================
\* Temporal Properties
\* ==============================================================

\* CommitPathCompletes: if config committed, cleanup eventually completes
CommitPathCompletes ==
    \A mid \in MigrationId :
        (mid \in configCommitted /\ coordDocs[mid] = Committed)
            ~> (mid \in completedMigrations \/ coordDocs[mid] = Nil)

\* No coordinator doc persists forever
EventualCleanup ==
    \A mid \in MigrationId :
        (coordDocs[mid] /= Nil) ~> (coordDocs[mid] = Nil)

====
