--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation spec for SPDM CHALLENGE auth.
 * Drives TLC through a recorded execution trace from libspdm instrumentation,
 * verifying that base.tla can reproduce every observed state transition.
 *
 * Category A (Distributed / Message-Passing) — single-file linear trace.
 * Trace file format: NDJSON, one JSON object per line.
 * Default trace file: ../traces/trace.ndjson (override via IOEnv.JSON).
 *)
EXTENDS base, Sequences, TLC, IOUtils, Json

\* ── Trace file ────────────────────────────────────────────────────────────

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* ── Cursor ────────────────────────────────────────────────────────────────

VARIABLE l      \* cursor into TraceLog; starts at 1

\* Current trace line
logline == TraceLog[l]

\* ── Role and node mapping ─────────────────────────────────────────────────

\* Map implementation role string -> spec constant
RoleToNode(role) ==
    CASE role = "requester" -> Requester
    []   role = "responder" -> Responder

\* Map implementation state string -> spec constant
StateStrToConst(s) ==
    CASE s = "NOT_STARTED"        -> NOT_STARTED
    []   s = "AFTER_VERSION"      -> AFTER_VERSION
    []   s = "AFTER_CAPABILITIES" -> AFTER_CAPABILITIES
    []   s = "NEGOTIATED"         -> NEGOTIATED
    []   s = "AFTER_DIGESTS"      -> AFTER_DIGESTS
    []   s = "AFTER_CERTIFICATE"  -> AFTER_CERTIFICATE
    []   s = "AUTHENTICATED"      -> AUTHENTICATED

\* ── Event predicates ──────────────────────────────────────────────────────

IsEvent(name)              == l <= Len(TraceLog) /\ logline.event = name
IsNodeEvent(name, node_str) == l <= Len(TraceLog) /\ logline.event = name /\ logline.node = node_str

\* ── Post-state validation helpers ────────────────────────────────────────

\* Validate connection_state for a node matches the trace (post-action)
ValidateConnectionState(node_str) ==
    connection_state'[RoleToNode(node_str)] =
        StateStrToConst(logline.connection_state)

\* Validate cert_fetched for a slot (post-action)
ValidateCertFetched(s) ==
    cert_fetched'[s] = logline.cert_fetched

\* Validate cert_hash_valid for a slot (post-action)
ValidateCertHashValid(s) ==
    cert_hash_valid'[s] = logline.cert_hash_valid

\* ── Bootstrap state ───────────────────────────────────────────────────────
(*
 * TraceInit may differ from base Init when the trace starts mid-protocol
 * (e.g., after VCA negotiation). Map the first trace event to initial spec state.
 *)
TraceInit ==
    /\ l = 1
    /\ Init  \* libspdm connection starts from NOT_STARTED; trace starts at Negotiate

\* ── Action wrappers ───────────────────────────────────────────────────────

(*
 * TraceNegotiate — matches "negotiate" event
 * Emitted after VCA completes; both sides reach NEGOTIATED.
 *)
TraceNegotiate ==
    /\ IsEvent("negotiate")
    /\ Negotiate
    /\ ValidateConnectionState(logline.node)
    /\ l' = l + 1

(*
 * TraceReqGetDigests — matches "req_get_digests" event
 *)
TraceReqGetDigests ==
    /\ IsNodeEvent("req_get_digests", "requester")
    /\ ReqGetDigests
    /\ ValidateConnectionState("requester")
    /\ l' = l + 1

(*
 * TraceRspGetDigests — matches "rsp_get_digests" event
 *)
TraceRspGetDigests ==
    /\ IsNodeEvent("rsp_get_digests", "responder")
    /\ RspGetDigests
    /\ ValidateConnectionState("responder")
    /\ l' = l + 1

(*
 * TraceReqDigestsRecv — matches "req_digests_recv" event
 *)
TraceReqDigestsRecv ==
    /\ IsNodeEvent("req_digests_recv", "requester")
    /\ ReqDigestsRecv
    /\ ValidateConnectionState("requester")
    /\ l' = l + 1

(*
 * TraceReqGetCertificate — matches "req_get_certificate" event
 * logline.slot: slot ID (integer)
 *)
TraceReqGetCertificate ==
    /\ IsNodeEvent("req_get_certificate", "requester")
    /\ LET s == logline.slot IN
       /\ s \in SlotIDs
       /\ ReqGetCertificate(s)
    /\ ValidateConnectionState("requester")
    /\ l' = l + 1

(*
 * TraceRspGetCertificate — matches "rsp_get_certificate" event (normal path)
 * Instrumented after cert is appended to message_b (session_id == NULL path).
 *)
