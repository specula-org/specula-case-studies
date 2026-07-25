---- MODULE Trace ----
\* Trace validation spec for the libspdm chunking / reassembly base spec.
\*
\* Category A (Distributed / Message-Passing) — standard single-cursor trace pattern.
\* Drives TLC through an NDJSON trace from the instrumented libspdm implementation,
\* verifying that every observed state transition is reproducible by the base spec.
\*
\* Trace file location: ../traces/trace.ndjson (override with IOEnv.JSON).
\*
\* Run: tlc -config Trace.cfg Trace
\*
\* Success condition: TraceMatched holds — every trace event consumed.

EXTENDS base, IOUtils, Json, Sequences, TLC

\* ------------------------------------------------------------------
\* Trace loading
\* ------------------------------------------------------------------

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* ------------------------------------------------------------------
\* Cursor variable
\* ------------------------------------------------------------------
VARIABLE l         \* index into TraceLog; starts at 1

tracevars == <<l>>

\* ------------------------------------------------------------------
\* Event predicates
\* ------------------------------------------------------------------

IsEvent(name) ==
    l <= Len(TraceLog) /\ TraceLog[l].event = name

\* ------------------------------------------------------------------
\* Post-state validation helpers
\*
\* Each action wrapper calls ValidatePostState after the base action.
\* Fields listed here must be captured in the NDJSON trace.
\* ------------------------------------------------------------------

\* Validate responder CHUNK_SEND accumulation state
ValidateSendState ==
    LET t == TraceLog[l] IN
    /\ send_in_use           = t.send_in_use
    /\ send_seq_no           = t.send_seq_no
    /\ send_bytes_transferred = t.send_bytes_transferred
    /\ send_large_msg_size   = t.send_large_msg_size

\* Validate responder CHUNK_GET serving state
ValidateGetState ==
    LET t == TraceLog[l] IN
    /\ get_in_use    = t.get_in_use
    /\ get_seq_no    = t.get_seq_no
    /\ get_bytes_sent = t.get_bytes_sent
    /\ get_large_msg_size = t.get_large_msg_size

\* Validate requester reassembly state
ValidateReqState ==
    LET t == TraceLog[l] IN
    /\ req_state       = t.req_state
    /\ req_bytes_so_far = t.req_bytes_so_far
    /\ last_chunk_received = t.last_chunk_received
    /\ output_written  = t.output_written
    /\ scratch_zeroed  = t.scratch_zeroed
    /\ transfer_status = t.transfer_status

\* ------------------------------------------------------------------
\* Action wrappers
\* Each wrapper: matches event → calls base action → validates post-state → advances l
\* ------------------------------------------------------------------

\* --- Wrapper: ResponderChunkSendReceivedFirstChunk ---
\* Trace event: "chunk_send_first"
\* Source: libspdm_rsp_chunk_send_ack.c:106–159
TraceResponderChunkSendReceivedFirstChunk ==
    /\ IsEvent("chunk_send_first")
    /\ ResponderChunkSendReceivedFirstChunk
    /\ ValidateSendState
    /\ l' = l + 1

\* --- Wrapper: ResponderChunkSendReceivedValidSeqNo ---
\* Trace event: "chunk_send_valid"
\* Source: libspdm_rsp_chunk_send_ack.c:160–203 (valid path)
TraceResponderChunkSendReceivedValidSeqNo ==
    /\ IsEvent("chunk_send_valid")
    /\ ResponderChunkSendReceivedValidSeqNo
    /\ ValidateSendState
    /\ l' = l + 1

\* --- Wrapper: ResponderChunkSendReceivedInvalidSeqNo ---
\* Trace event: "chunk_send_invalid_seq"
\* Source: libspdm_rsp_chunk_send_ack.c:166–199 (invalid seq-no path — Family 2)
TraceResponderChunkSendReceivedInvalidSeqNo ==
    /\ IsEvent("chunk_send_invalid_seq")
    /\ ResponderChunkSendReceivedInvalidSeqNo
    \* Post-state: bytes_transferred must NOT have advanced (correct behavior)
    \* or WILL have advanced (bug path) — trace validation disambiguates
    /\ send_bytes_transferred = TraceLog[l].send_bytes_transferred
    /\ l' = l + 1

\* --- Wrapper: ResponderLargeResponseReady ---
\* Trace event: "large_response_ready"
\* Source: libspdm_rsp_receive_send.c:~L650–680
TraceResponderLargeResponseReady ==
    /\ IsEvent("large_response_ready")
    /\ LET t == TraceLog[l] IN
       ResponderLargeResponseReady(t.handle, t.large_size)
    /\ ValidateGetState
    /\ l' = l + 1

\* --- Wrapper: RequesterReceivesLargeResponseError ---
\* Trace event: "large_response_error_received"
\* Source: libspdm_req_handle_error_response.c:~L270–320
TraceRequesterReceivesLargeResponseError ==
    /\ IsEvent("large_response_error_received")
    /\ RequesterReceivesLargeResponseError
    /\ req_state = IN_PROGRESS
    /\ req_bytes_so_far = 0
    /\ l' = l + 1

\* --- Wrapper: ResponderServesChunkGet (normal path) ---
\* Trace event: "chunk_get_served"
\* Source: libspdm_rsp_chunk_response.c:98–160 (normal path)
TraceResponderServesChunkGet ==
    /\ IsEvent("chunk_get_served")
    /\ ResponderServesChunkGet
    /\ ValidateGetState
    /\ l' = l + 1

