---- MODULE MC ----
(* ========================================================================
   Model Checking Spec for sonic-linkmgrd Active-Active

   Wraps base spec with counter-bounded fault-injection actions.
   Deterministic/reactive actions (ProcessEvent, timer handlers) are
   NOT bounded — only actions that introduce non-determinism.
   ======================================================================== *)
EXTENDS base

CONSTANTS
    MaxHeartbeatLimit,     \* Bound on heartbeat stimulus actions
    MaxMuxNotifyLimit,     \* Bound on mux notification actions
    MaxLinkChangeLimit,    \* Bound on link state change actions
    MaxDefaultRouteLimit,  \* Bound on default route change actions
    MaxModeChangeLimit,    \* Bound on mode change actions
    MaxSoCRestartLimit     \* Bound on SoC restart (fault injection)

VARIABLES
    ctrHeartbeat,     \* [Tor -> 0..MaxHeartbeatLimit]
    ctrMuxNotify,     \* [Tor -> 0..MaxMuxNotifyLimit]
    ctrLinkChange,    \* [Tor -> 0..MaxLinkChangeLimit]
    ctrDefaultRoute,  \* [Tor -> 0..MaxDefaultRouteLimit]
    ctrModeChange,    \* [Tor -> 0..MaxModeChangeLimit]
    ctrSoCRestart     \* [Tor -> 0..MaxSoCRestartLimit]

faultVars == <<ctrHeartbeat, ctrMuxNotify, ctrLinkChange,
               ctrDefaultRoute, ctrModeChange, ctrSoCRestart>>

mcVars == <<vars, faultVars>>

(* ========================================================================
   Counter-Bounded Wrappers
   ======================================================================== *)

\* --- Bounded stimulus actions ---

MCHeartbeatActive(t) ==
    /\ ctrHeartbeat[t] < MaxHeartbeatLimit
    /\ HeartbeatActive(t)
    /\ ctrHeartbeat' = [ctrHeartbeat EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<ctrMuxNotify, ctrLinkChange, ctrDefaultRoute,
                   ctrModeChange, ctrSoCRestart>>

MCHeartbeatUnknown(t) ==
    /\ ctrHeartbeat[t] < MaxHeartbeatLimit
    /\ HeartbeatUnknown(t)
    /\ ctrHeartbeat' = [ctrHeartbeat EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<ctrMuxNotify, ctrLinkChange, ctrDefaultRoute,
                   ctrModeChange, ctrSoCRestart>>

MCPeerHeartbeatActive(t) ==
    /\ ctrHeartbeat[t] < MaxHeartbeatLimit
    /\ PeerHeartbeatActive(t)
    /\ ctrHeartbeat' = [ctrHeartbeat EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<ctrMuxNotify, ctrLinkChange, ctrDefaultRoute,
                   ctrModeChange, ctrSoCRestart>>

MCPeerHeartbeatUnknown(t) ==
    /\ ctrHeartbeat[t] < MaxHeartbeatLimit
    /\ PeerHeartbeatUnknown(t)
    /\ ctrHeartbeat' = [ctrHeartbeat EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<ctrMuxNotify, ctrLinkChange, ctrDefaultRoute,
                   ctrModeChange, ctrSoCRestart>>

MCMuxNotification(t) ==
    /\ ctrMuxNotify[t] < MaxMuxNotifyLimit
    /\ MuxNotification(t)
    /\ ctrMuxNotify' = [ctrMuxNotify EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<ctrHeartbeat, ctrLinkChange, ctrDefaultRoute,
                   ctrModeChange, ctrSoCRestart>>

MCLinkChange(t) ==
    /\ ctrLinkChange[t] < MaxLinkChangeLimit
    /\ LinkChange(t)
    /\ ctrLinkChange' = [ctrLinkChange EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<ctrHeartbeat, ctrMuxNotify, ctrDefaultRoute,
                   ctrModeChange, ctrSoCRestart>>

MCDefaultRouteChange(t) ==
    /\ ctrDefaultRoute[t] < MaxDefaultRouteLimit
    /\ DefaultRouteChange(t)
    /\ ctrDefaultRoute' = [ctrDefaultRoute EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<ctrHeartbeat, ctrMuxNotify, ctrLinkChange,
                   ctrModeChange, ctrSoCRestart>>

