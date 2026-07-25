------------------------------ MODULE MC --------------------------------
(*
 * Model-checking wrapper for SecuredMessage.
 * Wraps fault-injection actions with per-action counters so TLC can explore
 * the state space exhaustively without unbounded injection loops.
 *
 * Counter design: each counter is checked AND incremented on the same transition.
 * Reactive actions (decode, key-update handlers) are NOT bounded – only the
 * non-deterministic injections and initiating actions are.
 *
 * Bug families targeted:
 *   F1 – InjectWrongSessionId, InjectAEADFailure
 *   F2 – bounded key-update initiations; InjectWrongEpochVerifyNewKey
 *   F3 – EncapCreateAndActivateRspKey initiation
 *   F4 – SendResponseNotReady
 *)
EXTENDS SecuredMessage

VARIABLES faultVars

\* faultVars record definition
FaultVarsInit ==
    faultVars = [
        wrongSessionId   |-> 0,   \* F1
        aeadFailure      |-> 0,   \* F1
        keyUpdateInit    |-> 0,   \* F2: non-encap KEY_UPDATE initiations
        wrongEpochVNK    |-> 0,   \* F2: injected wrong-epoch VERIFY_NEW_KEY
        encapInit        |-> 0,   \* F3: encap key-update initiations
        responseNotReady |-> 0    \* F4
    ]

\* MC bounds – override in hunt configs
CONSTANTS
    MaxWrongSessionId,   \* F1
    MaxAEADFailure,      \* F1
    MaxKeyUpdateInit,    \* F2
    MaxWrongEpochVNK,    \* F2
    MaxEncapInit,        \* F3
    MaxResponseNotReady, \* F4
    MaxMsgBuffer         \* structural: message bag size

-------------------------------------------------------------------------
\* BOUNDED WRAPPERS for fault-injection and initiation actions

MCInjectWrongSessionId(d) ==
    /\ faultVars.wrongSessionId < MaxWrongSessionId
    /\ BagCardinality(msgs) < MaxMsgBuffer
    /\ InjectWrongSessionId(d)
    /\ faultVars' = [faultVars EXCEPT !.wrongSessionId = @ + 1]

MCInjectAEADFailure(d) ==
    /\ faultVars.aeadFailure < MaxAEADFailure
    /\ BagCardinality(msgs) < MaxMsgBuffer
    /\ InjectAEADFailure(d)
    /\ faultVars' = [faultVars EXCEPT !.aeadFailure = @ + 1]

\* MCUpdateAllKeys – atomic: CreateUpdateResponderKey + SendKeyUpdateRequest(TRUE).
\* In the implementation, create_update(RESPONDER) is ONLY called inside the UPDATE_ALL_KEYS
\* path (libspdm_req_key_update.c:111–122, guarded by !single_direction).  Separating them
\* allows TLC to create the rsp key and then send UPDATE_KEY (false intermediate state).
MCUpdateAllKeys ==
    LET e  == Requester
        d  == RequestDir
        sd == ResponseDir
        m  == [mtype |-> MSG_KEY_UPDATE, dir |-> d,
               epoch |-> active_epoch[e][d],
               seq   |-> seq[e][d] + 1,
               session_id_ok |-> TRUE, aead_ok |-> TRUE, all_keys |-> TRUE]
    IN
    /\ faultVars.keyUpdateInit < MaxKeyUpdateInit
    /\ BagCardinality(msgs) < MaxMsgBuffer
    /\ update_phase = Idle
    /\ is_encap = FALSE
    /\ active_epoch[e][sd] < MaxEpoch
    \* CreateUpdateResponderKey effects: backup rsp key, install new epoch, reset seq
    /\ backup_epoch' = [backup_epoch EXCEPT ![e][sd] = active_epoch[e][sd]]
    /\ backup_seq'   = [backup_seq   EXCEPT ![e][sd] = seq[e][sd]]
    /\ backup_valid' = [backup_valid EXCEPT ![e][sd] = TRUE]
    /\ active_epoch' = [active_epoch EXCEPT ![e][sd] = active_epoch[e][sd] + 1]
    \* Combined seq update: rsp seq reset + req seq advance for KEY_UPDATE message
    /\ seq' = [seq EXCEPT ![e][sd] = 0, ![e][d] = seq[e][d] + 1]
    \* SendKeyUpdateRequest(TRUE) effects on update state and network
    /\ update_phase'    = PendingAck
    /\ update_all_keys' = TRUE
    /\ is_encap'        = FALSE
    /\ initiator_committed' = initiator_committed
    /\ msgs' = msgs (+) SetToBag({m})
    /\ faultVars' = [faultVars EXCEPT !.keyUpdateInit = @ + 1]

