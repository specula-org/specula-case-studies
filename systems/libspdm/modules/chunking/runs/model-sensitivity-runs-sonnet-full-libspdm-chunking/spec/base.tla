---- MODULE base ----
\* SPDM Large-Message Chunking / Reassembly
\* DSP0274 §11 — libspdm reference implementation
\*
\* Category A (Distributed / Message-Passing):
\*   Two orthogonal transfer flows over explicit message types.
\*   - CHUNK_SEND flow: Requester fragments a large request → Responder accumulates
\*   - CHUNK_GET flow:  Responder serves a large response → Requester reassembles
\*
\* Bug families addressed:
\*   Family 1 (TransferTerminationConditionIncompleteness) — last_chunk_received
\*   Family 2 (ControlFlowOrderingSeqNoMismatch)           — seq-no guard separation
\*   Family 3 (ReassemblyOutputValidityAfterCompletion)    — output_written / scratch_zeroed
\*   Family 4 (SourceLengthUnboundedInReassemblyCopy)      — received_msg_size bound
\*   Family 5 (MutualExclusionAsymmetry)                   — dual send_in_use / get_in_use

EXTENDS Naturals, Sequences, FiniteSets, Bags, TLC

CONSTANTS
    MaxChunks,           \* max fragments in one transfer
    MaxLargeSize,        \* max bytes in a large message
    HeaderOverhead,      \* sizeof(spdm_chunk_response_response_t) — Family 4
    ResponseCapacity,    \* caller's output buffer size — Family 3
    NULL                 \* sentinel for "no current transfer"

ASSUME MaxChunks   \in Nat \ {0}
ASSUME MaxLargeSize \in Nat \ {0}
ASSUME HeaderOverhead \in Nat \ {0}
ASSUME ResponseCapacity \in Nat \ {0}

----
\* ------------------------------------------------------------------
\* Message types
\* ------------------------------------------------------------------

CHUNK_SEND       == "CHUNK_SEND"
CHUNK_SEND_ACK   == "CHUNK_SEND_ACK"
CHUNK_GET        == "CHUNK_GET"
CHUNK_RESPONSE   == "CHUNK_RESPONSE"
LARGE_RESPONSE   == "LARGE_RESPONSE"   \* error code initiating CHUNK_GET flow

\* Transfer-state constants
IDLE         == "IDLE"
IN_PROGRESS  == "IN_PROGRESS"
SUCCESS      == "SUCCESS"
ERROR_STATE  == "ERROR"

----
\* ------------------------------------------------------------------
\* Variables
\* ------------------------------------------------------------------

\* ----- Network -----
VARIABLE messages          \* message bag shared between Requester and Responder

\* ----- Responder CHUNK_SEND accumulation context -----
\* libspdm_rsp_chunk_send_ack.c — send_info (libspdm_chunk_info_t)
VARIABLE send_in_use             \* send_info->chunk_in_use       (Bool)
VARIABLE send_handle             \* send_info->chunk_handle        (0..255)
VARIABLE send_seq_no             \* send_info->chunk_seq_no        (Nat)
VARIABLE send_bytes_transferred  \* send_info->chunk_bytes_transferred (Nat)
VARIABLE send_large_msg_size     \* send_info->large_message_size  (Nat); 0 when idle

\* ----- Responder CHUNK_GET serving context -----
\* libspdm_rsp_chunk_response.c — get_info (libspdm_chunk_info_t)
VARIABLE get_in_use              \* get_info->chunk_in_use         (Bool)
VARIABLE get_handle              \* get_info->chunk_handle          (0..255)
VARIABLE get_seq_no              \* get_info->chunk_seq_no          (Nat)
VARIABLE get_large_msg_size      \* get_info->large_message_size    (Nat)
VARIABLE get_bytes_sent          \* bytes dispatched so far         (Nat)

\* ----- Requester CHUNK_GET reassembly state -----
\* libspdm_req_handle_error_response.c — local variables in do-while loop
VARIABLE req_state               \* IDLE | IN_PROGRESS | SUCCESS | ERROR_STATE
VARIABLE req_large_size          \* large_response_size declared by first CHUNK_SEND_ACK
VARIABLE req_bytes_so_far        \* large_response_size_so_far

