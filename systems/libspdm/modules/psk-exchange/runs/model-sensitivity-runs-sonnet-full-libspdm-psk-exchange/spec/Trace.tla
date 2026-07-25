-------------------------- MODULE Trace --------------------------
(*
  Trace validation spec for libspdm PSK exchange.

  Drives TLC through an NDJSON trace recorded from the real implementation,
  verifying that the base spec can reproduce every observed state transition.

  System category: A (Distributed/Message-Passing) — single linear trace.

  Trace format: one JSON object per line, each with field "event" naming the
  spec action, plus fields defined in instrumentation-spec.md.
*)

EXTENDS base, Integers, Sequences, TLC, IOUtils, Json

-----------------------------------------------------------------------------
\* TRACE LOADING
-----------------------------------------------------------------------------

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == SelectSeq(ndJsonDeserialize(JsonFile),
                       LAMBDA line: "event" \in DOMAIN line)

-----------------------------------------------------------------------------
\* CURSOR
-----------------------------------------------------------------------------

VARIABLE l   \* current trace position (1-indexed)

logline == TraceLog[l]

-----------------------------------------------------------------------------
\* EVENT PREDICATES
-----------------------------------------------------------------------------

IsEvent(name)   == logline.event = name
IsReqEvent(name) == logline.event = name /\ logline.role = "requester"
IsRspEvent(name) == logline.event = name /\ logline.role = "responder"

-----------------------------------------------------------------------------
\* JSON STRING -> TLA+ VALUE MAPPING
-----------------------------------------------------------------------------

(*
  Version constants (V_NONE, V_VALID, V_ALT) are TLC typed model values.
  JSON deserializes them as plain strings.  Map before comparing.
*)
JsonToVersion(s) ==
    IF s = "V_NONE"  THEN V_NONE
    ELSE IF s = "V_VALID" THEN V_VALID
    ELSE V_ALT

-----------------------------------------------------------------------------
\* POST-STATE VALIDATION
-----------------------------------------------------------------------------

(*
  ValidatePostState: verify spec state matches captured trace fields after action.
  Called at end of each action wrapper.
  Fields captured per instrumentation-spec.md.
  session_state fields are plain strings in both spec and JSON (no mapping needed).
  session_version fields require JsonToVersion mapping (typed model values).
*)

ValidatePostStateReq ==
    /\ req_state.session_state = logline.session_state
    /\ req_state.session_version = JsonToVersion(logline.session_version)
    /\ req_state.hmac_verified = logline.hmac_verified

ValidatePostStateRsp ==
    /\ rsp_state.session_state = logline.session_state
    /\ rsp_state.session_version = JsonToVersion(logline.session_version)

\* Version negotiation fields (Family 1 + 2)
ValidateOpaqueFields ==
    /\ rsp_has_opaque = logline.has_opaque
    /\ rsp_negotiated_version = JsonToVersion(logline.negotiated_version)

-----------------------------------------------------------------------------
\* ACTION WRAPPERS
-----------------------------------------------------------------------------

\* --- SendPskExchange ---
TraceSendPskExchange ==
    /\ IsReqEvent("SendPskExchange")
    /\ SendPskExchange(logline.has_opaque)
    /\ req_has_opaque' = logline.has_opaque
    /\ ValidatePostStateReq
    /\ l' = l + 1
    /\ UNCHANGED <<rsp_state, rsp_has_opaque, opaque_call_results,
                   rsp_negotiated_version, req_negotiated_version>>

\* --- GetResponsePskExchange ---
TraceGetResponsePskExchange ==
    /\ IsRspEvent("GetResponsePskExchange")
    /\ GetResponsePskExchange
    /\ ValidatePostStateRsp
    /\ ValidateOpaqueFields
    /\ l' = l + 1
    /\ UNCHANGED <<req_state, req_has_opaque, req_negotiated_version>>

\* --- RecvPskExchangeRsp ---
TraceRecvPskExchangeRsp ==
    /\ IsReqEvent("RecvPskExchangeRsp")
    /\ RecvPskExchangeRsp
    /\ req_negotiated_version' = JsonToVersion(logline.negotiated_version)
    /\ ValidatePostStateReq
    /\ l' = l + 1
    /\ UNCHANGED <<rsp_state, rsp_has_opaque, opaque_call_results,
                   rsp_negotiated_version>>

\* --- SendPskFinish ---
TraceSendPskFinish ==
    /\ IsReqEvent("SendPskFinish")
    /\ SendPskFinish
    /\ l' = l + 1
    /\ UNCHANGED <<req_state, rsp_state, req_has_opaque, rsp_has_opaque,
                   opaque_call_results, rsp_negotiated_version, req_negotiated_version>>

\* --- GetResponsePskFinish ---
TraceGetResponsePskFinish ==
    /\ IsRspEvent("GetResponsePskFinish")
    /\ GetResponsePskFinish
    /\ ValidatePostStateRsp
    /\ l' = l + 1
    /\ UNCHANGED <<req_state, req_has_opaque, rsp_has_opaque,
                   opaque_call_results, rsp_negotiated_version, req_negotiated_version>>

\* --- RecvPskFinishRsp ---
TraceRecvPskFinishRsp ==
    /\ IsReqEvent("RecvPskFinishRsp")
    /\ RecvPskFinishRsp
    /\ ValidatePostStateReq
    /\ l' = l + 1
    /\ UNCHANGED <<rsp_state, req_has_opaque, rsp_has_opaque,
                   opaque_call_results, rsp_negotiated_version, req_negotiated_version>>

-----------------------------------------------------------------------------
\* SILENT ACTIONS
\* Handle impl state changes that produce no trace event.
\* Tightly constrained to prevent state-space explosion.
-----------------------------------------------------------------------------

(*
  SilentDropMessage: message was dropped inside the implementation (e.g., timeout)
  but no trace event was emitted.  Only fire when the NEXT trace event cannot
  match any in-flight message — i.e., the message bag must be non-empty and the
  cursor is not past the end.
*)
SilentDropMessage ==
    /\ l <= Len(TraceLog)
    /\ BagCardinality(msgs) > 0
    \* Only allow drop if next event is a fresh Send (meaning prior message was lost)
    /\ logline.event \in {"SendPskExchange", "SendPskFinish"}
    /\ DropMessage
    /\ UNCHANGED l

-----------------------------------------------------------------------------
\* TRACE INIT
-----------------------------------------------------------------------------

TraceInit ==
    /\ Init
    /\ l = 1

-----------------------------------------------------------------------------
\* TRACE NEXT
-----------------------------------------------------------------------------

TraceNext ==
    /\ l <= Len(TraceLog)
    /\ \/ TraceSendPskExchange
       \/ TraceGetResponsePskExchange
       \/ TraceRecvPskExchangeRsp
       \/ TraceSendPskFinish
       \/ TraceGetResponsePskFinish
       \/ TraceRecvPskFinishRsp
       \/ SilentDropMessage

TraceSpec == TraceInit /\ [][TraceNext]_<<allVars, l>> /\ WF_<<allVars, l>>(TraceNext)

-----------------------------------------------------------------------------
\* COMPLETION PROPERTY
-----------------------------------------------------------------------------

(*
  TraceMatched: eventually the entire trace is consumed.
  Must be listed under PROPERTIES in Trace.cfg.
  Without this, TLC reports "no errors" even when l never advances.
*)
TraceMatched == <>(l > Len(TraceLog))

=================================================================
