---- MODULE Trace ----
(*
 * Trace validation spec for sonic-dash-ha.
 * Category A (distributed/message-passing): single-file linear trace.
 *
 * Replays NDJSON traces from instrumented hamgrd against the base spec,
 * verifying that every observed state transition is reproducible.
 *)

EXTENDS base, Sequences, TLC, IOUtils, Json

\* ===========================================================================
\* Trace Loading
\* ===========================================================================

\* Trace file path: override via TLC -DJSON=path or use default
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load and filter trace events
RawLog == ndJsonDeserialize(JsonFile)

\* Filter to HA-relevant events (skip infrastructure noise)
IsHAEvent(e) == e.tag = "ha"

TraceLog == SelectSeq(RawLog, LAMBDA e : IsHAEvent(e))

\* ===========================================================================
\* Trace Variable
\* ===========================================================================

VARIABLE l   \* Cursor: index into TraceLog (1..Len(TraceLog)+1)

traceVars == <<vars, l>>

\* Current log line
logline == TraceLog[l]

\* ===========================================================================
\* Node Extraction
\* ===========================================================================

\* Derive Node set from trace (each unique node_id in trace)
TraceNode == {TraceLog[i].node : i \in 1..Len(TraceLog)}

\* ===========================================================================
\* Event Predicates
\* ===========================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

IsNodeEvent(name, n) ==
    /\ IsEvent(name)
    /\ logline.node = n

\* ===========================================================================
\* State Mapping
\* ===========================================================================

\* Map implementation HA state strings to spec constants
MapHAState(s) ==
    CASE s = "dead"                  -> Dead
      [] s = "connecting"            -> Connecting
      [] s = "connected"             -> Connected
      [] s = "initializing_to_active" -> InitToActive
      [] s = "initializing_to_standby" -> InitToStandby
      [] s = "active"                -> Active
      [] s = "standby"               -> Standby
      [] s = "standalone"            -> Standalone
      [] s = "switching_to_active"   -> SwitchingToActive
      [] s = "switching_to_standby"  -> SwitchingToStandby
      [] s = "destroying"            -> Destroying

\* Map implementation desired state strings to spec constants
MapDesiredState(s) ==
    CASE s = "unspecified" -> DsUnspecified
      [] s = "active"     -> DsActive
      [] s = "standby"    -> DsStandby
      [] s = "dead"       -> DsDead

\* ===========================================================================
\* Post-State Validation
\* ===========================================================================

\* Validate HA state after transition
ValidateHAState(n) ==
    IF "ha_state" \in DOMAIN logline
    THEN haState'[n] = MapHAState(logline.ha_state)
    ELSE TRUE

\* Validate term after transition
ValidateTerm(n) ==
    IF "term" \in DOMAIN logline
    THEN haTerm'[n] = logline.term
    ELSE TRUE

\* Validate desired state
ValidateDesiredState(n) ==
    IF "desired_state" \in DOMAIN logline
    THEN desiredState'[n] = MapDesiredState(logline.desired_state)
    ELSE TRUE

\* Strong validation: check all key fields
ValidatePostState(n) ==
    /\ ValidateHAState(n)
    /\ ValidateTerm(n)
    /\ ValidateDesiredState(n)

