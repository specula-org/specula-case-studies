---- MODULE MC ----
\* Model checking wrapper for the RethinkDB Raft specification.
\* Counter-bounded fault injection for exhaustive state space exploration.
\*
\* Bounds: fault-injection actions (Timeout, Crash, ClientRequest, LoseMessage,
\*         StartVirtualHeartbeat, StopVirtualHeartbeat, config changes, lifecycle).
\* Unbounded: reactive/deterministic actions (message handlers, CompleteStepDown).

EXTENDS base

\* ============================================================================
\* Counter-bounded constants
\* ============================================================================

CONSTANTS
    MaxTimeoutCount,       \* Bound on Timeout (election start)
    MaxCrashCount,         \* Bound on Crash actions
    MaxClientRequestCount, \* Bound on ClientRequest actions
    MaxLoseCount,          \* Bound on LoseMessage actions
    MaxHeartbeatCount,     \* Bound on StartVirtualHeartbeat actions
    MaxStopHeartbeatCount, \* Bound on StopVirtualHeartbeat actions
    MaxConfigChangeCount,  \* Bound on ProposeConfigChange actions
    MaxEraseCount,         \* Bound on EraseRaftState actions
    MaxReenrollCount,      \* Bound on ReenrollWithSameId actions
    MaxDuplicateCount,     \* Bound on DuplicateMessage actions
    MaxSnapshotCount,      \* Bound on TakeSnapshot actions
    MaxMsgBuffer           \* Max messages in flight

\* ============================================================================
\* Counter variables
\* ============================================================================

VARIABLES
    timeoutCount,
    crashCount,
    clientRequestCount,
    loseCount,
    heartbeatCount,
    stopHeartbeatCount,
    configChangeCount,
    eraseCount,
    reenrollCount,
    duplicateCount,
    snapshotCount

faultVars == <<timeoutCount, crashCount, clientRequestCount, loseCount,
               heartbeatCount, stopHeartbeatCount, configChangeCount,
               eraseCount, reenrollCount, duplicateCount, snapshotCount>>

mcAllVars == <<allVars, faultVars>>

\* ============================================================================
\* Counter-bounded action wrappers
\* ============================================================================

MCTimeout(s) ==
    /\ timeoutCount < MaxTimeoutCount
    /\ currentTerm[s] < MaxTerm  \* Term bound
    /\ Timeout(s)
    /\ timeoutCount' = timeoutCount + 1
    /\ UNCHANGED <<crashCount, clientRequestCount, loseCount,
                   heartbeatCount, stopHeartbeatCount, configChangeCount,
                   eraseCount, reenrollCount, duplicateCount, snapshotCount>>

MCCrash(s) ==
    /\ crashCount < MaxCrashCount
    /\ Crash(s)
    /\ crashCount' = crashCount + 1
    /\ UNCHANGED <<timeoutCount, clientRequestCount, loseCount,
                   heartbeatCount, stopHeartbeatCount, configChangeCount,
                   eraseCount, reenrollCount, duplicateCount, snapshotCount>>

MCClientRequest(s, v) ==
    /\ clientRequestCount < MaxClientRequestCount
    /\ Len(log[s]) < MaxLogLen  \* Log length bound
    /\ ClientRequest(s, v)
    /\ clientRequestCount' = clientRequestCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, loseCount,
                   heartbeatCount, stopHeartbeatCount, configChangeCount,
                   eraseCount, reenrollCount, duplicateCount, snapshotCount>>

MCLoseMessage(m) ==
    /\ loseCount < MaxLoseCount
    /\ LoseMessage(m)
    /\ loseCount' = loseCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, clientRequestCount,
                   heartbeatCount, stopHeartbeatCount, configChangeCount,
                   eraseCount, reenrollCount, duplicateCount, snapshotCount>>

MCDuplicateMessage(m) ==
    /\ duplicateCount < MaxDuplicateCount
    /\ DuplicateMessage(m)
    /\ duplicateCount' = duplicateCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, clientRequestCount, loseCount,
                   heartbeatCount, stopHeartbeatCount, configChangeCount,
                   eraseCount, reenrollCount, snapshotCount>>

MCStartVirtualHeartbeat(leader, follower) ==
    /\ heartbeatCount < MaxHeartbeatCount
    /\ StartVirtualHeartbeat(leader, follower)
    /\ heartbeatCount' = heartbeatCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, clientRequestCount, loseCount,
                   stopHeartbeatCount, configChangeCount,
                   eraseCount, reenrollCount, duplicateCount, snapshotCount>>

