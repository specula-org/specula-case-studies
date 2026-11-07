---------------------------- MODULE GenericProps ----------------------------
\* Hypothesis-FREE properties: none of these is derived from a Phase 1 hazard.
\* They state what any job runtime should guarantee (termination consistency,
\* resource conservation, at-most-once observations, process hygiene), over
\* stable port fields only, so they are meaningful in every mix. A violation
\* is a lead to triage (model artifact vs. candidate), not a bug by itself.
EXTENDS Ports

Started(c) == c \in pJobSP.startSent
Terminal == pJobSP.terminal /= "none"
Finished == pJobSP.terminal = "FINISHED"
LiveLaunches(c) == {l \in Launches : CJAlive(c, l)}

\* ---------------- G1 terminal decisions are final (action properties)
GTerminalStable == [][Terminal => pJobSP'.terminal = pJobSP.terminal]_portVars
GStatusStable   == [][pJobSP.status \in JobTerminalStatuses => pJobSP'.status = pJobSP.status]_portVars
\* an outcome recorded for a site is never rewritten
GOutcomeStable  == [][\A c \in Sites : pJobSP.outcomes[c] /= "none" =>
                        pJobSP'.outcomes[c] = pJobSP.outcomes[c]]_portVars
\* process exit facts never change once set (model sanity, all groups)
GExitStable     == [][\A c \in Sites, l \in Launches : pRunCJ[c][l].exit /= "none" =>
                        pRunCJ'[c][l].exit = pRunCJ[c][l].exit]_portVars
GGenerical == GTerminalStable /\ GStatusStable /\ GOutcomeStable /\ GExitStable

\* ---------------- G1b server worker threads do not die of exceptions
GCompletionThreadAlive == ~pJobSP.completionCrashed
GTaskMonitorAlive == ~pCommSJ.monitorCrashed
GSchedulerThreadAlive == ~pJobSP.schedulerCrashed
\* after an SP restart, once no process of the job is left, the stored status
\* must not still claim the job is dispatched or running (R1)
JobProcessesGone == ~SJAlive /\ \A c \in Sites, l \in Launches : ~CJAlive(c, l)
GNoStaleStatusAfterRestart == pJobSP.spRestarted /\ JobProcessesGone =>
                                 pJobSP.status /= "RUNNING"   \* a stale DISPATCHED can still be aborted

\* ---------------- G2 a FINISHED job is consistent with what happened
\* no process of a finished job died abnormally in its final incarnation
GFinishedNoAbnormalExit == Finished =>
    /\ ~SJFatal /\ SJExitCode /= "crashed"
    /\ \A c \in Sites : Started(c) /\ CurLaunch(c) > 0 =>
         CJExitCode(c, CurLaunch(c)) \in {"none", "ok"}
\* v8 multiJob: the other job J2 can still be finalized. Only the single
\* completion thread finalizes a job; once it died (C1-B) a J2 that is queued,
\* running or exited never reaches a terminal status (a livelock, not a deadlock)
GOtherJobFinalizable == ~(pJobSP.completionCrashed /\ pJobSP.other \in {"queued", "running", "exited"})
\* the SP's client cleanup thread is alive (v8, T2/T3): otherwise dead clients
\* are never removed and no SJ is told about them again
GCleanupThreadAlive == pReg.cleanupCrashed = "no"
\* the same, with the known T2 death (re-login during the logout loop) excluded
GCleanupThreadAliveK == pReg.cleanupCrashed \in {"no", "relogin"}
\* a job reported COMPLETED had no fatal error in its server run (v7, L13)
GFinishedNoPanic == Finished => ~SJPanicked
\* the same with the known L13 escape (statusLost) excluded, for hunts
GFinishedNoPanicK8 == "statusLost" \notin Faults => GFinishedNoPanic
\* a finished job leaves no running client job process behind
GFinishedNoLiveChild == Finished => \A c \in Sites : LiveLaunches(c) = {}
\* a terminal job has no running server job process. Excluded: FAILED_TO_RUN,
\* which the start-failure path writes right after an asynchronous server abort
\* (job_runner.py:777-800; server_engine.py:355-384: ABORT with 1 s timeout,
\* then a cleanup thread waits up to 10 s before terminate) -- by design.
GTerminalNoLiveSJ == Terminal /\ pJobSP.sjLaunched /\ pJobSP.status /= "FAILED_TO_RUN" => ~SJAlive
\* A workflow that returned, finished its END_RUN phase and saved its model
\* ends as a completed job unless an admin aborted it (user-visible outcome
\* agrees with what the workflow did).
\* Injected crashes are excluded (a crashed process legitimately fails the job).
NoInjectedCrash == /\ pWfSJ.sj /= "crashed" /\ ~pJobSP.sjKilled
                   /\ \A c \in Sites, l \in Launches : pJobCP[c].exitSeen[l] /= "crash"
GDoneSavedCompleted == (Terminal /\ pWfSJ.saved /\ pWfSJ.done /\ pWfSJ.returned = "normal"
                        /\ ~pWfSJ.panic /\ pJobSP.status /= "ABORTED" /\ NoInjectedCrash) => Finished
\* a finished job recorded a definite outcome for every started site
GFinishedAllOutcomes == Finished => \A c \in Sites : Started(c) => pJobSP.outcomes[c] /= "none"

\* ---------------- G3 resource conservation (single job)
GFreeAtMostOnce == \A c \in Sites : pJobCP[c].freed <= 1
GNoFreeWhileAlive == \A c \in Sites : pJobCP[c].freed > 0 => LiveLaunches(c) = {}
GNoAllocAfterFree == \A c \in Sites : pJobCP[c].freed > 0 => ~pJobCP[c].allocated
\* a CJ never runs at a site whose resources were never allocated
GNoChildWithoutAlloc == \A c \in Sites : LiveLaunches(c) /= {} =>
    (pJobCP[c].allocated \/ pJobCP[c].freed > 0)

\* ---------------- G4 at-most-once process launches per generation
GOneLiveLaunch == \A c \in Sites : Cardinality(LiveLaunches(c)) <= 1

GenericSafety ==
    /\ GFinishedNoAbnormalExit /\ GFinishedNoLiveChild /\ GTerminalNoLiveSJ
    /\ GFinishedAllOutcomes /\ GFreeAtMostOnce /\ GNoFreeWhileAlive
    /\ GNoAllocAfterFree /\ GNoChildWithoutAlloc /\ GOneLiveLaunch

\* ---------------- G5 no hang: used with CHECK_DEADLOCK (mkmc --deadlock):
\* a non-terminal state without any enabled step is a hang; terminal states
\* are given an explicit stutter so that they do not count as deadlocks.
\* a deleted job is over as well (it will never run)
\* v8 multiJob: not done while the SP-only job J2 still has to run or be finalized
DoneStutter == (Terminal \/ pJobSP.deleted) /\ pJobSP.other \notin {"queued", "running", "exited"}
               /\ UNCHANGED portVars

\* ---------------- K: known findings filtered out of bug hunts (plans/hunt4.py)
\* so that a run does not stop at them; anything else of the same kind is
\* still reported.
\* K1 #5301 (upstream, known-accepted): delayed RUNNING write over a terminal
\* status; K2 CANT_SCHEDULE over an acknowledged ABORTED (notes/job-impl.md).
GStatusStableK == [][pJobSP.status \in JobTerminalStatuses =>
                      \/ pJobSP'.status = pJobSP.status
                      \/ pJobSP'.status = "RUNNING"
                      \/ pJobSP.status = "ABORTED" /\ pJobSP'.status = "CANT_SCHEDULE"
                      \* K8 (hunt4 candidate C1): start-failure FAILED_TO_RUN over a
                      \* terminal status the completion thread already published
                      \/ pJobSP'.status = "FAILED_TO_RUN"
                      \* C1 in the other order (hunt5): the completion thread
                      \* publishes over the start-failure FAILED_TO_RUN
                      \/ pJobSP.status = "FAILED_TO_RUN"]_portVars
\* the terminal class is stable while the stored status is still terminal
GTerminalStableK == [][Terminal /\ pJobSP.status \in JobTerminalStatuses =>
                        \/ pJobSP'.terminal = pJobSP.terminal
                        \/ pJobSP.status = "ABORTED" /\ pJobSP'.status = "CANT_SCHEDULE"
                        \/ pJobSP'.status = "FAILED_TO_RUN" \/ pJobSP.status = "FAILED_TO_RUN"]_portVars
\* K3 S02 (REPRODUCED): the send() tail cleared the successor input
KS02 == \E c \in Sites, l \in Launches :
          LET P == pTrainer[c][l] IN
          P.received > (IF P.published = None THEN 0 ELSE P.published.gen) /\ P.slot /= P.received
\* K4 H30 (MASKED): the SJ died fatally after its workflow completed
KH30 == pWfSJ.done /\ SJFatal
\* K5 H21 (seed historical finding, pin client_executor.py:367-373): the waiter
\* thread failed to start after launch; the rollback replied START "no" and
\* freed the allocation while the CJ is alive
KH21 == \E c \in Sites :
          /\ pJobCP[c].freed > 0 /\ \E l \in Launches : CJAlive(c, l)
          /\ \E k \in DOMAIN net : net[k].msg.kind = "START_REPLY" /\ net[k].msg.from = CP(c)
                                 /\ net[k].msg.body = "no"
\* K6 H19 class (upstream #5559, open) on the restart path: the relaunch raised
\* after the backend may have accepted it (client_executor.py:771-776), the CP
\* reported failure and freed the allocation while a CJ is alive
KH19R == \E c \in Sites :
           /\ pJobCP[c].freed > 0 /\ pJobCP[c].launch >= 2 /\ pJobCP[c].reported = "failed"
           /\ \E l \in Launches : CJAlive(c, l)
KnownPrune == ~KS02 /\ ~KH30 /\ ~KH21 /\ ~KH19R
\* Hunts filter known findings at the invariant level and let traces continue
\* (pruning by CONSTRAINT turns "the only way forward is a known state" into a
\* spurious deadlock): K forms of the affected invariants, and KnownStuck as a
\* bounded state for the deadlock check (mkmc --known).
GNoFreeWhileAliveK == GNoFreeWhileAlive \/ KH21 \/ KH19R
\* K7 H33 class (by design): a started site's outcome is missing (report lost or
\* failed); the heartbeat path fails the job (fed_server.py _resolve_missing_client_outcome)
KH33 == \E c \in pJobSP.startSent : pJobSP.outcomes[c] = "none"
GDoneSavedCompletedK == GDoneSavedCompleted \/ KH30 \/ KH33
\* A CJ crash the CP classified as teardown noise (reported "ok": RC after
\* STOPPED, client_executor.py:784-797) is not an abnormal exit of a finished job.
GFinishedNoAbnormalExitK == Finished =>
    /\ ~SJFatal /\ SJExitCode /= "crashed"
    /\ \A c \in Sites : Started(c) /\ CurLaunch(c) > 0 =>
         CJExitCode(c, CurLaunch(c)) \in {"none", "ok"} \/ pJobCP[c].reported = "ok"
\* K9 H11 (REPRODUCED, checks/confirm/h11_repro.py): a resend listed the same
\* ClientTask twice and the task monitor died at its retirement
KH11 == pCommSJ.monitorCrashed
\* K10 C1-B (REPRODUCED, checks/confirm/c1_repro.py): the completion thread
\* died of the unguarded running_jobs delete after a start failure
KC1B == pJobSP.completionCrashed
\* K11 N1 / H32 class (Phase 1 contract baseline; hunt5 smoke): sites the
\* non-strict START check dropped are not awaited and their outcome report is
\* dropped; the per-site FINISHED checks skip them
Kept(c) == c \notin pJobSP.startDropped
GFinishedAllOutcomesK == Finished => \A c \in Sites : Started(c) /\ Kept(c) => pJobSP.outcomes[c] /= "none"
GFinishedNoLiveChildK == Finished => \A c \in Sites : Kept(c) => LiveLaunches(c) = {}
GFinishedNoAbnormalExitK2 == Finished =>
    /\ ~SJFatal /\ SJExitCode /= "crashed"
    /\ \A c \in Sites : Started(c) /\ Kept(c) /\ CurLaunch(c) > 0 =>
         CJExitCode(c, CurLaunch(c)) \in {"none", "ok"} \/ pJobCP[c].reported = "ok"
\* K12 T1 / T1-b (REPRODUCED, checks/confirm/t1_repro.py, t1b_repro.py): the
\* scheduling loop died after a queued job was deleted
KT1 == pJobSP.schedulerCrashed
\* K13 R2 (REPRODUCED at the server-logic level, checks/confirm/r2_repro.py): a
\* restarted CP's new token matches no job participant, the SJ is never told
\* that this client's job died, and its task waits (hang)
KR2 == \E c \in Sites : pJobCP[c].cpRestarted
\* K14 R1 (REPRODUCED, checks/confirm/r1_repro.py): no startup recovery after an
\* SP restart; checked by GNoStaleStatusAfterRestart, filtered in hunts
KR1 == pJobSP.spRestarted
\* K15 T2 / T3 (REPRODUCED, t2_repro.py, t3_repro.py): the cleanup thread died,
\* so dead clients are never logged out and their jobs' SJs never told (v8)
KT23 == pReg.cleanupCrashed /= "no"
KnownStuck == KS02 \/ KH21 \/ KH19R \/ KH30 \/ KH11 \/ KC1B \/ KT1 \/ KR2 \/ KR1 \/ KT23
=============================================================================