MCModeChange(t) ==
    /\ ctrModeChange[t] < MaxModeChangeLimit
    /\ ModeChange(t)
    /\ ctrModeChange' = [ctrModeChange EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<ctrHeartbeat, ctrMuxNotify, ctrLinkChange,
                   ctrDefaultRoute, ctrSoCRestart>>

MCSoCRestart(t) ==
    /\ ctrSoCRestart[t] < MaxSoCRestartLimit
    /\ SoCRestart(t)
    /\ ctrSoCRestart' = [ctrSoCRestart EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<ctrHeartbeat, ctrMuxNotify, ctrLinkChange,
                   ctrDefaultRoute, ctrModeChange>>

\* --- Unbounded reactive actions ---

MCProcessEvent(t) ==
    /\ ProcessEvent(t)
    /\ UNCHANGED faultVars

MCMuxProbeTimeout(t) ==
    /\ MuxProbeTimeout(t)
    /\ UNCHANGED faultVars

MCMuxWaitTimeout(t) ==
    /\ MuxWaitTimeout(t)
    /\ UNCHANGED faultVars

MCPeerWaitTimeout(t) ==
    /\ PeerWaitTimeout(t)
    /\ UNCHANGED faultVars

MCResyncTimeout(t) ==
    /\ ResyncTimeout(t)
    /\ UNCHANGED faultVars

(* ========================================================================
   MC Init and Next
   ======================================================================== *)

MCInit ==
    /\ Init
    /\ ctrHeartbeat    = [t \in Tor |-> 0]
    /\ ctrMuxNotify    = [t \in Tor |-> 0]
    /\ ctrLinkChange   = [t \in Tor |-> 0]
    /\ ctrDefaultRoute = [t \in Tor |-> 0]
    /\ ctrModeChange   = [t \in Tor |-> 0]
    /\ ctrSoCRestart   = [t \in Tor |-> 0]

MCNext ==
    \E t \in Tor :
        \* --- Bounded stimulus actions ---
        \/ MCHeartbeatActive(t)
        \/ MCHeartbeatUnknown(t)
        \/ MCPeerHeartbeatActive(t)
        \/ MCPeerHeartbeatUnknown(t)
        \/ MCMuxNotification(t)
        \/ MCLinkChange(t)
        \/ MCDefaultRouteChange(t)
        \/ MCModeChange(t)
        \/ MCSoCRestart(t)
        \* --- Unbounded reactive actions ---
        \/ MCProcessEvent(t)
        \/ MCMuxProbeTimeout(t)
        \/ MCMuxWaitTimeout(t)
        \/ MCPeerWaitTimeout(t)
        \/ MCResyncTimeout(t)

MCSpec == MCInit /\ [][MCNext]_mcVars

(* ========================================================================
   Structural Invariants (always hold in correct states)
   ======================================================================== *)

\* Event queue bounded (prevents state explosion)
MaxQueueSize == 10
EventQueueBounded ==
    \A t \in Tor : Cardinality(eventQueue[t]) <= MaxQueueSize

\* Sub-SM and composite states are consistent when queue is empty
StatesConsistentWhenIdle ==
    \A t \in Tor :
        eventQueue[t] = {} =>
        /\ subLpState[t] = lpState[t]
        /\ subMuxState[t] = muxState[t]
        /\ subLinkState[t] = linkState[t]

\* Counters within bounds
CountersValid ==
    /\ \A t \in Tor : ctrHeartbeat[t]    <= MaxHeartbeatLimit
    /\ \A t \in Tor : ctrMuxNotify[t]    <= MaxMuxNotifyLimit
    /\ \A t \in Tor : ctrLinkChange[t]   <= MaxLinkChangeLimit
    /\ \A t \in Tor : ctrDefaultRoute[t] <= MaxDefaultRouteLimit
    /\ \A t \in Tor : ctrModeChange[t]   <= MaxModeChangeLimit
    /\ \A t \in Tor : ctrSoCRestart[t]   <= MaxSoCRestartLimit

\* Mux probe backoff within range
BackoffInRange ==
    \A t \in Tor : muxProbeBackoff[t] \in 1..MAX_BACKOFF

(* ========================================================================
   Symmetry
   ======================================================================== *)

MCSymmetry == Permutations(Tor)

====
