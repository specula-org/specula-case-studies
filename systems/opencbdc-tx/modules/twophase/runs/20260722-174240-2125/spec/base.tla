-------------------------- MODULE base --------------------------
EXTENDS Integers, FiniteSets, TLC, Sequences

CONSTANTS
    CoordinatorNode,
    ShardNode,
    DtxId,
    UhsId,
    TxId,
    BatchSize

VARIABLES
    \* === Standard Raft leadership ===
    isLeader,

    \* === Family 1: Leader/Follower Asymmetry in Handler Lifecycle ===
    \* Coordinator raft_callback sets startFlag/stopFlag (controller.cpp:112-144)
    \* start_stop_func processes flags to start/stop handler (controller.cpp:536-583)
    handlerActive,
    startFlag,
    stopFlag,

    \* === Family 2: Non-Atomic RSM State Transitions ===
    \* RSM state replicates first, then shard operations execute
    \* distributed_tx.cpp:109-145 — execute() transitions through prepare/commit/discard
    rsmPhase,
    shardLocked,
    shardApplied,
    shardDiscarded,

    \* === Family 3: Sentinel-to-Coordinator Communication ===
    \* coordinator selected by sentinel_id % coordinators.size() (sentinel_2pc/controller.cpp:21-25)
    sentinelTxs,
    requestInFlight,
    requestResult,

    \* === Family 4: Unbounded Raft Log Growth ===
    \* snapshot_distance_ = 0 (coordinator/controller.cpp:37, locking_shard/controller.cpp:46)
    logEntries,

    \* === Family 5: Batch Processing Races ===
    \* batch_set_cbs on m_current_batch after m_batch_mut released (controller.cpp:398-406)
    \* schedule_exec yield-based spin loop (controller.cpp:491-525)
    currentBatchDtx,
    batchTxCount,
    execBusy,
    batchSwapPending,

    \* === Family 6: Locking Shard In-Memory State Loss ===
    \* All state in unordered_set/unordered_map (locking_shard.hpp:139-144)
    \* Snapshot restore returns false (state_machine.cpp:56-58)
    uhsExists,
    lockedUhs

\* ====== Type Definitions ======

Node == CoordinatorNode \cup ShardNode

DtxStatus == {"none", "prepare", "commit", "discard", "done", "failed"}

NULL == "<none>"

\* ====== Type Invariant ======

TypeOK ==
    /\ isLeader      \in [Node -> BOOLEAN]
    /\ handlerActive \in [Node -> BOOLEAN]
    /\ startFlag     \in [CoordinatorNode -> BOOLEAN]
    /\ stopFlag      \in [CoordinatorNode -> BOOLEAN]
    /\ rsmPhase      \in [DtxId -> DtxStatus]
    /\ shardLocked   \in [ShardNode \times DtxId -> BOOLEAN]
    /\ shardApplied  \in [ShardNode \times DtxId -> BOOLEAN]
    /\ shardDiscarded \in [ShardNode \times DtxId -> BOOLEAN]
    /\ sentinelTxs   \in [TxId -> BOOLEAN]
    /\ requestInFlight \in [CoordinatorNode -> BOOLEAN]
    /\ requestResult \in [CoordinatorNode -> BOOLEAN]
    /\ logEntries    \in [Node -> Nat]
    /\ currentBatchDtx \in [CoordinatorNode -> DtxId \cup {NULL}]
    /\ batchTxCount  \in [CoordinatorNode -> 0..BatchSize]
    /\ execBusy      \in [CoordinatorNode -> BOOLEAN]
    /\ batchSwapPending \in [CoordinatorNode -> BOOLEAN]
    /\ uhsExists     \in [UhsId -> BOOLEAN]
    /\ lockedUhs     \in [UhsId -> BOOLEAN]

\* ====== Structural Invariants ======

\* No UTXO can be both present and locked simultaneously
InvUhsConsistent ==
    \A u \in UhsId : ~(uhsExists[u] /\ lockedUhs[u])

