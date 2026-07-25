---- MODULE MC ----
(* Model checking wrapper for base.tla with counter-bounded fault injection.
   Enables exhaustive state space exploration with controlled non-determinism.
*)

EXTENDS base, Naturals

(* ============ Fault Injection Constants ============ *)
CONSTANT MAX_TIMEOUT_LIMIT
CONSTANT MAX_MESSAGE_LOSS_LIMIT
CONSTANT MAX_VERSION_MISMATCH_LIMIT
CONSTANT MAX_MSG_BUFFER_SIZE

(* ============ Fault Injection Counters ============ *)

VARIABLE fcounters  \* Fault injection counters

(* Counter state: record with one counter per fault action *)
faultVars == <<fcounters>>

InitCounters ==
    fcounters = [
        timeout |-> 0,
        message_loss |-> 0,
        crash_recovery |-> 0,
        version_mismatch |-> 0
    ]

(* ============ Fault-Injection Actions (Bounded) ============ *)

\* Timeout: requester gives up waiting for CHALLENGE_AUTH response
MCTimeout ==
    /\ fcounters.timeout < MAX_TIMEOUT_LIMIT
    /\ \/ connection_state = CHALLENGED
    /\ fcounters' = [fcounters EXCEPT !.timeout = @ + 1]
    /\ messages' = messages  \* Clear any pending messages (timeout effect)
    /\ UNCHANGED vars

\* Message Loss: drop a CHALLENGE or CHALLENGE_AUTH in flight
MCMessageLoss ==
    /\ fcounters.message_loss < MAX_MESSAGE_LOSS_LIMIT
    /\ \E msg \in messages:
       /\ messages' = messages \ {msg}
       /\ fcounters' = [fcounters EXCEPT !.message_loss = @ + 1]
    /\ UNCHANGED (vars \ {messages, fcounters})

\* Version Mismatch: requester and responder negotiate different versions
MCVersionMismatch ==
    /\ fcounters.version_mismatch < MAX_VERSION_MISMATCH_LIMIT
    /\ spdm_version' \in {SPDM_VERSION_10, SPDM_VERSION_11, SPDM_VERSION_12, SPDM_VERSION_13}
    /\ spdm_version' # spdm_version
    /\ fcounters' = [fcounters EXCEPT !.version_mismatch = @ + 1]
    /\ UNCHANGED (vars \ {spdm_version, fcounters})

(* ============ Normal Actions (Unconstrained) ============ *)

\* These are reactive actions that don't introduce non-determinism; pass through
UCRequesterSendChallenge(slot, ver) ==
    /\ RequesterSendChallenge(slot, ver)
    /\ UNCHANGED faultVars

UCResponderHandleChallenge ==
    /\ ResponderHandleChallenge
    /\ UNCHANGED faultVars

UCRequesterHandleChallengeAuth ==
    /\ RequesterHandleChallengeAuth
    /\ UNCHANGED faultVars

UCResponderHandleEncapChallenge ==
    /\ ResponderHandleEncapChallenge
    /\ UNCHANGED faultVars

UCRequesterHandleEncapChallengeAuth ==
    /\ RequesterHandleEncapChallengeAuth
    /\ UNCHANGED faultVars

(* ============ MC Init and Next ============ *)

MCInit ==
    /\ Init
    /\ InitCounters

MCNext ==
    \/ \E slot \in 0..7, ver \in {SPDM_VERSION_10, SPDM_VERSION_11}:
       UCRequesterSendChallenge(slot, ver)
    \/ UCRequesterSendChallenge(255, SPDM_VERSION_10)
    \/ UCResponderHandleChallenge
    \/ UCRequesterHandleChallengeAuth
    \/ UCResponderHandleEncapChallenge
    \/ UCRequesterHandleEncapChallengeAuth
    \/ MCTimeout
    \/ MCMessageLoss
    \/ MCVersionMismatch

(* ============ View for Symmetry Reduction ============ *)

MCView ==
    <<connection_state, spdm_version, authentication_phase, active_transcript,
      slot_id, nonces_seen, key_source, messages>>

(* Note: fcounters excluded from view *)

(* ============ State Space Pruning ============ *)

(* Keep message buffer bounded to prevent infinite growth *)
MessageBufferBounded ==
    Cardinality(messages) <= MAX_MSG_BUFFER_SIZE

(* ============ Temporal Properties ============ *)

\* Eventually both sides complete authentication
EventuallyAuthenticated ==
    <>  (authentication_phase = "FULLY_AUTHENTICATED")

\* Once authenticated, state remains consistent
OnceAuthenticatedAlwaysConsistent ==
    (authentication_phase = "FULLY_AUTHENTICATED") ~>
    (StateConsistency)

====
