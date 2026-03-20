---------- MODULE MC ----------
\* Model Checking Spec for async-raft.
\*
\* Wraps the base spec with counter-bounded actions for
\* exhaustive state-space exploration via TLC.
\*
\* Bug families covered:
\*   1. Buggy quorum formula for reads (Bug Family 1)
\*   2. Buggy log up-to-date check (Bug Family 2)
\*   3. Unconditional commit_index + optimistic match_index (Bug Family 3)
\*   4. Snapshot state clobbering (Bug Family 4)
\*   5. Membership change lifecycle gaps (Bug Family 5)
\*   6. Client read continues after deposition (Bug Family 6)

EXTENDS base

\* Access original (un-overridden) operator definitions.
B == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

CONSTANT MaxTermLimit
ASSUME MaxTermLimit \in Nat

CONSTANT MaxTimeoutLimit
ASSUME MaxTimeoutLimit \in Nat

CONSTANT RequestLimit
ASSUME RequestLimit \in Nat

CONSTANT CrashLimit
ASSUME CrashLimit \in Nat

CONSTANT LoseLimit
ASSUME LoseLimit \in Nat

CONSTANT HeartbeatLimit
ASSUME HeartbeatLimit \in Nat

CONSTANT SnapshotLimit
ASSUME SnapshotLimit \in Nat

CONSTANT ReadRequestLimit
ASSUME ReadRequestLimit \in Nat

CONSTANT ConfigChangeLimit
ASSUME ConfigChangeLimit \in Nat

CONSTANT MaxMsgBufferLimit
ASSUME MaxMsgBufferLimit \in Nat

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

VARIABLE constraintCounters

faultVars == <<constraintCounters>>

\* ============================================================================
\* MODEL CHECKING CONSTRAINED ACTIONS
\* ============================================================================

\* --- Election Constraints ---
MCTimeout(i) ==
    /\ currentTerm[i] < MaxTermLimit
    /\ constraintCounters.timeout < MaxTimeoutLimit
    /\ B!Timeout(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.timeout = @ + 1]

\* --- Client Request Constraints ---
MCClientRequest(i) ==
    /\ constraintCounters.request < RequestLimit
    /\ B!ClientRequest(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.request = @ + 1]

\* --- Crash Constraints ---
MCCrash(i) ==
    /\ constraintCounters.crash < CrashLimit
    /\ B!Crash(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.crash = @ + 1]

\* --- Message Loss Constraints ---
MCLoseMessage(m) ==
    /\ constraintCounters.lose < LoseLimit
    /\ B!LoseMessage(m)
    /\ constraintCounters' = [constraintCounters EXCEPT !.lose = @ + 1]

\* --- Heartbeat Constraints ---
MCSendHeartbeat(i, j) ==
    /\ constraintCounters.heartbeat < HeartbeatLimit
    /\ B!SendHeartbeat(i, j)
    /\ constraintCounters' = [constraintCounters EXCEPT !.heartbeat = @ + 1]

\* --- Snapshot Constraints (Bug Family 4) ---
MCSendInstallSnapshot(i, j) ==
    /\ constraintCounters.snapshot < SnapshotLimit
    /\ B!SendInstallSnapshot(i, j)
    /\ constraintCounters' = [constraintCounters EXCEPT !.snapshot = @ + 1]

\* --- Client Read Constraints (Bug Family 1, 6) ---
MCClientReadRequest(i) ==
    /\ constraintCounters.readRequest < ReadRequestLimit
    /\ B!ClientReadRequest(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.readRequest = @ + 1]

\* --- Config Change Constraints (Bug Family 5) ---
MCChangeMembership(i, newMembers) ==
    /\ constraintCounters.configChange < ConfigChangeLimit
    /\ B!ChangeMembership(i, newMembers)
    /\ constraintCounters' = [constraintCounters EXCEPT !.configChange = @ + 1]

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ constraintCounters = [
         timeout      |-> 0,
         request      |-> 0,
         crash        |-> 0,
         lose         |-> 0,
         heartbeat    |-> 0,
         snapshot     |-> 0,
         readRequest  |-> 0,
         configChange |-> 0]

\* ============================================================================
\* NEXT STATE RELATIONS
\* ============================================================================

