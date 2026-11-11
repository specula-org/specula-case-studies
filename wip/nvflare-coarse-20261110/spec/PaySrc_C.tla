------------------------------ MODULE PaySrc_C ------------------------------
\* Group PaySrc, COARSE variant. Process: CJ(si), one DownloadService
\* transaction per (launch ln, attempt a = round): one result tx Tx(si, ln, a),
\* one ref Ref(si, ln, a), one receiver SJ.
\* Over-approximates PaySrc_F on pPaySrc + PAYLOAD_REPLY (checked by
\* scripts/gen_ref.py PaySrc F C). Private state per tx:
\* live : registered and not retired (fine: reg /\ live; closed => ~live)
\* rcv : final receiver status of the single (ref, receiver) pair
\* cause : retirement cause none/finished/timeout/deleted
\* shut : this CJ's DownloadService.shutdown ran (tombstones/receipts cleared)
\* adm : admitted pull keys whose reply is still pending
\* Coarsened away (port-invisible in the fine): handler/finalizer PCs, progress
\* tracker, callbacks, monitor, drain, settlement claim/completion, receipt/waiters.
\* Anchors: download_service.py:270-335,1315-1425,1457-1507,1525-1605,1681-1855,897-1002.
EXTENDS Ports
VARIABLE paySrc_c

CInit0 == [live |-> FALSE, rcv |-> "none", cause |-> "none", shut |-> FALSE, adm |-> {}]
InitValue == [si \in Sites |-> [ln \in Launches |-> [a \in Attempts |-> CInit0]]]
Init == paySrc_c = InitValue

S(si, ln, a) == paySrc_c[si][ln][a]
Reg(si, ln, a) == pPaySrc[si][ln].tx[a].registered
MyRef(si, ln, a) == Reg(si, ln, a).ref
ServeNonce(si, ln, a) == <<"nonce", si, ln, a>>
TxUpd(si, ln, a, r) == SrcTxSet(pPaySrc, si, ln, a, r)
ReplyMsg(si, mk, status, value, nonce) ==
    Msg("PAYLOAD_REPLY", CJ(si), M(mk).from, M(mk).id,
        [status |-> status, value |-> value, nonce |-> nonce])
Replied(si, mk) == MsgKey("PAYLOAD_REPLY", CJ(si), M(mk).from, M(mk).id) \in DOMAIN net
IsPull(si, ln, a, mk) == /\ InInbox(mk, CJ(si), "PAYLOAD_PULL") /\ Reg(si, ln, a) /= None
                         /\ M(mk).body.ref = MyRef(si, ln, a)
\* Reply statuses for an admitted request with state n - 1 (ChunkCount = 1).
ServeStatuses(n) == {IF n = 1 THEN "DATA" ELSE "EOF"}
                    \cup (IF "payProduce" \in Faults THEN {"PROCESS_EXCEPTION", "ERROR"} ELSE {})
\* A provisional EOF/ERROR serve carries the nonce iff the receiver status was
\* still none when it was served; a status that is final now may be newer.
NonceChoices(si, ln, a, status) ==
    IF status \in {"EOF", "ERROR"}
    THEN (IF S(si, ln, a).rcv = "none" THEN {ServeNonce(si, ln, a)} ELSE {ServeNonce(si, ln, a), None})
    ELSE {None}
\* Late pull after retirement: finished-ref tombstone (not after shutdown) or INVALID_REQUEST.
RetiredStatuses(si, ln, a) ==
    {"INVALID_REQUEST"} \cup
    (IF S(si, ln, a).cause = "finished" /\ ~S(si, ln, a).shut
     THEN {IF S(si, ln, a).rcv = "success" THEN "EOF" ELSE "ERROR"} ELSE {})
RetireCauses(si, ln, a) ==
    (IF S(si, ln, a).rcv /= "none" THEN {"finished"} ELSE {})
    \cup (IF "txTimeout" \in Faults THEN {"timeout"} ELSE {})
    \cup (IF "payDelete" \in Faults THEN {"deleted"} ELSE {})
\* Verdict from a frozen snapshot taken before recording (receiver status is monotone).
Outcomes(si, ln, a) ==
    (IF S(si, ln, a).rcv = "success" THEN {"completed"} ELSE {})
    \cup (IF S(si, ln, a).cause = "deleted" THEN {"aborted"} ELSE {"failed"})
    \cup (IF "payCompute" \in Faults THEN {"failed"} ELSE {})

