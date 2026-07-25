---- MODULE base ----
\* =============================================================================
\* SPDM Encapsulated Mutual Authentication - Base Spec
\*
\* Models the Responder's encapsulated mutual authentication state machine
\* in libspdm. The Requester is treated as an environment that delivers
\* valid or adversarial responses.
\*
\* Bug families targeted:
\*   Family 1 - Encap op-code sequence state machine correctness
\*   Family 2 - Authentication state ordering vs. protocol completion
\*   Family 3 - CHALLENGE_AUTH response validation inconsistency
\*   Family 4 - Encap error code path / state reset completeness
\*
\* Source: library/spdm_responder_lib/libspdm_rsp_encap_response.c
\*         library/spdm_responder_lib/libspdm_rsp_encap_challenge.c
\*         library/spdm_requester_lib/libspdm_req_challenge.c
\*         include/internal/libspdm_common_lib.h:479-493
\* =============================================================================
EXTENDS Naturals, Sequences, FiniteSets, TLC

\* -----------------------------------------------------------------------------
\* Constants
\* -----------------------------------------------------------------------------

CONSTANTS
    MAX_REQUEST_ID    \* Upper bound on request_id counter for finite model checking

\* Op-codes (libspdm_common_lib.h:480-484, rsp_encap_response.c dispatch table:50-76)
CONSTANTS
    OP_NONE,             \* 0x00 - sequence terminator / idle
    OP_GET_DIGESTS,      \* SPDM_GET_DIGESTS
    OP_GET_CERTIFICATE,  \* SPDM_GET_CERTIFICATE
    OP_CHALLENGE         \* SPDM_CHALLENGE

OP_CODES == {OP_NONE, OP_GET_DIGESTS, OP_GET_CERTIFICATE, OP_CHALLENGE}

\* Mutual auth variants (libspdm_init_basic_mut_auth_encap_state:508-548,
\*                       libspdm_init_mut_auth_encap_state:551-612)
CONSTANTS
    VAR_NO_ENCAP,            \* MUT_AUTH_REQUESTED - no encapsulation (rsp_encap_response.c:591-593)
    VAR_WITH_ENCAP_REQUEST,  \* MUT_AUTH_REQUESTED_WITH_ENCAP_REQUEST (rsp_encap_response.c:595-600)
    VAR_WITH_GET_DIGESTS,    \* MUT_AUTH_REQUESTED_WITH_GET_DIGESTS (rsp_encap_response.c:595-600,555-556)
    VAR_BASIC_PK,            \* Basic mutual auth, PUB_KEY_ID_CAP (rsp_encap_response.c:534-535)
    VAR_BASIC_CERT           \* Basic mutual auth, cert chain (rsp_encap_response.c:541-544)

VARIANTS == {VAR_NO_ENCAP, VAR_WITH_ENCAP_REQUEST, VAR_WITH_GET_DIGESTS,
             VAR_BASIC_PK, VAR_BASIC_CERT}

\* Responder response state (libspdm_response_state_t)
CONSTANTS
    RS_NORMAL,           \* LIBSPDM_RESPONSE_STATE_NORMAL
    RS_PROCESSING_ENCAP  \* LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP

RESPONSE_STATES == {RS_NORMAL, RS_PROCESSING_ENCAP}

\* =============================================================================
\* Helpers
\* =============================================================================

\* VariantOpSequence: the request_op_code_sequence[] for each variant.
\* Terminator OP_NONE is always last.
\* rsp_encap_response.c:526-544 (basic), rsp_encap_response.c:576-606 (session)
VariantOpSequence(v) ==
    CASE v = VAR_NO_ENCAP           -> <<OP_NONE>>
      [] v = VAR_WITH_ENCAP_REQUEST -> <<OP_GET_DIGESTS, OP_GET_CERTIFICATE, OP_NONE>>
      [] v = VAR_WITH_GET_DIGESTS   -> <<OP_GET_DIGESTS, OP_GET_CERTIFICATE, OP_NONE>>
      [] v = VAR_BASIC_PK           -> <<OP_CHALLENGE, OP_NONE>>
      [] v = VAR_BASIC_CERT         -> <<OP_GET_DIGESTS, OP_GET_CERTIFICATE, OP_CHALLENGE, OP_NONE>>
      [] OTHER                      -> <<OP_NONE>>

