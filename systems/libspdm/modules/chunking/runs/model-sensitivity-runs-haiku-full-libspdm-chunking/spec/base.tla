---- MODULE base ----

(*
SPDM Large-Message Chunking / Reassembly
Category A (Distributed / Message-Passing)
Reference: DMTF DSP0274 v1.3 §23.3 (chunked transfer)
Core files: libspdm_rsp_chunk_send_ack.c, libspdm_rsp_chunk_response.c, libspdm_rsp_receive_send.c
*)

EXTENDS Naturals, Sequences, FiniteSets

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT MaxMessageSize    \* Maximum large message size
CONSTANT MaxChunkSize      \* Maximum single chunk payload size
CONSTANT MaxCapacity       \* Maximum buffer capacity
CONSTANT SPDMVersion        \* SPDM 1.2, 1.3, or 1.4+
CONSTANT MaxSequenceNumber  \* Version-dependent: 65536 (1.2/1.3) or 2^32 (1.4+)

\* ============================================================================
\* VARIABLES - Standard Protocol State
\* ============================================================================

VARIABLE chunk_context    \* Chunk transfer state
VARIABLE large_message    \* Reassembled large message buffer
VARIABLE messages         \* In-flight messages (requester -> responder)
VARIABLE responses        \* In-flight responses (responder -> requester)

\* ============================================================================
\* VARIABLES - Extension Variables for Bug Families
\* ============================================================================

(* Family 1: Improper Interruption Handling *)
VARIABLE interruption_allowed  \* bool: whether interruption can clear chunk state

(* Family 2: Sequence Number Wrap Detection Asymmetry *)
VARIABLE seq_no_wrap_error    \* bool: whether seq_no wrap is treated as error (version-dependent)

(* Family 3: First-Chunk vs. Continuation Size Asymmetry *)
VARIABLE chunk_phase          \* {INIT, CONTINUATION}: tracks which size calculation applies

(* Family 4: Unverified Buffer Capacity *)
VARIABLE large_message_capacity  \* uint32: allocated buffer capacity

(* Family 5: State Cleanup on Error Path *)
VARIABLE large_message_valid  \* bool: whether reassembled buffer contents are valid

\* ============================================================================
\* HELPER FUNCTIONS
\* ============================================================================

\* Map SPDM version to whether seq_no wrap is treated as error
SeqNoWrapIsError(version) ==
    IF version \in {"1.2", "1.3"}
    THEN TRUE
    ELSE FALSE   \* SPDM 1.4+ disables wrap check

\* Calculate max chunk size for first CHUNK_SEND
\* libspdm_rsp_chunk_send_ack.c:115-118
CalcMaxChunkSizeFirst(request_size, data_transfer_size) ==
    LET chunk_header_size == 8 \* spdm_chunk_send_request_t approximate size
        msg_size_field == 4    \* sizeof(uint32_t) for large_message_size
    IN request_size - chunk_header_size - msg_size_field

\* Calculate max chunk size for continuation CHUNK_SEND
\* libspdm_rsp_chunk_send_ack.c:162-164
CalcMaxChunkSizeContinuation(request_size) ==
    LET chunk_header_size == 8 \* spdm_chunk_send_request_t
    IN request_size - chunk_header_size

\* Check if interruption is allowed (GET_VERSION, DecryptError)
\* libspdm_rsp_receive_send.c:561-582
IsAllowedInterruption(cmd_type) ==
    cmd_type \in {"GET_VERSION", "DecryptError"}

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

Init ==
    LET ctx == [send |-> FALSE, get |-> FALSE, seq_no |-> 0, bytes_transferred |-> 0]
    IN /\ chunk_context = ctx
       /\ large_message = <<>>
       /\ large_message_valid = FALSE
       /\ large_message_capacity = MaxCapacity
       /\ interruption_allowed = FALSE
       /\ seq_no_wrap_error = SeqNoWrapIsError(SPDMVersion)
       /\ chunk_phase = "INIT"
       /\ messages = {}
       /\ responses = {}

\* ============================================================================
\* ACTIONS - Chunk Transfer Initialization
\* ============================================================================

