-------------------------------- MODULE MC ---------------------------------
\* Model checking wrapper for MongoDB Range Deletion Protocol
\*
\* Wraps base.tla with counter-bounded fault-injection actions.
\* Normal reactive actions (decision delivery, task activation) are unbounded.
\* Fault-injection actions (Crash, RemoveRecipientShard, RollbackForgetMigration)
\* are bounded to keep the state space finite and tractable.

EXTENDS base, Naturals

-----------------------------------------------------------------------------
\* FAULT INJECTION COUNTERS
\*
\* One counter per non-deterministic (fault-injection) action.
\* Reactive/deterministic actions are NOT bounded.

VARIABLES faultVarsCount

\* Fault counter record fields:
\*   crashCount            — number of Crash actions fired
\*   removeShardCount      — number of RemoveRecipientShard actions fired
\*   rollbackCount         — number of RollbackForgetMigration actions fired

MCFaultVarsInit ==
    faultVarsCount = [crashCount         |-> 0,
                      removeShardCount   |-> 0,
                      rollbackCount      |-> 0]

-----------------------------------------------------------------------------
\* TUNING CONSTANTS (overridden in .cfg)

CONSTANTS
    MaxCrashCount,        \* bound on Crash actions
    MaxRemoveShardCount,  \* bound on RemoveRecipientShard actions
    MaxRollbackCount      \* bound on RollbackForgetMigration (w:1 rollback) actions

-----------------------------------------------------------------------------
\* BOUNDED FAULT WRAPPERS

\* Bounded Crash (Family 1 & 2): crash between sequential persistent writes
MCCrash ==
    /\ faultVarsCount.crashCount < MaxCrashCount
    /\ Crash
    /\ faultVarsCount' = [faultVarsCount EXCEPT
                            !.crashCount = @ + 1]

\* Bounded RemoveRecipientShard (Family 2): enables ShardNotFound path
MCRemoveRecipientShard ==
    /\ faultVarsCount.removeShardCount < MaxRemoveShardCount
    /\ RemoveRecipientShard
    /\ faultVarsCount' = [faultVarsCount EXCEPT
                            !.removeShardCount = @ + 1]

\* Bounded RollbackForgetMigration (Family 2): w:1 write rolled back on stepdown
MCRollbackForgetMigration(m) ==
    /\ faultVarsCount.rollbackCount < MaxRollbackCount
    /\ RollbackForgetMigration(m)
    /\ faultVarsCount' = [faultVarsCount EXCEPT
                            !.rollbackCount = @ + 1]

-----------------------------------------------------------------------------
\* PASS-THROUGH WRAPPERS FOR NON-FAULT ACTIONS
\* Deterministic/reactive actions are not bounded; they add UNCHANGED faultVarsCount.

