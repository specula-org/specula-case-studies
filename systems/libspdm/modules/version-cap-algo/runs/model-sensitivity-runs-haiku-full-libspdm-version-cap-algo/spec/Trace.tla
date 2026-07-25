---- MODULE Trace ----
\* Trace validation spec for libspdm-version-cap-algo
\* Category A: Standard linear trace replay against base spec
\* Validates base spec against recorded implementation traces

EXTENDS base, Naturals, FiniteSets, Sequences, Bags, TLC, TLCExt

\* ============================================================================
\* TRACE LOADING
\* ============================================================================

\* ============================================================================
\* TRACE CURSOR AND STATE
\* ============================================================================

\* Trace cursor: walks through events in sequence
VARIABLE l

\* Trace data will be provided by TLC at runtime
CONSTANT TraceData

\* Sentinel value for missing/unset fields in trace events
NULLVAL == "null"

\* Use provided trace data
TraceLog == TraceData

\* ============================================================================
\* EVENT MATCHING HELPERS
\* ============================================================================

\* Extract fields from trace event
IsEvent(name) == l <= Len(TraceLog) /\ TraceLog[l].event = name

\* Check if event is for a specific node
IsNodeEvent(name, nodeID) ==
    /\ IsEvent(name)
    /\ TraceLog[l].node_id = nodeID

\* Check if event is a message between specific endpoints
IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ TraceLog[l].from = from
    /\ TraceLog[l].to = to

\* Extract current trace event
CurrentEvent == IF l <= Len(TraceLog) THEN TraceLog[l] ELSE NULLVAL

\* ============================================================================
\* TRACE INITIALIZATION
\* ============================================================================

\* Bootstrap state from trace: initial conditions may differ from base spec Init
TraceInit ==
    /\ Init
    /\ l = 1

\* ============================================================================
\* POST-STATE VALIDATION (MANDATORY)
\* ============================================================================

\* Validate requester state matches trace
ValidateRequesterState(expected) ==
    requesterState = expected

\* Validate responder state matches trace
ValidateResponderState(expected) ==
    responderState = expected

\* Validate negotiated version matches trace
ValidateVersion(expected) ==
    version = expected

\* Validate algorithms state matches trace
ValidateAlgorithmState(expected_negotiated, expected_agreed) ==
    /\ algorithmsNegotiated = expected_negotiated
    /\ IF expected_negotiated THEN agreedAlgorithms.base_asym_algo = expected_agreed
       ELSE TRUE

\* Validate connection state consistency
ValidateConnectionState ==
    /\ (capabilitiesNegotiated = TRUE => versionNegotiated = TRUE)
    /\ (algorithmsNegotiated = TRUE => capabilitiesNegotiated = TRUE)

\* ============================================================================
\* ACTION WRAPPERS - REQUESTER SIDE
\* ============================================================================

\* Event: requester_init_version
TraceRequesterInitVersion ==
    /\ IsEvent("requester_init_version")
    /\ RequesterInitVersion
    /\ ValidateRequesterState(REQUESTER_VERSION_SENT)
    /\ l' = l + 1

\* Event: requester_receives_version
TraceRequesterReceivesVersion ==
    /\ IsEvent("requester_receives_version")
    /\ CurrentEvent.version # NULLVAL
    /\ RequesterReceivesVersion
    /\ ValidateRequesterState(REQUESTER_CAPS_SENT)
    /\ ValidateVersion(CurrentEvent.version)
    /\ ValidateConnectionState
    /\ l' = l + 1

\* Event: requester_init_capabilities
TraceRequesterInitCapabilities ==
    /\ IsEvent("requester_init_capabilities")
    /\ RequesterInitCapabilities
    /\ ValidateRequesterState(REQUESTER_CAPS_SENT)
    /\ l' = l + 1

\* Event: requester_receives_capabilities
TraceRequesterReceivesCapabilities ==
    /\ IsEvent("requester_receives_capabilities")
    /\ RequesterReceivesCapabilities
    /\ ValidateRequesterState(REQUESTER_ALGO_SENT)
    /\ ValidateConnectionState
    /\ l' = l + 1

\* Event: requester_init_algorithms
TraceRequesterInitAlgorithms ==
    /\ IsEvent("requester_init_algorithms")
    /\ CurrentEvent.proposed_algos # NULLVAL
    /\ RequesterInitAlgorithms
    /\ ValidateRequesterState(REQUESTER_ALGO_SENT)
    /\ proposedAlgorithms = CurrentEvent.proposed_algos
    /\ l' = l + 1

