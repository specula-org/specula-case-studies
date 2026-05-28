---- MODULE base ----
(* ========================================================================
   sonic-linkmgrd Active-Active Dual-ToR Link Manager

   Models the triple state machine interaction (LinkProber x MuxState x
   LinkState) for Active-Active mode with two ToR instances.

   Bug Families:
   1. Event Ordering / strand::wrap dispatch (HIGH)
   2. Missing/Incomplete Composite State Transitions (HIGH)
   3. Timer Interference with State Transitions (MEDIUM-HIGH)
   4. Default Route State Interaction (MEDIUM)
   5. Peer State Desynchronization (MEDIUM-HIGH)
   ======================================================================== *)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    Tor,    \* Set of ToR instances, e.g., {t1, t2}
    NULL    \* Placeholder for "no value"

(* ========================================================================
   State Value Definitions
   ======================================================================== *)

\* LinkProber states (src/link_prober/LinkProberState.h:62-71)
LPActive      == "LPActive"
LPUnknown     == "LPUnknown"
LPWait        == "LPWait"
LPPeerActive  == "LPPeerActive"
LPPeerUnknown == "LPPeerUnknown"
LPPeerWait    == "LPPeerWait"

\* MuxState states (src/mux_state/MuxState.h:50-58)
MuxActive  == "MuxActive"
MuxStandby == "MuxStandby"
MuxUnknown == "MuxUnknown"
MuxError   == "MuxError"
MuxWait    == "MuxWait"

\* LinkState states (src/link_state/LinkState.h:48-52)
LinkUp   == "LinkUp"
LinkDown == "LinkDown"

\* DefaultRoute states (src/link_manager/LinkManagerStateMachineBase.h:157-163)
DrOK   == "DrOK"
DrNA   == "DrNA"
DrWait == "DrWait"

\* Mode values (src/common/MuxPortConfig.h)
ModeAuto     == "Auto"
ModeActive   == "Active"
ModeStandby  == "Standby"
ModeDetached == "Detached"

\* Health labels (src/link_manager/LinkManagerStateMachineBase.h:144-150)
Healthy   == "Healthy"
Unhealthy == "Unhealthy"

\* Event types for strand dispatch queue (Family 1)
EvLP     == "EvLP"
EvMux    == "EvMux"
EvLink   == "EvLink"
EvPeerLP == "EvPeerLP"

\* Timer types (Family 3)
TMuxProbe    == "MuxProbe"     \* mDeadlineTimer (ActiveActive.cpp:1222)
TWait        == "WaitTimer"    \* mWaitTimer (ActiveActive.cpp:1263)
TPeerWait    == "PeerWait"     \* mPeerWaitTimer (ActiveActive.cpp:1302)
TResync      == "Resync"       \* mResyncTimer (ActiveActive.cpp:457)
TOscillation == "Oscillation"  \* mOscillationTimer

\* Derived sets
LocalLPStates  == {LPActive, LPUnknown, LPWait}
PeerLPStates   == {LPPeerActive, LPPeerUnknown, LPPeerWait}
AllLPStates    == LocalLPStates \union PeerLPStates
AllMuxStates   == {MuxActive, MuxStandby, MuxUnknown, MuxError, MuxWait}
AllLinkStates  == {LinkUp, LinkDown}
AllDfltRoutes  == {DrOK, DrNA, DrWait}
AllModes       == {ModeAuto, ModeActive, ModeStandby, ModeDetached}
AllTimerTypes  == {TMuxProbe, TWait, TPeerWait, TResync, TOscillation}
EventTypes     == {EvLP, EvMux, EvLink, EvPeerLP}

\* Abstracted backoff limit (real MAX_BACKOFF_FACTOR=32, ActiveActive.cpp:30)
MAX_BACKOFF == 4

(* ========================================================================
   Variables
   ======================================================================== *)

