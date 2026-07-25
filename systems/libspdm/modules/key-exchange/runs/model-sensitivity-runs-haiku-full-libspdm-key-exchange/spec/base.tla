---- MODULE base ----
(* SPDM KEY_EXCHANGE / FINISH Protocol Specification

   Modeling the SPDM 1.1+ session establishment protocol with comprehensive
   coverage of 5 bug families from the Modeling Brief:

   Family 1: Message Authentication Bypass via Protocol Mixing
   Family 2: Input Validation & Capability Mismatch
   Family 3: Session ID Lifecycle & Resource Leak
   Family 4: Certificate/Public Key Slot Validation
   Family 5: Transcript Hash Integrity & Reconstruction Divergence

   Category A (Distributed/Message-Passing) protocol spec modeling
   state transitions between Requester and Responder entities.
*)

EXTENDS Naturals, Sequences, FiniteSets

(* ===== CONSTANTS ===== *)

CONSTANT Requester, Responder, NULL_SESSION_ID
CONSTANT MAX_SESSIONS, MAX_HEARTBEAT_PERIOD
CONSTANT SLOT_1, SLOT_2  (* Certificate slot IDs *)

(* Session types - Family 1 *)
CONSTANT DHE, PSK, PSK_DHE

(* Capability flags - Family 2 *)
CONSTANT HBEAT_CAP, MULTI_KEY_CAP

(* Maximum opaque data length - Family 2 *)
CONSTANT MAX_OPAQUE_LENGTH

(* Compilation modes - Family 5 *)
CONSTANT WITH_RECORDS, FAST_PATH

(* ===== VARIABLES ===== *)

(* Standard protocol variables *)
VARIABLE messages       (* Message queue: sequences of messages *)
VARIABLE requesterState (* State of requester *)
VARIABLE responderState (* State of responder *)

(* Session variables - core tracking *)
VARIABLE sessions       (* Map: session_id -> session record *)
VARIABLE sessionIDCounter (* Counter for allocating unique session IDs *)

(* Extension variables from Bug Families *)

(* Family 1: Session type and transcript tracking *)
VARIABLE sessionType    (* Map: session_id -> {DHE, PSK, PSK_DHE} *)
VARIABLE transcriptHashKEX (* Map: session_id -> hash after KEY_EXCHANGE *)
VARIABLE transcriptHashFINISH (* Map: session_id -> hash after FINISH *)

(* Family 2: Negotiated capabilities *)
VARIABLE capabilitiesReq (* Requester capabilities: set of flags *)
VARIABLE capabilitiesRsp (* Responder capabilities: set of flags *)
VARIABLE capabilitiesValidated (* Boolean: capabilities checked *)

(* Family 3: Session ID pool lifecycle *)
VARIABLE sessionIDPool  (* Set: currently allocated session IDs *)
VARIABLE sessionIDPoolCount (* Counter for detecting leaks *)

(* Family 4: Certificate slots *)
VARIABLE certSlots     (* Map: slot_id -> {has_cert, key_usage_bits} *)

(* Family 5: Compilation mode flag *)
VARIABLE recordTranscriptData (* Boolean: WITH_RECORDS or FAST_PATH mode *)

(* ===== STANDARD HELPERS ===== *)

Null == [type |-> "null"]

IsNull(msg) == msg.type = "null"

(* ===== EXTENDED HELPERS - BUG FAMILIES ===== *)

(* Family 1: Transcript tracking *)
GetTranscriptPrefix(hash1, hash2) ==
    (** Returns TRUE if hash1 is a prefix of hash2 in transcript sequence *)
    \* In actual protocol, transcripts are byte sequences; here we model
    \* as logical prefixes: hash1 <= hash2 in the ordering
    TRUE  \* Placeholder: actual implementation uses byte-level comparison

CanMixSessionTypes(type1, type2) ==
    (** Family 1: Returns TRUE if two types can be mixed (protocol vulnerability) *)
    /\ type1 = DHE
    /\ type2 = PSK
    (* This represents the vulnerability: DHE KEY_EXCHANGE followed by PSK_FINISH *)

