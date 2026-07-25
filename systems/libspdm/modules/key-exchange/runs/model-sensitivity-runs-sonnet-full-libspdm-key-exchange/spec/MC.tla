---- MODULE MC ----
(***************************************************************************)
(* MC wrapper for base (SpdmKeyExchange).                                  *)
(* Bounds fault-injection actions with per-action counters.                *)
(* Standard safety + structural invariants active; extension (bug-family)  *)
(* invariants commented out here — enabled individually in MC_hunt_*.cfg.  *)
(***************************************************************************)
EXTENDS base, Naturals, TLC

CONSTANTS
    MaxKeyExchanges,    \* Bound on total KEY_EXCHANGE sends (per-session nondeterminism)
    MaxEncodeFailures,  \* [F3] Bound on RspEncodeFailure firings
    MaxInjections,      \* [F4] Bound on InjectBadMessage firings
    MaxAppDataSends     \* Bound on ReqSendAppData firings

\* Per-action counters for bounded fault injection
VARIABLE kexCount
VARIABLE encodeFailCount
VARIABLE injectCount
VARIABLE appDataCount

\* Group all counters for UNCHANGED clauses
faultVars == <<kexCount, encodeFailCount, injectCount, appDataCount>>

MCInit ==
    /\ Init
    /\ kexCount       = 0
    /\ encodeFailCount = 0
    /\ injectCount    = 0
    /\ appDataCount   = 0

\* ----------------------------------------------------------------
\* Constrained wrappers for bounded actions

\* KEY_EXCHANGE is the primary driver of nondeterminism; bound total sends
MCReqSendKeyExchange(hitc, slot, mode) ==
    /\ kexCount < MaxKeyExchanges
    /\ ReqSendKeyExchange(hitc, slot, mode)
    /\ kexCount' = kexCount + 1
    /\ UNCHANGED <<encodeFailCount, injectCount, appDataCount>>

\* [F3] Encoding failure leaves session in KEYS_DERIVED (zombie)
MCRspEncodeFailure(s) ==
    /\ encodeFailCount < MaxEncodeFailures
    /\ RspEncodeFailure(s)
    /\ encodeFailCount' = encodeFailCount + 1
    /\ UNCHANGED <<kexCount, injectCount, appDataCount>>

\* [F4] Attacker injects message with valid header but invalid ciphertext
MCInjectBadMessage(s) ==
    /\ injectCount < MaxInjections
    /\ InjectBadMessage(s)
    /\ injectCount' = injectCount + 1
    /\ UNCHANGED <<kexCount, encodeFailCount, appDataCount>>

\* App-data sends are bounded to keep state space manageable
MCReqSendAppData(s, auth) ==
    /\ appDataCount < MaxAppDataSends
    /\ ReqSendAppData(s, auth)
    /\ appDataCount' = appDataCount + 1
    /\ UNCHANGED <<kexCount, encodeFailCount, injectCount>>

\* ----------------------------------------------------------------
\* Unconstrained (reactive) actions — pass through, counters unchanged

MCRspHandleKeyExchange(m, s) ==
    /\ RspHandleKeyExchange(m, s)
    /\ UNCHANGED faultVars

MCReqSendFinish(rsp, auth) ==
    /\ ReqSendFinish(rsp, auth)
    /\ UNCHANGED faultVars

MCRspDeriveDataKeys(m) ==
    /\ RspDeriveDataKeys(m)
    /\ UNCHANGED faultVars

MCRspCommitEstablished(frsp, s) ==
    /\ RspCommitEstablished(frsp, s)
    /\ UNCHANGED faultVars

MCRspDecodeSecuredMessage(m) ==
    /\ RspDecodeSecuredMessage(m)
    /\ UNCHANGED faultVars

\* ----------------------------------------------------------------
\* MCNext

MCNext ==
    \/ \E hitc \in BOOLEAN, slot \in CertSlots, mode \in {MUT_NONE, MUT_NON_ENCAP, MUT_ENCAP} :
           MCReqSendKeyExchange(hitc, slot, mode)
    \/ \E m \in msgs, s \in Sessions : MCRspHandleKeyExchange(m, s)
    \/ \E rsp \in msgs, auth \in Sessions : MCReqSendFinish(rsp, auth)
    \/ \E m \in msgs : MCRspDeriveDataKeys(m)
    \/ \E frsp \in msgs, s \in Sessions : MCRspCommitEstablished(frsp, s)
    \/ \E s \in Sessions : MCRspEncodeFailure(s)
    \/ \E s \in Sessions, auth \in BOOLEAN : MCReqSendAppData(s, auth)
    \/ \E s \in Sessions : MCInjectBadMessage(s)
    \/ \E m \in msgs : MCRspDecodeSecuredMessage(m)

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

\* ----------------------------------------------------------------
\* Symmetry and view
\* Sessions are symmetric — TLC can permute them
Symmetry == Permutations(Sessions)

\* Exclude counters from the view to avoid spurious state distinctions
MCView == <<vars>>

\* ----------------------------------------------------------------
\* Message buffer size constraint (prunes invalid large-buffer states)
MsgBufferConstraint == Cardinality(msgs) <= 8

\* ----------------------------------------------------------------
\* INVARIANTS

\* Structural invariants (always enabled)
MCTypeOK              == TypeOK
MCSessionStateMonotonic == SessionStateMonotonic
MCFinishRspConsistency  == FinishRspConsistency

\* Extension invariants — operators defined here; COMMENTED OUT in MC.cfg.
\* Enabled individually in MC_hunt_*.cfg files after spec convergence.
MCSessionEstablishedOnlyAfterOwnFinish == SessionEstablishedOnlyAfterOwnFinish
MCMutAuthUsesNegotiatedSlot            == MutAuthUsesNegotiatedSlot
MCNoDataKeysBeforeEstablished          == NoDataKeysBeforeEstablished
MCSeqCounterStableOnDecryptFailure     == SeqCounterStableOnDecryptFailure

====