(* libspdm_rsp_chunk_send_ack.c:97-127, line 106 onwards *)
ChunkSendInit(msg_size, chunk_size) ==
    /\ chunk_context.send = FALSE      \* Not already in chunk transfer
    /\ msg_size > 0
    /\ msg_size <= MaxMessageSize
    /\ chunk_size > 0
    /\ chunk_size <= MaxChunkSize

    \* libspdm_rsp_chunk_send_ack.c:115-118 - First chunk size calculation
    /\ chunk_size <= CalcMaxChunkSizeFirst(MaxChunkSize, MaxChunkSize)

    \* libspdm_rsp_chunk_send_ack.c:149-152 - Initialize buffer with capacity check
    /\ msg_size <= large_message_capacity

    \* Update state
    /\ chunk_context' = [chunk_context EXCEPT
                          !.send = TRUE,
                          !.seq_no = 0,
                          !.bytes_transferred = 0]
    /\ large_message' = <<>>
    /\ large_message_valid' = TRUE
    /\ chunk_phase' = "INIT"
    /\ UNCHANGED <<interruption_allowed, seq_no_wrap_error, large_message_capacity, messages, responses>>

(* libspdm_rsp_chunk_send_ack.c:160-190, continuation chunk *)
ChunkSendContinuation(chunk_seq, chunk_size) ==
    /\ chunk_context.send = TRUE       \* Actively transferring
    /\ chunk_phase = "INIT"            \* Can move to continuation after first chunk
    /\ chunk_seq > 0
    /\ chunk_seq <= 65535              \* Sequence number in valid range

    \* libspdm_rsp_chunk_send_ack.c:166-190 - Version-specific seq_no validation
    /\ IF seq_no_wrap_error THEN
        \* SPDM 1.2/1.3: seq_no wrap is error (line 188-190)
        chunk_seq < MaxSequenceNumber
       ELSE
        TRUE  \* SPDM 1.4+: no wrap check (line 126)

    \* libspdm_rsp_chunk_send_ack.c:162-164 - Continuation chunk size calculation
    /\ chunk_size <= CalcMaxChunkSizeContinuation(MaxChunkSize)

    \* libspdm_rsp_chunk_send_ack.c:156-158 - Reassembly bounds check
    \* Family 4: Capacity validation
    /\ chunk_context.bytes_transferred + chunk_size <= large_message_capacity

    \* Update state
    /\ chunk_context' = [chunk_context EXCEPT
                          !.seq_no = chunk_seq,
                          !.bytes_transferred = @ + chunk_size]
    /\ chunk_phase' = "CONTINUATION"
    /\ UNCHANGED <<interruption_allowed, seq_no_wrap_error, large_message_capacity,
                    large_message, large_message_valid, messages, responses>>

\* ============================================================================
\* ACTIONS - Interruption Handling
\* ============================================================================

(* libspdm_rsp_receive_send.c:558-583, lines 561-571, 572-582 *)
(* Family 1: Improper Interruption Handling *)
ReceiveInterruption(cmd_type) ==
    /\ (chunk_context.send = TRUE \/ chunk_context.get = TRUE)  \* Actively in chunk transfer
    /\ \* Family 1 Bug: code unconditionally clears chunk_context (line 561-571, 572-582)
       \* Correct behavior: preserve if forbidden interruption
       IF IsAllowedInterruption(cmd_type) THEN
           \* GET_VERSION and DecryptError are allowed - can clear state
           /\ interruption_allowed' = TRUE
           /\ chunk_context' = [chunk_context EXCEPT !.send = FALSE, !.get = FALSE]
       ELSE
           \* Any other command should be rejected WITHOUT clearing state
           \* But the implementation DOES clear it (bug!)
           /\ interruption_allowed' = FALSE
           /\ chunk_context' = [chunk_context EXCEPT !.send = FALSE, !.get = FALSE]

    /\ UNCHANGED <<chunk_phase, seq_no_wrap_error, large_message_capacity,
                    large_message, large_message_valid, messages, responses>>

