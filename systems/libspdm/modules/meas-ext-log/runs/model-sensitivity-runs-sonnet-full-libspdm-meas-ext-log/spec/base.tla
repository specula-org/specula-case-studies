---------------------------- MODULE base ----------------------------
(*
 * SPDM Measurement Extension Log (MEL) paged-transfer protocol
 *
 * Targets:
 *   Family 1 — multi-chunk MEL consistency (no snapshot on Responder)
 *   Family 2 — mel_spec negotiation validation bypass
 *
 * System category: A (Distributed / Message-Passing)
 * Reference: DMTF DSP0274 SPDM 1.3+, GET_MEASUREMENT_EXTENSION_LOG
 *)

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    MEL_SIZES,        \* set of possible total MEL byte sizes {Nat}
    MAX_CHUNK,        \* max portion_length per response (models SPDM_MAX_MEL_SIZE cap)
    MEL_SPEC_DMTF,    \* SPDM_MEL_SPECIFICATION_DMTF = 1  (spdm.h:962)
    MEL_SPEC_INVALID  \* hypothetical unrecognised wire value (e.g. 3 = 0x03)

\* sizeof(spdm_measurement_extension_log_dmtf_t) = 16 bytes  (spdm.h:884-891)
MEL_HEADER_SIZE == 16

Min(a, b) == IF a <= b THEN a ELSE b

\* ---------- state-space constants ----------
CS_INIT       == "init"        \* before NEGOTIATE_ALGORITHMS
CS_NEGOTIATED == "negotiated"  \* after successful negotiation

TS_IDLE    == "idle"     \* no GET_MEL in progress
TS_PENDING == "pending"  \* at least one GET_MEL round-trip outstanding
TS_DONE    == "done"     \* all chunks received

MEL_SPEC_UNSET == 0  \* not negotiated

\* =============================================================
\* Variables
\* =============================================================

VARIABLES
    \* --- connection/negotiation ---
    conn_state,       \* CS_INIT | CS_NEGOTIATED
    mel_spec_conn,    \* negotiated mel_spec: 0 | MEL_SPEC_DMTF | MEL_SPEC_INVALID
    has_session_cap,  \* BOOL: KEY_EX_CAP || PSK_CAP present (Family 2 gate)

    \* --- Responder MEL state (Family 1) ---
    mel_generation,   \* Nat: incremented each time MEL content changes
    mel_size,         \* Nat: current total MEL byte size (from current generation)

    \* --- Requester transfer state (Family 1) ---
    transfer_state,    \* TS_IDLE | TS_PENDING | TS_DONE
    mel_offset,        \* bytes accumulated so far in the caller buffer
    mel_snapshot_gen,  \* generation captured at first-chunk time (set by Requester)
    first_portion_len, \* portion_length from the first chunk response

    \* --- in-flight channel (synchronous req/rsp) ---
    req_pending,      \* BOOL
    req_offset,       \* offset field of the in-flight GET_MEL request
    req_length,       \* length field of the in-flight GET_MEL request
    rsp_pending,      \* BOOL
    rsp_portion_len,  \* portion_length of the in-flight response
    rsp_remainder,    \* remainder_length of the in-flight response
    rsp_generation    \* which mel_generation the Responder served from

connVars     == <<conn_state, mel_spec_conn, has_session_cap>>
respVars     == <<mel_generation, mel_size>>
reqVars      == <<transfer_state, mel_offset, mel_snapshot_gen, first_portion_len>>
chanVars     == <<req_pending, req_offset, req_length,
                  rsp_pending, rsp_portion_len, rsp_remainder, rsp_generation>>

vars == <<connVars, respVars, reqVars, chanVars>>

\* =============================================================
\* Type invariant
\* =============================================================

TypeOK ==
    /\ conn_state \in {CS_INIT, CS_NEGOTIATED}
    /\ mel_spec_conn \in {MEL_SPEC_UNSET, MEL_SPEC_DMTF, MEL_SPEC_INVALID}
    /\ has_session_cap \in BOOLEAN
    /\ mel_generation \in Nat
    /\ mel_size \in MEL_SIZES
    /\ transfer_state \in {TS_IDLE, TS_PENDING, TS_DONE}
    /\ mel_offset \in Nat
    /\ mel_snapshot_gen \in Nat
    /\ first_portion_len \in Nat
    /\ req_pending \in BOOLEAN
    /\ req_offset \in Nat
    /\ req_length \in Nat
    /\ rsp_pending \in BOOLEAN
    /\ rsp_portion_len \in Nat
    /\ rsp_remainder \in Nat
    /\ rsp_generation \in Nat

