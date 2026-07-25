--------------------------- MODULE MC ---------------------------
(*
 * Model-checking wrapper for sofa-jraft base spec.
 *
 * Wraps fault-injection actions with counters to bound the state space.
 * Deterministic/reactive actions (message handlers, commit advance, FSM apply)
 * are NOT bounded — they react to existing state and do not introduce
 * independent non-determinism.
 *
 * Fault injection actions bounded here:
 *   ElectionTimeout  — non-deterministic timer expiry
 *   Crash            — server crash (Family 1: crash between two disk writes)
 *   InstallSnapshot  — leader-initiated snapshot send
 *   ClientRequest    — client command injection
 *   AppendEntries    — leader-initiated replication message
 *   ServeReadIndex   — client read request (Family 4)
 *   StepDown         — explicit step-down (Family 4: pending reads not cleared)
 *)

EXTENDS base, TLC

\* ============================================================================
\* COUNTER BOUNDS (tuning constants)
\* ============================================================================

\* Limits on non-deterministic / fault-injection actions
CONSTANT MaxTimeoutLimit    \* ElectionTimeout per server
CONSTANT MaxCrashLimit      \* Crash per server (Family 1)
CONSTANT MaxRequestLimit    \* ClientRequest total
CONSTANT MaxSnapshotLimit   \* InstallSnapshot per (leader, follower) pair
CONSTANT MaxReadLimit       \* ServeReadIndex per server (Family 4)
CONSTANT MaxStepDownLimit   \* StepDown per server (Family 4)
CONSTANT MaxTermLimit       \* Global term upper bound (prune runaway elections)
CONSTANT MaxMsgBufferLimit  \* Maximum messages in flight at once

\* ============================================================================
\* COUNTER VARIABLES
\* ============================================================================

VARIABLE faultVars  \* record of all counters

MCInit ==
    /\ Init
    /\ faultVars = [
           timeouts    |-> [s \in Server |-> 0],
           crashes     |-> [s \in Server |-> 0],
           requests    |-> 0,
           snapshots   |-> [s \in Server |-> [t \in Server |-> 0]],
           reads       |-> [s \in Server |-> 0],
           stepdowns   |-> [s \in Server |-> 0]
       ]

\* ============================================================================
\* CONSTRAINED WRAPPERS — fault-injection actions only
\* ============================================================================

\* ElectionTimeout: bounded per server
MCElectionTimeout(s) ==
    /\ faultVars.timeouts[s] < MaxTimeoutLimit
    /\ currentTerm[s] < MaxTermLimit
    /\ ElectionTimeout(s)
    /\ faultVars' = [faultVars EXCEPT !.timeouts[s] = @ + 1]

\* Crash: bounded per server (Family 1)
MCCrash(s) ==
    /\ faultVars.crashes[s] < MaxCrashLimit
    /\ Crash(s)
    /\ faultVars' = [faultVars EXCEPT !.crashes[s] = @ + 1]

\* ClientRequest: bounded globally
MCClientRequest(s, v) ==
    /\ faultVars.requests < MaxRequestLimit
    /\ ClientRequest(s, v)
    /\ faultVars' = [faultVars EXCEPT !.requests = @ + 1]

\* InstallSnapshot: bounded per (src, dst) pair
MCInstallSnapshot(s, t) ==
    /\ faultVars.snapshots[s][t] < MaxSnapshotLimit
    /\ InstallSnapshot(s, t)
    /\ faultVars' = [faultVars EXCEPT !.snapshots[s][t] = @ + 1]

\* ServeReadIndex: bounded per server (Families 3, 4)
MCServeReadIndex(s, idx) ==
    /\ faultVars.reads[s] < MaxReadLimit
    /\ ServeReadIndex(s, idx)
    /\ faultVars' = [faultVars EXCEPT !.reads[s] = @ + 1]

\* StepDown: bounded per server (Family 4)
MCStepDown(s) ==
    /\ faultVars.stepdowns[s] < MaxStepDownLimit
    /\ StepDown(s)
    /\ faultVars' = [faultVars EXCEPT !.stepdowns[s] = @ + 1]

\* ============================================================================
\* UNCONSTRAINED PASS-THROUGHS — reactive actions
\* ============================================================================

\* These actions react to existing state; bounding them would prune valid behaviours.

MCHandleRequestVoteRequestDeny(s, m) ==
    /\ HandleRequestVoteRequestDeny(s, m)
    /\ UNCHANGED faultVars

MCHandleRequestVoteRequestGrantSameTerm(s, m) ==
    /\ HandleRequestVoteRequestGrantSameTerm(s, m)
    /\ UNCHANGED faultVars

MCHandleRequestVoteRequestHigherTermStep1(s, m) ==
    /\ HandleRequestVoteRequestHigherTermStep1(s, m)
    /\ UNCHANGED faultVars

MCHandleRequestVoteRequestHigherTermStep2(s, m) ==
    /\ HandleRequestVoteRequestHigherTermStep2(s, m)
    /\ UNCHANGED faultVars

