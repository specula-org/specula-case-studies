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
\* base_fedavg.py:302-322.
\* v11 (DESIGN 16.5-16.6, coarse-only): the workflow policy (Consts.WfPolicy) may be
\* ScatterAndGather (sag: scatter_and_gather.py:240-460), Cyclic (cyclic: relay,
\* cyclic_ctl.py control_flow/_process_result) or server-controlled cross-site
\* evaluation (cseServer: cross_site_model_eval.py control_flow); with sjModel the
\* accept / aggregate / save calls go to the group Model (pWfSJ.mcall, pModel.ret).
\* With no v11 switch every new branch is disabled and the module is v10's.
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
Pol == WfPolicy
\* FedAvg and SAG hand OK results to the aggregator; with sjModel through Model
ModelAccepts == SJModel /\ Pol \in {"fedavg", "sag"}
Raised(r) == RaiseTracked /\ r \in pWfSJ.raised
\* a round is finished once it saved its model (cseServer: once it closed)
RoundDone == IF Pol \in {"cseServer", "swarm"} THEN W.closed /= "none" ELSE W.saved = W.round
Max2(a, b) == IF a > b THEN a ELSE b
Ret(c) == [site |-> c, round |-> Call.round]
ModelRet == IF pWfSJ.mcall = None \/ pModel.ret = None THEN FALSE
            ELSE pModel.ret.n = pWfSJ.mcall.n
NewCall(op, r, c) == [n |-> pWfSJ.mseq + 1, op |-> op, round |-> r, site |-> c]

\* @L WfSJ.proc.SJ
Open ==
    /\ pJobSP.sjLaunched /\ pWfSJ.sj = "none" /\ SJAlive
    /\ pWfSJ' = [pWfSJ EXCEPT !.sj = "running", !.open = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>

\* Cyclic relays only among active sites (no disconnect report, approximated by
\* a dead-job notification); fewer than two is a system_panic (_get_relay_orders).
CycActive == {c \in Sites : \A g \in 1..MaxTok : <<c, g>> \notin pReg.notified}
\* @L WfSJ.fedavg.round
StartRound ==
    /\ Running /\ pWfSJ.open /\ W.round < Rounds /\ (W.round = 0 \/ RoundDone)
    /\ Pol = "cyclic" => ~pWfSJ.wfDone /\ Cardinality(CycActive) >= 2
    \* swarm: config (round 1) must reach every site before the start task (round 2)
    /\ Pol = "swarm" /\ W.round = 1 => CountedSites = Sites
    /\ wfSJ_c' = [wfSJ_c EXCEPT !.round = @ + 1, !.counted = {}, !.closed = "none"]
    /\ UNCHANGED <<pWfSJ, net>>

\* v11 targets: swarm sends config to every site and start to the starting
\* client; sampling draws a nonempty subset (sample_clients)
TargetSets == IF Pol = "swarm" THEN {IF W.round = 1 THEN Sites ELSE {Starter}}
              ELSE IF "sampling" \in Profile THEN SUBSET Sites \ {{}} ELSE {Sites}
\* @L WfSJ.fedavg.round
Schedule ==
    /\ Running /\ W.round >= 1 /\ pWfSJ.scheduled < W.round
    \* per-round port fields are reset with `scheduled`
    /\ \E ts \in TargetSets :
         LET w == [pWfSJ EXCEPT !.scheduled = W.round, !.accepted = {}, !.aggregate = None]
         IN pWfSJ' = IF Targeted THEN [w EXCEPT !.targets = ts] ELSE w
    /\ UNCHANGED <<wfSJ_c, net>>

\* @L WfSJ.fedavg.callback
Count(c) ==
    /\ ~ModelAccepts
    /\ SJAlive /\ Call /= None /\ Call.site = c /\ Call.round = W.round
    /\ Call.kind = "live" /\ Call.rc = "OK" /\ c \notin CountedSites
    /\ wfSJ_c' = [wfSJ_c EXCEPT !.counted = @ \cup {<<c, Call.value>>}]
    /\ UNCHANGED <<pWfSJ, net>>

