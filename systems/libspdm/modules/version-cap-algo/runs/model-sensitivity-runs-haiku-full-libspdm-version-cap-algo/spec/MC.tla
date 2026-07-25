---- MODULE MC ----
\* Model checking specification with counter-bounded fault injection
\* Extends base spec with exhaustive state space exploration

EXTENDS base

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT MaxFaults \* Maximum number of times each fault can be injected

\* ============================================================================
\* FAULT INJECTION COUNTERS
\* ============================================================================

\* Counter variables - limit how many times each fault can occur
VARIABLE faultCounters

\* Initialize counters
MCInit ==
    /\ Init
    /\ faultCounters = [responderAcceptsUnsupported |-> 0,
                        responderReturnsZero |-> 0,
                        midHandshakeVersionReset |-> 0,
                        requesterSkipsValidation |-> 0]

\* All variables including fault counters
mcVars == <<vars, faultCounters>>

\* ============================================================================
\* WRAPPED ACTIONS WITH FAULT INJECTION
\* ============================================================================

\* Family 1: Inject fault where responder accepts unsupported algorithm
\* Mechanism: responder stores proposed algorithm even though it's not in local support
MCResponderHandlesAlgorithms ==
    \/ \* Normal path: responder validates (high priority)
       /\ responderState = RESPONDER_ALGO_RESP
       /\ capabilitiesNegotiated = TRUE
       /\ \E msg \in messages :
           /\ msg.type = MSG_NEGOTIATE_ALGORITHMS
           /\ LET proposed == msg.proposed_algos
                  prioritized == PrioritizeAlgorithm(localAlgorithms_resp, proposed)
              IN
                /\ IF prioritized = 0 THEN
                     /\ prioritizationResult' = 0
                     /\ prioritizationFailed' = TRUE
                     /\ responderResponse' = {}
                   ELSE
                     /\ prioritizationResult' = prioritized
                     /\ prioritizationFailed' = FALSE
                     /\ responderResponse' = {prioritized}
                /\ algorithmsNegotiated' = TRUE
           /\ responderState' = RESPONDER_COMPLETE
           /\ messages' = messages \ {msg}
           /\ UNCHANGED faultCounters
    \/ \* Faulty path: responder accepts unsupported algorithm (Family 1)
       /\ responderState = RESPONDER_ALGO_RESP
       /\ capabilitiesNegotiated = TRUE
       /\ faultCounters.responderAcceptsUnsupported < MaxFaults
       /\ \E msg \in messages :
           /\ msg.type = MSG_NEGOTIATE_ALGORITHMS
           /\ LET proposed == msg.proposed_algos
              IN
                \* Faulty: directly accept proposed without checking intersection
                \* (simulates libspdm_rsp_algorithms.c:565-566 without validation)
                /\ responderResponse' = proposed
                /\ algorithmsNegotiated' = TRUE
                /\ prioritizationResult' = IF proposed = {} THEN 0 ELSE 1
                /\ prioritizationFailed' = (proposed = {})
           /\ responderState' = RESPONDER_COMPLETE
           /\ messages' = messages \ {msg}
           /\ faultCounters' = [faultCounters EXCEPT
                !.responderAcceptsUnsupported = @ + 1]

\* Family 1, 2: Responder sends ALGORITHMS response
MCResponderSendsAlgorithms ==
    /\ responderState = RESPONDER_COMPLETE
    /\ messages' = messages \cup {[type |-> MSG_ALGORITHMS,
                                  agreed_algos |-> responderResponse]}
    /\ UNCHANGED <<requesterState, responderState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, prioritizationResult,
                    prioritizationFailed, versionNegotiated,
                    capabilitiesNegotiated, algorithmsNegotiated,
                    enabledCapabilities, faultCounters>>

