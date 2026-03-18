---------- MODULE MC ----------
\* Model Checking Spec for hashicorp/raft.
\*
\* Wraps the base spec with counter-bounded actions for
\* exhaustive state-space exploration via TLC.
\*
\* Bug families targeted:
\*   Family 1: Leader phantom lease (heartbeat + disk block + lease)
\*   Family 2: Configuration change safety (committed vs latest)
\*   Family 3: Non-atomic persistVote (crash recovery)

EXTENDS base

\* Access original (un-overridden) operator definitions.
\* Required because cfg uses <- to override operators; without
\* INSTANCE the MC wrappers would recurse into themselves.
B == INSTANCE base

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

\* Message loss limits
CONSTANT LoseLimit
ASSUME LoseLimit \in Nat

\* Heartbeat send limits
CONSTANT HeartbeatLimit
ASSUME HeartbeatLimit \in Nat

\* Disk block limits
CONSTANT DiskBlockLimit
ASSUME DiskBlockLimit \in Nat

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
\* Bound: timeout introduces non-determinism (election trigger)
MCTimeout(i) ==
    /\ currentTerm[i] < MaxTermLimit
    /\ constraintCounters.timeout < MaxTimeoutLimit
    /\ B!Timeout(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.timeout = @ + 1]

\* --- Client Request Constraints ---
\* Bound: client requests introduce log entries non-deterministically
MCClientRequest(i) ==
    /\ constraintCounters.request < RequestLimit
    /\ B!ClientRequest(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.request = @ + 1]

\* --- Crash Constraints ---
\* Bound: crash is a fault-injection action
MCCrash(i) ==
    /\ constraintCounters.crash < CrashLimit
    /\ B!Crash(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.crash = @ + 1]

\* --- Message Loss Constraints ---
\* Bound: message loss is a fault-injection action
MCLoseMessage(m) ==
    /\ constraintCounters.lose < LoseLimit
    /\ B!LoseMessage(m)
    /\ constraintCounters' = [constraintCounters EXCEPT !.lose = @ + 1]

\* --- Heartbeat Constraints ---
\* Bound: heartbeat introduces lease contacts non-deterministically
MCSendHeartbeat(i, j) ==
    /\ constraintCounters.heartbeat < HeartbeatLimit
    /\ B!SendHeartbeat(i, j)
    /\ constraintCounters' = [constraintCounters EXCEPT !.heartbeat = @ + 1]

\* --- Disk Block Constraints ---
\* Bound: disk blocking is a fault-injection action
MCDiskBlock(i) ==
    /\ constraintCounters.diskBlock < DiskBlockLimit
    /\ B!DiskBlock(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.diskBlock = @ + 1]

\* --- Config Change Constraints ---
\* Bound: config changes introduce non-determinism
MCProposeConfigChange(i, s) ==
    /\ constraintCounters.configChange < ConfigChangeLimit
    /\ B!ProposeConfigChange(i, s)
    /\ constraintCounters' = [constraintCounters EXCEPT !.configChange = @ + 1]

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ constraintCounters = [
         timeout     |-> 0,
         request     |-> 0,
         crash       |-> 0,
         lose        |-> 0,
         heartbeat   |-> 0,
         diskBlock   |-> 0,
         configChange |-> 0]

\* ============================================================================
\* NEXT STATE RELATIONS
\* ============================================================================

\* MCNextAsync(i) - All async actions for a single server i.
\* Allows external quantification: \E i \in Server : MCNextAsync(i)
MCNextAsync(i) ==
    \* --- Elections ---
    \/ MCTimeout(i)
    \/ /\ B!BecomeLeader(i)
       /\ UNCHANGED faultVars
    \* --- Client requests ---
    \/ MCClientRequest(i)
    \* --- Non-atomic persist vote (Extension 5) ---
    \/ /\ B!CompletePersistVote(i)
       /\ UNCHANGED faultVars
    \* --- Leader lease (Extension 2) ---
    \/ /\ B!CheckLeaderLease(i)
       /\ UNCHANGED faultVars
    \* --- Disk IO (Extension 3) ---
    \/ MCDiskBlock(i)
    \/ /\ B!DiskUnblock(i)
       /\ UNCHANGED faultVars
    \* --- Commit advancement ---
    \/ /\ B!AdvanceCommitIndex(i)
       /\ UNCHANGED faultVars
    \* --- Log replication ---
    \/ /\ \E j \in Server : B!ReplicateEntries(i, j)
       /\ UNCHANGED faultVars
    \* --- Heartbeats (independent of disk IO) ---
    \/ \E j \in Server : MCSendHeartbeat(i, j)
    \* --- Message receive: only messages destined for server i ---
    \/ /\ \E m \in DOMAIN messages :
           /\ m.mdest = i
           /\ \/ B!HandleRequestVoteRequest(i, m)
              \/ B!HandleRequestVoteResponse(i, m)
              \/ B!HandleAppendEntriesRequest(i, m)
              \/ B!HandleReplicateResponse(i, m)
              \/ B!HandleHeartbeatResponse(i, m)
       /\ UNCHANGED faultVars