VARIABLES
    \* Sub-state-machine actual states - updated immediately on stimulus.
    \* Tracked separately for self-transition suppression
    \* (Family 2: MuxStateMachine.cpp:176, LinkProberStateMachineBase.cpp:202)
    subLpState,          \* [Tor -> AllLPStates]
    subMuxState,         \* [Tor -> AllMuxStates]
    subLinkState,        \* [Tor -> AllLinkStates]

    \* LinkManager composite state - updated when event is processed.
    \* Transition table operates on these (Family 2).
    lpState,             \* [Tor -> AllLPStates]
    muxState,            \* [Tor -> AllMuxStates]
    linkState,           \* [Tor -> AllLinkStates]

    \* Event queue per ToR - SET (unordered) models strand::wrap
    \* non-FIFO ordering (Family 1: #104, #254)
    eventQueue,          \* [Tor -> SUBSET [type: EventTypes, state: STRING]]

    \* Timer state per ToR (Family 3: #253, #81)
    timerPending,        \* [Tor -> [AllTimerTypes -> BOOLEAN]]
    muxProbeBackoff,     \* [Tor -> 1..MAX_BACKOFF]

    \* Peer state tracking per ToR (Family 5: #143, #285)
    peerMuxState,        \* [Tor -> AllMuxStates]
    peerLpState,         \* [Tor -> PeerLPStates]

    \* Environment per ToR (Family 4)
    defaultRoute,        \* [Tor -> AllDfltRoutes]
    mode,                \* [Tor -> AllModes]

    \* Mux state tracking
    lastMuxNotification, \* [Tor -> AllMuxStates]
    switchTarget         \* [Tor -> AllMuxStates \union {NULL}]

\* Variable groups for UNCHANGED clauses
subVars   == <<subLpState, subMuxState, subLinkState>>
compVars  == <<lpState, muxState, linkState>>
queueVar  == <<eventQueue>>
timerVars == <<timerPending, muxProbeBackoff>>
peerVars  == <<peerMuxState, peerLpState>>
envVars   == <<defaultRoute, mode>>
trackVars == <<lastMuxNotification, switchTarget>>

vars == <<subVars, compVars, queueVar, timerVars, peerVars, envVars, trackVars>>

(* ========================================================================
   Helpers
   ======================================================================== *)

\* Peer ToR (assumes exactly 2 ToRs)
OtherTor(t) == CHOOSE t2 \in Tor : t2 /= t

Min(a, b) == IF a <= b THEN a ELSE b

\* Compute health from state (ActiveActive.cpp:1138-1152)
\* Not a variable - computed deterministically from current state.
\* Note: defaultRoute check is conditional on enableDefaultRouteFeature
\* (line 1147: ifEnableDefaultRouteFeature() == false || DR == OK).
\* Omitted here as the feature flag is not modeled; DR interactions
\* are covered by DefaultRouteChange guards instead.
Health(t) ==
    IF /\ linkState[t] = LinkUp                          \* line 1143
       /\ lpState[t] = LPActive                          \* line 1144
       /\ \/ muxState[t] = lastMuxNotification[t]        \* line 1145
          \/ lastMuxNotification[t] = MuxUnknown
    THEN Healthy
    ELSE Unhealthy

\* Initialize LP state from mux state on link up
\* (ActiveActive.cpp:1187-1208)
InitLPFromMux(mux) ==
    CASE mux = MuxActive  -> LPActive       \* line 1194
      [] mux = MuxStandby -> LPUnknown      \* line 1198
      [] OTHER            -> LPWait          \* line 1202-1206

\* Initialize peer LP state from peer mux state on link up
InitPeerLPFromMux(mux) ==
    CASE mux = MuxActive  -> LPPeerActive    \* line 1194
      [] mux = MuxStandby -> LPPeerUnknown   \* line 1198
      [] OTHER            -> LPPeerWait       \* line 1202-1206

\* Check if transition has a registered handler
\* (ActiveActive.cpp:653-774 — initializeTransitionFunctionTable)
HasHandler(lp, mux, link) ==
    \/ lp = LPActive  /\ mux = MuxActive  /\ link = LinkUp    \* line 658
    \/ lp = LPActive  /\ mux = MuxStandby /\ link = LinkUp    \* line 667
    \/ lp = LPActive  /\ mux = MuxUnknown /\ link = LinkUp    \* line 676
    \/ lp = LPUnknown /\ mux = MuxActive  /\ link = LinkUp    \* line 685
    \/ lp = LPUnknown /\ mux = MuxStandby /\ link = LinkUp    \* line 694
    \/ lp = LPUnknown /\ mux = MuxUnknown /\ link = LinkUp    \* line 712
    \/ lp = LPActive  /\ mux = MuxError   /\ link = LinkUp    \* line 721
    \/ lp = LPActive  /\ mux = MuxWait    /\ link = LinkUp    \* line 730
    \/ lp = LPUnknown /\ mux = MuxWait    /\ link = LinkUp    \* line 739
    \/ lp = LPUnknown /\ mux = MuxWait    /\ link = LinkDown  \* line 748
    \/ lp = LPUnknown /\ mux = MuxUnknown /\ link = LinkDown  \* line 757
    \/ lp = LPUnknown /\ mux = MuxActive  /\ link = LinkDown  \* line 766

(* ========================================================================
   Init
   ======================================================================== *)

Init ==
    \* Initial composite state: (Wait, Wait, Down) (ActiveActive.cpp:50-52)
    /\ subLpState   = [t \in Tor |-> LPWait]
    /\ subMuxState  = [t \in Tor |-> MuxWait]
    /\ subLinkState = [t \in Tor |-> LinkDown]
    /\ lpState   = [t \in Tor |-> LPWait]
    /\ muxState  = [t \in Tor |-> MuxWait]
    /\ linkState = [t \in Tor |-> LinkDown]
    /\ eventQueue = [t \in Tor |-> {}]
    /\ timerPending = [t \in Tor |-> [tm \in AllTimerTypes |-> FALSE]]
    /\ muxProbeBackoff = [t \in Tor |-> 1]
    /\ peerMuxState = [t \in Tor |-> MuxWait]
    /\ peerLpState  = [t \in Tor |-> LPPeerWait]
    /\ defaultRoute = [t \in Tor |-> DrWait]
    /\ mode = [t \in Tor |-> ModeAuto]
    /\ lastMuxNotification = [t \in Tor |-> MuxUnknown]
    /\ switchTarget = [t \in Tor |-> NULL]

(* ========================================================================
   External Stimulus Actions

   Events arrive at sub-state-machines. If the sub-SM state changes
   (not a self-transition), an event is posted to the LinkManager queue
   via strand::wrap (modeled as unordered set, Family 1).

   Self-transition suppression (Family 2): when sub-SM is already in the
   target state, no event is posted. This models the bug mechanism from
   #136 where Unknown->Unknown produces no event, breaking retry loops.
   ======================================================================== *)

\* ICMP heartbeat: self ToR active
\* (LinkProberStateMachineBase.cpp:188-207)
HeartbeatActive(t) ==
    /\ subLpState[t] /= LPActive                    \* line 202: not self-transition
    /\ subLpState' = [subLpState EXCEPT ![t] = LPActive]
    /\ eventQueue' = [eventQueue EXCEPT ![t] = @ \union
                      {[type |-> EvLP, state |-> LPActive]}]
    /\ UNCHANGED <<subMuxState, subLinkState, compVars,
                   timerVars, peerVars, envVars, trackVars>>

\* ICMP heartbeat timeout: self ToR unknown
HeartbeatUnknown(t) ==
    /\ subLpState[t] /= LPUnknown                   \* line 202: not self-transition
    /\ subLpState' = [subLpState EXCEPT ![t] = LPUnknown]
    /\ eventQueue' = [eventQueue EXCEPT ![t] = @ \union
                      {[type |-> EvLP, state |-> LPUnknown]}]
    /\ UNCHANGED <<subMuxState, subLinkState, compVars,
                   timerVars, peerVars, envVars, trackVars>>

\* Peer heartbeat: peer ToR active
PeerHeartbeatActive(t) ==
    /\ subLpState[t] /= LPPeerActive                \* not self-transition
    /\ subLpState' = [subLpState EXCEPT ![t] = LPPeerActive]
    /\ eventQueue' = [eventQueue EXCEPT ![t] = @ \union
                      {[type |-> EvPeerLP, state |-> LPPeerActive]}]
    /\ UNCHANGED <<subMuxState, subLinkState, compVars,
                   timerVars, peerVars, envVars, trackVars>>

