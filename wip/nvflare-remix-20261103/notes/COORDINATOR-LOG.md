# Coordinator log (for recovery after context loss)

Task: see GOAL.md. User returns about 2026-11-04 01:30 UTC. Workspace W=/home/ubuntu/nvflare-remix-20261103. `/` and `/tmp` are full; always go through `scripts/tlc.sh`.

## Done (17:30-18:30 UTC)

- Framework.
  - Port modules: Consts, Ports, PortsJob, PortsFed, PortsPay.
  - Coarse variants of 8 groups plus Net R/L.
  - Generator `scripts/gen_mix.py` (static decoupling checks; one step per action in Mix, so CEs name actions).
  - `mkmc.py` (mix MC files), `run_mc.py` (JSON receipts in checks/results), `ce.py` (CE summary), `gen_ref.py` (fine ⊑ coarse refinement plus negative check).
  - Registry: `spec/registry.json` (core plus Net) and `spec/registry.d/{job,fed,pay}.json`.
- Baselines.
  - All-coarse happy path at 2 sites: 194,428 states, exhaustive pass.
  - 1 site with all faults: FinishedJobSaved violated. A task timeout fails the round, yet the job is marked FINISHED. This comes from the coarse draft semantics; check it against source before claiming anything.
  - Witness NotJobFinished is violated as expected, so the job can finish.
- Refinement machinery validated: WfSJ_M ⊑ WfSJ_C at 1 site with 6 faults, exhaustive at 2.68M states. The negative check fails as intended.
- Analysis notes:
  - `notes/seeds/{payload,fedavg,job}-partition.{md,json}`.
  - `notes/phase1-hazards.*` is still pending.
  - Group decisions: payload keeps SERVE+SETTLE in one PaySrc group (the MC-2 progress lock); fedavg keeps the callback body in WfSJ (it shares the round guard); job merges SPENGINE into JobSP.

## Running agents (launched about 18:15-18:30)

- Phase 1 hazards analysis, writing `notes/phase1-hazards.{md,json}`.
- Payload implementation (PaySrc_F, PayRcv_F), writing `notes/pay-impl.md`.
- Job implementation (JobSP_F, JobCP_F, RunCJ_F), writing `notes/job-impl.md`.
- FedAvg implementation (WfSJ_F, CommSJ_F, TaskCJ_F), writing `notes/fed-impl.md`.
- Design review, writing `notes/design-review.md`.

## Next (coordinator)

1. When the hazards analysis lands: write scenario campaigns (DESIGN §5), add cross-component properties to Props.tla, and add fault hooks requested in `notes/port-requests.md`.
2. Write a sweep runner over all mixes (product of variants) x fault profiles x sites, with budgets and a result table, plus a zoom-in triage helper.
3. Apply the design-review fixes.
4. Trace validation of mixes against the POC trace (`inputs/vertical-slice/traces/normalized`). Maybe delegate.
5. Write RESULTS.md at the end.

## 18:00-18:30 coordinator additions

- Ports: process-death `fatal` flags (Has/Flag), CJExitCode/CJGone/SJExitCode/SJGone. Per-agent build dirs (MIX_BUILD) and `"wip"` variants (MIX_INCLUDE_WIP).
- New group **Trainer** (my own): `PortsTrn.tla`, `Trainer_C.tla`, `Trainer_F.tla`, `registry.d/trn.json`. Port pTrainer[c][l] = [slot, received, published([gen, value, seq]), stopped]. TaskCJ must provide pTaskCJ[c][l].input / trainerSignal (contract sent to the fed agent).
- Component harness `checks/trainer/TrainerHarness.tla`, with a chaotic or realistic executor stub:
  - Trainer_F ⊑ Trainer_C: pass, 164 states.
  - Negative control (coarse without ClearCache): fails, as it should.
  - **S02 / H02 (Phase 1 v2 MC-2/TP-C) reproduced at model level in the component harness.** The previous send() tail `clear_cache` nulls the next input after the executor delivers it; 10-step CE in `logs/trainer_s02.log`. It still needs the full mix with 2 rounds (fed agent K07) and real-system confirmation.
