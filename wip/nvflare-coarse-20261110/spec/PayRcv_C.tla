------------------------------ MODULE PayRcv_C ------------------------------
\* Group PayRcv, COARSE variant. Process: SJ; one receiver attempt per (site si,
\* round a): the round-a result envelope's single ref.
\* Over-approximates PayRcv_F on pPayRcv + PAYLOAD_PULL / RECEIVER_CONFIRM /
\* RECEIVER_CANCEL (checked by scripts/gen_ref.py PayRcv F C). Private state:
\* phase : idle -> pulling -> eof -> confirm -> done | failed
\* data : value of the DATA reply; nonce: serve nonce of the terminal reply
\* result: receiver truth none/success/failed
\* Coarsened away: consumer pipeline PCs, request futures, source-signal registry.
\* Anchors: download_service.py:2000-2041,2083-2105,2139-2144,2164-2366; cell.py:116-135.
EXTENDS Ports
VARIABLE payRcv_c

CInit0 == [phase |-> "idle", data |-> None, nonce |-> None, result |-> "none"]
InitValue == [si \in Sites |-> [a \in Attempts |-> CInit0]]
Init == payRcv_c = InitValue

R(si, a) == payRcv_c[si][a]
Desc(si, a) == pPayRcv[si].rx[a].want
RxUpd(si, a, r) == RcvRxSet(pPayRcv, si, a, r)
PullMsg(si, a, n, k) == Msg("PAYLOAD_PULL", SJ, Desc(si, a).source, <<"pull", Desc(si, a).ref, n, k>>,
                      [ref |-> Desc(si, a).ref, n |-> n, try |-> k])
ConfirmMsg(si, a, nonce, status) == Msg("RECEIVER_CONFIRM", SJ, Desc(si, a).source,
                      <<"confirm", Desc(si, a).ref, Desc(si, a).launch>>,
                      [ref |-> Desc(si, a).ref, nonce |-> nonce, status |-> status])
CancelMsg(si, a) == Msg("RECEIVER_CANCEL", SJ, Desc(si, a).source, <<"cancel", Desc(si, a).ref, Desc(si, a).launch>>,
                      [ref |-> Desc(si, a).ref, status |-> "cancelled"])
PullLossy == "pullTimeout" \in Faults \/ LossyIn(Faults, {"PAYLOAD_PULL", "PAYLOAD_REPLY"})
MaxPullTry == IF PullLossy THEN 2 ELSE 1
IsReply(si, a, mk) == /\ InInbox(mk, SJ, "PAYLOAD_REPLY") /\ M(mk).from = Desc(si, a).source
                   /\ M(mk).id \in {<<"pull", Desc(si, a).ref, n, k>> : n \in 1..2, k \in 1..MaxPullTry}
\* The SJ's DownloadService.shutdown() is one step for this group (fine:
\* SJShutdownPending): between WfSJ declaring it and ShutdownReturn, no receiver
\* step runs.
SJShutdownPending == Flag(pWfSJ, "dsShutdown") /\ ~PayRcvShutDone
Live(si, a) == SJAlive /\ ~SJShutdownPending /\ Desc(si, a) /= None
\* Every fine failure cause of an unfinished download: consumer fault, request
\* timeout, owned-source failure notice, the SJ's own DS shutdown
\* (pWfSJ.dsShutdown), source process gone, or an error reply.
\* Every cause except the SJ's own shutdown is persistent (fault switch, peer
\* death, an error reply in the append-only net), so Return can re-check it.
OtherCause(si, a) ==
    \/ "payConsumer" \in Faults \/ "pullTimeout" \in Faults \/ "sourceFailure" \in Faults
    \/ LossyIn(Faults, {"PAYLOAD_PULL", "PAYLOAD_REPLY"})
    \/ PeerFailureCJ(si, Desc(si, a).launch)
    \/ \E mk \in DOMAIN net : IsReply(si, a, mk) /\ M(mk).body.status \in {"PROCESS_EXCEPTION", "INVALID_REQUEST"}
FailCause(si, a) == OtherCause(si, a) \/ Flag(pWfSJ, "dsShutdown")

