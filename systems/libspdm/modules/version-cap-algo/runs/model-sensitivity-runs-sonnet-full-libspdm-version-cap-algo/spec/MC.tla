---- MODULE MC ----
\* Model checking wrapper for libspdm VCA handshake spec.
\*
\* Wraps base.tla with counter-bounded fault injection actions.
\* Bound fault-injecting actions (ContextReset, RspError*); leave
\* deterministic/reactive protocol actions unbounded.
EXTENDS base

----
\* ------------------------------------------------------------------
\*  COUNTER BOUNDS (tune before each run)
\* ------------------------------------------------------------------

CONSTANTS
    MaxResetLimit,      \* ContextReset firings (models crash-between-VCA-phases)
    MaxRspErrorLimit    \* RspError* firings (models error-return paths for F4)

----
\* ------------------------------------------------------------------
\*  COUNTER STATE
\* ------------------------------------------------------------------

VARIABLES faultCounters   \* record: [reset |-> Nat, rspError |-> Nat]

mcVars == <<vars, faultCounters>>

----
\* ------------------------------------------------------------------
\*  BOUNDED WRAPPERS FOR FAULT INJECTION ACTIONS
\* ------------------------------------------------------------------

MCContextReset ==
    /\ faultCounters.reset < MaxResetLimit
    /\ ContextReset
    /\ faultCounters' = [faultCounters EXCEPT !.reset = @ + 1]

MCRspErrorInCapabilities ==
    /\ faultCounters.rspError < MaxRspErrorLimit
    /\ RspErrorInCapabilities
    /\ faultCounters' = [faultCounters EXCEPT !.rspError = @ + 1]

MCRspErrorInAlgorithms ==
    /\ faultCounters.rspError < MaxRspErrorLimit
    /\ RspErrorInAlgorithms
    /\ faultCounters' = [faultCounters EXCEPT !.rspError = @ + 1]

----
\* ------------------------------------------------------------------
\*  PASS-THROUGH WRAPPERS FOR NORMAL ACTIONS
\* These are deterministic/reactive — no counter bounding.
\* ------------------------------------------------------------------

MCReqSendGetVersion ==
    /\ ReqSendGetVersion
    /\ UNCHANGED faultCounters

MCRspHandleGetVersion(v) ==
    /\ RspHandleGetVersion(v)
    /\ UNCHANGED faultCounters

MCReqHandleVersion ==
    /\ ReqHandleVersion
    /\ UNCHANGED faultCounters

MCReqSendGetCapabilities(flags) ==
    /\ ReqSendGetCapabilities(flags)
    /\ UNCHANGED faultCounters

MCRspHandleGetCapabilities(req_f, rsp_f) ==
    /\ RspHandleGetCapabilities(req_f, rsp_f)
    /\ UNCHANGED faultCounters

MCReqHandleCapabilities ==
    /\ ReqHandleCapabilities
    /\ UNCHANGED faultCounters

MCReqSendNegotiateAlgorithms(alg_types) ==
    /\ ReqSendNegotiateAlgorithms(alg_types)
    /\ UNCHANGED faultCounters

MCRspHandleNegotiateAlgorithms(sh, sa, ms, mh, st, dh, ae, ra, ks) ==
    /\ RspHandleNegotiateAlgorithms(sh, sa, ms, mh, st, dh, ae, ra, ks)
    /\ UNCHANGED faultCounters

MCReqHandleAlgorithms ==
    /\ ReqHandleAlgorithms
    /\ UNCHANGED faultCounters

----
\* ------------------------------------------------------------------
\*  MCInit / MCNext
\* ------------------------------------------------------------------

MCInit ==
    /\ Init
    /\ faultCounters = [reset |-> 0, rspError |-> 0]

MCNext ==
    \/ MCReqSendGetVersion
    \/ \E v \in AllVersions : MCRspHandleGetVersion(v)
    \/ MCReqHandleVersion
    \/ \E flags \in SUBSET AllCapFlags : MCReqSendGetCapabilities(flags)
    \/ \E req_f \in SUBSET AllCapFlags :
       \E rsp_f \in SUBSET AllCapFlags :
           MCRspHandleGetCapabilities(req_f, rsp_f)
    \/ MCReqHandleCapabilities
    \/ \E alg_types \in SUBSET AllAlgTypes : MCReqSendNegotiateAlgorithms(alg_types)
    \/ \E sh \in {ALGO_NONE, ALGO_SOME} :
       \E sa \in {ALGO_NONE, ALGO_SOME} :
       \E ms \in {ALGO_NONE, ALGO_SOME} :
       \E mh \in {ALGO_NONE, ALGO_SOME} :
       \E st \in SUBSET AllAlgTypes :
       \E dh \in {ALGO_NONE, ALGO_SOME} :
       \E ae \in {ALGO_NONE, ALGO_SOME} :
       \E ra \in {ALGO_NONE, ALGO_SOME} :
       \E ks \in {ALGO_NONE, ALGO_SOME} :
           MCRspHandleNegotiateAlgorithms(sh, sa, ms, mh, st, dh, ae, ra, ks)
    \/ MCReqHandleAlgorithms
    \/ MCContextReset
    \/ MCRspErrorInCapabilities
    \/ MCRspErrorInAlgorithms

MCSpec == MCInit /\ [][MCNext]_mcVars

----
\* ------------------------------------------------------------------
\*  VIEW (exclude counters from state identity for symmetry)
\* ------------------------------------------------------------------

MCView == vars

----
\* ------------------------------------------------------------------
\*  MESSAGE BUFFER CONSTRAINT
\* Limit in-flight message to 1 (SPDM is strictly sequential).
\* ------------------------------------------------------------------

MCMsgConstraint ==
    in_flight_msg = "none" \/ in_flight_msg /= "none"
    \* (always true; SPDM protocol is single-slot by design — no buffering needed)

====
