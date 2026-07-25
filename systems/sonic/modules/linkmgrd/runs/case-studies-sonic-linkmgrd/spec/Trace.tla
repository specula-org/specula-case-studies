---- MODULE Trace ----
(* ========================================================================
   Trace Validation Spec for sonic-linkmgrd Active-Active

   Replays implementation traces against the base spec to verify that
   every observed state transition is consistent with the spec.

   Category A: Single-file linear trace with cursor variable l.
   ======================================================================== *)
EXTENDS base, Sequences, TLC, IOUtils, Json

(* ========================================================================
   Trace Loading
   ======================================================================== *)

\* Trace file location: sibling traces/ directory
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load and deserialize the trace
RawTrace == ndJsonDeserialize(JsonFile)

\* Filter to linkmgrd events only
TraceLog == SelectSeq(RawTrace, LAMBDA e : e.tag = "linkmgrd")

(* ========================================================================
   Trace Cursor
   ======================================================================== *)

VARIABLES
    l    \* Cursor into TraceLog, starts at 1

traceVars == <<vars, l>>

logline == TraceLog[l]

(* ========================================================================
   Role/Type Mapping: Implementation Strings -> Spec Constants
   ======================================================================== *)

MapLPState(s) ==
    CASE s = "active"       -> LPActive
      [] s = "unknown"      -> LPUnknown
      [] s = "wait"         -> LPWait
      [] s = "peer_active"  -> LPPeerActive
      [] s = "peer_unknown" -> LPPeerUnknown
      [] s = "peer_wait"    -> LPPeerWait

MapMuxState(s) ==
    CASE s = "active"  -> MuxActive
      [] s = "standby" -> MuxStandby
      [] s = "unknown" -> MuxUnknown
      [] s = "error"   -> MuxError
      [] s = "wait"    -> MuxWait

MapLinkState(s) ==
    CASE s = "up"   -> LinkUp
      [] s = "down" -> LinkDown

MapDefaultRoute(s) ==
    CASE s = "ok"   -> DrOK
      [] s = "na"   -> DrNA
      [] s = "wait" -> DrWait

MapMode(s) ==
    CASE s = "auto"     -> ModeAuto
      [] s = "active"   -> ModeActive
      [] s = "standby"  -> ModeStandby
      [] s = "detached" -> ModeDetached

(* ========================================================================
   Server/Tor Extraction
   ======================================================================== *)

\* Derive Tor set from trace
TraceTors == {TraceLog[i].tor : i \in 1..Len(TraceLog)}

(* ========================================================================
   Event Predicates
   ======================================================================== *)

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

IsTorEvent(name, t) ==
    /\ IsEvent(name)
    /\ logline.tor = t

(* ========================================================================
   Post-State Validation

   Validates that the spec state matches the trace after each action.
   Each action wrapper validates the key fields that action modifies.
   ======================================================================== *)

\* Validate composite state for a given ToR
ValidateCompositeState(t) ==
    /\ ("lp_state" \in DOMAIN logline.state) =>
        lpState'[t] = MapLPState(logline.state.lp_state)
    /\ ("mux_state" \in DOMAIN logline.state) =>
        muxState'[t] = MapMuxState(logline.state.mux_state)
    /\ ("link_state" \in DOMAIN logline.state) =>
        linkState'[t] = MapLinkState(logline.state.link_state)

\* Validate sub-SM state
ValidateSubState(t) ==
    /\ ("sub_lp_state" \in DOMAIN logline.state) =>
        subLpState'[t] = MapLPState(logline.state.sub_lp_state)
    /\ ("sub_mux_state" \in DOMAIN logline.state) =>
        subMuxState'[t] = MapMuxState(logline.state.sub_mux_state)

\* Validate peer state
ValidatePeerState(t) ==
    /\ ("peer_mux_state" \in DOMAIN logline.state) =>
        peerMuxState'[t] = MapMuxState(logline.state.peer_mux_state)
    /\ ("peer_lp_state" \in DOMAIN logline.state) =>
        peerLpState'[t] = MapLPState(logline.state.peer_lp_state)

\* Validate timer state
ValidateTimerState(t) ==
    /\ ("mux_probe_backoff" \in DOMAIN logline.state) =>
        muxProbeBackoff'[t] = logline.state.mux_probe_backoff

\* Validate environment state
ValidateEnvState(t) ==
    /\ ("default_route" \in DOMAIN logline.state) =>
        defaultRoute'[t] = MapDefaultRoute(logline.state.default_route)
    /\ ("mode" \in DOMAIN logline.state) =>
        mode'[t] = MapMode(logline.state.mode)

\* Validate tracking state
ValidateTrackState(t) ==
    /\ ("last_mux_notification" \in DOMAIN logline.state) =>
        lastMuxNotification'[t] = MapMuxState(logline.state.last_mux_notification)

(* ========================================================================
   Action Wrappers

   Each wrapper: match event -> call base action -> validate -> advance l
   ======================================================================== *)

\* --- External Stimulus Wrappers ---

TraceHeartbeatActive ==
    \E t \in Tor :
        /\ IsTorEvent("HeartbeatActive", t)
        /\ HeartbeatActive(t)
        /\ ValidateSubState(t)
        /\ l' = l + 1

TraceHeartbeatUnknown ==
    \E t \in Tor :
        /\ IsTorEvent("HeartbeatUnknown", t)
        /\ HeartbeatUnknown(t)
        /\ ValidateSubState(t)
        /\ l' = l + 1

