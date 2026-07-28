-------------------------- MODULE MC --------------------------
EXTENDS base, TLC, Sequences, FiniteSets

\* ====== Counter Variables ======
\* One counter per fault-injection action family.
\* These bound the number of times each fault can fire.

VARIABLE
    mcFaultCounter

\* Counters indexed by fault type
MC_NUM_COUNTERS == 12

\* Counter indices
MC_COORD_ELECTION      == 0
MC_COORD_START_STOP    == 1
MC_SHARD_ELECTION      == 2
MC_RSM_REPLICATE       == 3
MC_SHARD_OPERATION     == 4
MC_SENTINEL_REQUEST    == 5
MC_SENTINEL_NONLEADER  == 6
MC_BATCH_ADD           == 7
MC_BATCH_SWAP          == 8
MC_LOG_GROW            == 9
MC_COORD_CRASH         == 10
MC_SHARD_CRASH         == 11

\* ====== Fault Limits (tunable in cfg) ======

MaxCoordElectionLimit     == 4
MaxCoordStartStopLimit    == 4
MaxShardElectionLimit     == 4
MaxRSMReplicateLimit      == 6
MaxShardOperationLimit    == 6
MaxSentinelRequestLimit   == 3
MaxSentinelNonLeaderLimit == 3
MaxBatchAddLimit          == 6
MaxBatchSwapLimit         == 4
MaxLogGrowLimit           == 3
MaxCoordCrashLimit        == 2
MaxShardCrashLimit        == 2

\* ====== Counter Helpers ======

MCFaultCounterVal(i) == mcFaultCounter[i]

MCCanFire(i) == MCFaultCounterVal(i) > 0

MCFire(i) == [mcFaultCounter EXCEPT ![i] = mcFaultCounter[i] - 1]

\* ====== MCInit ======

MCInit ==
    /\ Init
    /\ mcFaultCounter = [i \in 0..(MC_NUM_COUNTERS - 1) |->
                            IF i = MC_COORD_ELECTION      THEN MaxCoordElectionLimit
                            ELSE IF i = MC_COORD_START_STOP    THEN MaxCoordStartStopLimit
                            ELSE IF i = MC_SHARD_ELECTION      THEN MaxShardElectionLimit
                            ELSE IF i = MC_RSM_REPLICATE       THEN MaxRSMReplicateLimit
                            ELSE IF i = MC_SHARD_OPERATION     THEN MaxShardOperationLimit
                            ELSE IF i = MC_SENTINEL_REQUEST    THEN MaxSentinelRequestLimit
                            ELSE IF i = MC_SENTINEL_NONLEADER  THEN MaxSentinelNonLeaderLimit
                            ELSE IF i = MC_BATCH_ADD           THEN MaxBatchAddLimit
                            ELSE IF i = MC_BATCH_SWAP          THEN MaxBatchSwapLimit
                            ELSE IF i = MC_LOG_GROW            THEN MaxLogGrowLimit
                            ELSE IF i = MC_COORD_CRASH         THEN MaxCoordCrashLimit
                            ELSE IF i = MC_SHARD_CRASH         THEN MaxShardCrashLimit
                            ELSE 0]

\* ====== Constrained Action Wrappers ======

\* Family 1: Coordinator leadership elections (fault-injection: non-deterministic)
MCCoordRaftCallbackBecomeLeader(c) ==
    /\ MCCanFire(MC_COORD_ELECTION)
    /\ CoordRaftCallbackBecomeLeader(c)
    /\ mcFaultCounter' = MCFire(MC_COORD_ELECTION)

MCCoordRaftCallbackBecomeFollower(c) ==
    /\ MCCanFire(MC_COORD_ELECTION)
    /\ CoordRaftCallbackBecomeFollower(c)
    /\ mcFaultCounter' = MCFire(MC_COORD_ELECTION)