MCSendKeyUpdateRequest ==
    \* UPDATE_KEY only (single direction, no prior create_update(RESPONDER))
    /\ faultVars.keyUpdateInit < MaxKeyUpdateInit
    /\ BagCardinality(msgs) < MaxMsgBuffer
    /\ SendKeyUpdateRequest(FALSE)
    /\ faultVars' = [faultVars EXCEPT !.keyUpdateInit = @ + 1]

MCInjectWrongEpochVerifyNewKey ==
    /\ faultVars.wrongEpochVNK < MaxWrongEpochVNK
    /\ BagCardinality(msgs) < MaxMsgBuffer
    /\ InjectWrongEpochVerifyNewKey
    /\ faultVars' = [faultVars EXCEPT !.wrongEpochVNK = @ + 1]

MCEncapCreateAndActivateRspKey ==
    /\ faultVars.encapInit < MaxEncapInit
    /\ EncapCreateAndActivateRspKey
    /\ faultVars' = [faultVars EXCEPT !.encapInit = @ + 1]

MCSendResponseNotReady ==
    /\ faultVars.responseNotReady < MaxResponseNotReady
    /\ BagCardinality(msgs) < MaxMsgBuffer
    /\ SendResponseNotReady
    /\ faultVars' = [faultVars EXCEPT !.responseNotReady = @ + 1]

-------------------------------------------------------------------------
\* UNBOUNDED PASS-THROUGHS (reactive / deterministic actions)

\* MCEncodeAndSend – atomic: seq++ AND send message.
\* Base spec splits this into EncodeAdvanceSeq + EncodeSuccess (for trace validation); in MC we
\* combine them so TLC cannot fire EncodeSuccess a second time on the same seq value, which
\* would put two identical messages in the bag and create spurious SeqMonotonicity violations.
MCEncodeAndSend(d) ==
    LET e == Sender(d)
        m == [mtype |-> MSG_DATA, dir |-> d,
              epoch |-> active_epoch[e][d],
              seq   |-> seq[e][d] + 1,
              session_id_ok |-> TRUE,
              aead_ok       |-> TRUE,
              all_keys      |-> FALSE]
    IN
    /\ update_phase = Idle
    /\ seq[e][d] < MaxSeq
    /\ BagCardinality(msgs) < MaxMsgBuffer   \* backpressure: don't overflow the buffer
    /\ seq'  = [seq EXCEPT ![e][d] = seq[e][d] + 1]
    /\ Send(m)
    /\ UNCHANGED <<backup_seq, keyVars, updateVars, faultVars>>

\* MCDecodeIncrementSeq – atomic: seq++ AND consume message.
\* Base spec's DecodeIncrementSeq leaves the message in the bag (for trace validation); in MC we
\* consume it immediately so TLC cannot fire the action a second time on the same message.
\* All terminal outcomes (session_id_fail, aead_fail, success) are collapsed here: the seq
\* advance is the only state change that matters for the safety invariants being checked.
MCDecodeIncrementSeq(m) ==
    LET e == Receiver(m.dir) IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_DATA
    /\ seq[e][m.dir] < MaxSeq
    \* FIFO guard: only decode this message if there is no older MSG_DATA in the same
    \* direction still in the bag.  SPDM uses TCP (ordered delivery); out-of-order
    \* processing would violate SeqMonotonicity for stale injected messages, which is
    \* a bag-model artifact, not a real implementation scenario.
    /\ ~\E m2 \in DOMAIN msgs : m2.mtype = MSG_DATA /\ m2.dir = m.dir /\ m2.seq < m.seq
    /\ seq'  = [seq EXCEPT ![e][m.dir] = seq[e][m.dir] + 1]
    /\ msgs' = msgs (-) SetToBag({m})
    /\ UNCHANGED <<backup_seq, keyVars, updateVars, faultVars>>