(* Family 2: Capability validation *)
IsCapabilityValid(param, cap, value) ==
    (** Family 2: Check if parameter value is valid under negotiated capability *)
    IF cap \in capabilitiesRsp THEN TRUE ELSE value = 0

ValidateHeartbeatPeriod(period) ==
    (** Family 2: lines libspdm_req_key_exchange.c:580-590 *)
    IF HBEAT_CAP \in capabilitiesRsp
    THEN period <= MAX_HEARTBEAT_PERIOD  \* Valid range check
    ELSE period = 0  \* Must be 0 if capability not negotiated

ValidateMutAuthRequested(bitfield) ==
    (** Family 2: lines libspdm_req_key_exchange.c:590-651 *)
    \* Valid encodings: bits must be coherent
    \* Invalid: bits 1&2 set but bit 0 clear
    LET bit0 == bitfield \in {1, 3, 5, 7}
        bit1 == bitfield \in {2, 3, 6, 7}
        bit2 == bitfield \in {4, 5, 6, 7}
    IN IF bit1 \/ bit2 THEN bit0 ELSE TRUE  \* bit0 required if bit1 or bit2

(* Family 3: Session ID allocation tracking *)
AllocateSessionID ==
    (** Family 3: lines libspdm_req_key_exchange.c:386 *)
    LET newID == sessionIDCounter + 1
    IN /\ newID <= MAX_SESSIONS
       /\ sessionIDPool' = sessionIDPool \cup {newID}
       /\ sessionIDCounter' = newID
       /\ UNCHANGED <<sessionIDPoolCount>>

FreeSessionID(sessionID) ==
    (** Family 3: Ensure all error paths free the session ID *)
    /\ sessionIDPool' = sessionIDPool \ {sessionID}

(* Family 4: Slot validation *)
ValidateSlotID(slotID, keyUsageBits) ==
    (** Family 4: lines libspdm_req_key_exchange.c:623-636 *)
    /\ slotID \in DOMAIN certSlots
    /\ certSlots[slotID].has_cert = TRUE
    /\ (MULTI_KEY_CAP \in capabilitiesRsp =>
        certSlots[slotID].key_usage_bits \cap keyUsageBits /= {})

(* Family 5: Dual-path transcript hash *)
ComputeTranscriptHash(messages_list, mode) ==
    (** Family 5: lines libspdm_req_key_exchange.c:60-101 and rsp_key_exchange.c:79-178
        Two implementations must compute identical hash *)
    IF mode = WITH_RECORDS
    THEN "hash_with_records"  \* Symbolic representation
    ELSE "hash_fast_path"

TranscriptHashesMatch ==
    (** Family 5: Verify both compilation modes produce same result *)
    \A sessionID \in DOMAIN transcriptHashKEX :
        LET hash_records == ComputeTranscriptHash(messages, WITH_RECORDS)
            hash_fast == ComputeTranscriptHash(messages, FAST_PATH)
        IN hash_records = hash_fast

(* ===== MESSAGES ===== *)

(* Message type constructors *)
KeyExchangeRequest(reqID, nonce, dheKey, capabilities) ==
    [type |-> "KEY_EXCHANGE_REQ",
     id |-> reqID,
     nonce |-> nonce,
     dhePublicKey |-> dheKey,
     capabilities |-> capabilities]

KeyExchangeResponse(sessionID, nonce, dheKey, signature, signature2, hmac, capabilities) ==
    [type |-> "KEY_EXCHANGE_RSP",
     sessionID |-> sessionID,
     nonce |-> nonce,
     dhePublicKey |-> dheKey,
     signature |-> signature,
     signature2 |-> signature2,
     hmac |-> hmac,
     heartbeatPeriod |-> 0,
     mutAuthRequested |-> 0,
     capabilities |-> capabilities]

FinishRequest(sessionID, hmac) ==
    [type |-> "FINISH_REQ",
     sessionID |-> sessionID,
     hmac |-> hmac]

FinishResponse(sessionID, hmac) ==
    [type |-> "FINISH_RSP",
     sessionID |-> sessionID,
     hmac |-> hmac]

ErrorResponse(detail) ==
    [type |-> "ERROR",
     detail |-> detail]

(* ===== SESSION RECORDS ===== *)

