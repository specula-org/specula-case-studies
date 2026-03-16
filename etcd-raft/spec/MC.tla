---- MODULE MC ----
\*
\* Model checking wrapper for etcd-raft base spec.
\* Counter-bounded fault injection for exhaustive state space exploration.
\*

EXTENDS base

\* ============================================================================
\* Counter-bounded Constants
\* ============================================================================

CONSTANTS
    MaxTermLimit,       \* Max term any server can reach
    MaxTimeoutLimit,    \* Max number of election timeouts
    RequestLimit,       \* Max client requests
    HeartbeatLimit,     \* Max heartbeat rounds
    CrashLimit,        \* Max crashes
    LoseLimit,         \* Max message losses
    ReadRequestLimit,  \* Max ReadIndex requests
    CheckQuorumLimit,  \* Max CheckQuorum invocations
    MaxMsgBufferLimit  \* Max messages in flight

\* ============================================================================
\* Counter Variables
\* ============================================================================

VARIABLES
    timeoutCount,
    requestCount,
    heartbeatCount,
    crashCount,
    loseCount,
    readRequestCount,
    checkQuorumCount

mcVars == <<timeoutCount, requestCount, heartbeatCount,
            crashCount, loseCount, readRequestCount, checkQuorumCount>>

\* ============================================================================
\* Counter-bounded Action Wrappers
\* ============================================================================

MCTimeout(s) ==
    /\ timeoutCount < MaxTimeoutLimit
    /\ currentTerm[s] < MaxTermLimit
    /\ Timeout(s)
    /\ timeoutCount' = timeoutCount + 1
    /\ UNCHANGED <<requestCount, heartbeatCount, crashCount,
                   loseCount, readRequestCount, checkQuorumCount>>

MCClientRequest(s, v) ==
    /\ requestCount < RequestLimit
    /\ ClientRequest(s, v)
    /\ requestCount' = requestCount + 1
    /\ UNCHANGED <<timeoutCount, heartbeatCount, crashCount,
                   loseCount, readRequestCount, checkQuorumCount>>

MCSendHeartbeat(s) ==
    /\ heartbeatCount < HeartbeatLimit
    /\ SendHeartbeat(s)
    /\ heartbeatCount' = heartbeatCount + 1
    /\ UNCHANGED <<timeoutCount, requestCount, crashCount,
                   loseCount, readRequestCount, checkQuorumCount>>

MCCrash(s) ==
    /\ crashCount < CrashLimit
    /\ Crash(s)
    /\ crashCount' = crashCount + 1
    /\ UNCHANGED <<timeoutCount, requestCount, heartbeatCount,
                   loseCount, readRequestCount, checkQuorumCount>>

MCLoseMessage(m) ==
    /\ loseCount < LoseLimit
    /\ LoseMessage(m)
    /\ loseCount' = loseCount + 1
    /\ UNCHANGED <<timeoutCount, requestCount, heartbeatCount,
                   crashCount, readRequestCount, checkQuorumCount>>

MCRequestReadIndex(s) ==
    /\ readRequestCount < ReadRequestLimit
    /\ RequestReadIndex(s)
    /\ readRequestCount' = readRequestCount + 1
    /\ UNCHANGED <<timeoutCount, requestCount, heartbeatCount,
                   crashCount, loseCount, checkQuorumCount>>

MCPartitionServer(s) ==
    /\ loseCount < LoseLimit
    /\ PartitionServer(s)
    /\ loseCount' = loseCount + 1
    /\ UNCHANGED <<timeoutCount, requestCount, heartbeatCount,
                   crashCount, readRequestCount, checkQuorumCount>>

MCCheckQuorum(s) ==
    /\ checkQuorumCount < CheckQuorumLimit
    /\ CheckQuorum(s)
    /\ checkQuorumCount' = checkQuorumCount + 1
    /\ UNCHANGED <<timeoutCount, requestCount, heartbeatCount,
                   crashCount, loseCount, readRequestCount>>

\* ── Unconstrained actions (reactive / deterministic) ──

MCBecomeLeader(s) ==
    /\ BecomeLeader(s)
    /\ UNCHANGED mcVars