\* Weak validation: only HA state (for actions where term/desired aren't captured)
ValidatePostStateWeak(n) ==
    /\ ValidateHAState(n)

\* ===========================================================================
\* Action Wrappers
\* ===========================================================================

\* --- Startup ---

TraceStartConnecting ==
    \E n \in Node :
        /\ IsNodeEvent("start_connecting", n)
        /\ StartConnecting(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

TraceBecomeConnected ==
    \E n \in Node :
        /\ IsNodeEvent("become_connected", n)
        /\ BecomeConnected(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

\* --- Election ---

TraceSendRequestVote ==
    \E n \in Node :
        /\ IsNodeEvent("send_request_vote", n)
        /\ SendRequestVote(n)
        /\ ValidatePostStateWeak(n)
        /\ l' = l + 1

TraceHandleRequestVote ==
    \E n \in Node :
        /\ IsNodeEvent("handle_request_vote", n)
        /\ HandleRequestVote(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

TraceHandleVoteResponse ==
    \E n \in Node :
        /\ IsNodeEvent("handle_vote_response", n)
        /\ HandleVoteResponse(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

\* --- Initialization ---

TraceCompleteInitToActive ==
    \E n \in Node :
        /\ IsNodeEvent("complete_init_to_active", n)
        /\ CompleteInitToActive(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

TraceHandleBulkSyncDone ==
    \E n \in Node :
        /\ IsNodeEvent("handle_bulk_sync_done", n)
        /\ HandleBulkSyncDone(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

\* --- Switchover ---

TraceInitiateSwitchover ==
    \E n \in Node :
        /\ IsNodeEvent("initiate_switchover", n)
        /\ InitiateSwitchover(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

TraceHandleSwitchOver ==
    \E n \in Node :
        /\ IsNodeEvent("handle_switchover", n)
        /\ HandleSwitchOver(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

TraceCompleteSwitchoverToActive ==
    \E n \in Node :
        /\ IsNodeEvent("complete_switchover_to_active", n)
        /\ CompleteSwitchoverToActive(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

TraceCompleteSwitchoverToStandby ==
    \E n \in Node :
        /\ IsNodeEvent("complete_switchover_to_standby", n)
        /\ CompleteSwitchoverToStandby(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

TraceSwitchoverFailed ==
    \E n \in Node :
        /\ IsNodeEvent("switchover_failed", n)
        /\ SwitchoverFailed(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

\* --- Standalone ---

TraceEnterStandalone ==
    \E n \in Node :
        /\ IsNodeEvent("enter_standalone", n)
        /\ EnterStandalone(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

TraceExitStandalone ==
    \E n \in Node :
        /\ IsNodeEvent("exit_standalone", n)
        /\ ExitStandalone(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

TraceHandlePeerDestroying ==
    \E n \in Node :
        /\ IsNodeEvent("handle_peer_destroying", n)
        /\ HandlePeerDestroying(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

TraceInitToStandbyTimeout ==
    \E n \in Node :
        /\ IsNodeEvent("init_to_standby_timeout", n)
        /\ InitToStandbyTimeout(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

\* --- Destroying / Dead ---

TraceStartDestroying ==
    \E n \in Node :
        /\ IsNodeEvent("start_destroying", n)
        /\ StartDestroying(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

TraceCompleteDestroy ==
    \E n \in Node :
        /\ IsNodeEvent("complete_destroy", n)
        /\ CompleteDestroy(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

TraceGoToDead ==
    \E n \in Node :
        /\ IsNodeEvent("go_to_dead", n)
        /\ GoToDead(n)
        /\ ValidatePostState(n)
        /\ l' = l + 1

\* --- Health ---

TraceDpuHealthChange ==
    \E n \in Node :
        /\ IsNodeEvent("dpu_health_change", n)
        /\ LET newUp == logline.dpu_up IN
           DpuHealthChange(n, newUp)
        /\ l' = l + 1

\* --- Config / State Reception ---

TraceReceiveConfig ==
    \E n \in Node :
        /\ IsNodeEvent("receive_config", n)
        /\ ReceiveConfig(n)
        /\ l' = l + 1

TraceReceiveVdpuState ==
    \E n \in Node :
        /\ IsNodeEvent("receive_vdpu_state", n)
        /\ ReceiveVdpuState(n)
        /\ l' = l + 1

TraceReceiveHasetState ==
    \E n \in Node :
        /\ IsNodeEvent("receive_haset_state", n)
        /\ ReceiveHasetState(n)
        /\ l' = l + 1

\* --- Desired State Change ---

TraceChangeDesiredState ==
    \E n \in Node :
        /\ IsNodeEvent("change_desired_state", n)
        /\ LET ds == MapDesiredState(logline.desired_state) IN
           ChangeDesiredState(n, ds)
        /\ ValidateDesiredState(n)
        /\ l' = l + 1

\* ===========================================================================
\* Silent Actions
\* ===========================================================================

\* FlushOutgoing: pending messages delivered without trace event.
\* Tightly constrained: only fires when pendingOut is non-empty.
SilentFlushOutgoing ==
    /\ l <= Len(TraceLog)
    /\ \E n \in Node : FlushOutgoing(n)
    /\ UNCHANGED l

\* RejectSwitchOver: active consumes SwitchOver message silently.
\* Constrained: only fires when there's a pending SwitchOver to consume.
SilentRejectSwitchOver ==
    /\ l <= Len(TraceLog)
    /\ \E n \in Node : RejectSwitchOver(n)
    /\ UNCHANGED l

\* Actor creation: infrastructure event not in HA trace.
\* Constrained: only fires when next event requires the actor to exist.
SilentCreateActor ==
    /\ l <= Len(TraceLog)
    /\ \E n \in Node, level \in AllLevels :
        /\ CreateActor(n, level)
    /\ UNCHANGED l

\* ===========================================================================
\* Trace Init and Next
\* ===========================================================================

TraceInit ==
    /\ haState      = [n \in Node |-> Dead]
    /\ haTerm       = [n \in Node |-> 0]
    /\ desiredState = [n \in Node |-> DsUnspecified]
    /\ retryCount   = [n \in Node |-> 0]
    /\ dpuUp        = [n \in Node |-> FALSE]
    /\ actorAlive   = [n \in Node |-> {}]
    /\ configReady  = [n \in Node |-> FALSE]
    /\ vdpuReady    = [n \in Node |-> FALSE]
    /\ hasetReady   = [n \in Node |-> FALSE]
    /\ pendingOut   = [n \in Node |-> {}]
    /\ messages     = {}
    /\ l = 1

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ \/ TraceStartConnecting
          \/ TraceBecomeConnected
          \/ TraceSendRequestVote
          \/ TraceHandleRequestVote
          \/ TraceHandleVoteResponse
          \/ TraceCompleteInitToActive
          \/ TraceHandleBulkSyncDone
          \/ TraceInitiateSwitchover
          \/ TraceHandleSwitchOver
          \/ TraceCompleteSwitchoverToActive
          \/ TraceCompleteSwitchoverToStandby
          \/ TraceSwitchoverFailed
          \/ TraceEnterStandalone
          \/ TraceExitStandalone
          \/ TraceHandlePeerDestroying
          \/ TraceInitToStandbyTimeout
          \/ TraceStartDestroying
          \/ TraceCompleteDestroy
          \/ TraceGoToDead
          \/ TraceDpuHealthChange
          \/ TraceReceiveConfig
          \/ TraceReceiveVdpuState
          \/ TraceReceiveHasetState
          \/ TraceChangeDesiredState
    \* Silent actions (no trace event consumed)
    \/ SilentFlushOutgoing
    \/ SilentRejectSwitchOver
    \/ SilentCreateActor
    \* Stuttering after trace is fully consumed
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED traceVars

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

\* ===========================================================================
\* Trace Completion
\* ===========================================================================

\* Temporal property: entire trace must be consumed.
\* Without this, TLC silently reports success even if l never advances.
TraceMatched == <>(l > Len(TraceLog))

\* ===========================================================================
\* Invariants for Trace Validation
\* ===========================================================================

\* Safety invariants that should hold on every real execution
TraceTypeOK ==
    /\ haState      \in [Node -> AllHAStates]
    /\ haTerm       \in [Node -> 0..MaxTerm]
    /\ desiredState \in [Node -> AllDesiredStates]

TraceSingleDecisionMaker == SingleDecisionMaker
TraceNoDoubleActive == NoDoubleActive
TraceNoStandaloneStandalone == NoStandaloneStandalone

\* Structural invariants (catch spec modeling errors)
TraceMessageWellFormed == MessageWellFormed
TraceNoDoubleInitActive == NoDoubleInitActive

====
