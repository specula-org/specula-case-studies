------------------------------ MODULE MC ------------------------------
\* Model checking wrapper for tikv/raft-rs specification.
\* Adds counter-bounded fault-injection actions, symmetry reduction,
\* and state space pruning.
\*
EXTENDS base

\* Instance of base for original operator access (needed for cfg overrides)
B == INSTANCE base

----
\* Counter-bound constants
----

CONSTANT MaxTermLimit        \* Max term any server can reach
CONSTANT MaxTimeoutLimit     \* Max number of election timeouts
CONSTANT RequestLimit        \* Max number of client requests
CONSTANT CrashLimit          \* Max number of crash events
CONSTANT LoseLimit           \* Max number of lost messages
CONSTANT HeartbeatLimit      \* Max number of heartbeats
CONSTANT TransferLimit       \* Max number of leadership transfers
CONSTANT ReadLimit           \* Max number of ReadIndex requests
CONSTANT ConfChangeLimit     \* Max number of conf changes
CONSTANT CheckQuorumLimit    \* Max number of CheckQuorum events
CONSTANT MaxMsgBufferLimit   \* Max total messages in flight

----
\* Counter variables
----

VARIABLE ctr

faultVars == <<ctr>>

mc_vars == <<vars, faultVars>>

----
\* Counter-bounded wrappers (only bound non-deterministic / fault-injection actions)
----

\* Timeout: election timeout triggers (non-deterministic)
MCTimeout(i) ==
    /\ currentTerm[i] < MaxTermLimit
    /\ ctr.timeout < MaxTimeoutLimit
    /\ B!Timeout(i)
    /\ ctr' = [ctr EXCEPT !.timeout = @ + 1]

\* ClientRequest: new entry proposed (non-deterministic)
MCClientRequest(i) ==
    /\ ctr.request < RequestLimit
    /\ B!ClientRequest(i)
    /\ ctr' = [ctr EXCEPT !.request = @ + 1]

\* SendHeartbeat: leader heartbeat (non-deterministic)
MCSendHeartbeat(i, j) ==
    /\ ctr.heartbeat < HeartbeatLimit
    /\ B!SendHeartbeat(i, j)
    /\ ctr' = [ctr EXCEPT !.heartbeat = @ + 1]

\* CheckQuorum: leader quorum check (non-deterministic)
MCCheckQuorum(i) ==
    /\ ctr.checkQuorum < CheckQuorumLimit
    /\ B!CheckQuorum(i)
    /\ ctr' = [ctr EXCEPT !.checkQuorum = @ + 1]

\* TransferLeadership: begin transfer (non-deterministic)
MCTransferLeadership(i, j) ==
    /\ ctr.transfer < TransferLimit
    /\ B!TransferLeadership(i, j)
    /\ ctr' = [ctr EXCEPT !.transfer = @ + 1]

\* ProposeReadIndex: read request (non-deterministic)
MCProposeReadIndex(i) ==
    /\ ctr.read < ReadLimit
    /\ B!ProposeReadIndex(i)
    /\ ctr' = [ctr EXCEPT !.read = @ + 1]

\* ProposeConfChange: conf change proposal (non-deterministic)
MCProposeConfChange(i, S) ==
    /\ ctr.confChange < ConfChangeLimit
    /\ B!ProposeConfChange(i, S)
    /\ ctr' = [ctr EXCEPT !.confChange = @ + 1]

\* Crash: server crash (fault-injection)
MCCrash(i) ==
    /\ ctr.crash < CrashLimit
    /\ B!Crash(i)
    /\ ctr' = [ctr EXCEPT !.crash = @ + 1]

\* LoseMessage: message loss (fault-injection)
MCLoseMessage(m) ==
    /\ ctr.lose < LoseLimit
    /\ B!LoseMessage(m)
    /\ ctr' = [ctr EXCEPT !.lose = @ + 1]

----
\* Unconstrained wrappers (deterministic/reactive actions)
----

MCBecomeLeader(i) ==
    /\ B!BecomeLeader(i)
    /\ UNCHANGED <<votesGranted, preVotesGranted, messages, faultVars>>

MCAdvanceCommitIndex(i) ==
    /\ B!AdvanceCommitIndex(i) /\ UNCHANGED faultVars

MCPersistEntries(i) ==
    /\ B!PersistEntries(i) /\ UNCHANGED faultVars

MCConfirmReadIndex(i) ==
    /\ B!ConfirmReadIndex(i) /\ UNCHANGED faultVars