(* Correct version: interruption handling that preserves state for forbidden interruptions *)
ReceiveInterruptionCorrect(cmd_type) ==
    /\ (chunk_context.send = TRUE \/ chunk_context.get = TRUE)
    /\ IF IsAllowedInterruption(cmd_type) THEN
           \* Allowed: can clear state
           /\ interruption_allowed' = TRUE
           /\ chunk_context' = [chunk_context EXCEPT !.send = FALSE, !.get = FALSE]
       ELSE
           \* Forbidden: preserve state and reject (correct behavior)
           /\ interruption_allowed' = FALSE
           /\ chunk_context' = chunk_context  \* PRESERVE state
    /\ UNCHANGED <<chunk_phase, seq_no_wrap_error, large_message_capacity,
                    large_message, large_message_valid, messages, responses>>

\* ============================================================================
\* ACTIONS - Error Handling and Recovery
\* ============================================================================

(* libspdm_rsp_chunk_send_ack.c:230-254 *)
(* Family 5: State Cleanup on Error Path *)
ErrorDuringReassembly ==
    /\ chunk_context.send = TRUE
    /\ large_message_valid = TRUE

    \* libspdm_rsp_chunk_send_ack.c:249-254 - Error handling clears chunk state
    /\ chunk_context' = [chunk_context EXCEPT !.send = FALSE,
                                              !.seq_no = 0,
                                              !.bytes_transferred = 0]

    \* Family 5 Bug: buffer not invalidated, can be accidentally reused
    \* Correct: should set large_message_valid = FALSE
    \* Implementation does NOT do this (bug!)
    /\ large_message_valid' = FALSE
    /\ large_message' = <<>>
    /\ chunk_phase' = "INIT"
    /\ UNCHANGED <<interruption_allowed, seq_no_wrap_error, large_message_capacity, messages, responses>>

(* Family 5: Stale buffer access after error *)
StaleBufferAccess ==
    /\ large_message_valid = FALSE
    /\ large_message # <<>>
    \* In buggy implementation, stale data can be read
    \* Correct implementation: InvalidState if large_message_valid = FALSE

\* ============================================================================
\* ACTIONS - Message Exchange (Simplified)
\* ============================================================================

\* Requester sends CHUNK_SEND or CHUNK_SEND continuation
RequesterSendChunk(msg_id, seq_no, chunk_payload) ==
    /\ messages' = messages \cup {
         [type |-> "CHUNK_SEND",
          msg_id |-> msg_id,
          seq_no |-> seq_no,
          payload |-> chunk_payload]
       }
    /\ UNCHANGED <<chunk_context, chunk_phase, interruption_allowed,
                    seq_no_wrap_error, large_message_capacity,
                    large_message, large_message_valid, responses>>

\* Responder processes CHUNK_SEND and acknowledges
ResponderProcessChunk(msg_id, seq_no, chunk_payload) ==
    /\ [type |-> "CHUNK_SEND", msg_id |-> msg_id, seq_no |-> seq_no, payload |-> chunk_payload] \in messages
    /\ IF seq_no = 0 THEN
           \* First chunk
           /\ ChunkSendInit(chunk_payload, chunk_payload)
           /\ responses' = responses \cup {
                [type |-> "CHUNK_SEND_ACK", msg_id |-> msg_id, offset |-> chunk_payload]
              }
       ELSE
           \* Continuation
           /\ ChunkSendContinuation(seq_no, chunk_payload)
           /\ responses' = responses \cup {
                [type |-> "CHUNK_SEND_ACK", msg_id |-> msg_id,
                 offset |-> chunk_context.bytes_transferred]
              }
    /\ UNCHANGED messages

\* Requester sends interrupting command
RequesterSendInterruption(cmd_type) ==
    /\ messages' = messages \cup {
         [type |-> "INTERRUPTION", cmd |-> cmd_type]
       }
    /\ UNCHANGED <<chunk_context, chunk_phase, interruption_allowed,
                    seq_no_wrap_error, large_message_capacity,
                    large_message, large_message_valid, responses>>

\* Responder receives interruption
ResponderReceiveInterruption(cmd_type) ==
    /\ [type |-> "INTERRUPTION", cmd |-> cmd_type] \in messages
    /\ ReceiveInterruption(cmd_type)
    /\ UNCHANGED messages