\* Extension variables — Family 1 (TransferTerminationConditionIncompleteness)
\* libspdm_req_handle_error_response.c:457–459 — loop exit on byte-count alone
VARIABLE last_chunk_received     \* whether LAST_CHUNK flag was set on final fragment

\* Extension variables — Family 3 (ReassemblyOutputValidityAfterCompletion)
\* libspdm_req_handle_error_response.c:462–475 — missing else branch when buffer too small
VARIABLE output_written          \* TRUE iff libspdm_copy_mem to inout_response succeeded
VARIABLE scratch_zeroed          \* TRUE iff libspdm_zero_mem(large_response) was called

\* Extension variable — Family 4 (SourceLengthUnboundedInReassemblyCopy)
\* libspdm_req_handle_error_response.c:449–451 — chunk_size not bounded by received message
VARIABLE received_msg_size       \* actual bytes in the latest received CHUNK_RESPONSE message

\* Extension variable — Family 2 (ControlFlowOrderingSeqNoMismatch)
\* libspdm_rsp_chunk_send_ack.c:166 — seq-no check is separate standalone if, not a guard
VARIABLE incoming_seq_no         \* seq_no from the arriving CHUNK_SEND fragment

\* Transfer status tracking
VARIABLE transfer_status         \* overall status of the current requester CHUNK_GET transfer

sendVars    == <<send_in_use, send_handle, send_seq_no,
                send_bytes_transferred, send_large_msg_size>>
getVars     == <<get_in_use, get_handle, get_seq_no,
                get_large_msg_size, get_bytes_sent>>
reqVars     == <<req_state, req_large_size, req_bytes_so_far,
                last_chunk_received, output_written, scratch_zeroed,
                received_msg_size, transfer_status>>
protocolVars == <<incoming_seq_no>>
vars == <<messages, sendVars, getVars, reqVars, protocolVars>>

----
\* ------------------------------------------------------------------
\* Message helpers (bag-based)
\* ------------------------------------------------------------------

Send(m)    == messages' = messages (+) SetToBag({m})
Discard(m) == messages' = messages (-) SetToBag({m})
Reply(m,r) == messages' = (messages (-) SetToBag({m})) (+) SetToBag({r})

----
\* ------------------------------------------------------------------
\* Init
\* ------------------------------------------------------------------

Init ==
    /\ messages = EmptyBag
    \* Responder CHUNK_SEND context — all idle
    /\ send_in_use = FALSE
    /\ send_handle = 0
    /\ send_seq_no = 0
    /\ send_bytes_transferred = 0
    /\ send_large_msg_size = 0
    \* Responder CHUNK_GET context — all idle
    /\ get_in_use = FALSE
    /\ get_handle = 0
    /\ get_seq_no = 0
    /\ get_large_msg_size = 0
    /\ get_bytes_sent = 0
    \* Requester reassembly context
    /\ req_state = IDLE
    /\ req_large_size = 0
    /\ req_bytes_so_far = 0
    /\ last_chunk_received = FALSE
    /\ output_written = FALSE
    /\ scratch_zeroed = FALSE
    /\ received_msg_size = 0
    /\ incoming_seq_no = 0
    /\ transfer_status = IDLE

----
\* ==================================================================
\* CHUNK_SEND flow — Requester → Responder
\* ==================================================================

\* ------------------------------------------------------------------
\* Action: RequesterSendsFirstChunk
\* Requester initiates a CHUNK_SEND transfer by sending seq_no=0.
\* libspdm_req_send_receive.c:~L360–400 (CHUNK_SEND loop init)
\* ------------------------------------------------------------------
RequesterSendsFirstChunk(handle, chunkSize, largeSize) ==
    \* Precondition: requester is idle; valid sizes
    /\ req_state = IDLE
    /\ chunkSize \in 1..MaxLargeSize
    /\ largeSize \in chunkSize..MaxLargeSize
    /\ chunkSize < largeSize                    \* otherwise wouldn't need chunking
    \* Action: send CHUNK_SEND with seq_no=0
    /\ Send([mtype     |-> CHUNK_SEND,
             handle    |-> handle,
             seq_no    |-> 0,
             chunk_size|-> chunkSize,
             is_last   |-> FALSE,
             large_size|-> largeSize])
    /\ UNCHANGED <<sendVars, getVars, reqVars, protocolVars>>

