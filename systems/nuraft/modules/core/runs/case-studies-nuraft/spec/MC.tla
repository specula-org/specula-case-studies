------------------------------ MODULE MC ------------------------------
\* Model checking wrapper for nuraft base spec.
\*
\* Counter-bounded fault-injection actions, symmetry reduction,
\* message buffer constraint, and structural invariants.
\*
EXTENDS base

----
\* MC Constants
----

CONSTANT MaxTerm             \* Upper bound on term values
CONSTANT MaxLogLength        \* Upper bound on log length per server

----
\* Counter Variables
----

\* One counter per fault-injection / non-deterministic action.
\* Deterministic/reactive actions (message handlers) are NOT bounded.
VARIABLE faultCounters
\* Record fields:
\*   timeout      -- Timeout (election timeout, pre-vote start)
\*   clientReq    -- ClientRequest (leader appends entry)
\*   crash        -- Crash (crash and recovery)
\*   loseMsg      -- LoseMessage (network partition)
\*   configChange -- ProposeConfigChange (config changes)
\*   bypass       -- BypassConfigGuard (set_priority bypass)
\*   adjustQuorum -- AdjustQuorum (quorum adjustment)
\*   restoreQuorum -- RestoreQuorum
\*   heartbeat    -- AppendEntries (heartbeat/replication)
\*   persistState -- PersistState

faultVars == <<faultCounters>>
mcVars == <<vars, faultVars>>

----
\* MC Limits (set via cfg CONSTANTS)
----

CONSTANT TimeoutLimit        \* Max timeouts across all servers
CONSTANT ClientReqLimit      \* Max client requests
CONSTANT CrashLimit          \* Max crashes
CONSTANT LoseLimit           \* Max lost messages
CONSTANT ConfigChangeLimit   \* Max config changes
CONSTANT BypassLimit         \* Max config guard bypasses
CONSTANT AdjustQuorumLimit   \* Max quorum adjustments
CONSTANT RestoreQuorumLimit  \* Max quorum restorations
CONSTANT HeartbeatLimit      \* Max AE sends
CONSTANT PersistLimit        \* Max persist actions
CONSTANT MaxMsgCount         \* Max messages in flight

----
\* Counter-bounded wrappers
----

MCTimeout(i) ==
    /\ faultCounters.timeout < TimeoutLimit
    /\ Timeout(i)
    /\ faultCounters' = [faultCounters EXCEPT !.timeout = @ + 1]

MCClientRequest(i) ==
    /\ faultCounters.clientReq < ClientReqLimit
    /\ LastLogIndex(i) < MaxLogLength
    /\ ClientRequest(i)
    /\ faultCounters' = [faultCounters EXCEPT !.clientReq = @ + 1]

MCCrash(i) ==
    /\ faultCounters.crash < CrashLimit
    /\ Crash(i)
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

MCLoseMessage(m) ==
    /\ faultCounters.loseMsg < LoseLimit
    /\ LoseMessage(m)
    /\ faultCounters' = [faultCounters EXCEPT !.loseMsg = @ + 1]

MCProposeConfigChange(i) ==
    /\ faultCounters.configChange < ConfigChangeLimit
    /\ LastLogIndex(i) < MaxLogLength
    /\ ProposeConfigChange(i)
    /\ faultCounters' = [faultCounters EXCEPT !.configChange = @ + 1]

MCBypassConfigGuard(i) ==
    /\ faultCounters.bypass < BypassLimit
    /\ LastLogIndex(i) < MaxLogLength
    /\ BypassConfigGuard(i)
    /\ faultCounters' = [faultCounters EXCEPT !.bypass = @ + 1]

MCAdjustQuorum(i) ==
    /\ faultCounters.adjustQuorum < AdjustQuorumLimit
    /\ AdjustQuorum(i)
    /\ faultCounters' = [faultCounters EXCEPT !.adjustQuorum = @ + 1]

MCRestoreQuorum(i) ==
    /\ faultCounters.restoreQuorum < RestoreQuorumLimit
    /\ RestoreQuorum(i)
    /\ faultCounters' = [faultCounters EXCEPT !.restoreQuorum = @ + 1]

MCAppendEntries(i, j) ==
    /\ faultCounters.heartbeat < HeartbeatLimit
    /\ AppendEntries(i, j)
    /\ faultCounters' = [faultCounters EXCEPT !.heartbeat = @ + 1]

