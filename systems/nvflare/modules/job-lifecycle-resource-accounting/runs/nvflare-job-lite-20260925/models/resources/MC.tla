-------------------------------- MODULE MC --------------------------------
(* Model-checking wrapper for the resource-ownership model: fault actions  *)
(* are counter-bounded; reactive/normal actions are not.                   *)
EXTENDS base

CONSTANTS
    MaxCheckTimeout,    \* CHECK_RESOURCE reply timeouts
    MaxSkip,            \* runner `continue` after an admin abort (not SUBMITTED / not DISPATCHED)
    MaxDeployFail,      \* partial client deploy failures + server deploy failures
    MaxSJLaunchFail,    \* SJ launch failures
    MaxStartTimeout,    \* START_JOB reply timeouts
    MaxExpireInUse,     \* reservation expiry before START (scheduling->start > expiration_period)
    MaxLaunchFail       \* client launcher failures

VARIABLE flt
mcVars == <<vars, flt>>

MCInit == Init /\ flt = [ct |-> 0, sk |-> 0, df |-> 0, sl |-> 0, st |-> 0, ex |-> 0, lf |-> 0]
Inc(f) == flt' = [flt EXCEPT ![f] = @ + 1]
Keep == UNCHANGED flt

W_RunnerSendCheck == RunnerSendCheck /\ Keep
W_RunnerCollectCheck == RunnerCollectCheck /\ Keep
F_RunnerCollectCheckTimeout == flt.ct < MaxCheckTimeout /\ RunnerCollectCheckTimeout /\ Inc("ct")
F_RunnerSkipNotSubmitted == flt.sk < MaxSkip /\ RunnerSkipNotSubmitted /\ Inc("sk")
W_RunnerDeploy == RunnerDeploy /\ Keep
F_RunnerDeployPartial == flt.df < MaxDeployFail /\ RunnerDeployPartial /\ Inc("df")
F_RunnerServerDeployFail == flt.df < MaxDeployFail /\ RunnerServerDeployFail /\ Inc("df")
F_RunnerSkipNotDispatched == flt.sk < MaxSkip /\ RunnerSkipNotDispatched /\ Inc("sk")
W_RunnerPassDispatched == RunnerPassDispatched /\ Keep
W_RunnerStartJob == RunnerStartJob /\ Keep
F_RunnerStartSJFail == flt.sl < MaxSJLaunchFail /\ RunnerStartSJFail /\ Inc("sl")
W_RunnerCollectStart == RunnerCollectStart /\ Keep
F_RunnerCollectStartTimeout == flt.st < MaxStartTimeout /\ RunnerCollectStartTimeout /\ Inc("st")
W_RunnerExc == RunnerExc /\ Keep
W_ServerJobEnd(j) == ServerJobEnd(j) /\ Keep
W_ClientCheck(c, t) == ClientCheck(c, t) /\ Keep
W_ClientCancel(c, t) == ClientCancel(c, t) /\ Keep
W_ExpireAbandoned(c, t) == ExpireAbandoned(c, t) /\ Keep
F_ExpireInUse(c, t) == flt.ex < MaxExpireInUse /\ ExpireInUse(c, t) /\ Inc("ex")
W_ClientStartAlloc(c, t) == ClientStartAlloc(c, t) /\ Keep
W_ClientStartAppEarlyReturn(c, j) == ClientStartAppEarlyReturn(c, j) /\ Keep
W_ClientStartRegister(c, j) == ClientStartRegister(c, j) /\ Keep
W_ClientStartLaunch(c, j) == ClientStartLaunch(c, j) /\ Keep
F_ClientStartLaunchFail(c, j) == flt.lf < MaxLaunchFail /\ ClientStartLaunchFail(c, j) /\ Inc("lf")
W_CJExit(c, j) == CJExit(c, j) /\ Keep
W_WaiterFree(c, j) == WaiterFree(c, j) /\ Keep
W_ClientAbort(c, j) == ClientAbort(c, j) /\ Keep
W_HeartbeatAbort(c, j) == HeartbeatAbort(c, j) /\ Keep

MCNext ==
    \/ W_RunnerSendCheck \/ W_RunnerCollectCheck \/ F_RunnerCollectCheckTimeout
    \/ F_RunnerSkipNotSubmitted \/ W_RunnerDeploy \/ F_RunnerDeployPartial \/ F_RunnerServerDeployFail
    \/ F_RunnerSkipNotDispatched \/ W_RunnerPassDispatched
    \/ W_RunnerStartJob \/ F_RunnerStartSJFail \/ W_RunnerCollectStart \/ F_RunnerCollectStartTimeout \/ W_RunnerExc
    \/ \E j \in Jobs : W_ServerJobEnd(j)
    \/ \E c \in Clients :
          \/ \E t \in Tokens : W_ClientCheck(c, t) \/ W_ClientCancel(c, t) \/ W_ExpireAbandoned(c, t)
                               \/ F_ExpireInUse(c, t) \/ W_ClientStartAlloc(c, t)
          \/ \E j \in Jobs : W_ClientStartAppEarlyReturn(c, j) \/ W_ClientStartRegister(c, j)
                             \/ W_ClientStartLaunch(c, j) \/ F_ClientStartLaunchFail(c, j)
                             \/ W_CJExit(c, j) \/ W_WaiterFree(c, j) \/ W_ClientAbort(c, j) \/ W_HeartbeatAbort(c, j)

MCSpec == MCInit /\ [][MCNext]_mcVars
ClientSymmetry == Permutations(Clients)
=============================================================================
