# Spec Validation Changelog — nvflare-job

Pinned source 53ba7ee5. Phase 3 (validation-workflow). Entry kinds are kept distinct:
`[fix]` model (base/Trace spec) change from trace validation, `[fix-inv]` property change (Case A),
`[fix-spec]` model change from model checking (Case B), `[bug]` real defect (Case C),
`[obs]` observation/harness change (no model or property change), `[mc-control]` checker configuration only,
`[env]` environment limitation.

Snapshots of every spec version used in this phase are kept under `spec/history/<round>/`
(`r0-phase3-start` = the spec as delivered by Phase 2 / 2.5).

## Round 0 - Initialization
- [env] MCP `run_trace_validation` cannot run on this host: TLC fails with "could not make a directory
  /tmp/tlc_validation/..." because `/tmp/tlc_validation` is a dangling symlink into another user's home.
  Trace validation therefore uses `harness/validate.sh` (direct TLC, `-metadir harness/build/tlc-meta`,
  1 worker, -Xmx4g, sequential) with the same `Trace.tla` / `Trace.cfg`.
- Verified: base/MC/Trace specs, 21 hunting/seed cfgs, 29 traces, instrumentation-spec.md,
  harness/INSTRUMENTATION.md. `Trace.cfg` has `PROPERTIES TraceMatched`; `ValidatePostState` checks every
  observable variable on every event (not a stub). Trace provenance matches the current harness build
  (patch sha256 a74bfbf9..., tla_hooks sha256 66978101...).