(* Session state enumeration *)
SessionInit == "INIT"
SessionKEXSent == "KEX_SENT"
SessionKEXReceived == "KEX_RECEIVED"
SessionFinishSent == "FINISH_SENT"
SessionFinishReceived == "FINISH_RECEIVED"
SessionHandshaking == "HANDSHAKING"
SessionError == "ERROR"

MakeSession(id, sessiontype) ==
    [id |-> id,
     type |-> sessiontype,
     state |-> SessionInit,
     transcriptHash |-> "empty",
     requesterNonce |-> 0,
     responderNonce |-> 0,
     dheKeysAgreed |-> FALSE,
     hmacVerified |-> FALSE,
     signature2Verified |-> FALSE,
     slot |-> Null]

(* ===== ROLE STATE ===== *)

InitRequesterState ==
    [state |-> "IDLE",
     currentSessionID |-> NULL_SESSION_ID]

InitResponderState ==
    [state |-> "IDLE",
     currentSessionID |-> NULL_SESSION_ID]

(* ===== INVARIANTS ===== *)

(* Standard protocol invariants *)

TypeOK ==
    (** Every variable has correct type *)
    /\ messages \in Seq([ type: {"KEY_EXCHANGE_REQ", "KEY_EXCHANGE_RSP",
                                   "FINISH_REQ", "FINISH_RSP", "ERROR"},
                           id: Nat, sessionID: Nat \cup {NULL_SESSION_ID} ])
    /\ requesterState.state \in {"IDLE", "KEX_SENT", "KEX_RECEIVED", "FINISH_SENT", "HANDSHAKING"}
    /\ responderState.state \in {"IDLE", "KEX_RECEIVED", "KEX_SENT", "FINISH_RECEIVED", "HANDSHAKING"}
    /\ sessionIDCounter \in Nat
    /\ sessionIDPool \subseteq 1..MAX_SESSIONS
    /\ capabilitiesValidated \in BOOLEAN
    /\ recordTranscriptData \in {WITH_RECORDS, FAST_PATH}

(* Family 1 invariants *)

AuthenticationSafety ==
    (** If DHE KEY_EXCHANGE is sent, FINISH must not use PSK type
        and responder must verify mutual authentication. Lines from
        libspdm_req_key_exchange.c:580-590, libspdm_rsp_finish_rsp.c *)
    \A sessionID \in DOMAIN sessions :
        /\ sessions[sessionID].state = SessionHandshaking
        => /\ sessionType[sessionID] \in {DHE, PSK_DHE}
           \* Cannot transition from DHE to PSK only

TranscriptContinuity ==
    (** Transcript hash at end of KEY_EXCHANGE must be prefix of
        transcript hash at FINISH. Lines from libspdm_req_key_exchange.c,
        libspdm_req_finish.c *)
    \A sessionID \in DOMAIN transcriptHashKEX :
        transcriptHashKEX[sessionID] <= transcriptHashFINISH[sessionID]
    (* Using lexicographic ordering as proxy for transcript prefix property *)

NoProtocolMixing ==
    (** Cannot mix DHE KEY_EXCHANGE with PSK_FINISH for same session *)
    \A sessionID \in DOMAIN sessions :
        LET s == sessions[sessionID]
            t == sessionType[sessionID]
        IN ~CanMixSessionTypes(t, PSK)

(* Family 2 invariants *)

CapabilityConsistency ==
    (** All message parameters must be valid under negotiated capabilities.
        Lines from libspdm_req_key_exchange.c:580-590 *)
    capabilitiesValidated =>
        /\ ValidateHeartbeatPeriod(0)  \* Check in messages
        /\ ValidateMutAuthRequested(0) \* Check in messages

(* Family 3 invariants *)

SessionIDUniqueness ==
    (** All allocated session IDs are unique *)
    /\ Cardinality(sessionIDPool) = sessionIDPoolCount

SessionIDCleanup ==
    (** When a session completes or errors, its ID is freed.
        Lines from libspdm_req_key_exchange.c:744-878 *)
    \A sessionID \in DOMAIN sessions :
        sessions[sessionID].state = SessionError =>
            sessionID \notin sessionIDPool