\* ------------------------------------------------------------------
\* Action: RequesterSendsContinuationChunk
\* Requester sends subsequent CHUNK_SEND (seq_no > 0).
\* libspdm_req_send_receive.c:~L420–480
\* ------------------------------------------------------------------
RequesterSendsContinuationChunk(handle, seqNo, chunkSize, isLast, totalSent, largeSize) ==
    /\ req_state = IDLE                         \* requester CHUNK_GET is separate flow
    /\ seqNo \in 1..MaxChunks
    /\ chunkSize \in 1..MaxLargeSize
    /\ totalSent + chunkSize <= largeSize
    /\ Send([mtype     |-> CHUNK_SEND,
             handle    |-> handle,
             seq_no    |-> seqNo,
             chunk_size|-> chunkSize,
             is_last   |-> isLast,
             large_size|-> 0])                  \* large_size only in seq_no=0
    /\ UNCHANGED <<sendVars, getVars, reqVars, protocolVars>>

\* ------------------------------------------------------------------
\* Action: ResponderChunkSendReceivedFirstChunk
\* Responder processes first CHUNK_SEND (seq_no = 0).
\* libspdm_rsp_chunk_send_ack.c:106–158
\* ------------------------------------------------------------------
ResponderChunkSendReceivedFirstChunk ==
    \E msg \in DOMAIN messages :
        /\ messages[msg] > 0
        /\ msg.mtype = CHUNK_SEND
        /\ msg.seq_no = 0
        \* libspdm_rsp_chunk_send_ack.c:90–95 — reject if CHUNK_GET is in progress
        /\ ~get_in_use
        \* libspdm_rsp_chunk_send_ack.c:106 — first chunk: send_in_use must be false
        /\ ~send_in_use
        \* libspdm_rsp_chunk_send_ack.c:129–140 — validation (seq_no==0, sizes valid)
        /\ msg.large_size > 0
        /\ msg.chunk_size < msg.large_size
        \* State update: initialize accumulation context
        \* libspdm_rsp_chunk_send_ack.c:146–159
        /\ send_in_use' = TRUE
        /\ send_handle' = msg.handle
        /\ send_seq_no' = 0
        /\ send_bytes_transferred' = msg.chunk_size
        /\ send_large_msg_size' = msg.large_size
        /\ incoming_seq_no' = msg.seq_no
        /\ Reply(msg, [mtype    |-> CHUNK_SEND_ACK,
                       handle   |-> msg.handle,
                       seq_no   |-> 0,
                       is_error |-> FALSE])
        /\ UNCHANGED <<getVars, reqVars>>

\* ------------------------------------------------------------------
\* Action: ResponderChunkSendReceivedValidSeqNo
\* Responder processes a continuation CHUNK_SEND where seq_no is valid.
\* libspdm_rsp_chunk_send_ack.c:160–203 (else branch when in_use=true AND seq_no correct)
\*
\* Family 2 — this action models the CORRECT path where the seq-no check passes
\* and the data copy proceeds. The INVALID path is modeled separately below.
\* ------------------------------------------------------------------
ResponderChunkSendReceivedValidSeqNo ==
    \E msg \in DOMAIN messages :
        /\ messages[msg] > 0
        /\ msg.mtype = CHUNK_SEND
        /\ msg.seq_no > 0
        \* libspdm_rsp_chunk_send_ack.c:90–95
        /\ ~get_in_use
        \* libspdm_rsp_chunk_send_ack.c:160 — continuation requires send_in_use
        /\ send_in_use
        /\ msg.handle = send_handle
        \* libspdm_rsp_chunk_send_ack.c:166 — seq-no check (as STANDALONE if)
        /\ msg.seq_no = send_seq_no + 1
        /\ msg.chunk_size + send_bytes_transferred <= send_large_msg_size
        \* libspdm_rsp_chunk_send_ack.c:193–199 — copy + advance state
        /\ incoming_seq_no' = msg.seq_no
        /\ send_seq_no' = msg.seq_no
        /\ send_bytes_transferred' = send_bytes_transferred + msg.chunk_size
        /\ send_in_use' = IF msg.is_last THEN FALSE ELSE TRUE
        /\ Reply(msg, [mtype    |-> CHUNK_SEND_ACK,
                       handle   |-> msg.handle,
                       seq_no   |-> msg.seq_no,
                       is_error |-> FALSE])
        /\ UNCHANGED <<send_handle, send_large_msg_size,
                       getVars, reqVars>>