\* Peer heartbeat timeout: peer unknown
PeerHeartbeatUnknown(t) ==
    /\ subLpState[t] /= LPPeerUnknown               \* not self-transition
    /\ subLpState' = [subLpState EXCEPT ![t] = LPPeerUnknown]
    /\ eventQueue' = [eventQueue EXCEPT ![t] = @ \union
                      {[type |-> EvPeerLP, state |-> LPPeerUnknown]}]
    /\ UNCHANGED <<subMuxState, subLinkState, compVars,
                   timerVars, peerVars, envVars, trackVars>>

\* Mux hardware state notification
\* (ActiveActive.cpp:295-330 handleMuxStateNotification,
\*  ActiveActive.cpp:202-250 handleProbeMuxStateNotification)
\* Can arrive from: mux probe response, orchagent, state DB
MuxNotification(t) ==
    \E ns \in {MuxActive, MuxStandby, MuxUnknown, MuxError} :
        \* Timer/tracking effects always happen regardless of self-transition
        \* (ActiveActive.cpp:307,310,321 — cancel timers, update tracking)
        /\ timerPending' = [timerPending EXCEPT ![t] =
               [@ EXCEPT ![TWait] = FALSE, ![TMuxProbe] = FALSE]]
        /\ lastMuxNotification' = [lastMuxNotification EXCEPT ![t] = ns]
        /\ switchTarget' = [switchTarget EXCEPT ![t] = NULL]
        \* Sub-SM state change + event posting only on non-self-transition
        \* (MuxStateMachine.cpp:176 — self-transition suppresses event)
        /\ IF subMuxState[t] /= ns
           THEN /\ subMuxState' = [subMuxState EXCEPT ![t] = ns]
                /\ eventQueue' = [eventQueue EXCEPT ![t] = @ \union
                                  {[type |-> EvMux, state |-> ns]}]
           ELSE /\ UNCHANGED <<subMuxState, eventQueue>>
        /\ UNCHANGED <<subLpState, subLinkState, compVars,
                       muxProbeBackoff, peerVars, envVars>>

\* Link state change notification
\* (MuxPort.cpp:156-170 handleLinkState)
LinkChange(t) ==
    \E ns \in AllLinkStates :
        /\ subLinkState[t] /= ns             \* not self-transition
        /\ subLinkState' = [subLinkState EXCEPT ![t] = ns]
        /\ eventQueue' = [eventQueue EXCEPT ![t] = @ \union
                          {[type |-> EvLink, state |-> ns]}]
        /\ UNCHANGED <<subLpState, subMuxState, compVars,
                       timerVars, peerVars, envVars, trackVars>>

(* ========================================================================
   Mux Switch Helper

   Called by transition handlers to initiate a mux state switch.
   Mode guards control whether switch is allowed.
   (ActiveActive.cpp:1058-1087 switchMuxState)
   ======================================================================== *)

\* DoSwitchMux sets: muxState', subMuxState', switchTarget', timerPending'
\* Caller must set remaining handler vars
DoSwitchMux(t, target, force, fallbackMux) ==
    LET allowed == \/ force                                        \* line 1064
                   \/ mode[t] \in {ModeAuto, ModeDetached}        \* line 1066
                   \/ (mode[t] = ModeActive /\ target = MuxActive)   \* line 1068
                   \/ (mode[t] = ModeStandby /\ target = MuxStandby) \* line 1070
    IN
    IF allowed
    THEN \* Allowed: enter target state directly (line 1078: enterMuxState
         \* sets ms(nextState) = label, NOT MuxWait).
         \* Wait timer tracks pending switch confirmation.
         /\ muxState'  = [muxState  EXCEPT ![t] = target]
         /\ subMuxState' = [subMuxState EXCEPT ![t] = target]
         /\ switchTarget' = [switchTarget EXCEPT ![t] = target]
         /\ timerPending' = [timerPending EXCEPT ![t] =
                [@ EXCEPT ![TWait] = TRUE, ![TMuxProbe] = FALSE]]
    ELSE \* Not allowed: probe instead (line 1085)
         /\ muxState'  = [muxState EXCEPT ![t] = fallbackMux]
         /\ subMuxState' = subMuxState
         /\ switchTarget' = switchTarget
         /\ timerPending' = [timerPending EXCEPT ![t] =
                [@ EXCEPT ![TMuxProbe] = TRUE]]

(* ========================================================================
   Transition Handlers (ActiveActive mode)

   Each handler corresponds to a registered entry in the 3D transition
   table (ActiveActive.cpp:653-774). Unregistered entries default to
   AcceptNoOp (Family 2: potential stuck states).

   Each handler sets ALL "handler-controlled" variables:
     muxState, subMuxState, timerPending, muxProbeBackoff,
     peerMuxState, peerLpState, lastMuxNotification, switchTarget
   ======================================================================== *)

\* No-op: accept the proposed composite state, change nothing else.
\* Used for unregistered composite states (Family 2: NoStuckState check)
AcceptNoOp(t, pmux, pplp) ==
    /\ muxState' = [muxState EXCEPT ![t] = pmux]
    /\ peerLpState' = [peerLpState EXCEPT ![t] = pplp]
    /\ UNCHANGED <<subMuxState, timerPending, muxProbeBackoff,
                   peerMuxState, lastMuxNotification, switchTarget>>

