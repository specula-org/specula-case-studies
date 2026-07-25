---- MODULE base ----
\* SPDM VERSION / CAPABILITIES / NEGOTIATE_ALGORITHMS handshake
\* Category A (Distributed/Message-Passing) specification
\* Bug families: asymmetric algorithm validation, prioritization failures,
\* version negotiation state consistency, capability-conditional validation

EXTENDS Naturals, Sequences, FiniteSets, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT MaxAlgorithms \* Maximum number of algorithms in a support set

\* Algorithm identifiers (opaque values)
CONSTANT SHA256, SHA384, SHA512, ECDSA, FFDH, AES_128_GCM, AES_256_GCM

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* Standard protocol variables
VARIABLE messages          \* Message queue: sequence of in-flight messages
VARIABLE requesterState    \* Requester FSM state
VARIABLE responderState    \* Responder FSM state

\* Connection state (negotiated values)
VARIABLE version           \* Agreed SPDM version
VARIABLE agreedAlgorithms  \* Algorithms both sides claim agreement on (record)

\* Extension variables for bug family tracking

\* Family 1: Asymmetric Algorithm Validation Gap
\* Requester and responder track their local supports independently
VARIABLE localAlgorithms_req   \* Requester's supported algorithms (set)
VARIABLE localAlgorithms_resp  \* Responder's supported algorithms (set)

\* Requester tracks what it proposed and what it received
VARIABLE proposedAlgorithms    \* Requester's proposal sent to responder (set)
VARIABLE responderResponse     \* Responder's response received (set)

\* Family 2: Prioritization Function Silent Failure
\* Track if prioritize_algorithm was called and what result was obtained
VARIABLE prioritizationResult  \* Result of prioritize_algorithm call (0 = failure, nonzero = success)
VARIABLE prioritizationFailed  \* Flag: did prioritize return 0?

\* Family 4: Version Compatibility Check Without Prior Negotiation
\* Track negotiation progress at each stage
VARIABLE versionNegotiated      \* Was version exchange completed?
VARIABLE capabilitiesNegotiated \* Were capabilities negotiated?
VARIABLE algorithmsNegotiated   \* Were algorithms negotiated?

\* Family 5: Conditional Validation on Requester Side
\* Track which capabilities are enabled (subset of {MEAS, CERT, CHAL, KEY_EX, etc.})
VARIABLE enabledCapabilities    \* Set of capability flags enabled on requester

\* All variables tuple for UNCHANGED
vars == <<messages, requesterState, responderState, version,
          agreedAlgorithms, localAlgorithms_req, localAlgorithms_resp,
          proposedAlgorithms, responderResponse, prioritizationResult,
          prioritizationFailed, versionNegotiated, capabilitiesNegotiated,
          algorithmsNegotiated, enabledCapabilities>>

\* ============================================================================
\* STATE DEFINITIONS
\* ============================================================================

\* Requester states
REQUESTER_INIT         == "requester_init"
REQUESTER_VERSION_SENT == "requester_version_sent"
REQUESTER_CAPS_SENT    == "requester_caps_sent"
REQUESTER_ALGO_SENT    == "requester_algo_sent"
REQUESTER_COMPLETE     == "requester_complete"

\* Responder states
RESPONDER_INIT         == "responder_init"
RESPONDER_VERSION_RESP == "responder_version_resp"
RESPONDER_CAPS_RESP    == "responder_caps_resp"
RESPONDER_ALGO_RESP    == "responder_algo_resp"
RESPONDER_COMPLETE     == "responder_complete"

\* Message types
MSG_GET_VERSION           == "GET_VERSION"
MSG_VERSION               == "VERSION"
MSG_GET_CAPABILITIES      == "GET_CAPABILITIES"
MSG_CAPABILITIES          == "CAPABILITIES"
MSG_NEGOTIATE_ALGORITHMS  == "NEGOTIATE_ALGORITHMS"
MSG_ALGORITHMS            == "ALGORITHMS"

