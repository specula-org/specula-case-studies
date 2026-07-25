--------------------------- MODULE MC ---------------------------
(*
 * Model-checking wrapper for the SPDM CHALLENGE auth base spec.
 * Wraps fault-injection actions with counters to bound state space.
 *
 * Fault-injection actions (bounded):
 *   RspGetCertificateInSession  — F1/MC3: session-path cert without message_b append
 *   ReqChallengeAuthVerifyPass  — F2/MC1: cert hash verify passes without prior GET_CERT
 *   ReqSetAuthenticatedPrematurely + ReqEncapRequestFail — F1/MC2: premature AUTHENTICATED
 *   RspEncapChallengeAuthFail   — F1/TV1: encap mut_c not reset on sig failure
 *   AppendResponseFail_GetDigests / AppendResponseFail_GetCertificate — F4: partial transcript
 *
 * Reactive/deterministic actions (NOT bounded):
 *   Negotiate, ReqGetDigests, RspGetDigests, ReqDigestsRecv,
 *   ReqGetCertificate, RspGetCertificate, ReqCertificateRecv,
 *   ReqChallenge, RspChallengeAuth, ReqChallengeAuthVerifyFail,
 *   ReqEncapRequestSuccess, RspEncapChallengeSend, RspEncapChallengeAuthSuccess
 *)
EXTENDS base, Integers

\* ── Fault counters ────────────────────────────────────────────────────────

CONSTANTS
    MaxInSessionCertLimit,      \* RspGetCertificateInSession firings
    MaxVerifyPassLimit,         \* ReqChallengeAuthVerifyPass without cert firings
    MaxPrematureAuthLimit,      \* ReqSetAuthenticatedPrematurely firings
    MaxEncapFailLimit,          \* RspEncapChallengeAuthFail firings
    MaxPartialTranscriptLimit   \* AppendResponseFail_* firings

VARIABLE faultVars

\* ── Counters initial value ─────────────────────────────────────────────────

MCFaultInit ==
    /\ faultVars = [
        inSessionCert      |-> 0,
        verifyPass         |-> 0,
        prematureAuth      |-> 0,
        encapFail          |-> 0,
        partialTranscript  |-> 0
       ]

\* ── Bounded fault wrappers ──────────────────────────────────────────────────

\* F1/MC3: session-path GET_CERTIFICATE without message_b append
MCRspGetCertificateInSession(s) ==
    /\ faultVars.inSessionCert < MaxInSessionCertLimit
    /\ RspGetCertificateInSession(s)
    /\ faultVars' = [faultVars EXCEPT !.inSessionCert = @ + 1]

\* F2/MC1: cert hash verify passes even when cert not fetched
\* Models RECORD_TRANSCRIPT=0 production behavior: LIBSPDM_ASSERT compiled out,
\* comparison against zero-initialized buffer may succeed with adversarial response.
\* libspdm_com_crypto_service.c:920-921
MCReqChallengeAuthVerifyPass(s) ==
    /\ faultVars.verifyPass < MaxVerifyPassLimit
    /\ ReqChallengeAuthVerifyPass(s)
    /\ faultVars' = [faultVars EXCEPT !.verifyPass = @ + 1]

\* F1/MC2: premature AUTHENTICATED before encap completes
MCReqSetAuthenticatedPrematurely(s) ==
    /\ faultVars.prematureAuth < MaxPrematureAuthLimit
    /\ ReqSetAuthenticatedPrematurely(s)
    /\ faultVars' = [faultVars EXCEPT !.prematureAuth = @ + 1]

\* F1/TV1: encap mut_c not reset on sig failure
MCRspEncapChallengeAuthFail ==
    /\ faultVars.encapFail < MaxEncapFailLimit
    /\ RspEncapChallengeAuthFail
    /\ faultVars' = [faultVars EXCEPT !.encapFail = @ + 1]

\* F4: response append fails (partial transcript)
MCAppendResponseFail_GetDigests ==
    /\ faultVars.partialTranscript < MaxPartialTranscriptLimit
    /\ AppendResponseFail_GetDigests
    /\ faultVars' = [faultVars EXCEPT !.partialTranscript = @ + 1]

MCAppendResponseFail_GetCertificate(s) ==
    /\ faultVars.partialTranscript < MaxPartialTranscriptLimit
    /\ AppendResponseFail_GetCertificate(s)
    /\ faultVars' = [faultVars EXCEPT !.partialTranscript = @ + 1]

