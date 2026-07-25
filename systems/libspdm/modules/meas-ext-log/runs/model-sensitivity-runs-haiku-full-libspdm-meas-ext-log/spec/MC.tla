---- MODULE MC ----
(* Model Checking Spec for MEL Protocol
 * Wraps base spec with counter-bounded fault-injection actions
 *)

EXTENDS base, Naturals

(* Fault Injection Limits *)
CONSTANT MessageLossLimit
CONSTANT WrongRemainderLimit
CONSTANT OffsetOverflowLimit

(* Fault-Injection Counter Variables *)
VARIABLE messageLossCount
VARIABLE wrongRemainderCount
VARIABLE offsetOverflowCount

messageLossCtrVars == <<messageLossCount>>
wrongRemainderCtrVars == <<wrongRemainderCount>>
offsetOverflowCtrVars == <<offsetOverflowCount>>

(* ===== Counter-Bounded Actions ===== *)
(* Each fault-injection action has a counter limiting its firing rate *)

(* Fault: Response message loss (network drop)
 * BF2: If response is lost, remainder_length cannot be established
 *)
MCMessageLoss ==
    /\ messageLossCount < MessageLossLimit
    /\ \E msg \in messages :
        msg.type = MelResponse
        /\ messages' = messages \ {msg}
        /\ messageLossCount' = messageLossCount + 1
        /\ UNCHANGED requesterVars
        /\ UNCHANGED responderVars
        /\ UNCHANGED wrongRemainderCtrVars
        /\ UNCHANGED offsetOverflowCtrVars

(* Fault: Responder returns wrong remainder_length
 * BF2: Simulates remainder inconsistency
 * source: libspdm_req_get_measurement_extension_log.c:205-210
 *)
MCResponderWrongRemainder ==
    /\ wrongRemainderCount < WrongRemainderLimit
    /\ responder_pc = "ready"
    /\ \E req \in messages :
        req.type = GetMelRequest
        /\ LET offset == req.offset
             length == req.length
             mel_size == responder_mel.size
             valid_offset == offset < mel_size
             actual_length == IF offset + length > mel_size
                             THEN mel_size - offset
                             ELSE length
             correct_remainder == mel_size - offset - actual_length
             \* Introduce wrong remainder
             wrong_remainder == IF correct_remainder > 0
                               THEN correct_remainder - 1
                               ELSE 0
           IN /\ valid_offset
              /\ messages' = (messages \ {req}) \cup
                             {MakeMelResponse(actual_length, wrong_remainder, actual_length)}
              /\ wrongRemainderCount' = wrongRemainderCount + 1
              /\ UNCHANGED requesterVars
              /\ UNCHANGED responderVars
              /\ UNCHANGED messageLossCtrVars
              /\ UNCHANGED offsetOverflowCtrVars

(* Fault: Requester accepts response with overflow in offset
 * BF4: Offset increment doesn't detect overflow
 * source: libspdm_req_get_measurement_extension_log.c:109
 *)
MCOffsetOverflow ==
    /\ offsetOverflowCount < OffsetOverflowLimit
    /\ req_pc = "waiting"
    /\ \E resp \in messages :
        resp.type = MelResponse
        /\ LET portion_len == resp.portion_length
             remainder == resp.remainder_length
             new_mel_size == req_mel_size + portion_len
             \* Artificially large offset to test overflow
             bad_offset == MAX_MEL_SIZE + MAX_CHUNK_SIZE  \* Offset beyond MEL size
           IN /\ portion_len > 0
              /\ portion_len <= MAX_CHUNK_SIZE
              /\ new_mel_size <= MAX_MEL_SIZE
              /\ RemainderConsistent(bad_offset, portion_len, remainder,
                                    IF req_offset = 0 THEN portion_len + remainder
                                    ELSE req_total_mel_size)
              /\ messages' = messages \ {resp}
              /\ req_mel_size' = new_mel_size
              /\ req_remainder' = remainder
              /\ req_offset' = bad_offset  \* Inject bad offset
              /\ IF req_offset = 0
                 THEN req_total_mel_size' = portion_len + remainder
                 ELSE req_total_mel_size' = req_total_mel_size
              /\ IF remainder = 0
                 THEN req_pc' = "done"
                 ELSE req_pc' = "ready"
              /\ offsetOverflowCount' = offsetOverflowCount + 1
              /\ UNCHANGED responderVars
              /\ UNCHANGED wrongRemainderCtrVars
              /\ UNCHANGED messageLossCtrVars

(* ===== Normal Actions (Unchanged Counter Declarations) ===== *)
MCRequesterSendGetMel ==
    /\ RequesterSendGetMel
    /\ UNCHANGED messageLossCtrVars
    /\ UNCHANGED wrongRemainderCtrVars
    /\ UNCHANGED offsetOverflowCtrVars

MCResponderReceiveAndSendMel ==
    /\ ResponderReceiveAndSendMel
    /\ UNCHANGED messageLossCtrVars
    /\ UNCHANGED wrongRemainderCtrVars
    /\ UNCHANGED offsetOverflowCtrVars

MCRequesterReceiveMelResponse ==
    /\ RequesterReceiveMelResponse
    /\ UNCHANGED messageLossCtrVars
    /\ UNCHANGED wrongRemainderCtrVars
    /\ UNCHANGED offsetOverflowCtrVars

MCRequesterCheckTermination ==
    /\ RequesterCheckTermination
    /\ UNCHANGED messageLossCtrVars
    /\ UNCHANGED wrongRemainderCtrVars
    /\ UNCHANGED offsetOverflowCtrVars

(* ===== MC Init and Next ===== *)
MCInit ==
    /\ Init
    /\ messageLossCount = 0
    /\ wrongRemainderCount = 0
    /\ offsetOverflowCount = 0

MCNext ==
    \/ MCRequesterSendGetMel
    \/ MCResponderReceiveAndSendMel
    \/ MCRequesterReceiveMelResponse
    \/ MCRequesterCheckTermination
    \/ MCMessageLoss
    \/ MCResponderWrongRemainder
    \/ MCOffsetOverflow

MCSpec == MCInit /\ [][MCNext]_<<requesterVars, responderVars, msgVars, messageLossCtrVars, wrongRemainderCtrVars, offsetOverflowCtrVars>>

====