\* Acceptance is published together with the APP_RETURN.
\* @L WfSJ.fedavg.callback
Accept(c) ==
    /\ SJAlive /\ Call /= None /\ Call.site = c /\ Call.kind = "live"
    /\ c \in CountedSites /\ pWfSJ.ret /= [site |-> c, round |-> Call.round]
    /\ pWfSJ' = [pWfSJ EXCEPT !.accepted = @ \cup {c}, !.ret = [site |-> c, round |-> Call.round]]
    /\ UNCHANGED <<wfSJ_c, net>>

\* Strict error mode: a non-OK return code panics the runner (FedAvg; SAG's
\* ignore_result_error policy may panic or ignore: Panic or Return).
\* @L WfSJ.fedavg.callback
Panic ==
    /\ Pol \in {"fedavg", "sag"}
    /\ SJAlive /\ Call /= None /\ Call.kind = "live" /\ Call.rc /= "OK" /\ ~pWfSJ.panic
    /\ pWfSJ' = IF TaskMode THEN [pWfSJ EXCEPT !.panic = TRUE, !.errored = @ \cup {<<Call.round, Call.site>>}]
                ELSE [pWfSJ EXCEPT !.panic = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>

\* taskMode: a live non-OK result reached the callback (pWfSJ.errored).
\* @L WfSJ.fedavg.callback
RecordError ==
    /\ TaskMode /\ SJAlive /\ Call /= None /\ Call.kind = "live" /\ Call.rc /= "OK"
    /\ <<Call.round, Call.site>> \notin pWfSJ.errored
    /\ pWfSJ' = [pWfSJ EXCEPT !.errored = @ \cup {<<Call.round, Call.site>>}]
    /\ UNCHANGED <<wfSJ_c, net>>

\* APP_RETURN after the unknown hook or a rejection (bad rc, callback failure,
\* or a closed / failed round at the guard).
\* @L WfSJ.fedavg.callback
Return(c) ==
    /\ SJAlive /\ Call /= None /\ Call.site = c
    /\ pWfSJ.ret /= [site |-> c, round |-> Call.round]
    /\ \/ Call.kind = "unknown"
       \/ /\ c \notin CountedSites
          /\ Call.rc /= "OK" \/ "cbFail" \in Faults \/ W.closed /= "none"
    /\ pWfSJ' = [pWfSJ EXCEPT !.ret = [site |-> c, round |-> Call.round]]
    /\ UNCHANGED <<wfSJ_c, net>>

\* FedAvg's round guard: a raising callback fails the round and cancels its tasks
\* (fedavg.py:221-260); SAG, Cyclic and cross-site evaluation have no such guard.
\* @L WfSJ.fedavg.callback
CancelAll ==
    /\ Running /\ Pol = "fedavg" /\ W.round >= 1 /\ pWfSJ.cancelAll < W.round
    /\ "cbFail" \in Faults \/ Raised(W.round)
    /\ W.closed = "none"
    /\ pWfSJ' = [pWfSJ EXCEPT !.cancelAll = W.round]
    /\ UNCHANGED <<wfSJ_c, net>>

\* @L WfSJ.fedavg.round
CloseRound ==
    /\ Running /\ W.round >= 1 /\ pWfSJ.scheduled = W.round /\ pCommSJ.round = W.round
    /\ W.closed = "none"
    /\ \/ /\ ~pCommSJ.standing
          /\ wfSJ_c' = [wfSJ_c EXCEPT !.closed = "ok"]
          /\ UNCHANGED pWfSJ
       \/ /\ Pol = "fedavg" /\ ("cbFail" \in Faults \/ Raised(W.round))
          /\ (~pCommSJ.standing \/ pCommSJ.cancelled = W.round)
          /\ wfSJ_c' = [wfSJ_c EXCEPT !.closed = "failed"]
          /\ UNCHANGED pWfSJ
       \/ /\ Aborted
          /\ wfSJ_c' = [wfSJ_c EXCEPT !.closed = "aborted"]
          \* Cyclic persists the relayed model before its next abort check
          /\ IF Pol = "cyclic" THEN UNCHANGED pWfSJ ELSE pWfSJ' = [pWfSJ EXCEPT !.returned = "aborted"]
    /\ UNCHANGED net

\* @L WfSJ.fedavg.callback
RaiseReturn ==
    /\ Running /\ Pol = "fedavg"
    /\ \/ W.closed = "failed"
       \/ W.closed = "ok" /\ W.counted = {}
    /\ pWfSJ' = [pWfSJ EXCEPT !.returned = "error", !.panic = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>

\* @L WfSJ.fedavg.round
Aggregate ==
    /\ ~ModelAccepts /\ Pol \in {"fedavg", "sag"}
    /\ Running /\ W.closed = "ok" /\ (W.counted /= {} \/ Pol = "sag") /\ pWfSJ.aggregate = None
    /\ pWfSJ' = [pWfSJ EXCEPT !.aggregate = {p[2] : p \in W.counted}]
    /\ UNCHANGED <<wfSJ_c, net>>

SaveReady == \/ Pol \in {"fedavg", "sag"} /\ pWfSJ.aggregate /= None
             \/ Pol = "cyclic" /\ W.closed \in {"ok", "aborted"}
\* control_flow return after the save: last round, or Cyclic's stop / abort check
ReturnAfterSave == IF Pol = "cyclic"
                   THEN IF W.closed = "aborted" THEN "aborted"
                        ELSE IF pWfSJ.wfDone \/ W.round = Rounds THEN "normal" ELSE "none"
                   ELSE IF W.round = Rounds THEN "normal" ELSE "none"
\* @L WfSJ.fedavg.round
Save ==
    /\ ~SJModel
    /\ Running /\ SaveReady /\ W.saved < W.round
    /\ wfSJ_c' = [wfSJ_c EXCEPT !.saved = W.round]
    /\ pWfSJ' = [pWfSJ EXCEPT !.saved = TRUE, !.returned = ReturnAfterSave]
    /\ UNCHANGED net

\* ---------------------------------------------------------------- v11
\* sjModel: accept through Model (FedAvg aggregate_one_result / SAG
\* _accept_train_result; SAG also hands an unknown-task result of the current
\* round to the aggregator, process_result_of_unknown_task).
\* @L WfSJ.sag.flow
CallAccept(c) ==
    /\ ModelAccepts /\ SJAlive /\ Call /= None /\ Call.site = c /\ Call.round = W.round
    /\ Call.rc = "OK" /\ c \notin CountedSites /\ pWfSJ.mcall = None /\ pWfSJ.ret /= Ret(c)
    /\ Call.kind = "live" \/ (Pol = "sag" /\ Call.kind = "unknown")
    /\ pWfSJ' = [pWfSJ EXCEPT !.mcall = NewCall("accept", W.round, c), !.mseq = @ + 1]
    /\ UNCHANGED <<wfSJ_c, net>>

\* The accept outcome ends the callback: accepted (counted, APP_RETURN), rejected
\* (APP_RETURN), or raised after a partial mutation (APP_RETURN; WFComm marks the
\* task ERROR, wf_comm_server.py:657-672).
\* @L WfSJ.sag.flow
AcceptRet(c) ==
    /\ ModelAccepts /\ SJAlive /\ ModelRet /\ pWfSJ.mcall.op = "accept" /\ pWfSJ.mcall.site = c
    /\ Call /= None /\ Call.site = c
    /\ LET o == pModel.ret.out
           w0 == [pWfSJ EXCEPT !.mcall = None, !.ret = Ret(c)]
       IN CASE o = "accepted" -> /\ wfSJ_c' = [wfSJ_c EXCEPT !.counted = @ \cup {<<c, Call.value>>}]
                                 \* cause record: accepted after the round's aggregate was computed
                                 /\ pWfSJ' = [w0 EXCEPT !.accepted = @ \cup {c},
                                       !.lateAccept = IF pWfSJ.aggregate /= None THEN "WfSJ.sag.flow" ELSE @]
            [] o = "rejected" -> /\ pWfSJ' = w0 /\ UNCHANGED wfSJ_c
            [] OTHER -> /\ pWfSJ' = [w0 EXCEPT !.raised = @ \cup {pWfSJ.mcall.round}]
                        /\ UNCHANGED wfSJ_c
    /\ UNCHANGED net

