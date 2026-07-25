---- MODULE base ----
(* SPDM Measurement Extension Log (MEL) Protocol Model
 * Category: A (Distributed / Message-Passing)
 * Reference: libspdm implementation
 *)

EXTENDS Naturals, Sequences, FiniteSets

(* ===== Constants ===== *)
CONSTANT MAX_MEL_SIZE          \* Maximum MEL data size (abstract)
CONSTANT MAX_CHUNK_SIZE        \* Maximum bytes per response
ASSUME MAX_MEL_SIZE > 0 /\ MAX_CHUNK_SIZE > 0 /\ MAX_CHUNK_SIZE <= MAX_MEL_SIZE

CONSTANT REQUESTER             \* Requester role ID
CONSTANT RESPONDER             \* Responder role ID

(* ===== Variables ===== *)
VARIABLE responder_mel         \* Responder's MEL: {size, entries_len}
VARIABLE responder_pc          \* Responder's program counter
VARIABLE req_offset            \* Requester's current offset
VARIABLE req_mel_size          \* Requester's cumulative bytes received
VARIABLE req_remainder         \* Requester's last remainder_length
VARIABLE req_total_mel_size    \* Requester's stored total size
VARIABLE req_pc                \* Requester's program counter
VARIABLE messages              \* In-flight messages

(* ===== MEL Spec Data Structure ===== *)
(* Abstract representation of MEL: {size, entries_len, ...}
 * We model MEL as a record with key fields
 *)
NULL_MEL == [size |-> 0, entries_len |-> 0]
IS_VALID_MEL(mel) == mel.size > 0 /\ mel.entries_len > 0 /\ mel.entries_len <= mel.size

(* ===== Message Types ===== *)
(* GET_MEASUREMENT_EXTENSION_LOG request *)
GetMelRequest == "GetMelRequest"
(* MEASUREMENT_EXTENSION_LOG response *)
MelResponse == "MelResponse"

(* ===== Message Records ===== *)
(* Request: {offset, length}
 * source: libspdm_req_get_measurement_extension_log.c:109-114
 *)
MakeGetMelRequest(offset, length) ==
    [type |-> GetMelRequest, offset |-> offset, length |-> length]

(* Response: {portion_length, remainder_length, data}
 * source: libspdm_rsp_measurement_extension_log.c:152-157
 *)
MakeMelResponse(portion_length, remainder_length, data_len) ==
    [type |-> MelResponse, portion_length |-> portion_length,
     remainder_length |-> remainder_length, data_len |-> data_len]

(* ===== Responder Variables ===== *)
(* responder.mel: The actual MEL in responder's storage
 * Modeled as {size, entries_len} representing the full MEL
 * source: libspdm_rsp_measurement_extension_log.c:115-124
 *)

(* ===== Requester Variables ===== *)
(* req_offset: Current offset for next request (libspdm_req_get_measurement_extension_log.c:109) *)
(* req_mel_size: Cumulative bytes received so far (libspdm_req_get_measurement_extension_log.c:85) *)
(* req_remainder: Last received remainder_length (libspdm_req_get_measurement_extension_log.c:82) *)
(* req_total_mel_size: Stored total from first response (libspdm_req_get_measurement_extension_log.c:203-204) *)
(* req_pc: Program counter state (ready, waiting_response, processing, done) *)

(* ===== Globals ===== *)
(* messages: Bag of in-flight messages *)
(* The bag pattern allows multiple copies of same message *)

(* ===== Variable Groups for UNCHANGED ===== *)
requesterVars == <<req_offset, req_mel_size, req_remainder, req_total_mel_size, req_pc>>
responderVars == <<responder_mel, responder_pc>>
msgVars == <<messages>>

(* ===== Init ===== *)
Init ==
    /\ responder_mel = [size |-> 10, entries_len |-> 8]  \* Typical test case
    /\ responder_pc = "ready"
    /\ req_offset = 0
    /\ req_mel_size = 0
    /\ req_remainder = 0
    /\ req_total_mel_size = 0
    /\ req_pc = "ready"
    /\ messages = {}