TraceRspGetCertificate ==
    /\ IsNodeEvent("rsp_get_certificate", "responder")
    /\ logline.in_session = FALSE
    /\ LET s == logline.slot IN
       /\ s \in SlotIDs
       /\ RspGetCertificate(s)
    /\ ValidateConnectionState("responder")
    /\ cert_in_transcript_b' = TRUE   \* post-state check
    /\ l' = l + 1

(*
 * TraceRspGetCertificateInSession — matches "rsp_get_certificate" with in_session=TRUE
 * BUG path: cert_in_transcript_b should remain FALSE after this event.
 *)
TraceRspGetCertificateInSession ==
    /\ IsNodeEvent("rsp_get_certificate", "responder")
    /\ logline.in_session = TRUE
    /\ LET s == logline.slot IN
       /\ s \in SlotIDs
       /\ RspGetCertificateInSession(s)
    /\ ValidateConnectionState("responder")
    \* Post-state check: cert_in_transcript_b must NOT have been set (bug: no message_b append)
    \* UNCHANGED cert_in_transcript_b in base action handles this; invariant CertInTranscriptOnAuthenticated
    \* will fire later when AUTHENTICATED is reached without cert_in_transcript_b being TRUE.
    /\ l' = l + 1

(*
 * TraceReqCertificateRecv — matches "req_certificate_recv" event
 *)
TraceReqCertificateRecv ==
    /\ IsNodeEvent("req_certificate_recv", "requester")
    /\ LET s == logline.slot IN
       /\ s \in SlotIDs
       /\ ReqCertificateRecv(s)
    /\ ValidateConnectionState("requester")
    /\ ValidateCertFetched(logline.slot)
    /\ ValidateCertHashValid(logline.slot)
    /\ l' = l + 1

(*
 * TraceReqChallenge — matches "req_challenge" event
 *)
TraceReqChallenge ==
    /\ IsNodeEvent("req_challenge", "requester")
    /\ LET s == logline.slot IN
       /\ s \in SlotIDs \union {NullSlot}
       /\ ReqChallenge(s)
    /\ challenge_slot' = logline.slot
    /\ l' = l + 1

(*
 * TraceRspChallengeAuth — matches "rsp_challenge_auth" event
 *)
TraceRspChallengeAuth ==
    /\ IsNodeEvent("rsp_challenge_auth", "responder")
    /\ LET s == logline.slot IN
       /\ s \in SlotIDs \union {NullSlot}
       /\ RspChallengeAuth(s)
    /\ ValidateConnectionState("responder")
    /\ sig_computed' = TRUE
    /\ l' = l + 1

(*
 * TraceReqChallengeAuthVerifyPass — matches "req_challenge_auth_recv" with result="pass"
 *)
TraceReqChallengeAuthVerifyPass ==
    /\ IsNodeEvent("req_challenge_auth_recv", "requester")
    /\ logline.verify_result = "pass"
    /\ LET s == logline.slot IN
       /\ s \in SlotIDs \union {NullSlot}
       /\ ReqChallengeAuthVerifyPass(s)
    /\ ValidateConnectionState("requester")
    /\ challenge_verify_passed' = TRUE
    /\ l' = l + 1

(*
 * TraceReqChallengeAuthVerifyFail — matches "req_challenge_auth_recv" with result="fail"
 *)
TraceReqChallengeAuthVerifyFail ==
    /\ IsNodeEvent("req_challenge_auth_recv", "requester")
    /\ logline.verify_result = "fail"
    /\ LET s == logline.slot IN
       /\ s \in SlotIDs \union {NullSlot}
       /\ ReqChallengeAuthVerifyFail(s)
    /\ challenge_verify_passed' = FALSE
    /\ l' = l + 1

(*
 * TraceReqSetAuthenticatedPrematurely — matches "req_premature_authenticated" event
 * BUG path: emitted at libspdm_req_challenge.c:380 when mut_auth flag is set.
 *)
TraceReqSetAuthenticatedPrematurely ==
    /\ IsNodeEvent("req_premature_authenticated", "requester")
    /\ LET s == logline.slot IN
       /\ s \in SlotIDs \union {NullSlot}
       /\ ReqSetAuthenticatedPrematurely(s)
    /\ ValidateConnectionState("requester")
    /\ mut_auth_in_progress' = TRUE
    /\ l' = l + 1

(*
 * TraceReqEncapRequestFail — matches "req_encap_fail" event
 * BUG path: connection_state remains AUTHENTICATED.
 *)
