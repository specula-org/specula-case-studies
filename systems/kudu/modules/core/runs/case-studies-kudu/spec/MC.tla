---------- MODULE MC ----------
\* Model Checking Spec for Apache Kudu Raft consensus.
\*
\* Wraps the base spec with counter-bounded actions for
\* exhaustive state-space exploration via TLC.
\*
\* Bug families targeted:
\*   Family 1: Commit index / log matching safety
\*   Family 2: Configuration change safety
\*   Family 3: Election / leader stability
\*   Family 4: Operation ordering / role transition

EXTENDS base

\* Access original (un-overridden) operator definitions.
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

\* Heartbeat send limits
CONSTANT HeartbeatLimit
ASSUME HeartbeatLimit \in Nat

\* Message loss limits
CONSTANT LoseLimit
ASSUME LoseLimit \in Nat

\* Step down limits
CONSTANT StepDownLimit
ASSUME StepDownLimit \in Nat

\* Pre-vote limits
CONSTANT PreVoteLimit
ASSUME PreVoteLimit \in Nat

\* Configuration change limits
CONSTANT ConfigChangeLimit
ASSUME ConfigChangeLimit \in Nat

\* Expire withhold votes limits
CONSTANT ExpireWithholdLimit
ASSUME ExpireWithholdLimit \in Nat

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

\* --- Pre-Vote Constraints ---
\* Bound: pre-vote introduces non-determinism
MCPreVote(i) ==
    /\ currentTerm[i] < MaxTermLimit
    /\ constraintCounters.preVote < PreVoteLimit
    /\ B!PreVote(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.preVote = @ + 1]

\* --- Client Request Constraints ---
\* Bound: client requests introduce log entries non-deterministically
MCClientRequest(i) ==
    /\ constraintCounters.request < RequestLimit
    /\ B!ClientRequest(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.request = @ + 1]

\* --- Heartbeat Constraints ---
\* REMOVED: SendHeartbeat was removed from base spec.
\* Heartbeats are now modeled as SendEntries with empty entries.

\* --- Message Loss Constraints ---
\* Bound: message loss is a fault-injection action
MCLoseMessage(m) ==
    /\ constraintCounters.lose < LoseLimit
    /\ B!LoseMessage(m)
    /\ constraintCounters' = [constraintCounters EXCEPT !.lose = @ + 1]

\* --- Step Down Constraints ---
\* Bound: step down is a fault-injection action
MCStepDown(i) ==
    /\ constraintCounters.stepDown < StepDownLimit
    /\ B!StepDown(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.stepDown = @ + 1]

\* --- Config Change Constraints ---
\* Bound: config changes introduce non-determinism
MCProposeConfigChange(i, s) ==
    /\ constraintCounters.configChange < ConfigChangeLimit
    /\ B!ProposeConfigChange(i, s)
    /\ constraintCounters' = [constraintCounters EXCEPT !.configChange = @ + 1]

\* --- Expire Withhold Constraints ---
\* Bound: withhold expiry introduces non-determinism
MCExpireWithholdVotes(i) ==
    /\ constraintCounters.expireWithhold < ExpireWithholdLimit
    /\ B!ExpireWithholdVotes(i)
    /\ constraintCounters' = [constraintCounters EXCEPT !.expireWithhold = @ + 1]

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ constraintCounters = [
         timeout        |-> 0,
         preVote        |-> 0,
         request        |-> 0,
         heartbeat      |-> 0,
         lose           |-> 0,
         stepDown       |-> 0,
         configChange   |-> 0,
         expireWithhold |-> 0]

\* ============================================================================
\* NEXT STATE RELATIONS
\* ============================================================================

\* MCNextAsync(i) - All async actions for a single server i.
MCNextAsync(i) ==
    \* --- Elections ---
    \/ MCTimeout(i)
    \/ MCPreVote(i)
    \/ /\ B!BecomeLeader(i)
       /\ UNCHANGED faultVars
    \* --- Client requests ---
    \/ MCClientRequest(i)
    \* --- Step down ---
    \/ MCStepDown(i)
    \* --- Commit advancement ---
    \/ /\ B!AdvanceCommitIndex(i)
       /\ UNCHANGED faultVars
    \* --- Withhold votes expiry ---
    \/ MCExpireWithholdVotes(i)
    \* --- Log replication (includes heartbeats as empty SendEntries) ---
    \/ /\ \E j \in Server : B!SendEntries(i, j)
       /\ UNCHANGED faultVars
    \* --- Message receive: only messages destined for server i ---
    \/ /\ \E m \in DOMAIN messages :
           /\ m.mdest = i
           /\ \/ B!HandleRequestVoteRequest(i, m)
              \/ B!HandleRequestVoteResponse(i, m)
              \/ B!HandleAppendEntriesRequest(i, m)
              \/ B!HandleAppendEntriesResponse(i, m)
       /\ UNCHANGED faultVars

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
\* STRUCTURAL INVARIANTS (sanity checks that hold in all correct states)
\* ============================================================================

\* Commit index never exceeds log length.
CommitIndexBoundInv ==
    \A i \in Server : commitIndex[i] <= LastLogIndex(i)

\* Candidates always voted for themselves (for real elections).
CandidateVotedForSelfInv ==
    \A i \in Server :
        (state[i] = Candidate /\ votedFor[i] /= Nil) => votedFor[i] = i

\* Leaders always have a positive term.
LeaderTermPositiveInv ==
    \A i \in Server : state[i] = Leader => currentTerm[i] > 0

\* Active config is always a non-empty subset of Server.
ActiveConfigValidInv ==
    \A i \in Server :
        /\ ActiveConfig(i) /= {}
        /\ ActiveConfig(i) \subseteq Server

\* Committed config is always a non-empty subset of Server.
CommittedConfigValidInv ==
    \A i \in Server :
        /\ committedConfig[i] /= {}
        /\ committedConfig[i] \subseteq Server

\* A leader's log contains all committed entries from all servers.
\* Only checked against the highest-term leader (stale leaders excluded).
LeaderLogCompleteness ==
    \A leader \in Server :
        /\ state[leader] = Leader
        /\ \A other \in Server : currentTerm[other] <= currentTerm[leader]
        =>
            \A other \in Server :
                \A idx \in 1..commitIndex[other] :
                    log[other][idx].term <= currentTerm[leader] =>
                        /\ idx <= LastLogIndex(leader)
                        /\ log[leader][idx] = log[other][idx]

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* Term never decreases.
MonotonicTermProp ==
    [][\A i \in Server : currentTerm'[i] >= currentTerm[i]]_mc_vars

\* Leader only appends to its log, never truncates.
LeaderAppendOnlyProp ==
    [][
        \A i \in Server :
            (state[i] = Leader /\ state'[i] = Leader) =>
                /\ Len(log'[i]) >= Len(log[i])
                /\ SubSeq(log'[i], 1, Len(log[i])) =
                   SubSeq(log[i], 1, Len(log[i]))
    ]_mc_vars

\* Leader only commits entries from its current term (Raft paper section 5.4.2).
LeaderCommitCurrentTermLogsProp ==
    [][
        \A i \in Server :
            (state'[i] = Leader /\ commitIndex[i] /= commitIndex'[i]) =>
                log'[i][commitIndex'[i]].term = currentTerm'[i]
    ]_mc_vars

=============================================================================
