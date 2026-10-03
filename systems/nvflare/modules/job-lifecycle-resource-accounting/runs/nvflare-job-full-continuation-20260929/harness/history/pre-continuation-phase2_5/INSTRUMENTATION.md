# nvflare-job trace harness: instrumentation guide (for Phase 3)

Category A harness: one linear NDJSON trace per scenario, produced by the **real** product code of the pinned source
(`53ba7ee5`) running server parent (SP) and client parents (CP) in one Python process. Only the CellNet edge and
the SJ/CJ processes are stubbed. Every line has `"tag":"trace"`, a real `ts` (epoch ns, as a string), `seq`, the
emitting `thread`, and `event = {name, job, cl, [msg], [arg], state}` with the full post-state snapshot required by
`spec/Trace.tla` (`ValidatePostState` compares every field on every event).

## 1. Files

| Path | Role |
|---|---|
| `patches/instrumentation.patch` | Hooks in 11 product files (81 `TLA-TRACE` markers). |
| `src/tla_hooks.py` | No-op hook API, copied into the build as `nvflare/fuel/utils/tla_hooks.py`. Hooks do nothing unless a tracer is installed. |
| `src/nvf_tracer.py` | Trace backend: trace lock `T`, section stack, deferred outbox, snapshot (state mapping), NDJSON writer, side tables. |
| `src/nvf_env.py` | Environment: real `FederatedServer`/`ServerEngine`/`RunManager`/`ClientManager`/`JobRunner`/`DefaultJobScheduler`/`SimpleJobDefManager`+`FilesystemStorage`/`JobCommandModule`, and real `ClientEngine`/`JobExecutor`/`ListResourceManager`/request processors. Stubs: `Network`, `StubAdminServer`, `Stub{Server,Client}Cell`, `StubFedClient`, `FakeProc` (inside the real `ProcessHandle`), stub SJ/CJ launchers, `GatedTime`. |
| `src/nvf_scenarios.py` | Scenarios (section 6) and helpers (`Gate`, `wait_ev`, network policies). |
| `src/run_scenario.py` | Runs one scenario. It refuses to run unless `nvflare` resolves to the instrumented copy. |
| `src/trace_inspect.py` | Compact listing of a trace, or a window around the first event TLC could not match (`--tlc-log`). |
| `apply.sh` / `make_patch.sh` / `clean.sh` | Build the instrumented copy / regenerate the patch from it / remove `build/`. |
| `run.sh` / `validate.sh` / `stress.sh` | Build and run all scenarios into `../traces/` / TLC trace validation / N parallel rounds to check flakiness. |

The arm's source tree is **never modified**. `apply.sh` extracts `git archive 53ba7ee5 nvflare` into
`build/nvflare_src`, adds `tla_hooks.py`, commits that as the base of a throwaway git repo, and applies the patch as
working-tree changes. `build/PROVENANCE` records the patch and hook hashes.

## 2. Rebuild and re-run

```bash
cd .specula-output
bash harness/run.sh                                  # apply + run the 29 default scenarios -> traces/*.ndjson
VALIDATE=1 bash harness/run.sh                       # ... and TLC-validate each trace
SCENARIOS="normal_two_jobs start_failures" bash harness/run.sh
bash harness/validate.sh traces/<name>.ndjson        # TLC: spec/Trace.tla + spec/Trace.cfg, JSON=<trace>
python3 harness/src/trace_inspect.py traces/<name>.ndjson --tlc-log harness/build/validation-logs/<name>.log
bash harness/stress.sh 3                             # 3 parallel rounds; results in harness/build/stress/
```

`validate.sh` runs TLC directly with `-metadir harness/build/tlc-meta`. The MCP validator's
`/tmp/tlc_validation` path is a dangling symlink into another user's home on this host and is not writable. Each run
uses 1 worker and `-Xmx4g`. Uses the Python env from `PATH`; `run.sh` sets `PYTHONPATH=build/nvflare_src:src`.

**Editing hooks:** edit `harness/build/nvflare_src/...`, then run `bash harness/make_patch.sh` **before** the next
`run.sh`/`apply.sh`. `apply.sh` wipes and rebuilds `build/nvflare_src`, so unsaved edits there are lost.

## 3. Section model (how an event is emitted)

