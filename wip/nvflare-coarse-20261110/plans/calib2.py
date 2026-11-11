# Calibration pass 2: the same cells, with the model corrections of pass 1 and filters for
# the mechanisms pass 1 already attributed (triage only; STANDARD 10: filters live outside spec/).
import runpy
_c = runpy.run_path(__file__.replace("calib2.py", "calib.py"))
DEPS = _c["DEPS"]; CONFIGS = _c["CONFIGS"]
CONFIGS["multijob"] = dict(CONFIGS["multijob"], sites=1, points=CONFIGS["multijob"]["points"] + ["slowShutdownAbort"])
# one site is enough for these mechanisms and keeps the BFS within its time budget
for _k in ("sag", "fedmodel", "nonstrict"):
    CONFIGS[_k] = dict(CONFIGS[_k], sites=1)
CONFIGS["swarm"] = dict(CONFIGS["swarm"], points=CONFIGS["swarm"]["points"] + ["gatherRace"])
BUDGET_EXTRA = 2      # rare budget = 2 * w(point) + sum w(deps) + BUDGET_EXTRA
FILTERS = {
    # a delayed RUNNING write over a published terminal status
    "runningOverTerminal": 'pJobSP.status = "RUNNING" /\\ pJobSP.terminal /= "none"',
    # restarted SP: no startup recovery of DISPATCHED / RUNNING jobs
    "noRecoveryAfterSPRestart": 'pJobSP.spRestarted /\\ pJobSP.status \\in {"RUNNING", "DISPATCHED"}',
    # model gap: re-scheduling of a SUBMITTED job after an SP restart is not modeled
    "gapSubmittedAfterRestart": 'pJobSP.spRestarted /\\ pJobSP.status = "SUBMITTED"',
    # restarted CP: the SJ is never told that the client's job died (hang)
    "noDeadJobNoticeAfterCPRestart": '(\\E c \\in Sites : CPRestarted(c)) /\\ pJobSP.status = "RUNNING" /\\ ~pJobSP.spRestarted',
    # scheduler thread killed by a delete during its scan
    "schedulerDiesOnScan": 'pJobSP.schedulerCrashed = "JobSP.sched.scan"',
    # scheduler thread killed by its own except branch on a job deleted during deployment
    "schedulerDiesInExcept": 'pJobSP.schedulerCrashed = "JobSP.runner.except"',
    # cleanup thread: a listed token replaced by a re-login / registry iterated during a login
    "cleanupDiesOnReplacedToken": 'pReg.cleanupCrashed = "Reg.cleanup.logoutNone"',
    "cleanupDiesOnIteration": 'pReg.cleanupCrashed = "Reg.cleanup.iterate"',
    # a container CJ outlives a CP restart with no allocation record
    "containerCJWithoutAllocation": 'CJContainer /\\ \\E c \\in Sites : CPRestarted(c) /\\ Live(c) /= {} /\\ ~pJobCP[c].allocated',
    # an allocation freed while its CJ (process or Pod) still runs (rollback after a failed
    # waiter start; a Pod delete that failed but was treated as terminated)
    "freedWhileRunning": '\\E c \\in Sites : pJobCP[c].freed > 0 /\\ Live(c) /= {}',
    # the task monitor died on a duplicated ClientTask
    "monitorDiesOnDuplicate": 'pCommSJ.monitorCrashed',
    # a contribution accepted after its gather closed
    "acceptAfterGatherClosed": '~GatherExact',
    # attach send() reported success for a rejected result
    "ackWithoutAcceptance": '~S6AckMeansDone',
    # cleanup thread: run_processes changed size while the notify loop iterated it
    "cleanupDiesOnNotifyIteration": 'pReg.cleanupCrashed = "Reg.cleanup.notifyIterate"',
    # timing escape artifact: an admin stop slower than the 10 s terminate grace
    "adminStopEscape": 'Completed /\\ ~WfCompleted /\\ pJobSP.stopReq = "admin"',
    # a panicked run classified COMPLETED (lost status message)
    "completedAfterPanic": 'Completed /\\ SJPanicked',
    # a relaunch inherits the other job's GPU through the CP-global environment
    "relaunchInheritsOtherJobGPU": '\\E c \\in Sites : (MultiJobCP /\\ pJobCP[c].j2.gpu = 1) \\/ \\E l \\in Launches : pJobCP[c].gpu[l] = 2',
}

# pass 3: more phases (checkpoints closer to the end of the job): 1 dispatched, 3 first result
for _k, _c in CONFIGS.items():
    CONFIGS[_k] = dict(_c, phases=[0, 1, 2, 3, 4, 5] if _c["attempt"] >= 2 else [0, 1, 2, 3, 5])
