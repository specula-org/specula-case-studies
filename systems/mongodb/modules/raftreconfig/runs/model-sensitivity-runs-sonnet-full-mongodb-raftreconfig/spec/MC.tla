---- MODULE MC ----
\* MC.tla — Model checking wrapper for MongoDB Raft Reconfig base spec
\*
\* Wraps base.tla with counter-bounded fault-injection actions for exhaustive
\* state space exploration. Only fault-injecting / non-deterministic actions
\* get counter bounds; reactive/deterministic actions pass through unchanged.
\*
\* Usage: TLC -config MC.cfg MC.tla
\*        TLC -config MC_hunt_<family>.cfg MC.tla

EXTENDS base

\* MC-specific bound constants (set per hunting config)
CONSTANTS
    MaxTimeoutLimit,
    MaxCrashLimit,
    MaxForceReconfigLimit,
    MaxHBReconfigLimit,
    MaxLostMsgLimit,
    MaxAppendLimit,
    MaxMsgBufferLimit

\* =========================================================
\* FAULT COUNTERS
\* =========================================================

\* One counter per fault-injection action (actions that introduce non-determinism)
VARIABLES faultVars

MCFaultVars == [
    timeouts      : Nat,   \* Timeout — drives elections
    crashes       : Nat,   \* Crash — resets in-memory state
    forceReconfigs: Nat,   \* ForceReconfig — sets configTerm=UNINITIALIZED (Family 1)
    hbReconfigs   : Nat,   \* HBReconfigSchedule — weaker validation path (Family 2)
    lostMessages  : Nat,   \* DropMessage — network fault
    appendEntries : Nat    \* AppendEntry — log growth bound
]

MCInit ==
    /\ Init
    /\ faultVars = [timeouts |-> 0, crashes |-> 0, forceReconfigs |-> 0,
                    hbReconfigs |-> 0, lostMessages |-> 0, appendEntries |-> 0]

\* =========================================================
\* COUNTER-BOUNDED WRAPPERS (fault-injecting actions)
\* =========================================================

\* Timeout introduces non-determinism (which node times out when)
MCTimeout(n) ==
    /\ faultVars.timeouts < MaxTimeoutLimit
    /\ Timeout(n)
    /\ faultVars' = [faultVars EXCEPT !.timeouts = @ + 1]

\* Crash introduces non-determinism (which node crashes when)
MCCrash(n) ==
    /\ faultVars.crashes < MaxCrashLimit
    /\ Crash(n)
    /\ faultVars' = [faultVars EXCEPT !.crashes = @ + 1]

\* ForceReconfig is externally triggered (Family 1)
MCForceReconfig(n, newCfg, newVer) ==
    /\ faultVars.forceReconfigs < MaxForceReconfigLimit
    /\ ForceReconfig(n, newCfg, newVer)
    /\ faultVars' = [faultVars EXCEPT !.forceReconfigs = @ + 1]

\* HBReconfigSchedule is triggered by heartbeat delivery (Family 2)
MCHBReconfigSchedule(n, newCfg, v, t) ==
    /\ faultVars.hbReconfigs < MaxHBReconfigLimit
    /\ HBReconfigSchedule(n, newCfg, v, t)
    /\ faultVars' = [faultVars EXCEPT !.hbReconfigs = @ + 1]

\* Drop an in-flight message (network fault)
MCDropMessage(m) ==
    /\ faultVars.lostMessages < MaxLostMsgLimit
    /\ messages' = messages \ {m}
    /\ faultVars' = [faultVars EXCEPT !.lostMessages = @ + 1]
    /\ UNCHANGED <<serverVars, logVars, configVars, barrierVars, voteVars, leaderVars, hbVars>>

\* AppendEntry bound (log growth)
MCAppendEntry(n) ==
    /\ faultVars.appendEntries < MaxAppendLimit
    /\ AppendEntry(n)
    /\ faultVars' = [faultVars EXCEPT !.appendEntries = @ + 1]

\* =========================================================
\* PASS-THROUGH WRAPPERS (reactive / deterministic — not bounded)
\* These actions react to existing state; bounding them would prune valid states.
\* =========================================================