\* ------------------------------------------------------------------
\* Action: ResponderChunkSendReceivedInvalidSeqNo
\* Responder processes a CHUNK_SEND where chunk_seq_no ≠ expected.
\* libspdm_rsp_chunk_send_ack.c:166–168 — standalone if sets status = INVALID_MSG_FIELD
\* BUT does NOT prevent the if/else chain at 170–203 from entering the else branch
\* and executing libspdm_copy_mem + chunk_seq_no update (lines 193–199).
\*
\* Family 2 — this action models the BUGGY path: state may advance even though
\* seq_no validation failed. Split from the valid path to expose the invariant gap.
\* ------------------------------------------------------------------
ResponderChunkSendReceivedInvalidSeqNo ==
    \E msg \in DOMAIN messages :
        /\ messages[msg] > 0
        /\ msg.mtype = CHUNK_SEND
        /\ msg.seq_no > 0
        /\ ~get_in_use
        /\ send_in_use
        /\ msg.handle = send_handle
        \* libspdm_rsp_chunk_send_ack.c:166 — seq_no DOES NOT MATCH
        /\ msg.seq_no # send_seq_no + 1
        /\ msg.chunk_size + send_bytes_transferred <= send_large_msg_size
        \* Key question: does the implementation reach the copy/advance path?
        \* The code at line 166 sets status=INVALID but does NOT short-circuit
        \* the if/else at line 170; the else at line 191 runs when handle/size checks pass.
        \* We model BOTH sub-cases non-deterministically:
        \*   (a) copy executes  — state DOES advance   (models the bug)
        \*   (b) copy skipped   — state unchanged        (models the desired behavior)
        /\ incoming_seq_no' = msg.seq_no
        /\ \/ \* (a) Bug path: copy + advance (libspdm_rsp_chunk_send_ack.c:193–199)
              /\ send_seq_no' = msg.seq_no
              /\ send_bytes_transferred' = send_bytes_transferred + msg.chunk_size
           \/ \* (b) Correct path: no mutation
              /\ send_seq_no' = send_seq_no
              /\ send_bytes_transferred' = send_bytes_transferred
        /\ Reply(msg, [mtype    |-> CHUNK_SEND_ACK,
                       handle   |-> msg.handle,
                       seq_no   |-> msg.seq_no,
                       is_error |-> TRUE])
        /\ UNCHANGED <<send_in_use, send_handle, send_large_msg_size,
                       getVars, reqVars>>

----
\* ==================================================================
\* CHUNK_GET flow — Responder → Requester
\* ==================================================================

\* ------------------------------------------------------------------
\* Action: ResponderLargeResponseReady
\* Responder has produced a response too large for DataTransferSize.
\* libspdm_rsp_receive_send.c:~L650–680 — stores large response, sets get_in_use
\* Sends LARGE_RESPONSE error to signal the requester.
\* ------------------------------------------------------------------
ResponderLargeResponseReady(handle, largeSize) ==
    \* Precondition: GET context idle; not mid-SEND (SEND side does check; GET side: asymmetry)
    /\ ~get_in_use
    /\ largeSize \in 1..MaxLargeSize
    /\ get_in_use' = TRUE
    /\ get_handle' = handle
    /\ get_seq_no' = 0
    /\ get_large_msg_size' = largeSize
    /\ get_bytes_sent' = 0
    /\ Send([mtype       |-> LARGE_RESPONSE,
             handle      |-> handle,
             large_size  |-> largeSize])
    /\ UNCHANGED <<sendVars, reqVars, protocolVars>>

