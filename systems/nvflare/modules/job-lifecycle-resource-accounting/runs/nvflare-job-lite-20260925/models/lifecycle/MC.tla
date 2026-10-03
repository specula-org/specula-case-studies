-------------------------------- MODULE MC --------------------------------
(* Model-checking wrapper for base.tla: bounds fault-injection actions and *)
(* restricts which jobs the admin aborts/deletes. Reactive/normal actions  *)
(* are not bounded.                                                         *)
EXTENDS base

CONSTANTS
    AbortSet,             \* jobs the admin may abort (one abort_job per job)
    DeleteSet,            \* jobs the admin may delete (one delete_job per job)
    MaxNoResource,        \* scheduler NO_RESOURCE results
    MaxServerDeployFail,  \* server-side deploy failures
    MaxClientDeployFail,  \* client deploy failures/timeouts
    MaxSJLaunchFail,      \* SJ launch failures
    MaxStartErr,          \* explicit START_JOB error replies
    MaxStartTimeout,      \* START_JOB reply timeouts
    MaxSJExitFail,        \* SJ execution failures
    MaxCJExitFail,        \* CJ execution failures
    MaxReportLost,        \* lost CJ terminal-outcome reports
    MaxOutcomeDeadline,   \* client_outcome_wait_timeout expiries
    AbortOnlyRunning      \* scenario restriction: admin aborts only RUNNING jobs (hunts past S1)

VARIABLE flt
mcVars == <<vars, flt>>

MCInit ==
    /\ Init
    /\ flt = [nr |-> 0, sdf |-> 0, cdf |-> 0, slf |-> 0, se |-> 0, st |-> 0,
              sef |-> 0, cef |-> 0, rl |-> 0, od |-> 0]

Inc(f) == flt' = [flt EXCEPT ![f] = @ + 1]
Keep == UNCHANGED flt

\* Named wrappers so counterexample traces show action names.
W_RunnerScanList == RunnerScanList /\ Keep
W_RunnerScanRead == RunnerScanRead /\ Keep
W_RunnerSchedule == RunnerSchedule /\ Keep
W_RunnerNoSchedule == RunnerNoSchedule /\ Keep
W_RunnerCheckSubmitted == RunnerCheckSubmitted /\ Keep
W_RunnerDeploy == RunnerDeploy /\ Keep
W_RunnerSetDispatched == RunnerSetDispatched /\ Keep
W_RunnerUpdateMetaRead == RunnerUpdateMetaRead /\ Keep
W_RunnerUpdateMetaWrite == RunnerUpdateMetaWrite /\ Keep
W_RunnerCheckDispatched == RunnerCheckDispatched /\ Keep
W_RunnerStartSJ == RunnerStartSJ /\ Keep
W_RunnerCollectStart == RunnerCollectStart /\ Keep
W_RunnerAddRunning == RunnerAddRunning /\ Keep
W_RunnerSetRunning == RunnerSetRunning /\ Keep
W_RunnerExcCleanup == RunnerExcCleanup /\ Keep
W_RunnerExcSetFailed == RunnerExcSetFailed /\ Keep
W_RunnerExcFinish == RunnerExcFinish /\ Keep
F_RunnerNoResource == flt.nr < MaxNoResource /\ RunnerNoResource /\ Inc("nr")
F_RunnerServerDeployFail == flt.sdf < MaxServerDeployFail /\ RunnerServerDeployFail /\ Inc("sdf")
F_RunnerClientDeployFail == flt.cdf < MaxClientDeployFail /\ RunnerClientDeployFail /\ Inc("cdf")
F_RunnerStartSJFail == flt.slf < MaxSJLaunchFail /\ RunnerStartSJFail /\ Inc("slf")
F_RunnerCollectStartTimeout == flt.st < MaxStartTimeout /\ RunnerCollectStartTimeout /\ Inc("st")
W_CompleteClassify(j) == CompleteClassify(j) /\ Keep
W_CompletePublish(j) == CompletePublish(j) /\ Keep
F_CompleteAfterOutcomeDeadline(j) == flt.od < MaxOutcomeDeadline /\ CompleteAfterOutcomeDeadline(j) /\ Inc("od")
W_SJExitNormal(j) == SJExitNormal(j) /\ Keep
W_SJExitAborted(j) == SJExitAborted(j) /\ Keep
W_RemoveRunProcesses(j) == RemoveRunProcesses(j) /\ Keep
F_SJExitFail(j) == flt.sef < MaxSJExitFail /\ SJExitFail(j) /\ Inc("sef")
W_AdminAbortRead(j) == j \in AbortSet /\ (AbortOnlyRunning => status[j] = "RUNNING") /\ AdminAbortRead(j) /\ Keep
W_AdminAbortAct(j) == AdminAbortAct(j) /\ Keep
W_AdminAbortMark(j) == AdminAbortMark(j) /\ Keep
W_AdminDeleteSnap(j) == j \in DeleteSet /\ AdminDeleteSnap(j) /\ Keep
W_AdminDeleteAct(j) == AdminDeleteAct(j) /\ Keep
W_ClientStartOk(c, j) == ClientStartOk(c, j) /\ Keep
F_ClientStartErr(c, j) == flt.se < MaxStartErr /\ ClientStartErr(c, j) /\ Inc("se")
W_CJExitNormal(c, j) == CJExitNormal(c, j) /\ Keep
F_CJExitFail(c, j) == flt.cef < MaxCJExitFail /\ CJExitFail(c, j) /\ Inc("cef")
W_CJReport(c, j) == CJReport(c, j) /\ Keep
F_CJReportLost(c, j) == flt.rl < MaxReportLost /\ CJReportLost(c, j) /\ Inc("rl")
W_ClientAbort(c, j) == ClientAbort(c, j) /\ Keep
W_HeartbeatAbort(c, j) == HeartbeatAbort(c, j) /\ Keep
W_HeartbeatMissing(c, j) == HeartbeatMissing(c, j) /\ Keep

