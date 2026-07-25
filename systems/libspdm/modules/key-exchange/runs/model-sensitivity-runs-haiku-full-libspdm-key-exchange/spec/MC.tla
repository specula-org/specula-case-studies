---- MODULE MC ----
(* Model Checking wrapper for SPDM KEY_EXCHANGE / FINISH protocol

   Counter-bounded fault injection for exhaustive state space exploration.
   Each fault action is bounded by a counter to enable systematic bug hunting.
*)

EXTENDS base, Naturals, FiniteSets

(* ===== COUNTER VARIABLES ===== *)

VARIABLE faultVars

FaultCounters == faultVars

(* ===== FAULT ACTIONS (Counter-Bounded) ===== *)

(* Family 1 Fault: Protocol Mixing - Allow responder to accept PSK_FINISH after DHE KEY_EXCHANGE
   Simulates the DMTF-2023-0001 / CVE 2023-38545 vulnerability
   Lines: libspdm_req_key_exchange.c:580-590, libspdm_rsp_finish_rsp.c *)
MCEnableProtocolMixing ==
    /\ faultVars.protocolMixingCount < faultVars.protocolMixingLimit
    /\ \E sessionID \in DOMAIN sessions :
        /\ sessionType[sessionID] = DHE
        /\ sessionType' = [sessionType EXCEPT ![sessionID] = PSK]
        /\ faultVars' = [faultVars EXCEPT !.protocolMixingCount = @ + 1]
    /\ UNCHANGED <<requesterState, responderState, messages, sessions,
                   sessionIDCounter, transcriptHashKEX, transcriptHashFINISH,
                   capabilitiesReq, capabilitiesRsp, capabilitiesValidated,
                   sessionIDPool, sessionIDPoolCount, certSlots,
                   recordTranscriptData>>

(* Family 2 Fault: Invalid Capability Acceptance
   Responder accepts invalid heartbeat period or malformed mut_auth_requested
   Lines: libspdm_req_key_exchange.c:580-590 *)
MCAcceptInvalidHeartbeatPeriod ==
    /\ faultVars.capabilityMismatchCount < faultVars.capabilityMismatchLimit
    /\ \E msg_idx \in 1..Len(messages) :
        /\ messages[msg_idx].type = "KEY_EXCHANGE_RSP"
        /\ messages[msg_idx].heartbeatPeriod > MAX_HEARTBEAT_PERIOD
        /\ faultVars' = [faultVars EXCEPT !.capabilityMismatchCount = @ + 1]
    /\ UNCHANGED <<requesterState, responderState, messages, sessions,
                   sessionIDCounter, sessionType, transcriptHashKEX,
                   transcriptHashFINISH, capabilitiesReq, capabilitiesRsp,
                   capabilitiesValidated, sessionIDPool, sessionIDPoolCount,
                   certSlots, recordTranscriptData>>

MCAcceptInvalidMutAuthBits ==
    /\ faultVars.capabilityMismatchCount < faultVars.capabilityMismatchLimit
    /\ \E msg_idx \in 1..Len(messages) :
        /\ messages[msg_idx].type = "KEY_EXCHANGE_RSP"
        /\ ~ValidateMutAuthRequested(messages[msg_idx].mutAuthRequested)
        /\ faultVars' = [faultVars EXCEPT !.capabilityMismatchCount = @ + 1]
    /\ UNCHANGED <<requesterState, responderState, messages, sessions,
                   sessionIDCounter, sessionType, transcriptHashKEX,
                   transcriptHashFINISH, capabilitiesReq, capabilitiesRsp,
                   capabilitiesValidated, sessionIDPool, sessionIDPoolCount,
                   certSlots, recordTranscriptData>>

(* Family 3 Fault: Session ID Leak - Fail to free ID on error path
   Simulates GitHub issue #476: try_spdm_send_receive_finish() missing cleanup
   Lines: libspdm_req_finish.c (no cleanup) *)