\* Capability flags (Family 5)
CAP_MEAS_CAP       == "MEAS_CAP"
CAP_CERT_CAP       == "CERT_CAP"
CAP_CHAL_CAP       == "CHAL_CAP"
CAP_MEAS_CAP_SIG   == "MEAS_CAP_SIG"
CAP_KEY_EX_CAP     == "KEY_EX_CAP"

\* ============================================================================
\* HELPERS
\* ============================================================================

\* Message set operations - simplified

\* Intersection of two algorithm sets (Family 1)
\* Used to model the bitwise AND check in requester validation
Intersect(a, b) == a \cap b

\* Check if intersection is empty
IntersectionEmpty(a, b) == Intersect(a, b) = {}

\* Prioritize algorithm: returns highest-priority common algorithm or 0
\* Simplified model: returns any element from intersection, or 0 if empty
\* (Family 2: prioritize_algorithm function)
PrioritizeAlgorithm(local, peer) ==
    IF Intersect(local, peer) = {} THEN 0
    ELSE CHOOSE x \in Intersect(local, peer) : TRUE

\* Check if requester should validate algorithms based on enabled capabilities
\* (Family 5: conditional validation at libspdm_req_negotiate_algorithms.c:474-541)
ShouldValidateAlgorithms(caps) ==
    \* Validation required if ANY of these capabilities are enabled
    \* (lines 474-541: MEAS_CAP, CERT_CAP, CHAL_CAP, MEAS_CAP_SIG, KEY_EX_CAP)
    \/ CAP_MEAS_CAP \in caps
    \/ CAP_CERT_CAP \in caps
    \/ CAP_CHAL_CAP \in caps
    \/ CAP_MEAS_CAP_SIG \in caps
    \/ CAP_KEY_EX_CAP \in caps

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

Init ==
    /\ messages = {}
    /\ requesterState = REQUESTER_INIT
    /\ responderState = RESPONDER_INIT
    /\ version = 0
    /\ agreedAlgorithms = [base_asym_algo |-> 0, base_hash_algo |-> 0,
                            dhe_algo |-> 0, aead_algo |-> 0]
    /\ localAlgorithms_req = {SHA256, SHA384}     \* Requester supports these
    /\ localAlgorithms_resp = {SHA256, SHA512}    \* Responder supports these (intentional mismatch)
    /\ proposedAlgorithms = {}
    /\ responderResponse = {}
    /\ prioritizationResult = 0
    /\ prioritizationFailed = FALSE
    /\ versionNegotiated = FALSE
    /\ capabilitiesNegotiated = FALSE
    /\ algorithmsNegotiated = FALSE
    /\ enabledCapabilities = {CAP_MEAS_CAP, CAP_KEY_EX_CAP}  \* Enable some capabilities

\* ============================================================================
\* ACTIONS - REQUESTER SIDE
\* ============================================================================

\* Requester initiates GET_VERSION
\* Corresponds to libspdm_req_get_version.c:40-230
RequesterInitVersion ==
    /\ requesterState = REQUESTER_INIT
    /\ messages' = messages \cup {[type |-> MSG_GET_VERSION]}
    /\ requesterState' = REQUESTER_VERSION_SENT
    /\ UNCHANGED <<responderState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    versionNegotiated, capabilitiesNegotiated,
                    algorithmsNegotiated, enabledCapabilities>>

\* Requester receives VERSION response
\* Corresponds to libspdm_req_get_version.c (response handling)
RequesterReceivesVersion ==
    /\ requesterState = REQUESTER_VERSION_SENT
    /\ \E msg \in messages :
        /\ msg.type = MSG_VERSION
        /\ version' = msg.version
        /\ versionNegotiated' = TRUE  \* Family 4: mark version as negotiated
        /\ requesterState' = REQUESTER_CAPS_SENT
        /\ messages' = messages \ {msg}
    /\ UNCHANGED <<responderState, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    capabilitiesNegotiated, algorithmsNegotiated,
                    enabledCapabilities>>