\* Family 1: Coordinator handler activation/deactivation
MCCoordActivateHandler(c) ==
    /\ MCCanFire(MC_COORD_START_STOP)
    /\ CoordActivateHandler(c)
    /\ mcFaultCounter' = MCFire(MC_COORD_START_STOP)

MCCoordDeactivateHandler(c) ==
    /\ MCCanFire(MC_COORD_START_STOP)
    /\ CoordDeactivateHandler(c)
    /\ mcFaultCounter' = MCFire(MC_COORD_START_STOP)

\* Family 1: Shard leadership elections (inline, no gap — different pattern)
MCShardRaftCallbackBecomeLeader(s) ==
    /\ MCCanFire(MC_SHARD_ELECTION)
    /\ ShardRaftCallbackBecomeLeader(s)
    /\ mcFaultCounter' = MCFire(MC_SHARD_ELECTION)

MCShardRaftCallbackBecomeFollower(s) ==
    /\ MCCanFire(MC_SHARD_ELECTION)
    /\ ShardRaftCallbackBecomeFollower(s)
    /\ mcFaultCounter' = MCFire(MC_SHARD_ELECTION)

\* Family 2: RSM replication (non-deterministic phase transitions)
MCRSMReplicatePrepare(d) ==
    /\ MCCanFire(MC_RSM_REPLICATE)
    /\ RSMReplicatePrepare(d)
    /\ mcFaultCounter' = MCFire(MC_RSM_REPLICATE)

MCRSMReplicateCommit(d) ==
    /\ MCCanFire(MC_RSM_REPLICATE)
    /\ RSMReplicateCommit(d)
    /\ mcFaultCounter' = MCFire(MC_RSM_REPLICATE)

MCRSMReplicateDiscard(d) ==
    /\ MCCanFire(MC_RSM_REPLICATE)
    /\ RSMReplicateDiscard(d)
    /\ mcFaultCounter' = MCFire(MC_RSM_REPLICATE)

MCRSMReplicateDone(d) ==
    /\ MCCanFire(MC_RSM_REPLICATE)
    /\ RSMReplicateDone(d)
    /\ mcFaultCounter' = MCFire(MC_RSM_REPLICATE)

\* Family 2: Shard operations (reactive, not bounded)
MCShardLockOutputs(s, d) ==
    /\ ShardLockOutputs(s, d)
    /\ UNCHANGED mcFaultCounter

MCShardApplyOutputs(s, d) ==
    /\ ShardApplyOutputs(s, d)
    /\ UNCHANGED mcFaultCounter

MCShardDiscardDtx(s, d) ==
    /\ ShardDiscardDtx(s, d)
    /\ UNCHANGED mcFaultCounter

\* Family 3: Sentinel requests (bounded)
MCSentinelSubmitTx(c, tx) ==
    /\ MCCanFire(MC_SENTINEL_REQUEST)
    /\ SentinelSubmitTx(c, tx)
    /\ mcFaultCounter' = MCFire(MC_SENTINEL_REQUEST)

MCSentinelRequestToNonLeader(c, tx) ==
    /\ MCCanFire(MC_SENTINEL_NONLEADER)
    /\ SentinelRequestToNonLeader(c, tx)
    /\ mcFaultCounter' = MCFire(MC_SENTINEL_NONLEADER)

\* Family 5: Batch operations (bounded)
MCCoordAddTxToBatch(c) ==
    /\ MCCanFire(MC_BATCH_ADD)
    /\ CoordAddTxToBatch(c)
    /\ mcFaultCounter' = MCFire(MC_BATCH_ADD)

MCCoordSwapBatch(c) ==
    /\ MCCanFire(MC_BATCH_SWAP)
    /\ CoordSwapBatch(c)
    /\ mcFaultCounter' = MCFire(MC_BATCH_SWAP)

\* Family 5: Reactive batch operations (not bounded)
MCCoordScheduleExec(c) ==
    /\ CoordScheduleExec(c)
    /\ UNCHANGED mcFaultCounter