MCNext ==
    \/ W_RunnerScanList \/ W_RunnerScanRead \/ W_RunnerSchedule \/ W_RunnerNoSchedule
    \/ W_RunnerCheckSubmitted \/ W_RunnerDeploy \/ W_RunnerSetDispatched
    \/ W_RunnerUpdateMetaRead \/ W_RunnerUpdateMetaWrite \/ W_RunnerCheckDispatched
    \/ W_RunnerStartSJ \/ W_RunnerCollectStart \/ W_RunnerAddRunning \/ W_RunnerSetRunning
    \/ W_RunnerExcCleanup \/ W_RunnerExcSetFailed \/ W_RunnerExcFinish
    \/ F_RunnerNoResource \/ F_RunnerServerDeployFail \/ F_RunnerClientDeployFail
    \/ F_RunnerStartSJFail \/ F_RunnerCollectStartTimeout
    \/ \E j \in Jobs :
          \/ W_CompleteClassify(j) \/ W_CompletePublish(j) \/ F_CompleteAfterOutcomeDeadline(j)
          \/ W_SJExitNormal(j) \/ W_SJExitAborted(j) \/ W_RemoveRunProcesses(j) \/ F_SJExitFail(j)
          \/ W_AdminAbortRead(j) \/ W_AdminAbortAct(j) \/ W_AdminAbortMark(j)
          \/ W_AdminDeleteSnap(j) \/ W_AdminDeleteAct(j)
    \/ \E c \in Clients, j \in Jobs :
          \/ W_ClientStartOk(c, j) \/ F_ClientStartErr(c, j)
          \/ W_CJExitNormal(c, j) \/ F_CJExitFail(c, j)
          \/ W_CJReport(c, j) \/ F_CJReportLost(c, j)
          \/ W_ClientAbort(c, j) \/ W_HeartbeatAbort(c, j) \/ W_HeartbeatMissing(c, j)

MCSpec == MCInit /\ [][MCNext]_mcVars

ClientSymmetry == Permutations(Clients)

\* ---- Explicit timing assumption (fault/timing assumption, NOT a code guard) ----
\* The runner's set_status(RUNNING) (job_runner.py:711) completes before the completion loop
\* classifies the same job. Used only in *_assume*.cfg to look past candidate MC-4a.
AssumePromptRunningWrite == (rn.pc = "setRun") => (comp'[rn.job] = comp[rn.job])

\* mark_run_aborted (job_runner.py:802-811) runs before the aborted job is classified by the
\* completion loop (i.e. stop_run's two steps are effectively back-to-back). Used only to look past
\* candidate MC-4b.
AssumePromptAbortMark == \A j \in Jobs : (abortPc[j] = "mark") => (comp'[j] = comp[j])

AssumeBoth == AssumePromptRunningWrite /\ AssumePromptAbortMark

=============================================================================
