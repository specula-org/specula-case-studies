-------------------------- MODULE Trace --------------------------
EXTENDS Integers, FiniteSets, TLC, Sequences, Json

CONSTANTS
    CoordinatorNode, ShardNode, DtxId, UhsId, TxId, BatchSize, TracePath

VARIABLES
    isLeader, handlerActive, startFlag, stopFlag,
    rsmPhase, shardLocked, shardApplied, shardDiscarded,
    sentinelTxs, requestInFlight, requestResult,
    logEntries, currentBatchDtx, batchTxCount, execBusy, batchSwapPending,
    uhsExists, lockedUhs, l

Node == CoordinatorNode \cup ShardNode
DtxStatus == {"none", "prepare", "commit", "discard", "done", "failed"}
NULL == "<none>"

IncCoordLogEntries == [n \in Node |-> 
    IF n \in CoordinatorNode THEN logEntries[n] + 1 ELSE logEntries[n]]

IncShardLogEntries(s) == [n \in Node |-> 
    IF n = s THEN logEntries[n] + 1 ELSE logEntries[n]]

Init ==
    /\ isLeader = [n \in Node |-> FALSE]
    /\ handlerActive = [n \in Node |-> FALSE]
    /\ startFlag = [c \in CoordinatorNode |-> FALSE]
    /\ stopFlag = [c \in CoordinatorNode |-> FALSE]
    /\ rsmPhase = [d \in DtxId |-> "none"]
    /\ shardLocked = [sd \in ShardNode \times DtxId |-> FALSE]
    /\ shardApplied = [sd \in ShardNode \times DtxId |-> FALSE]
    /\ shardDiscarded = [sd \in ShardNode \times DtxId |-> FALSE]
    /\ sentinelTxs = [tx \in TxId |-> FALSE]
    /\ requestInFlight = [c \in CoordinatorNode |-> FALSE]
    /\ requestResult = [c \in CoordinatorNode |-> FALSE]
    /\ logEntries = [n \in Node |-> 0]
    /\ currentBatchDtx = [c \in CoordinatorNode |-> NULL]
    /\ batchTxCount = [c \in CoordinatorNode |-> 0]
    /\ execBusy = [c \in CoordinatorNode |-> FALSE]
    /\ batchSwapPending = [c \in CoordinatorNode |-> FALSE]
    /\ uhsExists = [u \in UhsId |-> TRUE]
    /\ lockedUhs = [u \in UhsId |-> FALSE]
    /\ l = 2

TraceLog == ndJsonDeserialize(TracePath)

\* ====== Event Predicates ======

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event.name = name

IsNodeEvent(name, n) ==
    /\ IsEvent(name)
    /\ TraceLog[l].event.nid = n

\* ====== Base Actions (inlined in wrappers to avoid TLC sub-action issue) ======

\* ====== Trace Wrappers ======

