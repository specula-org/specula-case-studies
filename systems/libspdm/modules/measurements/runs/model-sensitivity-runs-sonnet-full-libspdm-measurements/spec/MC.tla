---- MODULE MC ----
(*
 * Model checking wrapper for libspdm GET_MEASUREMENTS spec.
 * Wraps base.tla with counter-bounded fault injection actions.
 *
 * Counter-bounded actions (introduce non-determinism):
 *   MCL1L2ComputationFailure  — bounded fault injection
 *   MCPartialRetryAccumulate  — bounded retry scenario
 *   MCNeedResync              — bounded resync injection
 *
 * Reactive/deterministic actions pass through unchanged from base.
 *)

EXTENDS base

VARIABLES
    faultVars   \* record: [l1l2Fail: Nat, retryFail: Nat, resync: Nat]

(* ================================================================
   CONSTANTS (MC-layer bounds — override in .cfg)
   ================================================================ *)
CONSTANTS
    MaxL1L2FailLimit,       \* max times L1L2ComputationFailure may fire
    MaxRetryLimit,          \* max times PartialRetryAccumulate may fire
    MaxResyncLimit,         \* max times NeedResync may fire
    MaxExchangesLimit       \* max total GET_MEASUREMENTS exchanges

(* ================================================================
   MC INIT
   ================================================================ *)
MCInit ==
    /\ Init
    /\ faultVars = [l1l2Fail |-> 0, retryFail |-> 0, resync |-> 0]

(* ================================================================
   BOUNDED FAULT WRAPPERS
   ================================================================ *)

\* Bounded: L1/L2 computation failure (Family 1)
MCL1L2ComputationFailure ==
    /\ faultVars.l1l2Fail < MaxL1L2FailLimit
    /\ L1L2ComputationFailure
    /\ faultVars' = [faultVars EXCEPT !.l1l2Fail = @ + 1]

\* Bounded: partial retry accumulation (Family 3, Issue #491/#524)
MCPartialRetryAccumulate ==
    /\ faultVars.retryFail < MaxRetryLimit
    /\ PartialRetryAccumulate
    /\ faultVars' = [faultVars EXCEPT !.retryFail = @ + 1]

\* Bounded: NEED_RESYNC injection (Family 3)
MCNeedResync ==
    /\ faultVars.resync < MaxResyncLimit
    /\ NeedResync
    /\ faultVars' = [faultVars EXCEPT !.resync = @ + 1]

(* ================================================================
   PASS-THROUGH WRAPPERS (reactive / deterministic — not bounded)
   ================================================================ *)

MCNegotiateVersion(v) ==
    /\ NegotiateVersion(v)
    /\ UNCHANGED faultVars

MCEstablishSession(sid) ==
    /\ EstablishSession(sid)
    /\ UNCHANGED faultVars

MCRequesterSendGetMeasurements(sid, slot, gen_sig, meas_idx) ==
    /\ RequesterSendGetMeasurements(sid, slot, gen_sig, meas_idx)
    /\ UNCHANGED faultVars

MCResponderAppendRequest ==
    /\ ResponderAppendRequest
    /\ UNCHANGED faultVars

MCResponderBuildResponse(ml, ol, hs) ==
    /\ ResponderBuildResponse(ml, ol, hs)
    /\ UNCHANGED faultVars

MCResponderGenerateSignature ==
    /\ ResponderGenerateSignature
    /\ UNCHANGED faultVars

MCRequesterParseResponseSig(resp_size) ==
    /\ RequesterParseResponseSig(resp_size)
    /\ UNCHANGED faultVars

MCRequesterParseResponseNoSig(resp_size) ==
    /\ RequesterParseResponseNoSig(resp_size)
    /\ UNCHANGED faultVars

MCRequesterVerifySignature ==
    /\ RequesterVerifySignature
    /\ UNCHANGED faultVars

MCCompleteExchange ==
    /\ CompleteExchange
    /\ UNCHANGED faultVars

MCResetContext ==
    /\ ResetContext
    /\ UNCHANGED faultVars

(* ================================================================
   MCNext
   ================================================================ *)
MCNext ==
    \/ \E v \in Versions : MCNegotiateVersion(v)
    \/ \E sid \in SessionIDs : MCEstablishSession(sid)
    \/ \E sid \in ({NULL} \cup SessionIDs),
          slot \in ValidSlots,
          gen_sig \in {TRUE, FALSE},
          meas_idx \in {0, 255} :
            MCRequesterSendGetMeasurements(sid, slot, gen_sig, meas_idx)
    \/ MCResponderAppendRequest
    \/ \E ml \in {0, 32, 64}, ol \in {0, 16}, hs \in {TRUE, FALSE} :
            MCResponderBuildResponse(ml, ol, hs)
    \/ MCResponderGenerateSignature
    \/ MCL1L2ComputationFailure
    \/ \E rs \in 0..512 : MCRequesterParseResponseSig(rs)
    \/ \E rs \in 0..512 : MCRequesterParseResponseNoSig(rs)
    \/ MCRequesterVerifySignature
    \/ MCCompleteExchange
    \/ MCNeedResync
    \/ MCPartialRetryAccumulate
    \/ MCResetContext

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

(* ================================================================
   VIEW — exclude fault counters from state comparison
   ================================================================ *)
MCView == vars

(* ================================================================
   MESSAGE BUFFER CONSTRAINT
   ================================================================ *)
MessageBufferConstraint ==
    /\ Len(message_m_global) <= MaxExchangesLimit
    /\ \A sid \in SessionIDs : Len(message_m_session[sid]) <= MaxExchangesLimit

StateConstraint == MessageBufferConstraint

(* ================================================================
   SYMMETRY
   ================================================================ *)
\* No symmetry reduction needed — protocol is asymmetric (Requester vs Responder)
\* Session IDs are symmetric: Permutations(SessionIDs) can be used if MaxSessions > 1

(* ================================================================
   INVARIANTS
   ================================================================ *)

\* ---- Standard safety + structural (always enabled in MC.cfg) ----
MCTypeOK              == TypeOK
MCParseOffsetInRange  == ParseOffsetInRange
MCActiveSessionsBounded == ActiveSessionsBounded

\* ---- Extension invariants (bug-family specific) ----
\* Defined here; enabled selectively in MC_hunt_*.cfg
MCL1L2Agreement           == L1L2Agreement
MCTranscriptNoSigBytes    == TranscriptNoSignatureBytes
MCParseWithinBounds       == ParseWithinBounds
MCSlotBinding             == SlotBinding
MCSessionConsistency      == SessionConsistency

====
