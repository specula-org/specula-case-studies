---- MODULE Trace ----
\* Trace validation spec for libspdm session lifecycle.
\* Category A: single linear trace, cursor variable l.
\* Drives TLC through recorded NDJSON execution traces from libspdm.

EXTENDS base, Naturals, Sequences, TLC, IOUtils, Json

\* ---------------------------------------------------------------------------
\* Trace loading
\* ---------------------------------------------------------------------------
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* ---------------------------------------------------------------------------
\* Cursor variable
\* ---------------------------------------------------------------------------
VARIABLE l   \* index into TraceLog; l=1 means first event not yet consumed

TraceVars == <<vars, l>>

logline == TraceLog[l]

\* ---------------------------------------------------------------------------
\* Event predicate helpers
\* ---------------------------------------------------------------------------
IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

\* ---------------------------------------------------------------------------
\* Map trace session_state strings to spec constants
\* ---------------------------------------------------------------------------
ToSessionState(s) ==
    IF s = "ESTABLISHED" THEN ESTABLISHED ELSE NOT_STARTED

ToKeyOp(s) ==
    CASE s = "update_key"      -> KU_UPDATE_KEY
      [] s = "update_all_keys" -> KU_UPDATE_ALL
      [] OTHER                 -> KU_NONE

ToKuState(s) ==
    CASE s = "update_sent"  -> REQ_KU_UPDATE_SENT
      [] s = "verify_sent"  -> REQ_KU_VERIFY_SENT
      [] OTHER               -> REQ_KU_IDLE

\* ---------------------------------------------------------------------------
\* Post-state validation helper
\* Each action wrapper calls this with the logline's state snapshot.
\* Fields match the event schema in instrumentation-spec.md.
\* ---------------------------------------------------------------------------
ValidatePostState(snap) ==
    /\ req_session_state'  = ToSessionState(snap.req_session_state)
    /\ rsp_session_state'  = ToSessionState(snap.rsp_session_state)
    /\ req_ku_state'       = ToKuState(snap.req_ku_state)
    /\ rsp_last_key_op'    = ToKeyOp(snap.rsp_last_key_op)
    /\ req_tx_gen'         = snap.req_tx_gen
    /\ rsp_rx_gen'         = snap.rsp_rx_gen
    /\ rsp_rx_backup_valid' = snap.rsp_rx_backup_valid

\* ---------------------------------------------------------------------------
\* Trace Init — starts from ESTABLISHED session (same as base Init)
\* ---------------------------------------------------------------------------
TraceInit ==
    /\ Init
    /\ l = 1

\* ---------------------------------------------------------------------------
\* Action wrappers
\* Each wrapper: match event → call base action → validate post-state → advance l
\* ---------------------------------------------------------------------------

TraceReqSendUpdateKey ==
    /\ IsEvent("req_send_update_key")
    /\ ReqSendUpdateKey
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceReqSendUpdateAllKeys ==
    /\ IsEvent("req_send_update_all_keys")
    /\ ReqSendUpdateAllKeys
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceRspRecvUpdateKey ==
    /\ IsEvent("rsp_recv_update_key")
    /\ RspRecvUpdateKey
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceRspRecvUpdateAllKeys ==
    /\ IsEvent("rsp_recv_update_all_keys")
    /\ RspRecvUpdateAllKeys
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceReqRecvKeyUpdateAck ==
    /\ IsEvent("req_recv_key_update_ack")
    /\ ReqRecvKeyUpdateAck
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceRspRecvVerifyNewKey ==
    /\ IsEvent("rsp_recv_verify_new_key")
    /\ RspRecvVerifyNewKey
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceReqRecvVerifyAck ==
    /\ IsEvent("req_recv_verify_ack")
    /\ ReqRecvVerifyAck
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceDecodeWithBackupKey ==
    /\ IsEvent("rsp_decode_with_backup_key")
    /\ DecodeWithBackupKey
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceReqSendEndSession ==
    /\ IsEvent("req_send_end_session")
    /\ ReqSendEndSession
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceRspRecvEndSession ==
    /\ IsEvent("rsp_recv_end_session")
    /\ RspRecvEndSession
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceRspEncodeEndSessionAckSuccess ==
    /\ IsEvent("rsp_encode_end_session_ack_success")
    /\ RspEncodeEndSessionAckSuccess
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceReqRecvEndSessionAck ==
    /\ IsEvent("req_recv_end_session_ack")
    /\ ReqRecvEndSessionAck
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceReqSendHeartbeat ==
    /\ IsEvent("req_send_heartbeat")
    /\ ReqSendHeartbeat
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceRspRecvHeartbeat ==
    /\ IsEvent("rsp_recv_heartbeat")
    /\ RspRecvHeartbeat
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

