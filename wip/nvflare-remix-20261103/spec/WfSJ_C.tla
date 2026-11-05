------------------------------ MODULE WfSJ_C ------------------------------
\* Group WfSJ, COARSE variant. Process: SJ.
\* Mechanisms: workflow admission, FedAvg round loop, SCHEDULE / CANCEL_ALL
\* requests to CommSJ, the result callback (APP_CALL -> count / accept /
\* panic / APP_RETURN), round close, aggregate, save, control_flow return,
\* run end (status done, END_RUN fan-out, local DownloadService shutdown),
\* SJ exit / crash.
\* Over-approximates WfSJ_F on pWfSJ + END_RUN: the callback body collapses to
\* Count / Accept / Panic / Return (rejection is port-invisible); the round loop
\* to StartRound / Schedule / CloseRound / RaiseReturn / Aggregate / Save / Advance.
\* Writes: wfSJ_c, pWfSJ, net (END_RUN).
\* Anchors: server_runner.py:131-237; fedavg.py:194-410; base_model_controller.py:153-401;
\*          base_fedavg.py:302-322.
EXTENDS Ports
VARIABLE wfSJ_c

\* round: controller round; counted: <<site, value>> contributions counted in the
\* current round; saved: last saved round; closed: close outcome of the round.
Init == wfSJ_c = [round |-> 0, counted |-> {}, saved |-> 0, closed |-> "none"]
InitValue == [round |-> 0, counted |-> {}, saved |-> 0, closed |-> "none"]

W == wfSJ_c
Aborted == pCommSJ.panic \/ pWfSJ.panic
Call == pCommSJ.call
CountedSites == {p[1] : p \in W.counted}
Running == SJAlive /\ pWfSJ.returned = "none"

Open ==
    /\ pJobSP.sjLaunched /\ pWfSJ.sj = "none" /\ SJAlive
    /\ pWfSJ' = [pWfSJ EXCEPT !.sj = "running", !.open = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>

StartRound ==
    /\ Running /\ pWfSJ.open /\ W.round < Rounds /\ (W.round = 0 \/ W.saved = W.round)
    /\ wfSJ_c' = [wfSJ_c EXCEPT !.round = @ + 1, !.counted = {}, !.closed = "none"]
    /\ UNCHANGED <<pWfSJ, net>>

Schedule ==
    /\ Running /\ W.round >= 1 /\ pWfSJ.scheduled < W.round
    \* per-round port fields are reset with `scheduled`
    /\ pWfSJ' = [pWfSJ EXCEPT !.scheduled = W.round, !.accepted = {}, !.aggregate = None]
    /\ UNCHANGED <<wfSJ_c, net>>

Count(c) ==
    /\ SJAlive /\ Call /= None /\ Call.site = c /\ Call.round = W.round
    /\ Call.kind = "live" /\ Call.rc = "OK" /\ c \notin CountedSites
    /\ wfSJ_c' = [wfSJ_c EXCEPT !.counted = @ \cup {<<c, Call.value>>}]
    /\ UNCHANGED <<pWfSJ, net>>

\* Acceptance is published together with the APP_RETURN.
Accept(c) ==
    /\ SJAlive /\ Call /= None /\ Call.site = c /\ Call.kind = "live"
    /\ c \in CountedSites /\ pWfSJ.ret /= [site |-> c, round |-> Call.round]
    /\ pWfSJ' = [pWfSJ EXCEPT !.accepted = @ \cup {c}, !.ret = [site |-> c, round |-> Call.round]]
    /\ UNCHANGED <<wfSJ_c, net>>

\* Strict error mode: a non-OK return code panics the runner.
Panic ==
    /\ SJAlive /\ Call /= None /\ Call.kind = "live" /\ Call.rc /= "OK" /\ ~pWfSJ.panic
    /\ pWfSJ' = [pWfSJ EXCEPT !.panic = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>

\* APP_RETURN after the unknown hook or a rejection (bad rc, callback failure,
\* or a closed / failed round at the guard).
Return(c) ==
    /\ SJAlive /\ Call /= None /\ Call.site = c
    /\ pWfSJ.ret /= [site |-> c, round |-> Call.round]
    /\ \/ Call.kind = "unknown"
       \/ /\ c \notin CountedSites
          /\ Call.rc /= "OK" \/ "cbFail" \in Faults \/ W.closed /= "none"
    /\ pWfSJ' = [pWfSJ EXCEPT !.ret = [site |-> c, round |-> Call.round]]
    /\ UNCHANGED <<wfSJ_c, net>>

