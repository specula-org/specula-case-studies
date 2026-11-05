# Candidate: an admin-aborted running job can be finalized as FINISHED_COMPLETED

**Found by:** model checking with a hypothesis-free property. The violated property was `GenericProps!GFinishedNoAbnormalExit`, in BFS sweep `bfs1b`, mix JobSP=F (all other groups coarse), profile `abort` with always-on timers, 1 site. It took 41 steps (`ABORT_classified_completed.ce.txt`).

**Not in Phase 1:** the v2 lifecycle notes describe the `run_aborted` latch as a mechanism (`working-notes.md:10`), but there is no hazard about the order in which it is set.

## Mechanism (pin c411a201)

- `JobRunner.stop_run` (job_runner.py:888-890) runs `_stop_run(job_id)` first. That aborts the clients (`abort_client_run`) and then the server app (`engine.abort_app_on_server`, job_runner.py:425-446). Only after `_stop_run` returns does it call `mark_run_aborted`, which sets `job.run_aborted = True` (job_runner.py:892-897).
- The completion thread `_job_complete_process` (job_runner.py:492-592) polls every 1 s, independently of `stop_run`.
  - It waits for pending client outcomes only while `pending and not job.run_aborted` (line 517).
  - It then sets `status = FINISHED_ABORTED if job.run_aborted else self._get_finished_job_status(...)` (lines 536-541) and caches the result in `_finished_job_states`.
- `_classify_finished_job_status` (lines 594-619) returns FINISHED_COMPLETED if the job cell already reported finished, or if `run_process` is None.

**Race:** the clients are aborted first, so their CPs report outcomes and `pending` empties. The SJ then ends after the abort and reports finished. If the completion thread's 1 s poll runs before `mark_run_aborted`, the status is computed with `run_aborted = False`. The job is cached as FINISHED_COMPLETED, and the later `run_aborted = True` has no effect.

The model CE reaches the same classification through the outcome-grace path (`OutcomeGraceExpired`). That path is timing-implausible: the grace is 900 s. The pending-empty path above is the plausible one.

## Timing check against the source (2026-11-04): timing-implausible

The CE's order is: admin stop thread in `_stop_run` (`stopWait`) → `ServerEngineTerminateAfterGrace` (cleanup thread kills the SJ) → `RemoveAfterTerminate` (run_processes pop) → completion thread classifies → only then `mark_run_aborted`. The real code does not allow this order except in a microsecond window:

- `abort_app_on_server` (server_engine.py:355-382) sends ABORT with `timeout=1.0`, then starts `_remove_run_processes` on a new thread and **returns immediately**. `stop_run` calls `mark_run_aborted` right after (job_runner.py:888-890). The graceful path removes the run process only after the SJ exits (`wait_for_complete` pop, after the SJ's teardown plus up to 2 s waiting for UPDATE_RUN_STATUS) or after `graceful_wait = 10 s` (`_remove_run_processes`). Both are seconds after `run_aborted = True`.
- The completion thread ignores a job while it is in `run_processes` (job_runner.py:496), so it cannot classify before that pop.
- The only short window: the ABORT send raises → `graceful_wait = 0` → the cleanup thread terminates and pops at once, and the completion thread's 1 s poll lands between that pop and `mark_run_aborted` on the main thread (microseconds). On top of that, `pending` must already be empty (all CPs reported outcomes before the abort), because the client aborts sent microseconds earlier cannot have produced outcome reports yet.

The model has no ordering between the admin thread's return and the cleanup thread's grace wait, so it explores the implausible order freely.

**Verdict:** model-only; timing-implausible. Not a reportable bug. The narrow ABORT-send-failure window is noted, not pursued.

## Evidence level

- Model: reachable in fine JobSP (seed-derived).
- Source: reading supports it.
- Real execution: NOT REPRODUCED yet.

Next step: a unit or POC test that delays `mark_run_aborted`, or that polls the completion thread right after `abort_app_on_server`, and checks the terminal status.

**Impact:** the user aborted the job, but the job reports COMPLETED. Downstream automation that keys on the status, for example model publication or billing, treats an aborted run as successful.