\* SAG / cross-site evaluation: a callback failure (cbFail) raises into WFComm,
\* which marks the task ERROR; nothing checks it.
\* @L WfSJ.sag.flow
RaiseCb(c) ==
    /\ "cbFail" \in Faults /\ Pol \in {"sag", "cseServer"}
    /\ SJAlive /\ Call /= None /\ Call.site = c /\ Call.kind = "live"
    /\ c \notin CountedSites /\ pWfSJ.ret /= Ret(c)
    /\ pWfSJ' = [pWfSJ EXCEPT !.ret = Ret(c), !.raised = @ \cup {Call.round}]
    /\ UNCHANGED <<wfSJ_c, net>>

\* Cyclic: a non-OK result or a conversion failure calls _stop_workflow (cancel
\* the relay task, _is_done); the callback returns normally.
\* @L WfSJ.cyclic.flow
StopWorkflow(c) ==
    /\ Pol = "cyclic" /\ SJAlive /\ Call /= None /\ Call.site = c /\ Call.kind = "live"
    /\ Call.rc /= "OK" \/ "cbFail" \in Faults
    /\ c \notin CountedSites /\ pWfSJ.ret /= Ret(c)
    /\ pWfSJ' = [pWfSJ EXCEPT !.ret = Ret(c), !.wfDone = TRUE, !.cancelAll = Max2(@, Call.round)]
    /\ UNCHANGED <<wfSJ_c, net>>