\* The submission of round a registers transaction (si, ln, a).
\* @L PaySrc.tx.register
Register(si, ln, a) ==
    /\ pTaskCJ[si][ln].submission /= None /\ pTaskCJ[si][ln].submission.assignment.attempt = a
    /\ Reg(si, ln, a) = None /\ CJAlive(si, ln)
    /\ LET sub == pTaskCJ[si][ln].submission IN
       pPaySrc' = TxUpd(si, ln, a, [pPaySrc[si][ln].tx[a] EXCEPT !.registered =
          [ref |-> Ref(si, ln, a), source |-> CJ(si), launch |-> ln, value |-> sub.value]])
    /\ paySrc_c' = [paySrc_c EXCEPT ![si][ln][a].live = TRUE]
    /\ UNCHANGED net

\* Admission of a pull while the tx is live (port-invisible).
\* @L PaySrc.tx.serve
AdmitPull(si, ln, a, mk) ==
    /\ CJAlive(si, ln) /\ S(si, ln, a).live /\ IsPull(si, ln, a, mk)
    /\ mk \notin S(si, ln, a).adm /\ ~Replied(si, mk)
    /\ paySrc_c' = [paySrc_c EXCEPT ![si][ln][a].adm = @ \cup {mk}]
    /\ UNCHANGED <<pPaySrc, net>>

\* An admitted request is answered, possibly after retirement (admitted ops outlive close).
\* @L PaySrc.tx.serve
ServeAdmitted(si, ln, a, mk) ==
    /\ CJAlive(si, ln) /\ mk \in S(si, ln, a).adm
    /\ \E status \in ServeStatuses(M(mk).body.n), nonce \in {ServeNonce(si, ln, a), None} :
       /\ nonce \in NonceChoices(si, ln, a, status)
       /\ net' = Send(net, ReplyMsg(si, mk, status,
                     IF status = "DATA" THEN Reg(si, ln, a).value ELSE None, nonce))
    /\ paySrc_c' = [paySrc_c EXCEPT ![si][ln][a].adm = @ \ {mk}]
    /\ UNCHANGED pPaySrc

\* @L PaySrc.tx.serve
ServeRetired(si, ln, a, mk) ==
    /\ CJAlive(si, ln) /\ ~S(si, ln, a).live /\ IsPull(si, ln, a, mk)
    /\ mk \notin S(si, ln, a).adm /\ ~Replied(si, mk)
    /\ \E status \in RetiredStatuses(si, ln, a) :
          net' = Send(net, ReplyMsg(si, mk, status, None, None))
    /\ UNCHANGED <<pPaySrc, paySrc_c>>

\* A pull for a ref this (current, only live) process never registered (no attempt).
\* @L PaySrc.tx.serve
ServeUnknown(si, ln, mk) ==
    /\ CJAlive(si, ln) /\ ln = CurLaunch(si) /\ \A l2 \in Launches : l2 /= ln => ~CJAlive(si, l2)
    /\ InInbox(mk, CJ(si), "PAYLOAD_PULL")
    /\ \A b \in Attempts : IF Reg(si, ln, b) = None THEN TRUE ELSE M(mk).body.ref /= MyRef(si, ln, b)
    /\ ~Replied(si, mk)
    /\ net' = Send(net, ReplyMsg(si, mk, "INVALID_REQUEST", None, None))
    /\ UNCHANGED <<pPaySrc, paySrc_c>>

\* First final receiver status wins: nonce-bound CONFIRM, or CANCEL (always failed).
\* @L PaySrc.tx.confirm
Commit(si, ln, a, mk) ==
    /\ CJAlive(si, ln) /\ Reg(si, ln, a) /= None /\ S(si, ln, a).rcv = "none"
    /\ mk \in DOMAIN net /\ M(mk).to = CJ(si)
    /\ M(mk).kind \in {"RECEIVER_CONFIRM", "RECEIVER_CANCEL"}
    /\ M(mk).body.ref = MyRef(si, ln, a)
    /\ paySrc_c' = [paySrc_c EXCEPT ![si][ln][a].rcv =
          IF M(mk).kind = "RECEIVER_CONFIRM" /\ M(mk).body.status = "success"
             /\ M(mk).body.nonce = ServeNonce(si, ln, a)
          THEN "success" ELSE "failed"]
    /\ UNCHANGED <<pPaySrc, net>>

\* Single-winner retirement: finished (all final), monitor timeout, delete.
\* @L PaySrc.tx.retire
Retire(si, ln, a) ==
    /\ CJAlive(si, ln) /\ S(si, ln, a).live
    /\ \E cause \in RetireCauses(si, ln, a) :
          paySrc_c' = [paySrc_c EXCEPT ![si][ln][a].live = FALSE, ![si][ln][a].cause = cause]
    /\ UNCHANGED <<pPaySrc, net>>

