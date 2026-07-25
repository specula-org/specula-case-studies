--------------------------- MODULE base ---------------------------
(*
 * Base spec: SPDM certificate-based authentication (CHALLENGE flow)
 * Target: libspdm v4.0.0-pre
 * Category: A (Distributed / Message-Passing)
 * Reference: DMTF DSP0274 SPDM spec §10.6, §10.9
 *
 * Bug families modeled:
 *   F1 – Connection State / Transcript Desynchronization
 *   F2 – CHALLENGE Precondition Guards Too Weak
 *   F4 – Transcript Integrity Under Error Recovery
 *)
EXTENDS Integers, FiniteSets, Sequences, TLC

\* ── Nodes ────────────────────────────────────────────────────────────────
CONSTANTS
    Requester,  \* SPDM requester (initiates CHALLENGE)
    Responder   \* SPDM responder (issues CHALLENGE_AUTH)

Nodes == {Requester, Responder}

\* ── Certificate slots ────────────────────────────────────────────────────
CONSTANTS
    SlotIDs,    \* Set of slot IDs, e.g. {0}
    NullSlot    \* 0xFF – "no certificate" / slot_id means no hash check

ASSUME NullSlot \notin SlotIDs

\* ── Connection states ────────────────────────────────────────────────────
\* libspdm_connection_state_t  include/library/spdm_common_lib.h:201-223
CONSTANTS
    NOT_STARTED,        \* LIBSPDM_CONNECTION_STATE_NOT_STARTED
    AFTER_VERSION,      \* LIBSPDM_CONNECTION_STATE_AFTER_VERSION
    AFTER_CAPABILITIES, \* LIBSPDM_CONNECTION_STATE_AFTER_CAPABILITIES
    NEGOTIATED,         \* LIBSPDM_CONNECTION_STATE_NEGOTIATED
    AFTER_DIGESTS,      \* LIBSPDM_CONNECTION_STATE_AFTER_DIGESTS
    AFTER_CERTIFICATE,  \* LIBSPDM_CONNECTION_STATE_AFTER_CERTIFICATE
    AUTHENTICATED       \* LIBSPDM_CONNECTION_STATE_AUTHENTICATED

ConnectionStates == {NOT_STARTED, AFTER_VERSION, AFTER_CAPABILITIES,
                     NEGOTIATED, AFTER_DIGESTS, AFTER_CERTIFICATE, AUTHENTICATED}

\* Ordinal for >=/<  comparisons
StateOrd(s) ==
    CASE s = NOT_STARTED        -> 0
    []   s = AFTER_VERSION      -> 1
    []   s = AFTER_CAPABILITIES -> 2
    []   s = NEGOTIATED         -> 3
    []   s = AFTER_DIGESTS      -> 4
    []   s = AFTER_CERTIFICATE  -> 5
    []   s = AUTHENTICATED      -> 6

StateGe(s, t) == StateOrd(s) >= StateOrd(t)
StateLt(s, t) == StateOrd(s) <  StateOrd(t)

\* ── Transcript buffers ────────────────────────────────────────────────────
\* libspdm_com_context_data.c
CONSTANTS
    MSG_B,      \* message_b: GET_DIGESTS + GET_CERTIFICATE exchanges
    MSG_C,      \* message_c: CHALLENGE + CHALLENGE_AUTH
    MSG_MUT_B,  \* message_mut_b: encap mutual auth requester side
    MSG_MUT_C   \* message_mut_c: encap mutual auth responder side

TranscriptBuffers == {MSG_B, MSG_C, MSG_MUT_B, MSG_MUT_C}

\* ── Message types ────────────────────────────────────────────────────────
CONSTANTS
    GET_DIGESTS_MSG, DIGESTS_MSG,
    GET_CERTIFICATE_MSG, CERTIFICATE_MSG,
    CHALLENGE_MSG, CHALLENGE_AUTH_MSG,
    ENCAP_CHALLENGE_MSG, ENCAP_CHALLENGE_AUTH_MSG

\* ─────────────────────────────────────────────────────────────────────────
\* STATE VARIABLES
\* ─────────────────────────────────────────────────────────────────────────