\* =============================================================
\* Init
\* =============================================================

Init ==
    /\ conn_state = CS_INIT
    /\ mel_spec_conn = MEL_SPEC_UNSET
    /\ has_session_cap \in BOOLEAN          \* non-det: models both capability profiles
    /\ mel_generation = 0
    /\ mel_size \in MEL_SIZES               \* non-det initial MEL size
    /\ transfer_state = TS_IDLE
    /\ mel_offset = 0
    /\ mel_snapshot_gen = 0
    /\ first_portion_len = 0
    /\ req_pending = FALSE
    /\ req_offset = 0
    /\ req_length = 0
    /\ rsp_pending = FALSE
    /\ rsp_portion_len = 0
    /\ rsp_remainder = 0
    /\ rsp_generation = 0

\* =============================================================
\* Action: NegotiateAlgorithmsWithSessionCap
\*
\* libspdm_req_negotiate_algorithms.c:663-697
\* KEY_EX_CAP || PSK_CAP is set → mel_spec validation at lines 681-696 FIRES
\* =============================================================

NegotiateAlgorithmsWithSessionCap(wire_val) ==
    \* libspdm_req_negotiate_algorithms.c:663-670: capability gate — passes
    /\ has_session_cap = TRUE
    /\ conn_state = CS_INIT
    \* libspdm_req_negotiate_algorithms.c:681-696: validation block executes
    /\ wire_val \in {MEL_SPEC_UNSET, MEL_SPEC_DMTF, MEL_SPEC_INVALID}
    /\ IF wire_val = MEL_SPEC_DMTF
       THEN \* line 687: DMTF value → accepted
            /\ mel_spec_conn' = MEL_SPEC_DMTF
            /\ conn_state' = CS_NEGOTIATED
       ELSE IF wire_val = MEL_SPEC_UNSET
            THEN \* line 692: zero → stored as 0
                 /\ mel_spec_conn' = MEL_SPEC_UNSET
                 /\ conn_state' = CS_NEGOTIATED
            ELSE \* line 688: unrecognised → LIBSPDM_STATUS_INVALID_MSG_FIELD, negotiation aborted
                 /\ mel_spec_conn' = mel_spec_conn   \* not updated (error path)
                 /\ conn_state' = CS_INIT
    /\ UNCHANGED <<has_session_cap, respVars, reqVars, chanVars>>

\* =============================================================
\* Action: NegotiateAlgorithmsWithoutSessionCap
\*
\* libspdm_req_negotiate_algorithms.c:663-697
\* KEY_EX_CAP = 0 AND PSK_CAP = 0 → capability gate fails at line 663-670
\* Lines 681-696: ENTIRE VALIDATION BLOCK IS UNREACHABLE
\* libspdm_com_support.c:380-385: libspdm_mask_mel_specification defined but never called
\* Family 2: any wire_val including INVALID passes through without rejection
\* =============================================================

NegotiateAlgorithmsWithoutSessionCap(wire_val) ==
    \* libspdm_req_negotiate_algorithms.c:663-670: capability check — FAILS, block skipped
    /\ has_session_cap = FALSE
    /\ conn_state = CS_INIT
    /\ wire_val \in {MEL_SPEC_UNSET, MEL_SPEC_DMTF, MEL_SPEC_INVALID}
    \* Lines 681-696: SKIPPED — raw value stored without validation
    \* libspdm_rsp_algorithms.c:713-714: raw mel_specification stored before any masking
    /\ mel_spec_conn' = wire_val     \* unvalidated; MEL_SPEC_INVALID possible
    /\ conn_state' = CS_NEGOTIATED
    /\ UNCHANGED <<has_session_cap, respVars, reqVars, chanVars>>