\* A dtx cannot be in multiple final shard states on the same shard
InvShardStateConsistent ==
    \A s \in ShardNode, d \in DtxId :
        ~(shardLocked[s, d] /\ shardApplied[s, d])
        /\ ~(shardApplied[s, d] /\ shardDiscarded[s, d])
        /\ ~(shardLocked[s, d] /\ shardDiscarded[s, d])

\* If RSM believes dtx is done, all shards must have discarded
InvRSMDoneImpliesShardsDiscarded ==
    \A d \in DtxId :
        rsmPhase[d] = "done"
            => \A s \in ShardNode : shardDiscarded[s, d]

\* ====== Bug Family Safety Invariants ======

\* Family 1: Leader must have active handler (no gap where leader can't process)
InvLeaderHasHandler ==
    \A n \in Node : isLeader[n] => handlerActive[n]

\* Family 1: Handler must only be active on leader (no stale handler)
InvHandlerOnlyWhenLeader ==
    \A n \in Node : handlerActive[n] => isLeader[n]

\* Family 2: RSM commit implies all shards have locked
InvRSMCommitImpliesShardsLocked ==
    \A d \in DtxId :
        rsmPhase[d] = "commit"
            => \A s \in ShardNode : shardLocked[s, d]

\* Family 3: Non-leader coordinators must not have requests in flight
InvNonLeaderRejectsRequest ==
    \A c \in CoordinatorNode :
        requestInFlight[c] => isLeader[c]

\* Family 5: Batch tx count must not exceed BatchSize
InvBatchConsistency ==
    \A c \in CoordinatorNode : batchTxCount[c] <= BatchSize

\* Family 6: Locked UTXOs must not be in the UHS set
InvLockedNotInUhs ==
    \A u \in UhsId : lockedUhs[u] => ~uhsExists[u]

\* ====== Helper Definitions ======

\* Helper: increment log entries for all coordinator nodes
IncCoordLogEntries == [n \in Node |-> 
    IF n \in CoordinatorNode THEN logEntries[n] + 1 ELSE logEntries[n]]

\* Helper: increment log entries for a specific shard node
IncShardLogEntries(s) == [n \in Node |-> 
    IF n = s THEN logEntries[n] + 1 ELSE logEntries[n]]

\* Helper: increment log entries for all nodes
IncAllLogEntries == [n \in Node |-> logEntries[n] + 1]

\* ====== Fault Actions ======

\* ---- Family 1: Leadership and Handler Actions ----

\* Coordinator raft_callback: BecomeLeader (controller.cpp:112-130)
\* Sets startFlag, defers actual handler start to start_stop_func
CoordRaftCallbackBecomeLeader(c) ==
    /\ c \in CoordinatorNode
    /\ isLeader[c] = FALSE
    /\ isLeader' = [isLeader EXCEPT ![c] = TRUE]
    /\ startFlag' = [startFlag EXCEPT ![c] = TRUE]
    /\ stopFlag' = [stopFlag EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<handlerActive, rsmPhase, shardLocked, shardApplied,
                    shardDiscarded, sentinelTxs, requestInFlight, requestResult,
                    logEntries, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>

\* Coordinator raft_callback: BecomeFollower (controller.cpp:131-141)
\* Sets stopFlag, defers actual handler stop to start_stop_func
CoordRaftCallbackBecomeFollower(c) ==
    /\ c \in CoordinatorNode
    /\ isLeader[c] = TRUE
    /\ isLeader' = [isLeader EXCEPT ![c] = FALSE]
    /\ startFlag' = [startFlag EXCEPT ![c] = FALSE]
    /\ stopFlag' = [stopFlag EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<handlerActive, rsmPhase, shardLocked, shardApplied,
                    shardDiscarded, sentinelTxs, requestInFlight, requestResult,
                    logEntries, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>

\* start_stop_func processes start flag: activates handler (controller.cpp:572-581)
\* Calls stop() then start(), allocates new batch
CoordActivateHandler(c) ==
    /\ c \in CoordinatorNode
    /\ isLeader[c]
    /\ startFlag[c]
    /\ startFlag' = [startFlag EXCEPT ![c] = FALSE]
    /\ handlerActive' = [handlerActive EXCEPT ![c] = TRUE]
    \* start() allocates new batch (controller.cpp:619-641)
    /\ currentBatchDtx' = [currentBatchDtx EXCEPT ![c]
                                = CHOOSE d \in DtxId : TRUE]
    /\ batchTxCount' = [batchTxCount EXCEPT ![c] = 0]
    /\ UNCHANGED <<isLeader, stopFlag, rsmPhase, shardLocked, shardApplied,
                    shardDiscarded, sentinelTxs, requestInFlight, requestResult,
                    logEntries, execBusy, batchSwapPending, uhsExists, lockedUhs>>