VARIABLES
    \* ── Core protocol state ──────────────────────────────────────────────
    \* spdm_context_t.connection_info.connection_state (per endpoint)
    connection_state,       \* [Nodes -> ConnectionStates]
    msgs,                   \* set of in-flight messages (at most 1 due to sequential protocol)

    \* ── F2: cert chain fetch status ──────────────────────────────────────
    \* Requester tracks whether GET_CERTIFICATE completed for each slot.
    \* libspdm_req_get_certificate.c
    cert_fetched,           \* [SlotIDs -> BOOLEAN]
    \* Requester tracks whether peer cert chain hash is stored.
    \* libspdm_com_crypto_service.c:882-938
    cert_hash_valid,        \* [SlotIDs -> BOOLEAN]

    \* ── F2: challenge outcome tracking ───────────────────────────────────
    challenge_slot,         \* SlotIDs ∪ {NullSlot} – slot used in current CHALLENGE
    challenge_verify_passed, \* BOOLEAN – VerifyCertHash returned SUCCESS
    auth_slot,              \* SlotIDs ∪ {NullSlot} – slot at time AUTHENTICATED reached

    \* ── F1: cert hash in Responder's message_b ───────────────────────────
    \* TRUE iff CERTIFICATE response was appended to message_b on Responder.
    \* libspdm_rsp_certificate.c:224-246
    cert_in_transcript_b,   \* BOOLEAN

    \* ── F1: mutual auth state (Requester side) ───────────────────────────
    \* TRUE after libspdm_req_challenge.c:380 sets AUTHENTICATED
    \* but before libspdm_encapsulated_request() returns (line 392).
    mut_auth_in_progress,   \* BOOLEAN
    mut_auth_failed,        \* BOOLEAN – encapsulated_request returned non-SUCCESS

    \* ── F1: encap mut_c state (Responder side) ───────────────────────────
    \* TRUE after libspdm_rsp_encap_challenge.c:248 appends message_mut_c
    \* but sig not yet verified (verified at line 257).
    mut_c_has_unverified_data, \* BOOLEAN
    encap_sig_verified,        \* BOOLEAN

    \* ── F4: transcript partial flags ─────────────────────────────────────
    \* Set TRUE when request appended to buffer but response append not yet done.
    \* libspdm_rsp_digests.c:173-180  libspdm_rsp_certificate.c:228-235
    transcript_partial,     \* [Nodes -> [TranscriptBuffers -> BOOLEAN]]

    \* ── Outcome tracking ─────────────────────────────────────────────────
    sig_computed            \* BOOLEAN – Responder computed CHALLENGE_AUTH signature

vars == <<connection_state, msgs,
          cert_fetched, cert_hash_valid, challenge_slot, challenge_verify_passed, auth_slot,
          cert_in_transcript_b,
          mut_auth_in_progress, mut_auth_failed,
          mut_c_has_unverified_data, encap_sig_verified,
          transcript_partial, sig_computed>>

\* Variable groups for UNCHANGED clauses
coreVars      == <<connection_state, msgs>>
certVars      == <<cert_fetched, cert_hash_valid, challenge_slot,
                   challenge_verify_passed, auth_slot>>
f1TranscVars  == <<cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified>>
f4Vars        == <<transcript_partial>>
outcomeVars   == <<sig_computed>>

\* ─────────────────────────────────────────────────────────────────────────
\* TYPE INVARIANT
\* ─────────────────────────────────────────────────────────────────────────

MsgType == { GET_DIGESTS_MSG, DIGESTS_MSG,
             GET_CERTIFICATE_MSG, CERTIFICATE_MSG,
             CHALLENGE_MSG, CHALLENGE_AUTH_MSG,
             ENCAP_CHALLENGE_MSG, ENCAP_CHALLENGE_AUTH_MSG }

TypeInvariant ==
    /\ connection_state \in [Nodes -> ConnectionStates]
    /\ msgs \subseteq (
           {[mtype |-> t] : t \in {GET_DIGESTS_MSG, DIGESTS_MSG,
                                   ENCAP_CHALLENGE_MSG, ENCAP_CHALLENGE_AUTH_MSG}}
        \union {[mtype |-> GET_CERTIFICATE_MSG, slot |-> s] : s \in SlotIDs}
        \union {[mtype |-> CERTIFICATE_MSG,     slot |-> s] : s \in SlotIDs}
        \union {[mtype |-> CHALLENGE_MSG,        slot |-> s] : s \in SlotIDs \union {NullSlot}}
        \union {[mtype |-> CHALLENGE_AUTH_MSG,   slot |-> s] : s \in SlotIDs \union {NullSlot}})
    /\ cert_fetched  \in [SlotIDs -> BOOLEAN]
    /\ cert_hash_valid \in [SlotIDs -> BOOLEAN]
    /\ challenge_slot \in SlotIDs \union {NullSlot}
    /\ challenge_verify_passed \in BOOLEAN
    /\ auth_slot \in SlotIDs \union {NullSlot}
    /\ cert_in_transcript_b \in BOOLEAN
    /\ mut_auth_in_progress \in BOOLEAN
    /\ mut_auth_failed \in BOOLEAN
    /\ mut_c_has_unverified_data \in BOOLEAN
    /\ encap_sig_verified \in BOOLEAN
    /\ transcript_partial \in [Nodes -> [TranscriptBuffers -> BOOLEAN]]
    /\ sig_computed \in BOOLEAN

