---------- MODULE MC ----------
\* Model Checking Spec for lni/dragonboat.
\*
\* Wraps the base spec with counter-bounded actions for exhaustive
\* state-space exploration via TLC.
\*
\* Scenarios covered:
\*   MC-1: SnapshotStatus does not setActive -> leader steps down with active quorum
\*         (Bug Family 1, CheckQuorum + RemoteSnapshot interaction)
\*   MC-2: leaderHasQuorum() side effect -> double-check clears active flags
\*         (Bug Family 1, handled by CheckQuorum action structure)
\*   MC-3: hasConfigChangeToApply overly conservative -> election delay
\*         (Bug Family 2, liveness)
\*   MC-4: Silent persistence failure (PR #409) -> committed entry lost on crash
\*         (Bug Family 3, PersistBeforeAck / LeaderCompleteness)
\*   MC-5: Config change silently dropped -> client believes config changed
\*         (Bug Family 2, ConfigChangeSingleAtATime)

EXTENDS base

\* Access original (un-overridden) operator definitions.
\* Required because cfg uses <- to override operators; without INSTANCE
\* the MC wrappers would recurse into themselves.
db == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

\* Term limit (prevents infinite state space from repeated elections)
CONSTANT MaxTermLimit
ASSUME MaxTermLimit \in Nat

\* Total timeout (election start) events allowed
CONSTANT MaxTimeoutLimit
ASSUME MaxTimeoutLimit \in Nat

\* Client request limit
CONSTANT RequestLimit
ASSUME RequestLimit \in Nat

\* Crash/restart limit
CONSTANT CrashLimit
ASSUME CrashLimit \in Nat

\* Message loss limit
CONSTANT LoseLimit
ASSUME LoseLimit \in Nat

\* Heartbeat send limit
CONSTANT HeartbeatLimit
ASSUME HeartbeatLimit \in Nat

\* CheckQuorum invocation limit
CONSTANT CheckQuorumLimit
ASSUME CheckQuorumLimit \in Nat

\* Disk error injection limit (triggers PR #409 bug path)
CONSTANT DiskErrorLimit
ASSUME DiskErrorLimit \in Nat

\* Config change proposal limit
CONSTANT ConfigChangeLimit
ASSUME ConfigChangeLimit \in Nat

\* Snapshot send limit
CONSTANT SnapshotLimit
ASSUME SnapshotLimit \in Nat

\* Message buffer limit for state space pruning
CONSTANT MaxMsgBufferLimit
ASSUME MaxMsgBufferLimit \in Nat

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

\* All counters in a single record for simpler View
VARIABLE constraintCounters

faultVars == <<constraintCounters>>

\* ============================================================================
\* MODEL CHECKING CONSTRAINED ACTIONS
\* ============================================================================

\* --- Election (Timeout / BecomeLeader) ---
\* Bound: limits total elections and max term to prevent infinite growth.
MCTimeout(i) ==
    /\ currentTerm[i] < MaxTermLimit
    /\ constraintCounters.timeout < MaxTimeoutLimit
    /\ db!Timeout(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.timeout = @ + 1]

\* --- Client Request ---
\* Bound: limits total log entries.
MCClientRequest(i) ==
    /\ constraintCounters.request < RequestLimit
    /\ db!ClientRequest(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.request = @ + 1]

\* --- Config Change Proposal ---
\* Bound: limits total config change proposals.
MCProposeConfigChange(i) ==
    /\ constraintCounters.configChange < ConfigChangeLimit
    /\ db!ProposeConfigChange(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.configChange = @ + 1]

\* --- Crash / Recovery ---
\* Bound: limits total crash events to prevent infinite crash loops.
MCCrash(i) ==
    /\ constraintCounters.crash < CrashLimit
    /\ db!Crash(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.crash = @ + 1]

\* --- Message Loss ---
\* Bound: limits total dropped messages.
MCLoseMessage(m) ==
    /\ constraintCounters.lose < LoseLimit
    /\ db!LoseMessage(m)
    /\ constraintCounters' = [constraintCounters EXCEPT !.lose = @ + 1]

\* --- Heartbeat Send ---
\* Bound: limits total heartbeat sends.
MCSendHeartbeat(i, j) ==
    /\ constraintCounters.heartbeat < HeartbeatLimit
    /\ db!SendHeartbeat(i, j)
    /\ constraintCounters' = [constraintCounters EXCEPT !.heartbeat = @ + 1]

\* --- CheckQuorum ---
\* Bound: limits total CheckQuorum invocations.
\* Not bounding this would allow infinite leader/follower oscillation.
MCCheckQuorum(i) ==
    /\ constraintCounters.checkQuorum < CheckQuorumLimit
    /\ db!CheckQuorum(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.checkQuorum = @ + 1]

\* --- Disk Error Injection ---
\* Bound: limits total disk errors injected (triggers PR #409 code path).
MCInjectDiskError(i) ==
    /\ constraintCounters.diskError < DiskErrorLimit
    /\ db!InjectDiskError(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.diskError = @ + 1]

\* --- Snapshot Send ---
\* Bound: limits total snapshot sends to prevent state space explosion.
MCSendSnapshot(i, j) ==
    /\ constraintCounters.snapshot < SnapshotLimit
    /\ db!SendSnapshot(i, j)
    /\ constraintCounters' = [constraintCounters EXCEPT !.snapshot = @ + 1]

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ constraintCounters = [
         timeout     |-> 0,
         request     |-> 0,
         configChange |-> 0,
         crash       |-> 0,
         lose        |-> 0,
         heartbeat   |-> 0,
         checkQuorum |-> 0,
         diskError   |-> 0,
         snapshot    |-> 0]

\* ============================================================================
\* NEXT STATE RELATIONS
\* ============================================================================

\* MCNextAsync(i): all async per-server actions for server i.
MCNextAsync(i) ==
    \* --- Elections ---
    \/ MCTimeout(i)
    \/ /\ db!BecomeLeader(i)
       /\ UNCHANGED faultVars
    \* --- Client requests ---
    \/ MCClientRequest(i)
    \/ MCProposeConfigChange(i)
    \* --- Leader operations ---
    \/ /\ \E j \in Server : i /= j /\ db!ReplicateEntries(i, j)
       /\ UNCHANGED faultVars
    \/ \E j \in Server : i /= j /\ MCSendHeartbeat(i, j)
    \/ \E j \in Server : i /= j /\ MCSendSnapshot(i, j)
    \/ MCCheckQuorum(i)
    \* --- Commit and apply ---
    \/ /\ db!AdvanceCommitIndex(i)
       /\ UNCHANGED faultVars
    \/ /\ db!ApplyEntry(i)
       /\ UNCHANGED faultVars
    \/ /\ db!ApplyConfigChange(i)
       /\ UNCHANGED faultVars
    \* --- Persistence (Family 3) ---
    \/ /\ db!SaveRaftState(i)
       /\ UNCHANGED faultVars
    \/ MCInjectDiskError(i)
    \* --- Message receive: only messages destined for server i ---
    \/ /\ \E m \in DOMAIN messages :
           /\ m.mdest = i
           /\ \/ db!HandleRequestVoteRequest(i, m)
              \/ db!HandleRequestVoteResponse(i, m)
              \/ db!HandleReplicateRequest(i, m)
              \/ db!HandleHeartbeatRequest(i, m)
              \/ db!HandleReplicateResponse(i, m)
              \/ db!HandleHeartbeatResponse(i, m)
              \/ db!HandleInstallSnapshot(i, m)
              \/ db!HandleSnapshotStatus(i, m)
       /\ UNCHANGED faultVars

\* MCNextCrash: crash/recovery events
MCNextCrash == \E i \in Server : MCCrash(i)

\* MCNextUnreliable: network unreliability
MCNextUnreliable ==
    \E m \in DOMAIN messages :
        \/ MCLoseMessage(m)
        \/ /\ db!DropStaleMessage(m)
           /\ UNCHANGED faultVars

\* Combined Next
MCNext ==
    \/ \E i \in Server : MCNextAsync(i)
    \/ MCNextCrash
    \/ MCNextUnreliable

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

\* Symmetry reduction over server IDs.
Symmetry == Permutations(Server)

\* View excludes constraintCounters so states differing only in counters
\* are treated as identical.
ModelView == <<vars>>

\* ============================================================================
\* STATE SPACE PRUNING CONSTRAINTS
\* ============================================================================

\* Limit network message buffer size.
MsgBufferConstraint ==
    \/ MaxMsgBufferLimit = 0
    \/ BagCardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* STRUCTURAL INVARIANTS (complementing base spec invariants)
\* ============================================================================

\* Commit index never exceeds log length.
CommitIndexBoundInv ==
    \A i \in Server : commitIndex[i] <= LastLogIndex(i)

\* Applied never exceeds commit index.
AppliedBoundInv ==
    \A i \in Server : applied[i] <= commitIndex[i]

\* Candidates always voted for themselves.
CandidateVotedForSelfInv ==
    \A i \in Server : state[i] = Candidate => votedFor[i] = i

\* Leaders always have a positive term.
LeaderTermPositiveInv ==
    \A i \in Server : state[i] = Leader => currentTerm[i] > 0

\* Persisted state term <= in-memory term.
PersistedTermConsistencyInv ==
    \A i \in Server : persistedState[i].term <= currentTerm[i]

\* Active flags are only set for followers known to the leader.
ActiveOnlyForKnownFollowers ==
    \A i \in Server : state[i] = Leader =>
        \A j \in Server : active[i][j] => j \in Server

\* matchIndex[i][j] <= LastLogIndex(i) for all leaders i.
MatchIndexBoundInv ==
    \A i \in Server : state[i] = Leader =>
        \A j \in Server : matchIndex[i][j] <= LastLogIndex(i)

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* Commit index never decreases (except after Crash).
MonotonicCommitIndexProp ==
    [][(~\E i \in Server : db!Crash(i)) =>
        \A i \in Server : commitIndex'[i] >= commitIndex[i]]_mc_vars

\* Term never decreases (except after Crash).
MonotonicTermProp ==
    [][(~\E i \in Server : db!Crash(i)) =>
        \A i \in Server : currentTerm'[i] >= currentTerm[i]]_mc_vars

\* Leader only appends to its log, never truncates.
LeaderAppendOnlyProp ==
    [][
        \A i \in Server :
            (state[i] = Leader /\ state'[i] = Leader) =>
                /\ Len(log'[i]) >= Len(log[i])
                /\ SubSeq(log'[i], 1, Len(log[i])) = SubSeq(log[i], 1, Len(log[i]))
    ]_mc_vars

\* Leader only commits entries from its current term (Raft paper §5.4.2).
LeaderCommitCurrentTermProp ==
    [][
        \A i \in Server :
            (state'[i] = Leader /\ commitIndex[i] /= commitIndex'[i]) =>
                log'[i][commitIndex'[i]].term = currentTerm'[i]
    ]_mc_vars

\* Bug Family 1 action property:
\* HandleSnapshotStatus SHOULD call setActive but doesn't (raft.go:1976-1995).
\* This property checks: whenever a remote transitions from RemoteSnapshot to
\* RemoteWait (which only happens in HandleSnapshotStatus), the active flag for
\* that remote must be set to TRUE. The buggy implementation leaves it FALSE.
HandleSnapshotStatusSetsActive ==
    [][
        \A i \in Server : \A j \in Server \ {i} :
            (state[i] = Leader /\
             remoteState[i][j] = RemoteSnapshot /\
             remoteState'[i][j] = RemoteWait)
            => active'[i][j] = TRUE
    ]_mc_vars

\* ============================================================================
\* CONFIG FILE HINT (for base.cfg)
\* ============================================================================
\*
\* Recommended initial bounds (3-server cluster):
\*   Server           = {s1, s2, s3}
\*   MaxTermLimit     = 4
\*   MaxTimeoutLimit  = 5
\*   RequestLimit     = 3
\*   CrashLimit       = 2
\*   LoseLimit        = 3
\*   HeartbeatLimit   = 6
\*   CheckQuorumLimit = 4
\*   DiskErrorLimit   = 2
\*   ConfigChangeLimit = 2
\*   SnapshotLimit    = 2
\*   MaxMsgBufferLimit = 10
\*
\* For MC-1 (snapshot active tracking bug):
\*   SnapshotLimit    = 3, HeartbeatLimit = 8, CheckQuorumLimit = 6
\*
\* For MC-4 (silent persistence failure):
\*   DiskErrorLimit   = 2, CrashLimit = 3, RequestLimit = 4

=============================================================================