- `with _tla.section("Name", job=..., cl=...)` and `_tla.begin("Name")` .. `_tla.end("Name")` delimit one traced
  atomic step. The outermost section of a thread takes the process-wide trace lock `T` **before** the traced state
  change. At its end it writes one line with the post-state snapshot and releases `T`. The NDJSON order is therefore
  a linearization, and no snapshot can observe a half-done step.
- Nested sections are absorbed. For example, `stop_run` inside `SpProcessJobFailure` emits no `AdminStopRun`.
  `end(name)` and `cancel(name)` act only if `name` is the innermost open section. `emit(name)` writes an intermediate
  event inside the open section (`CmpOutcomeDeadline`, `SweepBegin`). `event(name)` is a one-shot section.
- A step that raises is closed by the handler that catches it: `_tla.end_open()` in `JobRunner.run`'s `except` block
  and in `StartJobProcessor`'s `except` block. A thread that dies with an open section is closed by
  `threading.excepthook`, or by the harness thread wrapper for the runner. The event then carries an `"error"` field.
- **Deadlock rules:** `T` is always taken before product locks, and the snapshot takes no product locks. `T` is never
  held while waiting for an RPC reply. Stub sends made inside a section are queued in the thread's outbox and
  delivered after the event line is written; the sender sees an injected timeout. This is used only where the product
  ignores the reply: ABORT fan-out from `_stop_run`/completion, the SJ ABORT command, REPORT, UPDATE_RUN_STATUS, and
  the CJ ABORT. A watchdog aborts the process (exit 3, stack dump) if `T` cannot be obtained within 120 s.
- **Hook arguments** are only locals or objects (`engine=self`, `executor=self`, `msg=req`, `replies=replies`), never
  derived attributes. The tracer resolves client names and Collect/Timeout names only when tracing is on, so with
  tracing off a hook cannot raise. Product unit tests give identical outcomes on the pristine and instrumented code
  (`evidence/unit_test_equivalence.txt`).
- `when="ctx"` makes a section conditional on a harness context. `runner_scan` is set by
  `get_jobs_to_schedule`, `rmw:<Prefix>` around the two status-reverting read-modify-writes, and `admin_delete` by the
  harness around delete commands. `@rmw.read` / `@rmw.write` resolve to `<Prefix>Read` / `<Prefix>Write`.

## 4. Instrumentation points (file:line in `harness/build/nvflare_src` after `apply.sh`)