MCResponderReceiveKeyUpdate(m)               == ResponderReceiveKeyUpdate(m)               /\ UNCHANGED faultVars
MCRequesterReceiveKeyUpdateAck(m)            == RequesterReceiveKeyUpdateAck(m)            /\ UNCHANGED faultVars
MCResponderReceiveVerifyNewKey(m)            == ResponderReceiveVerifyNewKey(m)            /\ UNCHANGED faultVars
MCResponderTryDiscardKeyUpdate(m)            == ResponderTryDiscardKeyUpdate(m)            /\ UNCHANGED faultVars
MCRequesterReceiveVerifyAck(m)               == RequesterReceiveVerifyAck(m)               /\ UNCHANGED faultVars
MCEncapSendVerifyNewKey ==
    \* One-at-a-time: only send if no VERIFY_NEW_KEY already in-flight in ResponseDir.
    \* In the implementation, the responder sends exactly one VERIFY_NEW_KEY per encap initiation.
    /\ BagCardinality(msgs) < MaxMsgBuffer
    /\ ~\E m2 \in DOMAIN msgs : m2.mtype = MSG_VERIFY_NEW_KEY /\ m2.dir = ResponseDir
    /\ EncapSendVerifyNewKey
    /\ UNCHANGED faultVars
MCRequesterReceiveEncapVerifyNewKey(m)       == RequesterReceiveEncapVerifyNewKey(m)       /\ UNCHANGED faultVars
MCEncapDecodeFailNoBackup(m)                 == EncapDecodeFailNoBackup(m)                 /\ UNCHANGED faultVars
MCResponderReceiveEncapVerifyAck(m)          == ResponderReceiveEncapVerifyAck(m)          /\ UNCHANGED faultVars
MCRequesterHandleResponseNotReady(m)         == RequesterHandleResponseNotReady(m)         /\ UNCHANGED faultVars

-------------------------------------------------------------------------
\* STRUCTURAL INVARIANT: message buffer size
MCMsgBufferBound == MsgBufferBound(MaxMsgBuffer)

-------------------------------------------------------------------------
\* MCInit and MCNext

MCInit == Init /\ FaultVarsInit

MCNext ==
    \* Normal data exchange
    \/ \E d \in Dirs : MCEncodeAndSend(d)               \* atomic: seq++ + send
    \/ \E m \in DOMAIN msgs : MCDecodeIncrementSeq(m)   \* atomic: seq++ + consume
    \* Key update (non-encap)
    \/ MCUpdateAllKeys                 \* atomic: create_update(RESPONDER) + send UPDATE_ALL_KEYS
    \/ MCSendKeyUpdateRequest          \* UPDATE_KEY only (no prior create_update)
    \/ \E m \in DOMAIN msgs : MCResponderReceiveKeyUpdate(m)
    \/ \E m \in DOMAIN msgs : MCRequesterReceiveKeyUpdateAck(m)
    \/ \E m \in DOMAIN msgs : MCResponderReceiveVerifyNewKey(m)
    \/ \E m \in DOMAIN msgs : MCResponderTryDiscardKeyUpdate(m)
    \/ \E m \in DOMAIN msgs : MCRequesterReceiveVerifyAck(m)
    \* Key update (encap)
    \/ MCEncapCreateAndActivateRspKey
    \/ MCEncapSendVerifyNewKey
    \/ \E m \in DOMAIN msgs : MCRequesterReceiveEncapVerifyNewKey(m)
    \/ \E m \in DOMAIN msgs : MCEncapDecodeFailNoBackup(m)
    \/ \E m \in DOMAIN msgs : MCResponderReceiveEncapVerifyAck(m)
    \* RESPONSE_NOT_READY
    \/ MCSendResponseNotReady
    \/ \E m \in DOMAIN msgs : MCRequesterHandleResponseNotReady(m)
    \* Fault injection (bounded)
    \/ \E d \in Dirs : MCInjectWrongSessionId(d)
    \/ \E d \in Dirs : MCInjectAEADFailure(d)
    \/ MCInjectWrongEpochVerifyNewKey

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

\* View: exclude fault counters so TLC merges states that differ only in counter values.
MCView == <<seq, backup_seq, active_epoch, backup_epoch, backup_valid,
            update_phase, update_all_keys, initiator_committed, is_encap, msgs>>

==========================================================================
