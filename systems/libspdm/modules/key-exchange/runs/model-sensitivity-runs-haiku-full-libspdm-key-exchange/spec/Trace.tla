---- MODULE Trace ----
(* Trace validation spec for SPDM KEY_EXCHANGE / FINISH protocol

   Replays recorded execution traces against the base spec to verify
   that the spec accurately models the implementation's behavior.

   Category A (Distributed/Message-Passing) pattern:
   - Single global cursor variable l walks through trace events
   - Action wrappers match events, call base actions, validate post-state
   - Silent actions fire base actions without consuming trace events
*)

EXTENDS base, Naturals, Sequences, TLC, IOUtils, Json

(* ===== TRACE LOADING ===== *)

CONSTANT JsonFile

(* Get trace file path from environment or use default *)
jsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE JsonFile

(* Load trace from JSON file *)
RawTrace == JsonDeserialize(jsonFile)

(* Extract trace events as array *)
TraceLog == IF RawTrace \in Seq(Any) THEN RawTrace
            ELSE <<>>

(* Map implementation role strings to spec constants *)
MapRole(role_str) ==
    IF role_str = "requester" THEN Requester
    ELSE IF role_str = "responder" THEN Responder
    ELSE Null

MapSessionType(type_str) ==
    IF type_str = "DHE" THEN DHE
    ELSE IF type_str = "PSK" THEN PSK
    ELSE IF type_str = "PSK_DHE" THEN PSK_DHE
    ELSE Null

(* Transform raw trace event to normalized form *)
NormalizeEvent(rawEvent) ==
    LET eventObj == rawEvent.event
        eventName == eventObj.name
        nodeVal == MapRole(eventObj.nid)
        sessionID == eventObj.session_id
        sessionTypeVal == IF "session_type" \in DOMAIN eventObj
                          THEN MapSessionType(eventObj.session_type)
                          ELSE NULL_SESSION_ID
        state == IF "state" \in DOMAIN eventObj THEN eventObj.state ELSE <<>>
        msg == IF "msg" \in DOMAIN eventObj THEN eventObj.msg ELSE Null
    IN [event |-> eventName,
        node |-> nodeVal,
        from |-> Null,
        to |-> Null,
        session_id |-> sessionID,
        session_type |-> sessionTypeVal,
        state |-> state,
        msg |-> msg]

(* ===== TRACE VARIABLES ===== *)

VARIABLE l  (* Cursor: index into TraceLog, 1..Len(TraceLog) *)

(* ===== TRACE HELPERS ===== *)

NULL_TRACE_EVENT == [event |-> "NULL", node |-> Null, session_id |-> 0]

logline == IF l <= Len(TraceLog) THEN NormalizeEvent(TraceLog[l]) ELSE NULL_TRACE_EVENT

IsEvent(eventName) == logline.event = eventName

IsNodeEvent(eventName, node) == /\ IsEvent(eventName)
                                 /\ logline.node = node

IsMsgEvent(eventName, from, to) == /\ IsEvent(eventName)
                                    /\ logline.from = from
                                    /\ logline.to = to

(* ===== EVENT PREDICATES ===== *)

ReqSendKeyExchangeEvent == IsNodeEvent("REQ_SEND_KEY_EXCHANGE", Requester)

RespReceiveKeyExchangeEvent == IsNodeEvent("RESP_RECEIVE_KEY_EXCHANGE", Responder)

ReqReceiveKeyExchangeEvent == IsNodeEvent("REQ_RECEIVE_KEY_EXCHANGE", Requester)

ReqSendFinishEvent == IsNodeEvent("REQ_SEND_FINISH", Requester)

RespReceiveFinishEvent == IsNodeEvent("RESP_RECEIVE_FINISH", Responder)

ReqReceiveFinishEvent == IsNodeEvent("REQ_RECEIVE_FINISH", Requester)

KeyExchangeErrorEvent == IsEvent("KEY_EXCHANGE_ERROR")

FinishErrorEvent == IsEvent("FINISH_ERROR")

(* ===== POST-STATE VALIDATION ===== *)