\* =============================================================
\* Action: MelUpdate
\*
\* Models the Responder's underlying MEL changing between chunk requests.
\* libspdm_rsp_measurement_extension_log.c:113-114: spdm_mel = NULL; spdm_mel_len = 0
\* libspdm_rsp_measurement_extension_log.c:115-124: libspdm_measurement_extension_log_collection
\*   called FRESH on every request — no epoch/generation field in libspdm_context_t
\*   (no caching between requests: the Responder serves from whatever MEL exists at call time)
\* =============================================================

MelUpdate ==
    \* MEL may change at any time on the Responder side (no lock, no epoch guard)
    /\ mel_generation' = mel_generation + 1
    /\ mel_size' \in MEL_SIZES    \* new generation may have different byte length
    /\ UNCHANGED <<connVars, reqVars, chanVars>>

\* =============================================================
\* Action: SendGetMelFirstChunk
\*
\* libspdm_req_get_measurement_extension_log.c:93-118 (first do-loop iteration, offset=0)
\* Pre-send state checks: lines 52-77
\* NOTE: no mel_spec != 0 check before send (Family 3 / MelSpecPreSend)
\* =============================================================

SendGetMelFirstChunk ==
    \* libspdm_req_get_measurement_extension_log.c:52-54: version >= 1.3
    \* libspdm_req_get_measurement_extension_log.c:56-59: MEL_CAP check
    \* libspdm_req_get_measurement_extension_log.c:61-63: connection state >= NEGOTIATED
    /\ conn_state = CS_NEGOTIATED
    \* libspdm_req_get_measurement_extension_log.c:52-77: NO mel_spec != 0 guard
    /\ transfer_state = TS_IDLE
    /\ ~req_pending
    \* libspdm_req_get_measurement_extension_log.c:109-111: offset=0, length=MAX_CHUNK
    /\ req_pending' = TRUE
    /\ req_offset' = 0
    /\ req_length' = MAX_CHUNK
    /\ transfer_state' = TS_PENDING
    /\ UNCHANGED <<connVars, respVars, mel_offset, mel_snapshot_gen, first_portion_len,
                   rsp_pending, rsp_portion_len, rsp_remainder, rsp_generation>>

\* =============================================================
\* Action: RespondGetMelFirstChunk
\*
\* libspdm_rsp_measurement_extension_log.c:10-162 (offset=0 request)
\* KEY BUG (Family 1): fresh libspdm_measurement_extension_log_collection at lines 113-124
\* No snapshot saved; serves from mel_generation at the time of THIS request
\* =============================================================

RespondGetMelFirstChunk(portion_len) ==
    /\ req_pending
    /\ req_offset = 0
    /\ ~rsp_pending
    \* libspdm_rsp_measurement_extension_log.c:86-91: mel_spec != 0 check
    \* Responder DOES check; will error if mel_spec_conn = 0 (unlike Requester pre-send)
    /\ mel_spec_conn /= MEL_SPEC_UNSET
    \* libspdm_rsp_measurement_extension_log.c:113-114: no prior snapshot, reset pointers
    \* libspdm_rsp_measurement_extension_log.c:115-124: fresh collection → uses mel_generation NOW
    /\ portion_len \in 1..Min(req_length, mel_size)
    \* libspdm_rsp_measurement_extension_log.c:152-153: fill portion/remainder fields
    /\ rsp_pending' = TRUE
    /\ rsp_portion_len' = portion_len
    /\ rsp_remainder' = mel_size - portion_len
    /\ rsp_generation' = mel_generation   \* records which generation was served
    /\ req_pending' = FALSE
    /\ UNCHANGED <<connVars, respVars, reqVars, req_offset, req_length>>

\* =============================================================
\* Action: ProcessGetMelFirstChunkResp
\*
\* libspdm_req_get_measurement_extension_log.c:148-243 (first chunk)
\* Records mel_snapshot_gen from the response generation field.
\* =============================================================