\* start_stop_func processes stop flag: deactivates handler (controller.cpp:564-571)
\* Calls stop() which joins threads and clears state
CoordDeactivateHandler(c) ==
    /\ c \in CoordinatorNode
    /\ ~isLeader[c]
    /\ stopFlag[c]
    /\ stopFlag' = [stopFlag EXCEPT ![c] = FALSE]
    /\ handlerActive' = [handlerActive EXCEPT ![c] = FALSE]
    \* stop() clears batch and joins exec threads (controller.cpp:182-217)
    /\ currentBatchDtx' = [currentBatchDtx EXCEPT ![c] = NULL]
    /\ batchTxCount' = [batchTxCount EXCEPT ![c] = 0]
    /\ execBusy' = [execBusy EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<isLeader, startFlag, rsmPhase, shardLocked, shardApplied,
                    shardDiscarded, sentinelTxs, requestInFlight, requestResult,
                    logEntries, batchSwapPending, uhsExists, lockedUhs>>

\* ---- Family 1 (Shard): Locking shard raft_callback ----

\* Locking shard raft_callback: BecomeLeader (controller.cpp:122-131)
\* Directly starts RPC server — different pattern from coordinator
ShardRaftCallbackBecomeLeader(s) ==
    /\ s \in ShardNode
    /\ isLeader[s] = FALSE
    /\ isLeader' = [isLeader EXCEPT ![s] = TRUE]
    \* Directly starts handler (controller.cpp:124-129)
    /\ handlerActive' = [handlerActive EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<startFlag, stopFlag, rsmPhase, shardLocked, shardApplied,
                    shardDiscarded, sentinelTxs, requestInFlight, requestResult,
                    logEntries, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>

\* Locking shard raft_callback: BecomeFollower (controller.cpp:117-120)
\* Directly stops handler
ShardRaftCallbackBecomeFollower(s) ==
    /\ s \in ShardNode
    /\ isLeader[s] = TRUE
    /\ isLeader' = [isLeader EXCEPT ![s] = FALSE]
    \* Directly stops handler (controller.cpp:119: m_server.reset())
    /\ handlerActive' = [handlerActive EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<startFlag, stopFlag, rsmPhase, shardLocked, shardApplied,
                    shardDiscarded, sentinelTxs, requestInFlight, requestResult,
                    logEntries, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>

\* ---- Family 2: 2PC RSM and Shard Operations ----

\* RSM replicate prepare (distributed_tx.cpp:24-30, prepare_cb at controller.cpp:146-155)
\* prepare_cb called BEFORE shard lock operations
RSMReplicatePrepare(d) ==
    /\ d \in DtxId
    /\ rsmPhase[d] = "none"
    /\ rsmPhase' = [rsmPhase EXCEPT ![d] = "prepare"]
    /\ logEntries' = IncCoordLogEntries
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, shardLocked,
                    shardApplied, shardDiscarded, sentinelTxs, requestInFlight,
                    requestResult, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>