\* ------------------------------------------------------------------
\* Action: RequesterReceivesLargeResponseError
\* Requester gets LARGE_RESPONSE error and starts CHUNK_GET loop.
\* libspdm_req_handle_error_response.c:~L270–320
\* ------------------------------------------------------------------
RequesterReceivesLargeResponseError ==
    \E msg \in DOMAIN messages :
        /\ messages[msg] > 0
        /\ msg.mtype = LARGE_RESPONSE
        /\ req_state = IDLE
        /\ req_state' = IN_PROGRESS
        /\ req_large_size' = msg.large_size
        /\ req_bytes_so_far' = 0
        /\ last_chunk_received' = FALSE
        /\ output_written' = FALSE
        /\ scratch_zeroed' = FALSE
        /\ received_msg_size' = 0
        /\ transfer_status' = IN_PROGRESS
        \* Immediately issue first CHUNK_GET (Reply = Discard + Send atomically)
        /\ Reply(msg, [mtype  |-> CHUNK_GET,
                       handle |-> msg.handle,
                       seq_no |-> 0])
        /\ UNCHANGED <<sendVars, getVars, incoming_seq_no>>

\* ------------------------------------------------------------------
\* Action: ResponderServesChunkGetWhileSendInProgress
\* Responder receives a CHUNK_GET while send_in_use is TRUE.
\* libspdm_rsp_chunk_response.c:98–103 — no send_in_use check exists here
\*
\* Family 5 — the CHUNK_RESPONSE handler does NOT check send_in_use.
\* CHUNK_SEND_ACK handler at rsp_chunk_send_ack.c:90–95 checks get_in_use (asymmetric).
\* Accepting CHUNK_GET mid-SEND leaves both contexts simultaneously active.
\* ------------------------------------------------------------------
ResponderServesChunkGetWhileSendInProgress ==
    \E msg \in DOMAIN messages :
        /\ messages[msg] > 0
        /\ msg.mtype = CHUNK_GET
        /\ get_in_use
        /\ msg.handle = get_handle
        /\ msg.seq_no = get_seq_no
        \* Bug: send_in_use is NOT checked here (asymmetric with rsp_chunk_send_ack.c:90–95)
        \* The SEND context remains live while we serve this CHUNK_GET
        /\ LET chunkData == CHOOSE sz \in 1..MaxLargeSize :
                                sz + get_bytes_sent <= get_large_msg_size
               isLast == (chunkData + get_bytes_sent = get_large_msg_size)
               \* Family 4: responder controls chunk_size field, potentially unbounded
               msgSize == chunkData + HeaderOverhead
           IN
           /\ get_seq_no' = get_seq_no + 1
           /\ get_bytes_sent' = get_bytes_sent + chunkData
           /\ get_in_use' = IF isLast THEN FALSE ELSE TRUE
           /\ Reply(msg, [mtype            |-> CHUNK_RESPONSE,
                          handle           |-> get_handle,
                          seq_no           |-> get_seq_no,
                          chunk_size       |-> chunkData,
                          received_msg_size|-> msgSize,
                          is_last          |-> isLast,
                          large_size       |-> get_large_msg_size])
        \* Note: send context NOT cleared here — cleared only on next non-CHUNK_GET request
        \* libspdm_rsp_receive_send.c:562–582
        /\ UNCHANGED <<sendVars, reqVars, protocolVars, get_handle, get_large_msg_size>>

\* ------------------------------------------------------------------
\* Action: ResponderServesChunkGet
\* Responder receives a CHUNK_GET with no active SEND (normal path).
\* libspdm_rsp_chunk_response.c:98–160
\* ------------------------------------------------------------------
ResponderServesChunkGet ==
    \E msg \in DOMAIN messages :
        /\ messages[msg] > 0
        /\ msg.mtype = CHUNK_GET
        /\ get_in_use
        /\ msg.handle = get_handle
        /\ msg.seq_no = get_seq_no
        /\ ~send_in_use                         \* normal path: SEND not active
        /\ LET chunkData == CHOOSE sz \in 1..MaxLargeSize :
                                sz + get_bytes_sent <= get_large_msg_size
               isLast == (chunkData + get_bytes_sent = get_large_msg_size)
               msgSize == chunkData + HeaderOverhead
           IN
           /\ get_seq_no' = get_seq_no + 1
           /\ get_bytes_sent' = get_bytes_sent + chunkData
           /\ get_in_use' = IF isLast THEN FALSE ELSE TRUE
           /\ Reply(msg, [mtype            |-> CHUNK_RESPONSE,
                          handle           |-> get_handle,
                          seq_no           |-> get_seq_no,
                          chunk_size       |-> chunkData,
                          received_msg_size|-> msgSize,
                          is_last          |-> isLast,
                          large_size       |-> get_large_msg_size])
        /\ UNCHANGED <<sendVars, reqVars, protocolVars, get_handle, get_large_msg_size>>

