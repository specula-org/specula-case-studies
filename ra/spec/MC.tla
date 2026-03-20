---- MODULE MC ----
\*
\* Model checking wrapper for Ra Raft specification.
\* Counter-bounds fault-injection and non-deterministic actions.
\* Leaves deterministic/reactive actions unconstrained.
\*
EXTENDS base

\* ============================================================================
\* COUNTER CONSTANTS
\* ============================================================================

CONSTANTS
    MaxTermLimit,           \* Max term any server can reach (bounds term growth)
    MaxTimeoutLimit,        \* Max number of election timeouts
    RequestLimit,           \* Max number of client requests
    HeartbeatLimit,         \* Max number of heartbeat rounds (consistent queries)
    LoseLimit,              \* Max number of lost messages
    SnapshotLimit,          \* Max number of snapshots taken
    ConfigChangeLimit,      \* Max number of config changes proposed
    MaxMsgBufferLimit       \* Max messages in the bag (state space pruning)

\* ============================================================================
\* COUNTER VARIABLES
\* ============================================================================

VARIABLES
    timeoutCount,
    requestCount,
    heartbeatCount,
    loseCount,
    snapshotCount,
    configChangeCount

faultVars == <<timeoutCount, requestCount, heartbeatCount,
               loseCount, snapshotCount, configChangeCount>>

mcVars == <<vars, faultVars>>

\* ============================================================================
\* SYMMETRY
\* ============================================================================

\* Use symmetry reduction on Server set (all servers are interchangeable at init)
ModelSymmetry == Permutations(Server)

\* ============================================================================
\* STATE SPACE PRUNING
\* ============================================================================

\* Limit message buffer to prevent state space explosion
MsgBufferConstraint == BagCardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* COUNTER-BOUNDED WRAPPERS
\* ============================================================================

\* --- Timeout (pre-vote election start) ---
\* Bounded: introduces non-determinism (which server times out)
\* Also bounded by MaxTermLimit to prevent unbounded term growth
MCTimeout(i) ==
    /\ timeoutCount < MaxTimeoutLimit
    /\ currentTerm[i] < MaxTermLimit
    /\ Timeout(i)
    /\ timeoutCount' = timeoutCount + 1
    /\ UNCHANGED <<requestCount, heartbeatCount, loseCount,
                    snapshotCount, configChangeCount>>

\* --- ClientRequest ---
\* Bounded: introduces non-determinism (which value, when)
MCClientRequest(i, v) ==
    /\ requestCount < RequestLimit
    /\ ClientRequest(i, v)
    /\ requestCount' = requestCount + 1
    /\ UNCHANGED <<timeoutCount, heartbeatCount, loseCount,
                    snapshotCount, configChangeCount>>

\* --- ConsistentQuery ---
\* Bounded: introduces non-determinism (when queries arrive)
MCConsistentQuery(i) ==
    /\ heartbeatCount < HeartbeatLimit
    /\ ConsistentQuery(i)
    /\ heartbeatCount' = heartbeatCount + 1
    /\ UNCHANGED <<timeoutCount, requestCount, loseCount,
                    snapshotCount, configChangeCount>>

\* --- LoseMessage ---
\* Bounded: fault injection
MCLoseMessage(m) ==
    /\ loseCount < LoseLimit
    /\ LoseMessage(m)
    /\ loseCount' = loseCount + 1
    /\ UNCHANGED <<timeoutCount, requestCount, heartbeatCount,
                    snapshotCount, configChangeCount>>

\* --- TakeSnapshot ---
\* Bounded: introduces non-determinism
MCTakeSnapshot(i) ==
    /\ snapshotCount < SnapshotLimit
    /\ TakeSnapshot(i)
    /\ snapshotCount' = snapshotCount + 1
    /\ UNCHANGED <<timeoutCount, requestCount, heartbeatCount,
                    loseCount, configChangeCount>>

\* --- ProposeConfigChange ---
\* Bounded: introduces non-determinism
MCProposeConfigChange(i, nc) ==
    /\ configChangeCount < ConfigChangeLimit
    /\ ProposeConfigChange(i, nc)
    /\ configChangeCount' = configChangeCount + 1
    /\ UNCHANGED <<timeoutCount, requestCount, heartbeatCount,
                    loseCount, snapshotCount>>

\* ============================================================================
\* UNCONSTRAINED WRAPPERS (reactive/deterministic actions)
\* ============================================================================

\* These actions react to existing state and don't introduce new non-determinism.
\* They pass through with UNCHANGED faultVars.

MCBecomeLeader(i) ==
    /\ BecomeLeader(i) /\ UNCHANGED faultVars

MCLeaderAppendNoop(i) ==
    /\ LeaderAppendNoop(i) /\ UNCHANGED faultVars

MCSendHeartbeat(i) ==
    /\ SendHeartbeat(i) /\ UNCHANGED faultVars

MCWinPreVote(i) ==
    /\ WinPreVote(i) /\ UNCHANGED faultVars

MCAdvanceCommitIndex(i) ==
    /\ AdvanceCommitIndex(i) /\ UNCHANGED faultVars

MCApplyEntries(i) ==
    /\ ApplyEntries(i) /\ UNCHANGED faultVars

MCSnapshotWritten(i) ==
    /\ SnapshotWritten(i) /\ UNCHANGED faultVars

MCReplicateEntries(i, j) ==
    /\ ReplicateEntries(i, j) /\ UNCHANGED faultVars

MCSendInstallSnapshot(i, j) ==
    /\ SendInstallSnapshot(i, j) /\ UNCHANGED faultVars