\* ─────────────────────────────────────────────────────────────────────────
\* INITIALIZATION
\* ─────────────────────────────────────────────────────────────────────────

Init ==
    /\ connection_state = [n \in Nodes |-> NOT_STARTED]
    /\ msgs = {}
    /\ cert_fetched  = [s \in SlotIDs |-> FALSE]
    /\ cert_hash_valid = [s \in SlotIDs |-> FALSE]
    /\ challenge_slot = NullSlot
    /\ challenge_verify_passed = FALSE
    /\ auth_slot = NullSlot
    /\ cert_in_transcript_b = FALSE
    /\ mut_auth_in_progress = FALSE
    /\ mut_auth_failed = FALSE
    /\ mut_c_has_unverified_data = FALSE
    /\ encap_sig_verified = FALSE
    /\ transcript_partial = [n \in Nodes |-> [b \in TranscriptBuffers |-> FALSE]]
    /\ sig_computed = FALSE

\* ─────────────────────────────────────────────────────────────────────────
\* HELPERS
\* ─────────────────────────────────────────────────────────────────────────

Send(m)    == msgs' = msgs \union {m}
Consume(m) == msgs' = msgs \ {m}
Reply(old, new) == msgs' = (msgs \ {old}) \union {new}

\* ─────────────────────────────────────────────────────────────────────────
\* ACTIONS
\* ─────────────────────────────────────────────────────────────────────────

(*
 * Negotiate — VCA phase (Version + Capabilities + Algorithms)
 * Collapses three-step handshake into one; not a bug-family target.
 * Both sides advance from NOT_STARTED to NEGOTIATED.
 * include/library/spdm_common_lib.h:201-223 (state constants)
 *)
Negotiate ==
    /\ connection_state[Requester] = NOT_STARTED
    /\ connection_state[Responder] = NOT_STARTED
    /\ connection_state' = [connection_state EXCEPT
                                ![Requester] = NEGOTIATED,
                                ![Responder] = NEGOTIATED]
    /\ UNCHANGED <<msgs, cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * ReqGetDigests — Requester sends GET_DIGESTS
 * libspdm_req_get_digests.c
 * Guard: >= NEGOTIATED (correct guard for GET_DIGESTS)
 *)
ReqGetDigests ==
    /\ StateGe(connection_state[Requester], NEGOTIATED)
    /\ StateLt(connection_state[Requester], AFTER_DIGESTS)
    /\ msgs = {}
    /\ Send([mtype |-> GET_DIGESTS_MSG])
    /\ UNCHANGED <<connection_state, cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * RspGetDigests — Responder handles GET_DIGESTS; appends request then response to message_b
 * libspdm_rsp_digests.c:173-180
 *
 * Happy path: both appends succeed; transcript_partial stays FALSE.
 * Fault path: AppendResponseFail_GetDigests (below) models the partial-append case.
 *)
RspGetDigests ==
    /\ [mtype |-> GET_DIGESTS_MSG] \in msgs
    /\ StateGe(connection_state[Responder], NEGOTIATED)
    /\ Reply([mtype |-> GET_DIGESTS_MSG], [mtype |-> DIGESTS_MSG])
    \* libspdm_set_connection_state(AFTER_DIGESTS) — via callback
    /\ connection_state' = [connection_state EXCEPT ![Responder] = AFTER_DIGESTS]
    /\ UNCHANGED <<cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * ReqDigestsRecv — Requester receives DIGESTS; advances to AFTER_DIGESTS
 * libspdm_req_get_digests.c
 *)
ReqDigestsRecv ==
    /\ [mtype |-> DIGESTS_MSG] \in msgs
    /\ StateGe(connection_state[Requester], NEGOTIATED)
    /\ Consume([mtype |-> DIGESTS_MSG])
    /\ connection_state' = [connection_state EXCEPT ![Requester] = AFTER_DIGESTS]
    /\ UNCHANGED <<cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * ReqGetCertificate(s) — Requester sends GET_CERTIFICATE for slot s
 * libspdm_req_get_certificate.c
 *)