\* Requester sends GET_CAPABILITIES
\* Corresponds to libspdm_req_get_capabilities.c
RequesterInitCapabilities ==
    /\ requesterState = REQUESTER_CAPS_SENT
    /\ versionNegotiated = TRUE  \* Family 4: version must be negotiated first
    /\ messages' = messages \cup {[type |-> MSG_GET_CAPABILITIES]}
    /\ UNCHANGED <<requesterState, responderState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    versionNegotiated, capabilitiesNegotiated,
                    algorithmsNegotiated, enabledCapabilities>>

\* Requester receives CAPABILITIES response
\* Corresponds to libspdm_req_get_capabilities.c (response handling)
RequesterReceivesCapabilities ==
    /\ requesterState = REQUESTER_CAPS_SENT
    /\ \E msg \in messages :
        /\ msg.type = MSG_CAPABILITIES
        /\ capabilitiesNegotiated' = TRUE  \* Family 4: mark capabilities as negotiated
        /\ requesterState' = REQUESTER_ALGO_SENT
        /\ messages' = messages \ {msg}
    /\ UNCHANGED <<responderState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    versionNegotiated, algorithmsNegotiated,
                    enabledCapabilities>>

\* Requester sends NEGOTIATE_ALGORITHMS with proposals
\* Corresponds to libspdm_req_negotiate_algorithms.c:73-200 (request construction)
RequesterInitAlgorithms ==
    /\ requesterState = REQUESTER_ALGO_SENT
    /\ capabilitiesNegotiated = TRUE  \* Family 4: capabilities must be negotiated first
    /\ proposedAlgorithms' = localAlgorithms_req  \* Requester proposes its supported algorithms
    /\ messages' = messages \cup {[type |-> MSG_NEGOTIATE_ALGORITHMS,
                                   proposed_algos |-> proposedAlgorithms']}
    /\ UNCHANGED <<requesterState, responderState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    responderResponse, prioritizationResult,
                    prioritizationFailed, versionNegotiated,
                    capabilitiesNegotiated, algorithmsNegotiated,
                    enabledCapabilities>>

\* Requester receives and validates ALGORITHMS response
\* Corresponds to libspdm_req_negotiate_algorithms.c:474-541
\* Family 1: Conditional validation gap - only validates if capabilities enabled
\* Family 2: Checks for prioritization failure indirectly
RequesterValidatesAlgorithms ==
    /\ requesterState = REQUESTER_ALGO_SENT
    /\ \E msg \in messages :
        /\ msg.type = MSG_ALGORITHMS
        /\ responderResponse' = msg.agreed_algos  \* What responder agreed on
        /\ \* Family 5: Validation is conditional on enabled capabilities
           IF ShouldValidateAlgorithms(enabledCapabilities) THEN
             \* Family 1: Requester validates intersection (lines 529-533)
             IF IntersectionEmpty(localAlgorithms_req, responderResponse') THEN
               /\ requesterState' = REQUESTER_COMPLETE
               /\ algorithmsNegotiated' = FALSE  \* Validation failed
             ELSE
               /\ requesterState' = REQUESTER_COMPLETE
               /\ algorithmsNegotiated' = TRUE
               /\ agreedAlgorithms' = [agreedAlgorithms EXCEPT !.base_asym_algo = responderResponse']
           ELSE
             \* Family 5: No validation - silently accept
             /\ requesterState' = REQUESTER_COMPLETE
             /\ algorithmsNegotiated' = TRUE
             /\ agreedAlgorithms' = [agreedAlgorithms EXCEPT !.base_asym_algo = responderResponse']
        /\ messages' = messages \ {msg}
    /\ UNCHANGED <<responderState, version,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, prioritizationResult,
                    prioritizationFailed, versionNegotiated,
                    capabilitiesNegotiated, enabledCapabilities>>

\* ============================================================================
\* ACTIONS - RESPONDER SIDE
\* ============================================================================

