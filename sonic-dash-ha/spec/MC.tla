---- MODULE MC ----
(*
 * Model Checking wrapper for sonic-dash-ha HA state machine.
 * Counter-bounds fault-injection actions; reactive actions pass through.
 *
 * Bounded (fault-injection / non-deterministic):
 *   CrashNode, LoseMessage, DeleteActor, ChangeDesiredState,
 *   DpuHealthChange, EnterStandalone (gray failure)
 *
 * Unbounded (reactive / deterministic):
 *   All message handlers, FlushOutgoing, CreateActor, Receive*,
 *   state machine transitions driven by messages or local state
 *)

EXTENDS base, TLC

\* ===========================================================================
\* MC Constants (counter bounds)
\* ===========================================================================

CONSTANTS
    MaxCrashLimit,          \* Max CrashNode events (Family 3)
    MaxLoseLimit,           \* Max LoseMessage events (Families 1-3)
    MaxDeleteLimit,         \* Max DeleteActor events (Family 1)
    MaxDesiredChangeLimit,  \* Max ChangeDesiredState events (Family 4)
    MaxHealthChangeLimit,   \* Max DpuHealthChange events (Family 5)
    MaxStandaloneLimit      \* Max EnterStandalone events (Family 4)

\* ===========================================================================
\* MC Variables (fault counters)
\* ===========================================================================

VARIABLES
    crashCount,
    loseCount,
    deleteCount,
    desiredChangeCount,
    healthChangeCount,
    standaloneCount

faultVars == <<crashCount, loseCount, deleteCount,
              desiredChangeCount, healthChangeCount, standaloneCount>>

mcVars == <<vars, faultVars>>

\* ===========================================================================
\* Counter-Bounded Wrappers (fault-injection)
\* ===========================================================================

\* Crash between commit and send (Family 3)
MCCrashNode(n) ==
    /\ crashCount < MaxCrashLimit
    /\ CrashNode(n)
    /\ crashCount' = crashCount + 1
    /\ UNCHANGED <<loseCount, deleteCount, desiredChangeCount,
                   healthChangeCount, standaloneCount>>

\* Message loss (Families 1-3)
MCLoseMessage ==
    /\ loseCount < MaxLoseLimit
    /\ LoseMessage
    /\ loseCount' = loseCount + 1
    /\ UNCHANGED <<crashCount, deleteCount, desiredChangeCount,
                   healthChangeCount, standaloneCount>>

\* Actor deletion without notification (Family 1)
MCDeleteActor(n, level) ==
    /\ deleteCount < MaxDeleteLimit
    /\ DeleteActor(n, level)
    /\ deleteCount' = deleteCount + 1
    /\ UNCHANGED <<crashCount, loseCount, desiredChangeCount,
                   healthChangeCount, standaloneCount>>

\* SDN controller changes desired state (Family 4)
MCChangeDesiredState(n, ds) ==
    /\ desiredChangeCount < MaxDesiredChangeLimit
    /\ ChangeDesiredState(n, ds)
    /\ desiredChangeCount' = desiredChangeCount + 1
    /\ UNCHANGED <<crashCount, loseCount, deleteCount,
                   healthChangeCount, standaloneCount>>

\* DPU health change (Family 5)
MCDpuHealthChange(n, newUp) ==
    /\ healthChangeCount < MaxHealthChangeLimit
    /\ DpuHealthChange(n, newUp)
    /\ healthChangeCount' = healthChangeCount + 1
    /\ UNCHANGED <<crashCount, loseCount, deleteCount,
                   desiredChangeCount, standaloneCount>>

\* Enter standalone — bounded because it's non-deterministic
MCEnterStandalone(n) ==
    /\ standaloneCount < MaxStandaloneLimit
    /\ EnterStandalone(n)
    /\ standaloneCount' = standaloneCount + 1
    /\ UNCHANGED <<crashCount, loseCount, deleteCount,
                   desiredChangeCount, healthChangeCount>>

\* ===========================================================================
\* Unconstrained Wrappers (reactive / deterministic)
\* ===========================================================================