\* Shard executes lock_outputs (locking_shard.cpp:78-102)
\* Called by std::async during prepare phase (distributed_tx.cpp:31-45)
ShardLockOutputs(s, d) ==
    /\ s \in ShardNode
    /\ d \in DtxId
    /\ isLeader[s]
    /\ handlerActive[s]
    /\ rsmPhase[d] = "prepare"
    /\ shardLocked[s, d] = FALSE
    \* Moves UTXOs from uhsSet to lockedSet (locking_shard.cpp:123-131)
    /\ \E u \in UhsId :
        uhsExists[u]
        /\ ~lockedUhs[u]
        /\ uhsExists' = [uhsExists EXCEPT ![u] = FALSE]
        /\ lockedUhs' = [lockedUhs EXCEPT ![u] = TRUE]
    /\ shardLocked' = [shardLocked EXCEPT ![s, d] = TRUE]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardApplied, shardDiscarded, sentinelTxs, requestInFlight,
                    requestResult, logEntries, currentBatchDtx, batchTxCount,
                    execBusy, batchSwapPending>>

\* RSM replicate commit (distributed_tx.cpp:74-80, commit_cb at controller.cpp:157-168)
\* commit_cb called BEFORE shard apply operations
RSMReplicateCommit(d) ==
    /\ d \in DtxId
    /\ rsmPhase[d] = "prepare"
    /\ rsmPhase' = [rsmPhase EXCEPT ![d] = "commit"]
    /\ logEntries' = IncCoordLogEntries
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, shardLocked,
                    shardApplied, shardDiscarded, sentinelTxs, requestInFlight,
                    requestResult, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>

\* Shard executes apply_outputs (locking_shard.cpp:135-182)
\* Called during commit phase (distributed_tx.cpp:81-97)
ShardApplyOutputs(s, d) ==
    /\ s \in ShardNode
    /\ d \in DtxId
    /\ isLeader[s]
    /\ handlerActive[s]
    /\ rsmPhase[d] = "commit"
    /\ shardLocked[s, d]
    /\ shardApplied[s, d] = FALSE
    \* apply_outputs: unlocks inputs, adds outputs to uhsSet (locking_shard.cpp:158-177)
    /\ \E u \in {CHOOSE u \in UhsId : lockedUhs[u]} :
        lockedUhs' = [lockedUhs EXCEPT ![u] = FALSE]
        /\ uhsExists' = [uhsExists EXCEPT ![u] = TRUE]
    /\ shardApplied' = [shardApplied EXCEPT ![s, d] = TRUE]
    /\ shardLocked' = [shardLocked EXCEPT ![s, d] = FALSE]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardDiscarded, sentinelTxs, requestInFlight,
                    requestResult, logEntries, currentBatchDtx, batchTxCount,
                    execBusy, batchSwapPending>>

\* RSM replicate discard (distributed_tx.cpp:180-187, discard_cb at controller.cpp:170-174)
RSMReplicateDiscard(d) ==
    /\ d \in DtxId
    /\ rsmPhase[d] = "commit"
    /\ rsmPhase' = [rsmPhase EXCEPT ![d] = "discard"]
    /\ logEntries' = IncCoordLogEntries
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, shardLocked,
                    shardApplied, shardDiscarded, sentinelTxs, requestInFlight,
                    requestResult, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>

\* Shard executes discard_dtx (locking_shard.cpp:15-22)
\* Called during discard phase (distributed_tx.cpp:188-199)
ShardDiscardDtx(s, d) ==
    /\ s \in ShardNode
    /\ d \in DtxId
    /\ isLeader[s]
    /\ handlerActive[s]
    /\ rsmPhase[d] = "discard"
    /\ shardApplied[s, d]
    /\ shardDiscarded[s, d] = FALSE
    \* discard_dtx erases dtx from applied set (locking_shard.cpp:19)
    /\ shardDiscarded' = [shardDiscarded EXCEPT ![s, d] = TRUE]
    /\ shardApplied' = [shardApplied EXCEPT ![s, d] = FALSE]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, sentinelTxs, requestInFlight,
                    requestResult, logEntries, currentBatchDtx, batchTxCount,
                    execBusy, batchSwapPending, uhsExists, lockedUhs>>