\* FOBS decode of the RESULT_ENVELOPE reaches download_object for its ref.
\* @L PayRcv.rx.decode, Timing.TA3
Accept(si, a) ==
    /\ SJAlive /\ ~SJShutdownPending /\ pCommSJ.envelopes[si] /= None /\ pCommSJ.envelopes[si].assignment.attempt = a
    /\ Desc(si, a) = None
    /\ TimingOK(Faults, "slowEnvelope", TA3Holds(Flag(pWfSJ, "dsShutdown")))   \* timing TA3 (Timing)
    /\ pPayRcv' = RxUpd(si, a, [pPayRcv[si].rx[a] EXCEPT
                     !.want = CHOOSE d \in pCommSJ.envelopes[si].refs : TRUE, !.status = "pulling"])
    /\ UNCHANGED <<payRcv_c, net>>

\* @L PayRcv.rx.decode
StartPull(si, a) ==
    /\ Live(si, a) /\ R(si, a).phase = "idle" /\ Fresh(net, PullMsg(si, a, 1, 1))
    /\ net' = Send(net, PullMsg(si, a, 1, 1))
    /\ payRcv_c' = [payRcv_c EXCEPT ![si][a].phase = "pulling"]
    /\ UNCHANGED pPayRcv

\* Pipelined EOF pull, issued after the DATA reply (possibly after a local failure).
\* @L PayRcv.rx.decode
PipelinePull(si, a) ==
    /\ Live(si, a) /\ R(si, a).data /= None /\ Fresh(net, PullMsg(si, a, 2, 1))
    /\ net' = Send(net, PullMsg(si, a, 2, 1))
    /\ UNCHANGED <<payRcv_c, pPayRcv>>

\* TIMEOUT retry of a sent request state under a fresh key.
\* @L PayRcv.rx.decode
RetryPull(si, a) ==
    /\ PullLossy /\ Live(si, a) /\ R(si, a).phase = "pulling"
    /\ \E n \in 1..2, k \in 1..(MaxPullTry - 1) :
          /\ ~Fresh(net, PullMsg(si, a, n, k)) /\ Fresh(net, PullMsg(si, a, n, k + 1))
          /\ net' = Send(net, PullMsg(si, a, n, k + 1))
    /\ UNCHANGED <<payRcv_c, pPayRcv>>

\* @L PayRcv.rx.decode
RecvData(si, a, mk) ==
    /\ Live(si, a) /\ R(si, a).phase = "pulling" /\ R(si, a).data = None
    /\ IsReply(si, a, mk) /\ M(mk).body.status = "DATA"
    /\ payRcv_c' = [payRcv_c EXCEPT ![si][a].data = M(mk).body.value]
    /\ UNCHANGED <<pPayRcv, net>>

\* @L PayRcv.rx.decode
RecvEOF(si, a, mk) ==
    /\ Live(si, a) /\ R(si, a).phase = "pulling"
    /\ IsReply(si, a, mk) /\ M(mk).body.status = "EOF"
    /\ payRcv_c' = [payRcv_c EXCEPT ![si][a].phase = "eof", ![si][a].nonce = M(mk).body.nonce]
    /\ UNCHANGED <<pPayRcv, net>>

\* @L PayRcv.rx.decode
RecvError(si, a, mk) ==
    /\ Live(si, a) /\ R(si, a).phase = "pulling"
    /\ IsReply(si, a, mk) /\ M(mk).body.status = "ERROR"
    /\ payRcv_c' = [payRcv_c EXCEPT ![si][a].phase = "confirm", ![si][a].nonce = M(mk).body.nonce,
                                    ![si][a].result = "failed"]
    /\ UNCHANGED <<pPayRcv, net>>

\* download_completed returned: the receiver holds the data.
\* @L PayRcv.rx.decode
Materialize(si, a) ==
    /\ Live(si, a) /\ R(si, a).phase = "eof"
    /\ payRcv_c' = [payRcv_c EXCEPT ![si][a].phase = "confirm", ![si][a].result = "success"]
    /\ pPayRcv' = RxUpd(si, a, [pPayRcv[si].rx[a] EXCEPT !.status = "materialized",
                                                            !.materialized = R(si, a).data])
    /\ UNCHANGED net

\* @L PayRcv.rx.decode
FailCompletion(si, a) ==
    /\ "payConsumer" \in Faults /\ Live(si, a) /\ R(si, a).phase = "eof"
    /\ payRcv_c' = [payRcv_c EXCEPT ![si][a].phase = "confirm", ![si][a].result = "failed"]
    /\ UNCHANGED <<pPayRcv, net>>