- Props: OutcomeReflectsWorkflow, NoSJDeathAfterWorkflowDone (S10) and SuccessorInputPreserved (S02), all diagnostics.
- Scripts: `sweep.py` (all / one-fine / cover:T covering arrays / list), `campaign.py` (checks/scenarios.json), `zoom.py` (CE triage by refining the coarse groups seen in the CE).
- **S02 real-code reproduction** (`checks/confirm/s02_repro.py`): the pinned in-process Client API and DataBus are run directly from sources/current, read-only. The trainer thread is paused right after `publish_result()` returns (forced scheduling at a real preemption point), and then the executor delivers task 2. Result: `fl_model` goes 2 -> None, and receive() for task 2 times out. Status: REPRODUCED with forced scheduling.

  Plausibility: in the normal flow the executor delivers task k+1 only after the result submit/receipt round trip plus the next GET_TASK, so the trainer would have to stay descheduled for that whole time. Practical likelihood is low; possible wideners are S21 (concurrent AUX DO_TASK execute) and GC or CPU starvation. Severity when it happens: the trainer hangs, then result_wait_timeout ABORTs it, or the executor waits forever.

## 18:30-18:45 design review handled (notes/design-review.md, 12 issues)

Framework fixes, done by the coordinator:
- gen_mix:
  - generated `Assert(NetOK(g))` / `NetLossOK` on every step;
  - net is in the frame for groups without kinds (this fixes the Trainer net' bug);
  - EXTENDS/INSTANCE allowlist;
  - `.lost` rule (a warning now; becomes an error with STRICT_LOST=1).
- Ports:
  - InInbox;
  - kill = request (CJAlive no longer reads `killed`; CJExitCode = pRunCJ exit);
  - PeerFailureCJ/SJ (false suspicion under `transportFail`).
- gen_ref: RefEnv property; signed receipts in checks/receipts/.
- campaign.py: a result is labeled "transfers to all-fine" only with matching receipts.
- run_mc/tlc.sh: process-group kill on timeout; metadir removed via trap.
- DESIGN §2 now lists conditions C1–C8; §6 trace direction fixed (acceptance on all-fine, negatives on all-coarse).

Component fixes were sent to the three agents: DieOfKill, HeartbeatStop overwrite/lost oracle, END_RUN incarnation, PayRcv `.lost`, retry ids, SJ panic -> FINISHED, InInbox, Net=L receipts.

Orphan JVMs from earlier timed-out runs (pids 2440673, 2579907, 2607680) were still running. Killing them was denied by the permission classifier, so they are left alone; report this to the user. 58 stale metadirs were removed (7.4G -> 6.4G; the rest are in use).

## 19:30-20:30

- Trainer_C bug: publication seq was unbounded (state blowup). Fixed: publications <= received inputs. Harness refinement and S02 still hold.
- Generic negative refinement control: `[][UNCHANGED <<AbsC, Proj_G>>]` must be refuted. The old AbsCInit mapping was vacuous for trivial coarse privates.
- The all-coarse 1-site happy path grew to more than 9M states (agents' richer coarse variants). Coverage profile: WfSJ 47%, CommSJ 29%, TaskCJ 11%. Sent to the fed agent with concrete coarsening advice. The job FINISHED witness is still reachable (simulation, 104-step trace).
- **Per-site grain** implemented (SiteGrain constant, registry per_site_groups, mkmc `G=F@s1`, sweep `--per-site`). Verified by simulation: Trainer F at s1 and C at s2 in one behavior.
- The machine is oversubscribed (load about 175); agents were asked to cap workers at 12 per run, 2 runs each.

## 23:20-23:50 (after the usage-limit stop at about 20:30; all agents were resumed with wrap-up deadlines)

- **H30 sub-claim REPRODUCED against real code** (`checks/confirm/h30_shutdown_latch.py`; pinned DownloadService, fake cell that answers INVALID_REQUEST):
  - A download active at the SJ's own DS.shutdown() gets the typed DownloadCancelled (non-fatal path).
  - A download_object() started AFTER the shutdown returns with a plain failure (`error requesting data ... invalid_request`). That is the H29 decode-failure path, which cell.py:118-135 turns into os._exit(1) in the server job cell.

  So the SJ's shutdown gives no protection to late downloads; there is no latch in `_register_source_download`/`shutdown` (download_service.py:1285-1296, 1464-1508).
- Model CEs:
  - `checks/findings/H30_pay_ff_h30_sim.*` (PaySrc=F, PayRcv=F, rest coarse, taskTimeout): the late envelope's download registers after WfSJ DSShutdown, the source is gone, and the fatal decode follows.
  - Fed agent `logs/hz3_h30_1.log`: five fine groups, task timeout, empty round, controller panic, late envelope decode, END_RUN, CJ DS shutdown, fatal decode.
- The end-to-end job outcome (a completed workflow becoming a failed job, 2 sites + minClients) is not yet reached in the model and not run on a real system.

## 23:50-00:15 final runs (snapshot in .build/final_snapshot.txt, MIX_INCLUDE_WIP=all)

Campaign `checks/campaign/SUMMARY.md` (scenarios_final.json):
- F00w witness reached in 3 s.
- F10c all-coarse: H30 in 3.3 s.
- F10f six fine groups: H30 in 5.3 s.
- F10all2 all nine fine: H30 in 8 s, 128 steps (`checks/findings/H30_all_fine.ce.txt`).
- F10s (2 sites, minClients) and F22 (job fine + faults): no violation within budget.

Sweep final_cover2: 10 pairwise mixes (per-site, 2 sites, cjCrash+taskTimeout, sim 150 s each): no violation of the 8 core invariants.

Open: a TLC cast error when evaluating NoSJDeathAfterWorkflowDone (via SJFatal/Flag) in some mixes; a direct invariant works. RESULTS.md finalized.

## 2026-11-04 04:20-05:05 generic-property sweeps, artifact fixes, shutdown handshake

- exh_allC (all-coarse, 1 site, timers incl. outcomeTimeout) first hit `GTerminalNoLiveSJ` (known FAILED_TO_RUN-while-SJ-alive, skipped like bfs2), then `GFinishedNoLiveChild` via the coarse JobSP `Fail` firing on the always-on `rpcTimeout` after the job had run. Fix: coarse `Fail` at stage "started" only on `storeError` (fine: only `JobRunnerStartupStoreError` at writeRunning).
- bfs2 (10 mixes) was dominated by that artifact in every JobSP = C mix; stopped after 7 rows (`bfs2.partial.jsonl`).
- bfs3 (outcomeTimeout dropped from the timers: H33 grace expiry is known and masked everything else; non-WIP only by mistake): lead `GFinishedNoLiveChild` via CommSJ panic -> normal SJ exit -> heartbeat `ResolveMissingOutcome` (HBView 0) -> COMPLETED. Two artifacts:
  - SJ panic was a normal exit. Real code: system_panic -> FATAL_SYSTEM_ERROR latched sticky (server_runner.py:253-257) -> execution_error (server_engine.py:874-877) -> PROCESS_EXE_ERROR -> FINISHED_EXECUTION_EXCEPTION. `Ports!SJExitCode` now returns "error" after a panic.
  - Coarse JobCP sent the HB 2 listing lazily, after Spawn. Fine sends it atomically at RegisterPendingHandle (X1/X2). Coarse `Spawn` now requires `hb = 2`.
  - After both fixes: it_allC (all-coarse, 1 site, 6 timers) 7.9M distinct states in 900 s, no violation (budget-stopped).
- Abort-race candidate: abortrace_sim (depth 600, 29k traces) and abortrace_bfs (7.8M distinct, depth 50) are both budget-stopped with no violation without outcomeTimeout. Source timing check shows the CE order needs mark_run_aborted to lag the 10 s graceful wait (or a microsecond window after an ABORT-send failure): timing-implausible, model-only. Added timing T2 (`slowAdminStop` lifts it) and split `abortCmdError` from `abort`. Details: `checks/findings/ABORT_classified_completed.md`.
- GPT item 2 (DS shutdown call-return): port fields `tx.shut` (PaySrc) / `rx.sjDown` (PayRcv), `Ports!PaySrcShutDone` / `PayRcvShutDone`. RunCJ STOPPED/exit and WfSJ exit wait for the return. Fine side generated by pay_gen.py (regeneration verified identical before the edit); coarse PayRcv gained `ShutdownReturn`.
  - Payload harness refinement all exhaustive PASS: rcv nofault 7,027, rcv cjCrash+taskTimeout+netLoss 2,219,085, src nofault 2,146,120, src cjCrash+taskTimeout 2,371,050; both negatives FAIL as required.
  - RunCJ ref budget-stopped (2.9M, no violation).
- Relaunched: bfs4 (one-fine, WIP included, 77 runs, 600 s) and sim100c (cover:2 per-site, 2 sites, depth 100, 60 runs, 180 s) on `.build/bfs4_snapshot.txt`. Refinement batch 2 (JobSP, JobCP, WfSJ + negatives) in `.build/ref_batch2.out`.
- Refinement batch 2 (final spec): JobSP F ⊑ C (abort, abortCmdError, rpcTimeout, storeError, launchError, deployError) 5,310,493 distinct, JobCP F ⊑ C (l2, 11 faults) 2,931,600, WfSJ F ⊑ C (taskTimeout, WIP snapshot) 2,238,015: all budget-stopped, no RefStep/RefEnv violation. Negatives for JobSP and JobCP FAIL as required. (gen_ref for WIP groups needs MIX_SPEC/MIX_BUILD = a WIP-inclusive snapshot, else SANY "Unknown operator AbsC".)
- 05:20 refinement batch 2 on the fixed spec: JobSP F ⊑ C 5.3M, JobCP F ⊑ C 2.9M, WfSJ F ⊑ C 2.2M (WIP snapshot), all budget-stopped with no RefStep violation; JobSP/JobCP negatives FAIL as required. (`JobSP_F_C__s1_nR_l1_fabort-deployError-launchError-rpcTimeout.json` = the 03:26 RefStep violation of the reverted FailStatus tightening; stale, kept as evidence.)
- 05:20 free-combination demo `demofree` (`.build/demo_mixes.json`): 6 arbitrary mixes, 2 sites (all-C, all-F, two alternating, two with per-site grains, Net R and L), cjCrash+taskTimeout+abort + 6 timers, sim depth 100, 150 s each: all compose and run, 938-4,582 traces each, no violation of GenericProps / port invariants.
- 05:30 framework: bounded-evidence ("wip") variants are now mixable by default (`MIX_EXCLUDE_WIP` opts out); default `spec/Mix.tla` has all 20 variants. Second AG harness: `Env_RunCJ` + `AG_RunCJ`. The first harness run refuted RefStep: coarse RunCJ `Exit` required PaySrcShutDone at exit time (my handshake edit), stricter than fine after a late registration. Fixed to "STOPPED sent or shutdown done". Receipts exhaustive (10,911 / 86,973 / 867,245 states); negative FAILs; discharge by simulation in 5 mixes, no violation. bfs4/sim100c still run the pre-fix snapshot, where coarse RunCJ only misses the interleaving "exit between a late registration and its teardown".
- 05:45 payload on the AG standard: checker form `spec/Env_Pay.tla` + `AG_Pay`; PayEnv generator (scripts/pay_ref.py) widened to match it (any CJ/SJ death, dsDown/dsShutdown by a live process, submission reset, envelope clear) and the pay harness now also checks EnvSound. PayRcv nofault exhaustive PASS (92,541 states); both negatives FAIL. Discharge of AG_Pay + AG_RunCJ + AG_Trainer by simulation in 5 mixes (2 sites, 2 launches, 14 faults/timers, 300 s): no violation. PaySrc nofault, PayRcv faults and PaySrc faults harness runs still running (`.build/agpay.out`).

## 2026-11-04 08:00-09:50 rare-event budget (MixR), shutdown-return fix, coarse PayRcv precision

- bfs4 finished: 77/77 budget-stopped, no violation (11 mixes x 7 profiles, 1 site, 600 s). sim100c: 60/60 budget-stopped, no violation (2 sites, per-site cover:2, depth 100, 340k traces).
- **Rare-event budget** (user's idea; DESIGN.md §7): `spec/rarity.json` weights, `scripts/rarity.py` prices the 515 steps (56 static, 38 dynamic via `INSTANCE ... WITH Faults <- NormalFaults`, rest 0), generates `MixR.tla`; `mkmc --rarity K`; `rarce.py` lists the rare events of a CE.
  - BFS all-coarse, all 36 faults, 900 s: K=0 depth 40, K=1 31, K=2 25, K=3 23, unbounded 22; no violation. A first K=1 run hit known seed MC-2 (`GNoFreeWhileAlive` after one launchError) in 4 s; that property was skipped afterwards.
  - Simulation depth 150, 600 s: all-coarse K=1/K=2 hit `NoPayFatalAfterDoneP` in 65 s / 147 s, K=3 and unbounded did not (the budget focuses random walks); all-fine K=1/2/3/unbounded no violation.
- The cheap all-coarse CEs were coarse PayRcv over-approximations, fixed in two steps (pay harness rcv refinement exhaustive PASS after each):
  - a failure caused only by the SJ's own DS shutdown is the typed DownloadCancelled (fine: consumerReturn "cancelled") and is not fatal (`OtherCause` split);
  - the SJ's DS shutdown is one step for the receiver (`SJShutdownPending`): no pull may start between WfSJ declaring it and `ShutdownReturn`.
  - Further ordering precision (which failure came first) would copy the fine logic; policy instead: SJ-fatal leads from coarse PayRcv are zoomed in to fine payload.
- **User-reported bug fixed**: PaySrc_F `Shutdown` set the port `shut` at the start of shutdown()'s synchronous inline settlement (`spc[Inline] = "enter"`). Now a live transaction records `shutWait`, and `shut` is written by its Inline `SyncTerminationMarkerWrite` (download_service.py:1502-1505); coarse PaySrc mirrors it with `ShutdownReturn`. Checks:
  - src refinement nofault 4.57M and cjCrash+taskTimeout 5.95M budget-stopped, no violation; negative FAILs;
  - witness "CJ exits ok after its registered tx's shutdown returned": depth 90 before, depth 101 after (11 inline-settlement steps), so no new hang.
- Zoom-in h30g (PaySrc, PayRcv, RunCJ, WfSJ fine) K=1 reached H30 path 2 (late envelope registered after the SJ's DS shutdown, CJ replies INVALID_REQUEST, fatal decode) at cost 1 (an incidental admin abort). The cheapness came from `cancel` priced 0, coarse TaskCJ/CommSJ (send/accept after END_RUN/finalize), and the missing timing T3. Fixes: `cancel` weight 1; timing T3 `slowEnvelope` (weight 2; PortsPay) on PayRcv registration after the SJ's DS shutdown (fine via pay_gen, coarse Accept); rcv refinement nofault + slowEnvelope/taskTimeout exhaustive PASS.
- Running: rarz2 (h30g and +TaskCJ/CommSJ fine, K=1,2,3,5, depth 250, 900 s) on `.build/rarz2_snapshot.txt`. Expected calibration: known H30 costs >= 3.

## 2026-11-04 16:20–18:10 three-way review, v4 model, hunt4

- **Review.** Three agents worked on snapshots only; reports are in `.tmp/discuss/{gap,eff,rec}.md`.
  - **A (gaps).** Of 45 H items: 12 expressible, 2 bound-blocked, 24 missing, 7 out of scope. All post-fix sweeps used L1/R1.
  - **B (efficiency).** Under sweep-style faults, 0–0.4% of traces start the SJ. A fault throttle of 1/20 found the H30 class in 22 s, where the unthrottled run had found nothing in 600 s.
  - **C (recall).** Blind recall was 3/10 on expressible items and 7/10 when relaxed. Of 13 misses: 6 efficiency, 5 model gaps, 1 bound, 1 property gap.
- **Leads triaged.**
  - The submitTimeout deadlock was a retry bound not marked as AtBound (fixed).
  - B's two NoPayFatalAfterDoneP CEs were admin aborts: status ABORTED, so the impact is nil.
- **TLC 2.20 simulation bug.** A worker crashes in `getTrace` (ClassCastException) when it finds a violation, and the run hangs silently. 16 earlier logs show it, including 7 blind2 runs, all recorded as budget_stopped. Switched to the 2026.09 nightly. `run_mc` now records `worker_exception`. All-fine nominal 1 site reaches FINISHED in 304 steps.
- **v4 changes** (DESIGN.md §8):
  - Profile switches `wfTolerant` and `lossBudget3`; trainerError; TaskCJ AtBound.
  - `outcomeSeen` port. The smoke run showed a completed job FAILED via heartbeat-before-OUTCOME, because both JobCP variants returned from the outcome report without the server's reply.
  - Throttle; known-finding filters; GDoneSavedCompleted; `hunt.py`.
- **Refinement.**
  - Trainer harness with trainerError: exhaustive 487k states.
  - Trainer mix (attempt 2): 2.17M states, budget-stopped. CommSJ with wfTolerant: 1.48M states, budget-stopped.
  - Negatives FAIL as expected.
  - JobSP and JobCP re-checks after `outcomeSeen` are running (`logs/ref_v4b.out`).
- **hunt4.** Started 18:10 with 102 runs (`plans/hunt4.py`), budget 72 workers, expected to end around 22:00.

## 2026-11-04 18:10–22:24 hunt4

- Restarted three times in the first 45 min. Known and by-design findings stopped runs within seconds:
  - H21, H19 on the restart path, H33 grace expiry, #5301;
  - a multi-round port-invariant misfit, and the FAILED_TO_RUN async-abort window.
- These are now handled as invariant-level K filters, plus `KnownStuck` for the deadlock check. CONSTRAINT pruning produced spurious deadlocks.
- `outcomeTimeout` was dropped from the families: H33 by design, the same choice as bfs3.
- Model errors found and fixed mid-campaign; the affected runs were re-run (`rerun4`):
  - coarse CommSJ double receipt (net discipline assert);
  - my first guard for it used `\/` in an action, which TLC evaluates per disjunct; rewritten as IF;
  - JobSP CANCEL re-send after a loss (Send idempotent for identical messages);
  - old prebuilt modules without SiteGrain.
- CommSJ refinement after the fix (L2, A2, cjCrash): budget-stopped, no violation; the negative check FAILs. WfSJ refinement (A2) after the reset move: same.
- Lead "RECEIVED receipt for a result the workflow did not accept": zoomed in with fine CommSJ (`zoom_rcpt`). It persists there. Explained: RECEIVED is a transport receipt, and late or unknown-task results get it by design.
- Candidate C1 (FAILED_TO_RUN over a completion-published terminal status): found twice blind (all family). Model-only.
- Totals: 102 runs plus 8 re-runs; 78k simulation traces / 148M states; 51M BFS distinct states. RESULTS.md §9.
- `run_mc.py`: fixed `distinct_at_stop`, which my worker_exception edit had moved under the wrong branch; summary parsing comes from the logs.

## 2026-11-05 round 5: real-code confirmation, v5 gap fills

- C1 confirmed on the pin with `checks/confirm/c1_repro.py`, which drives the real JobRunner run() loop and completion thread with a forced schedule and a store fault on the RUNNING write. Variants:
  - A and A2: FAILED_TO_RUN over EXECUTION_EXCEPTION / COMPLETED.
  - B: the completion thread dies of KeyError, and a later job stays RUNNING.
- Upstream main `job_runner.py` is identical to the pin. #5301 (same family) was closed NOT_PLANNED as P3.
- H08 and H11 (Phase 1 candidates #1 and #8) confirmed on the pin, with no forced schedule (`h08_repro.py`, `h11_repro.py`). No upstream issues found. Both were made expressible in the model (profiles `otherJob` and `cseTasks`).
- v5 model: profiles `nonStrictStart`, `otherJob`, `errResilient`, `cseTasks`. Completion-thread and task-monitor death are modeled, with port flags and generic properties. Details in DESIGN.md §9.
- Smoke runs found two model errors, both fixed:
  - the JobCP_F restart claim swallowed the START reply;
  - the coarse JobSP Terminate no-kill branch applied to a live SJ.
- Smoke runs also found one lead, N1: under the non-strict start policy, a site whose START reply timed out has its failure OUTCOME dropped, and the job can finish COMPLETED. H32 class. It is now filtered by K11.
- A JobSP refinement check caught my first non-strict coarse encoding. It merged the reply evaluation with the pending filter, but the code has a window between them where an OUTCOME is still handled as pending. The coarse side now uses two steps.

## 2026-11-05 round 6: thread audit, restart, trace validation, hunt6

- Thread-death audit of the long-running SP/SJ/CP/CJ threads. Three new findings, reproduced on the pin:
  - T1: the scheduling loop dies when a queued job is deleted during the 1 s scan. Natural race, about 2.6% per delete with 300 queued jobs.
  - T1-b: same death when a job is deleted while being deployed (deterministic).
  - T2: client_cleanup dies when a dead client re-registers during the logout loop.
- Process-restart review. Two findings:
  - R1: the SP's startup recovery helpers have no caller, so an interrupted RUNNING job can be neither aborted nor deleted.
  - R2: a restarted CP's new token matches no job participant, so the SJ is never told that the client's job died. Confirmed at the server-logic level.
  - Upstream: no related issues; the relevant files on main match the pin.
- Model v6 (DESIGN §10):
  - `deleteJob`: fine and coarse JobSP, `GSchedulerThreadAlive`.
  - `spCrash` / `cpCrash`: fate sharing in Ports, `GNoStaleStatusAfterRestart`.
  - K filters K12–K14.
- Refinement after each change, all budget-stopped with no violation (negatives FAIL):
  - JobSP: 8.6M / 2.7M (deleteJob), 8.0M (spCrash).
  - JobCP: 4.3M / 3.4M (cpCrash).
  - The first deleteJob encoding missed the "blocked" stage; caught by the check.
- Probe findings:
  - cpCrash without rpcTimeout deadlocks: a model-bound wait. Rule: process death comes with rpcTimeout.
  - The restarted SP's idle scheduler never deadlocks, so R1 needs an invariant.
- Trace validation:
  - Silent bound 120; up to 3 events per step (END_RUN broadcast).
  - The real POC trace is accepted (simulation) on all-fine, all-coarse and two mixes.
  - A reordered trace is rejected exhaustively.
- hunt6:
  - Launched 17:20 UTC: 155 runs (S 120, L 12 three-site, D 8, B 15), planned ≤ 8 h.
  - Smoke: 20 runs clean; D rediscovered T1 and R1 in seconds.
- Not done: Attach / external-process trainer (scope).
