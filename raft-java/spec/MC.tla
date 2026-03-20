---------- MODULE MC ----------
\* Model Checking Spec for wenweihu86/raft-java.
\*
\* Wraps the base spec with counter-bounded actions for
\* exhaustive state-space exploration via TLC.
\*
\* Bug Families covered:
\*   1. Non-atomic persistence in startVote (crash recovery)
\*   2. CommitIndex/MatchIndex monotonicity violations (message reorder)
\*   3. Snapshot state desync (missing config/commitIndex update)
\*   4. Shared PreVote/Vote state (cross-contamination)
\*   5. Single-step multi-server config change (no joint consensus)

EXTENDS base

\* Access original (un-overridden) operator definitions.
B == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

CONSTANT MaxTermLimit
ASSUME MaxTermLimit \in Nat

CONSTANT MaxPreVoteLimit
ASSUME MaxPreVoteLimit \in Nat

CONSTANT MaxTimeoutLimit
ASSUME MaxTimeoutLimit \in Nat

CONSTANT RequestLimit
ASSUME RequestLimit \in Nat

CONSTANT CrashLimit
ASSUME CrashLimit \in Nat

CONSTANT LoseLimit
ASSUME LoseLimit \in Nat

CONSTANT AppendEntriesLimit
ASSUME AppendEntriesLimit \in Nat

CONSTANT SnapshotLimit
ASSUME SnapshotLimit \in Nat

CONSTANT TakeSnapshotLimit
ASSUME TakeSnapshotLimit \in Nat

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

\* --- PreVote Constraints (Bug Family 4) ---
MCStartPreVote(i) ==
    /\ constraintCounters.preVote < MaxPreVoteLimit
    /\ B!StartPreVote(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.preVote = @ + 1]

\* --- Election Constraints (Bug Family 1) ---
MCStartVote(i) ==
    /\ currentTerm[i] < MaxTermLimit
    /\ constraintCounters.timeout < MaxTimeoutLimit
    /\ B!StartVote(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.timeout = @ + 1]

\* --- Client Request Constraints ---
MCClientRequest(i) ==
    /\ constraintCounters.request < RequestLimit
    /\ B!ClientRequest(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.request = @ + 1]

\* --- Crash Constraints (Bug Family 1) ---
MCCrash(i) ==
    /\ constraintCounters.crash < CrashLimit
    /\ B!Crash(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.crash = @ + 1]

\* --- Message Loss Constraints (Bug Family 2) ---
MCLoseMessage(m) ==
    /\ constraintCounters.lose < LoseLimit
    /\ B!LoseMessage(m)
    /\ constraintCounters' = [constraintCounters EXCEPT !.lose = @ + 1]

\* --- AppendEntries Constraints (Bug Family 2) ---
MCAppendEntries(i, j) ==
    /\ constraintCounters.appendEntries < AppendEntriesLimit
    /\ B!AppendEntries(i, j)
    /\ constraintCounters' = [constraintCounters EXCEPT !.appendEntries = @ + 1]

\* --- Snapshot Constraints (Bug Family 3) ---
MCSendInstallSnapshot(i, j) ==
    /\ constraintCounters.snapshot < SnapshotLimit
    /\ B!SendInstallSnapshot(i, j)
    /\ constraintCounters' = [constraintCounters EXCEPT !.snapshot = @ + 1]

\* --- TakeSnapshot Constraints ---
MCTakeSnapshot(i) ==
    /\ constraintCounters.takeSnapshot < TakeSnapshotLimit
    /\ B!TakeSnapshot(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.takeSnapshot = @ + 1]

\* --- Config Change Constraints (Bug Family 5) ---
MCProposeConfigChange(i, newCfg) ==
    /\ constraintCounters.configChange < ConfigChangeLimit
    /\ B!ProposeConfigChange(i, newCfg)
    /\ constraintCounters' = [constraintCounters EXCEPT !.configChange = @ + 1]

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ constraintCounters = [
         preVote        |-> 0,
         timeout        |-> 0,
         request        |-> 0,
         crash          |-> 0,
         lose           |-> 0,
         appendEntries  |-> 0,
         snapshot       |-> 0,
         takeSnapshot   |-> 0,
         configChange   |-> 0]

\* ============================================================================
\* NEXT STATE RELATIONS
\* ============================================================================

