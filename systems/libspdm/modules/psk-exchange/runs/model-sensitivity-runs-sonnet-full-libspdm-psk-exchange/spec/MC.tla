-------------------------- MODULE MC --------------------------
(*
  Model-checking wrapper for libspdm PSK exchange base spec.

  Counter-bounds fault-injection actions; deterministic/reactive actions
  pass through with UNCHANGED faultVars.

  Bug families targeted by hunting configs:
    MC_hunt_family1.cfg  — ValidVersionOnEstablish  (zero-version session)
    MC_hunt_family2.cfg  — VersionAgreement         (triple-call version mismatch)
*)

EXTENDS base

-----------------------------------------------------------------------------
\* COUNTER VARIABLES
-----------------------------------------------------------------------------

(*
  One counter per fault-injection action:
    drop_count   — message loss injections
  Normal protocol actions (GetResponsePskExchange, RecvPskExchangeRsp, etc.)
  are reactive and are NOT bounded.
*)
VARIABLE faultVars          \* record: [drop_count: Nat]
VARIABLE sendNoOpaque_count \* counts SendPskExchange(FALSE) invocations

MCVars == <<allVars, faultVars, sendNoOpaque_count>>

-----------------------------------------------------------------------------
\* BOUNDS
-----------------------------------------------------------------------------

CONSTANTS
    MaxDropLimit,   \* max message drops (recommended: 2)
    MaxSendLimit    \* max PSK_EXCHANGE sends with_opaque=FALSE (recommended: 2)

-----------------------------------------------------------------------------
\* COUNTER-BOUNDED WRAPPERS
-----------------------------------------------------------------------------

\* Bounded DropMessage
MCDropMessage ==
    /\ faultVars.drop_count < MaxDropLimit
    /\ DropMessage
    /\ faultVars' = [faultVars EXCEPT !.drop_count = @ + 1]
    /\ UNCHANGED sendNoOpaque_count

\* SendPskExchange with opaque=FALSE is the Family 1 trigger.
\* Bound it so TLC doesn't flood with repeated no-opaque sends.
MCSendPskExchangeNoOpaque ==
    /\ sendNoOpaque_count < MaxSendLimit
    /\ SendPskExchange(FALSE)
    /\ sendNoOpaque_count' = sendNoOpaque_count + 1
    /\ UNCHANGED faultVars

MCSendPskExchangeWithOpaque ==
    /\ SendPskExchange(TRUE)
    /\ UNCHANGED <<faultVars, sendNoOpaque_count>>

\* Reactive actions: no counter needed
MCGetResponsePskExchange ==
    /\ GetResponsePskExchange
    /\ UNCHANGED <<faultVars, sendNoOpaque_count>>

MCRecvPskExchangeRsp ==
    /\ RecvPskExchangeRsp
    /\ UNCHANGED <<faultVars, sendNoOpaque_count>>

MCSendPskFinish ==
    /\ SendPskFinish
    /\ UNCHANGED <<faultVars, sendNoOpaque_count>>

MCGetResponsePskFinish ==
    /\ GetResponsePskFinish
    /\ UNCHANGED <<faultVars, sendNoOpaque_count>>

MCRecvPskFinishRsp ==
    /\ RecvPskFinishRsp
    /\ UNCHANGED <<faultVars, sendNoOpaque_count>>

-----------------------------------------------------------------------------
\* MCInit / MCNext
-----------------------------------------------------------------------------

MCInit ==
    /\ Init
    /\ faultVars       = [drop_count |-> 0]
    /\ sendNoOpaque_count = 0

MCNext ==
    \/ MCSendPskExchangeWithOpaque
    \/ MCSendPskExchangeNoOpaque
    \/ MCGetResponsePskExchange
    \/ MCRecvPskExchangeRsp
    \/ MCSendPskFinish
    \/ MCGetResponsePskFinish
    \/ MCRecvPskFinishRsp
    \/ MCDropMessage

MCSpec == MCInit /\ [][MCNext]_MCVars

-----------------------------------------------------------------------------
\* SYMMETRY / VIEW
-----------------------------------------------------------------------------

\* Exclude fault counters from symmetry view (they are monotone, not symmetric)
MCView == <<msgs, req_state, rsp_state, req_has_opaque, rsp_has_opaque,
            opaque_call_results, rsp_negotiated_version, req_negotiated_version>>

-----------------------------------------------------------------------------
\* STATE SPACE CONSTRAINT
-----------------------------------------------------------------------------

\* Prevent unbounded message accumulation
CONSTANT MaxMsgBuffer  \* recommended: 6

MCMsgConstraint == BagCardinality(msgs) <= MaxMsgBuffer

-----------------------------------------------------------------------------
\* STRUCTURAL INVARIANTS
-----------------------------------------------------------------------------

\* Session ID consistency: both sides agree on session ID once handshake starts
SessionIdConsistency ==
    (req_state.session_state /= SESSION_NOT_STARTED /\
     rsp_state.session_state /= SESSION_NOT_STARTED) =>
        req_state.session_id = rsp_state.session_id

\* Responder cannot be ESTABLISHED before requester sends PSK_EXCHANGE
RspNotAheadOfReq ==
    rsp_state.session_state = SESSION_ESTABLISHED =>
        req_state.session_state /= SESSION_NOT_STARTED

-----------------------------------------------------------------------------
\* INVARIANTS (grouped by category)
\* Extension (bug-family) invariants are commented out for convergence runs.
\* They are enabled in the MC_hunt_*.cfg files.
-----------------------------------------------------------------------------

\* Standard safety:
\*   NoEstablishWithoutHmacVerify
\*   PskFinishRequiredIfContext

\* Structural:
\*   TypeOK
\*   SessionIdConsistency
\*   RspNotAheadOfReq

\* Extension (bug-detection) — COMMENTED OUT here, enabled in hunt cfgs:
\*   ValidVersionOnEstablish    (Family 1)
\*   VersionAgreement           (Family 2)

=================================================================