\* @L WfSJ.sag.flow
CallAggregate ==
    /\ ModelAccepts /\ Running /\ W.closed = "ok" /\ (W.counted /= {} \/ Pol = "sag")
    /\ pWfSJ.aggregate = None /\ pWfSJ.mcall = None
    /\ pWfSJ' = [pWfSJ EXCEPT !.mcall = NewCall("aggregate", W.round, None), !.mseq = @ + 1]
    /\ UNCHANGED <<wfSJ_c, net>>

\* aggregate raising is a control_flow exception: system_panic
\* @L WfSJ.sag.flow
AggregateRet ==
    /\ ModelAccepts /\ SJAlive /\ ModelRet /\ pWfSJ.mcall.op = "aggregate"
    /\ pWfSJ' = IF pModel.ret.out = "raise"
                THEN [pWfSJ EXCEPT !.mcall = None, !.returned = "error", !.panic = TRUE]
                ELSE [pWfSJ EXCEPT !.mcall = None, !.aggregate = {p[2] : p \in W.counted}]
    /\ UNCHANGED <<wfSJ_c, net>>

\* @L WfSJ.sag.flow
CallSave ==
    /\ SJModel /\ Running /\ SaveReady /\ W.saved < W.round /\ pWfSJ.mcall = None
    /\ pWfSJ' = [pWfSJ EXCEPT !.mcall = NewCall("save", W.round, None), !.mseq = @ + 1]
    /\ UNCHANGED <<wfSJ_c, net>>

\* a failed save raises out of control_flow: system_panic
\* @L WfSJ.sag.flow
SaveRet ==
    /\ SJModel /\ SJAlive /\ ModelRet /\ pWfSJ.mcall.op = "save"
    /\ IF pModel.ret.out = "ok"
       THEN /\ wfSJ_c' = [wfSJ_c EXCEPT !.saved = W.round]
            /\ pWfSJ' = [pWfSJ EXCEPT !.mcall = None, !.saved = TRUE, !.returned = ReturnAfterSave]
       ELSE /\ pWfSJ' = [pWfSJ EXCEPT !.mcall = None, !.returned = "error", !.panic = TRUE]
            /\ UNCHANGED wfSJ_c
    /\ UNCHANGED net