\* Base: no config changes
MCNext ==
    \/ \E i \in Server :
        \* --- PreVote (Bug Family 4) ---
        \/ MCStartPreVote(i)
        \* --- Elections (Bug Family 1) ---
        \/ MCStartVote(i)
        \/ /\ B!BecomeLeader(i)
           /\ UNCHANGED faultVars
        \* --- Client requests ---
        \/ MCClientRequest(i)
        \* --- Commit advancement ---
        \/ /\ B!AdvanceCommitIndex(i)
           /\ UNCHANGED faultVars
        \* --- Snapshot (Bug Family 3) ---
        \/ MCTakeSnapshot(i)
        \* --- Crash (Bug Family 1) ---
        \/ MCCrash(i)
    \* --- Log replication (Bug Family 2) ---
    \/ \E i, j \in Server : MCAppendEntries(i, j)
    \* --- Snapshot sending (Bug Family 3) ---
    \/ \E i, j \in Server : MCSendInstallSnapshot(i, j)
    \* --- Message handlers (reactive, not bounded) ---
    \/ \E m \in DOMAIN messages :
        /\ m.mdest \in Server
        /\ \/ /\ B!HandlePreVoteRequest(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandlePreVoteResponse(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleRequestVoteRequest(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleRequestVoteResponse(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleAppendEntriesRequest(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleAppendEntriesResponse(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleInstallSnapshotRequest(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!HandleInstallSnapshotResponse(m.mdest, m)
              /\ UNCHANGED faultVars
           \/ /\ B!DropStaleMessage(m)
              /\ UNCHANGED faultVars
    \* --- Message loss (Bug Family 2) ---
    \/ \E m \in DOMAIN messages : MCLoseMessage(m)

\* Dynamic: with config changes (Bug Family 5)
MCNextDynamic ==
    \/ MCNext
    \/ \E i \in Server, newCfg \in (SUBSET Server \ {{}}) :
        MCProposeConfigChange(i, newCfg)

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

\* Persisted term is always <= in-memory term.
PersistedTermConsistencyInv ==
    \A i \in Server : persistedTerm[i] <= currentTerm[i]

\* Commit index never exceeds log length + snapshot offset.
CommitIndexBoundInv ==
    \A i \in Server : commitIndex[i] <= LastLogIndex(i) + snapshotIndex[i]

\* Candidates always voted for themselves.
CandidateVotedForSelfInv ==
    \A i \in Server : state[i] = Candidate => votedFor[i] = i

\* Leaders always have a positive term.
LeaderTermPositiveInv ==
    \A i \in Server : state[i] = Leader => currentTerm[i] > 0

\* PreVote phase cleared when entering Candidate state.
VotePhaseSeparationInv ==
    \A i \in Server : state[i] = Candidate => preVotesGranted[i] = {}

\* Config is always a non-empty subset of Server.
ConfigValidInv ==
    \A i \in Server :
        /\ config[i] /= {}
        /\ config[i] \subseteq Server

\* ============================================================================
\* BUG FAMILY 1: PERSISTENCE WINDOW DETECTION
\* ============================================================================

\* Detect orphaned election RPCs: a RequestVoteRequest is in flight from
\* server i at term T, but i's currentTerm < T (crashed after StartVote
\* before any stepDown persisted the term).
NoOrphanedElectionRPCs ==
    \A m \in DOMAIN messages :
        m.mtype = RequestVoteRequest =>
            currentTerm[m.msource] >= m.mterm

\* Detect when a crashed-and-recovered node has voted for
\* a DIFFERENT candidate at the same term as its orphaned RPCs.
NoDualVoteFromCrashInv ==
    \A m \in DOMAIN messages :
        /\ m.mtype = RequestVoteRequest
        /\ currentTerm[m.msource] = m.mterm
        => votedFor[m.msource] = m.msource

\* ============================================================================
\* BUG FAMILY 3: SNAPSHOT STATE DESYNC
\* ============================================================================

\* After snapshot install, node's configuration should contain snapshot servers.
SnapshotConfigConsistencyInv ==
    \A s \in Server :
        snapshotIndex[s] > 0 =>
            snapshotConfig[s] \subseteq config[s] \/ config[s] \subseteq snapshotConfig[s]

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* CommitIndex never decreases (except after Crash).
\* Bug Family 2: violated due to missing monotonicity guard in follower.
MonotonicCommitIndexProp ==
    [][(~\E i \in Server : B!Crash(i)) =>
        \A i \in Server : commitIndex'[i] >= commitIndex[i]]_mc_vars

\* Term never decreases (except after Crash).
MonotonicTermProp ==
    [][(~\E i \in Server : B!Crash(i)) =>
        \A i \in Server : currentTerm'[i] >= currentTerm[i]]_mc_vars

\* Leader only appends to its log, never truncates.
\* Uses absolute indices (snapshotIndex + Len(log)) to account for snapshot truncation.
LeaderAppendOnlyProp ==
    [][
        \A i \in Server :
            (state[i] = Leader /\ state'[i] = Leader) =>
                LET absLen  == snapshotIndex[i]  + Len(log[i])
                    absLen2 == snapshotIndex'[i] + Len(log'[i])
                IN /\ absLen2 >= absLen
                   \* Entries still in both pre/post logs have same terms
                   /\ LET lo == Max(snapshotIndex'[i], snapshotIndex[i]) + 1
                          hi == absLen
                      IN \A idx \in lo..hi :
                           log'[i][idx - snapshotIndex'[i]].term =
                           log[i][idx - snapshotIndex[i]].term
    ]_mc_vars

\* Leader only commits entries from its current term.
\* Uses snapshot-adjusted index for log access.
LeaderCommitCurrentTermLogsProp ==
    [][
        \A i \in Server :
            (state'[i] = Leader /\ commitIndex[i] /= commitIndex'[i]) =>
                LET adjIdx == commitIndex'[i] - snapshotIndex'[i]
                IN /\ adjIdx > 0 /\ adjIdx <= Len(log'[i])
                   /\ log'[i][adjIdx].term = currentTerm'[i]
    ]_mc_vars

\* MatchIndex never decreases for a stable leader.
\* Bug Family 2: violated due to missing monotonicity guard.
MonotonicMatchIndexProp ==
    [][
        \A i, j \in Server :
            (state[i] = Leader /\ state'[i] = Leader) =>
                matchIndex'[i][j] >= matchIndex[i][j]
    ]_mc_vars

=============================================================================