TraceCoordBecomeLeader(c) ==
    /\ IsNodeEvent("CoordRaftCallbackBecomeLeader", c)
    /\ isLeader[c] = FALSE
    /\ isLeader' = [isLeader EXCEPT ![c] = TRUE]
    /\ startFlag' = [startFlag EXCEPT ![c] = TRUE]
    /\ stopFlag' = [stopFlag EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<handlerActive, rsmPhase, shardLocked, shardApplied,
                    shardDiscarded, sentinelTxs, requestInFlight, requestResult,
                    logEntries, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceCoordBecomeFollower(c) ==
    /\ IsNodeEvent("CoordRaftCallbackBecomeFollower", c)
    /\ isLeader[c] = TRUE
    /\ isLeader' = [isLeader EXCEPT ![c] = FALSE]
    /\ startFlag' = [startFlag EXCEPT ![c] = FALSE]
    /\ stopFlag' = [stopFlag EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<handlerActive, rsmPhase, shardLocked, shardApplied,
                    shardDiscarded, sentinelTxs, requestInFlight, requestResult,
                    logEntries, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceCoordActivateHandler(c) ==
    /\ IsNodeEvent("CoordActivateHandler", c)
    /\ isLeader[c]
    /\ startFlag[c]
    /\ startFlag' = [startFlag EXCEPT ![c] = FALSE]
    /\ handlerActive' = [handlerActive EXCEPT ![c] = TRUE]
    /\ currentBatchDtx' = [currentBatchDtx EXCEPT ![c]
                                = CHOOSE d \in DtxId : TRUE]
    /\ batchTxCount' = [batchTxCount EXCEPT ![c] = 0]
    /\ UNCHANGED <<isLeader, stopFlag, rsmPhase, shardLocked, shardApplied,
                    shardDiscarded, sentinelTxs, requestInFlight, requestResult,
                    logEntries, execBusy, batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceCoordDeactivateHandler(c) ==
    /\ IsNodeEvent("CoordDeactivateHandler", c)
    /\ ~isLeader[c]
    /\ stopFlag[c]
    /\ stopFlag' = [stopFlag EXCEPT ![c] = FALSE]
    /\ handlerActive' = [handlerActive EXCEPT ![c] = FALSE]
    /\ currentBatchDtx' = [currentBatchDtx EXCEPT ![c] = NULL]
    /\ batchTxCount' = [batchTxCount EXCEPT ![c] = 0]
    /\ execBusy' = [execBusy EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<isLeader, startFlag, rsmPhase, shardLocked, shardApplied,
                    shardDiscarded, sentinelTxs, requestInFlight, requestResult,
                    logEntries, batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceShardBecomeLeader(s) ==
    /\ IsNodeEvent("ShardRaftCallbackBecomeLeader", s)
    /\ isLeader[s] = FALSE
    /\ isLeader' = [isLeader EXCEPT ![s] = TRUE]
    /\ handlerActive' = [handlerActive EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<startFlag, stopFlag, rsmPhase, shardLocked, shardApplied,
                    shardDiscarded, sentinelTxs, requestInFlight, requestResult,
                    logEntries, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceShardBecomeFollower(s) ==
    /\ IsNodeEvent("ShardRaftCallbackBecomeFollower", s)
    /\ isLeader[s] = TRUE
    /\ isLeader' = [isLeader EXCEPT ![s] = FALSE]
    /\ handlerActive' = [handlerActive EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<startFlag, stopFlag, rsmPhase, shardLocked, shardApplied,
                    shardDiscarded, sentinelTxs, requestInFlight, requestResult,
                    logEntries, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceRSMReplicatePrepare(d) ==
    /\ IsEvent("RSMReplicatePrepare")
    /\ TraceLog[l].event.dtx_id = d
    /\ rsmPhase[d] = "none"
    /\ rsmPhase' = [rsmPhase EXCEPT ![d] = "prepare"]
    /\ logEntries' = IncCoordLogEntries
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, shardLocked,
                    shardApplied, shardDiscarded, sentinelTxs, requestInFlight,
                    requestResult, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceShardLockOutputs(s, d) ==
    /\ IsNodeEvent("ShardLockOutputs", s)
    /\ TraceLog[l].event.dtx_id = d
    /\ isLeader[s]
    /\ handlerActive[s]
    /\ rsmPhase[d] = "prepare"
    /\ shardLocked[s, d] = FALSE
    /\ {u \in UhsId : uhsExists[u] /\ ~lockedUhs[u]} /= {}
    /\ \E u \in {CHOOSE u \in UhsId : uhsExists[u] /\ ~lockedUhs[u]} :
        uhsExists' = [uhsExists EXCEPT ![u] = FALSE]
        /\ lockedUhs' = [lockedUhs EXCEPT ![u] = TRUE]
    /\ shardLocked' = [shardLocked EXCEPT ![s, d] = TRUE]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardApplied, shardDiscarded, sentinelTxs, requestInFlight,
                    requestResult, logEntries, currentBatchDtx, batchTxCount,
                    execBusy, batchSwapPending>>
    /\ l' = l + 1