ReqGetCertificate(s) ==
    /\ s \in SlotIDs
    /\ StateGe(connection_state[Requester], AFTER_DIGESTS)
    /\ msgs = {}
    /\ Send([mtype |-> GET_CERTIFICATE_MSG, slot |-> s])
    /\ UNCHANGED <<connection_state, cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * RspGetCertificate(s) — Responder handles GET_CERTIFICATE, normal path (session_id == NULL)
 * libspdm_get_response_certificate()  libspdm_rsp_certificate.c:27-251
 *
 * Normal path: session_id == NULL, so message_b IS appended (lines 224-241).
 * cert_in_transcript_b = TRUE.
 * connection_state advances to AFTER_CERTIFICATE (line 243).
 *)
RspGetCertificate(s) ==
    /\ s \in SlotIDs
    /\ [mtype |-> GET_CERTIFICATE_MSG, slot |-> s] \in msgs
    /\ StateGe(connection_state[Responder], AFTER_DIGESTS)
    /\ Reply([mtype |-> GET_CERTIFICATE_MSG, slot |-> s],
             [mtype |-> CERTIFICATE_MSG, slot |-> s])
    \* line 243: advance state
    /\ connection_state' = [connection_state EXCEPT ![Responder] = AFTER_CERTIFICATE]
    \* lines 224-241: message_b appended (session_id == NULL path)
    /\ cert_in_transcript_b' = TRUE
    /\ UNCHANGED <<cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * RspGetCertificateInSession(s) — Responder handles GET_CERTIFICATE inside a session
 * libspdm_rsp_certificate.c:224-246
 *
 * BUG [F1/MC3]: when session_id != NULL, the guard at lines 224-241 is FALSE,
 * so message_b is NOT appended. But line 243-246 STILL advances connection_state
 * to AFTER_CERTIFICATE unconditionally. State says cert exchanged; message_b does not.
 *
 * Effect: cert_in_transcript_b stays FALSE while connection_state -> AFTER_CERTIFICATE.
 *)
RspGetCertificateInSession(s) ==
    /\ s \in SlotIDs
    /\ [mtype |-> GET_CERTIFICATE_MSG, slot |-> s] \in msgs
    /\ StateGe(connection_state[Responder], AFTER_DIGESTS)
    /\ Reply([mtype |-> GET_CERTIFICATE_MSG, slot |-> s],
             [mtype |-> CERTIFICATE_MSG, slot |-> s])
    \* line 243: state advances unconditionally
    /\ connection_state' = [connection_state EXCEPT ![Responder] = AFTER_CERTIFICATE]
    \* BUG: cert_in_transcript_b NOT set (message_b not appended in session path)
    /\ UNCHANGED <<cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b,          \* intentionally not updated
                   mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * ReqCertificateRecv(s) — Requester receives CERTIFICATE for slot s
 * libspdm_try_get_certificate()  libspdm_req_get_certificate.c
 *
 * On success: cert_fetched[s] = TRUE, cert_hash_valid[s] = TRUE,
 * connection_state[Requester] -> AFTER_CERTIFICATE.
 *)
ReqCertificateRecv(s) ==
    /\ s \in SlotIDs
    /\ [mtype |-> CERTIFICATE_MSG, slot |-> s] \in msgs
    /\ StateGe(connection_state[Requester], AFTER_DIGESTS)
    /\ Consume([mtype |-> CERTIFICATE_MSG, slot |-> s])
    /\ connection_state' = [connection_state EXCEPT ![Requester] = AFTER_CERTIFICATE]
    /\ cert_fetched'    = [cert_fetched    EXCEPT ![s] = TRUE]
    /\ cert_hash_valid' = [cert_hash_valid EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * ReqChallenge(s) — Requester sends CHALLENGE for slot s
 * libspdm_try_challenge()  libspdm_req_challenge.c:43-405
 *
 * BUG [F2]: guard at line 89 only checks >= NEGOTIATED, not >= AFTER_CERTIFICATE.
 * For s != NullSlot this should require cert_fetched[s] = TRUE, but does not.
 * The spec models the ACTUAL weak guard to allow TLC to find F2 violations.
 *)
ReqChallenge(s) ==
    /\ s \in SlotIDs \union {NullSlot}
    \* BUG [F2]: libspdm_req_challenge.c:89 — weak guard, only >= NEGOTIATED
    /\ StateGe(connection_state[Requester], NEGOTIATED)
    /\ msgs = {}
    /\ Send([mtype |-> CHALLENGE_MSG, slot |-> s])
    /\ challenge_slot' = s
    /\ UNCHANGED <<connection_state, cert_fetched, cert_hash_valid,
                   challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * RspChallengeAuth(s) — Responder computes and sends CHALLENGE_AUTH
 * libspdm_get_response_challenge_auth()  libspdm_rsp_challenge_auth.c
 *
 * BUG [F2]: guard at line 64 only checks >= NEGOTIATED on Responder side too.
 * sig_computed = TRUE marks that a signature was computed over current transcript state
 * (which may be partial or missing cert data — the F4 / MC3 concern).
 * Responder's connection_state -> AUTHENTICATED via libspdm_set_connection_state().
 *)