\* Family 4: Inject fault where GET_VERSION arrives mid-handshake and resets context
MCResponderHandlesVersion ==
    \/ \* Normal path: GET_VERSION arrives when expected
       /\ responderState = RESPONDER_INIT
       /\ \E msg \in messages :
           /\ msg.type = MSG_GET_VERSION
           /\ versionNegotiated' = FALSE
           /\ capabilitiesNegotiated' = FALSE
           /\ algorithmsNegotiated' = FALSE
           /\ responderState' = RESPONDER_VERSION_RESP
           /\ messages' = messages \ {msg}
           /\ UNCHANGED faultCounters
    \/ \* Faulty path: GET_VERSION arrives mid-handshake and resets state
       /\ responderState \in {RESPONDER_CAPS_RESP, RESPONDER_ALGO_RESP}
       /\ faultCounters.midHandshakeVersionReset < MaxFaults
       /\ \E msg \in messages :
           /\ msg.type = MSG_GET_VERSION
           \* Simulate libspdm_reset_context() at line 81 of libspdm_rsp_version.c
           /\ versionNegotiated' = FALSE
           /\ capabilitiesNegotiated' = FALSE
           /\ algorithmsNegotiated' = FALSE
           /\ responderState' = RESPONDER_VERSION_RESP
           /\ messages' = messages \ {msg}
           /\ faultCounters' = [faultCounters EXCEPT
                !.midHandshakeVersionReset = @ + 1]

\* Family 5: Inject fault where requester skips validation
MCRequesterValidatesAlgorithms ==
    \/ \* Normal path: requester validates if capabilities enabled
       /\ requesterState = REQUESTER_ALGO_SENT
       /\ \E msg \in messages :
           /\ msg.type = MSG_ALGORITHMS
           /\ responderResponse' = msg.agreed_algos
           /\ IF ShouldValidateAlgorithms(enabledCapabilities) THEN
                IF IntersectionEmpty(localAlgorithms_req, responderResponse') THEN
                  /\ requesterState' = REQUESTER_COMPLETE
                  /\ algorithmsNegotiated' = FALSE
                ELSE
                  /\ requesterState' = REQUESTER_COMPLETE
                  /\ algorithmsNegotiated' = TRUE
                  /\ agreedAlgorithms' = [agreedAlgorithms EXCEPT !.base_asym_algo = responderResponse']
              ELSE
                /\ requesterState' = REQUESTER_COMPLETE
                /\ algorithmsNegotiated' = TRUE
                /\ agreedAlgorithms' = [agreedAlgorithms EXCEPT !.base_asym_algo = responderResponse']
           /\ messages' = messages \ {msg}
           /\ UNCHANGED faultCounters
    \/ \* Faulty path: requester skips validation even when capabilities require it (Family 5)
       /\ requesterState = REQUESTER_ALGO_SENT
       /\ faultCounters.requesterSkipsValidation < MaxFaults
       /\ ShouldValidateAlgorithms(enabledCapabilities)
       /\ \E msg \in messages :
           /\ msg.type = MSG_ALGORITHMS
           /\ responderResponse' = msg.agreed_algos
           \* Faulty: silently accept without validation
           /\ requesterState' = REQUESTER_COMPLETE
           /\ algorithmsNegotiated' = TRUE
           /\ agreedAlgorithms' = [agreedAlgorithms EXCEPT !.base_asym_algo = responderResponse']
           /\ messages' = messages \ {msg}
           /\ faultCounters' = [faultCounters EXCEPT
                !.requesterSkipsValidation = @ + 1]

\* Reactive actions (no fault injection, no counter bounds)

MCRequesterInitVersion ==
    /\ requesterState = REQUESTER_INIT
    /\ messages' = messages \cup {[type |-> MSG_GET_VERSION]}
    /\ requesterState' = REQUESTER_VERSION_SENT
    /\ UNCHANGED <<responderState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    versionNegotiated, capabilitiesNegotiated,
                    algorithmsNegotiated, enabledCapabilities, faultCounters>>