| Event(s) | Location | Section extent / notes |
|---|---|---|
| RunnerScanList | apis/impl/job_def_manager.py:521 | around `store.list_objects` (only in `runner_scan` context, set at :515) |
| RunnerScanRead | job_def_manager.py:528 → app_common/job_schedulers/job_scheduler.py:277 | from the first meta read (tags included) until the end of `_exceed_max_jobs` |
| RunnerScanReadDeleted | job_def_manager.py:540-541 | `get_meta` raised for a listed object (re-raised; run() dies) |
| RunnerTryNext | job_scheduler.py:202 (CHECK branch, tracer increments att), :365 (blocked), :383 (no CHECK), :302 (`_try_job` raised) | one per candidate |
| RunnerBackoffSkip / RunnerTryDone | job_scheduler.py:374 / :396 | TryDone only if the candidate list was non-empty |
| RunnerCheckCollect / RunnerCheckTimeout | private/fed/server/server_engine.py:1031 | after `_send_admin_requests`; the tracer names it Timeout if a reply is missing/`None` |
| RunnerRefreshRead / RunnerRefreshWrite | app_common/storages/filesystem_storage.py:270 / :282 (context set at job_scheduler.py:311, :316) | the two halves of `update_meta` (gate `rmw.between` at :280) |
| RunnerSetCantSched | job_scheduler.py:318 | around `set_status(FINISHED_CANT_SCHEDULE)` |
| RunnerCheckSubmitted / RunnerCheckDispatched | private/fed/server/job_runner.py:778 (`_check_job_status`) | around `get_job` + compare; emitted on raise too |
| RunnerDeployJob | job_runner.py:227 (unknown clients, `failed=[]`), :284 (deploy failure), :288 (success) | exits of `_deploy_job`; `arg.failed` mapped to c-names |
| RunnerSetDispatched | job_runner.py:697 | around `set_status(DISPATCHED)` |
| RunnerMetaRead / RunnerMetaWrite | filesystem_storage.py:270 / :282 (context `rmw:RunnerMeta` at job_runner.py:702) | the RMW at :674 of the pinned file |
| RunnerStartServerApp (/Fail) | job_runner.py:301 → :317 | `get_job_clients` .. SJ launch .. pending registration; the stub SJ launcher renames it `RunnerStartServerAppFail` when it raises; an error return is closed by run()'s handler (:747) |
| RunnerStartCollect / RunnerStartTimeout | job_runner.py:322 → :377 | after `start_client_job` returns .. JOB_STARTED; the tracer names it Timeout if a START reply is `None`; raises closed at :747 |
| RunnerInsertRunning / RunnerSetRunning | job_runner.py:739 / :743 | around the insert under `self.lock` / around `set_status(RUNNING)` |
| RunnerExceptStop / RunnerExceptSetFailed / RunnerExceptMeta | job_runner.py:748→755 / :756 / :759→767 | except path; ExceptMeta ends after JOB_ABORTED (or when `update_meta` raises: run() dies, closed by the thread wrapper) |
| CmpFinalizeBegin / CmpOutcomeDeadline | job_runner.py:460 → :511; :492 (intermediate emit) | from the `run_processes` pre-check to the latch; cancelled (:488, :562, :565) when there is nothing to finalize |
| CmpPublish / CmpRemove | job_runner.py:543 / :552 → :564 | publish `set_status`; `del running_jobs` .. events .. `remove_exception_process` (a KeyError kills the thread, closed by excepthook) |
| AdminStopRun / AdminMarkAborted | job_runner.py:843 / :845 (`stop_run`) | absorbed when called inside `SpProcessJobFailure` |
| AdminAbortBegin / AdminAbortWrite | private/fed/server/job_cmds.py:1070 / :1080 | Begin cancelled unless SUBMITTED/DISPATCHED/RUNNING |
| AdminDeleteAuthorize / AdminDeleteExec | job_cmds.py:301 / :514 | only in the `admin_delete` context (set by `Env.admin_delete`) |
| AdminDisable | server_engine.py:630 | around `disable_client` + token cleanup |
| SpWaitForComplete | server_engine.py:219 (after pop), :237 (entry already gone) | the ≤2 s UPDATE_RUN_STATUS wait is **outside** the section |
| SpRemoveRunProcesses | server_engine.py:406 | `terminate()` + final pop (the ≤10 s wait loop is outside) |
| SpUpdateRunStatus / SpProcessJobFailure | private/fed/server/fed_server.py:599 / :912 (wrapper method) | whole handler |
| SweepBegin / SweepEnd | fed_server.py:1116 (emit) / :319 (section around `logout_client`) | `logout_client` .. pending loop (SweepBegin) .. run_processes loop (SweepEnd) |
| CpCheckResource / CpCancelResource | private/fed/client/scheduler_cmds.py:69 / :161 | whole resource-manager call |
| CpStartAllocate (/AppMissing) | scheduler_cmds.py:123 → private/fed/client/client_engine.py:360/:370/:372 | allocate .. `start_app` status + app-dir checks; failures closed at scheduler_cmds.py:145 after the free |
| CpStartRegister | client_executor.py:303 → :312 | STARTING registration; "still registered" raise closed at scheduler_cmds.py:145 after the free |
| CpStartLaunch (/Fail) | client_executor.py:315 → :344 (renamed at :321) | launch .. attach (pending abort honoured) .. waiter thread start |
| CpAbortApp | client_engine.py:397 → client_executor.py:522/:531/:545/:549/:558 (or client_engine.py:404/:408/:412) | status read .. abort recorded (.. `terminate()` / CJ ABORT fired / `_terminate_job` started), before the join |
| CpTerminateJob | client_executor.py:601 → :606 (early return) / :620 (after `terminate()`) | per poll iteration; cancelled (:613) between polls |
| CpChildFinished | client_executor.py:650 → :704 | reap .. rc remap .. REPORT (deferred) .. free .. pop |
| CpTick | app_common/resource_managers/auto_clean_resource_manager.py:106 → :120 | one real tick body; no event when nothing is reserved |
| SjFinish / SjCrash / SjHandleAbort | src/nvf_env.py `Env.sj_finish` / `sj_crash` / `sj_handle_abort` | stub SJ at the process edge |
| CjNotifyStarted / CjNotifyStopped / CjHandleAbort | `Env.cj_notify_started` / `cj_notify_stopped` / `_cj_on_abort` | wrap the real `NotifyJobStatusProcessor` |
| CjExit / CjGroupExit | `Env.cj_exit` / `cj_group_exit` | stub CJ leader / descendants |
| Heartbeat | `Env.heartbeat` | CP `get_all_job_ids` + real `FederatedServer._sync_client_jobs`; the abort list is then processed by the real `Communicator._clean_up_runs` (CpAbortApp, flag=TRUE) |
| ClientCrash | `Env.client_crash` | CP stops; its CJs exit; queued requests to it are purged |
| LoseMsg | `Network.lose` (drop policy or `drop_held`) | identity = the dropped message |

