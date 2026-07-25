---- MODULE base ----
(**
 * TLA+ base specification for libspdm VERSION / CAPABILITIES / NEGOTIATE_ALGORITHMS
 *
 * Protocol: SPDM VCA handshake (DSP0274 §§ 8.1–8.4)
 * Category: A (Distributed / Message-Passing)
 * System:   Single-threaded request-response; Requester drives, Responder reacts.
 *
 * Bug families modelled:
 *   F1 — Version × Capability × Algorithm Coherence
 *   F2 — Capability Compatibility Asymmetry
 *   F3 — NEGOTIATE_ALGORITHMS Struct Table Mirroring
 *   F4 — Transcript Integrity on VCA Error Paths
 *)
EXTENDS Naturals, Sequences, FiniteSets, TLC

----
\* ------------------------------------------------------------------
\*  CONSTANTS
\* ------------------------------------------------------------------

\* SPDM version constants (encoded as 0x10, 0x11, 0x12, 0x13, 0x14)
CONSTANTS
    Ver10,   \* 0x10
    Ver11,   \* 0x11
    Ver12,   \* 0x12
    Ver13,   \* 0x13
    Ver14    \* 0x14

\* Capability flag names (boolean set membership models bit fields)
CONSTANTS
    CERT_CAP,          \* bit 1
    CHAL_CAP,          \* bit 2
    ENCRYPT_CAP,       \* bit 6
    MAC_CAP,           \* bit 7
    MUT_AUTH_CAP,      \* bit 8
    KEY_EX_CAP,        \* bit 9
    PSK_CAP_1,         \* bit 10 (LSB of 2-bit PSK_CAP field)
    PSK_CAP_2,         \* bit 11 (MSB of 2-bit PSK_CAP field)
    ENCAP_CAP,         \* bit 12
    HBEAT_CAP,         \* bit 13
    KEY_UPD_CAP,       \* bit 14
    HANDSHAKE_IN_CLEAR_CAP, \* bit 15
    PUB_KEY_ID_CAP,    \* bit 16
    MEAS_CAP,          \* bits 17-18 (any measurement capability)
    MEAS_CAP_SIG,      \* MEAS_CAP with signature (bit 17=0, 18=1 per spec)
    MEL_CAP            \* MEL capability (v1.3+)

\* Algorithm type constants (AlgType field in struct table)
CONSTANTS
    ALG_DHE,
    ALG_AEAD,
    ALG_REQ_ASYM,
    ALG_KEY_SCHEDULE,
    ALG_REQ_PQC_ASYM,
    ALG_KEM

\* Non-zero sentinel for "some valid algorithm was selected"
CONSTANTS ALGO_NONE, ALGO_SOME

----
\* ------------------------------------------------------------------
\*  TYPE HELPERS
\* ------------------------------------------------------------------

AllVersions == {Ver10, Ver11, Ver12, Ver13, Ver14}

\* Versions that permit capability flag extensions
V11Plus == {Ver11, Ver12, Ver13, Ver14}
V13Plus == {Ver13, Ver14}
V14Plus == {Ver14}

AllCapFlags == {CERT_CAP, CHAL_CAP, ENCRYPT_CAP, MAC_CAP, MUT_AUTH_CAP, KEY_EX_CAP,
                PSK_CAP_1, PSK_CAP_2, ENCAP_CAP, HBEAT_CAP, KEY_UPD_CAP,
                HANDSHAKE_IN_CLEAR_CAP, PUB_KEY_ID_CAP, MEAS_CAP, MEAS_CAP_SIG,
                MEL_CAP}

AllAlgTypes == {ALG_DHE, ALG_AEAD, ALG_REQ_ASYM, ALG_KEY_SCHEDULE, ALG_REQ_PQC_ASYM, ALG_KEM}

\* PSK_CAP field value helpers (2-bit field in requester flags)
\* psk_cap=0 → neither bit, psk_cap=1 → PSK_CAP_1 only, psk_cap=3 → both bits (illegal for requester per v1.1+)
HasPskCap(flags) == PSK_CAP_1 \in flags \/ PSK_CAP_2 \in flags
HasKeyExCap(flags) == KEY_EX_CAP \in flags
HasMacCap(flags) == MAC_CAP \in flags
HasEncryptCap(flags) == ENCRYPT_CAP \in flags
HasCertCap(flags) == CERT_CAP \in flags
HasPubKeyIdCap(flags) == PUB_KEY_ID_CAP \in flags
HasMeasCap(flags) == MEAS_CAP \in flags \/ MEAS_CAP_SIG \in flags
HasMelCap(flags) == MEL_CAP \in flags