\* cross-site evaluation: the last validation group closed; results saved (json)
\* @L WfSJ.cyclic.flow
RelayPanic ==
    /\ Pol = "cyclic" /\ Running /\ pWfSJ.open /\ W.round < Rounds /\ (W.round = 0 \/ RoundDone)
    /\ ~pWfSJ.wfDone /\ Cardinality(CycActive) < 2
    /\ pWfSJ' = [pWfSJ EXCEPT !.returned = "error", !.panic = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>

\* ---------------------------------------------------------------- v11 swarm
\* CCWF ServerSideController (ccwf/server_ctl.py:231-540): config broadcast, start
\* task, status monitor, end-workflow aux request.
SwarmStatus(k) == InInbox(k, SJ, "SWARM_STATUS")
\* @L WfSJ.swarm.server
SwarmCfgPanic ==
    /\ Pol = "swarm" /\ Running /\ W.round = 1 /\ W.closed = "ok" /\ CountedSites /= Sites
    /\ pWfSJ' = [pWfSJ EXCEPT !.returned = "error", !.panic = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>
\* @L WfSJ.swarm.server
SwarmStartOk ==
    /\ Pol = "swarm" /\ Running /\ W.round = 2 /\ W.closed = "ok" /\ Starter \in CountedSites
    /\ pWfSJ.cw = "init"
    /\ pWfSJ' = [pWfSJ EXCEPT !.cw = "monitor"]
    /\ UNCHANGED <<wfSJ_c, net>>
\* @L WfSJ.swarm.server
SwarmStartPanic ==
    /\ Pol = "swarm" /\ Running /\ W.round = 2 /\ W.closed = "ok" /\ Starter \notin CountedSites
    /\ pWfSJ' = [pWfSJ EXCEPT !.returned = "error", !.panic = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>
\* a failure report from any client: asked_to_stop + system_panic
\* @L WfSJ.swarm.server
SwarmErrPanic ==
    /\ Pol = "swarm" /\ Running /\ pWfSJ.cw \in {"monitor", "init"}
    /\ \E k \in DOMAIN net : SwarmStatus(k) /\ M(k).body.error
    /\ pWfSJ' = [pWfSJ EXCEPT !.returned = "error", !.panic = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>
\* no progress / a silent client (progress_timeout, max_status_report_interval):
\* only with a stall cause (a dead or unreachable client, lost aux messages, a
\* client that stopped itself)
\* @L WfSJ.swarm.server
SwarmProgressPanic ==
    /\ Pol = "swarm" /\ Running /\ pWfSJ.cw = "monitor"
    /\ \/ \E c \in Sites : PeerFailureCJ(c, CurLaunch(c))
       \/ {"swarmMsgFail", "busyReplace"} \cap Faults /= {} \/ LossyIn(Faults, SwarmKinds)
    /\ pWfSJ' = [pWfSJ EXCEPT !.returned = "error", !.panic = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>
\* ALL_DONE from a client: ask every client to end the workflow
\* @L WfSJ.swarm.server
SwarmAllDone ==
    /\ Pol = "swarm" /\ Running /\ pWfSJ.cw = "monitor"
    /\ \E k \in DOMAIN net : SwarmStatus(k) /\ M(k).body.allDone
    /\ pWfSJ' = [pWfSJ EXCEPT !.cw = "ending"]
    /\ net' = SendAll(net, {Msg("SWARM_END_WF", SJ, CJ(c), <<JobId, c>>, None) : c \in Sites})
    /\ UNCHANGED wfSJ_c
EndReplied(c) == \E k \in DOMAIN net : InInbox(k, SJ, "SWARM_END_REPLY") /\ M(k).from = CJ(c)
\* @L WfSJ.swarm.server
SwarmEndDone ==
    /\ Pol = "swarm" /\ Running /\ pWfSJ.cw = "ending" /\ \A c \in Sites : EndReplied(c)
    /\ pWfSJ' = [pWfSJ EXCEPT !.returned = "normal", !.saved = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>