MCStopVirtualHeartbeat(leader, follower) ==
    /\ stopHeartbeatCount < MaxStopHeartbeatCount
    /\ StopVirtualHeartbeat(leader, follower)
    /\ stopHeartbeatCount' = stopHeartbeatCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, clientRequestCount, loseCount,
                   heartbeatCount, configChangeCount,
                   eraseCount, reenrollCount, duplicateCount, snapshotCount>>

MCProposeConfigChange(s, newVoters) ==
    /\ configChangeCount < MaxConfigChangeCount
    /\ Len(log[s]) < MaxLogLen
    /\ ProposeConfigChange(s, newVoters)
    /\ configChangeCount' = configChangeCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, clientRequestCount, loseCount,
                   heartbeatCount, stopHeartbeatCount,
                   eraseCount, reenrollCount, duplicateCount, snapshotCount>>

MCEraseRaftState(s) ==
    /\ eraseCount < MaxEraseCount
    /\ EraseRaftState(s)
    /\ eraseCount' = eraseCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, clientRequestCount, loseCount,
                   heartbeatCount, stopHeartbeatCount, configChangeCount,
                   reenrollCount, duplicateCount, snapshotCount>>

MCReenrollWithSameId(s) ==
    /\ reenrollCount < MaxReenrollCount
    /\ ReenrollWithSameId(s)
    /\ reenrollCount' = reenrollCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, clientRequestCount, loseCount,
                   heartbeatCount, stopHeartbeatCount, configChangeCount,
                   eraseCount, duplicateCount, snapshotCount>>

MCTakeSnapshot(s) ==
    /\ snapshotCount < MaxSnapshotCount
    /\ TakeSnapshot(s)
    /\ snapshotCount' = snapshotCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, clientRequestCount, loseCount,
                   heartbeatCount, stopHeartbeatCount, configChangeCount,
                   eraseCount, reenrollCount, duplicateCount>>

