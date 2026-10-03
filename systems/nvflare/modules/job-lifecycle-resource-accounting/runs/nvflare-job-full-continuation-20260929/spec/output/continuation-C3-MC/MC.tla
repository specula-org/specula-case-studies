--------------------------------- MODULE MC ---------------------------------
(***************************************************************************)
(* Model-checking wrapper for base.tla (NVFlare job lifecycle / resource   *)
(* accounting).                                                            *)
(*                                                                         *)
(* Counter-bounded (they INTRODUCE nondeterminism: faults and inputs):     *)
(*   message loss, early RPC timeouts (CHECK / START), deploy failures of  *)
(*   live clients, SJ launch failure, scheduler back-off skips, SJ error / *)
(*   crash, CJ error / UNSAFE rc / same-group descendants, CJ launch       *)
(*   failure, CP crash, admin abort / delete / disable, heartbeats, the    *)
(*   unsupported app-dir removal (F9), and CHECK attempts (constraint).    *)
(* Unbounded (reactive / normal operation): every runner, completion,      *)
(* handler, waiter, expiry-tick, CJ-notification and normal-exit step, and *)
(* timeouts whose missing replies can no longer arrive.                    *)
(***************************************************************************)
EXTENDS base

B == INSTANCE base

CONSTANTS
    MaxLose,          \* LoseMsg
    MaxCheckTimeout,  \* RunnerCheckTimeout while a reply could still arrive (late CHECK processing)
    MaxStartTimeout,  \* RunnerStartTimeout while a reply could still arrive
    MaxDeployFail,    \* RunnerDeployJob with a live client failing / timing out
    MaxSjLaunchFail,  \* RunnerStartServerAppFail
    MaxBackoff,       \* RunnerBackoffSkip
    MaxSjError,       \* SjFinish with execution_error
    MaxSjCrash,       \* SjCrash
    MaxCjError,       \* CjExit rc 1
    MaxCjUnsafe,      \* CjExit rc 102 (rc file)
    MaxCjDesc,        \* CjExit leaving same-group descendants
    MaxCpLaunchFail,  \* CpStartLaunchFail
    MaxClientCrash,   \* ClientCrash
    MaxAbort,         \* AdminAbortBegin
    MaxDelete,        \* AdminDeleteAuthorize
    MaxDisable,       \* AdminDisable
    MaxHeartbeat,     \* Heartbeat (safety configs); liveness configs use MCLiveSpec (unbounded, fair)
    MaxAppMissing,    \* CpStartAllocateAppMissing (only with EnableUnsupported)
    MaxAttempts       \* CHECK attempts (state constraint on nextAtt)

FaultKinds == {"lose", "chkTO", "stTO", "depFail", "sjLaunchFail", "backoff", "sjError", "sjCrash",
               "cjError", "cjUnsafe", "cjDesc", "cpLaunchFail", "crash", "abort", "delete", "disable",
               "hb", "appMissing"}

VARIABLE fc
faultVars == <<fc>>
mc_vars == <<vars, fc>>

Under(k, lim) == fc[k] < lim
Bump(k) == fc' = [fc EXCEPT ![k] = @ + 1]

-----------------------------------------------------------------------------
(* Counter-bounded wrappers *)

MCLoseMsg(m) == Under("lose", MaxLose) /\ B!LoseMsg(m) /\ Bump("lose")

MCRunnerCheckTimeout ==
    \/ /\ B!RunnerCheckTimeout /\ B!CheckRepliesLost /\ UNCHANGED faultVars      \* real timeout
    \/ /\ Under("chkTO", MaxCheckTimeout) /\ ~B!CheckRepliesLost
       /\ B!RunnerCheckTimeout /\ Bump("chkTO")                                   \* early timeout (late reply)

MCRunnerStartTimeout ==
    \/ /\ B!RunnerStartTimeout /\ B!StartRepliesLost /\ UNCHANGED faultVars
    \/ /\ Under("stTO", MaxStartTimeout) /\ ~B!StartRepliesLost
       /\ B!RunnerStartTimeout /\ Bump("stTO")

MCRunnerDeployJob(F) ==
    LET liveFail == {c \in F : cpAlive[c]} IN
    IF liveFail = {}
    THEN B!RunnerDeployJob(F) /\ UNCHANGED faultVars
    ELSE Under("depFail", MaxDeployFail) /\ B!RunnerDeployJob(F) /\ Bump("depFail")