MCAppendEntries(s, j) ==
    /\ s # j
    /\ AppendEntries(s, j)
    /\ UNCHANGED mcVars

MCPersistAndSend(s) ==
    /\ PersistAndSend(s)
    /\ UNCHANGED mcVars

MCHandleRequestVoteRequest(s, m) ==
    /\ HandleRequestVoteRequest(s, m)
    /\ UNCHANGED mcVars

MCHandleRequestVoteResponse(s, m) ==
    /\ HandleRequestVoteResponse(s, m)
    /\ UNCHANGED mcVars

MCHandlePreVoteRequest(s, m) ==
    /\ HandlePreVoteRequest(s, m)
    /\ UNCHANGED mcVars

MCHandlePreVoteResponse(s, m) ==
    /\ HandlePreVoteResponse(s, m)
    /\ UNCHANGED mcVars

MCHandleAppendEntriesRequest(s, m) ==
    /\ HandleAppendEntriesRequest(s, m)
    /\ UNCHANGED mcVars

MCHandleAppendEntriesResponse(s, m) ==
    /\ HandleAppendEntriesResponse(s, m)
    /\ UNCHANGED mcVars

MCHandleHeartbeat(s, m) ==
    /\ HandleHeartbeat(s, m)
    /\ UNCHANGED mcVars

MCHandleHeartbeatResponse(s, m) ==
    /\ HandleHeartbeatResponse(s, m)
    /\ UNCHANGED mcVars

\* ============================================================================
\* State Space Pruning
\* ============================================================================

MsgBufferConstraint ==
    Cardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* Symmetry
\* ============================================================================

Symmetry == Permutations(Server)

\* ============================================================================
\* Init / Next
\* ============================================================================

MCInit ==
    /\ Init
    /\ timeoutCount = 0
    /\ requestCount = 0
    /\ heartbeatCount = 0
    /\ crashCount = 0
    /\ loseCount = 0
    /\ readRequestCount = 0
    /\ checkQuorumCount = 0

MCNext ==
    \* ── Bounded fault-injection actions ──
    \/ \E s \in Server : MCTimeout(s)
    \/ \E s \in Server, v \in Value : MCClientRequest(s, v)
    \/ \E s \in Server : MCSendHeartbeat(s)
    \/ \E s \in Server : MCCrash(s)
    \/ \E m \in messages : MCLoseMessage(m)
    \/ \E s \in Server : MCPartitionServer(s)
    \/ \E s \in Server : MCRequestReadIndex(s)
    \/ \E s \in Server : MCCheckQuorum(s)
    \* ── Unconstrained reactive actions ──
    \/ \E s \in Server : MCBecomeLeader(s)
    \/ \E s \in Server, j \in Server : s # j /\ MCAppendEntries(s, j)
    \/ \E s \in Server : MCPersistAndSend(s)
    \/ \E m \in messages : MCHandleRequestVoteRequest(m.mdest, m)
    \/ \E m \in messages : MCHandleRequestVoteResponse(m.mdest, m)
    \/ \E m \in messages : MCHandlePreVoteRequest(m.mdest, m)
    \/ \E m \in messages : MCHandlePreVoteResponse(m.mdest, m)
    \/ \E m \in messages : MCHandleAppendEntriesRequest(m.mdest, m)
    \/ \E m \in messages : MCHandleAppendEntriesResponse(m.mdest, m)
    \/ \E m \in messages : MCHandleHeartbeat(m.mdest, m)
    \/ \E m \in messages : MCHandleHeartbeatResponse(m.mdest, m)

MCSpec == MCInit /\ [][MCNext]_<<vars, mcVars>>

\* ============================================================================
\* Structural Invariants (always checked)
\* ============================================================================

MCTermsPositive == TermsPositive
MCCommitIndexBound == CommitIndexBound
MCMessageEndpointsValid == MessageEndpointsValid
MCLeaderLogCommitConsistency == LeaderLogCommitConsistency

\* ============================================================================
\* Temporal Properties
\* ============================================================================

\* Commit index is monotonically non-decreasing (per server, between crashes)
\* Note: after crash, commitIndex resets to 0, so this is not globally monotonic

====