TraceRSMReplicateCommit(d) ==
    /\ IsEvent("RSMReplicateCommit")
    /\ TraceLog[l].event.dtx_id = d
    /\ rsmPhase[d] = "prepare"
    /\ rsmPhase' = [rsmPhase EXCEPT ![d] = "commit"]
    /\ logEntries' = IncCoordLogEntries
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, shardLocked,
                    shardApplied, shardDiscarded, sentinelTxs, requestInFlight,
                    requestResult, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceShardApplyOutputs(s, d) ==
    /\ IsNodeEvent("ShardApplyOutputs", s)
    /\ TraceLog[l].event.dtx_id = d
    /\ isLeader[s]
    /\ handlerActive[s]
    /\ rsmPhase[d] = "commit"
    /\ shardLocked[s, d]
    /\ shardApplied[s, d] = FALSE
    \* apply_outputs: unlocks inputs, adds outputs to uhsSet (locking_shard.cpp:158-177)
    /\ {u \in UhsId : lockedUhs[u]} /= {}
    /\ \E u \in {CHOOSE u \in UhsId : lockedUhs[u]} :
        lockedUhs' = [lockedUhs EXCEPT ![u] = FALSE]
        /\ uhsExists' = [uhsExists EXCEPT ![u] = TRUE]
    /\ shardApplied' = [shardApplied EXCEPT ![s, d] = TRUE]
    \* apply_outputs releases the lock (locking_shard.cpp:158-177)
    /\ shardLocked' = [shardLocked EXCEPT ![s, d] = FALSE]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardDiscarded, sentinelTxs, requestInFlight,
                    requestResult, logEntries, currentBatchDtx, batchTxCount,
                    execBusy, batchSwapPending>>
    /\ l' = l + 1