RspChallengeAuth(s) ==
    /\ s \in SlotIDs \union {NullSlot}
    /\ [mtype |-> CHALLENGE_MSG, slot |-> s] \in msgs
    \* BUG [F2]: libspdm_rsp_challenge_auth.c:64 — weak guard
    /\ StateGe(connection_state[Responder], NEGOTIATED)
    /\ Reply([mtype |-> CHALLENGE_MSG, slot |-> s],
             [mtype |-> CHALLENGE_AUTH_MSG, slot |-> s])
    /\ sig_computed' = TRUE
    /\ connection_state' = [connection_state EXCEPT ![Responder] = AUTHENTICATED]
    /\ UNCHANGED <<cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial>>

(*
 * ReqChallengeAuthVerifyPass(s) — Requester receives CHALLENGE_AUTH; cert hash verify PASSES
 * libspdm_try_challenge()  libspdm_req_challenge.c:250-380
 *
 * libspdm_verify_certificate_chain_hash() at line 252 is called with:
 *   - slot_id = s
 *   - peer_cert_chain_hash = stored during GET_CERTIFICATE (may be empty if never fetched)
 *
 * This action models both correct pass (cert_hash_valid[s]=TRUE) AND the adversarial/buggy
 * pass (cert_hash_valid[s]=FALSE, modeling RECORD_TRANSCRIPT=0 production behavior where
 * LIBSPDM_ASSERT is compiled out and comparison against zero-initialized buffer may succeed
 * when adversary provides Hash("") — libspdm_com_crypto_service.c:920-921).
 *
 * Requester sets connection_state = AUTHENTICATED at line 380.
 * NOTE: This is a DIRECT STRUCT WRITE, not libspdm_set_connection_state().
 * Asymmetry with Responder path (libspdm_set_connection_state at rsp_challenge_auth.c:337).
 *)
ReqChallengeAuthVerifyPass(s) ==
    /\ s \in SlotIDs \union {NullSlot}
    /\ [mtype |-> CHALLENGE_AUTH_MSG, slot |-> s] \in msgs
    /\ s = challenge_slot
    \* Verification passes. For NullSlot always allowed.
    \* For real slot: allowed when cert_hash_valid[s] (normal) OR ~cert_hash_valid[s] (bug).
    \* Both are modeled to let TLC find F2 invariant violations.
    /\ Consume([mtype |-> CHALLENGE_AUTH_MSG, slot |-> s])
    /\ challenge_verify_passed' = TRUE
    \* line 380: direct struct write (bypasses callback)
    /\ connection_state' = [connection_state EXCEPT ![Requester] = AUTHENTICATED]
    /\ auth_slot' = s
    /\ UNCHANGED <<cert_fetched, cert_hash_valid, challenge_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * ReqChallengeAuthVerifyFail(s) — Requester receives CHALLENGE_AUTH; cert hash verify FAILS
 * libspdm_try_challenge()  libspdm_req_challenge.c:252-260
 *
 * When verification fails (e.g., slot_id != NullSlot, cert_hash_valid[s] = FALSE in
 * RECORD_TRANSCRIPT=1 mode or assertion fires in debug): returns error, no state advance.
 *)
ReqChallengeAuthVerifyFail(s) ==
    /\ s \in SlotIDs \union {NullSlot}
    /\ [mtype |-> CHALLENGE_AUTH_MSG, slot |-> s] \in msgs
    /\ s = challenge_slot
    /\ s /= NullSlot                \* NullSlot always passes; only real slots can fail
    /\ ~cert_hash_valid[s]          \* cert was not fetched — the precondition deficiency
    /\ Consume([mtype |-> CHALLENGE_AUTH_MSG, slot |-> s])
    /\ challenge_verify_passed' = FALSE
    \* No state advance on failure
    /\ UNCHANGED <<connection_state, cert_fetched, cert_hash_valid, challenge_slot,
                   auth_slot, cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * ReqSetAuthenticatedPrematurely(s) — CHALLENGE with MutAuth; premature AUTHENTICATED set
 * libspdm_try_challenge()  libspdm_req_challenge.c:365-392
 *
 * BUG [F1/MC2/Issue #3059]:
 * Line 380: connection_state[Requester] = AUTHENTICATED set BEFORE libspdm_encapsulated_request()
 * returns (line 392). mut_auth_in_progress = TRUE marks this intermediate buggy state.
 * WG-approved fix: move line 380 assignment to after line 392 check.
 *)