\* ---- (Active, Active, Up) ----
\* ActiveActive.cpp:781-792 LinkProberActiveMuxActiveLinkUpTransitionFunction
TH_LPActive_MxActive_Up(t, pmux, pplp) ==
    /\ peerLpState' = [peerLpState EXCEPT ![t] = pplp]
    /\ UNCHANGED <<muxProbeBackoff, peerMuxState, lastMuxNotification>>
    /\ IF mode[t] = ModeStandby
       THEN \* Mode Standby: force switch to Standby (line 786)
            DoSwitchMux(t, MuxStandby, TRUE, pmux)
       ELSE IF lastMuxNotification[t] = MuxUnknown
       THEN \* Last notification was Unknown: confirm Active (line 790)
            DoSwitchMux(t, MuxActive, FALSE, pmux)
       ELSE \* Normal Active/Active/Up: no action
            /\ muxState' = [muxState EXCEPT ![t] = pmux]
            /\ UNCHANGED <<subMuxState, switchTarget, timerPending>>

\* ---- (Active, Standby, Up) ----
\* ActiveActive.cpp:799-810 LinkProberActiveMuxStandbyLinkUpTransitionFunction
\* Family 4, MC-6: DrWait passes the /= DrNA check
TH_LPActive_MxStandby_Up(t, pmux, pplp) ==
    /\ peerLpState' = [peerLpState EXCEPT ![t] = pplp]
    /\ UNCHANGED <<muxProbeBackoff, peerMuxState, lastMuxNotification>>
    /\ IF mode[t] = ModeStandby
       THEN \* Mode Standby: retry standby switch if failed (line 805)
            DoSwitchMux(t, MuxStandby, TRUE, pmux)
       ELSE IF defaultRoute[t] /= DrNA
       THEN \* Default route not NA: switch to Active (line 808)
            \* BUG: DrWait also passes this check (MC-6)
            DoSwitchMux(t, MuxActive, FALSE, pmux)
       ELSE \* Default route NA: no switch
            /\ muxState' = [muxState EXCEPT ![t] = pmux]
            /\ UNCHANGED <<subMuxState, switchTarget, timerPending>>

\* ---- (Active, Unknown, Up) ----
\* ActiveActive.cpp:849-862 LinkProberActiveMuxUnknownLinkUpTransitionFunction
TH_LPActive_MxUnknown_Up(t, pmux, pplp) ==
    /\ peerLpState' = [peerLpState EXCEPT ![t] = pplp]
    /\ UNCHANGED <<peerMuxState, lastMuxNotification, switchTarget>>
    \* Start mux probe timer (line 854)
    /\ muxState' = [muxState EXCEPT ![t] = pmux]
    /\ subMuxState' = subMuxState
    /\ timerPending' = [timerPending EXCEPT ![t] = [@ EXCEPT ![TMuxProbe] = TRUE]]
    /\ muxProbeBackoff' = muxProbeBackoff

\* ---- (Unknown, Active, Up) ----
\* ActiveActive.cpp:817-828 LinkProberUnknownMuxActiveLinkUpTransitionFunction
TH_LPUnknown_MxActive_Up(t, pmux, pplp) ==
    /\ peerLpState' = [peerLpState EXCEPT ![t] = pplp]
    /\ UNCHANGED <<muxProbeBackoff, peerMuxState, lastMuxNotification>>
    /\ IF mode[t] = ModeActive
       THEN \* Mode Active: retry active (line 823)
            DoSwitchMux(t, MuxActive, TRUE, pmux)
       ELSE \* Otherwise: force standby (line 826)
            DoSwitchMux(t, MuxStandby, TRUE, pmux)

\* ---- (Unknown, Standby, Up) ----
\* ActiveActive.cpp:835-847 LinkProberUnknownMuxStandbyLinkUpTransitionFunction
TH_LPUnknown_MxStandby_Up(t, pmux, pplp) ==
    /\ peerLpState' = [peerLpState EXCEPT ![t] = pplp]
    /\ UNCHANGED <<muxProbeBackoff, peerMuxState, lastMuxNotification>>
    /\ IF mode[t] = ModeActive
       THEN \* Mode Active: retry active (line 841)
            DoSwitchMux(t, MuxActive, TRUE, pmux)
       ELSE IF lastMuxNotification[t] = MuxUnknown
       THEN \* Last notification Unknown: confirm standby (line 845)
            DoSwitchMux(t, MuxStandby, FALSE, pmux)
       ELSE \* Normal: no action
            /\ muxState' = [muxState EXCEPT ![t] = pmux]
            /\ UNCHANGED <<subMuxState, switchTarget, timerPending>>

\* ---- (Unknown, Unknown, Up) ----
\* ActiveActive.cpp:864-878 LinkProberUnknownMuxUnknownLinkUpTransitionFunction
\* Family 3, MC-5: backoff can reach MAX and stay there
TH_LPUnknown_MxUnknown_Up(t, pmux, pplp) ==
    /\ peerLpState' = [peerLpState EXCEPT ![t] = pplp]
    /\ UNCHANGED <<peerMuxState, lastMuxNotification, switchTarget>>
    \* Start mux probe with exponential backoff (line 873-874)
    /\ muxState' = [muxState EXCEPT ![t] = pmux]
    /\ subMuxState' = subMuxState
    /\ timerPending' = [timerPending EXCEPT ![t] = [@ EXCEPT ![TMuxProbe] = TRUE]]
    /\ muxProbeBackoff' = [muxProbeBackoff EXCEPT ![t] =
           Min(@ * 2, MAX_BACKOFF)]

\* ---- (Active, Error, Up) ----
\* ActiveActive.cpp:880-890 LinkProberActiveMuxErrorLinkUpTransitionFunction
TH_LPActive_MxError_Up(t, pmux, pplp) ==
    /\ peerLpState' = [peerLpState EXCEPT ![t] = pplp]
    /\ UNCHANGED <<peerMuxState, lastMuxNotification, switchTarget>>
    \* Start mux probe timer (line 885)
    /\ muxState' = [muxState EXCEPT ![t] = pmux]
    /\ subMuxState' = subMuxState
    /\ timerPending' = [timerPending EXCEPT ![t] = [@ EXCEPT ![TMuxProbe] = TRUE]]
    /\ muxProbeBackoff' = muxProbeBackoff