\* DownloadService.shutdown in the CJ runner's run-finally (client_runner.py:814-821):
\* applied once RunCJ's ShutdownDownloadService step declared it (pRunCJ.dsDown,
\* itself gated by timing TA1, PortsJob!CJTeardownTimingOK).
\* @L PaySrc.tx.shutdown
Shutdown(si, ln, a) ==
    /\ CJAlive(si, ln) /\ Reg(si, ln, a) /= None /\ ~S(si, ln, a).shut
    /\ Flag(pRunCJ[si][ln], "dsDown")
    /\ paySrc_c' = [paySrc_c EXCEPT ![si][ln][a].shut = TRUE, ![si][ln][a].live = FALSE,
          ![si][ln][a].cause = IF S(si, ln, a).live THEN "deleted" ELSE @]
    \* return side (PaySrcShutDone): at once for a transaction that was no longer
    \* live; a live one first runs shutdown()'s synchronous inline settlement
    \* (download_service.py:1502-1505) and returns in ShutdownReturn
    /\ pPaySrc' = IF S(si, ln, a).live THEN pPaySrc
                  ELSE TxUpd(si, ln, a, [pPaySrc[si][ln].tx[a] EXCEPT !.shut = TRUE])
    /\ UNCHANGED net

\* shutdown()'s inline settlement of a live transaction finished (fine:
\* SyncTerminationMarkerWrite of the Inline settler); the call returns for it.
\* @L PaySrc.tx.shutdown
ShutdownReturn(si, ln, a) ==
    /\ CJAlive(si, ln) /\ S(si, ln, a).shut /\ ~pPaySrc[si][ln].tx[a].shut
    /\ \A b \in Attempts : Reg(si, ln, b) /= None => S(si, ln, b).shut
    /\ pPaySrc' = TxUpd(si, ln, a, [pPaySrc[si][ln].tx[a] EXCEPT !.shut = TRUE])
    /\ UNCHANGED <<paySrc_c, net>>

Settling(si, ln, a) == CJAlive(si, ln) /\ ~S(si, ln, a).live /\ S(si, ln, a).cause /= "none"

\* @L PaySrc.tx.settle
ReleaseSource(si, ln, a) ==
    /\ Settling(si, ln, a) /\ ~pPaySrc[si][ln].tx[a].released
    /\ pPaySrc' = TxUpd(si, ln, a, [pPaySrc[si][ln].tx[a] EXCEPT !.released = TRUE])
    /\ UNCHANGED <<paySrc_c, net>>

\* Owner-guarded single receipt; shutdown clears the owner first.
\* @L PaySrc.tx.settle
RecordOutcome(si, ln, a) ==
    /\ Settling(si, ln, a) /\ ~S(si, ln, a).shut /\ pPaySrc[si][ln].tx[a].outcome = "none"
    /\ \E o \in Outcomes(si, ln, a) :
          pPaySrc' = TxUpd(si, ln, a, [pPaySrc[si][ln].tx[a] EXCEPT !.outcome = o])
    /\ UNCHANGED <<paySrc_c, net>>

Next ==
    \/ \E si \in Sites, ln \in Launches, a \in Attempts : Register(si, ln, a)
    \/ \E si \in Sites, ln \in Launches, a \in Attempts, mk \in DOMAIN net : AdmitPull(si, ln, a, mk)
    \/ \E si \in Sites, ln \in Launches, a \in Attempts, mk \in DOMAIN net : ServeAdmitted(si, ln, a, mk)
    \/ \E si \in Sites, ln \in Launches, a \in Attempts, mk \in DOMAIN net : ServeRetired(si, ln, a, mk)
    \/ \E si \in Sites, ln \in Launches, mk \in DOMAIN net : ServeUnknown(si, ln, mk)
    \/ \E si \in Sites, ln \in Launches, a \in Attempts, mk \in DOMAIN net : Commit(si, ln, a, mk)
    \/ \E si \in Sites, ln \in Launches, a \in Attempts : Retire(si, ln, a)
    \/ \E si \in Sites, ln \in Launches, a \in Attempts : Shutdown(si, ln, a)
    \/ \E si \in Sites, ln \in Launches, a \in Attempts : ShutdownReturn(si, ln, a)
    \/ \E si \in Sites, ln \in Launches, a \in Attempts : ReleaseSource(si, ln, a)
    \/ \E si \in Sites, ln \in Launches, a \in Attempts : RecordOutcome(si, ln, a)
=============================================================================