\* RSM replicate done (distributed_tx.cpp:207-212, done_cb at controller.cpp:176-180)
RSMReplicateDone(d) ==
    /\ d \in DtxId
    /\ rsmPhase[d] = "discard"
    /\ \A s \in ShardNode : shardDiscarded[s, d]
    /\ rsmPhase' = [rsmPhase EXCEPT ![d] = "done"]
    /\ logEntries' = IncCoordLogEntries
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, shardLocked,
                    shardApplied, shardDiscarded, sentinelTxs, requestInFlight,
                    requestResult, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>

\* ---- Family 3: Sentinel Communication ----

\* Sentinel submits transaction to coordinator (sentinel_2pc/controller.cpp:98-125)
\* send_compact_tx retries infinitely (controller.cpp:210-227)
SentinelSubmitTx(c, tx) ==
    /\ c \in CoordinatorNode
    /\ tx \in TxId
    /\ ~sentinelTxs[tx]
    \* execute_transaction checks is_leader() (controller.cpp:688)
    /\ isLeader[c]
    /\ sentinelTxs' = [sentinelTxs EXCEPT ![tx] = TRUE]
    /\ requestInFlight' = [requestInFlight EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase, shardLocked,
                    shardApplied, shardDiscarded, requestResult, logEntries,
                    currentBatchDtx, batchTxCount, execBusy, batchSwapPending,
                    uhsExists, lockedUhs>>

\* Sentinel request to non-leader is dropped (controller.cpp:688-690)
\* is_leader() returns false, execute_transaction returns false
SentinelRequestToNonLeader(c, tx) ==
    /\ c \in CoordinatorNode
    /\ tx \in TxId
    /\ ~sentinelTxs[tx]
    /\ ~isLeader[c]
    \* Request silently dropped, sentinel retries (controller.cpp:219)
    /\ sentinelTxs' = [sentinelTxs EXCEPT ![tx] = TRUE]
    \* No requestInFlight since non-leader immediately rejected
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase, shardLocked,
                    shardApplied, shardDiscarded, requestInFlight, requestResult,
                    logEntries, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>

\* ---- Family 5: Batch Processing ----

\* execute_transaction adds tx to current batch (controller.cpp:684-731)
\* Checks m_current_txs->size() < m_batch_size (controller.cpp:704-706)
CoordAddTxToBatch(c) ==
    /\ c \in CoordinatorNode
    /\ isLeader[c]
    /\ handlerActive[c]
    /\ currentBatchDtx[c] /= NULL
    /\ batchTxCount[c] < BatchSize
    \* Adds tx to batch (controller.cpp:716)
    /\ batchTxCount' = [batchTxCount EXCEPT ![c] = batchTxCount[c] + 1]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, logEntries, currentBatchDtx,
                    execBusy, batchSwapPending, uhsExists, lockedUhs>>

\* batch_executor_func swaps batch (controller.cpp:364-458)
\* batch_set_cbs called on new batch after batch_mut released (controller.cpp:398-406)
CoordSwapBatch(c) ==
    /\ c \in CoordinatorNode
    /\ isLeader[c]
    /\ handlerActive[c]
    /\ batchTxCount[c] > 0
    /\ batchSwapPending[c] = FALSE
    \* Swap occurs under m_batch_mut (controller.cpp:399-406)
    \* Creates new batch and atomically swaps
    /\ batchSwapPending' = [batchSwapPending EXCEPT ![c] = TRUE]
    /\ currentBatchDtx' = [currentBatchDtx EXCEPT ![c]
                                = CHOOSE d \in DtxId : TRUE]
    /\ batchTxCount' = [batchTxCount EXCEPT ![c] = 0]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, logEntries, execBusy,
                    uhsExists, lockedUhs>>

