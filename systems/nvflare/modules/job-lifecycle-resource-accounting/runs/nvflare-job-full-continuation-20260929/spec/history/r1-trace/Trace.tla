------------------------------- MODULE Trace -------------------------------
(***************************************************************************)
(* Trace validation for base.tla (Category A: one linear NDJSON trace).    *)
(*                                                                         *)
(* Trace file lines (see instrumentation-spec.md):                         *)
(*   {"tag":"config", ...scenario constants...}      exactly one line      *)
(*   {"tag":"trace", "seq":n, "event":{name, job, cl, msg, arg, state}}    *)
(* Every event names one base action; "state" is the POST-state snapshot  *)
(* of every observable variable (server tables for all jobs, client pools *)
(* and registrations for all clients).  Program counters, in-flight        *)
(* messages and history variables are implied by the event order and are  *)
(* checked through the base actions' preconditions.                        *)
(***************************************************************************)
EXTENDS base, Json, IOUtils, Sequences, TLC

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawLog == TLCEval(ndJsonDeserialize(JsonFile))

TraceLog == TLCEval(SelectSeq(RawLog, LAMBDA x : /\ "tag" \in DOMAIN x
                                                 /\ x.tag = "trace"
                                                 /\ "event" \in DOMAIN x))

TraceConfig == TLCEval(LET cfgs == SelectSeq(RawLog, LAMBDA x : "tag" \in DOMAIN x /\ x.tag = "config")
                       IN cfgs[1])

ASSUME Len(TraceLog) > 0

ToSet(s) == {s[i] : i \in DOMAIN s}
TV(x) == IF x = "None" THEN None ELSE x

(* ---- Scenario constants read from the config line (bound in Trace.cfg with <-) ---- *)
TraceJobs             == ToSet(TraceConfig.jobs)
TraceJobOrder         == TraceConfig.jobs                        \* listed in submit order
TraceClients          == ToSet(TraceConfig.clients)
TraceUnits            == ToSet(TraceConfig.units)
TraceNeed             == TraceConfig.need
TraceDeploySites      == [j \in TraceJobs |-> ToSet(TraceConfig.deploy_sites[j])]
TraceMinSites         == [j \in TraceJobs |-> TraceConfig.min_sites[j]]
TraceRequired         == [j \in TraceJobs |-> ToSet(TraceConfig.required[j])]
TraceMaxJobs          == TraceConfig.max_jobs
TraceMaxScheduleCount == TraceConfig.max_schedule_count
TraceExpiry           == TraceConfig.expiry
TracePoisonAt         == [j \in TraceJobs |-> "none"]

-----------------------------------------------------------------------------
VARIABLE l

traceVars == <<l>>

logline == TraceLog[l]
E == logline.event
S == E.state

IsEvent(n) == l <= Len(TraceLog) /\ E.name = n
StepTrace == l' = l + 1

(* The consumed message is identified by the event's msg object. *)
MsgMatches(m) ==
    /\ m.type = E.msg.type
    /\ m.job = TV(E.msg.job)
    /\ m.cl = TV(E.msg.cl)
    /\ m.att = E.msg.att
    /\ m.ok = E.msg.ok
    /\ m.code = E.msg.code
    /\ m.flag = E.msg.flag

-----------------------------------------------------------------------------
(***************************************************************************)
(* Post-state validation (strong): every observable variable, every event. *)
(***************************************************************************)

RecMatches(specRec, t) ==
    IF ~t.present THEN specRec = None
    ELSE /\ specRec # None
         /\ specRec.finished = t.finished
         /\ specRec.exeErr = t.exe_error
         /\ specRec.rc = t.rc
         /\ specRec.parts = ToSet(t.parts)

PendingMatches(p, t) == IF ~t.present THEN p = None ELSE p # None /\ p = ToSet(t.set)

RegMatches(e, t) ==
    IF ~t.present THEN e = None
    ELSE /\ e # None
         /\ e.st = t.st
         /\ e.attached = t.attached
         /\ e.abortReq = t.abort_req

StartingMatches(x, t) == IF ~t.present THEN x = None ELSE x # None /\ x.units = ToSet(t.units)

BagOf(L) == [u \in Units |-> Cardinality({i \in DOMAIN L : L[i] = u})]

ResvOf(L) == {[tok |-> L[i].att, job |-> L[i].job, units |-> ToSet(L[i].units), ttl |-> L[i].ttl] : i \in DOMAIN L}

ValidateServer ==
    /\ tagged' = ToSet(S.tagged)
    /\ slots' = ToSet(S.scheduled_jobs)
    /\ runningJobs' = ToSet(S.running_jobs)
    /\ sessions' = ToSet(S.sessions)
    /\ \A j \in Jobs :
         LET t == S.jobs[j] IN
         /\ status'[j] = t.status
         /\ pCount'[j] = t.schedule_count
         /\ runAborted'[j] = t.run_aborted
         /\ PendingMatches(pending'[j], t.pending)
         /\ latched'[j] = TV(t.latched)
         /\ RecMatches(rp'[j], t.run_process)
         /\ RecMatches(exc'[j], t.exception_process)
         /\ sj'[j] = t.sj

ValidateClients ==
    \A c \in Clients :
        LET t == S.clients[c] IN
        /\ cpAlive'[c] = t.alive
        /\ t.alive =>
             /\ free'[c] = BagOf(t.free)
             /\ resv'[c] = ResvOf(t.reserved)
             /\ \A j \in Jobs :
                  /\ RegMatches(cjReg'[c][j], t.jobs[j].registration)
                  /\ StartingMatches(cst'[c][j], t.jobs[j].starting)
                  /\ alloc'[c][j] = ToSet(t.jobs[j].allocated)
                  /\ cjProc'[c][j] = t.jobs[j].cj

ValidatePostState == ValidateServer /\ ValidateClients

-----------------------------------------------------------------------------
(***************************************************************************)
(* Action wrappers: match event -> base action -> validate -> advance.     *)
(***************************************************************************)

(* Parameterless actions *)
Plain(n, A) == IsEvent(n) /\ A /\ ValidatePostState /\ StepTrace

(* Job-parameterised actions *)
JobEv(n) == IsEvent(n) /\ TV(E.job) \in Jobs
(* Client-parameterised actions *)
ClEv(n) == IsEvent(n) /\ TV(E.cl) \in Clients

RunnerScanListLogged        == Plain("RunnerScanList", RunnerScanList)
RunnerScanReadDeletedLogged == Plain("RunnerScanReadDeleted", RunnerScanReadDeleted)
RunnerScanReadLogged        == Plain("RunnerScanRead", RunnerScanRead)
RunnerTryNextLogged         == Plain("RunnerTryNext", RunnerTryNext)
RunnerBackoffSkipLogged     == Plain("RunnerBackoffSkip", RunnerBackoffSkip)
RunnerTryDoneLogged         == Plain("RunnerTryDone", RunnerTryDone)
RunnerCheckCollectLogged    == Plain("RunnerCheckCollect", RunnerCheckCollect)
RunnerCheckTimeoutLogged    == Plain("RunnerCheckTimeout", RunnerCheckTimeout)
RunnerRefreshReadLogged     == Plain("RunnerRefreshRead", RunnerRefreshRead)
RunnerRefreshWriteLogged    == Plain("RunnerRefreshWrite", RunnerRefreshWrite)
RunnerSetCantSchedLogged    == Plain("RunnerSetCantSched", RunnerSetCantSched)
RunnerCheckSubmittedLogged  == Plain("RunnerCheckSubmitted", RunnerCheckSubmitted)
RunnerDeployJobLogged       ==
    /\ IsEvent("RunnerDeployJob")
    /\ RunnerDeployJob(ToSet(E.arg.failed))
    /\ ValidatePostState
    /\ StepTrace
RunnerSetDispatchedLogged   == Plain("RunnerSetDispatched", RunnerSetDispatched)
RunnerMetaReadLogged        == Plain("RunnerMetaRead", RunnerMetaRead)
RunnerMetaWriteLogged       == Plain("RunnerMetaWrite", RunnerMetaWrite)
RunnerCheckDispatchedLogged == Plain("RunnerCheckDispatched", RunnerCheckDispatched)
RunnerStartServerAppLogged  == Plain("RunnerStartServerApp", RunnerStartServerApp)
RunnerStartServerAppFailLogged == Plain("RunnerStartServerAppFail", RunnerStartServerAppFail)
RunnerStartCollectLogged    == Plain("RunnerStartCollect", RunnerStartCollect)
RunnerStartTimeoutLogged    == Plain("RunnerStartTimeout", RunnerStartTimeout)
RunnerInsertRunningLogged   == Plain("RunnerInsertRunning", RunnerInsertRunning)
RunnerSetRunningLogged      == Plain("RunnerSetRunning", RunnerSetRunning)
RunnerExceptStopLogged      == Plain("RunnerExceptStop", RunnerExceptStop)
RunnerExceptSetFailedLogged == Plain("RunnerExceptSetFailed", RunnerExceptSetFailed)
RunnerExceptMetaLogged      == Plain("RunnerExceptMeta", RunnerExceptMeta)

CmpFinalizeBeginLogged ==
    /\ JobEv("CmpFinalizeBegin") /\ CmpFinalizeBegin(TV(E.job)) /\ ValidatePostState /\ StepTrace
CmpOutcomeDeadlineLogged ==
    /\ JobEv("CmpOutcomeDeadline") /\ CmpOutcomeDeadline(TV(E.job)) /\ ValidatePostState /\ StepTrace
CmpPublishLogged == Plain("CmpPublish", CmpPublish)
CmpRemoveLogged  == Plain("CmpRemove", CmpRemove)

AdminAbortBeginLogged ==
    /\ JobEv("AdminAbortBegin") /\ AdminAbortBegin(TV(E.job)) /\ ValidatePostState /\ StepTrace
AdminAbortWriteLogged ==
    /\ JobEv("AdminAbortWrite") /\ AdminAbortWrite(TV(E.job)) /\ ValidatePostState /\ StepTrace
AdminStopRunLogged ==
    /\ JobEv("AdminStopRun") /\ AdminStopRun(TV(E.job)) /\ ValidatePostState /\ StepTrace
AdminMarkAbortedLogged ==
    /\ JobEv("AdminMarkAborted") /\ AdminMarkAborted(TV(E.job)) /\ ValidatePostState /\ StepTrace
AdminDeleteAuthorizeLogged ==
    /\ JobEv("AdminDeleteAuthorize") /\ AdminDeleteAuthorize(TV(E.job)) /\ ValidatePostState /\ StepTrace
AdminDeleteExecLogged ==
    /\ JobEv("AdminDeleteExec") /\ AdminDeleteExec(TV(E.job)) /\ ValidatePostState /\ StepTrace
AdminDisableLogged ==
    /\ ClEv("AdminDisable") /\ AdminDisable(TV(E.cl)) /\ ValidatePostState /\ StepTrace

(* Message-consuming actions: the event's msg object identifies the message. *)
MsgEv(n, A(_)) == IsEvent(n) /\ \E m \in DOMAIN msgs : MsgMatches(m) /\ A(m) /\ ValidatePostState /\ StepTrace

SpUpdateRunStatusLogged   == MsgEv("SpUpdateRunStatus", SpUpdateRunStatus)
SpProcessJobFailureLogged == MsgEv("SpProcessJobFailure", SpProcessJobFailure)
SjHandleAbortLogged       == MsgEv("SjHandleAbort", SjHandleAbort)
CpCheckResourceLogged     == MsgEv("CpCheckResource", CpCheckResource)
CpCancelResourceLogged    == MsgEv("CpCancelResource", CpCancelResource)
CpStartAllocateLogged     == MsgEv("CpStartAllocate", CpStartAllocate)
CpStartAllocateAppMissingLogged == MsgEv("CpStartAllocateAppMissing", CpStartAllocateAppMissing)
CpAbortAppLogged          == MsgEv("CpAbortApp", CpAbortApp)
LoseMsgLogged             == MsgEv("LoseMsg", LoseMsg)

SpWaitForCompleteLogged ==
    /\ JobEv("SpWaitForComplete") /\ SpWaitForComplete(TV(E.job)) /\ ValidatePostState /\ StepTrace
SpRemoveRunProcessesLogged ==
    /\ JobEv("SpRemoveRunProcesses") /\ SpRemoveRunProcesses(TV(E.job)) /\ ValidatePostState /\ StepTrace
SweepBeginLogged == /\ ClEv("SweepBegin") /\ SweepBegin(TV(E.cl)) /\ ValidatePostState /\ StepTrace
SweepEndLogged   == Plain("SweepEnd", SweepEnd)

SjFinishLogged ==
    /\ JobEv("SjFinish") /\ SjFinish(TV(E.job), E.arg.execution_error, E.arg.rc) /\ ValidatePostState /\ StepTrace
SjCrashLogged ==
    /\ JobEv("SjCrash") /\ SjCrash(TV(E.job)) /\ ValidatePostState /\ StepTrace

CJEv(n) == IsEvent(n) /\ TV(E.cl) \in Clients /\ TV(E.job) \in Jobs

CpStartRegisterLogged ==
    /\ CJEv("CpStartRegister") /\ CpStartRegister(TV(E.cl), TV(E.job)) /\ ValidatePostState /\ StepTrace
CpStartLaunchLogged ==
    /\ CJEv("CpStartLaunch") /\ CpStartLaunch(TV(E.cl), TV(E.job)) /\ ValidatePostState /\ StepTrace
CpStartLaunchFailLogged ==
    /\ CJEv("CpStartLaunchFail") /\ CpStartLaunchFail(TV(E.cl), TV(E.job)) /\ ValidatePostState /\ StepTrace
CpTerminateJobLogged ==
    /\ CJEv("CpTerminateJob") /\ CpTerminateJob(TV(E.cl), TV(E.job)) /\ ValidatePostState /\ StepTrace
CpChildFinishedLogged ==
    /\ CJEv("CpChildFinished") /\ CpChildFinished(TV(E.cl), TV(E.job)) /\ ValidatePostState /\ StepTrace
CpTickLogged      == /\ ClEv("CpTick") /\ CpTick(TV(E.cl)) /\ ValidatePostState /\ StepTrace
HeartbeatLogged   == /\ ClEv("Heartbeat") /\ Heartbeat(TV(E.cl)) /\ ValidatePostState /\ StepTrace
ClientCrashLogged == /\ ClEv("ClientCrash") /\ ClientCrash(TV(E.cl)) /\ ValidatePostState /\ StepTrace

CjNotifyStartedLogged ==
    /\ CJEv("CjNotifyStarted") /\ CjNotifyStarted(TV(E.cl), TV(E.job)) /\ ValidatePostState /\ StepTrace
CjNotifyStoppedLogged ==
    /\ CJEv("CjNotifyStopped") /\ CjNotifyStopped(TV(E.cl), TV(E.job)) /\ ValidatePostState /\ StepTrace
CjHandleAbortLogged ==
    /\ CJEv("CjHandleAbort") /\ CjHandleAbort(TV(E.cl), TV(E.job)) /\ ValidatePostState /\ StepTrace
CjExitLogged ==
    /\ CJEv("CjExit")
    /\ CjExit(TV(E.cl), TV(E.job), E.arg.rc, E.arg.descendants)
    /\ ValidatePostState
    /\ StepTrace
CjGroupExitLogged ==
    /\ CJEv("CjGroupExit") /\ CjGroupExit(TV(E.cl), TV(E.job)) /\ ValidatePostState /\ StepTrace

-----------------------------------------------------------------------------
(***************************************************************************)
(* Silent actions: none.  Every base action has an instrumented code point *)
(* (instrumentation-spec.md), including expiry ticks, injected message     *)
(* loss and RPC timeouts, so every state change consumes one event.        *)
(***************************************************************************)

TraceInit == Init /\ l = 1

TraceNext ==
    \/ RunnerScanListLogged \/ RunnerScanReadDeletedLogged \/ RunnerScanReadLogged
    \/ RunnerTryNextLogged \/ RunnerBackoffSkipLogged \/ RunnerTryDoneLogged
    \/ RunnerCheckCollectLogged \/ RunnerCheckTimeoutLogged
    \/ RunnerRefreshReadLogged \/ RunnerRefreshWriteLogged \/ RunnerSetCantSchedLogged
    \/ RunnerCheckSubmittedLogged \/ RunnerDeployJobLogged \/ RunnerSetDispatchedLogged
    \/ RunnerMetaReadLogged \/ RunnerMetaWriteLogged \/ RunnerCheckDispatchedLogged
    \/ RunnerStartServerAppLogged \/ RunnerStartServerAppFailLogged
    \/ RunnerStartCollectLogged \/ RunnerStartTimeoutLogged
    \/ RunnerInsertRunningLogged \/ RunnerSetRunningLogged
    \/ RunnerExceptStopLogged \/ RunnerExceptSetFailedLogged \/ RunnerExceptMetaLogged
    \/ CmpFinalizeBeginLogged \/ CmpOutcomeDeadlineLogged \/ CmpPublishLogged \/ CmpRemoveLogged
    \/ AdminAbortBeginLogged \/ AdminAbortWriteLogged \/ AdminStopRunLogged \/ AdminMarkAbortedLogged
    \/ AdminDeleteAuthorizeLogged \/ AdminDeleteExecLogged \/ AdminDisableLogged
    \/ SpUpdateRunStatusLogged \/ SpProcessJobFailureLogged \/ SjHandleAbortLogged
    \/ CpCheckResourceLogged \/ CpCancelResourceLogged \/ CpStartAllocateLogged
    \/ CpStartAllocateAppMissingLogged \/ CpAbortAppLogged \/ LoseMsgLogged
    \/ SpWaitForCompleteLogged \/ SpRemoveRunProcessesLogged \/ SweepBeginLogged \/ SweepEndLogged
    \/ SjFinishLogged \/ SjCrashLogged
    \/ CpStartRegisterLogged \/ CpStartLaunchLogged \/ CpStartLaunchFailLogged
    \/ CpTerminateJobLogged \/ CpChildFinishedLogged \/ CpTickLogged \/ HeartbeatLogged \/ ClientCrashLogged
    \/ CjNotifyStartedLogged \/ CjNotifyStoppedLogged \/ CjHandleAbortLogged \/ CjExitLogged
    \/ CjGroupExitLogged

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>> /\ WF_<<vars, l>>(TraceNext)

TraceView == <<vars, l>>

TraceMatched == <>(l > Len(TraceLog))

TraceAlias ==
    [ l      |-> l,
      len    |-> Len(TraceLog),
      event  |-> IF l <= Len(TraceLog) THEN E.name ELSE "DONE",
      seq    |-> IF l <= Len(TraceLog) /\ "seq" \in DOMAIN logline THEN logline.seq ELSE -1,
      status |-> status,
      rpc_pc |-> rpc.pc,
      cmp_pc |-> cpc.pc,
      slots  |-> slots,
      running |-> runningJobs,
      pending |-> pending,
      rp     |-> rp,
      exc    |-> exc,
      free   |-> free,
      resv   |-> resv,
      reg    |-> cjReg,
      msgs   |-> msgs ]

=============================================================================