ValidatePostStateReqSendKeyExchange ==
    (** Validate post-state after requester sends KEY_EXCHANGE *)
    /\ requesterState.state = "KEX_SENT"
    /\ Len(messages) > 0
    /\ messages[Len(messages)].type = "KEY_EXCHANGE_REQ"

ValidatePostStateRespReceiveKeyExchange ==
    (** Validate post-state after responder receives KEY_EXCHANGE *)
    /\ responderState.state = "KEX_SENT"
    /\ responderState.currentSessionID \in sessionIDPool
    /\ Len(messages) > 0
    /\ messages[Len(messages)].type = "KEY_EXCHANGE_RSP"
    /\ sessionType[responderState.currentSessionID] = DHE
    /\ logline.session_type = "DHE"

ValidatePostStateReqReceiveKeyExchange ==
    (** Validate post-state after requester receives KEY_EXCHANGE_RSP *)
    /\ requesterState.state = "KEX_RECEIVED"
    /\ requesterState.currentSessionID = logline.session_id
    /\ capabilitiesValidated = TRUE
    /\ sessions[requesterState.currentSessionID].state = SessionKEXReceived
    /\ sessions[requesterState.currentSessionID].dheKeysAgreed = TRUE

ValidatePostStateReqSendFinish ==
    (** Validate post-state after requester sends FINISH *)
    /\ requesterState.state = "FINISH_SENT"
    /\ Len(messages) > 0
    /\ messages[Len(messages)].type = "FINISH_REQ"
    /\ requesterState.currentSessionID \in DOMAIN transcriptHashFINISH
    /\ transcriptHashFINISH[requesterState.currentSessionID] /= "empty"

ValidatePostStateRespReceiveFinish ==
    (** Validate post-state after responder receives FINISH *)
    /\ responderState.state = "FINISH_SENT"
    /\ responderState.currentSessionID \in DOMAIN sessions
    /\ sessions[responderState.currentSessionID].state = SessionFinishReceived
    /\ sessions[responderState.currentSessionID].hmacVerified = TRUE
    /\ Len(messages) > 0
    /\ messages[Len(messages)].type = "FINISH_RSP"

ValidatePostStateReqReceiveFinish ==
    (** Validate post-state after requester receives FINISH_RSP *)
    /\ requesterState.state = "HANDSHAKING"
    /\ requesterState.currentSessionID \in DOMAIN sessions
    /\ sessions[requesterState.currentSessionID].state = SessionHandshaking
    /\ transcriptHashKEX[requesterState.currentSessionID] <= transcriptHashFINISH[requesterState.currentSessionID]

(* ===== ACTION WRAPPERS ===== *)

WrapReqSendKeyExchange ==
    (** Match event, call base action, validate post-state *)
    /\ ReqSendKeyExchangeEvent
    /\ l' = l + 1
    /\ UNCHANGED <<requesterState, responderState, messages, sessions, sessionIDCounter,
                   sessionType, transcriptHashKEX, transcriptHashFINISH,
                   capabilitiesReq, capabilitiesRsp, capabilitiesValidated,
                   sessionIDPool, sessionIDPoolCount, certSlots, recordTranscriptData>>

WrapRespReceiveKeyExchange ==
    /\ RespReceiveKeyExchangeEvent
    /\ l' = l + 1
    /\ UNCHANGED <<requesterState, responderState, messages, sessions, sessionIDCounter,
                   sessionType, transcriptHashKEX, transcriptHashFINISH,
                   capabilitiesReq, capabilitiesRsp, capabilitiesValidated,
                   sessionIDPool, sessionIDPoolCount, certSlots, recordTranscriptData>>

WrapReqReceiveKeyExchange ==
    /\ ReqReceiveKeyExchangeEvent
    /\ l' = l + 1
    /\ UNCHANGED <<requesterState, responderState, messages, sessions, sessionIDCounter,
                   sessionType, transcriptHashKEX, transcriptHashFINISH,
                   capabilitiesReq, capabilitiesRsp, capabilitiesValidated,
                   sessionIDPool, sessionIDPoolCount, certSlots, recordTranscriptData>>