MCRunnerStartServerAppFail == Under("sjLaunchFail", MaxSjLaunchFail) /\ B!RunnerStartServerAppFail /\ Bump("sjLaunchFail")
MCRunnerBackoffSkip == B!RunnerBackoffSkip /\ UNCHANGED faultVars

MCSjFinish(j, ee, rc) ==
    IF ee THEN Under("sjError", MaxSjError) /\ B!SjFinish(j, ee, rc) /\ Bump("sjError")
    ELSE B!SjFinish(j, ee, rc) /\ UNCHANGED faultVars
MCSjCrash(j) == Under("sjCrash", MaxSjCrash) /\ B!SjCrash(j) /\ Bump("sjCrash")

MCCjExit(c, j, rc, d) ==
    /\ rc = RC_EXEC_ERR => Under("cjError", MaxCjError)
    /\ rc = RC_UNSAFE => Under("cjUnsafe", MaxCjUnsafe)
    /\ d => Under("cjDesc", MaxCjDesc)
    /\ B!CjExit(c, j, rc, d)
    /\ fc' = [fc EXCEPT !["cjError"] = @ + (IF rc = RC_EXEC_ERR THEN 1 ELSE 0),
                        !["cjUnsafe"] = @ + (IF rc = RC_UNSAFE THEN 1 ELSE 0),
                        !["cjDesc"] = @ + (IF d THEN 1 ELSE 0)]

MCCpStartLaunchFail(c, j) == Under("cpLaunchFail", MaxCpLaunchFail) /\ B!CpStartLaunchFail(c, j) /\ Bump("cpLaunchFail")
MCClientCrash(c) == Under("crash", MaxClientCrash) /\ B!ClientCrash(c) /\ Bump("crash")
MCAdminAbortBegin(j) == Under("abort", MaxAbort) /\ B!AdminAbortBegin(j) /\ Bump("abort")
MCAdminDeleteAuthorize(j) == Under("delete", MaxDelete) /\ B!AdminDeleteAuthorize(j) /\ Bump("delete")
MCAdminDisable(c) == Under("disable", MaxDisable) /\ B!AdminDisable(c) /\ Bump("disable")
MCHeartbeat(c) == B!Heartbeat(c) /\ UNCHANGED faultVars
MCCpStartAllocateAppMissing(m) ==
    Under("appMissing", MaxAppMissing) /\ B!CpStartAllocateAppMissing(m) /\ Bump("appMissing")

-----------------------------------------------------------------------------
(* Unbounded reactive steps: one named wrapper per base action so TLC traces name the step. *)

