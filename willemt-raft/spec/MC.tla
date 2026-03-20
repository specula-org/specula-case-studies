---- MODULE MC ----
\***********************************************************************
\* Model checking wrapper for willemt/raft base spec.
\* Counter-bounds fault-injection and non-deterministic actions.
\* Does NOT bound reactive/deterministic actions (message handlers).
\***********************************************************************
EXTENDS base, TLC

\***********************************************************************
\* Constants for model checking bounds
\***********************************************************************
CONSTANTS
    MaxTimeoutLimit,    \* Max number of elections (Timeout actions)
    RequestLimit,       \* Max client requests
    CrashLimit,         \* Max crashes
    LoseLimit,          \* Max lost messages
    DuplicateLimit,     \* Max duplicated messages
    SnapshotLimit,      \* Max snapshots taken
    BroadcastLimit,     \* Max broadcast AE actions
    MaxMsgCount         \* Max messages in network (state pruning)

\***********************************************************************
\* Counter variables
\***********************************************************************
VARIABLE counters
\* counters is a record:
\* [timeout, request, crash, lose, duplicate, snapshot, broadcast : Nat]

mcVars == <<counters>>

\***********************************************************************
\* Counter-bounded wrappers
\***********************************************************************

MCTimeout(i) ==
    /\ counters.timeout < MaxTimeoutLimit
    /\ Timeout(i)
    /\ counters' = [counters EXCEPT !.timeout = @ + 1]

MCClientRequest(i, v) ==
    /\ counters.request < RequestLimit
    /\ ClientRequest(i, v)
    /\ counters' = [counters EXCEPT !.request = @ + 1]

MCCrash(i) ==
    /\ counters.crash < CrashLimit
    /\ Crash(i)
    /\ counters' = [counters EXCEPT !.crash = @ + 1]

MCLoseMessage(m) ==
    /\ counters.lose < LoseLimit
    /\ LoseMessage(m)
    /\ counters' = [counters EXCEPT !.lose = @ + 1]

MCDuplicateMessage(m) ==
    /\ counters.duplicate < DuplicateLimit
    /\ DuplicateMessage(m)
    /\ counters' = [counters EXCEPT !.duplicate = @ + 1]

MCTakeSnapshot(i) ==
    /\ counters.snapshot < SnapshotLimit
    /\ TakeSnapshot(i)
    /\ counters' = [counters EXCEPT !.snapshot = @ + 1]

MCBroadcastAppendEntries(i) ==
    /\ counters.broadcast < BroadcastLimit
    /\ BroadcastAppendEntries(i)
    /\ counters' = [counters EXCEPT !.broadcast = @ + 1]

\***********************************************************************
\* Unconstrained wrappers (reactive/deterministic actions)
\***********************************************************************

MCSendAppendEntries(i, j) ==
    /\ SendAppendEntries(i, j)
    /\ UNCHANGED mcVars

MCSendInstallSnapshot(i, j) ==
    /\ SendInstallSnapshot(i, j)
    /\ UNCHANGED mcVars

MCRecover(i) ==
    /\ Recover(i)
    /\ UNCHANGED mcVars

MCHandleRequestVoteRequest(i, j, m) ==
    /\ HandleRequestVoteRequest(i, j, m)
    /\ UNCHANGED mcVars

MCHandleRequestVoteResponse(i, j, m) ==
    /\ HandleRequestVoteResponse(i, j, m)
    /\ UNCHANGED mcVars

MCHandleAppendEntriesRequest(i, j, m) ==
    /\ HandleAppendEntriesRequest(i, j, m)
    /\ UNCHANGED mcVars

MCHandleAppendEntriesResponse(i, j, m) ==
    /\ HandleAppendEntriesResponse(i, j, m)
    /\ UNCHANGED mcVars

MCHandleInstallSnapshot(i, j, m) ==
    /\ HandleInstallSnapshot(i, j, m)
    /\ UNCHANGED mcVars

\***********************************************************************
\* State space pruning: limit message buffer size
\***********************************************************************
MsgBufferConstraint == BagCardinality(messages) <= MaxMsgCount

\***********************************************************************
\* MCInit and MCNext
\***********************************************************************
MCInit ==
    /\ Init
    /\ counters = [timeout   |-> 0, request   |-> 0, crash    |-> 0,
                   lose      |-> 0, duplicate  |-> 0, snapshot |-> 0,
                   broadcast |-> 0]

MCNext ==
    \* --- Bounded: non-deterministic / fault-injection ---
    \/ \E i \in Server : MCTimeout(i)
    \/ \E i \in Server, v \in Value : MCClientRequest(i, v)
    \/ \E i \in Server : MCBroadcastAppendEntries(i)
    \/ \E i \in Server : MCCrash(i)
    \/ \E i \in Server : MCTakeSnapshot(i)
    \/ \E m \in BagToSet(messages) : MCLoseMessage(m)
    \/ \E m \in BagToSet(messages) : MCDuplicateMessage(m)
    \* --- Unbounded: reactive / deterministic ---
    \/ \E i,j \in Server : MCSendAppendEntries(i, j)
    \/ \E i,j \in Server : MCSendInstallSnapshot(i, j)
    \/ \E i \in Server : MCRecover(i)
    \/ \E m \in BagToSet(messages) : MCHandleRequestVoteRequest(m.mdest, m.msource, m)
    \/ \E m \in BagToSet(messages) : MCHandleRequestVoteResponse(m.mdest, m.msource, m)
    \/ \E m \in BagToSet(messages) : MCHandleAppendEntriesRequest(m.mdest, m.msource, m)
    \/ \E m \in BagToSet(messages) : MCHandleAppendEntriesResponse(m.mdest, m.msource, m)
    \/ \E m \in BagToSet(messages) : MCHandleInstallSnapshot(m.mdest, m.msource, m)

MCSpec == MCInit /\ [][MCNext]_<<allVars, mcVars>>

\***********************************************************************
\* Symmetry reduction
\***********************************************************************
ModelSymmetry == Permutations(Server)

\***********************************************************************
\* Structural invariants for convergence
\***********************************************************************

\* Counters non-negative
CountersOK ==
    /\ counters.timeout >= 0
    /\ counters.request >= 0
    /\ counters.crash >= 0
    /\ counters.lose >= 0
    /\ counters.duplicate >= 0
    /\ counters.snapshot >= 0
    /\ counters.broadcast >= 0

\***********************************************************************
\* Temporal properties
\***********************************************************************

\* TermMonotonicity: term never decreases (violated by snapshot load bug, Family 3+4)
TermNeverDecreases ==
    [][\A i \in Server : ~crashed[i] => currentTerm'[i] >= currentTerm[i]]_allVars

\* CommitIndexMonotonicity: commit index never decreases (Family 1)
CommitNeverDecreases ==
    [][\A i \in Server : ~crashed[i] => commitIndex'[i] >= commitIndex[i]]_allVars

====
