---- MODULE Trace ----
(* Trace Validation Spec for MEL Protocol
 * Validates that implementation traces match the base spec
 *)

EXTENDS base, IOUtils, Json, Naturals, Sequences

(* ===== Trace Loading ===== *)
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/mel.ndjson"

(* ===== Trace Log ===== *)
VARIABLE TraceLog
VARIABLE l

traceVars == <<TraceLog, l>>

(* ===== Trace File Loading ===== *)
LoadTraceFile ==
    IF "JSON" \in DOMAIN IOEnv
    THEN ndJsonDeserialize(IOEnv.JSON)
    ELSE ndJsonDeserialize(JsonFile)

(* ===== Event Helpers ===== *)
IsEvent(eventName) == l <= Len(TraceLog) /\ TraceLog[l].event_name = eventName
GetEvent == IF l <= Len(TraceLog) THEN TraceLog[l] ELSE NULL_MEL

(* ===== Trace Action: Process RequesterSendGetMel ===== *)
TraceRequesterSendGetMel ==
    /\ IsEvent("req_send_get_mel")
    /\ LET event == GetEvent
       IN /\ req_pc = "ready"
          /\ event.req_pc = "waiting"
          /\ event.msg_type = GetMelRequest
          /\ event.msg_length > 0
          /\ event.msg_length <= MAX_CHUNK_SIZE
          /\ event.msg_offset >= 0
          /\ event.msg_offset + event.msg_length <= MAX_MEL_SIZE + MAX_CHUNK_SIZE
          /\ req_pc' = "waiting"
          /\ UNCHANGED <<TraceLog, req_offset, req_mel_size, req_remainder, req_total_mel_size, responder_mel, responder_pc, messages>>
          /\ l' = l + 1

(* ===== Trace Action: Process ResponderReceiveAndSendMel ===== *)
TraceResponderReceiveAndSendMel ==
    /\ IsEvent("resp_receive_and_send_mel")
    /\ LET event == GetEvent
       IN /\ responder_pc = "ready"
          /\ event.responder_mel_size = responder_mel.size
          /\ event.responder_mel_entries_len = responder_mel.entries_len
          /\ event.msg_type = MelResponse
          /\ event.msg_portion_length > 0
          /\ event.msg_portion_length <= responder_mel.size
          /\ event.msg_remainder_length >= 0
          /\ event.msg_portion_length + event.msg_remainder_length <= responder_mel.size + 1
          /\ UNCHANGED <<TraceLog, req_offset, req_mel_size, req_remainder, req_total_mel_size, req_pc, responder_mel, responder_pc, messages>>
          /\ l' = l + 1

(* ===== Trace Action: Process RequesterReceiveMelResponse ===== *)
TraceRequesterReceiveMelResponse ==
    /\ IsEvent("req_receive_mel_response")
    /\ LET event == GetEvent
           new_mel_size == req_mel_size + event.recv_portion_length
       IN /\ req_pc = "waiting"
          /\ event.msg_type = MelResponse
          /\ event.recv_portion_length > 0
          /\ event.recv_portion_length <= MAX_CHUNK_SIZE
          /\ event.recv_remainder_length >= 0
          /\ new_mel_size <= MAX_MEL_SIZE
          /\ event.recv_portion_length = new_mel_size - req_offset
          /\ event.recv_remainder_length >= 0
          /\ req_mel_size' = new_mel_size
          /\ req_remainder' = event.recv_remainder_length
          /\ req_offset' = new_mel_size
          /\ IF req_offset = 0
             THEN req_total_mel_size' = event.recv_portion_length + event.recv_remainder_length
             ELSE req_total_mel_size' = req_total_mel_size
          /\ IF event.recv_remainder_length = 0
             THEN req_pc' = "done"
             ELSE req_pc' = "ready"
          /\ UNCHANGED <<TraceLog, responder_mel, responder_pc, messages>>
          /\ l' = l + 1

(* ===== Trace Action: Process RequesterCheckTermination ===== *)
TraceRequesterCheckTermination ==
    /\ IsEvent("req_check_termination")
    /\ LET event == GetEvent
       IN /\ req_pc = "ready"
          /\ req_remainder = 0
          /\ req_mel_size >= 8
          /\ req_pc' = "done"
          /\ event.req_pc = "done"
          /\ UNCHANGED <<TraceLog, req_offset, req_mel_size, req_remainder, req_total_mel_size, responder_mel, responder_pc, messages>>
          /\ l' = l + 1

(* ===== Error Event Handler ===== *)
(* Handle resp_error events - these represent error cases *)
TraceResponderError ==
    /\ IsEvent("resp_error")
    /\ l' = l + 1
    /\ UNCHANGED <<TraceLog, requesterVars, responderVars, msgVars>>

(* ===== Silent Actions ===== *)
(* Move to next event if current one can't be matched *)
TraceSilentSkip ==
    /\ l <= Len(TraceLog)
    /\ ~IsEvent("req_send_get_mel")
    /\ ~IsEvent("resp_receive_and_send_mel")
    /\ ~IsEvent("req_receive_mel_response")
    /\ ~IsEvent("req_check_termination")
    /\ ~IsEvent("resp_error")
    /\ l' = l + 1
    /\ UNCHANGED <<TraceLog, requesterVars, responderVars, msgVars>>

(* ===== Trace Init ===== *)
TraceInit ==
    /\ TraceLog = LoadTraceFile
    /\ IF Len(TraceLog) > 0 /\ TraceLog[1].event_name = "init"
       THEN LET event == TraceLog[1]
            IN /\ responder_mel = [size |-> event.responder_mel_size,
                                  entries_len |-> event.responder_mel_entries_len]
               /\ responder_pc = event.responder_pc
               /\ req_offset = event.req_offset
               /\ req_mel_size = event.req_mel_size
               /\ req_remainder = event.req_remainder
               /\ req_total_mel_size = event.req_total_mel_size
               /\ req_pc = event.req_pc
               /\ messages = {}
               /\ l = 2
       ELSE /\ responder_mel = [size |-> 10, entries_len |-> 8]
            /\ responder_pc = "ready"
            /\ req_offset = 0
            /\ req_mel_size = 0
            /\ req_remainder = 0
            /\ req_total_mel_size = 0
            /\ req_pc = "ready"
            /\ messages = {}
            /\ l = 1

(* ===== Trace Next ===== *)
TraceNext ==
    \/ TraceRequesterSendGetMel
    \/ TraceResponderReceiveAndSendMel
    \/ TraceRequesterReceiveMelResponse
    \/ TraceRequesterCheckTermination
    \/ TraceResponderError
    \/ TraceSilentSkip

(* ===== Trace Spec ===== *)
TraceSpec == TraceInit /\ [][TraceNext]_<<requesterVars, responderVars, msgVars, traceVars>>

(* ===== Trace Completion Property ===== *)
TraceMatched == <>(l > Len(TraceLog))

====