\* ---- (Active, Wait, Up) ----
\* ActiveActive.cpp:892-900 LinkProberActiveMuxWaitLinkUpTransitionFunction
\* Switches mux to Active (line 899: switchMuxState(Active))
TH_LPActive_MxWait_Up(t, pmux, pplp) ==
    /\ peerLpState' = [peerLpState EXCEPT ![t] = pplp]
    /\ UNCHANGED <<muxProbeBackoff, peerMuxState, lastMuxNotification>>
    /\ DoSwitchMux(t, MuxActive, FALSE, pmux)

\* ---- (Unknown, Wait, Up) ----
\* ActiveActive.cpp:907-911 LinkProberUnknownMuxWaitLinkUpTransitionFunction
\* Switches mux to Standby (line 910: switchMuxState(Standby))
TH_LPUnknown_MxWait_Up(t, pmux, pplp) ==
    /\ peerLpState' = [peerLpState EXCEPT ![t] = pplp]
    /\ UNCHANGED <<muxProbeBackoff, peerMuxState, lastMuxNotification>>
    /\ DoSwitchMux(t, MuxStandby, FALSE, pmux)

\* ---- (Unknown, Wait, Down) ----
\* ActiveActive.cpp:906-917 LinkProberUnknownMuxWaitLinkDownTransitionFunction
TH_LPUnknown_MxWait_Down(t, pmux, pplp) ==
    /\ peerLpState' = [peerLpState EXCEPT ![t] = pplp]
    /\ UNCHANGED <<muxProbeBackoff, peerMuxState, lastMuxNotification>>
    \* Switch to standby (line 912)
    /\ DoSwitchMux(t, MuxStandby, TRUE, pmux)

\* ---- (Unknown, Unknown, Down) ----
\* ActiveActive.cpp:919-930 LinkProberUnknownMuxUnknownLinkDownTransitionFunction
TH_LPUnknown_MxUnknown_Down(t, pmux, pplp) ==
    /\ peerLpState' = [peerLpState EXCEPT ![t] = pplp]
    /\ UNCHANGED <<muxProbeBackoff, peerMuxState, lastMuxNotification>>
    \* Switch to standby (line 925)
    /\ DoSwitchMux(t, MuxStandby, TRUE, pmux)

\* ---- (Unknown, Active, Down) ----
\* ActiveActive.cpp:932-943 LinkProberUnknownMuxActiveLinkDownTransitionFunction
TH_LPUnknown_MxActive_Down(t, pmux, pplp) ==
    /\ peerLpState' = [peerLpState EXCEPT ![t] = pplp]
    /\ UNCHANGED <<muxProbeBackoff, peerMuxState, lastMuxNotification>>
    \* Switch to standby (line 938)
    /\ DoSwitchMux(t, MuxStandby, TRUE, pmux)