MCRequesterReceivesVersion ==
    /\ requesterState = REQUESTER_VERSION_SENT
    /\ \E msg \in messages :
        /\ msg.type = MSG_VERSION
        /\ version' = msg.version
        /\ versionNegotiated' = TRUE
        /\ requesterState' = REQUESTER_CAPS_SENT
        /\ messages' = messages \ {msg}
    /\ UNCHANGED <<responderState, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    capabilitiesNegotiated, algorithmsNegotiated,
                    enabledCapabilities, faultCounters>>

MCRequesterInitCapabilities ==
    /\ requesterState = REQUESTER_CAPS_SENT
    /\ versionNegotiated = TRUE
    /\ messages' = messages \cup {[type |-> MSG_GET_CAPABILITIES]}
    /\ UNCHANGED <<requesterState, responderState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    versionNegotiated, capabilitiesNegotiated,
                    algorithmsNegotiated, enabledCapabilities, faultCounters>>

MCRequesterReceivesCapabilities ==
    /\ requesterState = REQUESTER_CAPS_SENT
    /\ \E msg \in messages :
        /\ msg.type = MSG_CAPABILITIES
        /\ capabilitiesNegotiated' = TRUE
        /\ requesterState' = REQUESTER_ALGO_SENT
        /\ messages' = messages \ {msg}
    /\ UNCHANGED <<responderState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    versionNegotiated, algorithmsNegotiated,
                    enabledCapabilities, faultCounters>>

MCRequesterInitAlgorithms ==
    /\ requesterState = REQUESTER_ALGO_SENT
    /\ capabilitiesNegotiated = TRUE
    /\ proposedAlgorithms' = localAlgorithms_req
    /\ messages' = messages \cup {[type |-> MSG_NEGOTIATE_ALGORITHMS,
                                   proposed_algos |-> proposedAlgorithms']}
    /\ UNCHANGED <<requesterState, responderState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    responderResponse, prioritizationResult,
                    prioritizationFailed, versionNegotiated,
                    capabilitiesNegotiated, algorithmsNegotiated,
                    enabledCapabilities, faultCounters>>

MCResponderSendsVersion ==
    /\ responderState = RESPONDER_VERSION_RESP
    /\ version' = 16
    /\ versionNegotiated' = TRUE
    /\ messages' = messages \cup {[type |-> MSG_VERSION, version |-> version']}
    /\ responderState' = RESPONDER_CAPS_RESP
    /\ UNCHANGED <<requesterState, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    capabilitiesNegotiated, algorithmsNegotiated,
                    enabledCapabilities, faultCounters>>

MCResponderHandlesCapabilities ==
    /\ responderState = RESPONDER_CAPS_RESP
    /\ versionNegotiated = TRUE
    /\ \E msg \in messages :
        /\ msg.type = MSG_GET_CAPABILITIES
        /\ capabilitiesNegotiated' = TRUE
        /\ responderState' = RESPONDER_ALGO_RESP
        /\ messages' = messages \ {msg}
    /\ UNCHANGED <<requesterState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    versionNegotiated, algorithmsNegotiated,
                    enabledCapabilities, faultCounters>>

MCResponderSendsCapabilities ==
    /\ responderState = RESPONDER_ALGO_RESP
    /\ messages' = messages \cup {[type |-> MSG_CAPABILITIES]}
    /\ UNCHANGED <<requesterState, responderState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    versionNegotiated, capabilitiesNegotiated,
                    algorithmsNegotiated, enabledCapabilities, faultCounters>>

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

MCNext ==
    \/ MCRequesterInitVersion
    \/ MCRequesterReceivesVersion
    \/ MCRequesterInitCapabilities
    \/ MCRequesterReceivesCapabilities
    \/ MCRequesterInitAlgorithms
    \/ MCRequesterValidatesAlgorithms
    \/ MCResponderHandlesVersion
    \/ MCResponderSendsVersion
    \/ MCResponderHandlesCapabilities
    \/ MCResponderSendsCapabilities
    \/ MCResponderHandlesAlgorithms
    \/ MCResponderSendsAlgorithms

MCSpec == MCInit /\ [][MCNext]_mcVars

====