\* VariantInitOpCode: initial current_request_op_code.
\* WITH_GET_DIGESTS pre-seeds to OP_GET_DIGESTS; all others start at 0x00.
\* rsp_encap_response.c:554-556
VariantInitOpCode(v) ==
    IF v = VAR_WITH_GET_DIGESTS THEN OP_GET_DIGESTS ELSE OP_NONE

\* VariantNeedsEncap: whether the variant sets PROCESSING_ENCAP state.
\* rsp_encap_response.c:608-611
VariantNeedsEncap(v) ==
    v \in {VAR_WITH_ENCAP_REQUEST, VAR_WITH_GET_DIGESTS, VAR_BASIC_PK, VAR_BASIC_CERT}

\* VariantUsesGetEncapRequest: whether the variant sends GET_ENCAPSULATED_REQUEST first.
\* WITH_GET_DIGESTS skips this step; Requester directly delivers DELIVER_ENCAPSULATED_RESPONSE.
\* rsp_encap_response.c:555-556 (pre-seeds op_code), req_encap_request.c (Requester path)
VariantUsesGetEncapRequest(v) ==
    v \in {VAR_WITH_ENCAP_REQUEST, VAR_BASIC_PK, VAR_BASIC_CERT}

\* EncapMoveToNextOpCode: mirrors libspdm_encap_move_to_next_op_code.
\* rsp_encap_response.c:90-110
\* If current = OP_NONE, returns seq[1] (start of sequence).
\* Otherwise finds current in seq and returns the next element.
\* Precondition: current \in Range(seq) if current /= OP_NONE.
\* Each op appears at most once in the sequence (SPDM protocol guarantee).
EncapMoveToNextOpCode(seq, current) ==
    IF current = OP_NONE THEN
        seq[1]   \* rsp_encap_response.c:97-99: start from sequence[0]
    ELSE
        LET pos == CHOOSE i \in 1..Len(seq) :   \* rsp_encap_response.c:101-108: find current
                       /\ seq[i] = current
                       /\ \A j \in 1..(i-1) : seq[j] /= current
        IN seq[pos + 1]  \* return next element (may be OP_NONE terminator)

\* =============================================================================
\* Variables
\* =============================================================================

VARIABLES
    \* -- Encap context (libspdm_encap_context_t, libspdm_common_lib.h:479-493) --
    cur_op,          \* current_request_op_code (libspdm_common_lib.h:484)
    op_sequence,     \* request_op_code_sequence as TLA+ Sequence (libspdm_common_lib.h:482)
    request_id,      \* monotonic counter linking ENCAP_REQUEST / DELIVER_ENCAP_RESPONSE (libspdm_common_lib.h:485)
    response_state,  \* NORMAL or PROCESSING_ENCAP (libspdm_common_lib.h:~380)
    variant,         \* active mut_auth variant (selects init path and sequence)

    \* -- Bug Family 2: Authentication state ordering --
    \* req_challenge.c:380 sets resp_authenticated BEFORE encap flow begins.
    \* rsp_encap_challenge.c:263 sets mutually_authenticated only on success.
    \* If encap then fails, resp_authenticated remains TRUE with mutually_authenticated FALSE.
    resp_authenticated,     \* connection_state == AUTHENTICATED (req_challenge.c:380)
    mutually_authenticated, \* encap CHALLENGE_AUTH passed (rsp_encap_challenge.c:263)

    \* -- Bug Family 3: CHALLENGE_AUTH triple validation (rsp_encap_challenge.c:124-175) --
    slot_id_ok,    \* auth_attribute slot_id matches req_slot_id (rsp_encap_challenge.c:124-139)
    slot_mask_ok,  \* param2 has the bit for req_slot_id (rsp_encap_challenge.c:136-139)
    cert_hash_ok,  \* cert_chain_hash verified (rsp_encap_challenge.c:169-175)

    \* -- Bug Family 4: Partial reset on non-NOT_READY error --
    \* rsp_encap_response.c:467-470: response_state set to NORMAL, cur_op NOT zeroed.
    encap_error,    \* TRUE after a non-NOT_READY error exits the encap flow

    \* -- Bug Family 1/3: Certificate chain completion (rsp_encap_get_certificate.c:297-334) --
    \* peer_used_cert_chain[req_slot_id] is populated only after GET_CERTIFICATE completes.
    cert_chain_received   \* GET_CERTIFICATE exchange completed for the active slot