\* PSK_CAP value as integer: 0, 1, or 3 (2 is reserved too but handled separately)
\* For the requester, PSK_CAP_1 and PSK_CAP_2 both set means value=3 (illegal per
\* libspdm_rsp_capabilities.c:70 — responder rejects it but spec allows it for requester)
ReqPskCapBothBits(flags) == PSK_CAP_1 \in flags /\ PSK_CAP_2 \in flags

----
\* ------------------------------------------------------------------
\*  STATE MACHINE STATES
\* ------------------------------------------------------------------

\* include/library/spdm_common_lib.h:201-223
NOT_STARTED     == "NOT_STARTED"
AFTER_VERSION   == "AFTER_VERSION"
AFTER_CAPS      == "AFTER_CAPS"
NEGOTIATED      == "NEGOTIATED"

AllConnectionStates == {NOT_STARTED, AFTER_VERSION, AFTER_CAPS, NEGOTIATED}

----
\* ------------------------------------------------------------------
\*  VARIABLES
\* ------------------------------------------------------------------

\* ---- Protocol state ----
VARIABLES
    conn_state,          \* connection state machine; AllConnectionStates
    negotiated_version,  \* version agreed at VERSION phase; AllVersions ∪ {"-"}
    \* [F1] req/rsp capability flags as subsets of AllCapFlags
    req_cap_flags,       \* requester's advertised capability flags
    rsp_cap_flags,       \* responder's advertised capability flags
    \* [F1,F3] algorithm selection: AlgType → ALGO_NONE | ALGO_SOME
    base_hash_algo,      \* scalar — selected base hash algorithm value
    base_asym_algo,      \* scalar — selected base asym algorithm value
    measurement_spec,    \* measurement_specification_sel in response
    measurement_hash_algo, \* measurement_hash_algo selected
    dhe_algo,            \* selected DHE group (0 or non-zero)
    aead_algo,           \* selected AEAD suite
    req_asym_algo,       \* selected requester asym algorithm
    key_schedule_algo    \* selected key schedule

\* [F3] Struct table types sent by each side
VARIABLES
    req_alg_types,       \* set of AlgType sent in NEGOTIATE_ALGORITHMS request
    rsp_alg_types        \* set of AlgType mirrored in ALGORITHMS response

\* [F4] Transcript append tracking per phase
\* phase ∈ {"version", "capabilities", "algorithms"}
VARIABLES
    req_appended,        \* [phase → BOOLEAN]: request appended to message_a
    rsp_appended         \* [phase → BOOLEAN]: response appended to message_a

\* Message in flight (single-slot channel; SPDM is strictly sequential)
VARIABLES
    in_flight_msg        \* record with type and payload, or [type |-> "NONE"]

\* Fault injection tracking (used by MC wrapper)
VARIABLES
    ctx_reset_count      \* number of times context has been reset (for F1 crash path)

----
\* ------------------------------------------------------------------
\*  VARIABLE GROUPS (for UNCHANGED clauses)
\* ------------------------------------------------------------------

protocolVars == <<conn_state, negotiated_version>>
capVars      == <<req_cap_flags, rsp_cap_flags>>
algoVars     == <<base_hash_algo, base_asym_algo, measurement_spec, measurement_hash_algo,
                  dhe_algo, aead_algo, req_asym_algo, key_schedule_algo>>
algTypeVars  == <<req_alg_types, rsp_alg_types>>
transcriptVars == <<req_appended, rsp_appended>>
msgVar       == <<in_flight_msg>>
faultVars    == <<ctx_reset_count>>

vars == <<protocolVars, capVars, algoVars, algTypeVars, transcriptVars, msgVar, faultVars>>

----
\* ------------------------------------------------------------------
\*  INITIAL STATE
\* ------------------------------------------------------------------

Init ==
    /\ conn_state           = NOT_STARTED
    /\ negotiated_version   = "-"
    /\ req_cap_flags        = {}
    /\ rsp_cap_flags        = {}
    /\ base_hash_algo       = ALGO_NONE
    /\ base_asym_algo       = ALGO_NONE
    /\ measurement_spec     = ALGO_NONE
    /\ measurement_hash_algo = ALGO_NONE
    /\ dhe_algo             = ALGO_NONE
    /\ aead_algo            = ALGO_NONE
    /\ req_asym_algo        = ALGO_NONE
    /\ key_schedule_algo    = ALGO_NONE
    /\ req_alg_types        = {}
    /\ rsp_alg_types        = {}
    /\ req_appended         = [p \in {"version", "capabilities", "algorithms"} |-> FALSE]
    /\ rsp_appended         = [p \in {"version", "capabilities", "algorithms"} |-> FALSE]
    /\ in_flight_msg        = [type |-> "NONE"]
    /\ ctx_reset_count      = 0

----
\* ------------------------------------------------------------------
\*  PHASE 1 — VERSION
\* ------------------------------------------------------------------