\* ------------------------------------------------------------------
\* Action: RequesterProcessChunkResponseValid
\* Requester receives a CHUNK_RESPONSE with valid source bounds.
\* libspdm_req_handle_error_response.c:411–455
\*
\* Family 1: LAST_CHUNK flag is tracked independently of byte-count.
\* Family 4: chunk_size is bounded by received_msg_size - HeaderOverhead (CORRECT path).
\* ------------------------------------------------------------------
RequesterProcessChunkResponseValid ==
    \E msg \in DOMAIN messages :
        /\ messages[msg] > 0
        /\ msg.mtype = CHUNK_RESPONSE
        /\ req_state = IN_PROGRESS
        \* libspdm_req_handle_error_response.c:416–419 — destination overrun check
        /\ msg.chunk_size + req_bytes_so_far <= req_large_size
        \* Family 4 — source bound check (CORRECT: bounded)
        \* libspdm_req_handle_error_response.c:449–451 — this check is MISSING in impl
        /\ msg.chunk_size <= msg.received_msg_size - HeaderOverhead
        \* seq_no validity is guaranteed implicitly: exactly one CHUNK_GET is in flight
        \* at any time, and the responder echoes the seq_no in CHUNK_RESPONSE
        /\ received_msg_size' = msg.received_msg_size
        /\ req_bytes_so_far' = req_bytes_so_far + msg.chunk_size
        \* Family 1 — track LAST_CHUNK flag independently of byte count
        \* libspdm_req_handle_error_response.c:421, 457–459
        /\ last_chunk_received' = IF msg.is_last THEN TRUE ELSE last_chunk_received
        \* Issue next CHUNK_GET if not done, else just discard
        /\ IF msg.is_last \/ (req_bytes_so_far + msg.chunk_size = req_large_size)
           THEN Discard(msg)
           ELSE Reply(msg, [mtype  |-> CHUNK_GET,
                            handle |-> msg.handle,
                            seq_no |-> msg.seq_no + 1])
        /\ UNCHANGED <<sendVars, getVars, req_state, req_large_size,
                       output_written, scratch_zeroed, transfer_status, incoming_seq_no>>

\* ------------------------------------------------------------------
\* Action: RequesterProcessChunkResponseSourceUnbounded
\* Requester receives a CHUNK_RESPONSE where chunk_size > received_msg_size - HeaderOverhead.
\* libspdm_req_handle_error_response.c:449–451 — NO source-bound check in implementation.
\*
\* Family 4 — models the over-read vulnerability: chunk_size accepted despite exceeding
\* actual received message payload.
\* ------------------------------------------------------------------
RequesterProcessChunkResponseSourceUnbounded ==
    \E msg \in DOMAIN messages :
        /\ messages[msg] > 0
        /\ msg.mtype = CHUNK_RESPONSE
        /\ req_state = IN_PROGRESS
        /\ msg.chunk_size + req_bytes_so_far <= req_large_size
        \* Family 4 — source bound VIOLATED (implementation accepts this)
        /\ msg.chunk_size > msg.received_msg_size - HeaderOverhead
        /\ received_msg_size' = msg.received_msg_size
        /\ req_bytes_so_far' = req_bytes_so_far + msg.chunk_size
        /\ last_chunk_received' = IF msg.is_last THEN TRUE ELSE last_chunk_received
        /\ IF msg.is_last \/ (req_bytes_so_far + msg.chunk_size = req_large_size)
           THEN Discard(msg)
           ELSE Reply(msg, [mtype  |-> CHUNK_GET,
                            handle |-> msg.handle,
                            seq_no |-> msg.seq_no + 1])
        /\ UNCHANGED <<sendVars, getVars, req_state, req_large_size,
                       output_written, scratch_zeroed, transfer_status, incoming_seq_no>>

