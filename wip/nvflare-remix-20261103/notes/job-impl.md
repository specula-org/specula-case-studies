# Job component implementation log (JobSP, JobCP, RunCJ)

Agent: job. Workspace W. All runs use `MIX_BUILD=W/.build/job MIX_INCLUDE_WIP=JobSP,JobCP,RunCJ`.

## Design decisions (18:00-18:20)

- Ports (spec/PortsJob.tla): new message kinds replace the seed's set-network and cross-process reads:
  - JobSP -> CP: CHECK_RESOURCES, CANCEL_RESOURCES, DEPLOY_JOB, START_JOB, ABORT_JOB (seed Stop), HEARTBEAT_STOP; id <<JobId,c>>.
  - JobCP -> SP: RESOURCES_OK(ok|no), CANCEL_ACK, DEPLOY_REPLY(ok|no), START_REPLY(ok|no), OUTCOME(ok|failed|aborted); HEARTBEAT id <<JobId,c,ph>>, ph = listing phase 1 (not yet listed) / 2 (in run_processes) / 3 (removed). This replaces X1/X2 (SP reading client.handle).
  - RunCJ -> CP: STARTED, READY, STOPPED, id <<JobId,c,l>>, body l (launch id). Replaces X11 (spontaneous status with free generation).
  - pJobSP adds `sjKilled` (SP terminated SJ) and `status` (job store value, non-CAS); `terminal` = class of the last terminal status written.
  - pRunCJ adds `abort` (run_abort_signal, END_RUN) and `dsDown` (run-finally DownloadService.shutdown).
  - JobFaults: cjCrash, abort, outcomeReportFail, deployError, launchError, storeError, rpcTimeout, outcomeTimeout, archiveError, admissionError.
- JOB_SPENGINE merged into JobSP (partition note fallback `merge_spengine`).
- Seed shortcuts: X4 (outcome-reply absence) -> report returns spontaneously (reply or timeout); X5 (SJ failure code at physical exit) -> recorded at ObserveExit from SJExitCode (joint with registry pop); X10 rc -> constrained by CJExitCode; X12 can_restart stays a free choice; X3 dedup -> HEARTBEAT_STOP re-sent only if lost.
- Slice profile: one job, one token <<JobId,1>>, Pool <<0>>, TTL 1, StrictStart, MaxScheduleCount 1, RequiredSites = Sites; MaxRestartFailures = MaxLaunch-1, LaunchSlots = MaxLaunch (restart hazards with --launch 2).
- Known environment issue: spec/Trainer_C.tla Callback lacks UNCHANGED net (reported in port-requests.md); patched copy in .build/job shadows it.

## Revisions after coordinator updates (18:20-19:10)