\* MCNextCrash - Crash/recovery events
MCNextCrash == \E i \in Server : MCCrash(i)

\* MCNextUnreliable - Network unreliability
MCNextUnreliable ==
    \E m \in DOMAIN messages :
        \/ MCLoseMessage(m)
        \/ /\ B!DropStaleMessage(m)
           /\ UNCHANGED faultVars

\* MCNextConfigChange - Configuration changes
MCNextConfigChange ==
    \E i, s \in Server : MCProposeConfigChange(i, s)

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
\* Returns FALSE when message count exceeds limit, causing TLC to prune.
\* If MaxMsgBufferLimit = 0, no limit is applied.
MsgBufferConstraint ==
    \/ MaxMsgBufferLimit = 0
    \/ BagCardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* STRUCTURAL INVARIANTS (sanity checks that hold in all correct states)
\* ============================================================================

\* Persisted term is always <= in-memory term.
\* Crash recovery restores currentTerm from persistedTerm, so this holds
\* in all reachable states.
PersistedTermConsistencyInv ==
    \A i \in Server : persistedTerm[i] <= currentTerm[i]

\* Commit index never exceeds log length.
CommitIndexBoundInv ==
    \A i \in Server : commitIndex[i] <= LastLogIndex(i)

\* Candidates always voted for themselves.
\* Reference: Timeout(i) sets votedFor[i] = i, and no action changes
\* votedFor without also changing state away from Candidate.
CandidateVotedForSelfInv ==
    \A i \in Server : state[i] = Candidate => votedFor[i] = i

\* Leaders always have a positive term (can't be leader in term 0).
LeaderTermPositiveInv ==
    \A i \in Server : state[i] = Leader => currentTerm[i] > 0

\* Pending vote only exists for followers.
\* Timeout(i) requires pendingVote[i] = Nil, so a server with pending
\* vote cannot become a candidate or leader.
PendingVoteStateInv ==
    \A i \in Server : pendingVote[i] /= Nil => state[i] = Follower

\* Latest config is always a non-empty subset of Server.
LatestConfigValidInv ==
    \A i \in Server :
        /\ latestConfig[i] /= {}
        /\ latestConfig[i] \subseteq Server

\* Committed config is always a non-empty subset of Server.
CommittedConfigValidInv ==
    \A i \in Server :
        /\ committedConfig[i] /= {}
        /\ committedConfig[i] \subseteq Server

\* A leader's log contains all committed entries from all servers.
\* Stronger than LeaderCompleteness: checks full entry equality, not just term.
\* Guard: only entries committed at or before the leader's term.
LeaderLogCompleteness ==
    \A leader \in Server :
        state[leader] = Leader =>
            \A other \in Server :
                \A idx \in 1..commitIndex[other] :
                    log[other][idx].term <= currentTerm[leader] =>
                        /\ idx <= LastLogIndex(leader)
                        /\ log[leader][idx] = log[other][idx]

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
\* Reference: Raft paper Figure 3, Property 2
LeaderAppendOnlyProp ==
    [][
        \A i \in Server :
            (state[i] = Leader /\ state'[i] = Leader) =>
                /\ Len(log'[i]) >= Len(log[i])
                /\ SubSeq(log'[i], 1, Len(log[i])) =
                   SubSeq(log[i], 1, Len(log[i]))
    ]_mc_vars

\* Leader only commits entries from its current term (Raft paper §5.4.2).
\* Prevents the Figure 8 safety issue.
LeaderCommitCurrentTermLogsProp ==
    [][
        \A i \in Server :
            (state'[i] = Leader /\ commitIndex[i] /= commitIndex'[i]) =>
                log'[i][commitIndex'[i]].term = currentTerm'[i]
    ]_mc_vars

=============================================================================