MCRunnerScanList        == B!RunnerScanList /\ UNCHANGED faultVars
MCRunnerScanReadDeleted == B!RunnerScanReadDeleted /\ UNCHANGED faultVars
MCRunnerScanRead        == B!RunnerScanRead /\ UNCHANGED faultVars
MCRunnerTryNext         == B!RunnerTryNext /\ UNCHANGED faultVars
MCRunnerTryDone         == B!RunnerTryDone /\ UNCHANGED faultVars
MCRunnerCheckCollect    == B!RunnerCheckCollect /\ UNCHANGED faultVars
MCRunnerRefreshRead     == B!RunnerRefreshRead /\ UNCHANGED faultVars
MCRunnerRefreshWrite    == B!RunnerRefreshWrite /\ UNCHANGED faultVars
MCRunnerSetCantSched    == B!RunnerSetCantSched /\ UNCHANGED faultVars
MCRunnerCheckSubmitted  == B!RunnerCheckSubmitted /\ UNCHANGED faultVars
MCRunnerSetDispatched   == B!RunnerSetDispatched /\ UNCHANGED faultVars
MCRunnerMetaRead        == B!RunnerMetaRead /\ UNCHANGED faultVars
MCRunnerMetaWrite       == B!RunnerMetaWrite /\ UNCHANGED faultVars
MCRunnerCheckDispatched == B!RunnerCheckDispatched /\ UNCHANGED faultVars
MCRunnerStartServerApp  == B!RunnerStartServerApp /\ UNCHANGED faultVars
MCRunnerStartCollect    == B!RunnerStartCollect /\ UNCHANGED faultVars
MCRunnerInsertRunning   == B!RunnerInsertRunning /\ UNCHANGED faultVars
MCRunnerSetRunning      == B!RunnerSetRunning /\ UNCHANGED faultVars
MCRunnerExceptStop      == B!RunnerExceptStop /\ UNCHANGED faultVars
MCRunnerExceptSetFailed == B!RunnerExceptSetFailed /\ UNCHANGED faultVars
MCRunnerExceptMeta      == B!RunnerExceptMeta /\ UNCHANGED faultVars
MCCmpFinalizeBegin(j)   == B!CmpFinalizeBegin(j) /\ UNCHANGED faultVars
MCCmpOutcomeDeadline(j) == B!CmpOutcomeDeadline(j) /\ UNCHANGED faultVars
MCCmpPublish            == B!CmpPublish /\ UNCHANGED faultVars
MCCmpRemove             == B!CmpRemove /\ UNCHANGED faultVars
MCAdminAbortWrite(j)    == B!AdminAbortWrite(j) /\ UNCHANGED faultVars
MCAdminStopRun(j)       == B!AdminStopRun(j) /\ UNCHANGED faultVars
MCAdminMarkAborted(j)   == B!AdminMarkAborted(j) /\ UNCHANGED faultVars
MCAdminDeleteExec(j)    == B!AdminDeleteExec(j) /\ UNCHANGED faultVars
MCSpUpdateRunStatus(m)  == B!SpUpdateRunStatus(m) /\ UNCHANGED faultVars
MCSpProcessJobFailure(m) == B!SpProcessJobFailure(m) /\ UNCHANGED faultVars
MCSjHandleAbort(m)      == B!SjHandleAbort(m) /\ UNCHANGED faultVars
MCCpCheckResource(m)    == B!CpCheckResource(m) /\ UNCHANGED faultVars
MCCpCancelResource(m)   == B!CpCancelResource(m) /\ UNCHANGED faultVars
MCCpStartAllocate(m)    == B!CpStartAllocate(m) /\ UNCHANGED faultVars
MCCpAbortApp(m)         == B!CpAbortApp(m) /\ UNCHANGED faultVars
MCSpWaitForComplete(j)  == B!SpWaitForComplete(j) /\ UNCHANGED faultVars
MCSpRemoveRunProcesses(j) == B!SpRemoveRunProcesses(j) /\ UNCHANGED faultVars
MCSweepBegin(c)         == B!SweepBegin(c) /\ UNCHANGED faultVars
MCSweepEnd              == B!SweepEnd /\ UNCHANGED faultVars
MCCpTick(c)             == B!CpTick(c) /\ UNCHANGED faultVars
MCCpStartRegister(c, j) == B!CpStartRegister(c, j) /\ UNCHANGED faultVars
MCCpStartLaunch(c, j)   == B!CpStartLaunch(c, j) /\ UNCHANGED faultVars
MCCpTerminateJob(c, j)  == B!CpTerminateJob(c, j) /\ UNCHANGED faultVars
MCCpChildFinished(c, j) == B!CpChildFinished(c, j) /\ UNCHANGED faultVars
MCCjNotifyStarted(c, j) == B!CjNotifyStarted(c, j) /\ UNCHANGED faultVars
MCCjNotifyStopped(c, j) == B!CjNotifyStopped(c, j) /\ UNCHANGED faultVars
MCCjHandleAbort(c, j)   == B!CjHandleAbort(c, j) /\ UNCHANGED faultVars
MCCjGroupExit(c, j)     == B!CjGroupExit(c, j) /\ UNCHANGED faultVars

(* Message-driven steps, named so TLC traces show them (TLC does not split \E over a state-dependent set). *)
MsgUpdateRunStatus         == \E m \in DOMAIN msgs : MCSpUpdateRunStatus(m)
MsgProcessJobFailure       == \E m \in DOMAIN msgs : MCSpProcessJobFailure(m)
MsgSjHandleAbort           == \E m \in DOMAIN msgs : MCSjHandleAbort(m)
MsgCheckResource           == \E m \in DOMAIN msgs : MCCpCheckResource(m)
MsgCancelResource          == \E m \in DOMAIN msgs : MCCpCancelResource(m)
MsgStartAllocate           == \E m \in DOMAIN msgs : MCCpStartAllocate(m)
MsgStartAllocateAppMissing == \E m \in DOMAIN msgs : MCCpStartAllocateAppMissing(m)
MsgAbortApp                == \E m \in DOMAIN msgs : MCCpAbortApp(m)
MsgLose                    == \E m \in DOMAIN msgs : MCLoseMsg(m)