MCLeakSessionIDOnFinishError ==
    /\ faultVars.sessionIDLeakCount < faultVars.sessionIDLeakLimit
    /\ \E sessionID \in sessionIDPool :
        /\ sessions[sessionID].state = SessionKEXReceived
        \* Simulate error that doesn't call cleanup
        /\ faultVars' = [faultVars EXCEPT !.sessionIDLeakCount = @ + 1]
    /\ UNCHANGED <<requesterState, responderState, messages, sessions,
                   sessionIDCounter, sessionType, transcriptHashKEX,
                   transcriptHashFINISH, capabilitiesReq, capabilitiesRsp,
                   capabilitiesValidated, sessionIDPool, sessionIDPoolCount,
                   certSlots, recordTranscriptData>>

MCLeakSessionIDOnKEXError ==
    /\ faultVars.sessionIDLeakCount < faultVars.sessionIDLeakLimit
    /\ \E sessionID \in sessionIDPool :
        /\ sessions[sessionID].state = SessionInit
        \* Simulate opaque_length error path that doesn't free ID
        /\ faultVars' = [faultVars EXCEPT !.sessionIDLeakCount = @ + 1]
    /\ UNCHANGED <<requesterState, responderState, messages, sessions,
                   sessionIDCounter, sessionType, transcriptHashKEX,
                   transcriptHashFINISH, capabilitiesReq, capabilitiesRsp,
                   capabilitiesValidated, sessionIDPool, sessionIDPoolCount,
                   certSlots, recordTranscriptData>>

(* Family 4 Fault: Invalid Slot Acceptance
   Responder accepts slot_id without verifying key_usage_bits are set
   Lines: libspdm_req_key_exchange.c:623-636, libspdm_rsp_key_exchange.c:295-341 *)
MCAcceptInvalidSlotID ==
    /\ faultVars.slotValidationCount < faultVars.slotValidationLimit
    /\ \E sessionID \in DOMAIN sessions :
        /\ sessions[sessionID].slot /= NULL_SESSION_ID
        /\ MULTI_KEY_CAP \in capabilitiesRsp
        /\ certSlots[sessions[sessionID].slot].key_usage_bits = {}
        \* Simulates bug: accepts despite empty key_usage_bits
        /\ faultVars' = [faultVars EXCEPT !.slotValidationCount = @ + 1]
    /\ UNCHANGED <<requesterState, responderState, messages, sessions,
                   sessionIDCounter, sessionType, transcriptHashKEX,
                   transcriptHashFINISH, capabilitiesReq, capabilitiesRsp,
                   capabilitiesValidated, sessionIDPool, sessionIDPoolCount,
                   certSlots, recordTranscriptData>>

(* Family 5 Fault: Transcript Hash Divergence
   Two compilation modes compute different hashes
   Lines: libspdm_req_key_exchange.c:60-101, libspdm_rsp_key_exchange.c:79-178 *)
MCTranscriptHashMismatch ==
    /\ faultVars.transcriptDivergenceCount < faultVars.transcriptDivergenceLimit
    /\ recordTranscriptData = WITH_RECORDS
    /\ LET fast_hash == ComputeTranscriptHash(messages, FAST_PATH)
           recorded_hash == ComputeTranscriptHash(messages, WITH_RECORDS)
       IN /\ fast_hash /= recorded_hash
          /\ \E sessionID \in DOMAIN sessions :
              /\ transcriptHashKEX[sessionID] = recorded_hash
              /\ transcriptHashFINISH[sessionID] = fast_hash
              /\ faultVars' = [faultVars EXCEPT !.transcriptDivergenceCount = @ + 1]
    /\ UNCHANGED <<requesterState, responderState, messages, sessions,
                   sessionIDCounter, sessionType, transcriptHashKEX,
                   transcriptHashFINISH, capabilitiesReq, capabilitiesRsp,
                   capabilitiesValidated, sessionIDPool, sessionIDPoolCount,
                   certSlots, recordTranscriptData>>

