---- MODULE MC ----
\* ===========================================================================
\* Model Checking wrapper for MongoDB Transaction Router & Resource Contention
\*
\* Counter-bounded fault injection for exhaustive state space exploration.
\* Bounds fault-injection actions (NOT deterministic/reactive actions).
\*
\* Fault injection actions bounded:
\*   - DirectCommitPartial (Family 1, SERVER-116284)
\*   - SessionReaperFire (Family 3, SERVER-105751)
\*   - BackgroundTaskAcquire (Family 2, SERVER-65821)
\*   - SWSReadOnlyFail (Family 4)
\*   - SWSWriteFail (Family 4)
\*   - DelayedCommitArrival (Family 4)
\*   - RouterRetry (bounds retry count)
\*
\* Deterministic/reactive actions are NOT bounded:
\*   RouterStartTxn, RouterCommitTxn, DirectCommit, SWSCommitReadOnly,
\*   SWSCommitWrite, SWSRetryRecovery, CoordDecideCommit, CoordDecideAbort,
\*   CoordPersistAndSend, CoordSendDecisionToShard, CoordFinish,
\*   RouterReceive2PCResult, BackgroundTaskRelease
\* ===========================================================================
EXTENDS base

ASSUME Cardinality(Shard) >= 2

\* Original operators for direct access when cfg overrides
Base == INSTANCE base

\* ===========================================================================
\* Counter Variables
\* ===========================================================================

VARIABLES
    partialSendCount,    \* DirectCommitPartial counter [Family 1]
    reaperCount,         \* SessionReaperFire counter [Family 3]
    bgTaskCount,         \* BackgroundTaskAcquire counter [Family 2]
    swsReadFailCount,    \* SWSReadOnlyFail counter [Family 4]
    swsWriteFailCount,   \* SWSWriteFail counter [Family 4]
    delayedCommitCount,  \* DelayedCommitArrival counter [Family 4]
    retryCount           \* RouterRetry counter

faultVars == <<partialSendCount, reaperCount, bgTaskCount,
               swsReadFailCount, swsWriteFailCount, delayedCommitCount,
               retryCount>>

allVars == <<vars, faultVars>>

\* ===========================================================================
\* Counter Bounds (overridden in .cfg)
\* ===========================================================================

CONSTANTS
    MaxPartialSend,      \* Max DirectCommitPartial events
    MaxReaper,           \* Max SessionReaperFire events
    MaxBgTask,           \* Max BackgroundTaskAcquire events
    MaxSWSReadFail,      \* Max SWSReadOnlyFail events
    MaxSWSWriteFail,     \* Max SWSWriteFail events
    MaxDelayedCommit,    \* Max DelayedCommitArrival events
    MaxRetry             \* Max RouterRetry events

\* ===========================================================================
\* Counter-Bounded Wrappers
\* ===========================================================================

MCDirectCommitPartial(r, t) ==
    /\ partialSendCount < MaxPartialSend
    /\ DirectCommitPartial(r, t)
    /\ partialSendCount' = partialSendCount + 1
    /\ UNCHANGED <<reaperCount, bgTaskCount, swsReadFailCount,
                   swsWriteFailCount, delayedCommitCount, retryCount>>

MCSessionReaperFire(s, t) ==
    /\ reaperCount < MaxReaper
    /\ SessionReaperFire(s, t)
    /\ reaperCount' = reaperCount + 1
    /\ UNCHANGED <<partialSendCount, bgTaskCount, swsReadFailCount,
                   swsWriteFailCount, delayedCommitCount, retryCount>>

MCBackgroundTaskAcquire(s) ==
    /\ bgTaskCount < MaxBgTask
    /\ BackgroundTaskAcquire(s)
    /\ bgTaskCount' = bgTaskCount + 1
    /\ UNCHANGED <<partialSendCount, reaperCount, swsReadFailCount,
                   swsWriteFailCount, delayedCommitCount, retryCount>>

MCSWSReadOnlyFail(r, t) ==
    /\ swsReadFailCount < MaxSWSReadFail
    /\ SWSReadOnlyFail(r, t)
    /\ swsReadFailCount' = swsReadFailCount + 1
    /\ UNCHANGED <<partialSendCount, reaperCount, bgTaskCount,
                   swsWriteFailCount, delayedCommitCount, retryCount>>

MCSWSWriteFail(r, t) ==
    /\ swsWriteFailCount < MaxSWSWriteFail
    /\ SWSWriteFail(r, t)
    /\ swsWriteFailCount' = swsWriteFailCount + 1
    /\ UNCHANGED <<partialSendCount, reaperCount, bgTaskCount,
                   swsReadFailCount, delayedCommitCount, retryCount>>