TraceRSMReplicateDiscard(d) ==
    /\ IsEvent("RSMReplicateDiscard")
    /\ TraceLog[l].event.dtx_id = d
    /\ rsmPhase[d] = "commit"
    /\ rsmPhase' = [rsmPhase EXCEPT ![d] = "discard"]
    /\ logEntries' = IncCoordLogEntries
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, shardLocked,
                    shardApplied, shardDiscarded, sentinelTxs, requestInFlight,
                    requestResult, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceShardDiscardDtx(s, d) ==
    /\ IsNodeEvent("ShardDiscardDtx", s)
    /\ TraceLog[l].event.dtx_id = d
    /\ isLeader[s]
    /\ handlerActive[s]
    /\ rsmPhase[d] = "discard"
    /\ shardApplied[s, d]
    /\ shardDiscarded[s, d] = FALSE
    /\ shardDiscarded' = [shardDiscarded EXCEPT ![s, d] = TRUE]
    \* discard_dtx erases dtx from m_applied_dtxs (locking_shard.cpp:19)
    /\ shardApplied' = [shardApplied EXCEPT ![s, d] = FALSE]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, sentinelTxs, requestInFlight,
                    requestResult, logEntries, currentBatchDtx, batchTxCount,
                    execBusy, batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceRSMReplicateDone(d) ==
    /\ IsEvent("RSMReplicateDone")
    /\ TraceLog[l].event.dtx_id = d
    /\ rsmPhase[d] = "discard"
    /\ \A s \in ShardNode : shardDiscarded[s, d]
    /\ rsmPhase' = [rsmPhase EXCEPT ![d] = "done"]
    /\ logEntries' = IncCoordLogEntries
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, shardLocked,
                    shardApplied, shardDiscarded, sentinelTxs, requestInFlight,
                    requestResult, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceSentinelSubmitTx(c, tx) ==
    /\ IsEvent("SentinelSubmitTx")
    /\ TraceLog[l].event.tx_id = tx
    /\ ~sentinelTxs[tx]
    /\ isLeader[c]
    /\ sentinelTxs' = [sentinelTxs EXCEPT ![tx] = TRUE]
    /\ requestInFlight' = [requestInFlight EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase, shardLocked,
                    shardApplied, shardDiscarded, requestResult, logEntries,
                    currentBatchDtx, batchTxCount, execBusy, batchSwapPending,
                    uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceSentinelRequestToNonLeader(c, tx) ==
    /\ IsEvent("SentinelRequestToNonLeader")
    /\ TraceLog[l].event.tx_id = tx
    /\ ~sentinelTxs[tx]
    /\ ~isLeader[c]
    /\ sentinelTxs' = [sentinelTxs EXCEPT ![tx] = TRUE]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase, shardLocked,
                    shardApplied, shardDiscarded, requestInFlight, requestResult,
                    logEntries, currentBatchDtx, batchTxCount, execBusy,
                    batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceCoordAddTxToBatch(c) ==
    /\ IsNodeEvent("CoordAddTxToBatch", c)
    /\ isLeader[c]
    /\ handlerActive[c]
    /\ currentBatchDtx[c] /= NULL
    /\ batchTxCount[c] < BatchSize
    /\ batchTxCount' = [batchTxCount EXCEPT ![c] = batchTxCount[c] + 1]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, logEntries, currentBatchDtx,
                    execBusy, batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceCoordSwapBatch(c) ==
    /\ IsNodeEvent("CoordSwapBatch", c)
    /\ isLeader[c]
    /\ handlerActive[c]
    /\ batchTxCount[c] > 0
    /\ batchSwapPending[c] = FALSE
    /\ batchSwapPending' = [batchSwapPending EXCEPT ![c] = TRUE]
    /\ currentBatchDtx' = [currentBatchDtx EXCEPT ![c]
                                = CHOOSE d \in DtxId : TRUE]
    /\ batchTxCount' = [batchTxCount EXCEPT ![c] = 0]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, logEntries, execBusy,
                    uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceCoordScheduleExec(c) ==
    /\ IsNodeEvent("CoordScheduleExec", c)
    /\ batchSwapPending[c]
    /\ execBusy[c] = FALSE
    /\ execBusy' = [execBusy EXCEPT ![c] = TRUE]
    /\ batchSwapPending' = [batchSwapPending EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, logEntries, currentBatchDtx,
                    batchTxCount, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceCoordCompleteExec(c) ==
    /\ IsNodeEvent("CoordCompleteExec", c)
    /\ execBusy[c] = TRUE
    /\ execBusy' = [execBusy EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, logEntries, currentBatchDtx,
                    batchTxCount, batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceCoordLogGrow(c) ==
    /\ IsNodeEvent("CoordLogGrow", c)
    /\ logEntries' = IncCoordLogEntries
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, currentBatchDtx, batchTxCount,
                    execBusy, batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceShardLogGrow(s) ==
    /\ IsNodeEvent("ShardLogGrow", s)
    /\ logEntries' = IncShardLogEntries(s)
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, currentBatchDtx, batchTxCount,
                    execBusy, batchSwapPending, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceCoordCrash(c) ==
    /\ IsNodeEvent("CoordCrash", c)
    /\ currentBatchDtx' = [currentBatchDtx EXCEPT ![c] = NULL]
    /\ batchTxCount' = [batchTxCount EXCEPT ![c] = 0]
    /\ execBusy' = [execBusy EXCEPT ![c] = FALSE]
    /\ batchSwapPending' = [batchSwapPending EXCEPT ![c] = FALSE]
    /\ handlerActive' = [handlerActive EXCEPT ![c] = FALSE]
    /\ requestInFlight' = [requestInFlight EXCEPT ![c] = FALSE]
    \* CoordCrash in the trace represents stop() during handler transition,
    \* not a real process crash. isLeader persists because Raft leader state
    \* is separate from handler state. startFlag/stopFlag persist so the
    \* subsequent start() can use them. (instrumentation-spec.md §Family 6)
    /\ UNCHANGED <<isLeader, startFlag, stopFlag, rsmPhase, shardLocked,
                    shardApplied, shardDiscarded, sentinelTxs, requestResult,
                    logEntries, uhsExists, lockedUhs>>
    /\ l' = l + 1

