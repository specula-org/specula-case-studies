------------------------------- MODULE MC ---------------------------------
\* Model Checking Spec for sofastack/sofa-jraft.
\*
\* Wraps the base spec with counter-bounded actions for
\* exhaustive state-space exploration via TLC.
\*
\* Scenarios covered:
\*   - Elections with non-atomic vote persistence (Family 1)
\*   - Missing/incomplete term checks in response handlers (Family 2)
\*   - Joint consensus configuration changes (Family 4)
\*   - Crash / recovery with corrupted meta (Family 1, 5)
\*   - Unreliable network (message loss)

EXTENDS base

\* Access original (un-overridden) operator definitions.
\* Required because cfg uses <- to override operators; without
\* INSTANCE the MC wrappers would recurse into themselves.
baseInst == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

\* Term limits (prevents infinite state space from repeated elections)
CONSTANT MaxTermLimit
ASSUME MaxTermLimit \in Nat

\* Total timeout (election start) events
CONSTANT MaxTimeoutLimit
ASSUME MaxTimeoutLimit \in Nat

\* Client request limits
CONSTANT RequestLimit
ASSUME RequestLimit \in Nat

\* Crash/restart limits
CONSTANT CrashLimit
ASSUME CrashLimit \in Nat

\* Corrupted crash limits (meta file corruption — Family 5)
CONSTANT CorruptedCrashLimit
ASSUME CorruptedCrashLimit \in Nat

\* Message loss limits
CONSTANT LoseLimit
ASSUME LoseLimit \in Nat

\* Heartbeat send limits
CONSTANT HeartbeatLimit
ASSUME HeartbeatLimit \in Nat

\* InstallSnapshot send limits (needed for Family 2)
CONSTANT SnapshotLimit
ASSUME SnapshotLimit \in Nat

\* Configuration change limits
CONSTANT ConfigChangeLimit
ASSUME ConfigChangeLimit \in Nat

\* Message buffer limit for state space pruning
CONSTANT MaxMsgBufferLimit
ASSUME MaxMsgBufferLimit \in Nat

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

\* Counters for bounded actions (aggregated in a record for simpler View)
VARIABLE constraintCounters

faultVars == <<constraintCounters>>

\* ============================================================================
\* MODEL CHECKING CONSTRAINED ACTIONS
\* ============================================================================

\* --- Election Constraints ---
MCElectSelf(i) ==
    /\ currentTerm[i] < MaxTermLimit
    /\ constraintCounters.timeout < MaxTimeoutLimit
    /\ baseInst!ElectSelf(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.timeout = @ + 1]

\* --- Client Request Constraints ---
MCClientRequest(i) ==
    /\ constraintCounters.request < RequestLimit
    /\ baseInst!ClientRequest(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.request = @ + 1]

\* --- Crash Constraints ---
MCCrash(i) ==
    /\ constraintCounters.crash < CrashLimit
    /\ baseInst!Crash(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.crash = @ + 1]

\* --- Corrupted Crash Constraints (Family 5) ---
MCCorruptedCrash(i) ==
    /\ constraintCounters.corruptedCrash < CorruptedCrashLimit
    /\ baseInst!CorruptedCrash(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.corruptedCrash = @ + 1]

\* --- Message Loss Constraints ---
MCLoseMessage(m) ==
    /\ constraintCounters.lose < LoseLimit
    /\ baseInst!LoseMessage(m)
    /\ constraintCounters' = [constraintCounters EXCEPT !.lose = @ + 1]

\* --- Heartbeat Constraints ---
MCSendHeartbeat(i, j) ==
    /\ constraintCounters.heartbeat < HeartbeatLimit
    /\ baseInst!SendHeartbeat(i, j)
    /\ constraintCounters' = [constraintCounters EXCEPT !.heartbeat = @ + 1]

\* --- InstallSnapshot Constraints (Family 2) ---
MCSendInstallSnapshot(i, j) ==
    /\ constraintCounters.snapshot < SnapshotLimit
    /\ baseInst!SendInstallSnapshot(i, j)
    /\ constraintCounters' = [constraintCounters EXCEPT !.snapshot = @ + 1]

\* --- Config Change Constraints ---
MCProposeConfigChange(i, newPeers) ==
    /\ constraintCounters.configChange < ConfigChangeLimit
    /\ baseInst!ProposeConfigChange(i, newPeers)
    /\ constraintCounters' = [constraintCounters EXCEPT !.configChange = @ + 1]

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ constraintCounters = [
         timeout        |-> 0,
         request        |-> 0,
         crash          |-> 0,
         corruptedCrash |-> 0,
         lose           |-> 0,
         heartbeat      |-> 0,
         snapshot       |-> 0,
         configChange   |-> 0]

\* ============================================================================
\* NEXT STATE RELATIONS
\* ============================================================================