(* Everything except heartbeats; flat disjunction so TLC names each step. *)
MCRunnerScanReadOne(j) == B!RunnerScanReadOne(j) /\ UNCHANGED faultVars
MCSjBootstrap(j) == B!SjBootstrap(j) /\ UNCHANGED faultVars
MCRunnerLaunchSJ == B!RunnerLaunchSJ /\ UNCHANGED faultVars
MCRunnerRegisterSJ == B!RunnerRegisterSJ /\ UNCHANGED faultVars
MCRunnerInitOutcomes == B!RunnerInitOutcomes /\ UNCHANGED faultVars
MCRunnerSendStart(c) == B!RunnerSendStart(c) /\ UNCHANGED faultVars
MCSpWaitRead(j) == B!SpWaitRead(j) /\ UNCHANGED faultVars
MCSpTerminateRun(j) == B!SpTerminateRun(j) /\ UNCHANGED faultVars
MCCpReapChild(c, j) == B!CpReapChild(c, j) /\ UNCHANGED faultVars
MCCjParentExit(c, j) == B!CjParentExit(c, j) /\ UNCHANGED faultVars
MCCmpReadServer(j) == B!CmpReadServer(j) /\ UNCHANGED faultVars
MCCmpReadPending == B!CmpReadPending /\ UNCHANGED faultVars
MCCmpReadAbort == B!CmpReadAbort /\ UNCHANGED faultVars
MCCmpReadOutcome == B!CmpReadOutcome /\ UNCHANGED faultVars
MCSpAcceptJobFailure(m) == B!SpAcceptJobFailure(m) /\ UNCHANGED faultVars
MCSpHandleJobFailure(m) == B!SpHandleJobFailure(m) /\ UNCHANGED faultVars
MCSpFailureStop(m) == B!SpFailureStop(m) /\ UNCHANGED faultVars
MCSpFailureMark(m) == B!SpFailureMark(m) /\ UNCHANGED faultVars

MCMicroNext ==
    \/ \E j \in Jobs : MCRunnerScanReadOne(j)
    \/ \E j \in Jobs : MCSjBootstrap(j)
    \/ MCRunnerLaunchSJ
    \/ MCRunnerRegisterSJ
    \/ MCRunnerInitOutcomes
    \/ \E c \in Clients : MCRunnerSendStart(c)
    \/ \E j \in Jobs : MCSpWaitRead(j)
    \/ \E j \in Jobs : MCSpTerminateRun(j)
    \/ \E c \in Clients, j \in Jobs : MCCpReapChild(c, j)
    \/ \E c \in Clients, j \in Jobs : MCCjParentExit(c, j)
    \/ \E j \in Jobs : MCCmpReadServer(j)
    \/ MCCmpReadPending
    \/ MCCmpReadAbort
    \/ MCCmpReadOutcome
    \/ \E m \in DOMAIN msgs : MCSpAcceptJobFailure(m)
    \/ \E m \in DOMAIN msgs : MCSpHandleJobFailure(m)
    \/ \E m \in DOMAIN msgs : MCSpFailureStop(m)
    \/ \E m \in DOMAIN msgs : MCSpFailureMark(m)