MCRequestVotes(n)                     == RequestVotes(n)             /\ UNCHANGED faultVars
MCHandleRequestVote(voter, m)         == HandleRequestVote(voter, m) /\ UNCHANGED faultVars
MCPersistVote(n)                      == PersistVote(n)              /\ UNCHANGED faultVars
MCBecomeLeader(n)                     == BecomeLeader(n)             /\ UNCHANGED faultVars
MCAutoReconfig(n)                     == AutoReconfig(n)             /\ UNCHANGED faultVars
MCAutoReconfigPreempted(n)            == AutoReconfigPreempted(n)    /\ UNCHANGED faultVars
MCSafeReconfigStart(n, newCfg)        == SafeReconfigStart(n, newCfg) /\ UNCHANGED faultVars
MCSafeReconfigSwap(n, newCfg)         == SafeReconfigSwap(n, newCfg) /\ UNCHANGED faultVars
MCSafeReconfigCaptureBarrier(n)       == SafeReconfigCaptureBarrier(n) /\ UNCHANGED faultVars
MCHBReconfigFinish(n)                 == HBReconfigFinish(n)         /\ UNCHANGED faultVars
MCHBReconfigAborted(n)                == HBReconfigAborted(n)        /\ UNCHANGED faultVars
MCSendAppendEntries(leader, follower) == SendAppendEntries(leader, follower) /\ UNCHANGED faultVars
MCHandleAppendEntries(n, m)           == HandleAppendEntries(n, m)   /\ UNCHANGED faultVars
MCAdvanceCommitIndex(n)               == AdvanceCommitIndex(n)       /\ UNCHANGED faultVars
MCSendHeartbeat(from, to)             == SendHeartbeat(from, to)     /\ UNCHANGED faultVars
MCHandleHeartbeat(n, m)               == HandleHeartbeat(n, m)       /\ UNCHANGED faultVars

\* =========================================================
\* MCNext
\* =========================================================

MCNext ==
    \* Fault-injecting actions (bounded)
    \/ \E n \in Server : MCTimeout(n)
    \/ \E n \in Server : MCCrash(n)
    \/ \E n \in Server, newCfg \in SUBSET Server, newVer \in 1..MaxConfigVersion :
           MCForceReconfig(n, newCfg, newVer)
    \/ \E n \in Server, newCfg \in SUBSET Server, v \in 1..MaxConfigVersion,
           t \in ({UNINITIALIZED} \cup 0..MaxTerm) :
               MCHBReconfigSchedule(n, newCfg, v, t)
    \/ \E m \in messages : MCDropMessage(m)
    \/ \E n \in Server : MCAppendEntry(n)
    \* Reactive / deterministic actions (unbounded)
    \/ \E n \in Server : MCRequestVotes(n)
    \/ \E m \in messages : m.mtype = M_RequestVote /\ MCHandleRequestVote(m.mto, m)
    \/ \E n \in Server : MCPersistVote(n)
    \/ \E n \in Server : MCBecomeLeader(n)
    \/ \E n \in Server : MCAutoReconfig(n)
    \/ \E n \in Server : MCAutoReconfigPreempted(n)
    \/ \E n \in Server, newCfg \in SUBSET Server : MCSafeReconfigStart(n, newCfg)
    \/ \E n \in Server, newCfg \in SUBSET Server : MCSafeReconfigSwap(n, newCfg)
    \/ \E n \in Server : MCSafeReconfigCaptureBarrier(n)
    \/ \E n \in Server : MCHBReconfigFinish(n)
    \/ \E n \in Server : MCHBReconfigAborted(n)
    \/ \E n \in Server, m2 \in Server : n /= m2 /\ MCSendAppendEntries(n, m2)
    \/ \E m \in messages : m.mtype = M_AppendEntries /\ MCHandleAppendEntries(m.mto, m)
    \/ \E n \in Server : MCAdvanceCommitIndex(n)
    \/ \E from \in Server, to \in Server : from /= to /\ MCSendHeartbeat(from, to)
    \/ \E m \in messages : m.mtype = M_Heartbeat /\ MCHandleHeartbeat(m.mto, m)

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

\* =========================================================
\* SYMMETRY AND STATE CONSTRAINTS
\* =========================================================

\* Server is symmetric — permuting node identities gives equivalent states
Symmetry == Permutations(Server)

\* Exclude fault counters from state comparison (they increase monotonically
\* and would otherwise prevent state deduplication)
StateView == <<vars>>

\* Message buffer bound: prevents unbounded message accumulation
\* (messages in transit for a 3-node cluster)
MsgBufferBound == Cardinality(messages) <= MaxMsgBufferLimit

\* =========================================================
\* INVARIANTS — Standard and Structural (always checked)
\* Extension (bug-family) invariants are commented out here;
\* enable them per-family in MC_hunt_*.cfg files
\* =========================================================

MCElectionSafety         == ElectionSafety
MCLogMatching            == LogMatching
MCConfigVersionPositive  == ConfigVersionPositive
MCReconfigOnlyByLeader   == ReconfigOnlyByLeader
MCVoteTermMonotone       == VoteTermMonotone
MCConfigStateValid       == ConfigStateValid
MCHBConfigStateConsistency == HBConfigStateConsistency
MCConfigTermBelowElectionTerm == ConfigTermBelowElectionTerm
MCCommitBarrierConsistency == CommitBarrierConsistency

\* --- Extension (bug-family) invariants — commented out for convergence run ---
\* Uncomment selectively in MC_hunt_*.cfg files for targeted bug hunting
\*
MCVoteOnce           == VoteOnce              \* Family 5
MCCommitPointSafety  == CommitPointSafety     \* Family 3

====