MCNextAsync(i) ==
    \* --- Elections ---
    \/ MCTimeout(i)
    \/ /\ B!BecomeLeader(i)
       /\ UNCHANGED faultVars
    \* --- Client requests ---
    \/ MCClientRequest(i)
    \* --- Client reads (Bug Family 1, 6) ---
    \/ MCClientReadRequest(i)
    \/ /\ B!ClientReadComplete(i)
       /\ UNCHANGED faultVars
    \* --- Commit advancement ---
    \/ /\ B!AdvanceCommitIndex(i)
       /\ UNCHANGED faultVars
    \* --- Snapshots ---
    \/ /\ B!TakeSnapshot(i)
       /\ UNCHANGED faultVars
    \* --- Log replication ---
    \/ /\ \E j \in Server : B!ReplicateEntries(i, j)
       /\ UNCHANGED faultVars
    \* --- Heartbeats ---
    \/ \E j \in Server : MCSendHeartbeat(i, j)
    \* --- Snapshots (Bug Family 4) ---
    \/ \E j \in Server : MCSendInstallSnapshot(i, j)
    \* --- Membership changes (Bug Family 5) ---
    \/ /\ B!FinalizeJointConsensus(i)
       /\ UNCHANGED faultVars

MCNextMsg ==
    \E m \in DOMAIN messages :
        /\ m.mdest \in Server
        /\ \/ /\ B!HandleRequestVoteRequest(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleRequestVoteResponse(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleAppendEntriesRequest(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleAppendEntriesResponse(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!ClientReadConfirm(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleInstallSnapshotRequest(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleInstallSnapshotResponse(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!DropStaleMessage(m)
              /\ UNCHANGED faultVars

MCNextCrash == \E i \in Server : MCCrash(i)

MCNextUnreliable ==
    \E m \in DOMAIN messages : MCLoseMessage(m)

MCNextConfigChange ==
    \E i \in Server, newM \in SUBSET Server \ {{}} :
        MCChangeMembership(i, newM)

\* --- Combined Next ---

\* Base: no config changes
MCNext ==
    \/ \E i \in Server : MCNextAsync(i)
    \/ MCNextMsg
    \/ MCNextCrash
    \/ MCNextUnreliable

\* Dynamic: with config changes
MCNextDynamic ==
    \/ MCNext
    \/ MCNextConfigChange

\* ============================================================================
\* SPECIFICATIONS
\* ============================================================================

mc_vars == <<vars, faultVars>>

MCSpec ==
    /\ MCInit
    /\ [][MCNext]_mc_vars

MCSpecDynamic ==
    /\ MCInit
    /\ [][MCNextDynamic]_mc_vars

\* ============================================================================
\* SYMMETRY AND VIEW DEFINITIONS
\* ============================================================================

Symmetry == Permutations(Server)

ModelView == <<vars>>

\* ============================================================================
\* STATE SPACE PRUNING CONSTRAINTS
\* ============================================================================

MsgBufferConstraint ==
    \/ MaxMsgBufferLimit = 0
    \/ BagCardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* STRUCTURAL INVARIANTS
\* ============================================================================

\* Commit index never exceeds log length.
CommitIndexBoundStructural ==
    \A i \in Server : commitIndex[i] <= LastLogIndex(i)

\* Candidates always voted for themselves.
CandidateVotedForSelfStructural ==
    \A i \in Server : state[i] = Candidate => votedFor[i] = i

\* Leaders always have a positive term.
LeaderTermPositiveStructural ==
    \A i \in Server : state[i] = Leader => currentTerm[i] > 0

\* A leader's log contains all committed entries from all servers.
LeaderLogCompletenessStructural ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ commitIndex[s2] > 0) =>
            \A idx \in 1..Min(commitIndex[s2], LastLogIndex(s2)) :
                (log[s2][idx].term <= currentTerm[s1]) =>
                    /\ idx <= LastLogIndex(s1)
                    /\ log[s1][idx] = log[s2][idx]

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* Commit index never decreases (except after Crash).
MonotonicCommitIndexProp ==
    [][(~\E i \in Server : B!Crash(i)) =>
        \A i \in Server : commitIndex'[i] >= commitIndex[i]]_mc_vars

\* Term never decreases (except after Crash).
MonotonicTermProp ==
    [][(~\E i \in Server : B!Crash(i)) =>
        \A i \in Server : currentTerm'[i] >= currentTerm[i]]_mc_vars

\* Leader only appends to its log, never truncates.
LeaderAppendOnlyProp ==
    [][
        \A i \in Server :
            (state[i] = Leader /\ state'[i] = Leader) =>
                /\ Len(log'[i]) >= Len(log[i])
                /\ SubSeq(log'[i], 1, Len(log[i])) =
                   SubSeq(log[i], 1, Len(log[i]))
    ]_mc_vars

=============================================================================