CancelAll ==
    /\ Running /\ "cbFail" \in Faults /\ W.round >= 1 /\ pWfSJ.cancelAll < W.round
    /\ W.closed = "none"
    /\ pWfSJ' = [pWfSJ EXCEPT !.cancelAll = W.round]
    /\ UNCHANGED <<wfSJ_c, net>>

CloseRound ==
    /\ Running /\ W.round >= 1 /\ pWfSJ.scheduled = W.round /\ pCommSJ.round = W.round
    /\ W.closed = "none"
    /\ \/ /\ ~pCommSJ.standing
          /\ wfSJ_c' = [wfSJ_c EXCEPT !.closed = "ok"]
          /\ UNCHANGED pWfSJ
       \/ /\ "cbFail" \in Faults /\ (~pCommSJ.standing \/ pCommSJ.cancelled = W.round)
          /\ wfSJ_c' = [wfSJ_c EXCEPT !.closed = "failed"]
          /\ UNCHANGED pWfSJ
       \/ /\ Aborted
          /\ wfSJ_c' = [wfSJ_c EXCEPT !.closed = "aborted"]
          /\ pWfSJ' = [pWfSJ EXCEPT !.returned = "aborted"]
    /\ UNCHANGED net

RaiseReturn ==
    /\ Running
    /\ \/ W.closed = "failed"
       \/ W.closed = "ok" /\ W.counted = {}
    /\ pWfSJ' = [pWfSJ EXCEPT !.returned = "error", !.panic = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>

Aggregate ==
    /\ Running /\ W.closed = "ok" /\ W.counted /= {} /\ pWfSJ.aggregate = None
    /\ pWfSJ' = [pWfSJ EXCEPT !.aggregate = {p[2] : p \in W.counted}]
    /\ UNCHANGED <<wfSJ_c, net>>

Save ==
    /\ Running /\ pWfSJ.aggregate /= None /\ W.saved < W.round
    /\ wfSJ_c' = [wfSJ_c EXCEPT !.saved = W.round]
    /\ pWfSJ' = [pWfSJ EXCEPT !.saved = TRUE,
                              !.returned = IF W.round = Rounds THEN "normal" ELSE @]
    /\ UNCHANGED net

\* status done + END_RUN broadcast to all clients (one aux call).
EndRun ==
    /\ SJAlive /\ pWfSJ.returned /= "none" /\ pCommSJ.finalized /\ ~pWfSJ.done
    /\ pWfSJ' = [pWfSJ EXCEPT !.done = TRUE]
    /\ net' = SendAll(net, {Msg("END_RUN", SJ, CJ(c), <<JobId, c>>, None) : c \in Sites})
    /\ UNCHANGED wfSJ_c

DSShutdown ==
    /\ SJAlive /\ pWfSJ.done /\ ~pWfSJ.dsShutdown
    /\ pWfSJ' = [pWfSJ EXCEPT !.dsShutdown = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>

Exit ==
    /\ SJAlive /\ pWfSJ.dsShutdown /\ pWfSJ.sj = "running"
    /\ PayRcvShutDone    \* DownloadService.shutdown() returned (call-return handshake)
    /\ pWfSJ' = [pWfSJ EXCEPT !.sj = "exited"]
    /\ UNCHANGED <<wfSJ_c, net>>

Crash ==
    /\ "sjCrash" \in Faults /\ SJAlive /\ pWfSJ.sj = "running"
    /\ pWfSJ' = [pWfSJ EXCEPT !.sj = "crashed"]
    /\ UNCHANGED <<wfSJ_c, net>>

Next == \/ Open \/ StartRound \/ Schedule \/ Panic \/ CancelAll \/ CloseRound
        \/ RaiseReturn \/ Aggregate \/ Save \/ EndRun \/ DSShutdown \/ Exit \/ Crash
        \/ \E c \in Sites : Count(c) \/ Accept(c) \/ Return(c)
=============================================================================