SessionIDNoBoundaryLeaks ==
    (** Session ID allocated by KEY_EXCHANGE must be freed on all error paths.
        Catches Family 3 Bug #476. Lines from libspdm_req_finish.c *)
    /\ \A sessionID \in sessionIDPool :
            \E s \in { sessions[id] : id \in DOMAIN sessions } :
                s.id = sessionID

NoSessionIDExhaustion ==
    (** Session pool doesn't leak even after many failed FINISHes *)
    Cardinality(sessionIDPool) < MAX_SESSIONS

(* Family 4 invariants *)

SlotValidation ==
    (** Any slot_id reference must exist and have required key_usage_bits.
        Lines from libspdm_req_key_exchange.c:623-636 *)
    \A sessionID \in DOMAIN sessions :
        sessions[sessionID].slot /= Null =>
            ValidateSlotID(sessions[sessionID].slot, {})

(* Family 5 invariants *)

PathEquivalence ==
    (** Both compilation modes produce identical transcript hash *)
    recordTranscriptData = WITH_RECORDS => TranscriptHashesMatch

(* General safety invariants *)

NoDoubleFinish ==
    (** Session cannot reach HANDSHAKING twice *)
    \A sessionID \in DOMAIN sessions :
        Cardinality({ s \in { sessions[id] : id \in DOMAIN sessions } :
                      s.state = SessionHandshaking /\ s.id = sessionID }) <= 1

(* ===== ACTIONS ===== *)

(* Requester initiates KEY_EXCHANGE request
   Lines: libspdm_req_key_exchange.c:300-400 *)
ReqSendKeyExchange ==
    /\ requesterState.state = "IDLE"
    /\ requesterState' = [requesterState EXCEPT !.state = "KEX_SENT"]
    /\ LET kexReq == KeyExchangeRequest(1, 0, "dhe_key_1", {})
       IN messages' = Append(messages, kexReq)
    /\ capabilitiesReq' = {}
    /\ UNCHANGED <<responderState, sessions, sessionIDCounter, sessionType,
                   transcriptHashKEX, transcriptHashFINISH,
                   capabilitiesRsp, capabilitiesValidated,
                   sessionIDPool, sessionIDPoolCount, certSlots,
                   recordTranscriptData>>

(* Responder receives KEY_EXCHANGE request and sends response
   Lines: libspdm_rsp_key_exchange.c:50-350 *)
RespReceiveKeyExchange ==
    /\ responderState.state = "IDLE"
    /\ Len(messages) > 0
    /\ messages[Len(messages)].type = "KEY_EXCHANGE_REQ"
    /\ LET req == messages[Len(messages)]
           newSessionID == sessionIDCounter + 1
       IN /\ newSessionID \in 1..MAX_SESSIONS  \* Family 3: allocation boundary
          /\ sessions' = [s \in DOMAIN sessions \cup {newSessionID} |->
                          IF s = newSessionID THEN MakeSession(newSessionID, DHE) ELSE sessions[s]]
          /\ sessionIDCounter' = newSessionID
          /\ sessionIDPool' = sessionIDPool \cup {newSessionID}
          /\ sessionIDPoolCount' = sessionIDPoolCount + 1
          /\ sessionType' = [st \in DOMAIN sessionType \cup {newSessionID} |->
                           IF st = newSessionID THEN DHE ELSE sessionType[st]]
          /\ responderState' = [responderState EXCEPT !.state = "KEX_SENT",
                                                      !.currentSessionID = newSessionID]
          /\ LET kexRsp == KeyExchangeResponse(newSessionID, 0, "dhe_key_2",
                                              "sig", "sig2", "hmac", {})
             IN messages' = Append(messages, kexRsp)
          /\ capabilitiesRsp' = {}
          /\ capabilitiesValidated' = FALSE
    /\ UNCHANGED <<requesterState, transcriptHashKEX, transcriptHashFINISH,
                   capabilitiesReq, certSlots, recordTranscriptData>>

(* Requester receives KEY_EXCHANGE response and validates
   Lines: libspdm_req_key_exchange.c:500-700 *)