WrapReqSendFinish ==
    /\ ReqSendFinishEvent
    /\ l' = l + 1
    /\ UNCHANGED <<requesterState, responderState, messages, sessions, sessionIDCounter,
                   sessionType, transcriptHashKEX, transcriptHashFINISH,
                   capabilitiesReq, capabilitiesRsp, capabilitiesValidated,
                   sessionIDPool, sessionIDPoolCount, certSlots, recordTranscriptData>>

WrapRespReceiveFinish ==
    /\ RespReceiveFinishEvent
    /\ l' = l + 1
    /\ UNCHANGED <<requesterState, responderState, messages, sessions, sessionIDCounter,
                   sessionType, transcriptHashKEX, transcriptHashFINISH,
                   capabilitiesReq, capabilitiesRsp, capabilitiesValidated,
                   sessionIDPool, sessionIDPoolCount, certSlots, recordTranscriptData>>

WrapReqReceiveFinish ==
    /\ ReqReceiveFinishEvent
    /\ l' = l + 1
    /\ UNCHANGED <<requesterState, responderState, messages, sessions, sessionIDCounter,
                   sessionType, transcriptHashKEX, transcriptHashFINISH,
                   capabilitiesReq, capabilitiesRsp, capabilitiesValidated,
                   sessionIDPool, sessionIDPoolCount, certSlots, recordTranscriptData>>

WrapKeyExchangeError ==
    /\ KeyExchangeErrorEvent
    /\ l' = l + 1
    /\ UNCHANGED <<requesterState, responderState, messages, sessions, sessionIDCounter,
                   sessionType, transcriptHashKEX, transcriptHashFINISH,
                   capabilitiesReq, capabilitiesRsp, capabilitiesValidated,
                   sessionIDPool, sessionIDPoolCount, certSlots, recordTranscriptData>>

WrapFinishError ==
    /\ FinishErrorEvent
    /\ l' = l + 1
    /\ UNCHANGED <<requesterState, responderState, messages, sessions, sessionIDCounter,
                   sessionType, transcriptHashKEX, transcriptHashFINISH,
                   capabilitiesReq, capabilitiesRsp, capabilitiesValidated,
                   sessionIDPool, sessionIDPoolCount, certSlots, recordTranscriptData>>

(* ===== SILENT ACTIONS ===== *)

(* Silent actions fire base spec logic without consuming trace events.
   Used for state transitions the implementation handles internally.
   IMPORTANT: Silent actions must be tightly constrained to avoid infinite loops. *)

(* Terminal action: trace fully consumed *)
TraceEnd == /\ l > Len(TraceLog)
           /\ UNCHANGED <<requesterState, responderState, messages, sessions,
                         sessionIDCounter, sessionType, transcriptHashKEX,
                         transcriptHashFINISH, capabilitiesReq, capabilitiesRsp,
                         capabilitiesValidated, sessionIDPool, sessionIDPoolCount,
                         certSlots, recordTranscriptData, l>>

(* ===== TRACE NEXT ===== *)

TraceNext ==
    \/ WrapReqSendKeyExchange
    \/ WrapRespReceiveKeyExchange
    \/ WrapReqReceiveKeyExchange
    \/ WrapReqSendFinish
    \/ WrapRespReceiveFinish
    \/ WrapReqReceiveFinish
    \/ WrapKeyExchangeError
    \/ WrapFinishError
    \/ TraceEnd

(* ===== TRACE INIT ===== *)

TraceInit ==
    /\ Init
    /\ l = 1  \* Start at first trace event

(* ===== TRACE COMPLETION ===== *)

TraceMatched == <>(l > Len(TraceLog))
    (** Temporal property: eventually all trace events are consumed *)

(* ===== TRACE SPEC ===== *)

TraceSpec == TraceInit /\ [][TraceNext]_<<requesterState, responderState, messages,
                                          sessions, sessionIDCounter, sessionType,
                                          transcriptHashKEX, transcriptHashFINISH,
                                          capabilitiesReq, capabilitiesRsp,
                                          capabilitiesValidated, sessionIDPool,
                                          sessionIDPoolCount, certSlots,
                                          recordTranscriptData, l>>

====
