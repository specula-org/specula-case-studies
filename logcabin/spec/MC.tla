------------------------------ MODULE MC ------------------------------
\* Model checking wrapper for logcabin Raft spec.
\*
\* Counter-bounds fault-injection and non-deterministic actions.
\* Deterministic/reactive actions (message handlers, BecomeLeader,
\* AdvanceCommitIndex, LeaderDiskSync) are NOT bounded.
\*
EXTENDS base

\* Counter limits (tuned per MC.cfg / MC_hunt_*.cfg)
CONSTANTS MaxTimeoutLimit,     \* Elections started
          RequestLimit,        \* Client requests appended
          CrashLimit,          \* Server crashes
          LoseLimit,           \* Messages lost
          HeartbeatLimit,      \* Heartbeats sent (AppendEntries with no new data)
          ConfigChangeLimit,   \* Configuration changes proposed
          SnapshotLimit,       \* Snapshots taken
          StepDownCheckLimit,  \* Epoch step-down checks
          MaxMsgBufferLimit    \* Max messages in flight

\* Counter variable
VARIABLE faultCounters
\* Record: [timeout, request, crash, lose, heartbeat, configChange, snapshot, stepDownCheck]

faultVars == <<faultCounters>>

MCInit ==
    /\ Init
    /\ faultCounters = [timeout      |-> 0,
                        request      |-> 0,
                        crash        |-> 0,
                        lose         |-> 0,
                        heartbeat    |-> 0,
                        configChange |-> 0,
                        snapshot     |-> 0,
                        stepDownCheck |-> 0]

----
\* Counter-bounded action wrappers
----

MCTimeout(i) ==
    /\ faultCounters.timeout < MaxTimeoutLimit
    /\ Timeout(i)
    /\ faultCounters' = [faultCounters EXCEPT !.timeout = @ + 1]

MCClientRequest(i) ==
    /\ faultCounters.request < RequestLimit
    /\ ClientRequest(i)
    /\ faultCounters' = [faultCounters EXCEPT !.request = @ + 1]

MCCrash(i) ==
    /\ faultCounters.crash < CrashLimit
    /\ Crash(i)
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

MCLoseMessage(m) ==
    /\ faultCounters.lose < LoseLimit
    /\ LoseMessage(m)
    /\ faultCounters' = [faultCounters EXCEPT !.lose = @ + 1]

MCSendAppendEntries(i, j) ==
    /\ faultCounters.heartbeat < HeartbeatLimit
    /\ AppendEntries(i, j)
    /\ faultCounters' = [faultCounters EXCEPT !.heartbeat = @ + 1]

MCSendInstallSnapshot(i, j) ==
    /\ SendInstallSnapshot(i, j)
    /\ UNCHANGED faultVars

MCProposeConfigChange(i, newServers) ==
    /\ faultCounters.configChange < ConfigChangeLimit
    /\ ProposeConfigChange(i, newServers)
    /\ faultCounters' = [faultCounters EXCEPT !.configChange = @ + 1]

MCTakeSnapshot(i) ==
    /\ faultCounters.snapshot < SnapshotLimit
    /\ TakeSnapshot(i)
    /\ faultCounters' = [faultCounters EXCEPT !.snapshot = @ + 1]

MCStepDownCheck(i) ==
    /\ faultCounters.stepDownCheck < StepDownCheckLimit
    /\ StepDownCheck(i)
    /\ faultCounters' = [faultCounters EXCEPT !.stepDownCheck = @ + 1]

----
\* Unconstrained reactive actions (pass through with UNCHANGED faultVars)
----

MCBecomeLeader(i) ==
    /\ BecomeLeader(i)
    /\ UNCHANGED faultVars

MCAdvanceCommitIndex(i) ==
    /\ AdvanceCommitIndex(i)
    /\ UNCHANGED faultVars

MCLeaderDiskSync(i) ==
    /\ LeaderDiskSync(i)
    /\ UNCHANGED faultVars

MCHandleRequestVoteRequest(i, m) ==
    /\ HandleRequestVoteRequest(i, m)
    /\ UNCHANGED faultVars

MCHandleRequestVoteResponse(i, m) ==
    /\ HandleRequestVoteResponse(i, m)
    /\ UNCHANGED faultVars

MCHandleAppendEntriesRequest(i, m) ==
    /\ HandleAppendEntriesRequest(i, m)
    /\ UNCHANGED faultVars