MCPersistState(i) ==
    /\ faultCounters.persistState < PersistLimit
    /\ PersistState(i)
    /\ faultCounters' = [faultCounters EXCEPT !.persistState = @ + 1]

----
\* Unconstrained wrappers (reactive/deterministic actions)
----

MCInitiateVote(i) ==
    /\ currentTerm[i] + 1 <= MaxTerm
    /\ InitiateVote(i)
    /\ UNCHANGED faultVars

MCBecomeLeader(i) ==
    /\ BecomeLeader(i)
    /\ UNCHANGED faultVars

MCAdvanceCommitIndex(i) ==
    /\ AdvanceCommitIndex(i)
    /\ UNCHANGED faultVars

MCCommitEntry(i) ==
    /\ CommitEntry(i)
    /\ UNCHANGED faultVars

MCHandlePreVoteRequest(i, m) ==
    /\ HandlePreVoteRequest(i, m)
    /\ UNCHANGED faultVars

MCHandlePreVoteResponse(i, m) ==
    /\ HandlePreVoteResponse(i, m)
    /\ UNCHANGED faultVars

MCHandleVoteRequest(i, m) ==
    /\ HandleVoteRequest(i, m)
    /\ UNCHANGED faultVars

MCHandleVoteResponse(i, m) ==
    /\ HandleVoteResponse(i, m)
    /\ UNCHANGED faultVars

MCHandleAppendEntries(i, m) ==
    /\ HandleAppendEntries(i, m)
    /\ UNCHANGED faultVars

MCHandleAppendEntriesResponse(i, m) ==
    /\ HandleAppendEntriesResponse(i, m)
    /\ UNCHANGED faultVars

MCDropStaleMessage(m) ==
    /\ DropStaleMessage(m)
    /\ UNCHANGED faultVars

----
\* Init and Next
----

MCInit ==
    /\ Init
    /\ faultCounters = [
           timeout       |-> 0,
           clientReq     |-> 0,
           crash         |-> 0,
           loseMsg       |-> 0,
           configChange  |-> 0,
           bypass        |-> 0,
           adjustQuorum  |-> 0,
           restoreQuorum |-> 0,
           heartbeat     |-> 0,
           persistState  |-> 0
       ]

MCNext ==
    \/ \E i \in Server :
        \/ MCTimeout(i)
        \/ MCInitiateVote(i)
        \/ MCPersistState(i)
        \/ MCBecomeLeader(i)
        \/ MCClientRequest(i)
        \/ MCAdvanceCommitIndex(i)
        \/ MCCommitEntry(i)
        \/ MCProposeConfigChange(i)
        \/ MCBypassConfigGuard(i)
        \/ MCAdjustQuorum(i)
        \/ MCRestoreQuorum(i)
        \/ MCCrash(i)
    \/ \E i, j \in Server :
        \/ MCAppendEntries(i, j)
    \/ \E m \in DOMAIN messages :
        \/ MCHandlePreVoteRequest(m.mdest, m)
        \/ MCHandlePreVoteResponse(m.mdest, m)
        \/ MCHandleVoteRequest(m.mdest, m)
        \/ MCHandleVoteResponse(m.mdest, m)
        \/ MCHandleAppendEntries(m.mdest, m)
        \/ MCHandleAppendEntriesResponse(m.mdest, m)
        \/ MCDropStaleMessage(m)
        \/ MCLoseMessage(m)

----
\* State space pruning
----

\* Limit messages in flight to prevent state space explosion.
MsgBufferConstraint ==
    BagCardinality(messages) <= MaxMsgCount

\* Limit term growth.
TermConstraint ==
    \A s \in Server : currentTerm[s] <= MaxTerm

\* Limit log growth.
LogConstraint ==
    \A s \in Server : LastLogIndex(s) <= MaxLogLength

StateConstraint ==
    /\ MsgBufferConstraint
    /\ TermConstraint
    /\ LogConstraint

----
\* Symmetry
----

\* Permutations of Server for symmetry reduction.
\* Exclude faultCounters from view (they don't affect correctness).
ModelSymmetry == Permutations(Server)

----
\* Structural Invariants
----

\* Committed entries should have matching terms across servers.
CommittedEntriesMatch ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(smCommitIndex[s1], smCommitIndex[s2]) :
            log[s1][idx] = log[s2][idx]

\* A leader's own matched index should be its precommit index.
LeaderSelfConsistency ==
    \A s \in Server :
        state[s] = Leader =>
            \A t \in Server \ {s} :
                nextIndex[s][t] >= 1

=============================================================================