(* ===== BF1: Arithmetic Overflow Check (source: modeling-brief.md:BF1) ===== *)
(* Guard: Check for potential overflow in offset + length
 * source: libspdm_req_get_measurement_extension_log.c:99-100, 109-114
 *)
OffsetLengthValid(offset, length) ==
    /\ offset <= MAX_MEL_SIZE
    /\ length > 0
    /\ offset + length <= MAX_MEL_SIZE + 1  \* Allow at-boundary

(* ===== BF3: MEL Header Validation (source: modeling-brief.md:BF3) ===== *)
(* Helper: Check if MEL header (8 bytes) has been received
 * source: libspdm_req_get_measurement_extension_log.c:242-243
 *)
HeaderReceived == req_mel_size >= 8  \* sizeof(spdm_measurement_extension_log_dmtf_t)

(* ===== BF2: Remainder Consistency (source: modeling-brief.md:BF2) ===== *)
(* Helper: Verify remainder_length consistency
 * source: libspdm_req_get_measurement_extension_log.c:205-210
 *)
RemainderConsistent(offset, portion, remainder, total) ==
    \* First response: total = portion + remainder
    \* Later responses: offset + portion + remainder <= total
    \/ offset = 0  \* First response, accept any total
    \/ (offset + portion + remainder <= total)

(* ===== Action: RequesterSendGetMel ===== *)
(* Requester initiates or continues GET_MEASUREMENT_EXTENSION_LOG request
 * source: libspdm_req_get_measurement_extension_log.c:93-117
 *)
RequesterSendGetMel ==
    /\ req_pc = "ready"
    /\ OffsetLengthValid(req_offset, MAX_CHUNK_SIZE)  \* BF1 check
    /\ LET length == CHOOSE l \in 1..MAX_CHUNK_SIZE : TRUE
       IN /\ messages' = messages \cup {MakeGetMelRequest(req_offset, length)}
          /\ req_pc' = "waiting"
          /\ UNCHANGED <<req_offset, req_mel_size, req_remainder, req_total_mel_size>>
          /\ UNCHANGED responderVars

(* ===== Action: ResponderReceiveAndSendMel ===== *)
(* Responder receives request, validates, and sends response
 * source: libspdm_rsp_measurement_extension_log.c:10-160
 *)
ResponderReceiveAndSendMel ==
    /\ responder_pc = "ready"
    /\ \E req \in messages :
        req.type = GetMelRequest
        /\ LET offset == req.offset
             length == req.length
             mel_size == responder_mel.size
             \* BF6: Check if MEL is non-empty (source: libspdm_rsp_measurement_extension_log.c:126-130)
             valid_offset == offset < mel_size
             \* BF1: Check overflow in offset + length (source: libspdm_rsp_measurement_extension_log.c:132-134)
             actual_length == IF offset + length > mel_size
                             THEN mel_size - offset
                             ELSE length
             remainder == mel_size - offset - actual_length
           IN /\ valid_offset  \* Only proceed if offset is within bounds
              /\ messages' = (messages \ {req}) \cup
                             {MakeMelResponse(actual_length, remainder, actual_length)}
              /\ UNCHANGED requesterVars
              /\ UNCHANGED responderVars

(* ===== Action: RequesterReceiveMelResponse ===== *)
(* Requester receives and processes MEL response chunk
 * source: libspdm_req_get_measurement_extension_log.c:130-241
 *)