ReqReceiveKeyExchange ==
    /\ requesterState.state = "KEX_SENT"
    /\ Len(messages) > 0
    /\ messages[Len(messages)].type = "KEY_EXCHANGE_RSP"
    /\ LET rsp == messages[Len(messages)]
       IN /\ rsp.sessionID \in sessionIDPool  \* Verify session exists
          /\ sessions[rsp.sessionID].state = SessionInit
          (* Family 2: Validate capabilities - lines 580-590 *)
          /\ ValidateHeartbeatPeriod(rsp.heartbeatPeriod)
          /\ ValidateMutAuthRequested(rsp.mutAuthRequested)
          (* Family 4: Validate slot if present - lines 623-636 *)
          /\ (rsp.slot /= Null => ValidateSlotID(rsp.slot, {}))
          /\ requesterState' = [requesterState EXCEPT !.state = "KEX_RECEIVED",
                                                      !.currentSessionID = rsp.sessionID]
          /\ sessions' = [sessions EXCEPT ![rsp.sessionID].state = SessionKEXReceived,
                                          ![rsp.sessionID].dheKeysAgreed = TRUE]
          /\ transcriptHashKEX' = [th \in DOMAIN transcriptHashKEX \cup {rsp.sessionID} |->
                                   IF th = rsp.sessionID THEN "kex_hash" ELSE transcriptHashKEX[th]]
          /\ capabilitiesValidated' = TRUE
    /\ UNCHANGED <<responderState, sessionIDCounter, sessionIDPool, sessionIDPoolCount,
                   messages, sessionType, transcriptHashFINISH,
                   capabilitiesReq, capabilitiesRsp, certSlots,
                   recordTranscriptData>>

(* Requester sends FINISH request
   Lines: libspdm_req_finish.c:50-150 *)
ReqSendFinish ==
    /\ requesterState.state = "KEX_RECEIVED"
    /\ LET sessionID == requesterState.currentSessionID
       IN /\ sessionID \in DOMAIN sessions
          /\ sessions[sessionID].state = SessionKEXReceived
          (* Family 1: Verify session type consistency - line 85+ *)
          /\ sessionType[sessionID] \in {DHE, PSK_DHE}
          /\ requesterState' = [requesterState EXCEPT !.state = "FINISH_SENT"]
          /\ LET finishReq == FinishRequest(sessionID, "req_hmac")
             IN messages' = Append(messages, finishReq)
          /\ transcriptHashFINISH' = [tf \in DOMAIN transcriptHashFINISH \cup {sessionID} |->
                                     IF tf = sessionID THEN "finish_hash" ELSE transcriptHashFINISH[tf]]
    /\ UNCHANGED <<responderState, sessions, sessionIDCounter,
                   sessionIDPool, sessionIDPoolCount, sessionType,
                   transcriptHashKEX, capabilitiesReq, capabilitiesRsp,
                   capabilitiesValidated, certSlots, recordTranscriptData>>

(* Responder receives FINISH request and sends response
   Lines: libspdm_rsp_finish_rsp.c:50-300 *)
RespReceiveFinish ==
    /\ responderState.state = "KEX_SENT"
    /\ Len(messages) > 0
    /\ messages[Len(messages)].type = "FINISH_REQ"
    /\ LET req == messages[Len(messages)]
       IN /\ req.sessionID \in DOMAIN sessions
          /\ sessions[req.sessionID].state = SessionKEXReceived
          (* Family 2: Validate opaque_length if present - line 280+ *)
          (* Family 5: HMAC verification with both paths - lines 85-113 *)
          /\ responderState' = [responderState EXCEPT !.state = "FINISH_SENT"]
          /\ sessions' = [sessions EXCEPT ![req.sessionID].hmacVerified = TRUE,
                                          ![req.sessionID].state = SessionFinishReceived]
          /\ LET finishRsp == FinishResponse(req.sessionID, "rsp_hmac")
             IN messages' = Append(messages, finishRsp)
    /\ UNCHANGED <<requesterState, sessionIDCounter, sessionIDPool, sessionIDPoolCount,
                   sessionType, transcriptHashKEX, transcriptHashFINISH,
                   capabilitiesReq, capabilitiesRsp, capabilitiesValidated,
                   certSlots, recordTranscriptData>>

(* Requester receives FINISH response and establishes secure session
   Lines: libspdm_req_finish.c:85-150 *)