MCHandleRequestVoteRequestHigherTermStep3(s, m) ==
    /\ HandleRequestVoteRequestHigherTermStep3(s, m)
    /\ UNCHANGED faultVars

MCHandleRequestVoteResponse(s, m) ==
    /\ HandleRequestVoteResponse(s, m)
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

MCSendEBUSYResponse(s, m) ==
    /\ SendEBUSYResponse(s, m)
    /\ UNCHANGED faultVars

MCHandleAppendEntriesResponseBusyNormal(s, m) ==
    /\ HandleAppendEntriesResponseBusyNormal(s, m)
    /\ UNCHANGED faultVars

MCHandleAppendEntriesResponseBusyHigherTerm(s, m) ==
    /\ HandleAppendEntriesResponseBusyHigherTerm(s, m)
    /\ UNCHANGED faultVars

MCHandleInstallSnapshotRequest(s, m) ==
    /\ HandleInstallSnapshotRequest(s, m)
    /\ UNCHANGED faultVars

MCHandleInstallSnapshotResponseNormal(s, m) ==
    /\ HandleInstallSnapshotResponseNormal(s, m)
    /\ UNCHANGED faultVars

MCHandleInstallSnapshotResponseWithHigherTerm(s, m) ==
    /\ HandleInstallSnapshotResponseWithHigherTerm(s, m)
    /\ UNCHANGED faultVars

MCAdvanceCommitIndex(s) ==
    /\ AdvanceCommitIndex(s)
    /\ UNCHANGED faultVars

MCApplyCommittedEntries(s) ==
    /\ ApplyCommittedEntries(s)
    /\ UNCHANGED faultVars

MCNotifyReadIndexAfterSnapshot(s) ==
    /\ NotifyReadIndexAfterSnapshot(s)
    /\ UNCHANGED faultVars

MCRestartFromPersisted(s) ==
    /\ RestartFromPersisted(s)
    /\ UNCHANGED faultVars

MCTickClock ==
    /\ TickClock
    /\ UNCHANGED faultVars

\* ============================================================================
\* MCNext
\* ============================================================================

MCNext ==
    \/ \E s \in Server : MCElectionTimeout(s)
    \/ \E s \in Server : MCCrash(s)
    \/ \E s \in Server : MCRestartFromPersisted(s)
    \/ \E s \in Server : \E v \in Values : MCClientRequest(s, v)
    \/ \E s, t \in Server : MCAppendEntries(s, t)
    \/ \E s, t \in Server : MCInstallSnapshot(s, t)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCHandleRequestVoteRequestDeny(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCHandleRequestVoteRequestGrantSameTerm(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCHandleRequestVoteRequestHigherTermStep1(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCHandleRequestVoteRequestHigherTermStep2(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCHandleRequestVoteRequestHigherTermStep3(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCHandleRequestVoteResponse(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCHandleAppendEntriesRequest(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCHandleAppendEntriesResponse(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCSendEBUSYResponse(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCHandleAppendEntriesResponseBusyNormal(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCHandleAppendEntriesResponseBusyHigherTerm(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCHandleInstallSnapshotRequest(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCHandleInstallSnapshotResponseNormal(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            MCHandleInstallSnapshotResponseWithHigherTerm(s, m)
    \/ \E s \in Server : MCAdvanceCommitIndex(s)
    \/ \E s \in Server : MCApplyCommittedEntries(s)
    \/ \E s \in Server : \E idx \in 1..5 : MCServeReadIndex(s, idx)
    \/ \E s \in Server : MCNotifyReadIndexAfterSnapshot(s)
    \/ \E s \in Server : MCStepDown(s)
    \/ MCTickClock

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

\* ============================================================================
\* SYMMETRY AND VIEW
\* ============================================================================

\* Symmetry on server set reduces state space significantly
Symmetry == Permutations(Server)

\* Exclude fault counters from state view (only protocol state matters)
MCView == <<vars>>

\* ============================================================================
\* STATE SPACE PRUNING
\* ============================================================================

\* Hard cap on messages in flight to prevent queue blowup
MCMsgBound == BagCardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* INVARIANTS (standard + structural; bug-family invariants commented out)
\* ============================================================================

\* --- Standard Safety (always enabled) ---
\* INVARIANT ElectionSafety
\* INVARIANT LogMatching
\* INVARIANT LeaderCompleteness

\* --- Structural (always enabled) ---
\* INVARIANT TypeOK
\* INVARIANT PersistMonotone
\* INVARIANT CommitMonotone
\* INVARIANT MCMsgBound

\* --- Bug-family Extension Invariants (commented out; enable in hunt cfgs) ---
\* INVARIANT VoteOncePerTerm           \* Family 1
\* INVARIANT PersistBeforeSend         \* Family 1
\* INVARIANT StepDownOnHigherTerm      \* Family 2
\* INVARIANT ReadIndexSafety           \* Families 3, 4
\* INVARIANT NoPendingReadAfterStepDown \* Family 4

=============================================================================