\* schedule_exec starts execution of swapped batch (controller.cpp:491-525)
\* Uses yield-based spin loop (controller.cpp:518-522)
CoordScheduleExec(c) ==
    /\ c \in CoordinatorNode
    /\ batchSwapPending[c]
    /\ execBusy[c] = FALSE
    /\ execBusy' = [execBusy EXCEPT ![c] = TRUE]
    /\ batchSwapPending' = [batchSwapPending EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, logEntries, currentBatchDtx,
                    batchTxCount, uhsExists, lockedUhs>>

\* Executor thread completes (controller.cpp:448-452)
CoordCompleteExec(c) ==
    /\ c \in CoordinatorNode
    /\ execBusy[c] = TRUE
    /\ execBusy' = [execBusy EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, logEntries, currentBatchDtx,
                    batchTxCount, batchSwapPending, uhsExists, lockedUhs>>

\* ---- Family 4: Raft Log Growth ----

\* Snapshot not implemented: log grows unbounded (coordinator/controller.cpp:37)
\* apply_snapshot returns false (state_machine.cpp:101-104)
CoordLogGrow(c) ==
    /\ c \in CoordinatorNode
    /\ logEntries' = IncCoordLogEntries
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, currentBatchDtx, batchTxCount,
                    execBusy, batchSwapPending, uhsExists, lockedUhs>>

\* Shard log also grows unbounded (locking_shard/controller.cpp:46)
ShardLogGrow(s) ==
    /\ s \in ShardNode
    /\ logEntries' = IncShardLogEntries(s)
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, currentBatchDtx, batchTxCount,
                    execBusy, batchSwapPending, uhsExists, lockedUhs>>

\* ---- Family 6: Locking Shard Crash/Recovery ----

\* Locking shard crashes: all in-memory state lost (locking_shard.hpp:139-144)
\* No persistence, snapshot restore returns false (state_machine.cpp:56-58)
ShardCrash(s) ==
    /\ s \in ShardNode
    \* All in-memory state reset
    /\ uhsExists' = [u \in UhsId |-> FALSE]
    /\ lockedUhs' = [u \in UhsId |-> FALSE]
    \* Shard-specific dtx state reset
    /\ shardLocked' = [sd \in ShardNode \times DtxId |-> FALSE]
    /\ shardApplied' = [sd \in ShardNode \times DtxId |-> FALSE]
    /\ shardDiscarded' = [sd \in ShardNode \times DtxId |-> FALSE]
    /\ isLeader' = [isLeader EXCEPT ![s] = FALSE]
    /\ handlerActive' = [handlerActive EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<startFlag, stopFlag, rsmPhase, sentinelTxs, requestInFlight,
                    requestResult, logEntries, currentBatchDtx, batchTxCount,
                    execBusy, batchSwapPending>>

\* Coordinator crash: in-memory batch state lost (coordinator/controller.cpp)
\* RSM state survives via Raft log (recovery_func at controller.cpp:219-329)
CoordCrash(c) ==
    /\ c \in CoordinatorNode
    \* In-memory batch state lost
    /\ currentBatchDtx' = [currentBatchDtx EXCEPT ![c] = NULL]
    /\ batchTxCount' = [batchTxCount EXCEPT ![c] = 0]
    /\ execBusy' = [execBusy EXCEPT ![c] = FALSE]
    /\ batchSwapPending' = [batchSwapPending EXCEPT ![c] = FALSE]
    /\ handlerActive' = [handlerActive EXCEPT ![c] = FALSE]
    /\ isLeader' = [isLeader EXCEPT ![c] = FALSE]
    /\ requestInFlight' = [requestInFlight EXCEPT ![c] = FALSE]
    /\ startFlag' = [startFlag EXCEPT ![c] = FALSE]
    /\ stopFlag' = [stopFlag EXCEPT ![c] = FALSE]
    \* RSM state (rsmPhase) survives via Raft log replication
    /\ UNCHANGED <<rsmPhase, shardLocked, shardApplied, shardDiscarded,
                    sentinelTxs, requestResult, logEntries, uhsExists, lockedUhs>>

\* ---- Recovery Actions ----