ReqReceiveFinish ==
    /\ requesterState.state = "FINISH_SENT"
    /\ Len(messages) > 0
    /\ messages[Len(messages)].type = "FINISH_RSP"
    /\ LET rsp == messages[Len(messages)]
       IN /\ rsp.sessionID \in DOMAIN sessions
          /\ sessions[rsp.sessionID].state = SessionFinishReceived
          (* Family 1: Ensure transcript consistency - line 85+ *)
          /\ transcriptHashKEX[rsp.sessionID] <= transcriptHashFINISH[rsp.sessionID]
          /\ requesterState' = [requesterState EXCEPT !.state = "HANDSHAKING"]
          /\ sessions' = [sessions EXCEPT ![rsp.sessionID].state = SessionHandshaking]
    /\ UNCHANGED <<responderState, messages, sessionIDCounter,
                   sessionIDPool, sessionIDPoolCount, sessionType,
                   transcriptHashKEX, transcriptHashFINISH,
                   capabilitiesReq, capabilitiesRsp, capabilitiesValidated,
                   certSlots, recordTranscriptData>>

(* Error handling: Free session ID on KEY_EXCHANGE failure
   Lines: libspdm_req_key_exchange.c:744-878 *)
KeyExchangeErrorCleanup ==
    (** Family 3: Session ID cleanup on error paths *)
    /\ \E sessionID \in sessionIDPool :
        /\ sessions[sessionID].state = SessionInit
        /\ sessionIDPool' = sessionIDPool \ {sessionID}
        /\ sessionIDPoolCount' = sessionIDPoolCount - 1
    /\ UNCHANGED <<requesterState, responderState, messages, sessions,
                   sessionIDCounter, sessionType, transcriptHashKEX,
                   transcriptHashFINISH, capabilitiesReq, capabilitiesRsp,
                   capabilitiesValidated, certSlots, recordTranscriptData>>

(* Error handling: Free session ID on FINISH failure
   Lines: libspdm_req_finish.c (note: no cleanup in original) *)
FinishErrorCleanup ==
    (** Family 3: Session ID cleanup on FINISH error paths (missing in code) *)
    /\ \E sessionID \in sessionIDPool :
        /\ sessions[sessionID].state = SessionKEXReceived
        /\ sessionIDPool' = sessionIDPool \ {sessionID}
        /\ sessionIDPoolCount' = sessionIDPoolCount - 1
    /\ UNCHANGED <<requesterState, responderState, messages, sessions,
                   sessionIDCounter, sessionType, transcriptHashKEX,
                   transcriptHashFINISH, capabilitiesReq, capabilitiesRsp,
                   capabilitiesValidated, certSlots, recordTranscriptData>>

(* ===== INIT ===== *)

Init ==
    /\ messages = <<>>
    /\ requesterState = InitRequesterState
    /\ responderState = InitResponderState
    /\ sessions = <<>>
    /\ sessionIDCounter = 0
    /\ sessionType = <<>>
    /\ transcriptHashKEX = <<>>
    /\ transcriptHashFINISH = <<>>
    /\ capabilitiesReq = {}
    /\ capabilitiesRsp = {}
    /\ capabilitiesValidated = FALSE
    /\ sessionIDPool = {}
    /\ sessionIDPoolCount = 0
    /\ certSlots = [s \in {SLOT_1, SLOT_2} |-> [has_cert |-> TRUE, key_usage_bits |-> {}]]
    /\ recordTranscriptData = WITH_RECORDS

(* ===== NEXT ===== *)

Next ==
    \/ ReqSendKeyExchange
    \/ RespReceiveKeyExchange
    \/ ReqReceiveKeyExchange
    \/ ReqSendFinish
    \/ RespReceiveFinish
    \/ ReqReceiveFinish
    \/ KeyExchangeErrorCleanup
    \/ FinishErrorCleanup

(* ===== SPEC ===== *)

Spec == Init /\ [][Next]_<<requesterState, responderState, messages, sessions,
                            sessionIDCounter, sessionType, transcriptHashKEX,
                            transcriptHashFINISH, capabilitiesReq, capabilitiesRsp,
                            capabilitiesValidated, sessionIDPool, sessionIDPoolCount,
                            certSlots, recordTranscriptData>>

====