ProcessGetMelFirstChunkResp ==
    /\ transfer_state = TS_PENDING
    /\ mel_offset = 0
    /\ rsp_pending
    \* libspdm_req_get_measurement_extension_log.c:202-204: record total length
    /\ mel_offset' = rsp_portion_len
    \* Capture the generation from the first response (not tracked in real code;
    \* we model it to check consistency against subsequent chunks)
    /\ mel_snapshot_gen' = rsp_generation
    /\ first_portion_len' = rsp_portion_len
    \* libspdm_req_get_measurement_extension_log.c:241-243: loop-continue condition
    \* BUG: measurement_extension_log->mel_entries_len read from buffer WITHOUT
    \*      first verifying mel_size_internal >= sizeof(spdm_measurement_extension_log_dmtf_t)
    \*      If rsp_portion_len < MEL_HEADER_SIZE, header bytes are not yet in buffer
    /\ IF rsp_remainder = 0
       THEN transfer_state' = TS_DONE   \* single-chunk MEL
       ELSE transfer_state' = TS_PENDING
    /\ rsp_pending' = FALSE
    /\ UNCHANGED <<connVars, respVars, req_pending, req_offset, req_length,
                   rsp_portion_len, rsp_remainder, rsp_generation>>

\* =============================================================
\* Action: SendGetMelNextChunk
\*
\* libspdm_req_get_measurement_extension_log.c:93-118 (Nth iteration, offset>0)
\* =============================================================

SendGetMelNextChunk ==
    /\ transfer_state = TS_PENDING
    /\ mel_offset > 0    \* not the first chunk
    /\ ~req_pending
    /\ ~rsp_pending
    \* libspdm_req_get_measurement_extension_log.c:109,112-113: offset = mel_size_internal
    /\ req_pending' = TRUE
    /\ req_offset' = mel_offset
    /\ req_length' = MAX_CHUNK
    /\ UNCHANGED <<connVars, respVars, mel_offset, mel_snapshot_gen, first_portion_len,
                   transfer_state, rsp_pending, rsp_portion_len, rsp_remainder, rsp_generation>>

\* =============================================================
\* Action: RespondGetMelNextChunk
\*
\* libspdm_rsp_measurement_extension_log.c:10-162 (offset>0 request)
\* KEY BUG (Family 1): FRESH libspdm_measurement_extension_log_collection (lines 113-124)
\* mel_generation may have changed since chunk 1 (MelUpdate may have fired)
\* Responder has no memory of which generation served chunk 1
\* =============================================================

RespondGetMelNextChunk(portion_len) ==
    /\ req_pending
    /\ req_offset > 0
    /\ ~rsp_pending
    /\ mel_spec_conn /= MEL_SPEC_UNSET
    \* libspdm_rsp_measurement_extension_log.c:113-114: no snapshot — reset and re-collect
    \* libspdm_rsp_measurement_extension_log.c:115-124: fresh collection → mel_generation NOW
    \* mel_generation may differ from the generation that served chunk 1
    /\ req_offset < mel_size    \* libspdm_rsp_measurement_extension_log.c:126-129: offset check
    /\ portion_len \in 1..Min(req_length, mel_size - req_offset)
    /\ rsp_pending' = TRUE
    /\ rsp_portion_len' = portion_len
    /\ rsp_remainder' = mel_size - req_offset - portion_len
    /\ rsp_generation' = mel_generation   \* may differ from mel_snapshot_gen (the bug)
    /\ req_pending' = FALSE
    /\ UNCHANGED <<connVars, respVars, reqVars, req_offset, req_length>>

\* =============================================================
\* Action: ProcessGetMelNextChunkResp
\*
\* libspdm_req_get_measurement_extension_log.c:202-243 (Nth chunk, offset>0)
\* Requester does NOT check that rsp_generation == mel_snapshot_gen
\* (no generation/epoch concept in the implementation at all)
\* libspdm_req_get_measurement_extension_log.c:205-209: detects MEL shrinkage only
\* Growth (rsp_generation > mel_snapshot_gen, larger mel_size) silently accepted
\* =============================================================

ProcessGetMelNextChunkResp ==
    /\ transfer_state = TS_PENDING
    /\ mel_offset > 0
    /\ rsp_pending
    /\ ~req_pending
    \* libspdm_req_get_measurement_extension_log.c:233: mel_size_internal += portion_length
    /\ mel_offset' = mel_offset + rsp_portion_len
    \* libspdm_req_get_measurement_extension_log.c:241-243: loop-continue condition
    /\ IF rsp_remainder = 0
       THEN transfer_state' = TS_DONE
       ELSE transfer_state' = TS_PENDING
    /\ rsp_pending' = FALSE
    /\ UNCHANGED <<connVars, respVars, mel_snapshot_gen, first_portion_len,
                   req_pending, req_offset, req_length,
                   rsp_portion_len, rsp_remainder, rsp_generation>>