- Registry kinds updated together with coarse changes (static check must pass without WIP).
- Heartbeat: CP sends HEARTBEAT(2) at RegisterPendingHandle and HEARTBEAT(3) at SpawnException/RemoveProcess (joint with the run_processes change, i.e. the seed's atomic read X1/X2 without staleness). SP reads the latest listing from net (HBView), never consumes it, ignores loss (next periodic heartbeat repeats it). This removed 6 interleaving steps per site (coverage showed RecvHeartbeat/SendHeartbeat as top state splitters).
- Kill semantics (Ports.tla change): pJobCP.killed is a kill request; RunCJ_C/RunCJ_F have DieOfKill (exit "killed", no fairness). JobCP waits for CJExitCode.
- Net discipline: ABORT_JOB ids <<JobId,c,src>> (src fail/admin/outcome/complete; each path sends at most once), CANCEL_RESOURCES <<JobId,c,admit|fail>>, HEARTBEAT_STOP <<JobId,c,n>> n<=2 (seq 2 only with netLoss). No `.lost` reads or re-sends. InInbox used for receipt.
- END_RUN handled set is per cell CJ(c), not per launch (RunCJ_C, RunCJ_F).
- AbsC mentions only own private state and own port: JobCP_F tracks startReply/hb privately, RunCJ_F tracks sent notifications privately, JobSP_F records runner milestones (ms) at port-visible steps.
- JobSP_C made leaner (40 -> 28 actions): replies are read from net (not consumed), timeouts are a fault branch, deploy evaluation + start claim merged into WriteDispatched (abort may always find the claim busy), all startup-failure decisions merged into one Fail step, Release/GiveUp dropped.
- JobCP_C: CHECK "no" branch dropped (unreachable with one token per site and a one-unit pool).

## Checks so far

| Run | Mix / config | Result | States | Time |
|---|---|---|---|---|
| gen_mix + SANY | all variants (16) | pass | - | - |
| job_allC_s1 | all coarse, 1 site, no faults, default invs | violation ClaimNeedsMaterialized (CommSJ_C/PayRcv_C path; not job groups) | 32,722 | 8 s |
| ref_RunCJ_F_C_neg | negative map | violation (BadStep) as required, BFS and sim | 185 | 6 s |
| ref_{RunCJ,JobCP,JobSP}_F_C | 1 site, no faults, Net R | no violation, budget stop (BFS depth 63 for JobSP) | 204k / 170k / 217k | 240 s each |
| jref_{RunCJ,JobCP}_f2_R sim | 1 site, all job faults, MaxLaunch 2, Net R, simulation depth 250 | no violation | 2.07M / 1.35M states checked | 200 s |
| jref_JobSP_f1_R sim | 1 site, all job faults, Net R, simulation | no violation (8,831 traces, mean length 203) | 2.2M | 200 s |

Machine load is ~150 on 96 cores (other agents plus an orphan JVM, reported in port-requests.md), so throughput is ~30x below the 17:50 baseline.

## Hazard properties for Props.tla (definitions over port state)

```tla
\* S17 / H22 (#5301, known accepted): the job store has no CAS, so a terminal
\* status can be overwritten (delayed RUNNING after terminal; CANT_SCHEDULE over
\* a pre-run ABORTED). Diagnostic: violation expected with the abort fault or a
\* fast SJ exit.
TerminalStatusStable ==
    [][pJobSP.status \in JobTerminalStatuses => pJobSP.status' = pJobSP.status]_pJobSP

\* H33 / K20 OutcomePrecedenceAndPolicy: FINISHED is published by the
\* completion thread only after the SJ is gone, and never with an accepted
\* failed/aborted client outcome (fail_run makes the run FAILED/ABORTED;
\* job_runner.py:136-142,903-933, 494-547). A missing outcome is allowed (grace
\* expiry, job_runner.py:517-531), which is why FinishedJobAllOk (Props) is
\* violated by design when outcomeTimeout is enabled.
SJDownSP == pJobSP.sjKilled \/ SJGone
OutcomePrecedenceAndPolicy ==
    pJobSP.terminal = "FINISHED" =>
        /\ SJDownSP
        /\ \A c \in Sites : pJobSP.outcomes[c] \notin {"failed", "aborted"}

\* H36 AbortBlocksRestart: once CP requested a kill (abort latch set), no new
\* launch generation is spawned (client_executor.py:734-745 restart claim checks
\* the abort latch; a claimed restart re-launch is killed via the pending abort).
AbortBlocksRestart ==
    [][\A c \in Sites : pJobCP[c].killed /= {} => pJobCP[c].launch' = pJobCP[c].launch]_pJobCP

\* H34 ReservationOwnership: an allocation is freed only for a token that was
\* reserved and started (cancel never frees an allocation), at most once.
ReservationOwnership == \A c \in Sites :
    pJobCP[c].freed > 0 =>
        /\ MsgKey("RESOURCES_OK", CP(c), SP, <<JobId, c>>) \in DOMAIN net
        /\ MsgKey("START_JOB", SP, CP(c), <<JobId, c>>) \in DOMAIN net
        /\ pJobCP[c].freed <= 1

\* H35 StaleNotificationFenced: a CJ status notification can only change CP's
\* view if its launch id is the current generation (or legacy None). The CP's
\* view is private; over ports the observable consequence is that a READY from
\* an old launch never precedes a restart decision of the new one. Checked as a
\* JobCP_F-local invariant instead (guard of JobExecutorNotify*: g = 0 \/ g =
\* generation; stale ids go to JobExecutorIgnoreStaleStatus). Needs MaxLaunch 2.
```

## 19:15-19:35

- JobCP refinement CE (jref_JobCP_f2_R, BFS 110,929 states, 87 s): after a restart submission exception (JobExecutorRestartException, launchError) the seed leaves pc at registered/snapshotted, so ProcessJobLauncherSpawn can still launch the new generation. This matches the source comment (client_executor.py:771-783: "A submission exception may mean the backend accepted the job. Without a handle proving otherwise, never submit again."). Classified (a) for the coarse variant: JobCP_C had no such orphan launch. Fixed JobCP_C (RestartFail sets `orphan`; Relaunch also fires on orphan). Note for MC: the orphan CJ has no waiter, and the CP reports FAILED and frees the allocation while it may run, the same class as H19/#5559 (accepted-handle loss). Needs launchError + cjCrash + MaxLaunch 2.
- Coarse JobCP_C HEARTBEAT(3) guard tightened (only after a spawn exception before launch, or after the free): the loose guard let coarse runs tell SP early that CP dropped the job.
- New timing toggle `resExpiry` gates the reservation TTL scan (fine AutoCleanResourceManagerTick, coarse Expire). Reason: with TTL 1 and an always-enabled scan, random simulation of the fine mix almost always expires the token before START arrives (diagnostic witnesses: SJ launched within 6 s, CJ never launched in 45 s of simulation). H34 hazard runs enable it.
- scripts/job_refs.py writes the refinement models for the campaign instances (1 site, all job faults incl. resExpiry, Net R and Net L+netLoss, MaxLaunch 2 for JobCP/RunCJ) and the negative checks; scripts/job_mixes.py writes the baseline mixes with the job hazard properties inlined; scripts/job_run.py wraps run_mc.py and kills the model's JVM on timeout.
- Diagnostic: all-coarse witness (job_mC_w, simulation) reaches FINISHED in 64 s; the fine mix witness needs BFS (running).

## 19:35-20:00

- JobSP_F: the seed AdmissionException can recur at `history` (it re-arms cancelSend), which re-sends CANCEL_RESOURCES on the same key (net discipline assertion in jref_JobSP_f1_L sim). The seed MC bounds it with AdmissionErrorLimit = 1; carried into JobSP_F as budget `admissionErrors < 1` (like `adminAborts`). Classified (a), fixed.
- JobCP refinement CE 2 (jref_JobCP_f2_R BFS, 172,657 states): after the orphan relaunch (above) the fine CP reports the outcome of the observed exit of launch 1 while launch 2 is current; JobCP_C ReportOutcome only looked at the current launch. Fixed with a sticky `restartFailed` flag (fine and coarse). (a).
- RunCJ refinement receipt (Net R, all job faults, MaxLaunch 2, 1 site): BFS 2,623,262 distinct states, complete to depth 28 (budget 1500 s), no violation; sims Net R (2.07M states) and Net L (+netLoss) no violation; negative check violated. `wip` removed from RunCJ_F.
- JobSP refinement (pre-budget model): BFS 3,166,908 distinct states, complete to depth 39, no violation (budget 1500 s). Re-running on the final model.
- Fine mix witness: BFS to depth 82 (1.5M states) does not reach FINISHED (the fine lifecycle at 1 site is about 120+ steps); simulation (resExpiry off) violates NotJobFinished in 6 s with a 160-step trace (68 job-group steps). So the job can finish with all three job groups fine.
- Simulation statistics note: with MaxLaunch 2 the reported "mean trace length" is tiny because TLC averages finished traces only; many traces end early in deadlocked states (e.g. an early crash with no restart budget left). BFS receipts are the primary evidence.

## 20:00-20:20

- Seed invariants carried into the fine modules as group-local operators: JobCP_F `SeedInv` (ResourceConservation, SingleSupportedStart, WaitBeforeNormalFree) and `SeedHuntInv` (NoFreeWhileInUse, CleanupOwnerOrCompleted, with client.alive -> ChildAlive); JobSP_F `SeedInv` (SchedulerCapacity, RetryHistoryNotAhead) and `SeedHuntInv` (AcceptedPreRunAbortPersists, NoTerminalResurrection). The baseline mixes check JobCPSeed/JobSPSeed; job_mF_hunt adds the hunt ones.
- Refinement receipts so far (Net R, 1 site, all 11 job faults, MaxLaunch 2 for JobCP/RunCJ, BFS budget, no violation):
  - JobCP: 1,948,074 distinct, complete to depth 30 (1200 s).
  - JobSP: 4,067,477 distinct, complete to depth 40 (1200 s).
  - RunCJ: 2,623,262 distinct, complete to depth 28 (1500 s).
  `wip` removed from all three fine variants. Official receipts via `gen_ref.py --run` (now with RefEnv) are re-running for Net R and Net L (scripts/job_receipts.py).
- Mix job_mF_flt (job groups fine, rest coarse, all job faults, MaxLaunch 2, simulation): TerminalStatusStable violated in 38 s. CE saved as checks/job/ce_cantschedule_over_aborted.{log,txt}.

### CE: CANT_SCHEDULE overwrites an acknowledged pre-run ABORTED  (class c, candidate, low severity)

Trace (JobSP_F steps only; the rest is environment): check request times out (or the site has no free resource) -> no_resource -> cancel -> retry bookkeeping; next pass reads the SUBMITTED candidates; the admin `abort_job` runs `abort_before_start` (job_runner.py:815-825: under `_start_lock`, job not starting, status SUBMITTED -> FINISHED_ABORTED) and the CLI acknowledges "Aborted the job before running it." (job_cmds.py:1085-1089); the scheduler pass then finds the candidate's schedule count exhausted and writes FINISHED_CANT_SCHEDULE (job_scheduler.py:334-337) without `_start_lock` and without re-reading the status (job_def_manager.py:459-481 set_status has no CAS). Final store status CANT_SCHEDULE although the abort was acknowledged; this also violates the seed invariant AcceptedPreRunAbortPersists. Same non-CAS writer class as MC-3/#5300/#5301 (the seed partition lists CANT_SCHEDULE among the non-CAS writers); the seed never reached it because its MaxScheduleCount was 10. Realistic without faults: a job that stays unschedulable for max_schedule_count passes (e.g. no free GPU) and is aborted during its last pass. Impact: status/terminal-cause inconsistency only (both terminal, the job never runs). Needs source/implementation confirmation.

### CE detail: CANT_SCHEDULE over acknowledged ABORTED (23:25 re-check of source at the pin)

Model trace (checks/job/ce_cantschedule_over_aborted.{log,txt}, mix job_mF_flt = JobSP/JobCP/RunCJ fine, rest coarse, 1 site, all job faults, simulation, 24 states; only JobSP_F/JobCP_F steps): BeginPass, TryJob, CHECK_RESOURCES, AdminCheckTimeout, CP reserve, EvaluateResources (no_resource), CheckOK late, CANCEL_RESOURCES, CancelReturned, UpdateHistory (count = 1 = MaxScheduleCount), EndPass/PersistFailed/ReturnPass, BackoffElapsed, BeginPass (candidate read while SUBMITTED), **JobCommandAbortRead** (status SUBMITTED -> ABORTED, adminPC ackPreRun), Exhausted (blocked), EndPass, **JobCommandAbortPreRunAcknowledge** (abortAck), BackoffElapsed, **DefaultJobSchedulerPersistBlocked** (status ABORTED -> CANT_SCHEDULE). Violates TerminalStatusStable and the seed's AcceptedPreRunAbortPersists.

Source (pin c411a201):
- job_runner.py:703 `approved_jobs = job_manager.get_jobs_to_schedule(fl_ctx)`: snapshot of SUBMITTED jobs (job_def_manager.py:104-120 `_ScheduleJobFilter`, 512-515), taken without `_start_lock`.
- job_runner.py:708-710 `scheduler.schedule_job(...)`; job_scheduler.py:376-383 a candidate whose snapshot `SCHEDULE_COUNT >= max_schedule_count` goes to `blocked_jobs`; job_scheduler.py:334-337 then `job_manager.set_status(job.job_id, FINISHED_CANT_SCHEDULE)` with no status re-read and no lock.
- job_def_manager.py:459-481 `set_status` -> filesystem_storage.py:251-275 `update_meta(replace=False)`: read-merge-write, no compare-and-set.
- job_runner.py:815-825 `abort_before_start`: under `_start_lock`, a job not in `_starting_jobs` with status SUBMITTED/DISPATCHED is set to FINISHED_ABORTED; job_cmds.py:1080-1089 replies "Aborted the job ... before running it." with OK status.

Reachability in the real code: yes, statically. The two writers run on different threads (scheduler loop vs. admin command handler) and nothing orders the CANT_SCHEDULE write after a status re-check. The window is from the candidate snapshot (job_runner.py:703) to the blocked write (job_scheduler.py:337); it covers `_do_schedule_job` for all candidates, including resource-check RPCs to sites for earlier-submitted candidates (`_try_job`), so it can last seconds. Preconditions without any fault: the job has already used `max_schedule_count` scheduling attempts (default 10; e.g. resources stayed unavailable) and the admin aborts it during the pass that blocks it. Outcome: the user got a successful pre-run abort, the stored status is CANT_SCHEDULE. Both are terminal and the job never runs, so the impact is a wrong terminal cause (status/history/monitoring), not resource or execution damage. Evidence level: model-level candidate plus static source reading; not reproduced, not confirmed upstream. Same non-CAS writer class as #5300 (fixed for DISPATCHED by the start claim) and #5301 (known accepted, RUNNING after terminal); the start claim does not cover the scheduler's blocked branch.

## Final state (23:55)

- 20:32 the JobSP Net R receipt died on a metadir write error (a `.tlc/...` directory removed underneath it). Re-run 23:23 on the final JobSP_C (the lean rewrite from 19:00; unchanged since). gen_mix (with and without WIP) and SANY on Mix pass. The stale shadow copy `.build/job/Trainer_C.tla` was removed: gen_mix now frames net for kind-less groups.
- Official refinement receipts (`gen_ref.py --run`, files in checks/receipts/, logs in logs/ref_<G>_F_C__<R|L>.log). Instance: 1 site, all 11 job faults, Net R, or Net L + netLoss, MaxLaunch 1 (JobSP) or 2 (JobCP, RunCJ). Checked properties: RefInit, RefStep, RefEnv. All BFS runs stopped on budget with no violation (bounded evidence, not exhaustive):

| Group | Net | distinct states | BFS levels complete | budget |
|---|---|---:|---:|---:|
| JobSP | R | 9,036,604 | 42 | 1500 s |
| JobSP | L | 3,780,306 | 36 | 600 s |
| JobCP | R | 1,646,592 | 30 | 600 s |
| JobCP | L | 2,038,391 | 26 | 600 s |
| RunCJ | R | 3,404,062 | 26 | 600 s |
| RunCJ | L | 4,615,022 | 23 | 1200 s |

  Negative checks (gen_ref --negative, new BadStep form): all three violate within 1 s, as required. Earlier simulation runs (depth 250-300, 200 s each, Net R and L) also found no violation. 2-site refinement was not run.
- Baseline mixes (1 site):
  - all coarse, no faults (job_mC, default invariants + OutcomePrecedenceAndPolicy, ReservationOwnership, JobCPSeed, JobSPSeed, AbortBlocksRestart): simulation 420 s, 7.45M states, 36,141 traces, no violation. Earlier job_allC_s1 (17:50 framework) hit ClaimNeedsMaterialized in CommSJ_C/PayRcv_C (not job groups).
  - all coarse witness NotJobFinished: violated (sim, 64 s).
  - job groups fine, rest coarse, no faults: BFS 90 s no violation; witness NotJobFinished violated (sim, 6 s, 160-step trace). BFS to depth 82 does not reach FINISHED.
  - job groups fine + all job faults, MaxLaunch 2 (job_mF_flt): with TerminalStatusStable, violated in 38 s, CE (c) above; without it, simulation 240 s (2.86M states, 4,776 traces, mean length 518) shows no violation of the default or job invariants.
- Not done: Net L fine mix and the hunt mixes (job_mF_fltL, job_mF_hunt*, job_mF_s17 are generated but were not run); per-site grain; 2-site refinement.