TraceReqRecvHeartbeatAck ==
    /\ IsEvent("req_recv_heartbeat_ack")
    /\ ReqRecvHeartbeatAck
    /\ ValidatePostState(logline.state)
    /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* Silent actions
\* Handle spec state changes that have no corresponding trace event.
\* Tightly constrained to prevent state space explosion.
\* ---------------------------------------------------------------------------

\* WatchdogExpiry and IntegratorTerminatesSession are platform-internal and
\* may not be observable in traces. Allow them silently when preconditions match
\* and the next trace event requires them (e.g., rsp_session_state NOT_STARTED
\* without a prior END_SESSION_ACK event).

SilentWatchdogExpiry ==
    /\ l <= Len(TraceLog)
    /\ watchdog_active = TRUE
    /\ watchdog_expired = FALSE
    \* Only fire silently if the next event's state shows rsp terminated without ACK.
    \* Do NOT fire if the current event is rsp_encode_end_session_ack_success, which
    \* will itself transition rsp_session_state to NOT_STARTED.
    /\ logline.event /= "rsp_encode_end_session_ack_success"
    /\ logline.state.rsp_session_state = "NOT_STARTED"
    /\ logline.state.req_session_state = "ESTABLISHED"
    /\ WatchdogExpiry
    /\ UNCHANGED l

SilentIntegratorTerminatesSession ==
    /\ l <= Len(TraceLog)
    /\ watchdog_expired = TRUE
    /\ rsp_session_state = ESTABLISHED
    /\ IntegratorTerminatesSession
    /\ UNCHANGED l

\* RspEncodeEndSessionAckFail is silent: encoding failure produces no observable
\* trace event but advances responder-side state.
SilentRspEncodeEndSessionAckFail ==
    /\ l <= Len(TraceLog)
    /\ rsp_session_state = ESTABLISHED
    /\ end_session_sent = TRUE
    /\ end_session_ack_encoded = FALSE
    /\ RspEncodeEndSessionAckFail
    /\ UNCHANGED l

\* ---------------------------------------------------------------------------
\* TraceNext
\* ---------------------------------------------------------------------------
TraceNext ==
    \/ TraceReqSendUpdateKey
    \/ TraceReqSendUpdateAllKeys
    \/ TraceRspRecvUpdateKey
    \/ TraceRspRecvUpdateAllKeys
    \/ TraceReqRecvKeyUpdateAck
    \/ TraceRspRecvVerifyNewKey
    \/ TraceReqRecvVerifyAck
    \/ TraceDecodeWithBackupKey
    \/ TraceReqSendEndSession
    \/ TraceRspRecvEndSession
    \/ TraceRspEncodeEndSessionAckSuccess
    \/ TraceReqRecvEndSessionAck
    \/ TraceReqSendHeartbeat
    \/ TraceRspRecvHeartbeat
    \/ TraceReqRecvHeartbeatAck
    \/ SilentWatchdogExpiry
    \/ SilentIntegratorTerminatesSession
    \* Stuttering: stop once trace fully consumed
    \/ (l > Len(TraceLog) /\ UNCHANGED TraceVars)

TraceSpec == TraceInit /\ [][TraceNext]_TraceVars /\ WF_TraceVars(TraceNext)

\* ---------------------------------------------------------------------------
\* Completion property: entire trace must be consumed
\* ---------------------------------------------------------------------------
TraceMatched == <>(l > Len(TraceLog))

====
