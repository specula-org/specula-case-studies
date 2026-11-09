------------------------------ MODULE WitV11 ------------------------------
\* v11 smoke witnesses (DESIGN 16.10): each is an invariant whose VIOLATION means
\* the named situation was reached (reachability witness, not a property).
EXTENDS Ports
Pm == pModel
HasArt(k) == SJModel /\ Pm.artifact.kind = k
\* --- common
WTerminal == pJobSP.terminal = "none"
WFinished == pJobSP.terminal /= "FINISHED"
WFailedJob == pJobSP.terminal /= "ABORTED_OR_FAILED"
WRound2 == pWfSJ.scheduled < 2
\* --- A (sjModel)
WAccepted == ~(SJModel /\ \E r \in Attempts, c \in Sites : Pm.acc[r][c] = "accepted")
WRejected == ~(SJModel /\ \E r \in Attempts, c \in Sites : Pm.acc[r][c] = "rejected")
WPartial == ~(SJModel /\ Pm.poisoned /= {})
WAggPoisoned == ~(SJModel /\ \E r \in Attempts : Pm.agg[r] = "poisoned")
WAggEmpty == ~(SJModel /\ \E r \in Attempts : Pm.agg[r] = "empty")
WAggRaisePanic == ~(SJModel /\ pWfSJ.panic /\ \E r \in Pm.poisoned : Pm.agg[r] = "none" /\ pWfSJ.scheduled = r
                    /\ pWfSJ.returned = "error" /\ pCommSJ.round = r /\ ~pCommSJ.standing)
WArtClean == ~HasArt("clean")
WArtPoisoned == ~HasArt("poisoned")
WArtStale == ~HasArt("stale")
WArtCorrupt == ~HasArt("corrupt")
WSaveFailPanic == ~(SJModel /\ pWfSJ.returned = "error" /\ Pm.artifact.kind /= "initial" /\ ~pWfSJ.saved)
\* the FedAvg guard: a poisoned round fails the job instead of publishing
WFedPoisonFailed == ~(SJModel /\ WfPolicy = "fedavg" /\ Pm.poisoned /= {}
                      /\ pJobSP.terminal = "ABORTED_OR_FAILED")
\* --- B
WFinishedPoisoned == ~(pJobSP.terminal = "FINISHED" /\ HasArt("poisoned"))
WRaised == ~(RaiseTracked /\ pWfSJ.raised /= {})
WCycStop == ~(WfPolicy = "cyclic" /\ pWfSJ.wfDone)
WCycStopFinished == ~(WfPolicy = "cyclic" /\ pWfSJ.wfDone /\ pJobSP.terminal = "FINISHED")
WCseDone == ~(WfPolicy = "cseServer" /\ pWfSJ.returned = "normal")
WMonitorDead == ~pCommSJ.monitorCrashed
\* --- D (swarm)
Sw(c) == pSwarm[c][1]
WSwAgg2 == ~(SwarmOn /\ \E c \in Sites : Sw(c).aggregated[SwarmRounds] /= None)
WSwH05 == ~(SwarmOn /\ \E c \in Sites : Sw(c).gather /= None /\ Sw(c).gather.done
                                       /\ Sw(c).gather.gathered /= Sw(c).gather.replied)
WSwH06 == ~(SwarmOn /\ \E c \in Sites : Sw(c).stopped /\ Sw(c).learn.st = "aborted" /\ ~Sw(c).ended)
WSwH06Finished == ~(SwarmOn /\ pJobSP.terminal = "FINISHED" /\ \E c \in Sites : Sw(c).learn.st = "aborted")
WSwErrPanic == ~(SwarmOn /\ pWfSJ.panic /\ \E c \in Sites : Sw(c).report.error)
WSwPanicNoErr == ~(SwarmOn /\ pWfSJ.panic /\ pWfSJ.cw = "monitor" /\ \A c \in Sites : ~Sw(c).report.error)
WSwCfgPanic == ~(SwarmOn /\ pWfSJ.panic /\ pWfSJ.cw = "init" /\ \A c \in Sites : ~Sw(c).report.error)
WSwProgress == ~(SwarmOn /\ pWfSJ.panic /\ pWfSJ.cw = "monitor" /\ \E c \in Sites : CJGone(c, 1))
WSwMonCrash == ~(SwarmOn /\ pWfSJ.cw = "monitor" /\ \E c \in Sites : CJGone(c, 1))
WSwMonitor == ~(SwarmOn /\ pWfSJ.cw = "monitor")
WSwAllDoneSeen == ~(SwarmOn /\ pWfSJ.cw = "monitor" /\ \E k \in DOMAIN net : InInbox(k, SJ, "SWARM_STATUS") /\ M(k).body.allDone)
WSwEnding == ~(SwarmOn /\ pWfSJ.cw = "ending")
WSwEndLost == ~(SwarmOn /\ pWfSJ.cw = "ending" /\ \E k \in DOMAIN net : net[k].lost)
WSwEndFail == ~(SwarmOn /\ pWfSJ.panic /\ pWfSJ.cw = "ending")
WSwGatherTimeoutPartial == ~(SwarmOn /\ \E c \in Sites, r \in 1..SwarmRounds :
                                Sw(c).aggregated[r] /= None /\ Sw(c).aggregated[r] /= Sites)
\* --- E (k8sJob / dockerJob)
WOrphanCJ == ~(CJContainer /\ \E c \in Sites, l \in Launches : CPRestarted(c) /\ CJAlive(c, l))
WFreeWhileAlive == ~(\E c \in Sites : pJobCP[c].freed > 0 /\ \E l \in Launches : CJAlive(c, l))
WPubDone == ~("k8sJob" \in Profile /\ \E c \in Sites, l \in Launches : pJobCP[c].pub[l] = "done")
WWsLost == ~("k8sJob" \in Profile /\ \E c \in Sites : pJobCP[c].wsLost /= {})
\* the orphan CJ finished the workflow (model saved, CJ exited ok), yet the job
\* is recorded as failed (the restarted CP never reports its outcome)
WOrphanFail == ~(CJContainer /\ pWfSJ.saved /\ pJobSP.terminal = "ABORTED_OR_FAILED"
                 /\ \E c \in Sites : CPRestarted(c) /\ pRunCJ[c][1].exit = "ok")
WRelaunch == ~(\E c \in Sites : CurLaunch(c) >= 2)
\* --- F (multiJobCP)
WJ2Running == ~(MultiJobCP /\ \E c \in Sites : pJobCP[c].j2.st = "running")
WJ2Freed == ~(MultiJobCP /\ \E c \in Sites : pJobCP[c].j2.st = "freed")
WJ2Restart == ~(MultiJobCP /\ \E c \in Sites : pJobCP[c].j2.launch = 2)
WCheckBusy == ~(MultiJobCP /\ \E k \in DOMAIN net : net[k].msg.kind = "RESOURCES_OK" /\ net[k].msg.body = "no")
WCantSchedule == ~(MultiJobCP /\ pJobSP.status = "CANT_SCHEDULE")
WCPRestartBoth == ~(MultiJobCP /\ \E c \in Sites : CPRestarted(c) /\ pJobCP[c].j2.st = "exited" /\ ~pJobCP[c].j2.alloc
                                                    /\ \E l \in Launches : CJGone(c, l))
=============================================================================