MCNextCore ==
    \/ MCMicroNext
    \/ MCRunnerScanList \/ MCRunnerScanReadDeleted \/ MCRunnerScanRead \/ MCRunnerTryNext \/ MCRunnerTryDone
    \/ MCRunnerCheckCollect \/ MCRunnerCheckTimeout \/ MCRunnerBackoffSkip
    \/ MCRunnerRefreshRead \/ MCRunnerRefreshWrite \/ MCRunnerSetCantSched \/ MCRunnerCheckSubmitted
    \/ \E F \in SUBSET Clients : MCRunnerDeployJob(F)
    \/ MCRunnerSetDispatched \/ MCRunnerMetaRead \/ MCRunnerMetaWrite \/ MCRunnerCheckDispatched
    \/ MCRunnerStartServerApp \/ MCRunnerStartServerAppFail \/ MCRunnerStartCollect \/ MCRunnerStartTimeout
    \/ MCRunnerInsertRunning \/ MCRunnerSetRunning
    \/ MCRunnerExceptStop \/ MCRunnerExceptSetFailed \/ MCRunnerExceptMeta
    \/ \E j \in Jobs : MCCmpFinalizeBegin(j) \/ MCCmpOutcomeDeadline(j)
    \/ MCCmpPublish \/ MCCmpRemove
    \/ \E j \in Jobs : \/ MCAdminAbortBegin(j) \/ MCAdminAbortWrite(j) \/ MCAdminStopRun(j)
                       \/ MCAdminMarkAborted(j) \/ MCAdminDeleteAuthorize(j) \/ MCAdminDeleteExec(j)
    \/ \E c \in Clients : MCAdminDisable(c)
    \/ MsgUpdateRunStatus \/ MsgProcessJobFailure \/ MsgSjHandleAbort \/ MsgCheckResource
    \/ MsgCancelResource \/ MsgStartAllocate \/ MsgStartAllocateAppMissing \/ MsgAbortApp \/ MsgLose
    \/ \E j \in Jobs : \/ MCSpWaitForComplete(j) \/ MCSpRemoveRunProcesses(j)
                       \/ \E o \in SjOutcomes : MCSjFinish(j, o[1], o[2])
                       \/ MCSjCrash(j)
    \/ \E c \in Clients : MCSweepBegin(c) \/ MCCpTick(c) \/ MCClientCrash(c)
    \/ MCSweepEnd
    \/ \E c \in Clients, j \in Jobs :
          \/ MCCpStartRegister(c, j) \/ MCCpStartLaunch(c, j) \/ MCCpStartLaunchFail(c, j)
          \/ MCCpTerminateJob(c, j) \/ MCCpChildFinished(c, j)
          \/ MCCjNotifyStarted(c, j) \/ MCCjNotifyStopped(c, j) \/ MCCjHandleAbort(c, j) \/ MCCjGroupExit(c, j)
          \/ \E rc \in CjExitCodes, d \in BOOLEAN : MCCjExit(c, j, rc, d)

MCNext == MCNextCore \/ \E c \in Clients : MCHeartbeat(c)

MCInit == Init /\ fc = [k \in FaultKinds |-> 0]

MCSpec == MCInit /\ [][MCNext]_mc_vars

(* Liveness: heartbeats are periodic and must not be bounded away (a bounded heartbeat would make the
   heartbeat fairness assumption vacuous). *)
MCHeartbeatLive(c) == B!Heartbeat(c) /\ UNCHANGED faultVars
MCLiveNext == MCNextCore \/ \E c \in Clients : MCHeartbeatLive(c)
MCLiveSpec == MCInit /\ [][MCLiveNext]_mc_vars /\ Fairness /\ MicroFairness

-----------------------------------------------------------------------------
(* State-space control *)

AttemptBound == nextAtt <= MaxAttempts + 1

(* Views: behaviour variables + fault counters (never dropped: they gate behaviour) + exactly the history
   variables the configuration's checks read.  Sound for those checks because history is write-only. *)
ViewAll   == <<vars, fc>>
ViewS1    == <<behVars, fc, firstTerm, ovw, ackAbort, postAckLaunch, launches, ackInWindow>>
ViewS2    == <<behVars, fc, startedEv, endedEv>>
ViewS3    == <<behVars, fc>>
ViewS4    == <<behVars, fc, exeErrRec, failAccepted, sjAbortHandled, failRunRec, startFailCause, sjErr,
              latchInStopWin>>

(* Phase 3 fidelity probe (checker aid, not a contract): only the F16 writer.  MC_seed_F16.cfg reaches the
   shallower F1 overwrite first under TerminalStable; MC_seed_F16_refresh.cfg uses this to show F16 itself. *)
NoRefreshWriteOverwrite == \A o \in ovw : o.w # "RefreshWrite"

SymUnits == Permutations(Units)
SymClientsUnits == {p @@ q : p \in Permutations(Clients), q \in Permutations(Units)}

-----------------------------------------------------------------------------
(* Configuration helpers (TLC cfg files cannot spell tuples or functions).  Job ids are the strings
   "j1", "j2" (jobs are ordered by submit time and never symmetric); clients and units are model values. *)

MCJobOrder        == <<"j1", "j2">>
MCJobOrder1       == <<"j1">>
MCDeployAll       == [j \in Jobs |-> Clients]
MCMinOne          == [j \in Jobs |-> 1]
MCMinAll          == [j \in Jobs |-> Cardinality(Clients)]
MCReqNone         == [j \in Jobs |-> {}]
MCReqAll          == [j \in Jobs |-> Clients]
MCPoisonNone      == [j \in Jobs |-> "none"]
MCPoisonFirstPre  == [j \in Jobs |-> IF j = "j1" THEN "pre" ELSE "none"]
MCPoisonFirstPost == [j \in Jobs |-> IF j = "j1" THEN "post" ELSE "none"]
=============================================================================
