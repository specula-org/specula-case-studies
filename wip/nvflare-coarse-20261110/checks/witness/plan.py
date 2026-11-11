# Directed witnesses (bug-specific predicates, used ONLY to classify calibration misses as
# "reachable by a directed witness" vs "unreachable"; never part of the sweep or of spec/).
# Each: config of plans/calib.py, faults (may be several), phase to start from, and a property
# whose violation means "reached".
W = {
 "C1-A": dict(config="fedavg", faults=["storeError", "sjCrash"], phase=1,
              act='[][~(pJobSP.status \\in JobTerminalStatuses /\\ pJobSP.status /= "FAILED_TO_RUN" /\\ pJobSP\'.status = "FAILED_TO_RUN")]_portVars'),
 "C1-B": dict(config="fedavg", faults=["storeError", "sjCrash"], phase=1, inv='pJobSP.completionCrashed = "no"'),
 "N2":   dict(config="fedavg", faults=["deadClient"], phase=2,
              inv='~(Terminal /\\ WfCompleted /\\ pJobSP.status /= "COMPLETED" /\\ pCommSJ.panic)'),
 "S1":   dict(config="multijob", faults=["spShutdown", "slowShutdownAbort"], phase=2,
              act='[][~(jobSP_c.shut = "loop" /\\ jobSP_c\'.shut = "done" /\\ jobSP_c.registered /\\ ~jobSP_c.shutStopped)]_<<jobSP_c>>'),
 "S4":   dict(config="fedavg", faults=["spShutdown"], phase=0,
              act='[][~(jobSP_c.shut \\in {"done", "exited"} /\\ ~pJobSP.sjLaunched /\\ pJobSP\'.sjLaunched)]_<<jobSP_c, pJobSP>>'),
 "V7":   dict(config="k8s", faults=["cpCrash", "rpcTimeout"], phase=2,
              inv='~(Terminal /\\ pJobSP.status /= "COMPLETED" /\\ WfCompleted /\\ (\\E c \\in Sites : CPRestarted(c)) /\\ \\A c \\in pJobSP.startSent : pRunCJ[c][CurLaunch(c)].exit = "ok")'),
 "H06":  dict(config="swarm", faults=["busyReplace", "gatherTimeout"], phase=2,
              inv='\\A c \\in Sites, l \\in Launches : pSwarm[c][l].stopBy /= "event"'),
 "H07":  dict(config="k8s", faults=["slowPublish", "cjCrash"], phase=2, inv='\\A c \\in Sites : pJobCP[c].wsLost = {}'),
 "H03":  dict(config="external", faults=["tpSilent", "monitorStale"], phase=2,
              inv='\\A c \\in Sites, l \\in Launches : pTrainer[c][l].lostSrc \\subseteq pTrainer[c][l].notified'),
 "H04":  dict(config="sag", faults=["acceptRaise"], phase=2,
              inv='~(Completed /\\ pModel.artifact.kind = "poisoned")'),
 # re-checks after the corrections M5 (resend evidence) and M6 (priced gather window)
 "H11-resendEvidence": dict(config="cse", faults=["netLoss", "submitTimeout"], phase=2, inv='~CommSJ_C!Resent'),
 "H11-afterM5": dict(config="cse", faults=["netLoss", "submitTimeout"], phase=2, inv='pCommSJ.monitorCrashed = "no"'),
 "H05-afterM6": dict(config="swarm", faults=["gatherRace"], phase=2, inv='GatherExact'),
 "S1": dict(config="multijob", faults=["spShutdown", "slowShutdownAbort"], phase=2,
            act='[][~(jobSP_c.shut = "loop" /\\ jobSP_c\'.shut = "done" /\\ jobSP_c.registered /\\ ~jobSP_c.shutStopped)]_<<jobSP_c>>'),
}