MCStartConnecting(n)            == StartConnecting(n)            /\ UNCHANGED faultVars
MCBecomeConnected(n)            == BecomeConnected(n)            /\ UNCHANGED faultVars
MCSendRequestVote(n)            == SendRequestVote(n)            /\ UNCHANGED faultVars
MCHandleRequestVote(n)          == HandleRequestVote(n)          /\ UNCHANGED faultVars
MCHandleVoteResponse(n)         == HandleVoteResponse(n)         /\ UNCHANGED faultVars
MCCompleteInitToActive(n)       == CompleteInitToActive(n)       /\ UNCHANGED faultVars
MCHandleBulkSyncDone(n)         == HandleBulkSyncDone(n)         /\ UNCHANGED faultVars
MCInitiateSwitchover(n)         == InitiateSwitchover(n)         /\ UNCHANGED faultVars
MCHandleSwitchOver(n)           == HandleSwitchOver(n)           /\ UNCHANGED faultVars
MCRejectSwitchOver(n)           == RejectSwitchOver(n)           /\ UNCHANGED faultVars
MCCompleteSwitchoverToActive(n) == CompleteSwitchoverToActive(n) /\ UNCHANGED faultVars
MCCompleteSwitchoverToStandby(n)== CompleteSwitchoverToStandby(n)/\ UNCHANGED faultVars
MCHandlePeerDestroying(n)       == HandlePeerDestroying(n)       /\ UNCHANGED faultVars
MCExitStandalone(n)             == ExitStandalone(n)             /\ UNCHANGED faultVars
MCInitToStandbyTimeout(n)       == InitToStandbyTimeout(n)       /\ UNCHANGED faultVars
MCSwitchoverFailed(n)           == SwitchoverFailed(n)           /\ UNCHANGED faultVars
MCStartDestroying(n)            == StartDestroying(n)            /\ UNCHANGED faultVars
MCCompleteDestroy(n)            == CompleteDestroy(n)            /\ UNCHANGED faultVars
MCGoToDead(n)                   == GoToDead(n)                   /\ UNCHANGED faultVars
MCCreateActor(n, level)         == CreateActor(n, level)         /\ UNCHANGED faultVars
MCReceiveConfig(n)              == ReceiveConfig(n)              /\ UNCHANGED faultVars
MCReceiveVdpuState(n)           == ReceiveVdpuState(n)           /\ UNCHANGED faultVars
MCReceiveHasetState(n)          == ReceiveHasetState(n)          /\ UNCHANGED faultVars
MCFlushOutgoing(n)              == FlushOutgoing(n)              /\ UNCHANGED faultVars

\* ===========================================================================
\* MC Init and Next
\* ===========================================================================

MCInit ==
    /\ Init
    /\ crashCount         = 0
    /\ loseCount          = 0
    /\ deleteCount        = 0
    /\ desiredChangeCount = 0
    /\ healthChangeCount  = 0
    /\ standaloneCount    = 0

MCNext ==
    \/ \E n \in Node :
        \* Core protocol (reactive)
        \/ MCStartConnecting(n)
        \/ MCBecomeConnected(n)
        \/ MCSendRequestVote(n)
        \/ MCHandleRequestVote(n)
        \/ MCHandleVoteResponse(n)
        \/ MCCompleteInitToActive(n)
        \/ MCHandleBulkSyncDone(n)
        \/ MCInitiateSwitchover(n)
        \/ MCHandleSwitchOver(n)
        \/ MCRejectSwitchOver(n)
        \/ MCCompleteSwitchoverToActive(n)
        \/ MCCompleteSwitchoverToStandby(n)
        \/ MCHandlePeerDestroying(n)
        \/ MCExitStandalone(n)
        \/ MCInitToStandbyTimeout(n)
        \/ MCSwitchoverFailed(n)
        \/ MCStartDestroying(n)
        \/ MCCompleteDestroy(n)
        \/ MCGoToDead(n)
        \* Actor lifecycle (reactive: create; bounded: delete)
        \/ \E level \in AllLevels : MCCreateActor(n, level)
        \/ \E level \in AllLevels : MCDeleteActor(n, level)
        \* Message ordering (reactive)
        \/ MCReceiveConfig(n)
        \/ MCReceiveVdpuState(n)
        \/ MCReceiveHasetState(n)
        \* Crash recovery
        \/ MCFlushOutgoing(n)
        \/ MCCrashNode(n)
        \* Health + Standalone (bounded)
        \/ MCDpuHealthChange(n, TRUE)
        \/ MCDpuHealthChange(n, FALSE)
        \/ MCEnterStandalone(n)
        \* Desired state (bounded)
        \/ \E ds \in AllDesiredStates : MCChangeDesiredState(n, ds)
    \* Message loss (bounded)
    \/ MCLoseMessage

MCSpec == MCInit /\ [][MCNext]_mcVars

\* ===========================================================================
\* Symmetry and State Space Control
\* ===========================================================================

\* Symmetry reduction — nodes are interchangeable
ModelSymmetry == Permutations(Node)

\* State constraint: bound message buffer to prevent explosion
MaxMsgBuffer == 12
MsgBufferConstraint ==
    Cardinality(messages) + Cardinality(UNION {pendingOut[n] : n \in Node}) <= MaxMsgBuffer

\* ===========================================================================
\* Structural Invariants (always checked)
\* ===========================================================================

\* Fault counters are within bounds
FaultCountersOK ==
    /\ crashCount         \in 0..MaxCrashLimit
    /\ loseCount          \in 0..MaxLoseLimit
    /\ deleteCount        \in 0..MaxDeleteLimit
    /\ desiredChangeCount \in 0..MaxDesiredChangeLimit
    /\ healthChangeCount  \in 0..MaxHealthChangeLimit
    /\ standaloneCount    \in 0..MaxStandaloneLimit

====
