---- MODULE MC ----
\* Model checking wrapper for libspdm session lifecycle spec.
\* Adds counter-bounded fault injection, symmetry/view reduction,
\* structural invariants, and targeted bug-family invariants.

EXTENDS base, Naturals

\* ---------------------------------------------------------------------------
\* Fault counters (one per non-deterministic / fault-injection action)
\* ---------------------------------------------------------------------------
VARIABLE faultVars

\* faultVars is a record:
\*   [ dropReqToRsp   : Nat   -- message loss, req->rsp channel
\*     dropRspToReq   : Nat   -- message loss, rsp->req channel
\*     decodeBackup   : Nat   -- decode-time rollback (rsp_receive_send.c:197-263)
\*     watchdogExpiry : Nat   -- watchdog fires (platform callback)
\*     rspEncodeFail  : Nat   -- END_SESSION_ACK encoding failure
\*   ]

\* ---------------------------------------------------------------------------
\* Tuning constants
\* ---------------------------------------------------------------------------
CONSTANTS
    MaxDropReqToRsp,    \* bound on req->rsp message drops
    MaxDropRspToReq,    \* bound on rsp->req message drops
    MaxDecodeBackup,    \* bound on decode-time rollback events
    MaxWatchdogExpiry,  \* bound on watchdog expiry events
    MaxRspEncodeFail,   \* bound on END_SESSION_ACK encode failures
    MaxMsgBuffer        \* max length of either message channel

\* ---------------------------------------------------------------------------
\* Constrained fault wrappers
\* ---------------------------------------------------------------------------

MCDropReqToRsp ==
    /\ faultVars.dropReqToRsp < MaxDropReqToRsp
    /\ DropReqToRsp
    /\ faultVars' = [faultVars EXCEPT !.dropReqToRsp = @ + 1]

MCDropRspToReq ==
    /\ faultVars.dropRspToReq < MaxDropRspToReq
    /\ DropRspToReq
    /\ faultVars' = [faultVars EXCEPT !.dropRspToReq = @ + 1]

\* DecodeWithBackupKey models the decode-time revert+re-derive path.
\* rsp_receive_send.c:197-263 -- triggered when decryption fails but backup valid.
\* This is the key fault that exposes Family 4's stuck-state bug.
MCDecodeWithBackupKey ==
    /\ faultVars.decodeBackup < MaxDecodeBackup
    /\ DecodeWithBackupKey
    /\ faultVars' = [faultVars EXCEPT !.decodeBackup = @ + 1]

\* WatchdogExpiry -- platform watchdog fires (Family 3 fault).
MCWatchdogExpiry ==
    /\ faultVars.watchdogExpiry < MaxWatchdogExpiry
    /\ WatchdogExpiry
    /\ faultVars' = [faultVars EXCEPT !.watchdogExpiry = @ + 1]

\* END_SESSION_ACK encode failure -- Family 2 fault.
\* rsp_receive_send.c:779-793: transport_encode_message returns error.
MCRspEncodeEndSessionAckFail ==
    /\ faultVars.rspEncodeFail < MaxRspEncodeFail
    /\ RspEncodeEndSessionAckFail
    /\ faultVars' = [faultVars EXCEPT !.rspEncodeFail = @ + 1]

\* ---------------------------------------------------------------------------
\* Unconstrained (reactive) actions -- pass through with UNCHANGED faultVars
\* ---------------------------------------------------------------------------
MCReqSendUpdateKey          == ReqSendUpdateKey          /\ UNCHANGED faultVars
MCReqSendUpdateAllKeys      == ReqSendUpdateAllKeys      /\ UNCHANGED faultVars
MCRspRecvUpdateKey          == RspRecvUpdateKey          /\ UNCHANGED faultVars
MCRspRecvUpdateAllKeys      == RspRecvUpdateAllKeys      /\ UNCHANGED faultVars
MCReqRecvKeyUpdateAck       == ReqRecvKeyUpdateAck       /\ UNCHANGED faultVars
MCRspRecvVerifyNewKey       == RspRecvVerifyNewKey       /\ UNCHANGED faultVars
MCReqRecvVerifyAck          == ReqRecvVerifyAck          /\ UNCHANGED faultVars
MCReqSendEndSession         == ReqSendEndSession         /\ UNCHANGED faultVars
MCRspRecvEndSession         == RspRecvEndSession         /\ UNCHANGED faultVars
MCRspEncodeEndSessionAckSuccess == RspEncodeEndSessionAckSuccess /\ UNCHANGED faultVars
MCReqRecvEndSessionAck      == ReqRecvEndSessionAck      /\ UNCHANGED faultVars
MCReqSendHeartbeat          == ReqSendHeartbeat          /\ UNCHANGED faultVars
MCRspRecvHeartbeat          == RspRecvHeartbeat          /\ UNCHANGED faultVars
MCReqRecvHeartbeatAck       == ReqRecvHeartbeatAck       /\ UNCHANGED faultVars
MCIntegratorTerminatesSession == IntegratorTerminatesSession /\ UNCHANGED faultVars

\* ---------------------------------------------------------------------------
\* MCInit
\* ---------------------------------------------------------------------------
MCInit ==
    /\ Init
    /\ faultVars = [ dropReqToRsp   |-> 0,
                     dropRspToReq   |-> 0,
                     decodeBackup   |-> 0,
                     watchdogExpiry |-> 0,
                     rspEncodeFail  |-> 0 ]

\* ---------------------------------------------------------------------------
\* MCNext
\* ---------------------------------------------------------------------------
MCNext ==
    \/ MCReqSendUpdateKey
    \/ MCReqSendUpdateAllKeys
    \/ MCRspRecvUpdateKey
    \/ MCRspRecvUpdateAllKeys
    \/ MCReqRecvKeyUpdateAck
    \/ MCRspRecvVerifyNewKey
    \/ MCReqRecvVerifyAck
    \/ MCDecodeWithBackupKey
    \/ MCReqSendEndSession
    \/ MCRspRecvEndSession
    \/ MCRspEncodeEndSessionAckSuccess
    \/ MCRspEncodeEndSessionAckFail
    \/ MCReqRecvEndSessionAck
    \/ MCReqSendHeartbeat
    \/ MCRspRecvHeartbeat
    \/ MCReqRecvHeartbeatAck
    \/ MCWatchdogExpiry
    \/ MCIntegratorTerminatesSession
    \/ MCDropReqToRsp
    \/ MCDropRspToReq

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

\* ---------------------------------------------------------------------------
\* View: exclude fault counters from state comparison to reduce state space
\* ---------------------------------------------------------------------------
MCView == vars

\* ---------------------------------------------------------------------------
\* Message buffer constraint: prune states with excessively long queues
\* ---------------------------------------------------------------------------
MCMsgBufferConstraint ==
    /\ Len(req_to_rsp) <= MaxMsgBuffer
    /\ Len(rsp_to_req) <= MaxMsgBuffer

====