\* Event: requester_validates_algorithms
TraceRequesterValidatesAlgorithms ==
    /\ IsEvent("requester_validates_algorithms")
    /\ CurrentEvent.agreed_algos # NULLVAL
    /\ RequesterValidatesAlgorithms
    /\ ValidateRequesterState(REQUESTER_COMPLETE)
    /\ ValidateAlgorithmState(CurrentEvent.algorithms_negotiated, CurrentEvent.agreed_algos)
    /\ ValidateConnectionState
    /\ l' = l + 1

\* ============================================================================
\* ACTION WRAPPERS - RESPONDER SIDE
\* ============================================================================

\* Event: responder_handles_version
TraceResponderHandlesVersion ==
    /\ IsEvent("responder_handles_version")
    /\ ResponderHandlesVersion
    /\ ValidateResponderState(RESPONDER_VERSION_RESP)
    /\ l' = l + 1

\* Event: responder_sends_version
TraceResponderSendsVersion ==
    /\ IsEvent("responder_sends_version")
    /\ CurrentEvent.version # NULLVAL
    /\ ResponderSendsVersion
    /\ ValidateResponderState(RESPONDER_CAPS_RESP)
    /\ ValidateVersion(CurrentEvent.version)
    /\ ValidateConnectionState
    /\ l' = l + 1

\* Event: responder_handles_capabilities
TraceResponderHandlesCapabilities ==
    /\ IsEvent("responder_handles_capabilities")
    /\ ResponderHandlesCapabilities
    /\ ValidateResponderState(RESPONDER_ALGO_RESP)
    /\ ValidateConnectionState
    /\ l' = l + 1

\* Event: responder_sends_capabilities
TraceResponderSendsCapabilities ==
    /\ IsEvent("responder_sends_capabilities")
    /\ ResponderSendsCapabilities
    /\ ValidateResponderState(RESPONDER_ALGO_RESP)
    /\ l' = l + 1

\* Event: responder_handles_algorithms
TraceResponderHandlesAlgorithms ==
    /\ IsEvent("responder_handles_algorithms")
    /\ CurrentEvent.proposed_algos # NULLVAL
    /\ ResponderHandlesAlgorithms
    /\ ValidateResponderState(RESPONDER_COMPLETE)
    /\ proposedAlgorithms = CurrentEvent.proposed_algos \/ proposedAlgorithms = {}
    /\ IF CurrentEvent.prioritization_failed THEN prioritizationFailed = TRUE ELSE TRUE
    /\ l' = l + 1

\* Event: responder_sends_algorithms
TraceResponderSendsAlgorithms ==
    /\ IsEvent("responder_sends_algorithms")
    /\ CurrentEvent.agreed_algos # NULLVAL
    /\ ResponderSendsAlgorithms
    /\ ValidateResponderState(RESPONDER_COMPLETE)
    /\ responderResponse = CurrentEvent.agreed_algos \/ responderResponse = {}
    /\ l' = l + 1

\* ============================================================================
\* SILENT ACTIONS
\* ============================================================================

\* Silent action: responder progress between handling and sending messages
\* Used when implementation transitions are not traced
SilentResponderProgress ==
    /\ l <= Len(TraceLog)
    \* Responder can transition from VERSION_RESP to CAPS_RESP (if no message sent event)
    \/ /\ responderState = RESPONDER_VERSION_RESP
       /\ \/ IsEvent("responder_sends_version")
          \/ (l > Len(TraceLog))  \* End of trace
       /\ UNCHANGED <<requesterState, responderState, version, agreedAlgorithms,
                       localAlgorithms_req, localAlgorithms_resp,
                       proposedAlgorithms, responderResponse,
                       prioritizationResult, prioritizationFailed,
                       versionNegotiated, capabilitiesNegotiated,
                       algorithmsNegotiated, enabledCapabilities, messages>>

\* ============================================================================
\* TRACE SPECIFICATION
\* ============================================================================

TraceNext ==
    \/ TraceRequesterInitVersion
    \/ TraceRequesterReceivesVersion
    \/ TraceRequesterInitCapabilities
    \/ TraceRequesterReceivesCapabilities
    \/ TraceRequesterInitAlgorithms
    \/ TraceRequesterValidatesAlgorithms
    \/ TraceResponderHandlesVersion
    \/ TraceResponderSendsVersion
    \/ TraceResponderHandlesCapabilities
    \/ TraceResponderSendsCapabilities
    \/ TraceResponderHandlesAlgorithms
    \/ TraceResponderSendsAlgorithms
    \/ SilentResponderProgress

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>>

\* ============================================================================
\* TRACE COMPLETION AND CORRECTNESS
\* ============================================================================

\* Temporal property: entire trace must be consumed
TraceMatched == <>(l > Len(TraceLog))

\* Structural: trace index within bounds
TraceCursorValid == l >= 1 /\ l <= Len(TraceLog) + 1

====