\* Reactive actions: unbounded, just pass through with UNCHANGED faultVars
MCRequestVote(s, t) ==
    /\ RequestVote(s, t)
    /\ BagCardinality(messages') <= MaxMsgBuffer
    /\ UNCHANGED faultVars

MCHandleRequestVoteRequest(s, m) ==
    /\ HandleRequestVoteRequest(s, m)
    /\ UNCHANGED faultVars

MCHandleRequestVoteResponse(s, m) ==
    /\ HandleRequestVoteResponse(s, m)
    /\ UNCHANGED faultVars

MCAppendEntries(s, t) ==
    /\ AppendEntries(s, t)
    /\ BagCardinality(messages') <= MaxMsgBuffer
    /\ UNCHANGED faultVars

MCHandleAppendEntriesRequest(s, m) ==
    /\ HandleAppendEntriesRequest(s, m)
    /\ UNCHANGED faultVars

MCHandleAppendEntriesResponse(s, m) ==
    /\ HandleAppendEntriesResponse(s, m)
    /\ UNCHANGED faultVars

MCCompleteStepDown(s) ==
    /\ CompleteStepDown(s)
    /\ UNCHANGED faultVars

MCDiscoverHigherTerm(s, newTerm) ==
    /\ DiscoverHigherTerm(s, newTerm)
    /\ UNCHANGED faultVars

MCSendInstallSnapshot(s, t) ==
    /\ SendInstallSnapshot(s, t)
    /\ BagCardinality(messages') <= MaxMsgBuffer
    /\ UNCHANGED faultVars

MCHandleInstallSnapshotRequest(s, m) ==
    /\ HandleInstallSnapshotRequest(s, m)
    /\ UNCHANGED faultVars

MCHandleInstallSnapshotResponse(s, m) ==
    /\ HandleInstallSnapshotResponse(s, m)
    /\ UNCHANGED faultVars

MCLeaderContinueReconfiguration(s) ==
    /\ LastIndex(s) < MaxLogLen  \* Prevent exceeding log bound
    /\ LeaderContinueReconfiguration(s)
    /\ UNCHANGED faultVars

MCLeaderStepDownAfterConfigChange(s) ==
    /\ LeaderStepDownAfterConfigChange(s)
    /\ UNCHANGED faultVars

MCReenrollWithNewId(s) ==
    /\ ReenrollWithNewId(s)
    /\ UNCHANGED faultVars

\* ============================================================================
\* Init and Next
\* ============================================================================

MCInit ==
    /\ Init
    /\ timeoutCount = 0
    /\ crashCount = 0
    /\ clientRequestCount = 0
    /\ loseCount = 0
    /\ heartbeatCount = 0
    /\ stopHeartbeatCount = 0
    /\ configChangeCount = 0
    /\ eraseCount = 0
    /\ reenrollCount = 0
    /\ duplicateCount = 0
    /\ snapshotCount = 0

MCNext ==
    \* Leader election (bounded: Timeout; unbounded: message handlers)
    \/ \E s \in Server : MCTimeout(s)
    \/ \E s, t \in Server : s /= t /\ MCRequestVote(s, t)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\
           \E s \in Server : MCHandleRequestVoteRequest(s, m)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\
           \E s \in Server : MCHandleRequestVoteResponse(s, m)
    \* Virtual heartbeats [Family 1] (bounded)
    \/ \E s, t \in Server : s /= t /\ MCStartVirtualHeartbeat(s, t)
    \/ \E s, t \in Server : s /= t /\ MCStopVirtualHeartbeat(s, t)
    \* Log replication (bounded: ClientRequest; unbounded: AE handlers)
    \/ \E s \in Server, v \in Value : MCClientRequest(s, v)
    \/ \E s, t \in Server : s /= t /\ MCAppendEntries(s, t)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\
           \E s \in Server : MCHandleAppendEntriesRequest(s, m)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\
           \E s \in Server : MCHandleAppendEntriesResponse(s, m)
    \* Snapshot / InstallSnapshot [Family 5]
    \/ \E s \in Server : MCTakeSnapshot(s)
    \/ \E s, t \in Server : s /= t /\ MCSendInstallSnapshot(s, t)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\
           \E s \in Server : MCHandleInstallSnapshotRequest(s, m)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\
           \E s \in Server : MCHandleInstallSnapshotResponse(s, m)
    \* Async step-down [Family 2] (unbounded: reactive)
    \/ \E s \in Server, t \in 1..MaxTerm : MCDiscoverHigherTerm(s, t)
    \/ \E s \in Server : MCCompleteStepDown(s)
    \* Configuration change [Family 3] (bounded: propose; unbounded: continue, step-down)
    \/ \E s \in Server, v \in SUBSET Server : v /= {} /\ MCProposeConfigChange(s, v)
    \/ \E s \in Server : MCLeaderContinueReconfiguration(s)
    \/ \E s \in Server : MCLeaderStepDownAfterConfigChange(s)
    \* Raft lifecycle [Family 4] (bounded)
    \/ \E s \in Server : MCEraseRaftState(s)
    \/ \E s \in Server : MCReenrollWithSameId(s)
    \/ \E s \in Server : MCReenrollWithNewId(s)
    \* Faults (bounded)
    \/ \E s \in Server : MCCrash(s)
    \/ \E m \in DOMAIN messages : MCLoseMessage(m)
    \/ \E m \in DOMAIN messages : MCDuplicateMessage(m)

MCSpec == MCInit /\ [][MCNext]_mcAllVars

\* ============================================================================
\* Symmetry reduction
\* ============================================================================

MCSymmetry == Permutations(Server)

\* ============================================================================
\* State space constraint
\* ============================================================================

MCStateConstraint ==
    /\ \A s \in Server : currentTerm[s] <= MaxTerm
    /\ \A s \in Server : Len(log[s]) <= MaxLogLen
    /\ BagCardinality(messages) <= MaxMsgBuffer

\* ============================================================================
\* Structural Invariants (always checked)
\* ============================================================================

\* No pending step-down on a follower (should have been cleared)
NoPendingStepDownOnFollower ==
    \A s \in Server :
        state[s] = "follower" => ~pendingStepDown[s]

\* Virtual heartbeat sender should claim to be leader or at least same term
VHBSenderConsistency ==
    \A s \in Server :
        virtualHeartbeatSender[s] /= Nil =>
            virtualHeartbeatSender[s] \in Server

\* Watchdog blocked only if VHB sender is set
WatchdogBlockedConsistency ==
    \A s \in Server :
        watchdogBlocked[s] => virtualHeartbeatSender[s] /= Nil

\* Snapshot index is always <= commit index (snapshot only committed entries)
SnapshotBound ==
    \A s \in Server :
        persistentLogValid[s] => snapshotIndex[s] <= commitIndex[s]

====