(**
 * Requester sends GET_VERSION.
 * library/spdm_requester_lib/libspdm_req_get_version.c
 *
 * [F4] Requester appends GET_VERSION request to message_a before
 * waiting for the response (libspdm_req_get_version.c:~150).
 *)
ReqSendGetVersion ==
    /\ conn_state = NOT_STARTED
    /\ in_flight_msg = [type |-> "NONE"]
    \* [F4] append request to transcript before response arrives
    /\ req_appended' = [req_appended EXCEPT !["version"] = TRUE]
    /\ in_flight_msg' = [type |-> "GET_VERSION"]
    /\ UNCHANGED <<protocolVars, capVars, algoVars, algTypeVars, rsp_appended, faultVars>>

(**
 * Responder handles GET_VERSION and sends VERSION response.
 * library/spdm_responder_lib/libspdm_rsp_version.c
 *
 * Responder picks a version to advertise from its local list.
 * [F4] Append request to transcript, then (if success) append response.
 *      On error the request is already appended but response is not.
 *
 * We model: non-deterministic version choice from AllVersions;
 * normal path appends both request and response.
 *)
RspHandleGetVersion(v) ==
    /\ in_flight_msg /= [type |-> "NONE"]
    /\ in_flight_msg.type = "GET_VERSION"
    /\ v \in AllVersions
    \* State guard: libspdm_rsp_version.c — any connection state is valid for GET_VERSION
    \* (it resets the context)
    \* [F4] Responder appends request then generates response
    /\ req_appended' = [req_appended EXCEPT !["version"] = TRUE]
    /\ rsp_appended' = [rsp_appended EXCEPT !["version"] = TRUE]
    /\ in_flight_msg' = [type |-> "VERSION", version |-> v]
    /\ UNCHANGED <<protocolVars, capVars, algoVars, algTypeVars, faultVars>>

(**
 * Requester processes VERSION response.
 * library/spdm_requester_lib/libspdm_req_get_version.c:~200
 *
 * Records negotiated_version; advances to AFTER_VERSION.
 * [F4] Requester appends VERSION response to message_a.
 *)
ReqHandleVersion ==
    /\ in_flight_msg /= [type |-> "NONE"]
    /\ in_flight_msg.type = "VERSION"
    \* Requester must have already sent GET_VERSION (req_appended["version"] = TRUE)
    /\ req_appended["version"] = TRUE
    /\ LET v == in_flight_msg.version IN
        /\ negotiated_version' = v
        /\ conn_state' = AFTER_VERSION
        /\ rsp_appended' = [rsp_appended EXCEPT !["version"] = TRUE]
        /\ in_flight_msg' = [type |-> "NONE"]
    /\ UNCHANGED <<capVars, algoVars, algTypeVars, req_appended, faultVars>>

----
\* ------------------------------------------------------------------
\*  PHASE 2 — CAPABILITIES
\* ------------------------------------------------------------------

(**
 * Requester sends GET_CAPABILITIES with its flag set.
 * library/spdm_requester_lib/libspdm_req_get_capabilities.c
 *
 * [F1] version-specific mask must be applied to flags before sending
 *      (libspdm_mask_capability_flags; introduced in v3.x).
 * [F4] Requester appends GET_CAPABILITIES to transcript.
 *)
ReqSendGetCapabilities(flags) ==
    /\ conn_state = AFTER_VERSION
    /\ in_flight_msg = [type |-> "NONE"]
    /\ flags \subseteq AllCapFlags
    \* [F1] flags are scoped to negotiated version — ver10 has no extended flags
    /\ (negotiated_version = Ver10 => flags \subseteq {CERT_CAP, CHAL_CAP, MEAS_CAP, MEAS_CAP_SIG})
    /\ req_cap_flags' = flags
    /\ req_appended'  = [req_appended EXCEPT !["capabilities"] = TRUE]
    /\ in_flight_msg' = [type |-> "GET_CAPABILITIES", flags |-> flags]
    /\ UNCHANGED <<protocolVars, rsp_cap_flags, algoVars, algTypeVars, rsp_appended, faultVars>>

