------------------------------ MODULE StdProps ------------------------------
\* Generic properties of STANDARD.md section 7, split into items: a sweep filter
\* exempts exactly the items it names (STANDARD 10, v4). Ports only, plus the
\* quiescence test Q (QNext is generated into MixR by scripts/rarity.py: every step
\* of the composition with the fault set replaced by QFaults = the default-
\* deployment timers). None of these names a known bug. Each item's severity class
\* is in STANDARD 7 (server / data / job / status).
EXTENDS MixR

Terminal == pJobSP.status \in JobTerminalStatuses
Completed == pJobSP.status = "COMPLETED"
Started(c) == c \in pJobSP.startSent
Live(c) == {l \in Launches : CJAlive(c, l)}

\* Q: nothing but priced faults can move (default timers count as moves); states
\* at a finite-instance bound are not quiescent.
Q == ~AtBoundAny /\ ~ENABLED QNext

\* what actually happened (truth predicates over ports)
WfCompleted == pWfSJ.returned = "normal" /\ pWfSJ.saved /\ ~pWfSJ.panic
ProcsEndedOK == /\ pWfSJ.sj = "exited" /\ ~SJFatal /\ ~SJKilled /\ ~SPRestarted /\ ~SPDown
                /\ \A c \in pJobSP.startSent :
                     CurLaunch(c) > 0 => pRunCJ[c][CurLaunch(c)].exit = "ok"
NoStopRequest == pJobSP.stopReq = "none"
OtherJobsDone == pJobSP.other \notin {"queued", "running", "exited"}

\* ---------------- Q items: consequences at quiescence (checked only where Q holds)
Q1c == (Terminal \/ pJobSP.deleted) /\ OtherJobsDone                          \* job
Q2c == Terminal /\ WfCompleted /\ NoStopRequest /\ ProcsEndedOK => Completed  \* status
Q3c == \A c \in Sites : ~pJobCP[c].allocated /\ (MultiJobCP => ~pJobCP[c].j2.alloc)   \* job
Q4c == /\ ~SJAlive                                                            \* job
       /\ \A c \in Sites : Live(c) = {}
       /\ TaskMode => \A c \in Sites, w \in WAttempts : ~PodLive(pWorker[c].pod[w])
\* all Q items in one invariant, so ENABLED QNext is evaluated once per state; fi is
\* the filter that exempts item i (FALSE: none)
QAllF(f1, f2, f3, f4) == (/\ (Q1c \/ f1) /\ (Q2c \/ f2) /\ (Q3c \/ f3) /\ (Q4c \/ f4)) \/ ~Q
QAll == QAllF(FALSE, FALSE, FALSE, FALSE)
Q1Terminal == Q => Q1c
Q2StatusAgrees == Q => Q2c
Q3Released == Q => Q3c
Q4NoOrphan == Q => Q4c

\* ---------------- S items: every state
\* thread items: every long-lived thread is alive
S1Sched   == pJobSP.schedulerCrashed = "no"          \* server
S1Compl   == pJobSP.completionCrashed = "no"         \* server
S1Cleanup == pReg.cleanupCrashed = "no"              \* server
S1Monitor == pCommSJ.monitorCrashed = "no"           \* job (one job's SJ thread)
S1ThreadsAlive == S1Sched /\ S1Compl /\ S1Cleanup /\ S1Monitor
\* S2TerminalFinal: a terminal status, once written, is not changed (action property)  \* status
S2TerminalFinal == [][Terminal => pJobSP'.status = pJobSP.status]_portVars
S2F(f) == [][Terminal => (pJobSP'.status = pJobSP.status \/ f')]_portVars
\* resource items (job)
S3Alloc    == \A c \in Sites : Live(c) /= {} => pJobCP[c].allocated
S3Gpu      == \A c \in Sites : \A l \in Live(c) : pJobCP[c].gpu[l] = 1
S3J2Gpu    == \A c \in Sites : MultiJobCP /\ pJobCP[c].j2.st = "running" => pJobCP[c].j2.gpu = 2
S3FreeOnce == \A c \in Sites : pJobCP[c].freed <= 1
S3Resources == S3Alloc /\ S3Gpu /\ S3J2Gpu /\ S3FreeOnce
\* output items: no lost result, outputs delivered (data); a COMPLETED status is right (status)
\* a round's aggregate is exactly the contributions accepted for that round
S4Aggregate == pWfSJ.aggregate /= None =>
    pWfSJ.aggregate = {pPayRcv[c].rx[pWfSJ.scheduled].materialized : c \in pWfSJ.accepted}
\* every contribution that entered a closed gather is in that round's aggregate
S4Gather == SwarmOn => \A c \in Sites, l \in Launches :
    LET G == pSwarm[c][l].gather IN
    (G /= None /\ G.done) => G.gathered \subseteq pSwarm[c][l].aggregated[G.r]
\* the saved model of a COMPLETED job holds no half-added contribution, is not broken
S4Artifact == Completed /\ SJModel => pModel.artifact.kind \in {"initial", "clean", "stale"}
\* a COMPLETED job returned every client's workspace results (K8s publish)
S4OutputsDelivered == Completed /\ K8sJob => \A c \in pJobSP.startSent : CurLaunch(c) \notin pJobCP[c].wsLost
\* COMPLETED: the workflow returned normally and saved, no panic anywhere (a stop
\* request that arrives after the workflow completed does not make COMPLETED wrong)
S4CompletedWf == Completed => WfCompleted /\ ~SJPanicked                     \* status
S4NoLostResult == S4Aggregate /\ S4Gather
S4Completed == S4CompletedWf /\ S4Artifact
\* S5StatusMeaning: status meaning (FAILED_TO_RUN means "the startup raised", whatever had started
\* already, job_runner.py:770-800; FAILED_TO_RUN over a published status is the S2TerminalFinal item's)  \* status
S5StatusMeaning == pJobSP.status = "CANT_SCHEDULE" => ~pJobSP.sjLaunched /\ pJobSP.startSent = {}
\* S6AckMeansDone: a success reply means the callee did it (attach trainer)                  \* status
S6AckMeansDone == \A c \in Sites, l \in Launches : pTrainer[c][l].acked \subseteq pTrainer[c][l].taken
\* S7StopHasSource: a unit stops only because another unit asked it to, or it failed itself      \* job
S7StopHasSource == SwarmOn => \A c \in Sites, l \in Launches : pSwarm[c][l].stopBy \in {"none", "endRun", "endWf"}
\* S8LossNotified: when a result source others still depend on is torn down, they are told     \* job
S8LossNotified == \A c \in Sites, l \in Launches : pTrainer[c][l].lostSrc \subseteq pTrainer[c][l].notified

\* the items a sweep checks (Q items are checked together in QAll)
StdItems == <<"S1Sched", "S1Compl", "S1Cleanup", "S1Monitor", "S3Alloc", "S3Gpu", "S3J2Gpu",
              "S3FreeOnce", "S4Aggregate", "S4Gather", "S4Artifact", "S4OutputsDelivered",
              "S4CompletedWf", "S5StatusMeaning", "S6AckMeansDone", "S7StopHasSource", "S8LossNotified">>
QItems == <<"Q1c", "Q2c", "Q3c", "Q4c">>
=============================================================================
