---- MODULE MC ----
\* Model checking wrapper for Apache Ratis base spec.
\* Adds counter-bounded fault injection, symmetry reduction, and structural invariants.

EXTENDS base

CONSTANTS
    MaxTimeoutLimit,     \* Bound on Timeout actions
    MaxPreVoteLimit,     \* Bound on PreVote actions
    MaxRequestLimit,     \* Bound on ClientRequest actions
    MaxCrashLimit,       \* Bound on Crash actions
    MaxLoseLimit,        \* Bound on LoseMessage actions
    MaxHeartbeatLimit,   \* Bound on Heartbeat actions
    MaxConfigChangeLimit,\* Bound on ProposeConfigChange actions
    MaxReadLimit,        \* Bound on ClientRead actions
    MaxSnapshotLimit,    \* Bound on TakeSnapshot actions
    MaxCheckLeadershipLimit, \* Bound on CheckLeadership actions
    MaxExpireLeaseLimit, \* Bound on ExpireLease actions
    MaxExpireLeaderValidityLimit, \* Bound on ExpireLeaderValidity actions
    MaxMsgBufferLimit    \* Maximum messages in flight

\* ============================================================================
\* Counter Variables
\* ============================================================================

VARIABLE faultVars
\* faultVars is a record:
\*   [timeoutCount, preVoteCount, requestCount, crashCount, loseCount,
\*    heartbeatCount, configChangeCount, readCount, snapshotCount,
\*    checkLeadershipCount, expireLeaseCount, expireLeaderValidityCount]

mcVars == <<vars, faultVars>>

\* ============================================================================
\* Counter-Bounded Wrappers
\* ============================================================================

MCTimeout(s) ==
    /\ faultVars.timeoutCount < MaxTimeoutLimit
    /\ Timeout(s)
    /\ faultVars' = [faultVars EXCEPT !.timeoutCount = @ + 1]

MCPreVote(s) ==
    /\ faultVars.preVoteCount < MaxPreVoteLimit
    /\ StartPreVote(s)
    /\ faultVars' = [faultVars EXCEPT !.preVoteCount = @ + 1]

MCClientRequest(s, v) ==
    /\ faultVars.requestCount < MaxRequestLimit
    /\ ClientRequest(s, v)
    /\ faultVars' = [faultVars EXCEPT !.requestCount = @ + 1]

MCCrash(s) ==
    /\ faultVars.crashCount < MaxCrashLimit
    /\ Crash(s)
    /\ faultVars' = [faultVars EXCEPT !.crashCount = @ + 1]

MCLoseMessage(m) ==
    /\ faultVars.loseCount < MaxLoseLimit
    /\ LoseMessage(m)
    /\ faultVars' = [faultVars EXCEPT !.loseCount = @ + 1]

MCHeartbeat(s, t) ==
    /\ faultVars.heartbeatCount < MaxHeartbeatLimit
    /\ Heartbeat(s, t)
    /\ faultVars' = [faultVars EXCEPT !.heartbeatCount = @ + 1]

MCProposeConfigChange(s, newPeers) ==
    /\ faultVars.configChangeCount < MaxConfigChangeLimit
    /\ ProposeConfigChange(s, newPeers)
    /\ faultVars' = [faultVars EXCEPT !.configChangeCount = @ + 1]

MCClientRead(s) ==
    /\ faultVars.readCount < MaxReadLimit
    /\ ClientRead(s)
    /\ faultVars' = [faultVars EXCEPT !.readCount = @ + 1]

MCTakeSnapshot(s) ==
    /\ faultVars.snapshotCount < MaxSnapshotLimit
    /\ TakeSnapshot(s)
    /\ faultVars' = [faultVars EXCEPT !.snapshotCount = @ + 1]

MCCheckLeadership(s) ==
    /\ faultVars.checkLeadershipCount < MaxCheckLeadershipLimit
    /\ CheckLeadership(s)
    /\ faultVars' = [faultVars EXCEPT !.checkLeadershipCount = @ + 1]

MCExpireLease(s) ==
    /\ faultVars.expireLeaseCount < MaxExpireLeaseLimit
    /\ ExpireLease(s)
    /\ faultVars' = [faultVars EXCEPT !.expireLeaseCount = @ + 1]

MCExpireLeaderValidity(s) ==
    /\ faultVars.expireLeaderValidityCount < MaxExpireLeaderValidityLimit
    /\ ExpireLeaderValidity(s)
    /\ faultVars' = [faultVars EXCEPT !.expireLeaderValidityCount = @ + 1]

\* ============================================================================
\* Unconstrained (reactive) actions — pass through with UNCHANGED faultVars
\* ============================================================================

MCHandleRequestVoteRequest(s, m) ==
    /\ HandleRequestVoteRequest(s, m)
    /\ UNCHANGED faultVars