\* Responder handles GET_VERSION
\* Corresponds to libspdm_rsp_version.c:54-127
ResponderHandlesVersion ==
    /\ responderState = RESPONDER_INIT
    /\ \E msg \in messages :
        /\ msg.type = MSG_GET_VERSION
        /\ \* Family 4: GET_VERSION can reset context mid-handshake (line 81, libspdm_reset_context)
           versionNegotiated' = FALSE  \* Reset negotiation flags
           /\ capabilitiesNegotiated' = FALSE
           /\ algorithmsNegotiated' = FALSE
        /\ responderState' = RESPONDER_VERSION_RESP
        /\ messages' = messages \ {msg}
    /\ UNCHANGED <<requesterState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    enabledCapabilities>>

\* Responder sends VERSION response
\* Corresponds to libspdm_rsp_version.c (response construction)
ResponderSendsVersion ==
    /\ responderState = RESPONDER_VERSION_RESP
    /\ version' = 16  \* SPDM 1.0 negotiated (0x10)
    /\ versionNegotiated' = TRUE  \* Mark version as negotiated
    /\ messages' = messages \cup {[type |-> MSG_VERSION, version |-> version']}
    /\ responderState' = RESPONDER_CAPS_RESP
    /\ UNCHANGED <<requesterState, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    capabilitiesNegotiated, algorithmsNegotiated,
                    enabledCapabilities>>

\* Responder handles GET_CAPABILITIES
\* Corresponds to libspdm_rsp_capabilities.c:165-380
ResponderHandlesCapabilities ==
    /\ responderState = RESPONDER_CAPS_RESP
    /\ versionNegotiated = TRUE  \* Family 4: version must be negotiated
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
                    enabledCapabilities>>

\* Responder sends CAPABILITIES response
\* Corresponds to libspdm_rsp_capabilities.c (response construction)
ResponderSendsCapabilities ==
    /\ responderState = RESPONDER_ALGO_RESP
    /\ messages' = messages \cup {[type |-> MSG_CAPABILITIES]}
    /\ UNCHANGED <<requesterState, responderState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse,
                    prioritizationResult, prioritizationFailed,
                    versionNegotiated, capabilitiesNegotiated,
                    algorithmsNegotiated, enabledCapabilities>>

\* Responder handles NEGOTIATE_ALGORITHMS
\* Corresponds to libspdm_rsp_algorithms.c:557-695 (algorithm assignment phase)
\* Family 1: Responder accepts proposal WITHOUT validating against local support
\* Family 2: Responder may call prioritize_algorithm and gets 0 return
ResponderHandlesAlgorithms ==
    /\ responderState = RESPONDER_ALGO_RESP
    /\ capabilitiesNegotiated = TRUE  \* Family 4: capabilities must be negotiated
    /\ \E msg \in messages :
        /\ msg.type = MSG_NEGOTIATE_ALGORITHMS
        /\ \* Family 1: Responder accepts proposal without checking against localAlgorithms_resp
           \* (libspdm_rsp_algorithms.c:565-566: direct assignment without validation)
           LET proposed == msg.proposed_algos
               \* Family 2: Attempt to prioritize proposed algorithms
               prioritized == PrioritizeAlgorithm(localAlgorithms_resp, proposed)
           IN
             /\ IF prioritized = 0 THEN
                  \* Family 2: Prioritization failed - return 0 in response
                  /\ prioritizationResult' = 0
                  /\ prioritizationFailed' = TRUE
                  /\ responderResponse' = {}
                ELSE
                  \* Prioritization succeeded
                  /\ prioritizationResult' = prioritized
                  /\ prioritizationFailed' = FALSE
                  /\ responderResponse' = {prioritized}
             /\ algorithmsNegotiated' = TRUE
        /\ responderState' = RESPONDER_COMPLETE
        /\ messages' = messages \ {msg}
    /\ UNCHANGED <<requesterState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, versionNegotiated,
                    capabilitiesNegotiated, enabledCapabilities>>

\* Responder sends ALGORITHMS response
\* Corresponds to libspdm_rsp_algorithms.c:724-747 (response construction)
ResponderSendsAlgorithms ==
    /\ responderState = RESPONDER_COMPLETE
    /\ messages' = messages \cup {[type |-> MSG_ALGORITHMS,
                                  agreed_algos |-> responderResponse]}
    /\ UNCHANGED <<requesterState, responderState, version, agreedAlgorithms,
                    localAlgorithms_req, localAlgorithms_resp,
                    proposedAlgorithms, responderResponse, prioritizationResult,
                    prioritizationFailed, versionNegotiated,
                    capabilitiesNegotiated, algorithmsNegotiated,
                    enabledCapabilities>>

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