(* ========================================================================
   Transition Table Dispatch

   Dispatches to the registered handler based on the composite state.
   Unregistered states default to AcceptNoOp (Family 2: #136, #169).

   (ActiveActive.cpp:539,566,599 — mStateTransitionHandler lookup)
   ======================================================================== *)

TransitionDispatch(t, lp, pmux, link, pplp) ==
    IF      lp = LPActive  /\ pmux = MuxActive  /\ link = LinkUp
    THEN    TH_LPActive_MxActive_Up(t, pmux, pplp)
    ELSE IF lp = LPActive  /\ pmux = MuxStandby /\ link = LinkUp
    THEN    TH_LPActive_MxStandby_Up(t, pmux, pplp)
    ELSE IF lp = LPActive  /\ pmux = MuxUnknown /\ link = LinkUp
    THEN    TH_LPActive_MxUnknown_Up(t, pmux, pplp)
    ELSE IF lp = LPUnknown /\ pmux = MuxActive  /\ link = LinkUp
    THEN    TH_LPUnknown_MxActive_Up(t, pmux, pplp)
    ELSE IF lp = LPUnknown /\ pmux = MuxStandby /\ link = LinkUp
    THEN    TH_LPUnknown_MxStandby_Up(t, pmux, pplp)
    ELSE IF lp = LPUnknown /\ pmux = MuxUnknown /\ link = LinkUp
    THEN    TH_LPUnknown_MxUnknown_Up(t, pmux, pplp)
    ELSE IF lp = LPActive  /\ pmux = MuxError   /\ link = LinkUp
    THEN    TH_LPActive_MxError_Up(t, pmux, pplp)
    ELSE IF lp = LPActive  /\ pmux = MuxWait    /\ link = LinkUp
    THEN    TH_LPActive_MxWait_Up(t, pmux, pplp)
    ELSE IF lp = LPUnknown /\ pmux = MuxWait    /\ link = LinkUp
    THEN    TH_LPUnknown_MxWait_Up(t, pmux, pplp)
    ELSE IF lp = LPUnknown /\ pmux = MuxWait    /\ link = LinkDown
    THEN    TH_LPUnknown_MxWait_Down(t, pmux, pplp)
    ELSE IF lp = LPUnknown /\ pmux = MuxUnknown /\ link = LinkDown
    THEN    TH_LPUnknown_MxUnknown_Down(t, pmux, pplp)
    ELSE IF lp = LPUnknown /\ pmux = MuxActive  /\ link = LinkDown
    THEN    TH_LPUnknown_MxActive_Down(t, pmux, pplp)
    ELSE    \* No handler registered (Family 2: potential stuck state)
            AcceptNoOp(t, pmux, pplp)

(* ========================================================================
   Event Processing (Family 1: strand::wrap non-ordering)

   The LinkManager processes events from the unordered queue.
   ANY event can be picked — this non-determinism models the
   strand::wrap reordering bug (#104, #254).
   ======================================================================== *)

\* Handle LinkProber event (ActiveActive.cpp:525-540)
HandleLPEvent(t, newLp) ==
    /\ lpState' = [lpState EXCEPT ![t] = newLp]
    /\ linkState' = linkState
    /\ UNCHANGED subLpState
    /\ TransitionDispatch(t, newLp, muxState[t], linkState[t], peerLpState[t])

\* Handle MuxState event (ActiveActive.cpp:530-560)
HandleMuxEvent(t, newMux) ==
    /\ lpState' = lpState
    /\ linkState' = linkState
    /\ UNCHANGED subLpState
    /\ TransitionDispatch(t, lpState[t], newMux, linkState[t], peerLpState[t])

\* Handle LinkState event (ActiveActive.cpp:574-600)
HandleLinkEvent(t, newLink) ==
    /\ linkState' = [linkState EXCEPT ![t] = newLink]
    /\ IF linkState[t] = LinkDown /\ newLink = LinkUp
       THEN \* Down->Up: initialize LP and peer LP from mux state
            \* (ActiveActive.cpp:594-595)
            LET newLp    == InitLPFromMux(muxState[t])
                newPeerLp == InitPeerLPFromMux(peerMuxState[t])
            IN
            /\ lpState'  = [lpState EXCEPT ![t] = newLp]
            /\ subLpState' = [subLpState EXCEPT ![t] = newLp]
            /\ TransitionDispatch(t, newLp, muxState[t], LinkUp, newPeerLp)
       ELSE IF linkState[t] = LinkUp /\ newLink = LinkDown
       THEN \* Up->Down: switch to standby if not already
            \* (ActiveActive.cpp:597)
            /\ lpState' = lpState
            /\ UNCHANGED subLpState
            /\ IF muxState[t] /= MuxStandby
               THEN /\ DoSwitchMux(t, MuxStandby, TRUE, muxState[t])
                    /\ UNCHANGED <<muxProbeBackoff, peerMuxState,
                                   peerLpState, lastMuxNotification>>
               ELSE AcceptNoOp(t, muxState[t], peerLpState[t])
       ELSE \* No special handling: use transition table
            /\ lpState' = lpState
            /\ UNCHANGED subLpState
            /\ TransitionDispatch(t, lpState[t], muxState[t], newLink,
                                  peerLpState[t])

\* Handle Peer LinkProber event (ActiveActive.cpp:613-642)
\* Family 5: peer state desynchronization
HandlePeerLPEvent(t, newPeerLp) ==
    /\ lpState' = lpState
    /\ linkState' = linkState
    /\ UNCHANGED <<subLpState, muxProbeBackoff, lastMuxNotification>>
    /\ peerLpState' = [peerLpState EXCEPT ![t] = newPeerLp]
    /\ IF newPeerLp = LPPeerActive
       THEN \* PeerActive: enter peer mux Active (line 628)
            /\ peerMuxState' = [peerMuxState EXCEPT ![t] = MuxActive]
            /\ UNCHANGED <<muxState, subMuxState, switchTarget, timerPending>>
       ELSE IF newPeerLp = LPPeerUnknown
            /\ Health(t) = Healthy                     \* line 633
            /\ mode[t] = ModeAuto                      \* line 1109
       THEN \* PeerUnknown + Healthy + Auto: switch peer to Standby
            \* (ActiveActive.cpp:633, 1105-1118)
            /\ peerMuxState' = [peerMuxState EXCEPT ![t] = MuxStandby]
            /\ timerPending' = [timerPending EXCEPT ![t] =
                   [@ EXCEPT ![TPeerWait] = TRUE]]
            /\ UNCHANGED <<muxState, subMuxState, switchTarget>>
       ELSE \* PeerUnknown + NOT (Healthy AND Auto): stale peer state
            \* Family 5, MC-8: peerMuxState not updated when unhealthy
            /\ UNCHANGED <<peerMuxState, muxState, subMuxState,
                           switchTarget, timerPending>>

\* Main event processing dispatcher
ProcessEvent(t) ==
    /\ eventQueue[t] /= {}
    /\ \E ev \in eventQueue[t] :
        /\ eventQueue' = [eventQueue EXCEPT ![t] = @ \ {ev}]
        /\ UNCHANGED <<subLinkState, envVars>>
        /\ CASE ev.type = EvLP     -> HandleLPEvent(t, ev.state)
              [] ev.type = EvMux   -> HandleMuxEvent(t, ev.state)
              [] ev.type = EvLink  -> HandleLinkEvent(t, ev.state)
              [] ev.type = EvPeerLP -> HandlePeerLPEvent(t, ev.state)

(* ========================================================================
   Timer Expiry Actions (Family 3)

   Timers fire non-deterministically when pending. This models the
   real system where timer expiry can happen at any point during
   state transitions.
   ======================================================================== *)

\* Mux probe timer timeout (ActiveActive.cpp:1235-1250)
\* Family 3, MC-5: backoff reaches MAX and never resets
MuxProbeTimeout(t) ==
    /\ timerPending[t][TMuxProbe] = TRUE
    /\ IF muxState[t] \in {MuxUnknown, MuxError, MuxWait}
       THEN \* Still in bad state: double backoff, restart (line 1245)
            /\ muxProbeBackoff' = [muxProbeBackoff EXCEPT ![t] =
                   Min(@ * 2, MAX_BACKOFF)]
            /\ timerPending' = [timerPending EXCEPT ![t] =
                   [@ EXCEPT ![TMuxProbe] = TRUE]]
       ELSE \* State resolved: reset backoff (line 1247)
            /\ muxProbeBackoff' = [muxProbeBackoff EXCEPT ![t] = 1]
            /\ timerPending' = [timerPending EXCEPT ![t] =
                   [@ EXCEPT ![TMuxProbe] = FALSE]]
    /\ UNCHANGED <<subVars, compVars, queueVar, peerVars, envVars, trackVars>>