MCHandleRequestVoteResponse(s, m) ==
    /\ HandleRequestVoteResponse(s, m)
    /\ UNCHANGED faultVars

MCHandleRequestVoteResponseHigherTerm(s, m) ==
    /\ HandleRequestVoteResponseHigherTerm(s, m)
    /\ UNCHANGED faultVars

MCAppendEntries(s, t) ==
    /\ AppendEntries(s, t)
    /\ UNCHANGED faultVars

MCHandleAppendEntriesRequest(s, m) ==
    /\ HandleAppendEntriesRequest(s, m)
    /\ UNCHANGED faultVars

MCHandleAppendEntriesResponse(s, m) ==
    /\ HandleAppendEntriesResponse(s, m)
    /\ UNCHANGED faultVars

MCAdvanceCommitIndex(s) ==
    /\ AdvanceCommitIndex(s)
    /\ UNCHANGED faultVars

MCCommitJointConfig(s) ==
    /\ CommitJointConfig(s)
    /\ UNCHANGED faultVars

MCFlushLog(s) ==
    /\ FlushLog(s)
    /\ UNCHANGED faultVars

MCExtendLease(s) ==
    /\ ExtendLease(s)
    /\ UNCHANGED faultVars

MCSendInstallSnapshot(s, t) ==
    /\ SendInstallSnapshot(s, t)
    /\ UNCHANGED faultVars

MCHandleInstallSnapshotRequest(s, m) ==
    /\ HandleInstallSnapshotRequest(s, m)
    /\ UNCHANGED faultVars

MCHandleInstallSnapshotResponse(s, m) ==
    /\ HandleInstallSnapshotResponse(s, m)
    /\ UNCHANGED faultVars

MCDuplicateMessage(m) ==
    /\ DuplicateMessage(m)
    /\ UNCHANGED faultVars

\* ============================================================================
\* Message buffer constraint (state space pruning)
\* ============================================================================

MsgBufferConstraint == BagCardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* Symmetry
\* ============================================================================

ModelSymmetry == Permutations(Server)

\* ============================================================================
\* Init and Next
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultVars = [
        timeoutCount |-> 0,
        preVoteCount |-> 0,
        requestCount |-> 0,
        crashCount |-> 0,
        loseCount |-> 0,
        heartbeatCount |-> 0,
        configChangeCount |-> 0,
        readCount |-> 0,
        snapshotCount |-> 0,
        checkLeadershipCount |-> 0,
        expireLeaseCount |-> 0,
        expireLeaderValidityCount |-> 0
       ]

MCNext ==
    \* Election actions (bounded)
    \/ \E s \in Server : MCTimeout(s)
    \/ \E s \in Server : MCPreVote(s)
    \* Election actions (reactive)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ MCHandleRequestVoteRequest(s, m)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ MCHandleRequestVoteResponse(s, m)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ MCHandleRequestVoteResponseHigherTerm(s, m)
    \* Log replication (bounded: client request, heartbeat; reactive: the rest)
    \/ \E s \in Server, v \in Value : MCClientRequest(s, v)
    \/ \E s \in Server : MCFlushLog(s)
    \/ \E s, t \in Server : MCAppendEntries(s, t)
    \/ \E s, t \in Server : MCHeartbeat(s, t)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ MCHandleAppendEntriesRequest(s, m)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ MCHandleAppendEntriesResponse(s, m)
    \* Commit advancement (reactive)
    \/ \E s \in Server : MCAdvanceCommitIndex(s)
    \* Configuration changes (bounded)
    \/ \E s \in Server, newPeers \in SUBSET Server \ {{}} : MCProposeConfigChange(s, newPeers)
    \/ \E s \in Server : MCCommitJointConfig(s)
    \* Reads (bounded)
    \/ \E s \in Server : MCClientRead(s)
    \/ \E s \in Server : MCExtendLease(s)
    \/ \E s \in Server : MCExpireLease(s)
    \* Snapshots (bounded)
    \/ \E s \in Server : MCTakeSnapshot(s)
    \/ \E s, t \in Server : MCSendInstallSnapshot(s, t)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ MCHandleInstallSnapshotRequest(s, m)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ MCHandleInstallSnapshotResponse(s, m)
    \* Leadership management (bounded)
    \/ \E s \in Server : MCCheckLeadership(s)
    \/ \E s \in Server : MCExpireLeaderValidity(s)
    \* Network faults (bounded)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\ MCLoseMessage(m)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\ MCDuplicateMessage(m)
    \* Crash (bounded)
    \/ \E s \in Server : MCCrash(s)

MCSpec == MCInit /\ [][MCNext]_mcVars

\* ============================================================================
\* View (exclude counters from state fingerprint for symmetry)
\* ============================================================================

MCView == vars

====