MCHandlePreVoteRequest(i, m) ==
    /\ HandlePreVoteRequest(i, m) /\ UNCHANGED faultVars

MCHandlePreVoteResponse(i, m) ==
    /\ HandlePreVoteResponse(i, m) /\ UNCHANGED faultVars

MCHandleRequestVoteRequest(i, m) ==
    /\ HandleRequestVoteRequest(i, m) /\ UNCHANGED faultVars

MCHandleRequestVoteResponse(i, m) ==
    /\ HandleRequestVoteResponse(i, m) /\ UNCHANGED faultVars

MCHandleAppendEntriesRequest(i, m) ==
    /\ HandleAppendEntriesRequest(i, m) /\ UNCHANGED faultVars

MCHandleAppendEntriesResponse(i, m) ==
    /\ HandleAppendEntriesResponse(i, m) /\ UNCHANGED faultVars

MCHandleHeartbeatRequest(i, m) ==
    /\ HandleHeartbeatRequest(i, m) /\ UNCHANGED faultVars

MCHandleHeartbeatResponse(i, m) ==
    /\ HandleHeartbeatResponse(i, m) /\ UNCHANGED faultVars

MCHandleInstallSnapshotRequest(i, m) ==
    /\ HandleInstallSnapshotRequest(i, m) /\ UNCHANGED faultVars

MCHandleInstallSnapshotResponse(i, m) ==
    /\ HandleInstallSnapshotResponse(i, m) /\ UNCHANGED faultVars

MCCandidateStepDown(i, m) ==
    /\ CandidateStepDown(i, m) /\ UNCHANGED faultVars

MCLeaderStepDown(i, m) ==
    /\ LeaderStepDown(i, m) /\ UNCHANGED faultVars

MCLeaderIgnorePreVote(i, m) ==
    /\ LeaderIgnorePreVote(i, m) /\ UNCHANGED faultVars

MCDropStaleMessage(m) ==
    /\ DropStaleMessage(m) /\ UNCHANGED faultVars

\* ============================================================================
\* MC INIT AND NEXT
\* ============================================================================

MCInit ==
    /\ Init
    /\ timeoutCount = 0
    /\ requestCount = 0
    /\ heartbeatCount = 0
    /\ loseCount = 0
    /\ snapshotCount = 0
    /\ configChangeCount = 0

MCNext ==
    \* --- Per-server async actions (bounded) ---
    \/ \E i \in Server :
        \/ MCTimeout(i)
        \/ \E v \in Value : MCClientRequest(i, v)
        \/ MCConsistentQuery(i)
        \/ MCTakeSnapshot(i)
    \* --- Per-server reactive actions (unbounded) ---
    \/ \E i \in Server :
        \/ MCBecomeLeader(i)
        \/ MCLeaderAppendNoop(i)
        \/ MCWinPreVote(i)
        \/ MCAdvanceCommitIndex(i)
        \/ MCApplyEntries(i)
        \/ MCSnapshotWritten(i)
        \/ MCSendHeartbeat(i)
    \* --- Pair actions (unbounded) ---
    \/ \E i, j \in Server :
        /\ i /= j
        /\ \/ MCReplicateEntries(i, j)
           \/ MCSendInstallSnapshot(i, j)
    \* --- Message handlers (unbounded) ---
    \/ \E m \in BagToSet(messages) :
        \/ MCHandlePreVoteRequest(m.mdest, m)
        \/ MCHandlePreVoteResponse(m.mdest, m)
        \/ MCHandleRequestVoteRequest(m.mdest, m)
        \/ MCHandleRequestVoteResponse(m.mdest, m)
        \/ MCHandleAppendEntriesRequest(m.mdest, m)
        \/ MCHandleAppendEntriesResponse(m.mdest, m)
        \/ MCHandleHeartbeatRequest(m.mdest, m)
        \/ MCHandleHeartbeatResponse(m.mdest, m)
        \/ MCHandleInstallSnapshotRequest(m.mdest, m)
        \/ MCHandleInstallSnapshotResponse(m.mdest, m)
        \/ MCCandidateStepDown(m.mdest, m)
        \/ MCLeaderStepDown(m.mdest, m)
        \/ MCLeaderIgnorePreVote(m.mdest, m)
        \/ MCDropStaleMessage(m)
    \* --- Fault injection (bounded) ---
    \/ \E m \in BagToSet(messages) :
        MCLoseMessage(m)
    \* --- Config changes (bounded) ---
    \/ \E i \in Server, nc \in SUBSET Server :
        MCProposeConfigChange(i, nc)

MCSpec == MCInit /\ [][MCNext]_mcVars

\* ============================================================================
\* STRUCTURAL INVARIANTS (always hold in correct states)
\* ============================================================================

MCTermNonNegative == TermNonNegative
MCLeaderCommitBound == LeaderCommitBound
MCAppliedBound == AppliedBound
MCNextIndexPositive == NextIndexPositive

\* ============================================================================
\* VIEW (exclude counters from state comparison for folding)
\* ============================================================================

\* Two states differing only in counters are considered the same
ModelView == <<vars>>

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* Eventually a leader is elected (requires fairness)
ElectionLiveness ==
    <>(\E s \in Server : state[s] = Leader)

\* [Bug Family 1] Commit index never decreases (temporal, not state invariant)
\* Follows pattern from hashicorp-raft MonotonicCommitIndexProp
MonotonicCommitIndex ==
    [][\A i \in Server : commitIndex'[i] >= commitIndex[i]]_mcVars

\* [Bug Family 1] Term never decreases
MonotonicTerm ==
    [][\A i \in Server : currentTerm'[i] >= currentTerm[i]]_mcVars

====