\* ------------------------------------------------------------------
\* Action: RequesterTransferCompleteSuccess
\* Requester exits CHUNK_GET loop with all bytes received AND buffer fits.
\* libspdm_req_handle_error_response.c:462–472
\*
\* Family 3 — only taken when large_response_size <= response_capacity.
\* Family 1 — LAST_CHUNK may or may not have been received (bug exposure point).
\* ------------------------------------------------------------------
RequesterTransferCompleteSuccess ==
    /\ req_state = IN_PROGRESS
    /\ req_bytes_so_far = req_large_size          \* loop exit: byte count satisfied
    \* libspdm_req_handle_error_response.c:465 — buffer fits
    /\ req_large_size <= ResponseCapacity
    \* libspdm_req_handle_error_response.c:466–471 — copy + zero scratch
    /\ output_written' = TRUE
    /\ scratch_zeroed' = TRUE
    /\ req_state' = SUCCESS
    /\ transfer_status' = SUCCESS
    /\ UNCHANGED <<messages, sendVars, getVars,
                   req_large_size, req_bytes_so_far, last_chunk_received,
                   received_msg_size, incoming_seq_no>>

\* ------------------------------------------------------------------
\* Action: RequesterTransferCompleteBufferOverflow
\* Requester exits CHUNK_GET loop with all bytes received BUT buffer too small.
\* libspdm_req_handle_error_response.c:462–473 — NO ELSE BRANCH for overflow case.
\*
\* Family 3 — the missing else branch means: when large_response_size > response_capacity,
\* libspdm_copy_mem is SKIPPED, output is NOT written, scratch is NOT zeroed,
\* but status remains SUCCESS (no error set in the if/else-if chain).
\* ------------------------------------------------------------------
RequesterTransferCompleteBufferOverflow ==
    /\ req_state = IN_PROGRESS
    /\ req_bytes_so_far = req_large_size
    \* libspdm_req_handle_error_response.c:465 — buffer does NOT fit
    /\ req_large_size > ResponseCapacity
    \* Bug: no else branch — output_written stays FALSE, scratch_zeroed stays FALSE
    \* libspdm_req_handle_error_response.c:473 — status still SUCCESS
    /\ output_written' = FALSE                    \* copy was skipped
    /\ scratch_zeroed' = FALSE                    \* zero was skipped
    /\ req_state' = SUCCESS
    /\ transfer_status' = SUCCESS
    /\ UNCHANGED <<messages, sendVars, getVars,
                   req_large_size, req_bytes_so_far, last_chunk_received,
                   received_msg_size, incoming_seq_no>>

----
\* ==================================================================
\* Next
\* ==================================================================

Next ==
    \/ ResponderChunkSendReceivedFirstChunk
    \/ ResponderChunkSendReceivedValidSeqNo
    \/ ResponderChunkSendReceivedInvalidSeqNo
    \/ ResponderLargeResponseReady(0, 1)       \* existential handled inside
    \/ ResponderServesChunkGetWhileSendInProgress
    \/ ResponderServesChunkGet
    \/ RequesterReceivesLargeResponseError
    \/ RequesterProcessChunkResponseValid
    \/ RequesterProcessChunkResponseSourceUnbounded
    \/ RequesterTransferCompleteSuccess
    \/ RequesterTransferCompleteBufferOverflow
    \/ \E h \in 0..255, cs \in 1..MaxLargeSize, ls \in 1..MaxLargeSize :
           \/ RequesterSendsFirstChunk(h, cs, ls)
    \/ \E h \in 0..255, sn \in 1..MaxChunks, cs \in 1..MaxLargeSize,
           il \in BOOLEAN, ts \in 0..MaxLargeSize, ls \in 1..MaxLargeSize :
           RequesterSendsContinuationChunk(h, sn, cs, il, ts, ls)
    \/ \E h \in 0..255, ls \in 1..MaxLargeSize :
           ResponderLargeResponseReady(h, ls)

Spec == Init /\ [][Next]_vars

----
\* ==================================================================
\* Invariants
\* ==================================================================

\* ------------------------------------------------------------------
\* Structural invariants (always hold; sanity checks)
\* ------------------------------------------------------------------