ReqSetAuthenticatedPrematurely(s) ==
    /\ s \in SlotIDs \union {NullSlot}
    /\ [mtype |-> CHALLENGE_AUTH_MSG, slot |-> s] \in msgs
    /\ s = challenge_slot
    \* Local cert-hash verify would pass (precondition for reaching line 380)
    /\ (IF s = NullSlot THEN TRUE ELSE cert_hash_valid[s])
    /\ Consume([mtype |-> CHALLENGE_AUTH_MSG, slot |-> s])
    \* BUG line 380: set AUTHENTICATED BEFORE encap completes
    /\ connection_state' = [connection_state EXCEPT ![Requester] = AUTHENTICATED]
    /\ mut_auth_in_progress' = TRUE
    /\ auth_slot' = s
    /\ challenge_verify_passed' = TRUE
    /\ UNCHANGED <<cert_fetched, cert_hash_valid, challenge_slot,
                   cert_in_transcript_b, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * ReqEncapRequestSuccess — libspdm_encapsulated_request() returns SUCCESS
 * libspdm_req_challenge.c:392
 *)
ReqEncapRequestSuccess ==
    /\ mut_auth_in_progress = TRUE
    /\ msgs = {}
    /\ mut_auth_in_progress' = FALSE
    /\ mut_auth_failed' = FALSE
    /\ UNCHANGED <<connection_state, msgs, cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * ReqEncapRequestFail — libspdm_encapsulated_request() returns non-SUCCESS
 * libspdm_req_challenge.c:392-405
 *
 * BUG [F1/Issue #3059]: lines 393-396 reset message_c but do NOT reset connection_state.
 * connection_state remains AUTHENTICATED despite mutual auth failure.
 * Correct fix: set connection_state back to AFTER_CERTIFICATE before returning error.
 *)
ReqEncapRequestFail ==
    /\ mut_auth_in_progress = TRUE
    /\ msgs = {}
    /\ mut_auth_in_progress' = FALSE
    /\ mut_auth_failed' = TRUE
    \* BUG: connection_state NOT rolled back — stays AUTHENTICATED
    /\ UNCHANGED <<connection_state, msgs, cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * ReqEncapChallengeAuthSend — Requester receives encap CHALLENGE, replies with CHALLENGE_AUTH
 * libspdm_req_challenge.c (encapsulated_request path)
 * Requester processes encap CHALLENGE from Responder and sends its CHALLENGE_AUTH.
 *)
ReqEncapChallengeAuthSend ==
    /\ [mtype |-> ENCAP_CHALLENGE_MSG] \in msgs
    /\ mut_auth_in_progress = TRUE
    /\ Reply([mtype |-> ENCAP_CHALLENGE_MSG], [mtype |-> ENCAP_CHALLENGE_AUTH_MSG])
    /\ UNCHANGED <<connection_state, cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * RspEncapChallengeSend — Responder sends encap CHALLENGE (mutual auth)
 * libspdm_rsp_encap_challenge.c:163-342
 *)
RspEncapChallengeSend ==
    /\ mut_auth_in_progress = TRUE
    /\ msgs = {}
    /\ Send([mtype |-> ENCAP_CHALLENGE_MSG])
    /\ UNCHANGED <<connection_state, cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * RspEncapChallengeAuthSuccess — Responder receives encap CHALLENGE_AUTH; sig verify passes
 * libspdm_rsp_encap_challenge.c:248-260
 *
 * Correct path: append to message_mut_c (line 248), verify sig (line 257), success.
 * mut_c_has_unverified_data cleared; encap_sig_verified set TRUE.
 *)
RspEncapChallengeAuthSuccess ==
    /\ [mtype |-> ENCAP_CHALLENGE_AUTH_MSG] \in msgs
    /\ Consume([mtype |-> ENCAP_CHALLENGE_AUTH_MSG])
    \* line 248: append message_mut_c; line 257: sig verify passes
    /\ mut_c_has_unverified_data' = FALSE
    /\ encap_sig_verified' = TRUE
    /\ UNCHANGED <<connection_state, cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   transcript_partial, sig_computed>>