Reproduction gates (no-op unless a scenario registers them; never honoured while `T` is held):
`runner.after_scan_list` (job_def_manager.py:525), `runner.before_check_submitted` (job_runner.py:686),
`runner.after_deploy` (:696), `runner.before_check_dispatched` (:726), `runner.before_set_running` (:742),
`runner.after_start_client_job` (:319), `rmw.between` (filesystem_storage.py:280).

## 5. State mapping, observation decisions and reproduction controls

The snapshot is built by `Tracer.snapshot()` in `nvf_tracer.py`. Mapping follows instrumentation-spec 1.2.
Observation decisions that refine the spec's text are listed here; they are observation fixes, not model or property
changes:

- **`jobs[j].run_aborted`** is the flag of the Job object that the server most recently held in `running_jobs`, and
  it stays sticky after `CmpRemove`. The instrumentation spec's "else false" clause would contradict `base.tla`, where
  `CmpRemove` leaves `runAborted` unchanged.
- **Deleted jobs:** `schedule_count` and `tagged` keep their last observed values after the object is deleted. The
  implementation's tag file disappears with the directory, while `AdminDeleteExec` changes only `status`. If Phase 3
  prefers the literal tag-file view, change `snapshot()`: every trace that deletes a tagged job, such as
  `abort_running_and_queued`, will then fail at `AdminDeleteExec` until `base.tla` untags on delete.
- **`starting` / `allocated`** are harness side tables keyed by (client, job), as the instrumentation spec defines.
  `starting` is set at `CpStartAllocate` with the allocated units, unless the "already started" branch leaked them.
  It moves to `allocated` at `CpStartLaunch`. `CpStartLaunchFail` and `CpStartRegister`-failure clear it after the
  free. `CpChildFinished` clears `allocated`.
- **Tokens → att:** the tracer counts `RunnerTryNext(check=True)`, the stub attaches that att to the CHECK requests
  it sends, and `CpCheckResource` records `token → (att, job)` for reserved tokens. CANCEL and START identities, and
  `reserved[].att/job`, use that table.
- **`RunnerStartServerApp` on an error return** ("already started"): the event is emitted and then `RunnerExceptStop`.
  This follows `base.tla`, whose action has an `rp ≠ None` branch leading to ExceptStop. The instrumentation spec's
  "emit RunnerExceptStop next instead" is ambiguous.
- **`CpTick`** is not emitted for a tick that runs while nothing is reserved; that tick changes nothing, and the
  spec action requires reservations.
- **Unresponsive CJ** (`on_abort="ignore"`): no `CjHandleAbort` event. The `stop_only` behaviour (handles the abort,
  slow to exit) is the cooperative variant used in the default scenarios.

Reproduction controls (timing and edge only, behavior-preserving):
- Network policies: deliver, hold (sender times out and the message may be processed later with its reply
  discarded), drop (`LoseMsg`), or fail (DEPLOY error reply). A dead CP never processes requests.
- Deferred delivery with injected timeout for sends made inside a traced step (section 3).
- `GatedTime` replaces `auto_clean_resource_manager.time`, so the real expiry thread runs exactly one real tick per
  `Env.tick`.
- `client_outcome_wait_timeout` is set via `ConfigService` `var_dict`; `heart_beat_timeout` is large, and the harness
  calls the real `remove_dead_clients` after back-dating the crashed client.