MCHandleAppendEntriesResponse(i, m) ==
    /\ HandleAppendEntriesResponse(i, m)
    /\ UNCHANGED faultVars

MCHandleInstallSnapshotRequest(i, m) ==
    /\ HandleInstallSnapshotRequest(i, m)
    /\ UNCHANGED faultVars

MCHandleInstallSnapshotResponse(i, m) ==
    /\ HandleInstallSnapshotResponse(i, m)
    /\ UNCHANGED faultVars

MCDropStaleMessage(m) ==
    /\ DropStaleMessage(m)
    /\ UNCHANGED faultVars

----
\* Next state relation
----

MCNextAsync(i) ==
    \/ MCTimeout(i)
    \/ MCBecomeLeader(i)
    \/ MCClientRequest(i)
    \/ MCAdvanceCommitIndex(i)
    \/ MCLeaderDiskSync(i)
    \/ MCStepDownCheck(i)
    \/ MCTakeSnapshot(i)
    \/ MCCrash(i)

MCNextReplication(i, j) ==
    \/ MCSendAppendEntries(i, j)
    \/ MCSendInstallSnapshot(i, j)

MCNextMessage(m) ==
    \/ MCHandleRequestVoteRequest(m.mdest, m)
    \/ MCHandleRequestVoteResponse(m.mdest, m)
    \/ MCHandleAppendEntriesRequest(m.mdest, m)
    \/ MCHandleAppendEntriesResponse(m.mdest, m)
    \/ MCHandleInstallSnapshotRequest(m.mdest, m)
    \/ MCHandleInstallSnapshotResponse(m.mdest, m)
    \/ MCDropStaleMessage(m)
    \/ MCLoseMessage(m)

MCNext ==
    \/ \E i \in Server : MCNextAsync(i)
    \/ \E i, j \in Server : i /= j /\ MCNextReplication(i, j)
    \/ \E m \in DOMAIN messages : MCNextMessage(m)

MCNextWithConfigChange ==
    \/ MCNext
    \/ \E i \in Server, newServers \in (SUBSET Server \ {{}}) :
        MCProposeConfigChange(i, newServers)

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>
MCSpecWithConfigChange == MCInit /\ [][MCNextWithConfigChange]_<<vars, faultVars>>

----
\* State space constraints
----

\* Bound message buffer to prevent explosion
MsgBufferConstraint == BagCardinality(messages) <= MaxMsgBufferLimit

\* Symmetry reduction: servers are interchangeable
ModelSymmetry == Permutations(Server)

\* View: exclude fault counters (they don't affect protocol state)
MCView == <<serverVars, logVars, leaderVars, candidateVars, messages,
            configVars, withholdVar, epochVars, diskVars, snapshotVars,
            leaderId>>

----
\* Structural invariants
----

\* commitIndex never exceeds lastLogIndex or lastSnapshotIndex
MCCommitIndexBound ==
    \A s \in Server :
        commitIndex[s] <= LastLogIndex(s) \/
        commitIndex[s] <= lastSnapshotIndex[s]

\* Candidates voted for themselves
MCCandidateVotedForSelf ==
    \A s \in Server :
        state[s] = Candidate => votedFor[s] = s

\* Leader term is positive
MCLeaderTermPositive ==
    \A s \in Server :
        state[s] = Leader => currentTerm[s] > 0

\* logStartIndex is always >= 1
MCLogStartValid ==
    \A s \in Server :
        logStartIndex[s] >= 1

\* lastSnapshotIndex < logStartIndex (snapshot is before log)
MCSnapshotBeforeLog ==
    \A s \in Server :
        lastSnapshotIndex[s] < logStartIndex[s] \/
        (lastSnapshotIndex[s] = 0 /\ logStartIndex[s] = 1)

\* Config state is valid
MCConfigStateValid ==
    \A s \in Server :
        /\ configState[s] \in {ConfigBlank, ConfigStable, ConfigStaging, ConfigTransitional}
        /\ state[s] /= Leader => configState[s] \in {ConfigBlank, ConfigStable, ConfigTransitional}

----
\* Temporal properties
----

\* commitIndex monotonically increases (except on crash)
MonotonicCommitIndex ==
    [][\A s \in Server :
        state'[s] /= Follower \/ state[s] = Follower =>
            commitIndex'[s] >= commitIndex[s]]_vars

\* Terms monotonically increase
MonotonicTerm ==
    [][\A s \in Server : currentTerm'[s] >= currentTerm[s]]_vars

=============================================================================