(*
 * RspEncapChallengeAuthFail — Responder's encap sig verify FAILS; message_mut_c not reset
 * libspdm_rsp_encap_challenge.c:248-260
 *
 * BUG [F1/TV1]:
 * Line 248: message_mut_c appended → mut_c_has_unverified_data = TRUE.
 * Line 257: sig verify fails (line 259: return error).
 * BUG: NO libspdm_reset_message_mut_c() call. message_mut_c left dirty.
 * Compare with libspdm_req_challenge.c:365 which DOES call libspdm_reset_message_c() on failure.
 *)
RspEncapChallengeAuthFail ==
    /\ [mtype |-> ENCAP_CHALLENGE_AUTH_MSG] \in msgs
    /\ Consume([mtype |-> ENCAP_CHALLENGE_AUTH_MSG])
    \* line 248: mut_c appended (dirty)
    /\ mut_c_has_unverified_data' = TRUE
    \* BUG: no reset — encap_sig_verified stays FALSE
    /\ UNCHANGED <<connection_state, cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   encap_sig_verified,
                   transcript_partial, sig_computed>>

(*
 * AppendResponseFail_GetDigests — Response append fails during GET_DIGESTS exchange
 * libspdm_rsp_digests.c:173-180
 *
 * Fault injection [F4/Issue #524]:
 * Request was appended at line 173 (cannot be unappended — hash extend).
 * Response append at line 180 fails.
 * transcript_partial[Responder][MSG_B] = TRUE marks the partial state.
 * State does NOT advance (Responder returns error).
 *)
AppendResponseFail_GetDigests ==
    /\ [mtype |-> GET_DIGESTS_MSG] \in msgs
    /\ StateGe(connection_state[Responder], NEGOTIATED)
    /\ transcript_partial' = [transcript_partial EXCEPT
                                  ![Responder][MSG_B] = TRUE]
    /\ UNCHANGED <<connection_state, msgs, cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   sig_computed>>

(*
 * AppendResponseFail_GetCertificate(s) — Response append fails during GET_CERTIFICATE
 * libspdm_rsp_certificate.c:228-235
 *
 * Fault injection [F4]: same partial-append pattern as GET_DIGESTS.
 *)
AppendResponseFail_GetCertificate(s) ==
    /\ s \in SlotIDs
    /\ [mtype |-> GET_CERTIFICATE_MSG, slot |-> s] \in msgs
    /\ StateGe(connection_state[Responder], AFTER_DIGESTS)
    /\ transcript_partial' = [transcript_partial EXCEPT
                                  ![Responder][MSG_B] = TRUE]
    /\ UNCHANGED <<connection_state, msgs, cert_fetched, cert_hash_valid,
                   challenge_slot, challenge_verify_passed, auth_slot,
                   cert_in_transcript_b, mut_auth_in_progress, mut_auth_failed,
                   mut_c_has_unverified_data, encap_sig_verified,
                   sig_computed>>

\* ─────────────────────────────────────────────────────────────────────────
\* NEXT STATE RELATION
\* ─────────────────────────────────────────────────────────────────────────

Next ==
    \/ Negotiate
    \/ ReqGetDigests
    \/ RspGetDigests
    \/ ReqDigestsRecv
    \/ \E s \in SlotIDs :
        \/ ReqGetCertificate(s)
        \/ RspGetCertificate(s)
        \/ RspGetCertificateInSession(s)
        \/ ReqCertificateRecv(s)
        \/ AppendResponseFail_GetCertificate(s)
    \/ \E s \in SlotIDs \union {NullSlot} :
        \/ ReqChallenge(s)
        \/ RspChallengeAuth(s)
        \/ ReqChallengeAuthVerifyPass(s)
        \/ ReqChallengeAuthVerifyFail(s)
        \/ ReqSetAuthenticatedPrematurely(s)
    \/ ReqEncapRequestSuccess
    \/ ReqEncapRequestFail
    \/ ReqEncapChallengeAuthSend
    \/ RspEncapChallengeSend
    \/ RspEncapChallengeAuthSuccess
    \/ RspEncapChallengeAuthFail
    \/ AppendResponseFail_GetDigests

Spec == Init /\ [][Next]_vars

\* ─────────────────────────────────────────────────────────────────────────
\* SAFETY INVARIANTS
\* ─────────────────────────────────────────────────────────────────────────

\* ── F2: CHALLENGE precondition invariants ────────────────────────────────

(*
 * AuthImpliesCertFetched [F2/MC1]
 * Requester AUTHENTICATED with a real slot => cert was fetched for that slot.
 *
 * Violation path: ReqChallenge(s) with ~cert_fetched[s] (weak guard allows it)
 * → RspChallengeAuth → ReqChallengeAuthVerifyPass (adversary provides matching hash)
 * → connection_state[Requester]=AUTHENTICATED, auth_slot=s, cert_fetched[s]=FALSE.
 *)
