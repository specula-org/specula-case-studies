---------------------------- MODULE MC ----------------------------
\* Model checking wrapper for dotnet/dotNext Raft spec.
\*
\* Counter-bounds fault-injection actions (Timeout, Crash, ClientRequest,
\* LoseMessage, ProposeConfig, Heartbeat) to make exhaustive state space
\* exploration feasible. Deterministic/reactive actions pass through.
\*
\* Hunting configs (MC_hunt_*.cfg) override constants for targeted
\* bug-family exploration after spec convergence.
\*
EXTENDS base

\* ---- Counter bounds ----
CONSTANTS
    MaxTimeoutLimit,     \* max Timeout actions across all servers
    MaxCrashLimit,       \* max Crash actions across all servers
    MaxRequestLimit,     \* max ClientRequest actions across all servers
    MaxLoseLimit,        \* max LoseMessage actions
    MaxHeartbeatLimit,   \* max AppendEntries (heartbeat) actions per server
    MaxConfigLimit,      \* max ProposeConfig actions across all servers
    MaxTermLimit         \* max term any server can reach

\* ---- Counter variables ----
VARIABLE timeoutCount       \* Nat
VARIABLE crashCount         \* Nat
VARIABLE requestCount       \* Nat
VARIABLE loseCount          \* Nat
VARIABLE heartbeatCount     \* Nat
VARIABLE configCount        \* Nat

faultVars == <<timeoutCount, crashCount, requestCount,
               loseCount, heartbeatCount, configCount>>

mcVars == <<vars, faultVars>>

\* ---- Message buffer constraint ----
CONSTANTS MaxMsgCount       \* max total messages in bag

MsgBufferConstraint ==
    BagCardinality(messages) <= MaxMsgCount

\* ---- Term constraint ----
TermConstraint ==
    \A i \in Server : currentTerm[i] <= MaxTermLimit

\* ---- Counter-bounded wrappers ----

\* Timeout: bound total timeouts
MCTimeout(i) ==
    /\ timeoutCount < MaxTimeoutLimit
    /\ currentTerm[i] < MaxTermLimit  \* term constraint
    /\ Timeout(i)
    /\ timeoutCount' = timeoutCount + 1
    /\ UNCHANGED <<crashCount, requestCount, loseCount,
                   heartbeatCount, configCount>>

\* Crash: bound total crashes
MCCrash(i) ==
    /\ crashCount < MaxCrashLimit
    /\ Crash(i)
    /\ crashCount' = crashCount + 1
    /\ UNCHANGED <<timeoutCount, requestCount, loseCount,
                   heartbeatCount, configCount>>

\* ClientRequest: bound total client requests
MCClientRequest(i, v) ==
    /\ requestCount < MaxRequestLimit
    /\ ClientRequest(i, v)
    /\ requestCount' = requestCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, loseCount,
                   heartbeatCount, configCount>>

\* AppendEntries (heartbeat): bound total heartbeats
MCAppendEntries(i, j) ==
    /\ heartbeatCount < MaxHeartbeatLimit
    /\ AppendEntries(i, j)
    /\ heartbeatCount' = heartbeatCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, requestCount,
                   loseCount, configCount>>

\* LoseMessage: bound total message losses
MCLoseMessage(m) ==
    /\ loseCount < MaxLoseLimit
    /\ LoseMessage(m)
    /\ loseCount' = loseCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, requestCount,
                   heartbeatCount, configCount>>

\* ProposeConfig: bound total config proposals
MCProposeConfig(i, newConfig) ==
    /\ configCount < MaxConfigLimit
    /\ ProposeConfig(i, newConfig)
    /\ configCount' = configCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, requestCount,
                   loseCount, heartbeatCount>>

\* ---- Unconstrained wrappers (reactive/deterministic actions) ----
\* These actions react to existing state and don't need bounding.

UCRequestVote(i, j) ==
    /\ RequestVote(i, j)
    /\ UNCHANGED faultVars

UCHandleRequestVote(i, m) ==
    /\ HandleRequestVote(i, m)
    /\ UNCHANGED faultVars

UCHandleRequestVoteResponse(i, m) ==
    /\ HandleRequestVoteResponse(i, m)
    /\ UNCHANGED faultVars

UCBecomeLeader(i) ==
    /\ BecomeLeader(i)
    /\ UNCHANGED faultVars

