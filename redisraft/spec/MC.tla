---------- MODULE MC ----------
\* Model Checking Spec for RedisRaft.
\*
\* Wraps the base spec with counter-bounded actions for
\* exhaustive state-space exploration via TLC.
\*
\* Scenarios covered:
\*   - Snapshot loading crash window (Bug Family 1)
\*   - Stale read / read before noop (Bug Family 2)
\*   - Membership change + split brain (Bug Family 3)
\*   - Crash recovery with log persistence (Bug Family 4)
\*   - Unreliable network (message loss)

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

CONSTANT SnapshotLimit
ASSUME SnapshotLimit \in Nat

CONSTANT ConfigChangeLimit
ASSUME ConfigChangeLimit \in Nat

CONSTANT ReadLimit
ASSUME ReadLimit \in Nat

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

\* --- Crash Constraints (Bug Families 1, 4) ---
MCCrash(i) ==
    /\ constraintCounters.crash < CrashLimit
    /\ B!Crash(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.crash = @ + 1]

\* --- Message Loss Constraints ---
MCLoseMessage(m) ==
    /\ constraintCounters.lose < LoseLimit
    /\ B!LoseMessage(m)
    /\ constraintCounters' = [constraintCounters EXCEPT !.lose = @ + 1]

\* --- Snapshot Constraints (Bug Family 1) ---
MCTakeSnapshot(i) ==
    /\ constraintCounters.snapshot < SnapshotLimit
    /\ B!TakeSnapshot(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.snapshot = @ + 1]

MCSendInstallSnapshot(i, j) ==
    /\ constraintCounters.snapshot < SnapshotLimit
    /\ B!SendInstallSnapshot(i, j)
    /\ constraintCounters' = [constraintCounters EXCEPT !.snapshot = @ + 1]

\* --- Config Change Constraints (Bug Family 3) ---
MCProposeAddServer(i, target) ==
    /\ constraintCounters.configChange < ConfigChangeLimit
    /\ B!ProposeAddServer(i, target)
    /\ constraintCounters' = [constraintCounters EXCEPT !.configChange = @ + 1]

MCProposeRemoveServer(i, target) ==
    /\ constraintCounters.configChange < ConfigChangeLimit
    /\ B!ProposeRemoveServer(i, target)
    /\ constraintCounters' = [constraintCounters EXCEPT !.configChange = @ + 1]

\* --- Read Constraints (Bug Family 2) ---
MCClientNonQuorumRead(i) ==
    /\ constraintCounters.read < ReadLimit
    /\ B!ClientNonQuorumRead(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.read = @ + 1]

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
         snapshot     |-> 0,
         configChange |-> 0,
         read         |-> 0]

\* ============================================================================
\* NEXT STATE RELATIONS
\* ============================================================================

MCNext ==
    \/ \E i \in Server :
        \* --- Elections ---
        \/ MCTimeout(i)
        \/ /\ B!BecomeLeader(i)
           /\ UNCHANGED faultVars
        \* --- Client operations ---
        \/ MCClientRequest(i)
        \/ MCClientNonQuorumRead(i)
        \* --- Commit advancement ---
        \/ /\ B!AdvanceCommitIndex(i)
           /\ UNCHANGED faultVars
        \* --- Log replication ---
        \/ /\ \E j \in Server : B!AppendEntries(i, j)
           /\ UNCHANGED faultVars
        \* --- Snapshots (Bug Family 1) ---
        \/ MCTakeSnapshot(i)
        \/ \E j \in Server : MCSendInstallSnapshot(i, j)
        \/ /\ B!EndLoadSnapshot(i)
           /\ UNCHANGED faultVars
        \* --- Membership (Bug Family 3) ---
        \/ \E target \in Server : MCProposeAddServer(i, target)
        \/ \E target \in Server : MCProposeRemoveServer(i, target)
        \* --- Crash (Bug Families 1, 4) ---
        \/ MCCrash(i)
    \* --- Message handlers (reactive, not bounded) ---
    \/ \E m \in DOMAIN messages :
        /\ \/ /\ B!HandleRequestVoteRequest(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleRequestVoteResponse(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleAppendEntriesRequest(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleAppendEntriesResponse(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleInstallSnapshotRequest(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!DropStaleMessage(m)
              /\ UNCHANGED faultVars
    \* --- Network loss ---
    \/ \E m \in DOMAIN messages : MCLoseMessage(m)

\* ============================================================================
\* SPECIFICATIONS
\* ============================================================================

mc_vars == <<vars, faultVars>>

MCSpec ==
    /\ MCInit
    /\ [][MCNext]_mc_vars

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
CommitIndexBoundInv == B!CommitIndexBound

\* Leaders always have a positive term.
LeaderTermPositiveInv == B!LeaderTermPositive

\* Candidates always voted for themselves.
CandidateVotedForSelfInv == B!CandidateVotedForSelf

\* Config is always non-empty.
ConfigValidInv == B!ConfigValid

\* Log offset is >= snapshot last index.
LogOffsetValidInv == B!LogOffsetValid

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
\* Excludes snapshot compaction (logOffset change) which removes committed
\* entries from the physical log but preserves the logical log.
LeaderAppendOnlyProp ==
    [][
        \A i \in Server :
            (state[i] = Leader /\ state'[i] = Leader
             /\ logOffset'[i] = logOffset[i]) =>
                /\ Len(log'[i]) >= Len(log[i])
                /\ SubSeq(log'[i], 1, Len(log[i])) =
                   SubSeq(log[i], 1, Len(log[i]))
    ]_mc_vars

\* Leader only commits entries from its current term.
LeaderCommitCurrentTermProp ==
    [][
        \A i \in Server :
            (state'[i] = Leader /\ commitIndex[i] /= commitIndex'[i]) =>
                log'[i][commitIndex'[i] - logOffset'[i]].term = currentTerm'[i]
    ]_mc_vars

=============================================================================