- The tla_hooks gates listed in section 4. `FakeProc` models `ProcessAdapter`: `poll`/`wait`/`killpg`, with no kill
  after reap. The real `ProcessHandle` maps return codes. The stub CJ exits 0 only when STARTED/STOPPED and writes
  the rc-102 file only while STARTING (cooperative CJ).

## 6. Scenarios and current validation status (spec/Trace.cfg as delivered)

All 29 default scenarios run to completion (`run.sh` exit 0). With `VALIDATE=1`, 26 traces pass and 3 fail on the
two discrepancies in section 7. The result was stable in 3 parallel stress rounds. 64 of 65 `Trace.tla` event types
appear; `CpStartAllocateAppMissing` appears only in the opt-in `unsupported_app_missing`, which passes when
`EnableUnsupported = TRUE`.

| Scenario | Exercises | TLC |
|---|---|---|
| normal_two_jobs | full lifecycle ×2, heartbeats, CjGroupExit | PASS |
| abort_running_and_queued | queued abort (store-only), running abort (stop_run, SJ abort, abort cleanup, 10 s kill), delete refused/done | PASS |
| check_timeout_backoff_expiry | held CHECK → timeout → cancel → refresh RMW; late CHECK reserves; expiry ticks; back-off; retry runs | PASS |
| lossy_check_cant_schedule | LoseMsg CHECK ×2 → CANT_SCHEDULE; later job still admitted | PASS |
| start_failures | SJ launch fail; CJ launch fail (ERROR reply fails whole job); deploy fail on required site; orphan reservations expire | PASS |
| client_failure_and_sj_crash | CJ rc 1 → EXCEPTION report → fail_run; SJ crash → EXECUTION_EXCEPTION | PASS |
| client_crash_sweep | CP crash, dead-client sweep (SweepBegin/End), completion from remaining outcome | PASS |
| outcome_deadline_hb_cleanup | CmpOutcomeDeadline; heartbeat cleanup aborts the orphan CJ | PASS |
| disable_client_outcome_wait | AdminDisable; rejected report; finalize by deadline (F12 shape) | PASS |
| delete_held_job_kills_runner | seed F2 (delete before SUBMITTED re-check → runner dies) | PASS |
| delete_during_scan | RunnerScanReadDeleted → runner dies | PASS |
| abort_during_deploy | seed F1 (acked abort overwritten by DISPATCHED; job runs) | PASS |
| failrun_during_start | seed F5 (KeyError after fail_run → FAILED_TO_RUN), ordered so no duplicate ABORT is in flight | PASS |
| failrun_during_start_dup_abort | F5 with overlapping stop paths: two identical ABORTs to c2 and to the SJ | **FAIL** (7.1) |
| refresh_rmw_revert | seed F16 (refresh RMW reverts an acked abort to SUBMITTED; job runs) | PASS |
| running_after_terminal | seed F3 (RUNNING written after terminal publication) | PASS |
| start_timeout_late_start | held START → RunnerStartTimeout; late START launches an orphan CJ; heartbeat cleanup | PASS |
| concurrent_jobs_contention | max_jobs=2, 1 unit/client: concurrent jobs, NO_RESOURCE retries, partial dispatch | PASS |
| expiry_before_start | reservation expires during deploy → allocate error → FAILED_TO_RUN | PASS |
| disable_between_schedule_and_deploy | "unknown clients" at deploy fails a job min_sites could run (F15 shape); later job runs | PASS |
| abort_before_checks | abort before SUBMITTED / DISPATCHED re-checks (skip paths; F6 orphan reservations) | PASS |
| lost_report_heartbeat | lost REPORT → heartbeat → fail_run(INFRA) → FINISHED:ABNORMAL | PASS |
| double_abort_terminate | admin abort + heartbeat-cleanup abort of a slow-exiting CJ → two `_terminate_job` threads | **FAIL** (7.2) |
| random_mix_s1 … s6 | seeded mix of aborts, deletes, SJ/CJ failures, holds/drops, heartbeats, ticks, max_jobs=2 (timing-dependent) | s2–s6 PASS; s1 **FAIL** (7.2) |
| unsupported_app_missing (opt-in) | seed F9 trigger (outside the supported envelope) | FAIL by design; PASS with EnableUnsupported=TRUE |