UCHandleAppendEntries(i, m) ==
    /\ HandleAppendEntries(i, m)
    /\ UNCHANGED faultVars

UCHandleAppendEntriesResponse(i, m) ==
    /\ HandleAppendEntriesResponse(i, m)
    /\ UNCHANGED faultVars

UCAdvanceCommitIndex(i) ==
    /\ AdvanceCommitIndex(i)
    /\ UNCHANGED faultVars

UCApplyConfig(i) ==
    /\ ApplyConfig(i)
    /\ UNCHANGED faultVars

UCRenewLease(i) ==
    /\ RenewLease(i)
    /\ UNCHANGED faultVars

UCLeaseExpire(i) ==
    /\ LeaseExpire(i)
    /\ UNCHANGED faultVars

UCPersistCommitIndex(i) ==
    /\ PersistCommitIndex(i)
    /\ UNCHANGED faultVars

\* ---- MC Init ----

MCInit ==
    /\ Init
    /\ timeoutCount   = 0
    /\ crashCount     = 0
    /\ requestCount   = 0
    /\ loseCount      = 0
    /\ heartbeatCount = 0
    /\ configCount    = 0

\* ---- MC Next ----

MCNext ==
    \/ \E i \in Server :
        \/ MCTimeout(i)
        \/ MCCrash(i)
        \/ UCBecomeLeader(i)
        \/ UCAdvanceCommitIndex(i)
        \/ UCApplyConfig(i)
        \/ UCRenewLease(i)
        \/ UCLeaseExpire(i)
        \/ UCPersistCommitIndex(i)
        \/ \E j \in Server : UCRequestVote(i, j)
        \/ \E j \in Server : MCAppendEntries(i, j)
        \/ \E v \in Value : MCClientRequest(i, v)
        \/ \E newConfig \in (SUBSET Server \ {{}}) : MCProposeConfig(i, newConfig)
    \/ \E m \in BagToSet(messages) :
        \/ UCHandleRequestVote(m.mdest, m)
        \/ UCHandleRequestVoteResponse(m.mdest, m)
        \/ UCHandleAppendEntries(m.mdest, m)
        \/ UCHandleAppendEntriesResponse(m.mdest, m)
        \/ MCLoseMessage(m)

MCSpec == MCInit /\ [][MCNext]_mcVars

\* ---- Symmetry ----

ModelSymmetry == Permutations(Server)

\* ---- State space view (exclude counters) ----

MCView == <<vars>>

\* ---- Structural invariants for convergence ----

MCTypeOK ==
    /\ currentTerm \in [Server -> Nat]
    /\ state \in [Server -> {Follower, Candidate, Leader}]
    /\ votedFor \in [Server -> Server \cup {Nil}]
    /\ commitIndex \in [Server -> Nat]
    /\ activeConfig \in [Server -> SUBSET Server]
    /\ leaseValid \in [Server -> BOOLEAN]
    /\ persistedCommitIndex \in [Server -> Nat]
    /\ timeoutCount \in Nat
    /\ crashCount \in Nat
    /\ requestCount \in Nat
    /\ loseCount \in Nat
    /\ heartbeatCount \in Nat
    /\ configCount \in Nat

\* At most one leader per term (from base)
MCElectionSafety == ElectionSafety

\* Committed log entries agree (from base)
MCStateMachineSafety == StateMachineSafety

\* Log matching property (from base)
MCLogMatching == LogMatching

\* Structural bounds (from base)
MCCommitIndexBound == CommitIndexBound
MCPersistedCommitBound == PersistedCommitBound
MCMatchIndexBound == MatchIndexBound

\* ---- Extension invariants (for hunting configs) ----

\* Family 2: Config commit consistency
MCConfigCommitConsistency == ConfigCommitConsistency

\* Family 4: No stale leader with lease
MCNoStaleLeaderWithLease == NoStaleLeaderWithLease

\* Family 5: Commit monotonicity
MCCommitMonotonicity == CommitMonotonicity

\* ---- Election restriction comparison (Family 1) ----
\* Override IsUpToDate with the paper's disjunctive check to compare
\* MCIsUpToDatePaper(cIdx, cTerm, vIdx, vTerm) ==
\*     IsUpToDateDisjunctive(cIdx, cTerm, vIdx, vTerm)

====