MCServeLeaseBasedRead(i) ==
    /\ B!ServeLeaseBasedRead(i) /\ UNCHANGED faultVars

MCAbortLeaderTransfer(i) ==
    /\ B!AbortLeaderTransfer(i) /\ UNCHANGED faultVars

MCAutoLeaveJoint(i) ==
    /\ B!AutoLeaveJoint(i) /\ UNCHANGED faultVars

MCHandleRequestPreVoteRequest(i, m) ==
    /\ B!HandleRequestPreVoteRequest(i, m) /\ UNCHANGED faultVars

MCHandleRequestPreVoteResponse(i, m) ==
    /\ B!HandleRequestPreVoteResponse(i, m) /\ UNCHANGED faultVars

MCHandleRequestVoteRequest(i, m) ==
    /\ B!HandleRequestVoteRequest(i, m) /\ UNCHANGED faultVars

MCHandleRequestVoteResponse(i, m) ==
    /\ B!HandleRequestVoteResponse(i, m) /\ UNCHANGED faultVars

MCHandleAppendEntriesRequest(i, m) ==
    /\ B!HandleAppendEntriesRequest(i, m) /\ UNCHANGED faultVars

MCHandleAppendEntriesResponse(i, m) ==
    /\ B!HandleAppendEntriesResponse(i, m) /\ UNCHANGED faultVars

MCHandleHeartbeatRequest(i, m) ==
    /\ B!HandleHeartbeatRequest(i, m) /\ UNCHANGED faultVars

MCHandleHeartbeatResponse(i, m) ==
    /\ B!HandleHeartbeatResponse(i, m) /\ UNCHANGED faultVars

MCHandleTimeoutNowRequest(i, m) ==
    /\ B!HandleTimeoutNowRequest(i, m) /\ UNCHANGED faultVars

MCDropStaleMessage(m) ==
    /\ B!DropStaleMessage(m) /\ UNCHANGED faultVars

----
\* MCInit and MCNext
----

MCInit ==
    /\ Init
    /\ ctr = [timeout     |-> 0,
              request     |-> 0,
              heartbeat   |-> 0,
              checkQuorum |-> 0,
              transfer    |-> 0,
              read        |-> 0,
              confChange  |-> 0,
              crash       |-> 0,
              lose        |-> 0]

MCNext ==
    \* Per-server counter-bounded actions
    \/ \E i \in Server :
        \/ MCTimeout(i)
        \/ MCClientRequest(i)
        \/ MCCheckQuorum(i)
        \/ MCProposeReadIndex(i)
        \/ MCCrash(i)
        \/ MCBecomeLeader(i)
        \/ MCAdvanceCommitIndex(i)
        \/ MCPersistEntries(i)
        \/ MCConfirmReadIndex(i)
        \/ MCServeLeaseBasedRead(i)
        \/ MCAbortLeaderTransfer(i)
        \/ MCAutoLeaveJoint(i)
    \* Two-server counter-bounded actions
    \/ \E i, j \in Server :
        \/ MCSendHeartbeat(i, j)
        \/ MCTransferLeadership(i, j)
    \* Config change (bounded set of new configs)
    \/ \E i \in Server :
        \E S \in SUBSET Server :
            /\ S /= {}
            /\ MCProposeConfChange(i, S)
    \* Message handlers (unconstrained)
    \/ \E m \in DOMAIN messages :
        \/ MCHandleRequestPreVoteRequest(m.mdest, m)
        \/ MCHandleRequestPreVoteResponse(m.mdest, m)
        \/ MCHandleRequestVoteRequest(m.mdest, m)
        \/ MCHandleRequestVoteResponse(m.mdest, m)
        \/ MCHandleAppendEntriesRequest(m.mdest, m)
        \/ MCHandleAppendEntriesResponse(m.mdest, m)
        \/ MCHandleHeartbeatRequest(m.mdest, m)
        \/ MCHandleHeartbeatResponse(m.mdest, m)
        \/ MCHandleTimeoutNowRequest(m.mdest, m)
        \/ MCDropStaleMessage(m)
    \* Fault injection (bounded)
    \/ \E m \in DOMAIN messages :
        MCLoseMessage(m)

MCSpec == MCInit /\ [][MCNext]_mc_vars

----
\* State space constraints
----

\* Limit message buffer to prevent explosion
MsgBufferConstraint ==
    BagCardinality(messages) < MaxMsgBufferLimit

----
\* Symmetry and view
----

\* Symmetry reduction on Server set
ModelSymmetry == Permutations(Server)

\* View: exclude counters from state comparison
ModelView == <<vars>>

====