Next ==
    \/ RequesterInitVersion
    \/ RequesterReceivesVersion
    \/ RequesterInitCapabilities
    \/ RequesterReceivesCapabilities
    \/ RequesterInitAlgorithms
    \/ RequesterValidatesAlgorithms
    \/ ResponderHandlesVersion
    \/ ResponderSendsVersion
    \/ ResponderHandlesCapabilities
    \/ ResponderSendsCapabilities
    \/ ResponderHandlesAlgorithms
    \/ ResponderSendsAlgorithms

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* Standard Safety Invariants
TypeOK ==
    /\ requesterState \in {REQUESTER_INIT, REQUESTER_VERSION_SENT, REQUESTER_CAPS_SENT,
                            REQUESTER_ALGO_SENT, REQUESTER_COMPLETE}
    /\ responderState \in {RESPONDER_INIT, RESPONDER_VERSION_RESP, RESPONDER_CAPS_RESP,
                            RESPONDER_ALGO_RESP, RESPONDER_COMPLETE}
    /\ versionNegotiated \in {TRUE, FALSE}
    /\ capabilitiesNegotiated \in {TRUE, FALSE}
    /\ algorithmsNegotiated \in {TRUE, FALSE}
    /\ prioritizationFailed \in {TRUE, FALSE}

\* Family 1: Algorithm Intersection Validation
\* If both sides claim a negotiated algorithm, their local supports must intersect
AlgorithmIntersectionNonEmpty ==
    (requesterState = REQUESTER_COMPLETE /\ responderState = RESPONDER_COMPLETE) =>
        (algorithmsNegotiated = TRUE =>
            Intersect(localAlgorithms_req, localAlgorithms_resp) /= {})

\* Family 2: Prioritization Success
\* If prioritize_algorithm was called, either it succeeded or both sides have empty support
PrioritizationSucceeds ==
    (responderState = RESPONDER_COMPLETE /\ algorithmsNegotiated = TRUE) =>
        (prioritizationFailed = FALSE \/ Intersect(localAlgorithms_resp, proposedAlgorithms) = {})

\* Family 4: Version Negotiated Before Capabilities
VersionNegotiatedBeforeCapabilities ==
    capabilitiesNegotiated = TRUE => versionNegotiated = TRUE

\* Family 4: Version and Capabilities Negotiated Before Algorithms
VersionNegotiatedBeforeAlgorithms ==
    algorithmsNegotiated = TRUE => (versionNegotiated = TRUE /\ capabilitiesNegotiated = TRUE)

\* Family 5: Requester Validates If Capabilities Enabled
RequesterValidatesIfCapabilitiesEnabled ==
    (requesterState = REQUESTER_COMPLETE /\ ShouldValidateAlgorithms(enabledCapabilities)) =>
        (algorithmsNegotiated = TRUE <=> \neg IntersectionEmpty(localAlgorithms_req, responderResponse))

\* Family 1: Responder Algorithm Validation
\* Responder's agreed algorithm must be in responder's local support
ResponderAlgoInLocalSupport ==
    (responderState = RESPONDER_COMPLETE /\ algorithmsNegotiated = TRUE) =>
        (responderResponse \subseteq localAlgorithms_resp \/ responderResponse = {})

\* Structural Invariants
NoMessageDuplication ==
    TRUE  \* Automatically satisfied: messages is a set, so no duplicates

\* Handshake Progress
HandshakeOrdering ==
    /\ (requesterState \in {REQUESTER_CAPS_SENT, REQUESTER_ALGO_SENT, REQUESTER_COMPLETE}) =>
        versionNegotiated = TRUE
    /\ (requesterState \in {REQUESTER_ALGO_SENT, REQUESTER_COMPLETE}) =>
        capabilitiesNegotiated = TRUE

====
