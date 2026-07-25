------------------------------ MODULE MC ------------------------------
\* Model checking wrapper for eliben/raft base spec.
\*
\* Adds counter-bounded fault injection actions, symmetry reduction,
\* message buffer constraint, and structural invariants.
\*
EXTENDS base

B == INSTANCE base

----
\* Counter-bounded constants
----

CONSTANT MaxTimeoutLimit      \* Max election timeouts across all servers
CONSTANT MaxRequestLimit      \* Max client requests across all servers
CONSTANT MaxCrashLimit        \* Max crash-recovery events
CONSTANT MaxLoseLimit         \* Max lost messages
CONSTANT MaxAppendLimit       \* Max AppendEntries sends (heartbeats)
CONSTANT MaxMsgBufferLimit    \* Max messages in the bag (state space pruning)
CONSTANT MaxTermLimit         \* Max term any server can reach

----
\* Counter variable
----

VARIABLE constraintCounters
\* Record with fields: timeout, request, crash, lose, append

faultVars == <<constraintCounters>>

allVars == <<vars, faultVars>>

----
\* Counter-bounded action wrappers
\*
\* Only BOUND non-deterministic/fault-injection actions.
\* DO NOT bound reactive/deterministic actions (message handlers, BecomeLeader,
\* AdvanceCommitIndex, DropStaleMessage).
----

MCTimeout(i) ==
    /\ constraintCounters.timeout < MaxTimeoutLimit
    /\ currentTerm[i] + 1 <= MaxTermLimit
    /\ B!Timeout(i)
    /\ constraintCounters' = [constraintCounters EXCEPT
                               !.timeout = @ + 1]

MCClientRequest(i) ==
    /\ constraintCounters.request < MaxRequestLimit
    /\ B!ClientRequest(i)
    /\ constraintCounters' = [constraintCounters EXCEPT
                               !.request = @ + 1]

MCCrash(i) ==
    /\ constraintCounters.crash < MaxCrashLimit
    /\ B!Crash(i)
    /\ constraintCounters' = [constraintCounters EXCEPT
                               !.crash = @ + 1]

MCLoseMessage(m) ==
    /\ constraintCounters.lose < MaxLoseLimit
    /\ B!LoseMessage(m)
    /\ constraintCounters' = [constraintCounters EXCEPT
                               !.lose = @ + 1]

MCAppendEntries(i, j) ==
    /\ constraintCounters.append < MaxAppendLimit
    /\ B!AppendEntries(i, j)
    /\ constraintCounters' = [constraintCounters EXCEPT
                               !.append = @ + 1]

\* --- Fault injection: partial persist (Bug Family 1, F1c) ---
\* Models a crash during persistToStorage() where term is written
\* but votedFor is not yet persisted (raft.go:228-246 crash window).
\* This is a NEW action not in the base spec — pure fault injection.
PartialPersist(i) ==
    /\ constraintCounters.crash < MaxCrashLimit
    \* Only meaningful when volatile and persisted state differ
    /\ currentTerm[i] /= persistedTerm[i]
    \* Write term to persisted (first Set call at raft.go:233 succeeded)
    /\ persistedTerm' = [persistedTerm EXCEPT ![i] = currentTerm[i]]
    \* votedFor NOT written (crash before raft.go:239)
    /\ UNCHANGED persistedVotedFor
    \* Then crash: recover from partially persisted state
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i]]  \* term was persisted
    /\ votedFor'    = [votedFor    EXCEPT ![i] = persistedVotedFor[i]]  \* stale!
    /\ state'       = [state       EXCEPT ![i] = Follower]
    /\ commitIndex'  = [commitIndex  EXCEPT ![i] = 0]
    /\ nextIndex'    = [nextIndex    EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'   = [matchIndex   EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ UNCHANGED <<log, messages>>
    /\ constraintCounters' = [constraintCounters EXCEPT
                               !.crash = @ + 1]

----
\* Unconstrained (reactive/deterministic) action wrappers
----

MCHandleRequestVoteRequest(i, m) ==
    /\ B!HandleRequestVoteRequest(i, m)
    /\ UNCHANGED faultVars

MCHandleRequestVoteResponse(i, m) ==
    /\ B!HandleRequestVoteResponse(i, m)
    /\ UNCHANGED faultVars

MCBecomeLeader(i) ==
    /\ B!BecomeLeader(i)
    /\ UNCHANGED faultVars

MCHandleAppendEntriesRequest(i, m) ==
    /\ B!HandleAppendEntriesRequest(i, m)
    /\ UNCHANGED faultVars

MCHandleAppendEntriesResponse(i, m) ==
    /\ B!HandleAppendEntriesResponse(i, m)
    /\ UNCHANGED faultVars

MCAdvanceCommitIndex(i) ==
    /\ B!AdvanceCommitIndex(i)
    /\ UNCHANGED faultVars

MCDropStaleMessage(m) ==
    /\ B!DropStaleMessage(m)
    /\ UNCHANGED faultVars

----
\* Init
----

MCInit ==
    /\ B!Init
    /\ constraintCounters = [timeout |-> 0, request |-> 0,
                              crash |-> 0, lose |-> 0,
                              append |-> 0]

----
\* Next
----

\* Per-server async actions
MCNextAsync(i) ==
    \/ MCTimeout(i)
    \/ MCBecomeLeader(i)
    \/ MCClientRequest(i)
    \/ MCAdvanceCommitIndex(i)
    \/ MCCrash(i)
    \/ PartialPersist(i)

\* Per-pair actions
MCNextPair(i, j) ==
    \/ MCAppendEntries(i, j)

\* Message actions
MCNextMsg(m) ==
    \/ MCHandleRequestVoteRequest(m.mdest, m)
    \/ MCHandleRequestVoteResponse(m.mdest, m)
    \/ MCHandleAppendEntriesRequest(m.mdest, m)
    \/ MCHandleAppendEntriesResponse(m.mdest, m)
    \/ MCDropStaleMessage(m)
    \/ MCLoseMessage(m)

MCNext ==
    \/ \E i \in Server : MCNextAsync(i)
    \/ \E i, j \in Server : MCNextPair(i, j)
    \/ \E m \in DOMAIN messages : MCNextMsg(m)

MCSpec == MCInit /\ [][MCNext]_allVars

----
\* Symmetry and constraints
----

\* Symmetry reduction: servers are interchangeable
Symmetry == Permutations(Server)

\* State space pruning: limit message bag size
MsgBufferConstraint ==
    BagCardinality(messages) <= MaxMsgBufferLimit

----
\* Structural invariants
----

\* Candidate has voted for self
CandidateVotedForSelfInv == B!CandidateVotedForSelf

\* Commit index within log bounds
CommitIndexBoundInv == B!CommitIndexBound

\* Leader term is positive
LeaderTermPositiveInv == B!LeaderTermPositive

\* NextIndex always positive
NextIndexPositiveInv == B!NextIndexPositive

\* Persisted term consistency (may be violated by F2a term regression)
PersistedTermConsistencyInv == B!PersistedTermConsistency

----
\* Temporal properties
----

\* Term is monotonically non-decreasing (violated by F2a term regression)
MonotonicTermProp ==
    [][\A s \in Server : currentTerm'[s] >= currentTerm[s]]_vars

\* Commit index is monotonically non-decreasing (except across crashes)
MonotonicCommitProp ==
    [][\A s \in Server :
        \/ commitIndex'[s] >= commitIndex[s]
        \/ state'[s] = Follower /\ commitIndex'[s] = 0]_vars

=============================================================================