\* --- Wrapper: ResponderServesChunkGetWhileSendInProgress ---
\* Trace event: "chunk_get_during_send"
\* Source: libspdm_rsp_chunk_response.c:98–103 (no send_in_use check — Family 5)
TraceResponderServesChunkGetWhileSendInProgress ==
    /\ IsEvent("chunk_get_during_send")
    /\ ResponderServesChunkGetWhileSendInProgress
    /\ ValidateGetState
    \* Both contexts simultaneously active (the Family 5 violation)
    /\ send_in_use = TRUE
    /\ l' = l + 1

\* --- Wrapper: RequesterProcessChunkResponseValid ---
\* Trace event: "chunk_response_processed_valid"
\* Source: libspdm_req_handle_error_response.c:411–455 (valid source bound)
TraceRequesterProcessChunkResponseValid ==
    /\ IsEvent("chunk_response_processed_valid")
    /\ RequesterProcessChunkResponseValid
    /\ ValidateReqState
    \* Family 1: validate last_chunk_received tracking
    /\ last_chunk_received = TraceLog[l].last_chunk_received
    /\ l' = l + 1

\* --- Wrapper: RequesterProcessChunkResponseSourceUnbounded ---
\* Trace event: "chunk_response_source_oob"
\* Source: libspdm_req_handle_error_response.c:449–451 (no source-bound check — Family 4)
TraceRequesterProcessChunkResponseSourceUnbounded ==
    /\ IsEvent("chunk_response_source_oob")
    /\ RequesterProcessChunkResponseSourceUnbounded
    /\ received_msg_size = TraceLog[l].received_msg_size
    /\ req_bytes_so_far  = TraceLog[l].req_bytes_so_far
    /\ l' = l + 1

\* --- Wrapper: RequesterTransferCompleteSuccess ---
\* Trace event: "transfer_complete_success"
\* Source: libspdm_req_handle_error_response.c:462–472
TraceRequesterTransferCompleteSuccess ==
    /\ IsEvent("transfer_complete_success")
    /\ RequesterTransferCompleteSuccess
    /\ ValidateReqState
    \* Family 1: confirm last_chunk_received at completion
    /\ last_chunk_received = TraceLog[l].last_chunk_received
    \* Family 3: output_written and scratch_zeroed must be TRUE
    /\ output_written = TRUE
    /\ scratch_zeroed = TRUE
    /\ l' = l + 1

\* --- Wrapper: RequesterTransferCompleteBufferOverflow ---
\* Trace event: "transfer_complete_overflow"
\* Source: libspdm_req_handle_error_response.c:462–473 (missing else branch — Family 3)
TraceRequesterTransferCompleteBufferOverflow ==
    /\ IsEvent("transfer_complete_overflow")
    /\ RequesterTransferCompleteBufferOverflow
    /\ transfer_status = SUCCESS
    \* Family 3 bug: output_written=FALSE and scratch_zeroed=FALSE with SUCCESS
    /\ output_written = TraceLog[l].output_written
    /\ scratch_zeroed = TraceLog[l].scratch_zeroed
    /\ l' = l + 1

\* ------------------------------------------------------------------
\* Silent actions
\*
\* Handle state changes that do not generate trace events.
\* Must be tightly constrained (precondition + next-event lookahead).
\* ------------------------------------------------------------------

\* Silent: Requester sends a CHUNK_GET (follow-up after receiving CHUNK_RESPONSE).
\* No trace event is emitted for the send itself; only CHUNK_RESPONSE receipts are traced.
TraceSilentRequesterSendsChunkGet ==
    /\ l <= Len(TraceLog)
    /\ req_state = IN_PROGRESS
    /\ req_bytes_so_far < req_large_size
    \* Next event is a CHUNK_RESPONSE — the silent CHUNK_GET must fire first
    /\ TraceLog[l].event \in {"chunk_response_processed_valid",
                               "chunk_response_source_oob"}
    \* No base action to call here; this is purely network plumbing
    /\ \E h \in 0..3, sn \in 0..MaxChunks :
           Send([mtype  |-> CHUNK_GET,
                 handle |-> h,
                 seq_no |-> sn])
    /\ UNCHANGED <<sendVars, getVars, reqVars, protocolVars, l>>

\* ------------------------------------------------------------------
\* TraceNext
\* ------------------------------------------------------------------
TraceNext ==
    \/ TraceResponderChunkSendReceivedFirstChunk
    \/ TraceResponderChunkSendReceivedValidSeqNo
    \/ TraceResponderChunkSendReceivedInvalidSeqNo
    \/ TraceResponderLargeResponseReady
    \/ TraceRequesterReceivesLargeResponseError
    \/ TraceResponderServesChunkGet
    \/ TraceResponderServesChunkGetWhileSendInProgress
    \/ TraceRequesterProcessChunkResponseValid
    \/ TraceRequesterProcessChunkResponseSourceUnbounded
    \/ TraceRequesterTransferCompleteSuccess
    \/ TraceRequesterTransferCompleteBufferOverflow
    \/ TraceSilentRequesterSendsChunkGet

\* ------------------------------------------------------------------
\* TraceInit
\* ------------------------------------------------------------------
TraceInit ==
    /\ Init
    /\ l = 1

\* ------------------------------------------------------------------
\* TraceSpec
\* ------------------------------------------------------------------
TraceSpec == TraceInit /\ [][TraceNext]_<<vars, tracevars>>

\* ------------------------------------------------------------------
\* TraceMatched — temporal property
\* Verify that TLC consumed every trace event.
\* MUST be listed under PROPERTIES in Trace.cfg.
\* ------------------------------------------------------------------
TraceMatched == <>(l > Len(TraceLog))

====