encapVars == <<cur_op, op_sequence, request_id, response_state, variant>>
authVars  == <<resp_authenticated, mutually_authenticated>>
chalVars  == <<slot_id_ok, slot_mask_ok, cert_hash_ok>>
certVars  == <<cert_chain_received, encap_error>>
vars == <<encapVars, authVars, chalVars, certVars>>

\* =============================================================================
\* Type Invariant
\* =============================================================================
TypeOK ==
    /\ cur_op \in OP_CODES
    /\ op_sequence \in Seq(OP_CODES)
    /\ request_id \in 0..MAX_REQUEST_ID
    /\ response_state \in RESPONSE_STATES
    /\ variant \in VARIANTS
    /\ resp_authenticated \in BOOLEAN
    /\ mutually_authenticated \in BOOLEAN
    /\ slot_id_ok \in BOOLEAN
    /\ slot_mask_ok \in BOOLEAN
    /\ cert_hash_ok \in BOOLEAN
    /\ encap_error \in BOOLEAN
    /\ cert_chain_received \in BOOLEAN

\* =============================================================================
\* Initialization
\* =============================================================================

\* Models both libspdm_init_basic_mut_auth_encap_state (rsp_encap_response.c:508-548)
\* and libspdm_init_mut_auth_encap_state (rsp_encap_response.c:551-612).
\* MC checks all variants exhaustively via non-deterministic choice.
Init ==
    /\ variant \in VARIANTS
    /\ op_sequence = VariantOpSequence(variant)
    /\ cur_op = VariantInitOpCode(variant)         \* rsp_encap_response.c:511,554-556
    /\ request_id = 0                              \* rsp_encap_response.c:512,558
    /\ response_state =
           IF VariantNeedsEncap(variant)
           THEN RS_PROCESSING_ENCAP                \* rsp_encap_response.c:547,610
           ELSE RS_NORMAL                          \* VAR_NO_ENCAP: no state change
    \* resp_authenticated may already be TRUE at encap-init time:
    \* req_challenge.c:380 sets AUTHENTICATED *before* libspdm_encapsulated_request is called,
    \* which is the function that drives init. Model both cases non-deterministically.
    \* Bug Family 2: only the resp_authenticated=TRUE + EncapError scenario is interesting.
    /\ resp_authenticated \in BOOLEAN
    /\ mutually_authenticated = FALSE
    /\ slot_id_ok = FALSE
    /\ slot_mask_ok = FALSE
    /\ cert_hash_ok = FALSE
    /\ encap_error = FALSE
    /\ cert_chain_received = FALSE

\* =============================================================================
\* Actions
\* =============================================================================