TraceShardCrash(s) ==
    /\ IsNodeEvent("ShardCrash", s)
    /\ uhsExists' = [u \in UhsId |-> FALSE]
    /\ lockedUhs' = [u \in UhsId |-> FALSE]
    /\ shardLocked' = [sd \in ShardNode \times DtxId |-> FALSE]
    /\ shardApplied' = [sd \in ShardNode \times DtxId |-> FALSE]
    /\ shardDiscarded' = [sd \in ShardNode \times DtxId |-> FALSE]
    /\ isLeader' = [isLeader EXCEPT ![s] = FALSE]
    /\ handlerActive' = [handlerActive EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<startFlag, stopFlag, rsmPhase, sentinelTxs, requestInFlight,
                    requestResult, logEntries, currentBatchDtx, batchTxCount,
                    execBusy, batchSwapPending>>
    /\ l' = l + 1

TraceCoordRecoverPrepare(d) ==
    /\ IsEvent("CoordRecoverPrepare")
    /\ TraceLog[l].event.dtx_id = d
    /\ rsmPhase[d] = "prepare"
    /\ \E c \in CoordinatorNode :
        isLeader[c] /\ handlerActive[c] /\ ~execBusy[c]
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, logEntries, currentBatchDtx,
                    batchTxCount, execBusy, batchSwapPending, uhsExists,
                    lockedUhs>>
    /\ l' = l + 1

TraceShardReplayLog(s) ==
    /\ IsNodeEvent("ShardReplayLog", s)
    /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                    shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                    requestInFlight, requestResult, logEntries, currentBatchDtx,
                    batchTxCount, execBusy, batchSwapPending, uhsExists,
                    lockedUhs>>
    /\ l' = l + 1

\* ====== Invariants ======

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

InvUhsConsistent ==
    \A u \in UhsId : ~(uhsExists[u] /\ lockedUhs[u])

InvShardStateConsistent ==
    \A s \in ShardNode, d \in DtxId :
        ~(shardLocked[s, d] /\ shardApplied[s, d])
        /\ ~(shardApplied[s, d] /\ shardDiscarded[s, d])
        /\ ~(shardLocked[s, d] /\ shardDiscarded[s, d])

InvRSMDoneImpliesShardsDiscarded ==
    \A d \in DtxId :
        rsmPhase[d] = "done"
            => \A s \in ShardNode : shardDiscarded[s, d]

\* ====== TraceInit ======

TraceInit ==
    /\ Init
    /\ l = 2

\* ====== TraceNext ======

TraceNext ==
    \/ \E c \in CoordinatorNode :
        TraceCoordBecomeLeader(c)
        \/ TraceCoordBecomeFollower(c)
        \/ TraceCoordActivateHandler(c)
        \/ TraceCoordDeactivateHandler(c)
        \/ TraceCoordAddTxToBatch(c)
        \/ TraceCoordSwapBatch(c)
        \/ TraceCoordScheduleExec(c)
        \/ TraceCoordCompleteExec(c)
        \/ TraceCoordLogGrow(c)
        \/ TraceCoordCrash(c)
    \/ \E s \in ShardNode, d \in DtxId :
        TraceShardBecomeLeader(s)
        \/ TraceShardBecomeFollower(s)
        \/ TraceShardLockOutputs(s, d)
        \/ TraceShardApplyOutputs(s, d)
        \/ TraceShardDiscardDtx(s, d)
        \/ TraceShardLogGrow(s)
        \/ TraceShardCrash(s)
        \/ TraceShardReplayLog(s)
    \/ \E d \in DtxId :
        TraceRSMReplicatePrepare(d)
        \/ TraceRSMReplicateCommit(d)
        \/ TraceRSMReplicateDiscard(d)
        \/ TraceRSMReplicateDone(d)
        \/ TraceCoordRecoverPrepare(d)
    \/ \E tx \in TxId, c \in CoordinatorNode :
        TraceSentinelSubmitTx(c, tx)
        \/ TraceSentinelRequestToNonLeader(c, tx)
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED <<isLeader, handlerActive, startFlag, stopFlag, rsmPhase,
                       shardLocked, shardApplied, shardDiscarded, sentinelTxs,
                       requestInFlight, requestResult, logEntries, currentBatchDtx,
                       batchTxCount, execBusy, batchSwapPending, uhsExists,
                       lockedUhs, l>>

\* ====== TraceMatched ======

TraceMatched == <>(l > Len(TraceLog))
=============================================================================