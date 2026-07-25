---- MODULE MC ----
\* =============================================================================
\* SPDM Encapsulated Mutual Authentication - Model Checking Wrapper
\*
\* Wraps the base spec with counter-bounded adversarial actions to enable
\* exhaustive state space exploration.
\*
\* Bounded actions (adversary-controlled, non-deterministic):
\*   EncapResponseNotReady  - Requester sends NOT_READY error (terminates cleanly)
\*   EncapError             - Requester sends other bad response (partial reset bug)
\*
\* Unbounded actions (reactive/deterministic, given current state):
\*   VerifyResponder, GetEncapsulatedRequest, DeliverEncapResponseDigests,
\*   DeliverEncapResponseCertificate, DeliverEncapResponseChallengeAuth
\* =============================================================================
EXTENDS base

\* -----------------------------------------------------------------------------
\* Fault injection counters
\* -----------------------------------------------------------------------------
VARIABLES
    faultCounters  \* Record: [notReady |-> Nat, encapErr |-> Nat]

MCvars == <<vars, faultCounters>>

\* -----------------------------------------------------------------------------
\* Counter bounds (tune in hunting configs)
\* -----------------------------------------------------------------------------
CONSTANTS
    MaxNotReadyLimit,   \* bound on EncapResponseNotReady firings
    MaxEncapErrLimit    \* bound on EncapError firings

\* -----------------------------------------------------------------------------
\* MC Init
\* -----------------------------------------------------------------------------
MCInit ==
    /\ Init
    /\ faultCounters = [notReady |-> 0, encapErr |-> 0]

\* -----------------------------------------------------------------------------
\* Bounded adversarial wrappers
\* -----------------------------------------------------------------------------

\* MCEncapResponseNotReady: bounded EncapResponseNotReady
\* Requester delivers ERROR(ResponseNotReady); Responder terminates cleanly.
\* Bounded to prevent infinite NOT_READY re-triggering.
MCEncapResponseNotReady ==
    /\ faultCounters.notReady < MaxNotReadyLimit
    /\ EncapResponseNotReady
    /\ faultCounters' = [faultCounters EXCEPT !.notReady = @ + 1]

\* MCEncapError: bounded EncapError
\* Requester delivers a bad response causing non-NOT_READY error.
\* This is the fault injection that exposes Family 2 and Family 4 bugs.
MCEncapError ==
    /\ faultCounters.encapErr < MaxEncapErrLimit
    /\ EncapError
    /\ faultCounters' = [faultCounters EXCEPT !.encapErr = @ + 1]

\* -----------------------------------------------------------------------------
\* Unbounded reactive actions (pass through, UNCHANGED faultCounters)
\* -----------------------------------------------------------------------------

MCVerifyResponder ==
    /\ VerifyResponder
    /\ UNCHANGED faultCounters

MCGetEncapsulatedRequest ==
    /\ GetEncapsulatedRequest
    /\ UNCHANGED faultCounters

MCDeliverEncapResponseDigests ==
    /\ DeliverEncapResponseDigests
    /\ UNCHANGED faultCounters

MCDeliverEncapResponseCertificate ==
    /\ DeliverEncapResponseCertificate
    /\ UNCHANGED faultCounters

MCDeliverEncapResponseChallengeAuth ==
    /\ DeliverEncapResponseChallengeAuth
    /\ UNCHANGED faultCounters

\* -----------------------------------------------------------------------------
\* MCNext
\* -----------------------------------------------------------------------------
MCNext ==
    \/ MCVerifyResponder
    \/ MCGetEncapsulatedRequest
    \/ MCDeliverEncapResponseDigests
    \/ MCDeliverEncapResponseCertificate
    \/ MCDeliverEncapResponseChallengeAuth
    \/ MCEncapResponseNotReady
    \/ MCEncapError

\* -----------------------------------------------------------------------------
\* State constraint: prune states beyond request_id bound
\* -----------------------------------------------------------------------------
MCStateConstraint == request_id <= MAX_REQUEST_ID

\* -----------------------------------------------------------------------------
\* View: exclude fault counters from symmetry/view (no symmetry in single-node spec)
\* -----------------------------------------------------------------------------
MCView == vars

\* -----------------------------------------------------------------------------
\* MCSpec
\* -----------------------------------------------------------------------------
MCSpec == MCInit /\ [][MCNext]_MCvars

====