(**
 * Responder validates requester capability flags and sends CAPABILITIES.
 * library/spdm_responder_lib/libspdm_rsp_capabilities.c:49-163
 *   (libspdm_check_request_flag_compatibility)
 * library/spdm_responder_lib/libspdm_rsp_capabilities.c:165-487
 *   (libspdm_get_response_capabilities)
 *
 * [F2] Responder validator: checks psk_cap, key_ex+mac, cert/pub_key_id, mut_auth, etc.
 *      Known divergence from requester validator: PSK_CAP==3 (both bits) rejected here
 *      (libspdm_rsp_capabilities.c:70) but spec allows it for requester outgoing.
 *      Also missing: KEY_EX_CAP rejection when neither CERT nor PUB_KEY_ID is set
 *      (present in requester's validate_responder_capability; absent here).
 *
 * rsp_flags: the responder's own flag set.
 * req_flags: the requester's GET_CAPABILITIES flags.
 *)
RspHandleGetCapabilities(req_flags, rsp_flags) ==
    /\ in_flight_msg /= [type |-> "NONE"]
    /\ in_flight_msg.type = "GET_CAPABILITIES"
    /\ conn_state = AFTER_VERSION       \* libspdm_rsp_capabilities.c:185
    /\ req_flags = in_flight_msg.flags
    /\ rsp_flags \subseteq AllCapFlags
    \* [F2] Responder checks requester flags using libspdm_check_request_flag_compatibility
    \* libspdm_rsp_capabilities.c:68-70: psk_cap=2 or psk_cap=3 → reject (for v1.1+)
    /\ (negotiated_version \in V11Plus =>
            \* psk_cap=2 (PSK_CAP_2 set, PSK_CAP_1 unset) is illegal
            ~(PSK_CAP_2 \in req_flags /\ PSK_CAP_1 \notin req_flags))
    \* NOTE: libspdm_rsp_capabilities.c:70 ALSO rejects psk_cap=3 (both bits),
    \* but the SPDM spec treats PSK_CAP=3 as valid for requester; this is the
    \* F2 asymmetry — requester's own outgoing validator (req_get_capabilities.c)
    \* does NOT reject psk_cap=3. We model the actual code behavior here.
    /\ (negotiated_version \in V11Plus => ~ReqPskCapBothBits(req_flags))
    \* libspdm_rsp_capabilities.c:75-88: if key_ex or psk then mac or encrypt required
    /\ (negotiated_version \in V11Plus =>
            ((HasKeyExCap(req_flags) \/ HasPskCap(req_flags)) =>
                (HasMacCap(req_flags) \/ HasEncryptCap(req_flags))))
    \* libspdm_rsp_capabilities.c:97-113: cert+pub_key_id mutual exclusion
    /\ ~(HasCertCap(req_flags) /\ HasPubKeyIdCap(req_flags))
    \* libspdm_rsp_capabilities.c:116: F2 BUG — missing KEY_EX_CAP rejection when
    \* neither CERT nor PUB_KEY_ID is set; we model the ACTUAL (buggy) code path:
    \* no check here. (The correct check lives in validate_responder_capability.)
    \* [F4] Responder appends request then response to transcript
    /\ req_appended' = [req_appended EXCEPT !["capabilities"] = TRUE]
    /\ rsp_appended' = [rsp_appended EXCEPT !["capabilities"] = TRUE]
    /\ rsp_cap_flags' = rsp_flags
    /\ conn_state'    = AFTER_CAPS
    /\ in_flight_msg' = [type |-> "CAPABILITIES", rsp_flags |-> rsp_flags]
    /\ UNCHANGED <<negotiated_version, req_cap_flags, algoVars, algTypeVars, faultVars>>

(**
 * Requester validates CAPABILITIES response from responder.
 * library/spdm_requester_lib/libspdm_req_get_capabilities.c
 *   validate_responder_capability (lines ~80-175)
 *
 * [F2] Requester validator is separate from responder's — they can diverge.
 *      Key checks present in requester but absent in responder:
 *      - KEY_EX requires CERT or PUB_KEY_ID (req_get_capabilities.c:125)
 *      - MAC_CAP required when KEY_EX or PSK set (req_get_capabilities.c:~100)
 *
 * [F4] Requester appends CAPABILITIES response to transcript.
 *)
ReqHandleCapabilities ==
    /\ in_flight_msg /= [type |-> "NONE"]
    /\ in_flight_msg.type = "CAPABILITIES"
    /\ conn_state = AFTER_CAPS
    /\ req_appended["capabilities"] = TRUE
    /\ LET rf == in_flight_msg.rsp_flags IN
        \* Requester validates responder flags (validate_responder_capability)
        \* libspdm_req_get_capabilities.c:~100-175
        \* MAC required when KEY_EX or PSK is set
        /\ (negotiated_version \in V11Plus =>
                ((HasKeyExCap(rf) \/ HasPskCap(rf)) =>
                    (HasMacCap(rf) \/ HasEncryptCap(rf))))
        \* KEY_EX requires CERT or PUB_KEY_ID (req_get_capabilities.c:125)
        \* This check IS present in requester validator but absent in responder's validator
        /\ (negotiated_version \in V11Plus =>
                (HasKeyExCap(rf) =>
                    (HasCertCap(rf) \/ HasPubKeyIdCap(rf))))
        /\ rsp_appended' = [rsp_appended EXCEPT !["capabilities"] = TRUE]
        /\ conn_state'   = AFTER_CAPS
        /\ in_flight_msg' = [type |-> "NONE"]
    /\ UNCHANGED <<negotiated_version, capVars, algoVars, algTypeVars, req_appended, faultVars>>

----
\* ------------------------------------------------------------------
\*  PHASE 3 — NEGOTIATE_ALGORITHMS
\* ------------------------------------------------------------------

(**
 * Requester sends NEGOTIATE_ALGORITHMS.
 * library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c
 *
 * [F3] Requester builds req_alg_types — only includes AlgType entries for
 *      capabilities that are non-zero (fix #2344 / commit 2ee1e372).
 *      Each included entry must have alg_supported != 0.
 * [F4] Appends NEGOTIATE_ALGORITHMS to transcript.
 *)
ReqSendNegotiateAlgorithms(alg_types) ==
    /\ conn_state = AFTER_CAPS
    /\ in_flight_msg = [type |-> "NONE"]
    /\ alg_types \subseteq AllAlgTypes
    \* [F3] DHE alg type only included if KEY_EX_CAP set
    /\ (ALG_DHE \in alg_types => HasKeyExCap(rsp_cap_flags))
    \* [F3] AEAD only included if ENCRYPT_CAP or MAC_CAP set
    /\ (ALG_AEAD \in alg_types => (HasEncryptCap(rsp_cap_flags) \/ HasMacCap(rsp_cap_flags)))
    \* [F3] KEY_SCHEDULE only included if KEY_EX_CAP or PSK_CAP set
    /\ (ALG_KEY_SCHEDULE \in alg_types =>
            (HasKeyExCap(rsp_cap_flags) \/ HasPskCap(rsp_cap_flags)))
    /\ req_alg_types' = alg_types
    /\ req_appended'  = [req_appended EXCEPT !["algorithms"] = TRUE]
    /\ in_flight_msg' = [type |-> "NEGOTIATE_ALGORITHMS", alg_types |-> alg_types]
    /\ UNCHANGED <<protocolVars, capVars, algoVars, rsp_alg_types, rsp_appended, faultVars>>

(**
 * Responder handles NEGOTIATE_ALGORITHMS and sends ALGORITHMS response.
 * library/spdm_responder_lib/libspdm_rsp_algorithms.c:59-900
 *   (libspdm_get_response_algorithms)
 *
 * [F1] MEL_CAP-only path sets measurement_specification_sel but may not
 *      validate measurement_hash_algo (libspdm_rsp_algorithms.c:718-731).
 *      Modelled here: measurement_hash_algo set conditionally on MEAS_CAP.
 * [F3] Response mirrors req_alg_types exactly (param1 echo, libspdm_rsp_algorithms.c:542-552).
 * [F4] Appends request and response to transcript.
 *
 * selected_hash, selected_asym, mspec, mhash: algorithm selections
 * struct_alg_types: the alg types the responder mirrors back
 *)
RspHandleNegotiateAlgorithms(selected_hash, selected_asym, mspec, mhash, struct_alg_types,
                              dhe, aead, req_asym, key_sched) ==
    /\ in_flight_msg /= [type |-> "NONE"]
    /\ in_flight_msg.type = "NEGOTIATE_ALGORITHMS"
    /\ conn_state = AFTER_CAPS
    /\ LET req_types == in_flight_msg.alg_types IN
        \* [F3] Response mirrors exactly the request's struct table count/types
        \* libspdm_rsp_algorithms.c:542-548
        /\ struct_alg_types = req_types
        \* [F1] measurement_specification_sel set only if MEAS_CAP or MEL_CAP
        \* libspdm_rsp_algorithms.c:718-730
        /\ (HasMeasCap(rsp_cap_flags) \/ HasMelCap(rsp_cap_flags) =>
                mspec \in {ALGO_NONE, ALGO_SOME})
        /\ (~HasMeasCap(rsp_cap_flags) /\ ~HasMelCap(rsp_cap_flags) =>
                mspec = ALGO_NONE)
        \* [F1] measurement_hash_algo set only if MEAS_CAP set (NOT MEL-only path)
        \* libspdm_rsp_algorithms.c:557-564: set from request field if mspec != 0
        \* BUG: when MEL_CAP=1, MEAS_CAP=0 — mspec may be set but mhash may be 0
        \* because libspdm_rsp_algorithms.c:733-737 calls prioritize_algorithm
        \* unconditionally on the stored measurement_hash_algo (which is 0 when mspec=0
        \* from req), producing 0. We model the actual buggy logic:
        /\ (HasMeasCap(rsp_cap_flags) =>
                (mhash \in {ALGO_NONE, ALGO_SOME}))
        /\ (~HasMeasCap(rsp_cap_flags) => mhash = ALGO_NONE)
        \* DHE algo selected iff DHE type in struct table
        /\ (ALG_DHE \in struct_alg_types => dhe = ALGO_SOME)
        /\ (ALG_DHE \notin struct_alg_types => dhe = ALGO_NONE)
        /\ (ALG_AEAD \in struct_alg_types => aead = ALGO_SOME)
        /\ (ALG_AEAD \notin struct_alg_types => aead = ALGO_NONE)
        /\ (ALG_REQ_ASYM \in struct_alg_types => req_asym = ALGO_SOME)
        /\ (ALG_REQ_ASYM \notin struct_alg_types => req_asym = ALGO_NONE)
        /\ (ALG_KEY_SCHEDULE \in struct_alg_types => key_sched = ALGO_SOME)
        /\ (ALG_KEY_SCHEDULE \notin struct_alg_types => key_sched = ALGO_NONE)
        \* [F4] Responder appends request then response
        /\ req_appended' = [req_appended EXCEPT !["algorithms"] = TRUE]
        /\ rsp_appended' = [rsp_appended EXCEPT !["algorithms"] = TRUE]
        /\ rsp_alg_types'     = struct_alg_types
        /\ base_hash_algo'    = selected_hash
        /\ base_asym_algo'    = selected_asym
        /\ measurement_spec'  = mspec
        /\ measurement_hash_algo' = mhash
        /\ dhe_algo'          = dhe
        /\ aead_algo'         = aead
        /\ req_asym_algo'     = req_asym
        /\ key_schedule_algo' = key_sched
        /\ conn_state'        = NEGOTIATED
        /\ in_flight_msg'     = [type |-> "ALGORITHMS",
                                 alg_types    |-> struct_alg_types,
                                 hash         |-> selected_hash,
                                 asym         |-> selected_asym,
                                 mspec        |-> mspec,
                                 mhash        |-> mhash]
    /\ UNCHANGED <<negotiated_version, capVars, algTypeVars, faultVars>>
    \* NOTE: conn_state' is set to NEGOTIATED by responder; requester advances
    \* on receipt below. We model the responder setting its internal state.

(**
 * Requester processes ALGORITHMS response.
 * library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c:451-600
 *
 * [F1] Requester validates measurement_hash_algo for structural validity only —
 *      no intersection check against locally-supported set (lines 461-465).
 * [F3] Requester checks rsp_alg_types == req_alg_types.
 * [F4] Appends ALGORITHMS response to transcript.
 *)
ReqHandleAlgorithms ==
    /\ in_flight_msg /= [type |-> "NONE"]
    /\ in_flight_msg.type = "ALGORITHMS"
    /\ conn_state = NEGOTIATED
    /\ req_appended["algorithms"] = TRUE
    /\ LET msg == in_flight_msg IN
        \* [F3] Requester verifies struct table mirroring
        /\ msg.alg_types = req_alg_types
        /\ rsp_appended' = [rsp_appended EXCEPT !["algorithms"] = TRUE]
        /\ conn_state'   = NEGOTIATED
        /\ in_flight_msg' = [type |-> "NONE"]
    /\ UNCHANGED <<negotiated_version, capVars, algoVars, algTypeVars, req_appended, faultVars>>

----
\* ------------------------------------------------------------------
\*  FAULT INJECTION ACTIONS
\* ------------------------------------------------------------------

(**
 * Context reset — GET_VERSION resets the SPDM context.
 * library/spdm_common_lib/libspdm_common_context_data.c (libspdm_reset_context)
 *
 * Clears algorithm fields and resets connection state to NOT_STARTED.
 * Models the crash/context-reset scenario from §3.1 of the modeling brief.
 * Bounded in MC wrapper by ctx_reset_count.
 *)
ContextReset ==
    /\ ctx_reset_count' = ctx_reset_count + 1
    /\ conn_state'          = NOT_STARTED
    /\ negotiated_version'  = "-"
    /\ req_cap_flags'       = {}
    /\ rsp_cap_flags'       = {}
    /\ base_hash_algo'      = ALGO_NONE
    /\ base_asym_algo'      = ALGO_NONE
    /\ measurement_spec'    = ALGO_NONE
    /\ measurement_hash_algo' = ALGO_NONE
    /\ dhe_algo'            = ALGO_NONE
    /\ aead_algo'           = ALGO_NONE
    /\ req_asym_algo'       = ALGO_NONE
    /\ key_schedule_algo'   = ALGO_NONE
    /\ req_alg_types'       = {}
    /\ rsp_alg_types'       = {}
    /\ req_appended' = [p \in {"version", "capabilities", "algorithms"} |-> FALSE]
    /\ rsp_appended' = [p \in {"version", "capabilities", "algorithms"} |-> FALSE]
    /\ in_flight_msg' = [type |-> "NONE"]

(**
 * Error injection — responder generates error response instead of normal response.
 * Models the F4 scenario: request is appended but response generation fails.
 * The transcript is left in a state with req_appended=TRUE, rsp_appended=FALSE.
 *
 * Applicable to any of the three response phases.
 *)
RspErrorInCapabilities ==
    /\ in_flight_msg /= [type |-> "NONE"]
    /\ in_flight_msg.type = "GET_CAPABILITIES"
    /\ conn_state = AFTER_VERSION
    \* [F4] request was already appended (req_appended["capabilities"] set by RspHandleGetCapabilities)
    /\ req_appended' = [req_appended EXCEPT !["capabilities"] = TRUE]
    \* rsp_appended stays FALSE — error path does not complete transcript append
    /\ in_flight_msg' = [type |-> "NONE"]
    /\ UNCHANGED <<protocolVars, capVars, algoVars, algTypeVars, rsp_appended, faultVars>>

RspErrorInAlgorithms ==
    /\ in_flight_msg /= [type |-> "NONE"]
    /\ in_flight_msg.type = "NEGOTIATE_ALGORITHMS"
    /\ conn_state = AFTER_CAPS
    \* [F4] request already appended, response fails mid-generation
    /\ req_appended' = [req_appended EXCEPT !["algorithms"] = TRUE]
    /\ in_flight_msg' = [type |-> "NONE"]
    /\ UNCHANGED <<protocolVars, capVars, algoVars, algTypeVars, rsp_appended, faultVars>>

----
\* ------------------------------------------------------------------
\*  NEXT STATE RELATION
\* ------------------------------------------------------------------

Next ==
    \/ ReqSendGetVersion
    \/ \E v \in AllVersions : RspHandleGetVersion(v)
    \/ ReqHandleVersion
    \/ \E flags \in SUBSET AllCapFlags : ReqSendGetCapabilities(flags)
    \/ \E req_f \in SUBSET AllCapFlags :
       \E rsp_f \in SUBSET AllCapFlags :
           RspHandleGetCapabilities(req_f, rsp_f)
    \/ ReqHandleCapabilities
    \/ \E alg_types \in SUBSET AllAlgTypes : ReqSendNegotiateAlgorithms(alg_types)
    \/ \E sh \in {ALGO_NONE, ALGO_SOME} :
       \E sa \in {ALGO_NONE, ALGO_SOME} :
       \E ms \in {ALGO_NONE, ALGO_SOME} :
       \E mh \in {ALGO_NONE, ALGO_SOME} :
       \E st \in SUBSET AllAlgTypes :
       \E dh \in {ALGO_NONE, ALGO_SOME} :
       \E ae \in {ALGO_NONE, ALGO_SOME} :
       \E ra \in {ALGO_NONE, ALGO_SOME} :
       \E ks \in {ALGO_NONE, ALGO_SOME} :
           RspHandleNegotiateAlgorithms(sh, sa, ms, mh, st, dh, ae, ra, ks)
    \/ ReqHandleAlgorithms
    \/ ContextReset
    \/ RspErrorInCapabilities
    \/ RspErrorInAlgorithms

Spec == Init /\ [][Next]_vars

----
\* ------------------------------------------------------------------
\*  INVARIANTS
\* ------------------------------------------------------------------

\* ---------- Standard state machine ----------

\* State monotonicity (except for resets)
\* VersionProgression: NOT_STARTED → AFTER_VERSION → AFTER_CAPS → NEGOTIATED
TypeOK ==
    /\ conn_state \in AllConnectionStates
    /\ (negotiated_version = "-" \/ negotiated_version \in AllVersions)
    /\ req_cap_flags \subseteq AllCapFlags
    /\ rsp_cap_flags \subseteq AllCapFlags
    /\ base_hash_algo \in {ALGO_NONE, ALGO_SOME}
    /\ base_asym_algo \in {ALGO_NONE, ALGO_SOME}
    /\ measurement_spec \in {ALGO_NONE, ALGO_SOME}
    /\ measurement_hash_algo \in {ALGO_NONE, ALGO_SOME}
    /\ req_alg_types \subseteq AllAlgTypes
    /\ rsp_alg_types \subseteq AllAlgTypes

\* ---------- F1: Version × Capability × Algorithm Coherence ----------

(**
 * NegotiatedCoherence: In NEGOTIATED state, algorithm fields are non-zero iff
 * their enabling capability is set in rsp_cap_flags.
 *
 * modeling-brief.md §5: "algo_selection[T] != 0 ⟺ enabling_cap(T) ∈ rsp_cap_flags"
 * Bug target: MC1 — MEL_CAP=1, MEAS_CAP=0 may produce mspec!=0 but mhash=0
 *)
NegotiatedCoherence ==
    conn_state = NEGOTIATED =>
        /\ (HasMeasCap(rsp_cap_flags) <=> measurement_hash_algo = ALGO_SOME)
        \* measurement_spec set iff MEAS_CAP or MEL_CAP
        /\ ((HasMeasCap(rsp_cap_flags) \/ HasMelCap(rsp_cap_flags)) <=>
                measurement_spec = ALGO_SOME)
        \* base_hash_algo required when cert/chal/meas-sig/key-ex/psk present
        /\ ((HasCertCap(rsp_cap_flags) \/ CHAL_CAP \in rsp_cap_flags \/
             MEAS_CAP_SIG \in rsp_cap_flags \/ HasKeyExCap(rsp_cap_flags) \/
             HasPskCap(rsp_cap_flags)) <=> base_hash_algo = ALGO_SOME)
        \* base_asym_algo required when cert/chal/meas-sig/key-ex
        /\ ((HasCertCap(rsp_cap_flags) \/ CHAL_CAP \in rsp_cap_flags \/
             MEAS_CAP_SIG \in rsp_cap_flags \/ HasKeyExCap(rsp_cap_flags)) <=>
                base_asym_algo = ALGO_SOME)

(**
 * VersionAlgoScope: All capability bits in rsp_cap_flags are within the
 * allowed mask for negotiated_version.
 *
 * modeling-brief.md §5; Bug target: F1 (commit a3e5b996 — flags not masked)
 *)
VersionAlgoScope ==
    conn_state = NEGOTIATED =>
        /\ (negotiated_version = Ver10 =>
                rsp_cap_flags \subseteq {CERT_CAP, CHAL_CAP, MEAS_CAP, MEAS_CAP_SIG})
        /\ (negotiated_version = Ver10 =>
                req_cap_flags \subseteq {CERT_CAP, CHAL_CAP, MEAS_CAP, MEAS_CAP_SIG})
        \* v1.3+ MEL_CAP allowed; v1.4 only PQC
        /\ (~(negotiated_version \in V13Plus) => MEL_CAP \notin rsp_cap_flags)

\* ---------- F2: Capability Compatibility Asymmetry ----------

(**
 * CapabilityCompatibility: After AFTER_CAPS, the pair (req_cap_flags, rsp_cap_flags)
 * satisfies the spec's compatibility table.
 *
 * modeling-brief.md §5; Bug target: MC2 — PSK_CAP==3 asymmetry;
 * and CR1 — missing KEY_EX_CAP check on no-cert/no-pubkey path.
 *)
CapabilityCompatibility ==
    conn_state \in {AFTER_CAPS, NEGOTIATED} =>
        /\ (negotiated_version \in V11Plus =>
                \* MAC required when KEY_EX or PSK enabled
                ((HasKeyExCap(rsp_cap_flags) \/ HasPskCap(rsp_cap_flags)) =>
                    HasMacCap(rsp_cap_flags)))
        /\ (negotiated_version \in V11Plus =>
                (HasKeyExCap(rsp_cap_flags) =>
                    (HasCertCap(rsp_cap_flags) \/ HasPubKeyIdCap(rsp_cap_flags))))
        \* MAC/ENCRYPT/HEARTBEAT/KEY_UPD only when KEY_EX or PSK
        /\ (negotiated_version \in V11Plus =>
                ((~HasKeyExCap(rsp_cap_flags) /\ ~HasPskCap(rsp_cap_flags)) =>
                    (~HasMacCap(rsp_cap_flags) /\ ~HasEncryptCap(rsp_cap_flags))))

\* ---------- F3: NEGOTIATE_ALGORITHMS Struct Table Mirroring ----------

(**
 * AlgTableMirroring: In NEGOTIATED state, rsp_alg_types == req_alg_types.
 *
 * modeling-brief.md §5; Bug target: MC3
 * Fix: commit 941f0ae0 — responder must mirror exactly what requester sent.
 *)
AlgTableMirroring ==
    conn_state = NEGOTIATED =>
        rsp_alg_types = req_alg_types

\* ---------- F4: Transcript Coherence ----------

(**
 * TranscriptCoherence: A lone-appended request without a response is only
 * acceptable transiently (i.e., not as a stable state that can persist into
 * the next VCA phase).
 *
 * "Stable" = no in-flight message (both sides have completed their current exchange).
 * modeling-brief.md §5; Bug target: MC4 (open issue #524)
 *)
TranscriptCoherence ==
    \* When there is no in-flight message and we have advanced past NOT_STARTED,
    \* every appended request must have a corresponding appended response.
    in_flight_msg = [type |-> "NONE"] =>
        \A phase \in {"version", "capabilities", "algorithms"} :
            req_appended[phase] => rsp_appended[phase]

====