\* ── Unchanged wrappers for reactive actions ──────────────────────────────

MCNegotiate ==
    /\ Negotiate
    /\ UNCHANGED faultVars

MCReqGetDigests ==
    /\ ReqGetDigests
    /\ UNCHANGED faultVars

MCRspGetDigests ==
    /\ RspGetDigests
    /\ UNCHANGED faultVars

MCReqDigestsRecv ==
    /\ ReqDigestsRecv
    /\ UNCHANGED faultVars

MCReqGetCertificate(s) ==
    /\ ReqGetCertificate(s)
    /\ UNCHANGED faultVars

MCRspGetCertificate(s) ==
    /\ RspGetCertificate(s)
    /\ UNCHANGED faultVars

MCReqCertificateRecv(s) ==
    /\ ReqCertificateRecv(s)
    /\ UNCHANGED faultVars

MCReqChallenge(s) ==
    /\ ReqChallenge(s)
    /\ UNCHANGED faultVars

MCRspChallengeAuth(s) ==
    /\ RspChallengeAuth(s)
    /\ UNCHANGED faultVars

MCReqChallengeAuthVerifyFail(s) ==
    /\ ReqChallengeAuthVerifyFail(s)
    /\ UNCHANGED faultVars

MCReqEncapRequestSuccess ==
    /\ ReqEncapRequestSuccess
    /\ UNCHANGED faultVars

MCReqEncapRequestFail ==
    /\ ReqEncapRequestFail
    /\ UNCHANGED faultVars

MCReqEncapChallengeAuthSend ==
    /\ ReqEncapChallengeAuthSend
    /\ UNCHANGED faultVars

MCRspEncapChallengeSend ==
    /\ RspEncapChallengeSend
    /\ UNCHANGED faultVars

MCRspEncapChallengeAuthSuccess ==
    /\ RspEncapChallengeAuthSuccess
    /\ UNCHANGED faultVars

\* ── MCInit / MCNext ───────────────────────────────────────────────────────

MCInit ==
    /\ Init
    /\ MCFaultInit

MCNext ==
    \/ MCNegotiate
    \/ MCReqGetDigests
    \/ MCRspGetDigests
    \/ MCReqDigestsRecv
    \/ \E s \in SlotIDs :
        \/ MCReqGetCertificate(s)
        \/ MCRspGetCertificate(s)
        \/ MCRspGetCertificateInSession(s)
        \/ MCReqCertificateRecv(s)
        \/ MCAppendResponseFail_GetCertificate(s)
    \/ \E s \in SlotIDs \union {NullSlot} :
        \/ MCReqChallenge(s)
        \/ MCRspChallengeAuth(s)
        \/ MCReqChallengeAuthVerifyPass(s)
        \/ MCReqChallengeAuthVerifyFail(s)
        \/ MCReqSetAuthenticatedPrematurely(s)
    \/ MCReqEncapRequestSuccess
    \/ MCReqEncapRequestFail
    \/ MCReqEncapChallengeAuthSend
    \/ MCRspEncapChallengeSend
    \/ MCRspEncapChallengeAuthSuccess
    \/ MCRspEncapChallengeAuthFail
    \/ MCAppendResponseFail_GetDigests

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

\* ── View (exclude counters from state deduplication) ─────────────────────
MCView == vars

\* ── Message buffer constraint ────────────────────────────────────────────
\* The sequential protocol should have at most 1 message in flight.
MCMsgConstraint == Cardinality(msgs) <= 1

\* ── Structural invariants ─────────────────────────────────────────────────

MCTypeOK        == TypeOK
MCAtMostOneInFlight == AtMostOneInFlight
MCCertFetchedImpliesHashValid == CertFetchedImpliesHashValid

\* ── Extension invariants — enabled for hunt configs ─────────────────────

MCAuthImpliesCertFetched              == AuthImpliesCertFetched
MCChallengeHashMatchesFetch           == ChallengeHashMatchesFetch
MCCertInTranscriptOnAuthenticated     == CertInTranscriptOnAuthenticated
MCMutAuthCompleteBeforeStayAuthenticated == MutAuthCompleteBeforeStayAuthenticated
MCEncapMutCCleanAfterFailure          == EncapMutCCleanAfterFailure
MCNoPartialTranscriptOnChallenge      == NoPartialTranscriptOnChallenge

=============================================================================