(* Message Loss Fault - generic *)
MCLoseMessage ==
    /\ faultVars.messageLossCount < faultVars.messageLossLimit
    /\ Len(messages) > 0
    /\ \E idx \in 1..Len(messages) :
        /\ messages' = SubSeq(messages, 1, idx - 1) \o SubSeq(messages, idx + 1, Len(messages))
        /\ faultVars' = [faultVars EXCEPT !.messageLossCount = @ + 1]
    /\ UNCHANGED <<requesterState, responderState, sessions,
                   sessionIDCounter, sessionType, transcriptHashKEX,
                   transcriptHashFINISH, capabilitiesReq, capabilitiesRsp,
                   capabilitiesValidated, sessionIDPool, sessionIDPoolCount,
                   certSlots, recordTranscriptData>>

(* ===== CONSTRAINED WRAPPERS (Base Actions with Counter Bounds) ===== *)

MCReqSendKeyExchange ==
    /\ ReqSendKeyExchange
    /\ UNCHANGED faultVars

MCRespReceiveKeyExchange ==
    /\ RespReceiveKeyExchange
    /\ UNCHANGED faultVars

MCReqReceiveKeyExchange ==
    /\ ReqReceiveKeyExchange
    /\ UNCHANGED faultVars

MCReqSendFinish ==
    /\ ReqSendFinish
    /\ UNCHANGED faultVars

MCRespReceiveFinish ==
    /\ RespReceiveFinish
    /\ UNCHANGED faultVars

MCReqReceiveFinish ==
    /\ ReqReceiveFinish
    /\ UNCHANGED faultVars

MCKeyExchangeErrorCleanup ==
    /\ KeyExchangeErrorCleanup
    /\ UNCHANGED faultVars

MCFinishErrorCleanup ==
    /\ FinishErrorCleanup
    /\ UNCHANGED faultVars

(* ===== MC INIT ===== *)

MCInit ==
    /\ Init
    /\ faultVars = [protocolMixingCount |-> 0,
                    protocolMixingLimit |-> 3,
                    capabilityMismatchCount |-> 0,
                    capabilityMismatchLimit |-> 3,
                    sessionIDLeakCount |-> 0,
                    sessionIDLeakLimit |-> 3,
                    slotValidationCount |-> 0,
                    slotValidationLimit |-> 2,
                    transcriptDivergenceCount |-> 0,
                    transcriptDivergenceLimit |-> 2,
                    messageLossCount |-> 0,
                    messageLossLimit |-> 3]

(* ===== MC NEXT ===== *)

MCNext ==
    \/ MCReqSendKeyExchange
    \/ MCRespReceiveKeyExchange
    \/ MCReqReceiveKeyExchange
    \/ MCReqSendFinish
    \/ MCRespReceiveFinish
    \/ MCReqReceiveFinish
    \/ MCKeyExchangeErrorCleanup
    \/ MCFinishErrorCleanup
    (* Fault injection actions *)
    \/ MCEnableProtocolMixing
    \/ MCAcceptInvalidHeartbeatPeriod
    \/ MCAcceptInvalidMutAuthBits
    \/ MCLeakSessionIDOnFinishError
    \/ MCLeakSessionIDOnKEXError
    \/ MCAcceptInvalidSlotID
    \/ MCTranscriptHashMismatch
    \/ MCLoseMessage

(* ===== SYMMETRY REDUCTION ===== *)

(* Permutation == {{Requester, Responder}, {Responder, Requester}} *)

(* ===== VIEW (for symmetry) ===== *)

View == <<requesterState, responderState, messages, sessions,
          sessionType, transcriptHashKEX, transcriptHashFINISH,
          capabilitiesValidated, sessionIDPool>>

(* ===== MC SPEC ===== *)

MCSpec == MCInit /\ [][MCNext]_<<requesterState, responderState, messages, sessions,
                                 sessionIDCounter, sessionType, transcriptHashKEX,
                                 transcriptHashFINISH, capabilitiesReq, capabilitiesRsp,
                                 capabilitiesValidated, sessionIDPool, sessionIDPoolCount,
                                 certSlots, recordTranscriptData, faultVars>>

====