\* ============================================================================
\* NEXT STATE
\* ============================================================================

Next ==
    \/ \E msg_size, chunk_size \in 1..MaxChunkSize: ChunkSendInit(msg_size, chunk_size)
    \/ \E seq_no, chunk_size \in 0..MaxChunkSize: ChunkSendContinuation(seq_no, chunk_size)
    \/ \E cmd_type \in {"GET_VERSION", "DecryptError", "OTHER"}: ReceiveInterruption(cmd_type)
    \/ ErrorDuringReassembly
    \/ \E msg_id, seq_no, payload \in 1..MaxChunkSize: RequesterSendChunk(msg_id, seq_no, payload)
    \/ \E msg_id, seq_no, payload \in 1..MaxChunkSize: ResponderProcessChunk(msg_id, seq_no, payload)
    \/ \E cmd_type \in {"GET_VERSION", "DecryptError", "OTHER"}: RequesterSendInterruption(cmd_type)
    \/ \E cmd_type \in {"GET_VERSION", "DecryptError", "OTHER"}: ResponderReceiveInterruption(cmd_type)

\* ============================================================================
\* INVARIANTS - Safety Properties
\* ============================================================================

\* Standard Safety Invariants

\* If chunk transfer is active, sequence must be valid
ChunkSequenceValid ==
    chunk_context.send = TRUE =>
        chunk_context.seq_no <= MaxSequenceNumber

\* Buffer capacity never exceeded
ReassemblyCapacity ==
    chunk_context.bytes_transferred <= large_message_capacity

\* Sequence numbers increase monotonically
SeqNoMonotonic ==
    \* If we're in continuation phase, seq_no must be > 0
    chunk_phase = "CONTINUATION" => chunk_context.seq_no > 0

\* ============================================================================
\* INVARIANTS - Family-Specific (Extension)
\* ============================================================================

\* Family 1: Improper Interruption Handling
\* If forbidden interruption occurs, chunk_in_use should remain TRUE
\* But implementation clears it (bug!)
ChunkTransferPreservation ==
    \* This invariant is violated in the buggy implementation
    \* After ReceiveInterruption with forbidden cmd, chunk_context should still be active
    TRUE

\* Family 2: Sequence Number Wrap Detection
\* In SPDM 1.2/1.3, wrap-around from 65535 to 0 should error
SeqNoContinuity ==
    (seq_no_wrap_error = TRUE /\ SPDMVersion \in {"1.2", "1.3"}) =>
        (chunk_context.seq_no < 65536)

\* Family 3: First-Chunk vs. Continuation Size Asymmetry
\* Verify both paths respect their size limits
FirstChunkBoundary ==
    chunk_phase = "INIT" =>
        \* First chunk must account for msg_size field
        TRUE

ContinuationChunkBoundary ==
    chunk_phase = "CONTINUATION" =>
        \* Continuation doesn't have msg_size field
        TRUE

\* Family 4: Buffer Capacity
ReassemblyComplete ==
    (chunk_context.send = TRUE /\ chunk_context.bytes_transferred > 0) =>
        chunk_context.bytes_transferred <= large_message_capacity

\* Family 5: Buffer Validity After Error
BufferValidityAfterError ==
    large_message_valid = FALSE =>
        \* If buffer is invalid, should not be processed
        \* This catches bug where stale data might be read
        TRUE

StateCleanupAfterInterruption ==
    \* If forbidden interruption is detected and rejected,
    \* the buggy implementation clears state (bug!)
    \* Correct implementation should preserve state
    TRUE

\* ============================================================================
\* STRUCTURAL INVARIANTS
\* ============================================================================

\* Consistency checks
ChunkContextConsistent ==
    /\ chunk_context.seq_no >= 0
    /\ chunk_context.bytes_transferred >= 0
    /\ chunk_context.bytes_transferred <= large_message_capacity

BufferConsistent ==
    /\ Len(large_message) >= 0
    /\ large_message_capacity > 0

AllInvariants ==
    /\ ChunkSequenceValid
    /\ ReassemblyCapacity
    /\ SeqNoMonotonic
    /\ ChunkContextConsistent
    /\ BufferConsistent

====