## Round 1 - Trace Validation
Baseline (spec r0): 26/29 pass; 3 fail (`spec/output/trace_validation_r1_baseline.txt`; TLC counterexamples from
Phase 2.5 in `harness/evidence/validation/`).
- [fix] Network / every message send-consume action: `msgs` was a set, so two identical in-flight requests merged.
  CellNet does not deduplicate: `fail_run`'s `_stop_run` and the runner's except-path `_stop_run` each send
  ABORT(j) to every participant and to the SJ (`job_runner.py:374-393, 714-719, 843`), and both copies are
  processed. `msgs` is now a multiset (`NoMsgs`/`Send`/`Consume`/`ConsumeAll`/`Keep`; guards use `DOMAIN msgs`).
  (Trace: failrun_during_start_dup_abort.ndjson, 2nd `CpAbortApp(c2)` at #28)
- [fix] CpAbortApp / CpTerminateJob / CjHandleAbort: `termP[c][j]` and `cjAbortMsg[c][j]` were booleans, but every
  `abort_app` on a STARTED/STOPPED registration starts its own `_terminate_job` thread and (when STARTED) fires its
  own CJ ABORT (`client_executor.py:486-547`); CP requests run concurrently on the cell worker pool. Both are now
  counters. (Traces: double_abort_terminate.ndjson #68, random_mix_s1.ndjson #96)
- [fix] Heartbeat: new guard `~HbBusy(c)` and counter `termHb[c][j]`. The heartbeat thread processes the previous
  reply's abort list synchronously (`communicator.py:621-624, 640-646`) and `abort_app` joins the `_terminate_job`
  thread it starts (`client_executor.py:511-533`), so a client sends no heartbeat while one of its cleanup aborts is
  undelivered or blocked in that join. Companion to the multiset change (code evidence, no trace failure): without
  it, unbounded fair heartbeats in the liveness configs would accumulate duplicate cleanup ABORTs / terminate
  threads without bound. `heartbeat_cleanup=True` differs from a plain `terminate()` only for the Slurm launcher
  (out of scope).
- [obs] Harness probe for INSTRUMENTATION.md 7.3 (first bullet): added the timing gate `wfc.after_read` in the
  instrumented `ServerEngine.wait_for_complete` (after the entry read, before the <= 2 s wait; no-op unless a
  scenario registers it) and scenario `wfc_stale_read_after_pop`. Patch regenerated (Phase-2.5 patch, scenarios,
  run.sh and traces preserved in `harness/history/phase2.5/`); all traces regenerated with the new patch.
- [fix] SpWaitForComplete / SpRemoveRunProcesses: new variable `wfcStale[j]`. `wait_for_complete` reads the
  `run_processes` entry (`server_engine.py:205`) before its <= 2 s wait and records the SJ exit code into the object
  it read (`:218-233`); when `_remove_run_processes` popped the entry in between, the exit code is still recorded
  from the stale entry -- even after the completion thread finalized the job, leaving a stale
  `exception_run_processes` entry. The model merged read and record, so it could only express "rc never captured".
  `_remove_run_processes` now stashes the entry it pops while the waiter is alive, and `SpWaitForComplete` with
  the entry gone either records nothing (read after the pop, F20) or records from the stash (read before the pop).
  (Trace: wfc_stale_read_after_pop.ndjson #70; pre-fix counterexample
  `spec/output/r1_wfc_stale_read_after_pop_FAIL_before_wfcStale_fix.tlc.log`)
- [note, not modeled] INSTRUMENTATION.md 7.3 second bullet: `_job_complete_process` calls
  `remove_exception_process(job_id)` when a job vanished from `running_jobs` between the key snapshot and `get`
  (`job_runner.py:443-446, 541`). In scope the only other remover is the runner's except path
  (`job_runner.py:716-717`; `remove_running_job` is called only by HA `pause_server_jobs`), and the `exc` entry of
  a job removed there is never read again (not in `running_jobs`, no pending outcomes, SJ gone). No behavioural
  consequence, so no action was added. Third bullet (SweepEnd Dead branch) is a harness limitation (trace lock).
- Result: 30/30 official traces pass (`spec/output/trace_validation_r1_after_wfc_fix.txt`; re-run after
  regeneration in `harness/build/run_p3r1.log`), 2 parallel stress rounds 30/30 each, random seeds 7-40 34/34
  (`spec/output/trace_validation_r1_*`). Spec snapshot: `spec/history/r1-trace/`.

## Round 1 - Model Checking
Config MC.cfg (spec r1), BFS, 16 workers, -m 20G -M 40G, -t 30.
- [bug] RunnerSetDispatched: `TerminalStable` violated in 11 states (`spec/output/MC_r1_run1.out`):
  `AdminAbortBegin(j1)` reads SUBMITTED, the runner deploys, `AdminAbortWrite` acknowledges ("Aborted the job ...
  before running it.") and writes FINISHED:ABORTED, then `job_runner.py:670` blindly writes DISPATCHED over it
  (the job goes on to run). Case C: confirmed seed F1 (brief 6.1; harness A1/A2), and the real implementation
  exhibits it in the validated trace `abort_during_deploy.ndjson`. Contract: `FINISHED:*` is terminal
  (`job_cli.py:1926-1936`, `job_cmds.py:1067-1070` "already completed"), one-shot execution (`job.rst:342-345`).
  Not a new finding (known seed; see bug-report "Known seeds").
- [mc-control] MC_conv.cfg = MC.cfg with `TerminalStable` replaced by the residual `NoNovelTerminalOverwrite`
  (tolerates only the confirmed seed writers F1/I4, F1/F3, F16, RS-3, I5; see `evidence/deep/runner_status.md` I2-I7,
  I15) so the convergence round can continue past the F1 counterexample BFS always reaches first. `TerminalStable`
  stays enabled in MC.cfg; no property was changed.
- [bug] AdminAbortWrite (MC-A): `NoNovelTerminalOverwrite` violated in 12 states on MC_conv.cfg
  (`spec/output/MC_conv_r1_run1.out`): `AdminAbortBegin(j1)` reads SUBMITTED; the runner schedules j1, its deploy
  to the only dispatched site fails (min_sites not met, `job_runner.py:269-282`), the except path publishes
  FINISHED:FAILED_TO_RUN (`:720`); then the admin handler's `set_status(FINISHED_ABORTED)` (`job_cmds.py:1063`)
  overwrites it and acknowledges "Aborted the job ... before running it.". Case C: `abort_job` reads the status and
  writes without a lock or re-check (`job_cmds.py:1058-1063`), `set_status` is a blind merge
  (`job_def_manager.py:459-481`); `TerminalStable` is the documented contract (abort_job itself refuses FINISHED:*
  jobs as "already completed"). Low severity (terminal -> different terminal; no resource effect). Same
  blind-write root cause as the F1 family, new writer site; corresponds to the spec-generation smoke-test candidate
  (brief-coverage 8, MC_hunt_s1_status).
- [residual] KnownOverwrite: added `o.w = "AdminAbortWrite" /\ o.from \in Terminal` (hunting residual only; used by
  MC_conv.cfg and MC_hunt_s1_status.cfg) so the search continues past MC-A. `TerminalStable` unchanged.
- [bug] CmpPublish (MC-B, F1 family): `NoNovelTerminalOverwrite` violated in 21 states (`spec/output/MC_conv_r1_run2.out`):
  `AdminAbortBegin(j1)` reads SUBMITTED; the runner deploys (DISPATCHED), launches the SJ and sends START
  (`_start_run`); `AdminAbortWrite` then writes FINISHED:ABORTED and acknowledges "Aborted the job ... before running
  it." -- a store-only write (`job_cmds.py:1061-1066`) that stops nothing; the runner inserts j1 into running_jobs,
  the SJ ends, and the completion thread latches and publishes FINISHED:COMPLETED over FINISHED:ABORTED
  (`job_runner.py:484-492, 524`: no check of the persisted status). Case C: third overwrite site of the confirmed F1
  mechanism (F1 lists :670 and :711), reachable when the SJ ends during `_start_run` (F3's confirmed precondition;
  with an SJ execution error the published status is EXECUTION_EXCEPTION). `run_aborted` is set only on the RUNNING
  path (`job_runner.py:802-811`), so CmpPublish can overwrite ABORTED only through the store-only abort.
- [residual] KnownOverwrite: added `o.w = "CmpPublish" /\ o.from = ABORTED` (hunting residual only).
- MC_conv.cfg BFS, 30 min (`spec/output/MC_conv_r1_run3.out`): no violation; 448,903,190 states generated,
  82,819,524 distinct, BFS depth 33, 32,473,737 left on queue at the time limit (state space not exhausted).
- MC_conv.cfg simulation, 30 min, depth 100 (`spec/output/MC_conv_r1_sim1.out`): no violation; 219,007,639
  states checked, 2,134,199 traces (mean length 58).
- No Case A or Case B counterexample in this round: Phase 2 changed no action (only the hunting residual
  `KnownOverwrite`, which Trace.cfg does not use). Re-validation of all 30 traces against the final spec: 30/30
  (`spec/output/trace_validation_r1_final_converged.txt`).

## Round 1 - Convergence
Phase 1 passed after its fixes; Phase 2 then passed with no spec (behaviour) modification -> converged in 1 round.
Converged spec snapshot: `spec/history/r1-converged/` (base.tla sha256 db3585e7...).

## Bug Hunting - seed fidelity regression (converged spec r1)
All confirmed seeds still reproduce (2 workers each, `spec/output/MC_seed_*_r1.out`):
F1 `AbortHonored` (12 states, DISPATCHED over an acked abort); F2 `RunnerAliveInv` (6 states, RS-1 delete during
the scan); F3 `TerminalStable` (24 states, SJ error during `_start_run`, publish, then RUNNING); F5
`FinalMatchesOutcome` (27 states, fail_run pops pending -> KeyError at `:360` -> FAILED_TO_RUN); F9
`ResourceConservation` (15 states, unsupported app-dir removal). MC_seed_F16.cfg stops at the shallower F1
overwrite under `TerminalStable` (the Phase-2 run did too: `tlc-scratch/out_MC_seed_F16.txt`), so
- [mc-control] MC.tla: added checker-only probe `NoRefreshWriteOverwrite` and MC_seed_F16_refresh.cfg (F16 config,
  that invariant only). Result: violated in 30 states -- the queued job's abort lands between `RunnerRefreshRead` and
  `RunnerRefreshWrite`, which writes SUBMITTED back over FINISHED:ABORTED (F16) (`spec/output/MC_seed_F16_refresh_r1.out`).

## Bug Hunting - runs
- [bug] AdminDeleteExec (MC-C): MC_hunt_s2_slots.cfg BFS, `NoOrphanSlotNovel` violated in 22 states
  (`spec/output/MC_hunt_s2_slots_bfs1.out`): `AdminDeleteAuthorize(j1)` snapshots j1 while SUBMITTED; j1 is
  scheduled, deployed, started (JOB_STARTED takes the only slot) and set RUNNING; `AdminDeleteExec` checks only the
  snapshot (`job_cmds.py:507-521`) and deletes the RUNNING job. The completion thread's publish then raises
  StorageException on every pass (`filesystem_storage.py:266-267, 323-324`) and `continue`s
  (`job_runner.py:523-530`), so j1 never leaves running_jobs and JOB_COMPLETED never releases its scheduler slot;
  with max_jobs = 1 no later job is admitted. Case C: same TOCTOU root cause as the confirmed RS-8/K2v (delete during
  `_start_run` kills the runner), new consequence when the delete lands after `job_runner.py:711` (runner survives,
  slot and running_jobs entry leak permanently).
- [residual] NoOrphanSlotNovel: refactored `NoOrphanSlot` into `SlotOwned(j)` (identical contract) and added the
  MC-C tolerance (slot of a deleted job still in running_jobs) to the residual only.
- [bug] CmpRemove (MC-D): MC_hunt_s2_slots.cfg BFS run 2, `CompletionAlive` violated in 28 states
  (`spec/output/MC_hunt_s2_slots_bfs2.out`): delete authorized on a SUBMITTED snapshot; j1's SJ fails during
  `_start_run`; the runner inserts j1 into running_jobs (`:709-710`); the completion thread latches and publishes
  FINISHED:EXECUTION_EXCEPTION; the delete executes (stale snapshot); `set_status(RUNNING)` (`:711`) raises; the
  runner's except path removes j1 from running_jobs (guarded, `:716-717`); the completion thread's unguarded
  `del self.running_jobs[job_id]` (`:532`, no try) raises KeyError and the thread ends -- no later job is ever
  finalized or releases its slot (the runner also dies at `:720`, F2). Case C: RS-7 mechanism (confirmed in the
  analysis phase only with an injected store error at `:711`), here reached through supported operations (F3 timing
  plus the delete TOCTOU; a double race, low likelihood; any transient store error at `:711` reaches the same state).
- [residual] NoOrphanSlotNovel: added `cpc.pc = "Dead"` (orphans left by the MC-D dead completion thread).
- [mc-control] MC_hunt_s2_slots_c2.cfg = MC_hunt_s2_slots.cfg without `CompletionAlive` (its only violating
  transition is MC-D) for the continuation run.
- MC_hunt_s1_status.cfg BFS 30 min (`spec/output/MC_hunt_s1_status_bfs1.out`): no violation; 305,823,584 states,
  62,171,619 distinct, depth 36, 18,941,867 queued at the limit.
- MC_hunt_s2_slots_c2.cfg BFS 30 min (`spec/output/MC_hunt_s2_slots_c2_bfs1.out`): no violation; 311,217,083
  states, 56,717,106 distinct, depth 45, 12,487,571 queued.
- [bug] CmpFinalizeBegin / AdminStopRun (MC-E): MC_hunt_s4_outcome.cfg BFS, `FinalMatchesOutcomeNovel` clause (a)
  violated in 24 states (`spec/output/MC_hunt_s4_outcome_bfs1.out`): j1 RUNNING (its START was lost; non-strict
  start ignores it); admin abort -> `stop_run` = `_stop_run` then `mark_run_aborted` (`job_runner.py:798-800`);
  `_stop_run` sends the SJ ABORT and waits <= 1 s for the reply (`server_engine.py:354-383`); the SJ aborts, fires
  UPDATE_RUN_STATUS(execution_error=False) and exits 0 (`server_commands.py:106-118`,
  `server_app_runner.py:84-91`); `wait_for_complete` pops the entry; the completion thread (run_aborted still
  False, no exception record) latches and publishes FINISHED:COMPLETED; `mark_run_aborted` comes too late. Case C:
  an admin-aborted running job is reported as successfully completed, although `mark_run_aborted` exists to make it
  FINISHED:ABORTED (`job_runner.py:486-487`). Realistic window: the SJ's abort reply is slow or lost (optional,
  1 s) while the SJ exits quickly. Matches the spec-generation smoke-test candidate (brief-coverage 8).
- [residual] New write-only history variable `latchInStopWin[j]` (set by `CmpFinalizeBegin` when it latches while
  the admin is between `_stop_run` and `mark_run_aborted`, i.e. `adm[j].pc = "MarkAborted"`, with run_aborted
  False); `FinalMatchesOutcomeNovel` clause (a) tolerates `sjAbortHandled` only in that case. No action guard or
  non-history update reads it (added to histVars, ViewS4); contract `FinalMatchesOutcome` unchanged. Sanity:
  3 traces re-validated.
