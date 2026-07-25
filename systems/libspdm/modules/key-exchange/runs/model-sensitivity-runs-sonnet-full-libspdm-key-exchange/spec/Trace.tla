---- MODULE Trace ----
(***************************************************************************)
(* Trace validation spec for SpdmKeyExchange.                              *)
(* Category A (Distributed/Message-Passing): single-cursor linear trace.   *)
(*                                                                         *)
(* Drives TLC through an NDJSON trace recorded from the instrumented       *)
(* libspdm implementation and verifies that every state transition in the  *)
(* trace is reproducible by the base spec.                                 *)
(*                                                                         *)
(* Trace file format: ../traces/trace.ndjson  (overridable via IOEnv.JSON) *)
(* Each line is one JSON event record; see instrumentation-spec.md for     *)
(* the full schema.                                                        *)
(***************************************************************************)
EXTENDS base, Naturals, Sequences, TLC, IOUtils, Json

\* ----------------------------------------------------------------
\* Trace loading

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* ----------------------------------------------------------------
\* Cursor variable
VARIABLE l      \* 1..Len(TraceLog)+1; event TraceLog[l] is "current"

TraceVars == <<vars, l>>

\* ----------------------------------------------------------------
\* String-to-constant mappings for JSON fields

StrToState(s) ==
    CASE s = "not_started"  -> NOT_STARTED
      [] s = "handshaking"  -> HANDSHAKING
      [] s = "keys_derived" -> KEYS_DERIVED
      [] s = "established"  -> ESTABLISHED
      [] OTHER              -> NOT_STARTED  \* guard; should not happen

StrToMode(s) ==
    CASE s = "none"      -> MUT_NONE
      [] s = "non_encap" -> MUT_NON_ENCAP
      [] s = "encap"     -> MUT_ENCAP
      [] OTHER           -> MUT_NONE

\* ----------------------------------------------------------------
\* Event predicates

IsEvent(name)        == l <= Len(TraceLog) /\ TraceLog[l].event = name
HasField(f)          == f \in DOMAIN TraceLog[l]
FieldInt(f)          == TraceLog[l][f]
FieldBool(f)         == TraceLog[l][f]
FieldStr(f)          == TraceLog[l][f]

\* Session referenced by current event (integer, 1-based slot)
EventSession         == FieldInt("session_id")

\* ----------------------------------------------------------------
\* Post-state validation helpers
\*
\* Each wrapper checks the key variables that its corresponding base action modifies.
\* If the trace captures a field, we validate it. Missing fields are skipped.

ValidateSessionState(s) ==
    ~HasField("session_state") \/
    session_state'[s] = StrToState(FieldStr("session_state"))

ValidateLatestSessionId ==
    ~HasField("latest_session_id") \/
    latest_session_id' = FieldInt("latest_session_id")

ValidatePeerCertSlot(s) ==
    ~HasField("peer_cert_slot") \/
    peer_cert_slot'[s] = FieldInt("peer_cert_slot")

ValidateCertAdvertised(s) ==
    ~HasField("cert_advertised") \/
    cert_advertised'[s] = FieldInt("cert_advertised")

ValidateMutAuthMode(s) ==
    ~HasField("mut_auth_mode") \/
    mut_auth_mode'[s] = StrToMode(FieldStr("mut_auth_mode"))

ValidateDataKeysLive(s) ==
    ~HasField("data_keys_live") \/
    data_keys_live'[s] = FieldBool("data_keys_live")

ValidateExpectedSeq(s) ==
    ~HasField("expected_seq") \/
    expected_seq'[s] = FieldInt("expected_seq")

ValidateLastDecodeRejected(s) ==
    ~HasField("last_decode_rejected") \/
    last_decode_rejected'[s] = FieldBool("last_decode_rejected")

\* ----------------------------------------------------------------
\* TraceInit
\* Match the implementation's initial state.

TraceInit ==
    /\ Init
    /\ l = 1

\* ----------------------------------------------------------------
\* Action wrappers
\*
\* Each wrapper:
\*   1. Matches the event name
\*   2. Extracts parameters from the trace event
\*   3. Calls the base spec action
\*   4. Validates post-state fields from the trace
\*   5. Advances cursor: l' = l + 1

TraceReqSendKeyExchange ==
    /\ IsEvent("req_send_key_exchange")
    /\ LET hitc == FieldBool("hitc")
           slot == FieldInt("req_slot_id")
           mode == StrToMode(FieldStr("mode"))
       IN
       /\ ReqSendKeyExchange(hitc, slot, mode)
       \* Post-state: msgs updated (validated implicitly by base action preconditions)
    /\ l' = l + 1

TraceRspHandleKeyExchange ==
    /\ IsEvent("rsp_handle_key_exchange")
    /\ LET s    == EventSession
           hitc == FieldBool("hitc")
           slot == FieldInt("req_slot_id")
           mode == StrToMode(FieldStr("mode"))
           m    == [type        |-> MT_KEY_EX,
                    hitc        |-> hitc,
                    req_slot_id |-> slot,
                    mode        |-> mode]
       IN
       /\ RspHandleKeyExchange(m, s)
       \* Post-state validation: all fields modified by RspHandleKeyExchange
       /\ ValidateSessionState(s)
       /\ ValidateLatestSessionId
       /\ ValidatePeerCertSlot(s)
       /\ ValidateCertAdvertised(s)
       /\ ValidateMutAuthMode(s)
    /\ l' = l + 1