MCWriteCoordDoc(m)                    == WriteCoordDoc(m)                    /\ UNCHANGED faultVarsCount
MCWriteRangeDeletionTask(m)           == WriteRangeDeletionTask(m)           /\ UNCHANGED faultVarsCount
MCPersistCommitDecision(m)            == PersistCommitDecision(m)            /\ UNCHANGED faultVarsCount
MCDeleteRecipientTaskOnCommit(m)      == DeleteRecipientTaskOnCommit(m)      /\ UNCHANGED faultVarsCount
MCActivateDonorTaskOnCommit(m)        == ActivateDonorTaskOnCommit(m)        /\ UNCHANGED faultVarsCount
MCCommitSilentSkip(m)                 == CommitSilentSkip(m)                 /\ UNCHANGED faultVarsCount
MCPersistAbortDecision(m)             == PersistAbortDecision(m)             /\ UNCHANGED faultVarsCount
MCDeleteDonorTaskOnAbort(m)           == DeleteDonorTaskOnAbort(m)           /\ UNCHANGED faultVarsCount
MCAdvanceTransactionOnRecipientAbort(m) == AdvanceTransactionOnRecipientAbort(m) /\ UNCHANGED faultVarsCount
MCMarkRecipientTaskReady(m)           == MarkRecipientTaskReady(m)           /\ UNCHANGED faultVarsCount
MCMarkRecipientTaskReadyFails(m)      == MarkRecipientTaskReadyFails(m)      /\ UNCHANGED faultVarsCount
MCForgetMigration(m)                  == ForgetMigration(m)                  /\ UNCHANGED faultVarsCount
MCExecuteRangeDeletion(m)             == ExecuteRangeDeletion(m)             /\ UNCHANGED faultVarsCount
MCCompleteRangeDeletion(m)            == CompleteRangeDeletion(m)            /\ UNCHANGED faultVarsCount
MCExecuteRecipientRangeDeletion(m)    == ExecuteRecipientRangeDeletion(m)    /\ UNCHANGED faultVarsCount
MCCompleteRecipientRangeDeletion(m)   == CompleteRecipientRangeDeletion(m)   /\ UNCHANGED faultVarsCount
MCRegisterTaskPostSnapshot(m)         == RegisterTaskPostSnapshot(m)         /\ UNCHANGED faultVarsCount
MCGetOverlapSnapshot                  == GetOverlapSnapshot                  /\ UNCHANGED faultVarsCount
MCRecovery                            == Recovery                            /\ UNCHANGED faultVarsCount
MCRecipientShardRejoins               == RecipientShardRejoins               /\ UNCHANGED faultVarsCount

-----------------------------------------------------------------------------
\* MC INIT AND NEXT

MCInit ==
    /\ Init
    /\ MCFaultVarsInit

MCNext ==
    \/ \E m \in MigrationId :
        \/ MCWriteCoordDoc(m)
        \/ MCWriteRangeDeletionTask(m)
        \/ MCPersistCommitDecision(m)
        \/ MCDeleteRecipientTaskOnCommit(m)
        \/ MCActivateDonorTaskOnCommit(m)
        \/ MCCommitSilentSkip(m)
        \/ MCPersistAbortDecision(m)
        \/ MCDeleteDonorTaskOnAbort(m)
        \/ MCAdvanceTransactionOnRecipientAbort(m)
        \/ MCMarkRecipientTaskReady(m)
        \/ MCMarkRecipientTaskReadyFails(m)
        \/ MCForgetMigration(m)
        \/ MCExecuteRangeDeletion(m)
        \/ MCCompleteRangeDeletion(m)
        \/ MCExecuteRecipientRangeDeletion(m)
        \/ MCCompleteRecipientRangeDeletion(m)
        \/ MCRegisterTaskPostSnapshot(m)
        \/ MCRollbackForgetMigration(m)
    \/ MCGetOverlapSnapshot
    \/ MCCrash
    \/ MCRecovery
    \/ MCRemoveRecipientShard
    \/ MCRecipientShardRejoins

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVarsCount>>

-----------------------------------------------------------------------------
\* SYMMETRY AND VIEW
\* Exclude fault counters from symmetry reduction view to avoid false symmetry.

MCView == vars

Symmetry == Permutations(MigrationId) \cup Permutations(Shard)

-----------------------------------------------------------------------------
\* MESSAGE BUFFER CONSTRAINT (not applicable — no explicit message bag)
\* All RPCs are modeled as immediate state changes (no explicit message queues).

-----------------------------------------------------------------------------
\* INVARIANTS

\* -- Structural (always checked) --
MCTypeOK      == TypeOK
MCProcessingImpliesInMemory == ProcessingImpliesInMemory
MCRecoveryCompleteness      == RecoveryCompleteness

\* -- Safety (always checked in MC.cfg, commented in hunt cfgs unless targeted) --
MCNoSimultaneousDonorProcessing == NoSimultaneousDonorProcessing

\* -- Extension invariants (Bug Family specific) --
\* Commented out in MC.cfg; enabled in individual MC_hunt_*.cfg files.

MCNoOrphanOnCommit == NoOrphanOnCommit
MCNoAbortedCoordWithStuckPendingRecipient == NoAbortedCoordWithStuckPendingRecipient

=============================================================================