MCCoordCompleteExec(c) ==
    /\ CoordCompleteExec(c)
    /\ UNCHANGED mcFaultCounter

\* Family 4: Log growth (bounded)
MCCoordLogGrow(c) ==
    /\ MCCanFire(MC_LOG_GROW)
    /\ CoordLogGrow(c)
    /\ mcFaultCounter' = MCFire(MC_LOG_GROW)

MCShardLogGrow(s) ==
    /\ MCCanFire(MC_LOG_GROW)
    /\ ShardLogGrow(s)
    /\ mcFaultCounter' = MCFire(MC_LOG_GROW)

\* Family 6: Crash actions (bounded)
MCCoordCrash(c) ==
    /\ MCCanFire(MC_COORD_CRASH)
    /\ CoordCrash(c)
    /\ mcFaultCounter' = MCFire(MC_COORD_CRASH)

MCShardCrash(s) ==
    /\ MCCanFire(MC_SHARD_CRASH)
    /\ ShardCrash(s)
    /\ mcFaultCounter' = MCFire(MC_SHARD_CRASH)

\* Recovery actions (reactive, not bounded)
MCCoordRecoverPrepare(d) ==
    /\ CoordRecoverPrepare(d)
    /\ UNCHANGED mcFaultCounter

MCShardReplayLog(s) ==
    /\ ShardReplayLog(s)
    /\ UNCHANGED mcFaultCounter

\* ====== MCNext ======

MCNext ==
    \/ \E c \in CoordinatorNode :
        MCCoordRaftCallbackBecomeLeader(c)
        \/ MCCoordRaftCallbackBecomeFollower(c)
        \/ MCCoordActivateHandler(c)
        \/ MCCoordDeactivateHandler(c)
        \/ MCCoordAddTxToBatch(c)
        \/ MCCoordSwapBatch(c)
        \/ MCCoordScheduleExec(c)
        \/ MCCoordCompleteExec(c)
        \/ MCCoordLogGrow(c)
        \/ MCCoordCrash(c)
    \/ \E s \in ShardNode, d \in DtxId :
        MCShardRaftCallbackBecomeLeader(s)
        \/ MCShardRaftCallbackBecomeFollower(s)
        \/ MCShardLockOutputs(s, d)
        \/ MCShardApplyOutputs(s, d)
        \/ MCShardDiscardDtx(s, d)
        \/ MCShardLogGrow(s)
        \/ MCShardCrash(s)
        \/ MCShardReplayLog(s)
    \/ \E d \in DtxId :
        MCRSMReplicatePrepare(d)
        \/ MCRSMReplicateCommit(d)
        \/ MCRSMReplicateDiscard(d)
        \/ MCRSMReplicateDone(d)
        \/ MCCoordRecoverPrepare(d)
    \/ \E tx \in TxId, c \in CoordinatorNode :
        MCSentinelSubmitTx(c, tx)
        \/ MCSentinelRequestToNonLeader(c, tx)

\* ====== View ======

\* Exclude counter from symmetry reduction
MCView == <<isLeader, handlerActive, rsmPhase>>

\* ====== Structural Invariants ======

MCTypeOK == TypeOK
MCUhsConsistent == InvUhsConsistent
MCShardStateConsistent == InvShardStateConsistent
MCRSMDoneImpliesShardsDiscarded == InvRSMDoneImpliesShardsDiscarded
MCBatchConsistency == InvBatchConsistency

\* ====== Bug Family Safety Invariants ======

MCLeaderHasHandler == InvLeaderHasHandler
MCHandlerOnlyWhenLeader == InvHandlerOnlyWhenLeader
MCRSMCommitImpliesShardsLocked == InvRSMCommitImpliesShardsLocked
MCNonLeaderRejectsRequest == InvNonLeaderRejectsRequest
MCLockedNotInUhs == InvLockedNotInUhs

=============================================================================
