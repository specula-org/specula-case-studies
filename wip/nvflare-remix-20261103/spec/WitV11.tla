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
=============================================================================