\* Mux wait timer timeout (ActiveActive.cpp:1276-1290)
\* Fired when mux/xcvrd doesn't respond to switch command
MuxWaitTimeout(t) ==
    /\ timerPending[t][TWait] = TRUE
    /\ timerPending' = [timerPending EXCEPT ![t] = [@ EXCEPT ![TWait] = FALSE]]
    /\ UNCHANGED <<subVars, compVars, queueVar, muxProbeBackoff,
                   peerVars, envVars, trackVars>>

\* Peer mux wait timer timeout (ActiveActive.cpp:1314-1330)
PeerWaitTimeout(t) ==
    /\ timerPending[t][TPeerWait] = TRUE
    /\ timerPending' = [timerPending EXCEPT ![t] = [@ EXCEPT ![TPeerWait] = FALSE]]
    /\ UNCHANGED <<subVars, compVars, queueVar, muxProbeBackoff,
                   peerVars, envVars, trackVars>>

\* Admin forwarding state resync timer (ActiveActive.cpp:464-474)
\* Family 3, MC-12: can cause double probe
ResyncTimeout(t) ==
    /\ timerPending[t][TResync] = TRUE
    \* If not waiting for mux response, probe mux (line 467-470)
    /\ IF switchTarget[t] = NULL
       THEN timerPending' = [timerPending EXCEPT ![t] =
                [@ EXCEPT ![TResync] = FALSE, ![TMuxProbe] = TRUE]]
       ELSE timerPending' = [timerPending EXCEPT ![t] =
                [@ EXCEPT ![TResync] = FALSE]]
    /\ UNCHANGED <<subVars, compVars, queueVar, muxProbeBackoff,
                   peerVars, envVars, trackVars>>

(* ========================================================================
   Environment Actions
   ======================================================================== *)

\* Default route state change (ActiveActive.cpp:1337-1370)
\* Family 4: #292, #279 — route flaps interact with transitions
DefaultRouteChange(t) ==
    \E newDr \in AllDfltRoutes :
        /\ defaultRoute[t] /= newDr
        /\ defaultRoute' = [defaultRoute EXCEPT ![t] = newDr]
        /\ UNCHANGED mode   \* mode is not changed by route notifications
        /\ IF newDr = DrNA /\ mode[t] /= ModeActive
           THEN \* Route NA + not Active mode: switch to Standby
                \* (ActiveActive.cpp:1345-1354)
                \* Family 4, MC-7: Detached mode cannot recover on OK
                /\ DoSwitchMux(t, MuxStandby, TRUE, muxState[t])
                /\ UNCHANGED <<subLpState, subLinkState, lpState, linkState,
                               muxProbeBackoff, peerVars,
                               lastMuxNotification>>
                /\ eventQueue' = eventQueue
           ELSE IF defaultRoute[t] = DrNA /\ newDr /= DrNA
                /\ lpState[t] = LPActive /\ mode[t] = ModeAuto
           THEN \* Recovering from NA with Active prober in Auto mode
                \* (ActiveActive.cpp:1355-1367)
                /\ UNCHANGED <<subVars, compVars, queueVar, timerVars,
                               peerVars, trackVars>>
           ELSE \* Other transitions: no state change
                /\ UNCHANGED <<subVars, compVars, queueVar, timerVars,
                               peerVars, trackVars>>

\* Mode change notification (ActiveActive.cpp:266-293)
ModeChange(t) ==
    \E newMode \in AllModes :
        /\ mode[t] /= newMode
        /\ mode' = [mode EXCEPT ![t] = newMode]
        /\ IF newMode = ModeActive
           THEN \* Force switch to Active (line 274)
                /\ DoSwitchMux(t, MuxActive, TRUE, muxState[t])
                /\ UNCHANGED <<subLpState, subLinkState, lpState, linkState,
                               muxProbeBackoff, peerVars,
                               lastMuxNotification, eventQueue>>
           ELSE IF newMode = ModeStandby
           THEN \* Force switch to Standby (line 276)
                /\ DoSwitchMux(t, MuxStandby, TRUE, muxState[t])
                /\ UNCHANGED <<subLpState, subLinkState, lpState, linkState,
                               muxProbeBackoff, peerVars,
                               lastMuxNotification, eventQueue>>
           ELSE \* Auto/Detached: probe mux state (line 279)
                /\ timerPending' = [timerPending EXCEPT ![t] =
                       [@ EXCEPT ![TMuxProbe] = TRUE]]
                /\ UNCHANGED <<subVars, compVars, queueVar,
                               muxProbeBackoff, peerVars, trackVars>>
        /\ UNCHANGED defaultRoute

\* SoC restart: resets admin forwarding state on NIC
\* Family 5, MC-9: peer state not reset on restart
SoCRestart(t) ==
    /\ peerMuxState' = [peerMuxState EXCEPT ![t] = MuxWait]
    /\ peerLpState'  = [peerLpState  EXCEPT ![t] = LPPeerWait]
    \* Timers may need resync (line 451-462)
    /\ timerPending' = [timerPending EXCEPT ![t] =
           [@ EXCEPT ![TResync] = TRUE]]
    /\ UNCHANGED <<subVars, compVars, queueVar, muxProbeBackoff,
                   envVars, trackVars>>

(* ========================================================================
   Safety Invariants
   ======================================================================== *)

\* Type invariant
TypeOK ==
    /\ subLpState   \in [Tor -> AllLPStates]
    /\ subMuxState  \in [Tor -> AllMuxStates]
    /\ subLinkState \in [Tor -> AllLinkStates]
    /\ lpState   \in [Tor -> AllLPStates]
    /\ muxState  \in [Tor -> AllMuxStates]
    /\ linkState \in [Tor -> AllLinkStates]
    /\ \A t \in Tor : eventQueue[t] \subseteq
           [type: EventTypes, state: AllLPStates \union AllMuxStates \union AllLinkStates]
    /\ timerPending \in [Tor -> [AllTimerTypes -> BOOLEAN]]
    /\ muxProbeBackoff \in [Tor -> 1..MAX_BACKOFF]
    /\ peerMuxState \in [Tor -> AllMuxStates]
    /\ peerLpState  \in [Tor -> PeerLPStates]
    /\ defaultRoute \in [Tor -> AllDfltRoutes]
    /\ mode \in [Tor -> AllModes]
    /\ lastMuxNotification \in [Tor -> AllMuxStates]
    /\ switchTarget \in [Tor -> AllMuxStates \union {NULL}]