Random scenarios are timing-dependent. In two sweeps of seeds 7–40, 30 and then 31 of 34 passed. Every failure
(s8, s29, s30, s31, s40, depending on the run) stopped at a second `CpTerminateJob`, which is 7.2. No other failure
class appeared after the harness fixes in section 8.

## 7. Trace-validation discrepancies found (spec/model side; harness verified)

1. **Duplicate identical messages.** `msgs` is a set in `base.tla`. The implementation can have two identical
   requests in flight: here `fail_run`'s `_stop_run` and the runner's exception-path `_stop_run` each send
   `ABORT(j1)` to c2 and to the SJ, and both copies are delivered and processed (`CpAbortApp` twice, `SjHandleAbort`
   twice). In the spec the copies merge, so the second consumption (the second `CpAbortApp(c2)` in
   `failrun_during_start_dup_abort`, #28 or #29 depending on the interleaving) has no message. A candidate model fix
   is a message bag, or treating duplicate requests explicitly.
2. **Several pending `_terminate_job` threads per (client, job).** `termP[c][j]` is a boolean, but every
   `CpAbortApp` on a STARTED/STOPPED registration starts a new `_terminate_job` thread. For example, an admin abort
   and then a heartbeat-cleanup abort while the CJ is still stopping. Each thread ends with its own `CpTerminateJob`,
   and the second one (`double_abort_terminate` #68, `random_mix_s1` #96) finds `termP = FALSE`. A candidate fix is
   a counter.
3. **Not observed yet, but worth checking.**
   - `SpWaitForComplete`: the `run_processes` entry is read before the ≤2 s wait. If `_remove_run_processes` pops it
     during the wait, the code still records a non-zero rc from the stale dict, while `base.tla` leaves `exc`
     unchanged when `rp = None`.
   - The completion loop calls `remove_exception_process` even when the job vanished from `running_jobs` between the
     key snapshot and `get`. That is an untraced `exc` change with no spec action.
   - `SweepEnd`'s Dead branch needs a concurrent `run_processes` change **during** the loop, which cannot happen
     while the sweep holds `T`.

## 8. Harness fixes made while validating (harness side only; no product, model or property change)

- **CJ "ignore" behaviour.** It emitted `CjHandleAbort` without writing STOPPED. An unresponsive CJ now emits no
  event. The default scenarios use the cooperative `stop_only` variant: the CJ handles the abort but is slow to exit.
- **Network hold queue.** `release`/`drop_held` evaluated the (randomized) selection predicate twice per message, so
  one held CHECK was both reported lost and later delivered (seen in `random_mix_s6`). It is now a single-pass
  partition; seed 6 and seeds 7–40 no longer show that failure class.
- **Scenario ordering.** `failrun_during_start` now waits for fail_run's stop to settle before releasing the runner.
  The overlapping variant is kept separately as `failrun_during_start_dup_abort`, the reproducer for 7.1.
- **Random drain.** The randomized drain now also waits for queued jobs, so random traces end with every job terminal.
- **Hook arguments.** An earlier patch revision passed `cl=self.client_name` / `cl=client.client_name` and computed
  Collect/Timeout names in product code. With tracing off, 7 product unit tests failed because their fakes lack these
  attributes, so the patch was not behavior-preserving. Hooks now pass only objects, and names are resolved in
  `Tracer._normalize`. The unit-test outcomes are now identical, and all traces were regenerated with the fixed patch.
- **Benign gate.** The `rmw.between` gate reached inside other traced steps is ignored silently. `validate.sh` writes
  TLC's trace-explorer specs to `build/tlc-ttrace/`, not `spec/`. Earlier runs had left `Trace_TTrace_*` files in
  `spec/`; they were moved to `build/tlc-ttrace/dev-runs/`.

## 9. Evidence kept outside `build/`

`harness/evidence/`:
- `run_final.log`: the official `VALIDATE=1 run.sh` output for the delivered traces.
- `validation/<trace>.tlc.log` and `<trace>.stuck-window.txt`: TLC counterexamples for the three failing official
  traces, with the event window around the first unmatched event.
- `stress_default_3rounds.txt`: 3 parallel rounds of the default set.
- `stress_random_seeds_7_40.validate.txt`: one round of seeds 7–40.
- `unit_test_equivalence.txt`: product unit tests (1703 outcomes) on the pristine vs instrumented code, tracing off.