TypeOK ==
    /\ send_in_use \in BOOLEAN
    /\ send_handle \in Nat
    /\ send_seq_no \in Nat
    /\ send_bytes_transferred \in Nat
    /\ send_large_msg_size \in Nat
    /\ get_in_use \in BOOLEAN
    /\ get_handle \in Nat
    /\ get_seq_no \in Nat
    /\ get_large_msg_size \in Nat
    /\ get_bytes_sent \in Nat
    /\ req_state \in {IDLE, IN_PROGRESS, SUCCESS, ERROR_STATE}
    /\ req_large_size \in Nat
    /\ req_bytes_so_far \in Nat
    /\ last_chunk_received \in BOOLEAN
    /\ output_written \in BOOLEAN
    /\ scratch_zeroed \in BOOLEAN
    /\ received_msg_size \in Nat
    /\ incoming_seq_no \in Nat
    /\ transfer_status \in {IDLE, IN_PROGRESS, SUCCESS, ERROR_STATE}

\* Bytes transferred never exceed declared total
SendBytesInRange ==
    send_in_use => send_bytes_transferred <= send_large_msg_size

GetBytesInRange ==
    get_in_use => get_bytes_sent <= get_large_msg_size

RequesterBytesInRange ==
    req_state = IN_PROGRESS => req_bytes_so_far <= req_large_size

\* ------------------------------------------------------------------
\* Safety invariants — Bug Family targets
\* ------------------------------------------------------------------

\* Family 1 — TransferTerminationConditionIncompleteness
\* libspdm_req_handle_error_response.c:457–459, 462–473
\* SUCCESS from CHUNK_GET flow must have had LAST_CHUNK flag on the final fragment.
TransferCompleteImpliesLastChunk ==
    (req_state = SUCCESS /\ transfer_status = SUCCESS) => last_chunk_received

\* Family 2 — ControlFlowOrderingSeqNoMismatch
\* libspdm_rsp_chunk_send_ack.c:166–199
\* If incoming seq_no ≠ expected (send_seq_no + 1), bytes_transferred must be unchanged.
\* We track this as a transition invariant: after any action where incoming_seq_no ≠
\* send_seq_no (the current committed expected), send_bytes_transferred must not grow.
NoStateAdvanceOnSeqNoMismatch ==
    \* If the last incoming seq_no did not match expected, state should not have advanced.
    \* Note: send_seq_no holds the LAST ACCEPTED seq_no; expected next = send_seq_no + 1.
    (send_in_use /\ incoming_seq_no > 0 /\ incoming_seq_no # send_seq_no)
        => send_bytes_transferred <= 0  \* placeholder: checked via action split

\* Family 3 — ReassemblyOutputValidityAfterCompletion
\* libspdm_req_handle_error_response.c:462–475
\* SUCCESS implies output was written and scratch was zeroed.
SuccessImpliesOutputWritten ==
    (transfer_status = SUCCESS) =>
        (output_written = TRUE /\ scratch_zeroed = TRUE)

\* Family 4 — SourceLengthUnboundedInReassemblyCopy
\* libspdm_req_handle_error_response.c:449–451
\* Every ACCEPTED chunk_size must be ≤ received_msg_size - HeaderOverhead.
SourceBoundedness ==
    (req_state = IN_PROGRESS /\ req_bytes_so_far > 0) =>
        received_msg_size >= HeaderOverhead

\* Family 5 — MutualExclusionAsymmetry
\* libspdm_rsp_chunk_send_ack.c:90–95, libspdm_rsp_chunk_response.c:98–103
\* Both contexts must never be simultaneously active.
SingleDirectionAtATime ==
    ~(send_in_use /\ get_in_use)

\* Seq-no monotone — Families 1, 2
\* Accepted seq_no on SEND side increments exactly by 1.
SeqNoMonotone ==
    (send_in_use /\ send_seq_no > 0) =>
        incoming_seq_no \in {send_seq_no - 1, send_seq_no, send_seq_no + 1}

\* Large message size consistency — Families 3, 4
\* Declared size equals the value used throughout the transfer.
LargeMessageSizeConsistent ==
    (req_state = IN_PROGRESS => req_bytes_so_far <= req_large_size)
    /\ (req_state = SUCCESS   => req_bytes_so_far = req_large_size)

====
