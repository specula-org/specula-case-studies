---------------------------- MODULE MC ----------------------------
\* Model checking wrapper for goraft/raft base spec.
\*
\* Adds counter-bounded fault injection, symmetry reduction,
\* message buffer constraints, and structural invariants.
\*
EXTENDS base

\* Counter bounds for non-deterministic actions
CONSTANT MaxTimeoutLimit      \* Election timeout events
CONSTANT MaxRequestLimit      \* Client request + NOP entries
CONSTANT MaxCrashLimit        \* Server crash/recovery events
CONSTANT MaxLoseLimit         \* Network message loss events
CONSTANT MaxHeartbeatLimit    \* Heartbeat sends (Bug Family 5)
CONSTANT MaxSnapshotLimit     \* Snapshot sends (Bug Family 4)
CONSTANT MaxMsgBufferLimit    \* Message buffer size constraint

----
\* Counter variables
----

VARIABLE faultVars

MCInit ==
    /\ Init
    /\ faultVars = [
           timeoutCount   |-> 0,
           requestCount   |-> 0,
           crashCount     |-> 0,
           loseCount      |-> 0,
           heartbeatCount |-> 0,
           snapshotCount  |-> 0
       ]

----
\* Counter-bounded wrappers
\* Only BOUND actions that introduce non-determinism.
\* Do NOT bound reactive/deterministic actions.
----

\* Bounded: Timeout (introduces election non-determinism)
MCTimeout(i) ==
    /\ faultVars.timeoutCount < MaxTimeoutLimit
    /\ Timeout(i)
    /\ faultVars' = [faultVars EXCEPT !.timeoutCount = @ + 1]

\* Bounded: RequestVote (introduces term advancement non-determinism)
MCRequestVote(i) ==
    /\ faultVars.timeoutCount > 0  \* must have timed out first
    /\ RequestVote(i)
    /\ UNCHANGED faultVars

\* Bounded: ClientRequest (introduces log growth)
MCClientRequest(i) ==
    /\ faultVars.requestCount < MaxRequestLimit
    /\ ClientRequest(i)
    /\ faultVars' = [faultVars EXCEPT !.requestCount = @ + 1]

\* Bounded: AppendNOP (introduces log growth, counted with requests)
MCAppendNOP(i) ==
    /\ faultVars.requestCount < MaxRequestLimit
    /\ AppendNOP(i)
    /\ faultVars' = [faultVars EXCEPT !.requestCount = @ + 1]

\* Bounded: Crash (Bug Family 1 - introduces crash/recovery non-determinism)
MCCrash(i) ==
    /\ faultVars.crashCount < MaxCrashLimit
    /\ Crash(i)
    /\ faultVars' = [faultVars EXCEPT !.crashCount = @ + 1]

\* Bounded: LoseMessage (introduces network partition non-determinism)
MCLoseMessage(m) ==
    /\ faultVars.loseCount < MaxLoseLimit
    /\ LoseMessage(m)
    /\ faultVars' = [faultVars EXCEPT !.loseCount = @ + 1]

\* Bounded: SendHeartbeat (Bug Family 5 - introduces stale-term messages)
MCSendHeartbeat(i, j) ==
    /\ faultVars.heartbeatCount < MaxHeartbeatLimit
    /\ SendHeartbeat(i, j)
    /\ faultVars' = [faultVars EXCEPT !.heartbeatCount = @ + 1]

\* Bounded: SendSnapshotRequest (Bug Family 4 - introduces snapshot non-determinism)
MCSendSnapshotRequest(i, j) ==
    /\ faultVars.snapshotCount < MaxSnapshotLimit
    /\ SendSnapshotRequest(i, j)
    /\ faultVars' = [faultVars EXCEPT !.snapshotCount = @ + 1]

\* Bounded: SendSnapshotRecoveryRequest (Bug Family 4 - counted with snapshots)
MCSendSnapshotRecoveryRequest(i, j) ==
    /\ faultVars.snapshotCount < MaxSnapshotLimit
    /\ SendSnapshotRecoveryRequest(i, j)
    /\ faultVars' = [faultVars EXCEPT !.snapshotCount = @ + 1]

----
\* Unconstrained wrappers (reactive/deterministic actions)
----

MCBecomeLeader(i) ==
    /\ BecomeLeader(i)
    /\ UNCHANGED faultVars

MCReplicate(i, j) ==
    /\ Replicate(i, j)
    /\ UNCHANGED faultVars

MCAdvanceCommitIndex(i) ==
    /\ AdvanceCommitIndex(i)
    /\ UNCHANGED faultVars

MCUpdateHeartbeatTerm(i) ==
    /\ UpdateHeartbeatTerm(i)
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

MCHandleSnapshotRequest(i, m) ==
    /\ HandleSnapshotRequest(i, m)
    /\ UNCHANGED faultVars

MCHandleSnapshotRecoveryRequest(i, m) ==
    /\ HandleSnapshotRecoveryRequest(i, m)
    /\ UNCHANGED faultVars

----
\* Message buffer constraint (state space pruning)
----

MsgBufferOk == MsgCount <= MaxMsgBufferLimit

----
\* MCNext
----

MCNext ==
    /\ MsgBufferOk
    /\ \/ \E i \in Server :
           \/ MCTimeout(i)
           \/ MCRequestVote(i)
           \/ MCBecomeLeader(i)
           \/ MCClientRequest(i)
           \/ MCAppendNOP(i)
           \/ MCAdvanceCommitIndex(i)
           \/ MCUpdateHeartbeatTerm(i)
           \/ MCCrash(i)
           \/ \E j \in Server \ {i} :
               \/ MCReplicate(i, j)
               \/ MCSendHeartbeat(i, j)
               \/ MCSendSnapshotRequest(i, j)
               \/ MCSendSnapshotRecoveryRequest(i, j)
       \/ \E m \in DOMAIN messages :
           \/ MCHandleRequestVoteRequest(m.mdest, m)
           \/ MCHandleRequestVoteResponse(m.mdest, m)
           \/ MCHandleAppendEntriesRequest(m.mdest, m)
           \/ MCHandleAppendEntriesResponse(m.mdest, m)
           \/ MCHandleSnapshotRequest(m.mdest, m)
           \/ MCHandleSnapshotRecoveryRequest(m.mdest, m)
           \/ MCLoseMessage(m)

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

----
\* Symmetry
----

MCSymmetry == Permutations(Server)

\* View: exclude counters from state fingerprint to reduce state space
MCView == <<serverVars, logVars, leaderVars, candidateVars, messages,
            persistVars, syncVars, heartbeatVars, historyVars>>

----
\* Structural invariants (always checked during convergence)
----

\* All standard + structural invariants
MCTypeOK == TypeOK

MCElectionSafety == ElectionSafety

MCLogMatching == LogMatching

MCCommitIndexBound == CommitIndexBound

\* Counter bounds are respected
MCCounterBound ==
    /\ faultVars.timeoutCount <= MaxTimeoutLimit
    /\ faultVars.requestCount <= MaxRequestLimit
    /\ faultVars.crashCount <= MaxCrashLimit
    /\ faultVars.loseCount <= MaxLoseLimit
    /\ faultVars.heartbeatCount <= MaxHeartbeatLimit
    /\ faultVars.snapshotCount <= MaxSnapshotLimit

====