TracePeerHeartbeatActive ==
    \E t \in Tor :
        /\ IsTorEvent("PeerHeartbeatActive", t)
        /\ PeerHeartbeatActive(t)
        /\ ValidateSubState(t)
        /\ l' = l + 1

TracePeerHeartbeatUnknown ==
    \E t \in Tor :
        /\ IsTorEvent("PeerHeartbeatUnknown", t)
        /\ PeerHeartbeatUnknown(t)
        /\ ValidateSubState(t)
        /\ l' = l + 1

TraceMuxNotification ==
    \E t \in Tor :
        /\ IsTorEvent("MuxNotification", t)
        /\ MuxNotification(t)
        /\ ValidateSubState(t)
        /\ ValidateTrackState(t)
        /\ l' = l + 1

TraceLinkChange ==
    \E t \in Tor :
        /\ IsTorEvent("LinkChange", t)
        /\ LinkChange(t)
        /\ ValidateSubState(t)
        /\ l' = l + 1

\* --- Event Processing Wrapper ---

TraceProcessEvent ==
    \E t \in Tor :
        /\ IsTorEvent("ProcessEvent", t)
        /\ ProcessEvent(t)
        /\ ValidateCompositeState(t)
        /\ ValidatePeerState(t)
        /\ ValidateTimerState(t)
        /\ l' = l + 1

\* --- Timer Expiry Wrappers ---

TraceMuxProbeTimeout ==
    \E t \in Tor :
        /\ IsTorEvent("MuxProbeTimeout", t)
        /\ MuxProbeTimeout(t)
        /\ ValidateTimerState(t)
        /\ l' = l + 1

TraceMuxWaitTimeout ==
    \E t \in Tor :
        /\ IsTorEvent("MuxWaitTimeout", t)
        /\ MuxWaitTimeout(t)
        /\ l' = l + 1

TracePeerWaitTimeout ==
    \E t \in Tor :
        /\ IsTorEvent("PeerWaitTimeout", t)
        /\ PeerWaitTimeout(t)
        /\ l' = l + 1

TraceResyncTimeout ==
    \E t \in Tor :
        /\ IsTorEvent("ResyncTimeout", t)
        /\ ResyncTimeout(t)
        /\ l' = l + 1

\* --- Environment Action Wrappers ---

TraceDefaultRouteChange ==
    \E t \in Tor :
        /\ IsTorEvent("DefaultRouteChange", t)
        /\ DefaultRouteChange(t)
        /\ ValidateEnvState(t)
        /\ l' = l + 1

TraceModeChange ==
    \E t \in Tor :
        /\ IsTorEvent("ModeChange", t)
        /\ ModeChange(t)
        /\ ValidateEnvState(t)
        /\ l' = l + 1

\* --- Fault Injection Wrapper ---

TraceSoCRestart ==
    \E t \in Tor :
        /\ IsTorEvent("SoCRestart", t)
        /\ SoCRestart(t)
        /\ ValidatePeerState(t)
        /\ l' = l + 1

(* ========================================================================
   Silent Actions

   Handle implementation state changes that don't have trace events.
   TIGHTLY CONSTRAINED to prevent state space explosion.
   ======================================================================== *)

\* Silent ProcessEvent: disabled. Events accumulate in the queue
\* and are consumed by explicitly traced ProcessEvent entries.
\* The old version fired between consecutive stimuli and caused
\* premature state changes.
\* SilentProcessEvent == FALSE /\ UNCHANGED traceVars

\* SilentStimulus removed — missing stimulus events are now injected
\* by the trace preprocessor (preprocess.py) instead.

\* Silent timer expiry: timers can fire between traced events.
\* Constrained: only fires for pending timers when next event
\* is not the corresponding timer event.
SilentTimerExpiry ==
    /\ l <= Len(TraceLog)
    /\ \E t \in Tor :
        \/ /\ logline.event /= "MuxProbeTimeout"
           /\ MuxProbeTimeout(t)
        \/ /\ logline.event /= "MuxWaitTimeout"
           /\ MuxWaitTimeout(t)
        \/ /\ logline.event /= "PeerWaitTimeout"
           /\ PeerWaitTimeout(t)
        \/ /\ logline.event /= "ResyncTimeout"
           /\ ResyncTimeout(t)
    /\ UNCHANGED l

(* ========================================================================
   Trace Init
   ======================================================================== *)

TraceInit ==
    /\ Init
    /\ l = 1

(* ========================================================================
   Trace Next
   ======================================================================== *)

TraceNext ==
    \/ TraceHeartbeatActive
    \/ TraceHeartbeatUnknown
    \/ TracePeerHeartbeatActive
    \/ TracePeerHeartbeatUnknown
    \/ TraceMuxNotification
    \/ TraceLinkChange
    \/ TraceProcessEvent
    \/ TraceMuxProbeTimeout
    \/ TraceMuxWaitTimeout
    \/ TracePeerWaitTimeout
    \/ TraceResyncTimeout
    \/ TraceDefaultRouteChange
    \/ TraceModeChange
    \/ TraceSoCRestart
    \* --- Silent actions ---
    \/ SilentTimerExpiry
    \* --- Stuttering after trace consumed ---
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED traceVars

(* ========================================================================
   Trace Properties
   ======================================================================== *)

\* The entire trace must be consumed
TraceMatched == <>(l > Len(TraceLog))

TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceNext)

====