AuthImpliesCertFetched ==
    (connection_state[Requester] = AUTHENTICATED /\ auth_slot /= NullSlot)
    => cert_fetched[auth_slot]

(*
 * ChallengeHashMatchesFetch [F2/MC1]
 * VerifyCertHash passed for real slot => cert hash was stored from a prior GET_CERTIFICATE.
 *
 * Violation: challenge_verify_passed=TRUE with cert_hash_valid[challenge_slot]=FALSE.
 *)
ChallengeHashMatchesFetch ==
    (challenge_verify_passed /\ challenge_slot /= NullSlot)
    => cert_hash_valid[challenge_slot]

\* ── F1: Connection state / transcript desynchronization ──────────────────

(*
 * CertInTranscriptOnAuthenticated [F1/MC3]
 * When Responder has sent CHALLENGE_AUTH (AUTHENTICATED), cert hash must be in message_b.
 *
 * Violation path: RspGetCertificateInSession advances connection_state without setting
 * cert_in_transcript_b; then RspChallengeAuth sets AUTHENTICATED with cert_in_transcript_b=FALSE.
 *)
CertInTranscriptOnAuthenticated ==
    \* Only required when cert was actually fetched (F1/MC3: session path skips message_b append).
    \* Excludes F2 scenario (cert never fetched at all) and NullSlot (no cert).
    (connection_state[Responder] = AUTHENTICATED
     /\ challenge_slot \in SlotIDs
     /\ cert_fetched[challenge_slot])
    => cert_in_transcript_b

(*
 * MutAuthCompleteBeforeStayAuthenticated [F1/MC2]
 * After mutual auth failure, Requester must NOT remain AUTHENTICATED.
 *
 * Violation path: ReqSetAuthenticatedPrematurely → connection_state=AUTHENTICATED,
 * mut_auth_in_progress=TRUE. ReqEncapRequestFail → mut_auth_failed=TRUE but does NOT
 * reset connection_state. Invariant fires: mut_auth_failed /\ connection_state=AUTHENTICATED.
 *)
MutAuthCompleteBeforeStayAuthenticated ==
    mut_auth_failed => connection_state[Requester] /= AUTHENTICATED

(*
 * EncapMutCCleanAfterFailure [F1/TV1]
 * After encap sig verify failure, message_mut_c must not contain unverified data.
 *
 * In the spec: RspEncapChallengeAuthFail sets mut_c_has_unverified_data=TRUE
 * and leaves encap_sig_verified=FALSE. The message is consumed so the check applies
 * once the ENCAP_CHALLENGE_AUTH_MSG is no longer in msgs.
 *
 * Violation fires immediately after RspEncapChallengeAuthFail runs:
 * mut_c_has_unverified_data=TRUE, encap_sig_verified=FALSE, msg consumed.
 *)
EncapMutCCleanAfterFailure ==
    (~encap_sig_verified /\ [mtype |-> ENCAP_CHALLENGE_AUTH_MSG] \notin msgs
     /\ \E s \in SlotIDs \union {NullSlot} :
         [mtype |-> CHALLENGE_AUTH_MSG, slot |-> s] \notin msgs)
    => ~mut_c_has_unverified_data

\* ── F4: Transcript integrity ─────────────────────────────────────────────

(*
 * NoPartialTranscriptOnChallenge [F4]
 * When CHALLENGE_AUTH signature is computed, message_b must not be in a partial state.
 *
 * Violation path: AppendResponseFail_GetDigests sets transcript_partial[Responder][MSG_B]=TRUE,
 * then RspChallengeAuth sets sig_computed=TRUE. Connection is then based on a corrupted transcript.
 *)
NoPartialTranscriptOnChallenge ==
    sig_computed => ~transcript_partial[Responder][MSG_B]

\* ── Structural invariants ─────────────────────────────────────────────────

TypeOK == TypeInvariant

\* At most one message in flight (sequential protocol)
AtMostOneInFlight ==
    Cardinality(msgs) <= 1

\* cert_fetched implies cert_hash_valid (fetching cert sets both)
CertFetchedImpliesHashValid ==
    \A s \in SlotIDs : cert_fetched[s] => cert_hash_valid[s]

\* Once AUTHENTICATED, stay AUTHENTICATED (no state regression for AUTHENTICATED)
\* Checked as a TLA+ invariant on pairs (not a temporal property — see MC.cfg)
AuthenticatedIsTerminal ==
    connection_state[Requester] = AUTHENTICATED =>
        ~mut_auth_failed    \* unless mut auth was ongoing when failure struck (the bug)

=============================================================================