\* fewer replies than required (min_clients = 0: all) within end_workflow_timeout
\* @L WfSJ.swarm.server
SwarmEndFail ==
    /\ Pol = "swarm" /\ Running /\ pWfSJ.cw = "ending"
    /\ \E c \in Sites : ~EndReplied(c) /\ (PeerFailureCJ(c, CurLaunch(c)) \/ "swarmMsgFail" \in Faults
                                                \/ LossyIn(Faults, {"SWARM_END_WF", "SWARM_END_REPLY"}))
    /\ pWfSJ' = [pWfSJ EXCEPT !.returned = "error", !.panic = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>

\* @L WfSJ.cse.flow
CseDone ==
    /\ Pol = "cseServer" /\ Running /\ W.round = Rounds /\ W.closed = "ok"
    /\ pWfSJ' = [pWfSJ EXCEPT !.saved = TRUE, !.returned = "normal"]
    /\ UNCHANGED <<wfSJ_c, net>>

\* status done + END_RUN broadcast to all clients (one aux call).
\* @L WfSJ.runner.end
EndRun ==
    /\ SJAlive /\ pWfSJ.returned /= "none" /\ pCommSJ.finalized /\ ~pWfSJ.done
    /\ pWfSJ' = [pWfSJ EXCEPT !.done = TRUE]
    /\ net' = SendAll(net, {Msg("END_RUN", SJ, CJ(c), <<JobId, c>>, None) : c \in Sites})
    /\ UNCHANGED wfSJ_c

\* @L WfSJ.runner.end
DSShutdown ==
    /\ SJAlive /\ pWfSJ.done /\ ~pWfSJ.dsShutdown
    /\ pWfSJ' = [pWfSJ EXCEPT !.dsShutdown = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>

\* @L WfSJ.proc.SJ, WfSJ.runner.end
Exit ==
    /\ SJAlive /\ pWfSJ.dsShutdown /\ pWfSJ.sj = "running"
    /\ PayRcvShutDone    \* DownloadService.shutdown() returned (call-return handshake)
    /\ pWfSJ' = [pWfSJ EXCEPT !.sj = "exited"]
    /\ UNCHANGED <<wfSJ_c, net>>

\* v11 G (#15, sjSyncFail): the new SJ cannot get the participants from the SP
\* within 30 s (sync_clients_from_main_process, server_engine.py:829-848); the
\* RuntimeError ends start_server_app (FATAL_SYSTEM_ERROR, server_app_runner.py:
\* 84-91) and the SJ process exits nonzero before the workflow opens.
\* @L WfSJ.start.sync
SyncFail ==
    /\ "sjSyncFail" \in Faults /\ pJobSP.sjLaunched /\ pWfSJ.sj = "none" /\ SJAlive
    /\ pWfSJ' = [pWfSJ EXCEPT !.sj = "crashed", !.panic = TRUE]
    /\ UNCHANGED <<wfSJ_c, net>>

\* @L WfSJ.proc.SJ
Crash ==
    /\ "sjCrash" \in Faults /\ SJAlive /\ pWfSJ.sj = "running"
    /\ pWfSJ' = [pWfSJ EXCEPT !.sj = "crashed"]
    /\ UNCHANGED <<wfSJ_c, net>>

Next == \/ Open \/ StartRound \/ Schedule \/ Panic \/ RecordError \/ CancelAll \/ CloseRound
        \/ RaiseReturn \/ Aggregate \/ Save \/ EndRun \/ DSShutdown \/ Exit \/ Crash
        \/ CallAggregate \/ AggregateRet \/ CallSave \/ SaveRet \/ CseDone \/ RelayPanic
        \/ SwarmCfgPanic \/ SwarmStartOk \/ SwarmStartPanic \/ SwarmErrPanic \/ SwarmProgressPanic
        \/ SwarmAllDone \/ SwarmEndDone \/ SwarmEndFail \/ SyncFail
        \/ \E c \in Sites : Count(c) \/ Accept(c) \/ Return(c)
                           \/ CallAccept(c) \/ AcceptRet(c) \/ RaiseCb(c) \/ StopWorkflow(c)
=============================================================================