\* @L PayRcv.rx.decode
SendConfirm(si, a) ==
    /\ Live(si, a) /\ R(si, a).phase = "confirm"
    /\ payRcv_c' = [payRcv_c EXCEPT ![si][a].phase = "done"]
    /\ IF R(si, a).nonce /= None
       THEN net' = Send(net, ConfirmMsg(si, a, R(si, a).nonce, R(si, a).result))
       ELSE UNCHANGED net
    /\ UNCHANGED pPayRcv

\* Download fails before the terminal reply; CANCEL only once data was pulled.
\* @L PayRcv.rx.decode
Fail(si, a) ==
    /\ Live(si, a) /\ R(si, a).phase \in {"idle", "pulling"} /\ FailCause(si, a)
    /\ payRcv_c' = [payRcv_c EXCEPT ![si][a].phase = "failed", ![si][a].result = "failed"]
    /\ \/ UNCHANGED net
       \/ R(si, a).phase = "pulling" /\ net' = Send(net, CancelMsg(si, a))
    /\ UNCHANGED pPayRcv

\* download_object returns: a failed decode that is not a local DownloadCancelled
\* (possible only after the SJ's own DS shutdown) kills the SJ. A failure whose
\* only cause is the SJ's own shutdown is that typed cancellation (fine: the
\* source signal "cancelled" -> consumerReturn "cancelled" -> not fatal); a
\* download that started after the shutdown fails on the source's INVALID_REQUEST
\* or another persistent cause (OtherCause), so it can still be fatal.
\* (rarity sim lead without this, coarse mixes reached a fatal
\* SJ after the workflow ended from a pure own-shutdown cancellation.)
\* @L PayRcv.rx.decode
Return(si, a) ==
    /\ Live(si, a) /\ R(si, a).phase \in {"done", "failed"} /\ ~pPayRcv[si].rx[a].returned
    /\ \E fatal \in IF R(si, a).result = "success" THEN {FALSE}
                    ELSE (IF ~Flag(pWfSJ, "dsShutdown") \/ OtherCause(si, a) THEN {TRUE} ELSE {})
                         \cup (IF Flag(pWfSJ, "dsShutdown") THEN {FALSE} ELSE {}) :
          pPayRcv' = RxUpd(si, a, [pPayRcv[si].rx[a] EXCEPT !.returned = TRUE,
                         !.status = IF R(si, a).result = "success" THEN "materialized" ELSE "failed",
                         !.fatal = fatal])
    /\ UNCHANGED <<payRcv_c, net>>

\* server_runner.py:235-237: the SJ's DownloadService.shutdown() returns; its
\* cancellations are the dsShutdown disjunct of FailCause (fine:
\* ShutdownSourceDownloads). WfSJ's exit waits for this (PayRcvShutDone).
\* @L PayRcv.rx.shutdown
ShutdownReturn ==
    /\ SJAlive /\ Flag(pWfSJ, "dsShutdown") /\ ~PayRcvShutDone
    /\ pPayRcv' = RcvAllDown(pPayRcv)
    /\ UNCHANGED <<payRcv_c, net>>

Next ==
    \/ ShutdownReturn
    \/ \E si \in Sites, a \in Attempts : Accept(si, a)
    \/ \E si \in Sites, a \in Attempts : StartPull(si, a)
    \/ \E si \in Sites, a \in Attempts : PipelinePull(si, a)
    \/ \E si \in Sites, a \in Attempts : RetryPull(si, a)
    \/ \E si \in Sites, a \in Attempts, mk \in DOMAIN net : RecvData(si, a, mk)
    \/ \E si \in Sites, a \in Attempts, mk \in DOMAIN net : RecvEOF(si, a, mk)
    \/ \E si \in Sites, a \in Attempts, mk \in DOMAIN net : RecvError(si, a, mk)
    \/ \E si \in Sites, a \in Attempts : Materialize(si, a)
    \/ \E si \in Sites, a \in Attempts : FailCompletion(si, a)
    \/ \E si \in Sites, a \in Attempts : SendConfirm(si, a)
    \/ \E si \in Sites, a \in Attempts : Fail(si, a)
    \/ \E si \in Sites, a \in Attempts : Return(si, a)
=============================================================================