MCDelayedCommitArrival(s, t) ==
    /\ delayedCommitCount < MaxDelayedCommit
    /\ DelayedCommitArrival(s, t)
    /\ delayedCommitCount' = delayedCommitCount + 1
    /\ UNCHANGED <<partialSendCount, reaperCount, bgTaskCount,
                   swsReadFailCount, swsWriteFailCount, retryCount>>

MCRouterRetry(r, t) ==
    /\ retryCount < MaxRetry
    /\ RouterRetry(r, t)
    /\ retryCount' = retryCount + 1
    /\ UNCHANGED <<partialSendCount, reaperCount, bgTaskCount,
                   swsReadFailCount, swsWriteFailCount, delayedCommitCount>>

\* ===========================================================================
\* Unconstrained Wrappers (deterministic/reactive actions)
\* ===========================================================================

PassFaultVars == UNCHANGED faultVars

MCRouterStartTxn(r, t)         == RouterStartTxn(r, t)         /\ PassFaultVars
MCRouterCommitTxn(r, t)        == RouterCommitTxn(r, t)        /\ PassFaultVars
MCDirectCommit(r, t)            == DirectCommit(r, t)            /\ PassFaultVars
MCSWSCommitReadOnly(r, t)       == SWSCommitReadOnly(r, t)       /\ PassFaultVars
MCSWSCommitWrite(r, t)          == SWSCommitWrite(r, t)          /\ PassFaultVars
MCSWSRetryRecovery(r, t)        == SWSRetryRecovery(r, t)        /\ PassFaultVars
MCCoordDecideCommit(t)          == CoordDecideCommit(t)          /\ PassFaultVars
MCCoordDecideAbort(t)           == CoordDecideAbort(t)           /\ PassFaultVars
MCCoordPersistAndSend(t)        == CoordPersistAndSend(t)        /\ PassFaultVars
MCCoordSendDecisionToShard(t, s) == CoordSendDecisionToShard(t, s) /\ PassFaultVars
MCCoordFinish(t)                == CoordFinish(t)                /\ PassFaultVars
MCRouterReceive2PCResult(r, t)  == RouterReceive2PCResult(r, t)  /\ PassFaultVars
MCBackgroundTaskRelease(s)      == BackgroundTaskRelease(s)      /\ PassFaultVars

\* ===========================================================================
\* Init and Next
\* ===========================================================================

MCInit ==
    /\ Init
    /\ partialSendCount = 0
    /\ reaperCount = 0
    /\ bgTaskCount = 0
    /\ swsReadFailCount = 0
    /\ swsWriteFailCount = 0
    /\ delayedCommitCount = 0
    /\ retryCount = 0

MCNext ==
    \* --- Transaction lifecycle ---
    \/ \E r \in Router, t \in Txn : MCRouterStartTxn(r, t)
    \/ \E r \in Router, t \in Txn : MCRouterCommitTxn(r, t)
    \/ \E r \in Router, t \in Txn : MCRouterRetry(r, t)
    \* --- Direct commit [Family 1] ---
    \/ \E r \in Router, t \in Txn : MCDirectCommit(r, t)
    \/ \E r \in Router, t \in Txn : MCDirectCommitPartial(r, t)
    \* --- SWS path [Family 4] ---
    \/ \E r \in Router, t \in Txn : MCSWSCommitReadOnly(r, t)
    \/ \E r \in Router, t \in Txn : MCSWSReadOnlyFail(r, t)
    \/ \E r \in Router, t \in Txn : MCSWSCommitWrite(r, t)
    \/ \E r \in Router, t \in Txn : MCSWSWriteFail(r, t)
    \/ \E r \in Router, t \in Txn : MCSWSRetryRecovery(r, t)
    \* --- 2PC coordinator [Family 2, 3] ---
    \/ \E t \in Txn : MCCoordDecideCommit(t)
    \/ \E t \in Txn : MCCoordDecideAbort(t)
    \/ \E t \in Txn : MCCoordPersistAndSend(t)
    \/ \E t \in Txn, s \in Shard : MCCoordSendDecisionToShard(t, s)
    \/ \E t \in Txn : MCCoordFinish(t)
    \/ \E r \in Router, t \in Txn : MCRouterReceive2PCResult(r, t)
    \* --- Fault injection (bounded) ---
    \/ \E s \in Shard, t \in Txn : MCSessionReaperFire(s, t)
    \/ \E s \in Shard, t \in Txn : MCDelayedCommitArrival(s, t)
    \/ \E s \in Shard : MCBackgroundTaskAcquire(s)
    \/ \E s \in Shard : MCBackgroundTaskRelease(s)

MCSpec == MCInit /\ [][MCNext]_allVars

\* ===========================================================================
\* Symmetry
\* ===========================================================================

MCSymmetry == Permutations(Shard)

\* ===========================================================================
\* State Constraint (optional, for bounding state space)
\* ===========================================================================

MCStateConstraint ==
    /\ tickets >= 0
    /\ \A r \in Router, t \in Txn : rAttempt[r][t] <= MaxRetry

====