TraceReqSendFinish ==
    /\ IsEvent("req_send_finish")
    /\ LET s          == EventSession
           auth       == FieldInt("auth_session")
           rsp_msg    == [type       |-> MT_KEY_EX_RSP,
                          session_id |-> s,
                          mode       |-> mut_auth_mode[s],
                          slot_param |-> cert_advertised[s]]
       IN
       /\ ReqSendFinish(rsp_msg, auth)
       \* Post-state: msgs updated (new FINISH in flight)
    /\ l' = l + 1

TraceRspDeriveDataKeys ==
    /\ IsEvent("rsp_derive_data_keys")
    /\ LET s    == EventSession
           hitc == hitc_negotiated[s]
           \* Reconstruct FINISH message from trace fields
           m    == [type             |-> MT_FINISH,
                    session_id       |-> s,
                    session_id_valid |-> FieldBool("session_id_valid"),
                    auth_session     |-> FieldInt("auth_session"),
                    req_slot_id      |-> FieldInt("req_slot_id")]
       IN
       /\ RspDeriveDataKeys(m)
       \* Post-state: session_state, data_keys_live, cert_slot_verified
       /\ ValidateSessionState(s)
       /\ ValidateDataKeysLive(s)
       /\ (~HasField("cert_slot_verified") \/
           cert_slot_verified'[s] = FieldInt("cert_slot_verified"))
       /\ (~HasField("finish_authenticated_for") \/
           finish_authenticated_for'[s] = FieldInt("finish_authenticated_for"))
    /\ l' = l + 1

TraceRspCommitEstablished ==
    /\ IsEvent("rsp_commit_established")
    /\ LET s_derive == EventSession
           frsp     == [type       |-> MT_FINISH_RSP,
                        session_id |-> s_derive]
       IN
       /\ RspCommitEstablished(frsp, s_derive)
       \* Post-state: session_state of the committed session
       /\ ValidateSessionState(s_derive)
       /\ ValidateLatestSessionId
    /\ l' = l + 1

TraceRspEncodeFailure ==
    /\ IsEvent("rsp_encode_failure")
    /\ LET s == EventSession IN
       /\ RspEncodeFailure(s)
       /\ ValidateSessionState(s)
       /\ ValidateDataKeysLive(s)
    /\ l' = l + 1

TraceReqSendAppData ==
    /\ IsEvent("req_send_app_data")
    /\ LET s    == EventSession
           auth == FieldBool("authentic")
       IN
       /\ ReqSendAppData(s, auth)
    /\ l' = l + 1

TraceRspDecodeSecuredMessage ==
    /\ IsEvent("rsp_decode_secured_message")
    /\ LET s   == EventSession
           seq == FieldInt("seq_num")
           m   == [type       |-> MT_APP_DATA,
                   session_id |-> s,
                   seq_num    |-> seq,
                   authentic  |-> FieldBool("authentic")]
       IN
       /\ RspDecodeSecuredMessage(m)
       \* Post-state: expected_seq and last_decode_rejected are key outputs
       /\ ValidateExpectedSeq(s)
       /\ ValidateLastDecodeRejected(s)
       /\ (~HasField("seq_before_advance") \/
           seq_before_advance'[s] = FieldInt("seq_before_advance"))
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* Silent actions
\*
\* The base spec has no mandatory intermediate steps between trace events, but
\* some state changes might occur without producing a trace event (e.g., a message
\* being removed from msgs without a separate event).
\*
\* Kept tightly constrained: only fire when l <= Len(TraceLog) and a specific
\* upcoming event would require them.  Unconstrained silent actions cause state
\* space explosion.
\*
\* Currently no silent actions are needed for this protocol — every base spec
\* action has a corresponding instrumentation point and trace event.

SilentActions == FALSE  \* placeholder; expand if harness reveals gaps

\* ----------------------------------------------------------------
\* TraceNext

TraceNext ==
    \/ TraceReqSendKeyExchange
    \/ TraceRspHandleKeyExchange
    \/ TraceReqSendFinish
    \/ TraceRspDeriveDataKeys
    \/ TraceRspCommitEstablished
    \/ TraceRspEncodeFailure
    \/ TraceReqSendAppData
    \/ TraceRspDecodeSecuredMessage
    \/ /\ l <= Len(TraceLog)
       /\ SilentActions
       /\ UNCHANGED l
    \/ /\ l > Len(TraceLog)  \* stuttering after trace consumed
       /\ UNCHANGED TraceVars

TraceSpec == TraceInit /\ [][TraceNext]_TraceVars /\ WF_TraceVars(TraceNext)

\* ----------------------------------------------------------------
\* TraceMatched: temporal property — entire trace must be consumed
\* Must be included in PROPERTIES in Trace.cfg; without it TLC reports no
\* errors even when l never advances.

TraceMatched == <>(l > Len(TraceLog))

====