\* Coordinator recovery: re-reads rsmState from Raft log (controller.cpp:219-329)
\* For each dtx in prepare/commit/discard, creates reconstructor and executes
CoordRecoverPrepare(d) ==
    /\ d \in DtxId
    /\ rsmPhase[d] = "prepare"
    /\ \E c \in CoordinatorNode :
        isLeader[c] /\ handlerActive[c] /\ ~execBusy[c]
    \* recovery_func reconstructs dtx and re-executes from prepare
    \* Re-issues lock_outputs to shards (controller.cpp:253-260)
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, logEntries, currentBatchDtx,
                    batchTxCount, execBusy, batchSwapPending, uhsExists, lockedUhs>>

\* Shard replay recovery: replays Raft log from beginning (controller.cpp:46)
\* Since no snapshots, must replay from start of log
ShardReplayLog(s) ==
    /\ s \in ShardNode
    \* Shard replays Raft log to reconstruct in-memory state
    \* This is an abstract recovery — actual state reconstruction depends on log content
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, logEntries, currentBatchDtx,
                    batchTxCount, execBusy, batchSwapPending, uhsExists, lockedUhs>>

\* ====== Init ======

Init ==
    /\ isLeader      = [n \in Node |-> FALSE]
    /\ handlerActive = [n \in Node |-> FALSE]
    /\ startFlag     = [c \in CoordinatorNode |-> FALSE]
    /\ stopFlag      = [c \in CoordinatorNode |-> FALSE]
    /\ rsmPhase      = [d \in DtxId |-> "none"]
    /\ shardLocked   = [sd \in ShardNode \times DtxId |-> FALSE]
    /\ shardApplied  = [sd \in ShardNode \times DtxId |-> FALSE]
    /\ shardDiscarded = [sd \in ShardNode \times DtxId |-> FALSE]
    /\ sentinelTxs   = [tx \in TxId |-> FALSE]
    /\ requestInFlight = [c \in CoordinatorNode |-> FALSE]
    /\ requestResult = [c \in CoordinatorNode |-> FALSE]
    /\ logEntries    = [n \in Node |-> 0]
    /\ currentBatchDtx = [c \in CoordinatorNode |-> NULL]
    /\ batchTxCount  = [c \in CoordinatorNode |-> 0]
    /\ execBusy      = [c \in CoordinatorNode |-> FALSE]
    /\ batchSwapPending = [c \in CoordinatorNode |-> FALSE]
    /\ uhsExists     = [u \in UhsId |-> TRUE]
    /\ lockedUhs     = [u \in UhsId |-> FALSE]

\* ====== Next ======

Next ==
    \/ \E c \in CoordinatorNode :
        CoordRaftCallbackBecomeLeader(c)
        \/ CoordRaftCallbackBecomeFollower(c)
        \/ CoordActivateHandler(c)
        \/ CoordDeactivateHandler(c)
        \/ CoordAddTxToBatch(c)
        \/ CoordSwapBatch(c)
        \/ CoordScheduleExec(c)
        \/ CoordCompleteExec(c)
        \/ CoordLogGrow(c)
        \/ CoordCrash(c)
    \/ \E s \in ShardNode, d \in DtxId :
        ShardRaftCallbackBecomeLeader(s)
        \/ ShardRaftCallbackBecomeFollower(s)
        \/ ShardLockOutputs(s, d)
        \/ ShardApplyOutputs(s, d)
        \/ ShardDiscardDtx(s, d)
        \/ ShardLogGrow(s)
        \/ ShardCrash(s)
        \/ ShardReplayLog(s)
    \/ \E d \in DtxId :
        RSMReplicatePrepare(d)
        \/ RSMReplicateCommit(d)
        \/ RSMReplicateDiscard(d)
        \/ RSMReplicateDone(d)
        \/ CoordRecoverPrepare(d)
    \/ \E tx \in TxId, c \in CoordinatorNode :
        SentinelSubmitTx(c, tx)
        \/ SentinelRequestToNonLeader(c, tx)

=============================================================================