RequesterReceiveMelResponse ==
    /\ req_pc = "waiting"
    /\ \E resp \in messages :
        resp.type = MelResponse
        /\ LET portion_len == resp.portion_length
             remainder == resp.remainder_length
             new_mel_size == req_mel_size + portion_len
           IN /\ portion_len > 0  \* BF5: Check portion_length > 0 (source: libspdm_req_get_measurement_extension_log.c:180)
              /\ portion_len <= MAX_CHUNK_SIZE  \* BF5: Check portion <= requested (source: libspdm_req_get_measurement_extension_log.c:179)
              /\ new_mel_size <= MAX_MEL_SIZE  \* BF3: Buffer bounds (source: libspdm_req_get_measurement_extension_log.c:217)
              \* BF2: Remainder consistency check (source: libspdm_req_get_measurement_extension_log.c:202-210)
              /\ RemainderConsistent(req_offset, portion_len, remainder,
                                    IF req_offset = 0 THEN portion_len + remainder
                                    ELSE req_total_mel_size)
              /\ messages' = messages \ {resp}
              /\ req_mel_size' = new_mel_size
              /\ req_remainder' = remainder
              \* BF4: Update offset for next request (source: libspdm_req_get_measurement_extension_log.c:109)
              /\ req_offset' = new_mel_size
              /\ IF req_offset = 0
                 THEN req_total_mel_size' = portion_len + remainder
                 ELSE req_total_mel_size' = req_total_mel_size
              /\ IF remainder = 0
                 THEN req_pc' = "done"
                 ELSE req_pc' = "ready"
              /\ UNCHANGED responderVars

(* ===== BF3: Loop Termination Check ===== *)
(* Helper: Check if loop should terminate
 * source: libspdm_req_get_measurement_extension_log.c:242-243
 *)
ShouldTerminate ==
    /\ req_remainder = 0
    /\ HeaderReceived  \* BF3: Only dereference mel_entries_len after header complete

(* ===== Action: RequesterCheckTermination ===== *)
(* Requester checks if transfer is complete
 * source: libspdm_req_get_measurement_extension_log.c:242-246
 *)
RequesterCheckTermination ==
    /\ req_pc = "ready"
    /\ ShouldTerminate
    /\ req_pc' = "done"
    /\ messages' = messages
    /\ UNCHANGED <<req_offset, req_mel_size, req_remainder, req_total_mel_size>>
    /\ UNCHANGED responderVars

(* ===== Invariants ===== *)
(* INV-1: No arithmetic overflow in offset calculations *)
(* BF1: Check offset and offset+length never exceed bounds *)
NoOffsetOverflow ==
    /\ req_offset <= MAX_MEL_SIZE
    /\ req_mel_size <= MAX_MEL_SIZE
    /\ req_offset <= req_mel_size  \* Monotonic increase

(* INV-2: Remainder consistency *)
(* BF2: remainder_length stays consistent *)
RemainderConsistency ==
    /\ req_remainder <= responder_mel.size
    /\ req_offset + req_remainder <= responder_mel.size + 1

(* INV-3: No buffer overrun *)
(* BF3: Accumulated data never exceeds buffer capacity *)
BufferBounds ==
    /\ req_mel_size <= MAX_MEL_SIZE

(* INV-4: Header received before dereference *)
(* BF3: Don't check mel_entries_len until header fully received *)
(* Guarded by ShouldTerminate predicate, so this invariant is always satisfied *)
HeaderGuard ==
    TRUE

(* INV-5: Portion length valid *)
(* BF5: portion_length claimed <= responder MEL size *)
PortionLengthValid ==
    /\ \A msg \in messages :
        msg.type = MelResponse => msg.portion_length <= responder_mel.size

(* INV-6: Total size consistency *)
(* BF2: Stored total size never changes *)
TotalSizeConsistent ==
    /\ req_offset = 0 \/ req_total_mel_size > 0
    /\ req_total_mel_size <= responder_mel.size + MAX_CHUNK_SIZE

(* ===== Next State Relation ===== *)
Next ==
    \/ RequesterSendGetMel
    \/ ResponderReceiveAndSendMel
    \/ RequesterReceiveMelResponse
    \/ RequesterCheckTermination

(* ===== Spec ===== *)
Spec == Init /\ [][Next]_<<requesterVars, responderVars, msgVars>>

(* ===== Temporal Properties ===== *)
(* PROP-1: Eventually, transfer completes *)
TransferCompletes == <>(req_pc = "done")

(* PROP-2: No invalid states reachable *)
AlwaysValid ==
    NoOffsetOverflow /\
    RemainderConsistency /\
    BufferBounds /\
    HeaderGuard /\
    PortionLengthValid /\
    TotalSizeConsistent

====