\* MCNextAsync(i) - All async actions for a single server i.
MCNextAsync(i) ==
    \* --- Elections ---
    \/ MCElectSelf(i)
    \/ /\ baseInst!PersistElectSelf(i)
       /\ UNCHANGED faultVars
    \/ /\ baseInst!BecomeLeader(i)
       /\ UNCHANGED faultVars
    \* --- Client requests ---
    \/ MCClientRequest(i)
    \* --- Non-atomic persist vote (Extension 1) ---
    \/ /\ baseInst!CompletePersistVote(i)
       /\ UNCHANGED faultVars
    \* --- Commit advancement ---
    \/ /\ baseInst!AdvanceCommitIndex(i)
       /\ UNCHANGED faultVars
    \* --- Config change completion ---
    \/ /\ baseInst!ProposeStableConfig(i)
       /\ UNCHANGED faultVars
    \/ /\ baseInst!StepDownRemovedLeader(i)
       /\ UNCHANGED faultVars
    \* --- Log replication ---
    \/ /\ \E j \in Server : baseInst!AppendEntries(i, j)
       /\ UNCHANGED faultVars
    \* --- Heartbeats ---
    \/ \E j \in Server : MCSendHeartbeat(i, j)
    \* --- InstallSnapshot (Family 2) ---
    \/ \E j \in Server : MCSendInstallSnapshot(i, j)
    \* --- Message receive: only messages destined for server i ---
    \/ /\ \E m \in DOMAIN messages :
           /\ m.mdest = i
           /\ \/ baseInst!HandleRequestVoteRequest(i, m)
              \/ baseInst!HandleRequestVoteResponse(i, m)
              \/ baseInst!HandleAppendEntriesRequest(i, m)
              \/ baseInst!HandleAppendEntriesResponseFailure(i, m)
              \/ baseInst!HandleAppendEntriesResponseSuccess(i, m)
              \/ baseInst!HandleHeartbeatResponse(i, m)
              \/ baseInst!HandleInstallSnapshotRequest(i, m)
              \/ baseInst!HandleInstallSnapshotResponse(i, m)
       /\ UNCHANGED faultVars

\* MCNextCrash - Crash/recovery events
MCNextCrash ==
    \E i \in Server :
        \/ MCCrash(i)
        \/ MCCorruptedCrash(i)

\* MCNextUnreliable - Network unreliability
MCNextUnreliable ==
    \E m \in DOMAIN messages :
        \/ MCLoseMessage(m)
        \/ /\ baseInst!DropStaleMessage(m)
           /\ UNCHANGED faultVars

\* MCNextConfigChange - Configuration changes
MCNextConfigChange ==
    \E i \in Server, newPeers \in SUBSET Server \ {{}} :
        MCProposeConfigChange(i, newPeers)

\* --- Combined Next variants ---

\* Base: no config changes
MCNext ==
    \/ \E i \in Server : MCNextAsync(i)
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

\* Symmetry set over server IDs for state space reduction.
Symmetry == Permutations(Server)

\* View excludes constraintCounters so states differing only in counters
\* are considered identical.
ModelView == <<vars>>

\* ============================================================================
\* STATE SPACE PRUNING CONSTRAINTS
\* ============================================================================

\* Limit network messages buffer size.
MsgBufferConstraint ==
    \/ MaxMsgBufferLimit = 0
    \/ BagCardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* SAFETY INVARIANTS
\* ============================================================================

\* Persisted term is always <= in-memory term.
PersistedTermConsistencyInv ==
    \A i \in Server : persistedTerm[i] <= currentTerm[i]

\* Commit index never exceeds log length.
CommitIndexBoundInv ==
    \A i \in Server : commitIndex[i] <= LastLogIndex(i)

\* Candidates always voted for themselves.
CandidateVotedForSelfInv ==
    \A i \in Server : state[i] = Candidate => votedFor[i] = i

\* Leaders always have a positive term.
LeaderTermPositiveInv ==
    \A i \in Server : state[i] = Leader => currentTerm[i] > 0

\* Pending vote only exists for followers.
PendingVoteStateInv ==
    \A i \in Server : pendingVote[i] /= Nil => state[i] = Follower

\* Config is always a non-empty subset of Server.
ConfigValidInv ==
    \A i \in Server :
        /\ config[i] /= {}
        /\ config[i] \subseteq Server

\* A leader's log contains all committed entries from all servers.
LeaderLogCompleteness ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ commitIndex[s2] > 0) =>
            \A idx \in 1..commitIndex[s2] :
                /\ idx <= LastLogIndex(s1)
                /\ log[s1][idx] = log[s2][idx]

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* Commit index never decreases (except after Crash/CorruptedCrash).
MonotonicCommitIndexProp ==
    [][(~ \E i \in Server : baseInst!Crash(i) \/ baseInst!CorruptedCrash(i)) =>
        \A i \in Server : commitIndex'[i] >= commitIndex[i]]_mc_vars

\* Term never decreases (except after Crash/CorruptedCrash).
MonotonicTermProp ==
    [][(~ \E i \in Server : baseInst!Crash(i) \/ baseInst!CorruptedCrash(i)) =>
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

\* Leader only commits entries from its current term.
LeaderCommitCurrentTermLogsProp ==
    [][
        \A i \in Server :
            (state'[i] = Leader /\ commitIndex[i] /= commitIndex'[i]) =>
                log'[i][commitIndex'[i]].term = currentTerm'[i]
    ]_mc_vars

=============================================================================