\* ---------------------------------------------------------------------------
\* VerifyResponder: The Requester successfully authenticates the Responder
\* (processes Responder's CHALLENGE_AUTH), setting connection_state = AUTHENTICATED.
\* This happens BEFORE the encap mutual auth flow begins.
\* req_challenge.c:380
\*
\* Bug Family 2: After this point, if encap subsequently fails, the
\* connection_state remains AUTHENTICATED even though mutual auth is incomplete.
\* ---------------------------------------------------------------------------
VerifyResponder ==
    /\ ~resp_authenticated
    \* No response_state precondition: in the real code, AUTHENTICATED is set
    \* at req_challenge.c:380 before libspdm_encapsulated_request (line 389) is called,
    \* but the spec Init already represents the post-init state (PROCESSING_ENCAP for
    \* encap variants). The non-deterministic resp_authenticated \in BOOLEAN in Init
    \* covers the pre-set case; this action covers the fire-after-init-NORMAL case
    \* (e.g., trace replay where verify_responder event appears in sequence).
    /\ resp_authenticated' = TRUE
    /\ UNCHANGED <<encapVars, chalVars, certVars, mutually_authenticated>>

\* ---------------------------------------------------------------------------
\* GetEncapsulatedRequest: The Requester sends GET_ENCAPSULATED_REQUEST.
\* Responder handles it via libspdm_get_response_encapsulated_request
\* (rsp_encap_response.c:269-373), which calls libspdm_process_encapsulated_response
\* with a NULL/0 response (rsp_encap_response.c:357-358).
\*
\* Inside process_encapsulated_response with cur_op=0 (rsp_encap_response.c:132):
\*   - Skips "process previous response" block
\*   - Increments request_id (rsp_encap_response.c:159)
\*   - Calls EncapMoveToNextOpCode to advance from 0 to seq[0] (rsp_encap_response.c:163)
\*   - Prepares the first encapsulated request (GET_DIGESTS/CHALLENGE/...)
\*
\* Only fires for variants that send GET_ENCAPSULATED_REQUEST first (not WITH_GET_DIGESTS).
\* Bug Family 1: cur_op transitions from OP_NONE to first op in sequence.
\* ---------------------------------------------------------------------------
GetEncapsulatedRequest ==
    /\ response_state = RS_PROCESSING_ENCAP   \* rsp_encap_response.c:305
    /\ VariantUsesGetEncapRequest(variant)    \* WITH_GET_DIGESTS never sends GET_ENCAP
    /\ cur_op = OP_NONE                       \* rsp_encap_response.c:132: first call
    /\ request_id < MAX_REQUEST_ID
    /\ request_id' = request_id + 1           \* rsp_encap_response.c:159
    /\ cur_op' = EncapMoveToNextOpCode(op_sequence, cur_op)  \* rsp_encap_response.c:163
    /\ response_state' =
           IF EncapMoveToNextOpCode(op_sequence, cur_op) = OP_NONE
           THEN RS_NORMAL                     \* rsp_encap_response.c:166-170: encap_request_size=0
           ELSE RS_PROCESSING_ENCAP
    /\ UNCHANGED <<op_sequence, variant, authVars, chalVars, certVars>>

\* ---------------------------------------------------------------------------
\* DeliverEncapResponseDigests: Requester sends DELIVER_ENCAPSULATED_RESPONSE
\* carrying a DIGESTS sub-response. Responder handles via
\* libspdm_get_response_encapsulated_response_ack (rsp_encap_response.c:375-493)
\* which calls libspdm_process_encapsulated_response to dispatch to
\* libspdm_process_encap_response_digest.
\*
\* param1 check: rsp_encap_response.c:429 requires param1 == request_id.
\* Bug Family 1 / MC-2: WITH_GET_DIGESTS sends this as first message with request_id=0
\*   (no prior GET_ENCAPSULATED_REQUEST was sent). For all other variants, request_id >= 1
\*   after GetEncapsulatedRequest fires first.
\* ---------------------------------------------------------------------------
DeliverEncapResponseDigests ==
    /\ response_state = RS_PROCESSING_ENCAP
    /\ cur_op = OP_GET_DIGESTS
    /\ request_id < MAX_REQUEST_ID
    \* FOR WITH_GET_DIGESTS: first delivery uses request_id=0 (rsp_encap_response.c:429)
    \* Other variants have request_id >= 1 at this point (GetEncapsulatedRequest fired first)
    /\ (variant = VAR_WITH_GET_DIGESTS => request_id = 0)
    /\ request_id' = request_id + 1                          \* rsp_encap_response.c:159
    /\ cur_op' = EncapMoveToNextOpCode(op_sequence, cur_op)  \* rsp_encap_response.c:163
    /\ response_state' =
           IF EncapMoveToNextOpCode(op_sequence, cur_op) = OP_NONE
           THEN RS_NORMAL
           ELSE RS_PROCESSING_ENCAP
    /\ UNCHANGED <<op_sequence, variant, authVars, chalVars, certVars>>

\* ---------------------------------------------------------------------------
\* DeliverEncapResponseCertificate: Requester sends DELIVER_ENCAPSULATED_RESPONSE
\* carrying a CERTIFICATE sub-response. On completion, peer_used_cert_chain[req_slot_id]
\* is populated.
\* libspdm_process_encap_response_certificate (rsp_encap_get_certificate.c:297-334)
\*
\* Bug Family 5 / MC-4: cert_chain_received marks that the cert chain is populated;
\* required before CHALLENGE_AUTH can be meaningfully validated.
\* ---------------------------------------------------------------------------
DeliverEncapResponseCertificate ==
    /\ response_state = RS_PROCESSING_ENCAP
    /\ cur_op = OP_GET_CERTIFICATE
    /\ request_id < MAX_REQUEST_ID
    /\ request_id' = request_id + 1                          \* rsp_encap_response.c:159
    /\ cur_op' = EncapMoveToNextOpCode(op_sequence, cur_op)  \* rsp_encap_response.c:163
    /\ response_state' =
           IF EncapMoveToNextOpCode(op_sequence, cur_op) = OP_NONE
           THEN RS_NORMAL
           ELSE RS_PROCESSING_ENCAP
    /\ cert_chain_received' = TRUE   \* rsp_encap_get_certificate.c:297-334: chain stored
    /\ UNCHANGED <<op_sequence, variant, authVars, chalVars, encap_error>>

\* ---------------------------------------------------------------------------
\* DeliverEncapResponseChallengeAuth: Requester delivers CHALLENGE_AUTH.
\* Responder validates three interdependent fields and on success sets AUTHENTICATED.
\* libspdm_process_encap_response_challenge_auth (rsp_encap_challenge.c:80-268)
\*
\* Three checks (Bug Family 3):
\*   slot_id_ok:   auth_attribute slot_id matches encap_context.req_slot_id (rsp_encap_challenge.c:124-139)
\*   slot_mask_ok: param2 has the bit for req_slot_id                        (rsp_encap_challenge.c:136-139)
\*   cert_hash_ok: cert_chain_hash verified against stored chain             (rsp_encap_challenge.c:169-175)
\*
\* On success: libspdm_set_connection_state(AUTHENTICATED) (rsp_encap_challenge.c:263)
\* Bug Family 2: This sets mutually_authenticated = TRUE only on the success path.
\* ---------------------------------------------------------------------------
DeliverEncapResponseChallengeAuth ==
    /\ response_state = RS_PROCESSING_ENCAP
    /\ cur_op = OP_CHALLENGE
    /\ request_id < MAX_REQUEST_ID
    \* All three validation checks pass (rsp_encap_challenge.c:124-175)
    /\ slot_id_ok' = TRUE
    /\ slot_mask_ok' = TRUE
    /\ cert_hash_ok' = TRUE
    /\ mutually_authenticated' = TRUE          \* rsp_encap_challenge.c:263
    /\ request_id' = request_id + 1            \* rsp_encap_response.c:159
    /\ cur_op' = OP_NONE                       \* CHALLENGE is always last in sequence
    /\ response_state' = RS_NORMAL             \* rsp_encap_response.c:490: encap_request_size=0 path
    /\ UNCHANGED <<op_sequence, variant, resp_authenticated, cert_chain_received, encap_error>>

\* ---------------------------------------------------------------------------
\* EncapResponseNotReady: Requester delivers an ERROR(ResponseNotReady).
\* Responder terminates the encap flow cleanly:
\*   - cur_op set to 0 (rsp_encap_response.c:151)
\*   - encap_request_size = 0, so response_state = NORMAL (rsp_encap_response.c:480-491)
\*
\* Bug Family 1: Commit 58bf6bff (Issue #1791) added this handling. Before the fix,
\* NOT_READY was not handled and the encap flow could hang.
\* The CLEAN termination here is the CORRECT behavior (cur_op=0 AND NORMAL).
\* ---------------------------------------------------------------------------
EncapResponseNotReady ==
    /\ response_state = RS_PROCESSING_ENCAP
    /\ cur_op /= OP_NONE                     \* an active op exists
    \* rsp_encap_response.c:149-152: LIBSPDM_STATUS_NOT_READY_PEER path
    /\ cur_op' = OP_NONE                     \* cleanly zeroed
    /\ response_state' = RS_NORMAL           \* rsp_encap_response.c:480-491: encap_request_size=0
    /\ UNCHANGED <<op_sequence, request_id, variant, authVars, chalVars, certVars>>

\* ---------------------------------------------------------------------------
\* EncapError: A non-NOT_READY error occurs inside libspdm_process_encapsulated_response.
\* rsp_encap_response.c:467-470 (DELIVER_ENCAPSULATED_RESPONSE path):
\*     if (LIBSPDM_STATUS_IS_ERROR(status)) {
\*         spdm_context->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;  // line 468
\*         return libspdm_generate_error_response(...);                    // line 469
\*     }
\* rsp_encap_response.c:359-363 (GET_ENCAPSULATED_REQUEST path):
\*     if (LIBSPDM_STATUS_IS_ERROR(status)) {
\*         spdm_context->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;  // line 360
\*         return libspdm_generate_error_response(...);                    // line 362
\*     }
\*
\* BUG: response_state is set to NORMAL but current_request_op_code is NOT zeroed.
\* This leaves the context in a "half-reset" state.
\*
\* Bug Family 4 (MC-3): NoPartialAuthState violated: response_state=NORMAL, cur_op!=0
\* Bug Family 2 (MC-1): If resp_authenticated=TRUE and this fires for CHALLENGE op,
\*   mutually_authenticated stays FALSE while resp_authenticated=TRUE.
\* ---------------------------------------------------------------------------
EncapError ==
    /\ response_state = RS_PROCESSING_ENCAP
    /\ cur_op /= OP_NONE                  \* an active op exists to fail
    \* rsp_encap_response.c:468: only response_state is reset; cur_op left unchanged
    /\ response_state' = RS_NORMAL
    /\ encap_error' = TRUE                \* marks partial-reset state
    /\ UNCHANGED <<cur_op, op_sequence, request_id, variant, authVars, chalVars, cert_chain_received>>

\* =============================================================================
\* Next Relation
\* =============================================================================
Next ==
    \/ VerifyResponder
    \/ GetEncapsulatedRequest
    \/ DeliverEncapResponseDigests
    \/ DeliverEncapResponseCertificate
    \/ DeliverEncapResponseChallengeAuth
    \/ EncapResponseNotReady
    \/ EncapError

\* =============================================================================
\* Invariants
\* =============================================================================

\* --- Structural ---

\* Family 1 | EncapSequenceTerminates
\* The op-code sequence always terminates (cur_op reaches OP_NONE).
\* A non-NORMAL state with cur_op=OP_NONE would be stuck waiting for the
\* GET_ENCAPSULATED_REQUEST that cannot arrive. This catches infinite-loop patterns.
\* Historical: commit 6674aa87 (GET_CERTIFICATE chunk infinite loop).
EncapSequenceTerminates ==
    response_state = RS_NORMAL => cur_op = OP_NONE

\* Family 1 | RequestIdMonotonic
\* request_id stays within bounds (monotonic counter, never wraps in a single exchange).
RequestIdMonotonic ==
    request_id <= MAX_REQUEST_ID

\* Family 2 | AuthStateConsistency
\* If mutually_authenticated is TRUE, all three challenge checks must have passed.
\* Catches any path that sets mutually_authenticated without the triple check.
\* rsp_encap_challenge.c:124-175 + rsp_encap_challenge.c:263
AuthStateConsistency ==
    mutually_authenticated => (slot_id_ok /\ slot_mask_ok /\ cert_hash_ok)

\* Family 2 | NoPhantomAuth (MC-1)
\* After any encap error, resp_authenticated and mutually_authenticated must not
\* simultaneously misrepresent the state: it's invalid to have resp_authenticated=TRUE
\* (AUTHENTICATED set at req_challenge.c:380) and encap_error=TRUE while the
\* connection is back in NORMAL state -- because the session now has an ambiguous
\* authentication status (Responder says authenticated; mutual auth never completed).
\* Historical: commit b1942fee (Issue #3059).
NoPhantomAuth ==
    ~(resp_authenticated /\ encap_error /\ response_state = RS_NORMAL)

\* Family 3 | ChallengeAuthBinding (MC-4 related)
\* CHALLENGE_AUTH accepted (mutually_authenticated) implies all three fields verified.
\* rsp_encap_challenge.c:124-175
ChallengeAuthBinding ==
    mutually_authenticated =>
        (slot_id_ok /\ slot_mask_ok /\ cert_hash_ok)

\* Family 3 | CertChainReceivedBeforeChallenge (MC-4)
\* For variants that include GET_CERTIFICATE, cert_chain_received must be TRUE
\* before CHALLENGE_AUTH can be accepted (cert_hash verification would be against
\* an empty / stale peer_used_cert_chain).
\* rsp_encap_get_certificate.c:297-334 stores the chain; rsp_encap_challenge.c:169-175 uses it.
CertChainReceivedBeforeChallenge ==
    (mutually_authenticated /\
     variant \in {VAR_WITH_ENCAP_REQUEST, VAR_WITH_GET_DIGESTS, VAR_BASIC_CERT})
    => cert_chain_received

\* Family 4 | NoPartialAuthState (MC-3)
\* response_state = NORMAL implies cur_op = OP_NONE.
\* Violation means EncapError left the context half-reset:
\* response_state=NORMAL (callers think encap is done) but cur_op!=0
\* (encap context still holds a stale op-code).
\* rsp_encap_response.c:467-470
NoPartialAuthState ==
    response_state = RS_NORMAL => cur_op = OP_NONE

\* Family 2+4 | FullMutualAuthRequiresEncapComplete
\* Mutual authentication requires a complete, error-free encap exchange.
FullMutualAuthRequiresEncapComplete ==
    mutually_authenticated =>
        (response_state = RS_NORMAL /\ cur_op = OP_NONE /\ ~encap_error)

\* =============================================================================
\* Spec
\* =============================================================================
Spec == Init /\ [][Next]_vars

====