\* --- Core Safety ---

\* Family 5: At least one ToR must be Active (or transitioning) for
\* each server link. Exception: both-Standby is OK when no ToR CAN
\* be Active (all have DR=NA or mode forces Standby/Detached).
NoDoubleStandby ==
    LET CanBeActive(t) == /\ mode[t] \in {ModeAuto, ModeActive}
                          /\ defaultRoute[t] /= DrNA
    IN \/ \A t \in Tor : linkState[t] = LinkDown
       \/ \E t \in Tor : muxState[t] \in {MuxActive, MuxWait}
       \/ ~\E t \in Tor : CanBeActive(t)

\* --- Extension Invariants (Bug Family targets) ---

\* Family 2: Every reachable composite state either has a registered
\* handler or is a stable terminal state.
\* Stable terminals: (Active,Active,Up), (Unknown,Standby,Up),
\*                   (LPWait,*,Down), (*,Standby,Down)
NoStuckState ==
    \A t \in Tor :
        eventQueue[t] = {} =>
        LET lp == lpState[t]
            mx == muxState[t]
            lk == linkState[t]
        IN
        \/ HasHandler(lp, mx, lk)
        \/ lp = LPActive  /\ mx = MuxActive  /\ lk = LinkUp
        \/ mx = MuxStandby /\ lk = LinkUp
        \/ lk = LinkDown
        \/ mx = MuxWait  \* waiting for mux response
        \/ \E tm \in AllTimerTypes : timerPending[t][tm]  \* timer will fire

\* Family 3: Backoff factors should not stay at MAX permanently
\* when the underlying state has resolved.
\* (MC-5: mMuxProbeBackoffFactor stays at MAX=128)
BackoffNotStuckAtMax ==
    \A t \in Tor :
        muxProbeBackoff[t] = MAX_BACKOFF =>
        muxState[t] \in {MuxUnknown, MuxError, MuxWait}

\* Family 4, MC-6: DefaultRoute Wait should not enable Active switch
\* (DrWait passes the /= DrNA check in the code)
NoActiveWithDrWait ==
    \A t \in Tor :
        defaultRoute[t] = DrWait =>
        ~(switchTarget[t] = MuxActive)

\* Family 5, MC-8: Peer mux state must be updated when local becomes
\* healthy and peer is unknown
NoPeerStaleWhenHealthy ==
    \A t \in Tor :
        /\ Health(t) = Healthy
        /\ peerLpState[t] = LPPeerUnknown
        /\ mode[t] = ModeAuto
        => peerMuxState[t] = MuxStandby

\* Family 3: No spurious toggle — mux should not switch to Standby
\* when the composite state is healthy and mode allows Active
NoSpuriousToggle ==
    \A t \in Tor :
        /\ lpState[t] = LPActive
        /\ muxState[t] = MuxActive
        /\ linkState[t] = LinkUp
        /\ defaultRoute[t] = DrOK
        /\ mode[t] = ModeAuto
        => switchTarget[t] /= MuxStandby

\* Family 2, MC-2: {Unknown, Error, Up} has no handler in Active-Active
\* System can reach this state and get stuck
UnknownErrorUpReachable ==
    ~(\E t \in Tor :
        /\ lpState[t] = LPUnknown
        /\ muxState[t] = MuxError
        /\ linkState[t] = LinkUp
        /\ eventQueue[t] = {}
        /\ timerPending[t][TMuxProbe] = FALSE)

(* ========================================================================
   Liveness Properties (checked with fairness)
   ======================================================================== *)

\* Family 2,3,4: If link is Up and heartbeats are Active, mux
\* eventually reaches Active (requires fairness on ProcessEvent)
EventuallyActive ==
    \A t \in Tor :
        [](linkState[t] = LinkUp /\ lpState[t] = LPActive
           /\ defaultRoute[t] = DrOK /\ mode[t] = ModeAuto)
        => <>(muxState[t] = MuxActive)

\* Family 3: Backoff eventually resets when state resolves
EventuallyBackoffResets ==
    \A t \in Tor :
        [](muxState[t] = MuxActive) => <>(muxProbeBackoff[t] = 1)

\* Family 4: After default route recovers, mux returns to Active
DefaultRouteRecovery ==
    \A t \in Tor :
        [](defaultRoute[t] = DrOK /\ lpState[t] = LPActive
           /\ linkState[t] = LinkUp /\ mode[t] = ModeAuto)
        => <>(muxState[t] = MuxActive)

(* ========================================================================
   Next State Relation
   ======================================================================== *)

Next ==
    \E t \in Tor :
        \* --- External stimuli ---
        \/ HeartbeatActive(t)
        \/ HeartbeatUnknown(t)
        \/ PeerHeartbeatActive(t)
        \/ PeerHeartbeatUnknown(t)
        \/ MuxNotification(t)
        \/ LinkChange(t)
        \* --- Event processing (Family 1: non-deterministic ordering) ---
        \/ ProcessEvent(t)
        \* --- Timer expiry (Family 3: non-deterministic timing) ---
        \/ MuxProbeTimeout(t)
        \/ MuxWaitTimeout(t)
        \/ PeerWaitTimeout(t)
        \/ ResyncTimeout(t)
        \* --- Environment changes ---
        \/ DefaultRouteChange(t)
        \/ ModeChange(t)
        \* --- Fault injection (Family 5) ---
        \/ SoCRestart(t)

Spec == Init /\ [][Next]_vars

FairSpec == Spec /\ WF_vars(Next)

====