\* =============================================================
\* Next / Spec
\* =============================================================

Next ==
    \/ \E w \in {MEL_SPEC_UNSET, MEL_SPEC_DMTF, MEL_SPEC_INVALID} :
           NegotiateAlgorithmsWithSessionCap(w)
    \/ \E w \in {MEL_SPEC_UNSET, MEL_SPEC_DMTF, MEL_SPEC_INVALID} :
           NegotiateAlgorithmsWithoutSessionCap(w)
    \/ MelUpdate
    \/ SendGetMelFirstChunk
    \/ \E p \in 1..MAX_CHUNK : RespondGetMelFirstChunk(p)
    \/ ProcessGetMelFirstChunkResp
    \/ SendGetMelNextChunk
    \/ \E p \in 1..MAX_CHUNK : RespondGetMelNextChunk(p)
    \/ ProcessGetMelNextChunkResp

Spec == Init /\ [][Next]_vars

\* =============================================================
\* Invariants
\* =============================================================

\* ----- Safety: structural -----

ChannelOK ==
    \* At most one message in flight at a time on each direction
    /\ ~(req_pending /\ rsp_pending)

OffsetGrowth ==
    \* mel_offset never decreases once started
    transfer_state = TS_IDLE \/ mel_offset >= 0

\* ----- Safety: Family 1 — MelConsistency -----
\*
\* Brief §5: "All MEASUREMENT_EXTENSION_LOG portions in a single GET_MEL exchange
\* come from the same MEL generation."
\*
\* Violation: rsp_generation (the generation the Responder served for a next-chunk)
\* differs from mel_snapshot_gen (the generation it used for chunk 1).
\* This is only meaningful when a next-chunk response is in flight (rsp_pending,
\* mel_offset > 0 meaning we already processed chunk 1).

MelConsistency ==
    ~(rsp_pending /\ mel_offset > 0 /\ rsp_generation /= mel_snapshot_gen)

\* ----- Safety: Family 1 — MelHeaderComplete -----
\*
\* Brief §5: "Requester evaluates mel_entries_len only after
\* mel_size_internal >= sizeof(spdm_measurement_extension_log_dmtf_t)"
\*
\* The loop at libspdm_req_get_measurement_extension_log.c:241-243 uses
\* measurement_extension_log->mel_entries_len without first confirming
\* mel_size_internal >= 16. If the first chunk < 16 bytes, the field is
\* read from uninitialized/stale buffer memory.

MelHeaderComplete ==
    \* Once the first chunk has been processed (mel_offset > 0),
    \* first_portion_len must be >= MEL_HEADER_SIZE for safe header access.
    mel_offset = 0 \/ first_portion_len >= MEL_HEADER_SIZE

\* ----- Safety: Family 2 — MelSpecValid -----
\*
\* Brief §5: "After NEGOTIATE_ALGORITHMS completes, connection_info.algorithm.mel_spec
\* ∈ {0, SPDM_MEL_SPECIFICATION_DMTF} regardless of capability flags"
\*
\* Violation path: has_session_cap=FALSE → NegotiateAlgorithmsWithoutSessionCap(INVALID)
\* → mel_spec_conn = MEL_SPEC_INVALID, conn_state = CS_NEGOTIATED

MelSpecValid ==
    conn_state = CS_INIT \/ mel_spec_conn \in {MEL_SPEC_UNSET, MEL_SPEC_DMTF}

\* ----- Safety: Family 2/3 — MelSpecPreSend -----
\*
\* Brief §5: "GET_MEASUREMENT_EXTENSION_LOG is only issued when
\* connection_info.algorithm.mel_spec != 0"
\*
\* libspdm_req_get_measurement_extension_log.c:52-77: no such check exists
\* Requester will send with mel_spec_conn=0; Responder rejects (rsp_measurement_extension_log.c:86-91)

MelSpecPreSend ==
    transfer_state = TS_IDLE \/ mel_spec_conn /= MEL_SPEC_UNSET

====================================================================