TraceReqEncapRequestFail ==
    /\ IsNodeEvent("req_encap_fail", "requester")
    /\ ReqEncapRequestFail
    /\ ValidateConnectionState("requester")    \* still AUTHENTICATED (the bug)
    /\ mut_auth_failed' = TRUE
    /\ l' = l + 1

(*
 * TraceRspEncapChallengeAuthFail — matches "rsp_encap_sig_fail" event
 * BUG path: mut_c_has_unverified_data remains TRUE after handler returns.
 *)
TraceRspEncapChallengeAuthFail ==
    /\ IsNodeEvent("rsp_encap_sig_fail", "responder")
    /\ RspEncapChallengeAuthFail
    /\ mut_c_has_unverified_data' = TRUE    \* dirty flag set (the bug)
    /\ l' = l + 1

(*
 * TraceAppendResponseFail_GetDigests — matches "rsp_digest_append_fail" event
 * F4 path: partial transcript in message_b.
 *)
TraceAppendResponseFail_GetDigests ==
    /\ IsNodeEvent("rsp_digest_append_fail", "responder")
    /\ AppendResponseFail_GetDigests
    \* post-state: transcript_partial[Responder][MSG_B] = TRUE (set by base action)
    /\ l' = l + 1

(*
 * TraceAppendResponseFail_GetCertificate — matches "rsp_cert_append_fail" event
 *)
TraceAppendResponseFail_GetCertificate ==
    /\ IsNodeEvent("rsp_cert_append_fail", "responder")
    /\ LET s == logline.slot IN
       /\ s \in SlotIDs
       /\ AppendResponseFail_GetCertificate(s)
    \* post-state: transcript_partial[Responder][MSG_B] = TRUE (set by base action)
    /\ l' = l + 1

\* ── Silent actions ────────────────────────────────────────────────────────
(*
 * Silent actions handle base spec steps that have no trace event.
 * All are tightly constrained to prevent state space explosion.
 *)

\* ReqEncapRequestSuccess: no trace event; fires when encap succeeds (no failure event emitted)
SilentReqEncapRequestSuccess ==
    /\ l <= Len(TraceLog)
    /\ mut_auth_in_progress = TRUE
    \* Only fire if next trace event is NOT req_encap_fail (avoid conflicting with failure path)
    /\ logline.event /= "req_encap_fail"
    /\ ReqEncapRequestSuccess
    /\ UNCHANGED l

\* RspEncapChallengeSend: encap challenge sent; no separate trace event (embedded in CHALLENGE_AUTH)
SilentRspEncapChallengeSend ==
    /\ l <= Len(TraceLog)
    /\ mut_auth_in_progress = TRUE
    /\ [mtype |-> ENCAP_CHALLENGE_MSG] \notin msgs
    /\ RspEncapChallengeSend
    /\ UNCHANGED l

\* RspEncapChallengeAuthSuccess: if no failure event, encap succeeded silently
SilentRspEncapChallengeAuthSuccess ==
    /\ l <= Len(TraceLog)
    /\ [mtype |-> ENCAP_CHALLENGE_AUTH_MSG] \in msgs
    /\ logline.event /= "rsp_encap_sig_fail"
    /\ RspEncapChallengeAuthSuccess
    /\ UNCHANGED l

\* ── TraceNext ─────────────────────────────────────────────────────────────

TraceNext ==
    \/ TraceNegotiate
    \/ TraceReqGetDigests
    \/ TraceRspGetDigests
    \/ TraceReqDigestsRecv
    \/ TraceReqGetCertificate
    \/ TraceRspGetCertificate
    \/ TraceRspGetCertificateInSession
    \/ TraceReqCertificateRecv
    \/ TraceReqChallenge
    \/ TraceRspChallengeAuth
    \/ TraceReqChallengeAuthVerifyPass
    \/ TraceReqChallengeAuthVerifyFail
    \/ TraceReqSetAuthenticatedPrematurely
    \/ TraceReqEncapRequestFail
    \/ TraceRspEncapChallengeAuthFail
    \/ TraceAppendResponseFail_GetDigests
    \/ TraceAppendResponseFail_GetCertificate
    \* Silent actions
    \/ SilentReqEncapRequestSuccess
    \/ SilentRspEncapChallengeSend
    \/ SilentRspEncapChallengeAuthSuccess

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>> /\ WF_<<vars,l>>(TraceNext)

\* ── Termination property ──────────────────────────────────────────────────
\* TraceMatched: the entire trace was consumed. Without this in Trace.cfg,
\* TLC reports "no errors" even when l never advances.
TraceMatched == <>(l > Len(TraceLog))

=============================================================================
