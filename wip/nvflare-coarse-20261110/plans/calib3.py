# Every filter is an "it happened" predicate: TRUE only in states after the attributed cause
# occurred (a filter that also holds in normal states would mask every property).
# Calibration pass 3b (and the filter set for later blocks): the pass-3 configuration with
# CAUSE-level filters only (STANDARD 10, v3). Each filter matches a cause record written by the
# action that embodies the cause (a ledger id), or a port signature unique to one mechanism.
import runpy
_c = runpy.run_path(__file__.replace("calib3.py", "calib2.py"))
DEPS = {k: v for k, v in _c["DEPS"].items() if k != "slowShutdownExit"}
CONFIGS = _c["CONFIGS"]; BUDGET_EXTRA = _c["BUDGET_EXTRA"]
FILTERS = {
    # JobSP.runner.writeRunning: the RUNNING write replaced a published terminal status
    "overwriteByWriteRunning": 'pJobSP.overwrite = "JobSP.runner.writeRunning"',
    # JobSP.proc.SP (no startup recovery): the status was written by the previous SP incarnation
    "staleStatusFromOldSP": 'pJobSP.spRestarted /\\ pJobSP.statusGen = 0 /\\ pJobSP.status \\in {"RUNNING", "DISPATCHED", "SUBMITTED"}',
    # JobSP.admin.shutdownLoop: ask_to_stop ended the completion thread with a stopped job not finalized
    "shutdownLeftUnfinalized": 'pJobSP.unfinalized = "JobSP.admin.shutdownLoop" /\\ pJobSP.status = "RUNNING"',
    # Reg.hb.jobSync (R-replaced): no dead-job notice for a site whose token generation changed
    "noticeMissedReplacedToken": '\\E c \\in Sites : CPRestarted(c) /\\ pReg.tok[c] > 1 /\\ <<c, 1>> \\notin pReg.notified /\\ ~CJContainer',
    # thread deaths, by the ledger id of the failing operation
    "schedulerDiesOnScan": 'pJobSP.schedulerCrashed = "JobSP.sched.scan"',
    "schedulerDiesInExcept": 'pJobSP.schedulerCrashed = "JobSP.runner.except"',
    "cleanupDiesOnReplacedToken": 'pReg.cleanupCrashed = "Reg.cleanup.logoutNone"',
    "cleanupDiesOnIteration": 'pReg.cleanupCrashed = "Reg.cleanup.iterate"',
    "cleanupDiesOnNotifyIteration": 'pReg.cleanupCrashed = "Reg.cleanup.notifyIterate"',
    "monitorDiesOnDuplicate": 'pCommSJ.monitorCrashed = "CommSJ.wfc.resendDup"',
    # JobCP.container.lifetime: a container CJ outlived a CP restart that forgot its allocation
    "containerCJWithoutAllocation": 'CJContainer /\\ \\E c \\in Sites : CPRestarted(c) /\\ Live(c) /= {} /\\ ~pJobCP[c].allocated',
    # JobCP.exec.startApp (FA): the rollback freed the allocation of a spawned CJ
    "rollbackFreedLiveCJ": '\\E c \\in Sites : pJobCP[c].freedBy = "JobCP.exec.startApp" /\\ Live(c) /= {}',
    # JobCP.k8s.terminate (FB treated as done): the Pod may run after its records were released
    "podDeleteFailedTreatedDone": '\\E c \\in Sites : pJobCP[c].endBy = "JobCP.k8s.terminate" /\\ Live(c) /= {}',
    # JobSP.engine.waiter: the panicked SJ's exit was observed without its status message
    "exitWithoutStatus": 'pJobSP.exitObs = "JobSP.engine.waiter" /\\ Completed',
    # JobCP.res.gpuEnv: a launch copied the other job's unit from the CP-global environment
    "relaunchInheritsOtherJobGPU": '\\E c \\in Sites : (MultiJobCP /\\ pJobCP[c].j2.gpu = 1) \\/ \\E l \\in Launches : pJobCP[c].gpu[l] = 2',
    # Swarm.gather.done (check-then-act): contributions accepted after a close that raced them
    "acceptAfterRacedClose": 'SwarmOn /\\ \\E c \\in Sites, l \\in Launches : LET G == pSwarm[c][l].gather IN G /= None /\\ G.done /\\ G.gathered \\ pSwarm[c][l].aggregated[G.r] /= {} /\\ G.gathered \\ pSwarm[c][l].aggregated[G.r] \\subseteq G.raced',
    # Trainer.att.publish: a success the trainer inferred after both rejection replies were lost
    "inferredAck": '\\E c \\in Sites, l \\in Launches : pTrainer[c][l].acked \\ pTrainer[c][l].taken /= {} /\\ pTrainer[c][l].acked \\ pTrainer[c][l].taken \\subseteq pTrainer[c][l].ackInferred',
    # JobSP.engine.abort (TA2 escape): a terminate that overtook an admin stop in progress
    "terminateOvertookAdminStop": 'pJobSP.termEarly = "JobSP.engine.abort" /\\ Completed',
}
