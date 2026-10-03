# NVFlare job lifecycle and resource accounting — Specula Lite report

- **Target**: `/home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/lite/source`
- **Revision**: `53ba7ee567468ea7971dad4faccef13c6cb35dc2` (clean tree at start; product source unchanged at end — `git status` shows only the untracked `.specula-lite/` directory)
- **Date**: 2026-09-25. Single agent, Specula Lite workflow (code analysis → TLA+ modeling → TLC → real reproduction → report).
- **Trace validation was NOT performed** (no instrumentation, no implementation traces, no Trace.tla). TLC counterexample traces are used as model evidence only.
- **Scope**: default local-process launch path — scheduling/resource reservation, deployment, startup, termination and cleanup on the server parent and client parents, plus adjacent callers and exception handlers that decide resource ownership, job status and admission of later jobs. Excluded: training aggregation, model transfer, GPU computation, alternative launchers (Docker/K8s/Slurm), HA recovery.

All paths below are relative to the repository root unless stated otherwise; investigation artifacts live in `.specula-lite/job-lifecycle-20260925/`.

---

## 1. Summary

Seven defects were reproduced on the real implementation (a POC deployment: one server parent and two client parents as local OS processes, driven through the public FLARE admin API). Two model-checking candidates were refined as model/property artifacts. Five code-review candidates were ruled out or recorded as design choices.

| ID | Title | Status | Severity | Trigger surface |
|---|---|---|---|---|
| MC-2 | Deleting a queued job terminates the JobRunner scheduling thread; no later job is ever scheduled | REPRODUCED (black-box, 2 distinct windows) | Critical | `delete_job` on a SUBMITTED job |
| MC-1 | An acknowledged `abort_job` ("Aborted the job … before running it.") is lost; the job is deployed, started and completes | REPRODUCED (black-box, 8/8 attempts) | High | `abort_job` while the job is being dispatched |
| T-1 | Client resource reservations of a job that failed to dispatch are never released by the server; later eligible jobs are rejected until expiry (300 s by default) | REPRODUCED (black-box) | High | ordinary deploy failure (site policy rejection) |
| MC-4a | The runner's unconditional `set_status(RUNNING)` can overwrite a terminal status → permanent "zombie" RUNNING job that cannot be aborted/deleted and breaks `nvflare poc stop` | REPRODUCED (controlled timing) | High | job whose SJ ends during start + runner delay |
| MC-4b | Admin abort of a live run can be published as `FINISHED:COMPLETED` (run_aborted is set only after the abort signals) | REPRODUCED (controlled timing) | Medium | `abort_job` on a RUNNING job + delay |
| CR-4 | A client failure report during `_start_run` pops the pending-outcome set → `KeyError` → job mislabeled `FINISHED:FAILED_TO_RUN` with a misleading error | REPRODUCED (controlled timing) | Low | client startup failure during START collection |
| CR-3 | `GPUResourceManager` accepts float / 0 `expiration_period` in its signature and checks, but its base class rejects them at construction | REPRODUCED (unit level) | Low | site `resources.json` |

Answers to the four investigation questions are in §7. Model checking found **no** reachable conflicting allocation or permanent capacity loss in the client resource manager within the checked bounds (Q1). The real defects are in the server-side lifecycle: unsynchronized status writes (Q3), missing cleanup on failure paths (Q2/Q4), and unhandled job-store exceptions that end scheduling (Q4).

---

## 2. Method, environment and evidence locations

- Methodology: bundled Specula guides (code_analysis, spec_generation, tla-checking-workflow, bug-confirmation, bug-classification) applied under the Lite rules (single agent, no trace validation, no persistent-finding registry).
- History: `git log` over the in-scope files (294 commits, ~150 matching bug-fix keywords). Only commit messages/trees are available; historical blobs are missing from the alternate object store, so historical diffs could not be read. **GitHub issues/PRs were not consulted** (pilot rules). "Novelty" below is therefore relative to the reachable local history only.
- Tools: Java 21 (`/usr/lib/jvm/java-21-openjdk-amd64`), tla2tools 1.8.0, CommunityModules 202505152026; Python 3.12.3 venv with `PYTHONPATH` set to this arm's source (verified: `nvflare.__file__` resolves to `lite/source/nvflare/__init__.py`).
- Resource ceilings respected: at most 2 concurrent TLC processes, ≤ 24 GB heap and ≤ 12 workers for any single run. An unrelated, idle root-owned TLC process (4+ days old, ~10 GB RSS, not part of this investigation) was present on the host; it was not touched.
- Reproduction environment (`repro/env.sh`): POC provisioned by `python3 -m nvflare.cli poc prepare -i repro/project_custom.yml` with an unused port (28402), `HOME` and `NVFLARE_POC_WORKSPACE` redirected into `repro/` (so nothing was written to the real home directory), job store and snapshot storage inside the POC workspace. Test job: `repro/probe_job.py` (ScatterAndGather + NPTrainer, numpy only, built-in allow-listed components).
- Controlled-timing runs ("Level 3") used a **copy** of the package in `repro/l3_src/` with env-controlled sleeps (default 0 = unchanged behavior); the exact diff is `repro/l3_src.patch` (three `time.sleep(float(os.environ.get(...)))` lines, no logic change). The arm's source tree was never modified.

Key artifacts:
- `modeling-brief.md`, `brief-coverage.md`, `NOTES.md`
- Lifecycle model: `models/lifecycle/{base.tla, MC.tla, *.cfg, changelog.md, output/}`
- Resource model: `models/resources/{base.tla, MC.tla, *.cfg, changelog.md, output/}`
- Reproduction tests: `repro/test_*.py`; outputs `repro/logs/*`; workspace archives `repro/archive/*.tar.gz`

---

## 3. Reproduced bugs

### Bug 1 — MC-2: Deleting a queued job terminates the JobRunner scheduling thread

- **Source**: MC (counterexamples `models/lifecycle/output/hunt_delete_1.log`, `hunt_delete_noscan_1.log`, `hunt_delete_noscan_nostat1_1.log`)
- **Status**: REPRODUCED (black-box, two distinct windows) — **Severity: Critical**
- **Novelty**: NEW relative to reachable local history (no commit message describes job-store exceptions escaping `JobRunner.run`; `38fa2c75` introduced the tag-file scan but not a fix). Public tracker not consulted.
- **Location**:
  - `nvflare/private/fed/server/job_runner.py:650` `job_manager.get_jobs_to_schedule(fl_ctx)` — outside the `try` at 666.
  - `nvflare/private/fed/server/job_runner.py:661` `self._check_job_status(...)` — outside the `try`; `_check_job_status` (736-739) dereferences `reload_job.meta` although `SimpleJobDefManager.get_job` returns `None` for a deleted job (`nvflare/apis/impl/job_def_manager.py:379-385`).
  - `nvflare/private/fed/server/job_runner.py:720` (`set_status(FAILED_TO_RUN)`) and 724 (`update_meta`) — inside the `except` block; `FilesystemStorage.update_meta` raises `StorageException` for a missing object (`nvflare/app_common/storages/filesystem_storage.py:267-268`); `get_meta` likewise (326-327).
  - `nvflare/private/fed/app/deployer/server_deployer.py:144-145` runs `job_runner.run(fl_ctx)` in a bare thread with no handler or restart.
- **Description**: `delete_job` is permitted for any job whose status is not DISPATCHED/RUNNING (`nvflare/private/fed/server/job_cmds.py:516`). A job's store status stays SUBMITTED during scheduling and the whole `_deploy_job`, and queued jobs are re-scanned every second. If the job object disappears while the runner is scanning, checking or dispatching it, a `StorageException`/`AttributeError` escapes `JobRunner.run` and the scheduling thread ends. The server keeps accepting submissions and admin commands, clients stay connected, running jobs still finish (the completion thread is separate), but **no job is ever scheduled again until the server process is restarted**. The traceback goes only to the process stderr (`poc_console.log`), not to the server's `log.txt`.
- **Trigger scenarios** (all ordinary admin operations):
  - (c) delete a job right after submission while it is being deployed → `set_status(DISPATCHED)` raises → the handler's `set_status(FAILED_TO_RUN)` raises again → thread ends.
  - (a) delete queued jobs the runner is *not* dispatching; a delete that lands between the scan's list and `get_meta` raises `StorageException` at line 650 → thread ends.
  - (b) model-only window (same root cause, not separately reproduced): delete between scheduling and `_check_job_status` → `None.meta`.
- **Developer intent**: FLARE API `delete_job` docstring (`nvflare/fuel/flare_api/flare_api.py:583-593`): "The job will be deleted from the job store if the job is not currently running." Unit test `tests/unit_test/private/fed/server/job_cmds_test.py:655` exercises deletion of a non-running job. No code or test treats a scheduler crash as acceptable.
- **Reproduction** (Level 0, public API only, unmodified source):
  - (c) `cd .specula-lite/job-lifecycle-20260925/repro && source env.sh && timeout 600 python3 test_bug2_delete_kills_runner.py --observe 90 --out logs/bug2_delete_L0_run1.json`

    ```
    "t_server_run_dir": 0.647, "status_a_before_delete": "SUBMITTED",
    "delete_reply": {"job_id": "7979ef21-...", "submit_records_marked_deleted": 0}, "t_delete": 0.66,
    "job_b_status_trace": [[0.06, "SUBMITTED"]], "job_b_final": "SUBMITTED",
    "connected_clients": ["site-1", "site-2"], "BUG": true
    Exception in thread Thread-3 (_start_job_runner):
      File ".../nvflare/private/fed/server/job_runner.py", line 670, in run
      File ".../nvflare/app_common/storages/filesystem_storage.py", line 268, in update_meta
    nvflare.apis.storage.StorageException: object .../jobs-storage/7979ef21-... does not exist
      (during handling) File ".../server_deployer.py", line 145, in _start_job_runner
      File ".../nvflare/private/fed/server/job_runner.py", line 720, in run
    nvflare.apis.storage.StorageException: object .../jobs-storage/7979ef21-... does not exist
    ```
    A later job B stayed SUBMITTED for the whole 90 s window (a normal job is picked up in < 1 s, `repro/test_sanity.py`). After a server restart, B was scheduled and completed. Full console: `repro/logs/server_poc_console_after_bug2.log`.
  - (a) `timeout 900 python3 test_bug2b_delete_queued_scan_race.py --queued 150 --out logs/bug2b_scanrace_L0_run1.json` (one long job holds the GPU unit so 150 queued jobs stay SUBMITTED; they are then deleted):

    ```
    "deleted": 150, "delete_seconds": 0.7, "runner_thread_exception": true, "crash_after_n_deletes": 40,
    "long_job_final": "FINISHED:COMPLETED", "eligible_job_status_after_60s": "SUBMITTED", "BUG": true
      File ".../job_runner.py", line 650, in run
      File ".../job_def_manager.py", line 514, in get_jobs_to_schedule
      File ".../job_def_manager.py", line 527, in _scan
      File ".../filesystem_storage.py", line 327, in get_meta
    nvflare.apis.storage.StorageException: object .../jobs-storage/6e309394-... does not exist
    ```
- **Model/implementation match**: the three TLC traces end in `rn.pc = "crashed"` with `why` = `scan:get_meta`, `stat1:get_job_none`, `except:set_status`; the two reproduced tracebacks match `scan:get_meta` and `except:set_status` exactly.
- **Severity reasoning**: a persistent loss of the whole scheduling service (every later eligible job starves) with no automatic recovery and no log-level signal, triggered by an allowed administrative operation. Manual server restart recovers.
- **Recommendation**: guard every job-store access in `JobRunner.run` (move lines 650/661 inside the loop's `try`, treat a vanished/None job as "skip"); wrap the `except` block's status/meta updates in their own `try`; make `_start_job_runner` log and restart the loop on unexpected exceptions; make `_scan` skip objects that disappear between listing and reading; consider refusing `delete_job` while the runner holds the job.

### Bug 2 — MC-1: An acknowledged abort of a SUBMITTED/DISPATCHED job is lost

- **Source**: MC (`models/lifecycle/output/hunt_abort_1.log`, `hunt_abort_AbortedNotLaunched_1.log`, `hunt_abort_AbortFromDispatchedHonored_1.log`)
- **Status**: REPRODUCED (black-box, 8/8 attempts) — **Severity: High**
- **Novelty**: NEW relative to reachable local history (abort-related fixes `6d193a24`, `e3568925`, `9f49a109`, `bb840df0`, `a18489e4`, `cb784550` address other windows: completion publication, download gating, client launch). Public tracker not consulted.
- **Location**: `nvflare/private/fed/server/job_cmds.py:1059-1066` (abort of SUBMITTED/DISPATCHED only writes `FINISHED_ABORTED` and replies "Aborted the job … before running it."); `nvflare/private/fed/server/job_runner.py:661` and `697` (the only status re-checks), `670` (unconditional `set_status(DISPATCHED)`), `674-689` (`update_meta` read-modify-write of the whole meta), `711` (unconditional `set_status(RUNNING)`); `SimpleJobDefManager.set_status` has no transition guard (`nvflare/apis/impl/job_def_manager.py:459-481`).
- **Description**: the admin command and the JobRunner write the job-store status without a lock or compare-and-set. An abort that lands while the runner is deploying (status still SUBMITTED) or starting (status DISPATCHED) sets `FINISHED:ABORTED` and acknowledges the admin. The runner then overwrites it with DISPATCHED/RUNNING, launches the SJ and CJs, and the job runs to `FINISHED:COMPLETED`. Nothing is stopped; in the DISPATCHED window the processes were already alive at the time of the acknowledgement.
- **Developer intent**: FLARE API `abort_job` docstring (`nvflare/fuel/flare_api/flare_api.py:569-571`): "If job is not started yet, it will be cancelled and won't be scheduled." Unit test `tests/unit_test/private/fed/server/job_cmds_test.py:1960-1976` asserts the SUBMITTED abort path sets FINISHED_ABORTED and replies "Aborted the job job-123 before running it." The runner's log messages at 662/699 ("won't be deployed"/"won't be start to run") show the intended guard.
- **Reproduction** (Level 0, unmodified source; the abort is timed by externally observable signals only):
  - `timeout 900 python3 test_bug1_abort_lost.py --when deploy --attempts 3 --out logs/bug1_deploy_L0_run1.json`
  - `timeout 900 python3 test_bug1_abort_lost.py --when dispatched --attempts 5 --out logs/bug1_dispatched_L0_run1.json`

    ```
    "trigger": "server_run_dir", "t_trigger": 0.267,
    "abort_reply": "Aborted the job 11500dba-844f-4cc0-9dca-486a81368d54 before running it.", "t_ack": 0.28,
    "procs_at_ack": {"sj": [], "cj": []},
    "status_trace": [[0.29, "DISPATCHED"], [0.4, "RUNNING"], [14.18, "FINISHED:COMPLETED"]],
    "sj_cj_started_after_ack": true, "max_sj_procs": 1, "max_cj_procs": 2, "BUG": true
    SUMMARY when=deploy attempts=3 bug_triggered=3
    SUMMARY when=dispatched attempts=5 bug_triggered=5   (e.g. procs_at_ack {'sj': [3837804], 'cj': [3837807, 3837808]} -> RUNNING -> FINISHED:COMPLETED)
    ```
    Server-side timeline (`server/audit.log`, `server/log.txt`): `52.4639` submit_job → `52.683` "Got the job … from the scheduler" → **`52.6919` abort_job** → `52.694` server app deployed → `52.7097` first poll already reads DISPATCHED → `52.713` "Updated the schedule history" → `52.716` SJ launched → `52.725` "status changed to RUNNING". The job store archive (`repro/archive/poc_ws_run1_through_L3.tar.gz`) shows all 8 acknowledged-abort jobs as `FINISHED:COMPLETED`.
- **Model/implementation match**: TLC trace `AdminAbortRead(SUBMITTED) → RunnerCheckSubmitted → RunnerDeploy → AdminAbortAct → RunnerSetDispatched` (violates AbortHonored) is the observed order. A second model variant (abort between `update_meta`'s read and write) is subsumed.
- **Severity reasoning**: externally observable violation of the documented abort contract. A job the administrator was told was cancelled executes on all participating sites and is reported as completed. Harm is bounded to that job; the admin can re-abort once the job shows RUNNING, if they notice. In federated settings, executing a job an admin cancelled (for example because it was misconfigured) is more than cosmetic, which is why this is not rated lower.
- **Recommendation**: make the dispatch transitions conditional (compare-and-set on the expected status in the job store, or a per-job lock shared by `abort_job` and `JobRunner.run`). Re-check for a terminal/abort status after `_deploy_job` and `_start_run`, and stop the started processes if an abort arrived. Alternatively, let `abort_job` of a job being dispatched go through `stop_run`/`mark_run_aborted` semantics.

### Bug 3 — T-1: Reservations of a job that failed to dispatch are never released

- **Source**: Code review + resource model diagnostics (`models/resources/output/hunt_NoRejectionByLeftoverReservation_1.log`, `hunt_leftover_noCT*_1.log`). These are diagnostic invariants, not contract invariants.
- **Status**: REPRODUCED (black-box) — **Severity: High** (bounded; see reasoning)
- **Novelty**: NEW relative to reachable local history (`a6616c8a`/`5e2283fb`/`3bff3146` harden the scheduler's own NO_RESOURCE path only).
- **Location**: reservations are cancelled only on the scheduler's NO_RESOURCE path (`nvflare/app_common/job_schedulers/job_scheduler.py:229-254`). The runner's failure/skip paths never cancel: the `continue` paths (`nvflare/private/fed/server/job_runner.py:661-663`, `697-701`), the `except` path (713-731) after deploy or SJ-launch failure, and timed-out CHECK replies turned into `(False, "")` (`nvflare/private/fed/server/server_engine.py:1024-1041`). Reservations then persist until `AutoCleanResourceManager._check_expired` (`nvflare/app_common/resource_managers/auto_clean_resource_manager.py:102-117`); the provisioned default is `expiration_period: 300` (`nvflare/lighter/templates/master_template.yml:78`).
- **Description**: after an ordinary dispatch failure, the server knows the job failed but leaves its client reservations in place. Until they expire, each later eligible job's resource check is rejected ("not enough sites have enough resources"), and it burns scheduling attempts (`max_schedule_count` = 10 by default; exhausting it marks a job `FINISHED:CAN_NOT_SCHEDULE`). The deployed app directories of the failed job also stay on the server and on the clients that accepted deployment (observed for job `8b69269f…`).
- **Reproduction** (Level 0, unmodified source, supported site configuration: `GPUResourceManager(num_of_gpus=1, mem_per_gpu_in_GiB=1, expiration_period=300, ignore_host=True)` + `PassthroughResourceConsumer` on both sites; site-2 `privacy.json` offers only the `public` scope):
  `timeout 1500 python3 test_bug4_leftover_reservation.py --observe 840 --out logs/bug4_leftover_L0_run2.json`

  ```
  control {'final': 'FINISHED:COMPLETED', 'seconds': 10.1, 'schedule_count': 1}
  res after control {'site-1': "{'resources': [{'gpu_id': 0, 'memory': 1}], 'reserved_resources': {}}", ...}
  failed job {'final': 'FINISHED:FAILED_TO_RUN', 'deploy_detail': ['server: OK', "site-2: NVFLARE_ERROR: privacy scope 'research' is not allowed", 'site-1: OK', 'num_ok_sites 1 < required_min_sites 2']}
  res after failure {'site-1': "{'resources': [{'gpu_id': 0, 'memory': 0}], 'reserved_resources': {'01079354-...': [{'0': 1}, 299]}}",
                     'site-2': "{'resources': [{'gpu_id': 0, 'memory': 0}], 'reserved_resources': {'10a12c26-...': [{'0': 1}, 299]}}"}
  later job left SUBMITTED after 311.2 s; schedule_count 6 final FINISHED:COMPLETED
     hist: 06:34:55 / 06:35:05 / 06:35:25 / 06:36:05 / 06:37:25: not enough sites have enough resources (ok sites 0 < min sites 2)
     hist: 06:40:05: scheduled
  ```
  (An earlier run, `logs/bug4_leftover_L0_run1_gpuconsumer_envlimit.json`, used the default `GPUResourceConsumer`. It fails on this GPU-less host with "GPU ID 0 does not exist", so jobs could not start. That is a test-configuration limitation, not a product finding; the leftover reservations were observed identically.)
- **Severity reasoning**: externally observable, bounded harm. An idle system rejects an eligible job for about 5 minutes after each ordinary dispatch failure and consumes its scheduling budget. The designed expiry bounds the effect, which is why this is not rated higher. Uncertainty: one could rate it Medium because the expiry is an intentional safety net. It is rated High because the server has the tokens and the failure information but does not perform the cleanup it performs on its own NO_RESOURCE path.
- **Recommendation**: on every runner path that abandons a scheduled attempt (both `continue` checks, the `except` block, and deploy-failed clients excluded from start), call `engine.cancel_client_resources(...)` with the attempt's dispatch tokens. Optionally delete deployed run directories of jobs that never started.

### Bug 4 — MC-4a: Terminal status overwritten by RUNNING (zombie RUNNING job)

- **Source**: MC (`models/lifecycle/output/mc_2.log`, TerminalStatusStable)
- **Status**: REPRODUCED (controlled timing) — **Severity: High**
- **Novelty**: NEW relative to reachable local history (`1b009bdc`, `6d193a24` fix other completion races).
- **Location**: `nvflare/private/fed/server/job_runner.py:709-711`: `running_jobs[job_id] = ready_job` under the lock, then (lock released) an unconditional `set_status(RUNNING)`. The completion loop (`_job_complete_process`, 441-541) may finalize the job in between if its SJ already ended.
- **Description**: if the SJ ends before the runner writes RUNNING (for example a server-app configuration error or a trivial workflow) and the completion loop publishes the terminal status first, the runner then writes RUNNING. Nothing is running, but the store says RUNNING forever:
  - `abort_job` fails with "Job … is not running."
  - `delete_job` refuses ("still running").
  - The status survives restarts, because nothing reconciles stored statuses at startup (`JobRunner.update_unfinished_jobs` has no callers).
  - `nvflare poc stop` / `shutdown_system_by_session` fail with INTERNAL_ERROR (exit 5), because they abort every stored RUNNING job and only tolerate `JobNotFound` (`nvflare/tool/api_utils.py:104-110`).
- **Reproduction** (controlled timing: server started from `repro/l3_src` with `SPECULA_DELAY_BEFORE_RUNNING=15`, i.e. a sleep inserted between lines 710 and 711; unmodified runs of the same jobs give the correct outcome, `logs/bug3_*_L0_run1.json`):
  `SPECULA_DELAY_BEFORE_RUNNING=15 PYTHONPATH=$R/l3_src timeout 300 python3 test_bug3_running_overwrite.py --kind sjfail --observe 45` (and `--kind zerorounds`)

  ```
  trace [[0.06, 'SUBMITTED'], [0.95, 'DISPATCHED'], [8.87, 'FINISHED:EXECUTION_EXCEPTION'], [15.97, 'RUNNING']]
  final RUNNING procs_end {'sj': [], 'cj': []}
  abort <abort error InternalError: server internal error: Job 157b9742-... is not running.>
  delete <delete error JobNotDone: job 157b9742-... is still running>
  (zerorounds) trace [..., [8.17, 'FINISHED:COMPLETED'], [15.23, 'RUNNING']]  BUG True
  ```
  After restarting on the **unmodified** source the two jobs are still RUNNING and `python3 -m nvflare.cli poc stop` exits 5 (`logs/poc_stop_4_unmodified_zombie.log`: "server internal error: Job 157b9742-… is not running … Code: INTERNAL_ERROR (exit 5)").
- **Severity reasoning**: the consequence is persistent and has no automatic recovery (Critical-class by consequence alone). Natural occurrence, however, requires the runner thread to be descheduled for longer than the completion loop's detection, archive and publish work (seconds) between two adjacent statements. It was demonstrated only with an injected delay. Rated High with that reachability caveat stated explicitly.
- **Recommendation**: publish RUNNING before registering the job in `running_jobs`, or make the completion loop's terminal write and the runner's RUNNING write compare-and-set/serialized by one lock. Reject non-terminal writes over terminal statuses in `set_status`. Make `abort_jobs()` in `api_utils` tolerate "not running" errors. Consider reconciling stored RUNNING/DISPATCHED jobs at startup (outside this scope; see §5).

### Bug 5 — MC-4b: Aborted live run published as FINISHED:COMPLETED

- **Source**: MC (`models/lifecycle/output/hunt_overlap_3.log`, AbortOfLiveRunEndsAborted)
- **Status**: REPRODUCED (controlled timing) — **Severity: Medium**
- **Location**: `nvflare/private/fed/server/job_runner.py:798-800`: `stop_run` = `_stop_run` (signals the clients and the SJ) followed by `mark_run_aborted` (sets `job.run_aborted`). `_job_complete_process` computes the final status once (484-492) from `run_aborted` and the SJ exit code. A gracefully aborted SJ exits with code 0 (`mpm.run` in `nvflare/private/fed/app/server/runner_process.py:203`), and in the reproduction the aborted clients' terminal-outcome reports carried no failure code (the server log shows no "Failing job … due to reported failure" line for the job), so nothing but `run_aborted` could have produced FINISHED:ABORTED.
- **Description**: if the aborted SJ exits and the completion loop classifies the job before `mark_run_aborted` runs, the run is published as `FINISHED:COMPLETED`. The admin receives "Job … is not running"/"already completed" rather than an abort acknowledgement. Commit `e3568925` states that "stop_run() … sets job.run_aborted immediately", but it is set only after the signalling calls.
- **Reproduction** (controlled timing: `SPECULA_DELAY_BEFORE_MARK_ABORTED=15`; the unmodified baseline gives `FINISHED:ABORTED`, `logs/mc4b_abort_vs_completion_L0.json`):

  ```
  procs_before_abort {'sj': [3912893], 'cj': [3912895, 3912896]}
  abort_reply Job for 3746a32e-... is already completed.     (third client retry; see audit.log)
  final FINISHED:COMPLETED  MISCLASSIFIED True
  audit.log: 52:45.318 abort_job; 52:50.827 abort_job (retry); 52:56.835 abort_job (retry)
  log.txt:   53:03,322 / 53:06,884 "Job 3746a32e-... is not running. It can not be stopped."
  ```
- **Severity reasoning**: externally observable but bounded: one job's terminal status misreports an aborted, partial run as completed. The natural window is milliseconds, and it needs the SJ to finish within `_stop_run`'s ≤3 s signalling window.
- **Recommendation**: set `run_aborted` (under the runner lock) before sending any abort signal in `stop_run`, and keep user-abort precedence when the completion loop computes the final status.

### Bug 6 — CR-4: Failure report during `_start_run` → KeyError → mislabeled status

- **Source**: Code review (model: the KeyError path is modeled in `RunnerCollectStart`; no invariant flags it because a failed status results)
- **Status**: REPRODUCED (controlled timing) — **Severity: Low**
- **Location**: `nvflare/private/fed/server/job_runner.py:309` (pending set created), `841` (`fail_run` pops it), `359-360` (`self._pending_client_outcomes[job_id].intersection_update(...)`).
- **Reproduction** (client app with a disallowed class → every CJ fails at startup; `SPECULA_DELAY_AFTER_START_CLIENTS=10`): result `FINISHED:FAILED_TO_RUN` with `JobRunner - ERROR - Failed to run the Job (917dfde9-…): KeyError: '917dfde9-…'` (`logs/cr4_failrun_during_start_L3.json`). The unmodified run of the same job ends `FINISHED:ABNORMAL` with the clients' infrastructure-error reason (`logs/cr4_failrun_during_start_L0.json`). No processes or allocations leaked.
- **Severity reasoning**: hygiene. A misleading error message and status label, plus one stale `exception_run_processes` entry; no lifecycle or resource harm.
- **Recommendation**: use `self._pending_client_outcomes.get(job_id)` and treat a missing entry as "already failed" (propagate the recorded failure) instead of raising.

### Bug 7 — CR-3: `GPUResourceManager.expiration_period` validation contradicts its base class

- **Source**: Code review
- **Status**: REPRODUCED (unit level) — **Severity: Low**
- **Location**: `nvflare/app_common/resource_managers/gpu_resource_manager.py:80` (`expiration_period: Union[int, float] = 30`), `107-110` (accepts float and ≥ 0) vs `nvflare/app_common/resource_managers/auto_clean_resource_manager.py:42-45` (int > 0 only), reached via `super().__init__` at 146.
- **Reproduction**: `python3 repro/test_cr3_gpu_expiration_validation.py` → `expiration_period=30.5: TypeError: expiration_period should be of type int, but got <class 'float'>.`; `expiration_period=0: ValueError: expiration_period should be greater than 0.` (`repro/logs/cr3_cr2_unit_run1.log`)
- **Severity reasoning**: a configuration value that the class's own signature and checks declare valid makes the site's resource manager fail at startup, with an explicit error. Fail-fast; no runtime lifecycle harm.
- **Recommendation**: align the validation (accept float > 0 in the base class, or document int-only and reject 0 in the subclass).

---

## 4. Unconfirmed findings

- **MC-2 window (b)** — deleting a job between scheduling and `_check_job_status` (`None.meta` AttributeError at `job_runner.py:738-739`). This is a model-only path (`hunt_delete_noscan_1.log`) with the same root cause and consequence as the reproduced Bug 1. Its window is one CHECK_RESOURCE round trip (widened by slow clients, up to the 15 s timeout). It was not separately reproduced because windows (a) and (c) already demonstrate the defect. Next step, if needed: delay one client's CHECK handling with a site-local event handler and delete during that window.
- **MC-1 lost-update variant** — an abort written between the runner's `update_meta` read and write (`job_runner.py:674-689`, `filesystem_storage.py:273-275`) is overwritten by the write-back (`hunt_abort_AbortFromDispatchedHonored_1.log`). It is subsumed by the reproduced Bug 2 and was not reproduced separately (microsecond window).

---

## 5. Other dispositions

| Candidate | Disposition | Reason / evidence |
|---|---|---|
| MC-3 (Q1) client allocation ownership | No violation found (bounded) | `models/resources/output/mc_1.log`: 12,467,043 distinct states, depth 49, complete, no violation of ResourceConservation / NoOverAllocation / AllocationOwned (2 jobs, 2 clients, 1 unit, max_jobs 2, late CHECK/START, expiry, cancel, launch failure, abort, heartbeat). Real-system cross-check: partial START failure releases everything (`repro/logs/q2_partial_start_L0_run1.json`: site-1 CJ launched and killed within 3 ms, both sites back to 1 free unit, no reservations). |
| CR-1 `ClientEngine.start_app` error-string returns leak the allocation (`client_engine.py:357-367` with `scheduler_cmds.py:114-137`) | FALSE POSITIVE (latent) | Unreachable through supported operations: START is only sent to clients whose deploy succeeded, the only DELETE_RUN senders are the disabled `delete_workspace` command (`job_cmds.py:163-171`, `enabled=False`) and the uncalled `JobRunner._delete_run`, and a second START for a started job requires a second scheduling of a non-SUBMITTED job. Hardening suggestion: free on every non-success return. |
| CR-2 `free_resources` has no ownership check (`auto_clean_resource_manager.py:166-172`) | FALSE POSITIVE (latent) | A double free would duplicate a unit (`slot: [0, 0]`, unit run in `logs/cr3_cr2_unit_run1.log`), but no reachable double-free path exists: model AllocationOwned/ResourceConservation hold, and after launch `JobExecutor.start_app` swallows handler exceptions, so `StartJobProcessor` never frees an allocation owned by a CJ waiter. |
| CR-5 non-strict START check skips min_sites/required_sites (`job_runner.py:313-353`) | Documented design choice | Controlled by `STRICT_START_JOB_REPLY_CHECK` (default False); strict mode enforces the checks. Not a defect. |
| T-2 START after reservation expiry fails the job | By design | `expiration_period` semantics are documented in the class docstrings; the model (`ExpireInUse` fault) shows a clean FAILED_TO_RUN with no leak. Needs deploy > 300 s with the provisioned default. |
| AckedRunAbortEndsAborted (v1) | Property artifact (Case A) | `hunt_overlap_2.log`: an abort arriving after the SJ already completed normally; reporting COMPLETED is reasonable. Replaced by AbortOfLiveRunEndsAborted (v2), which still fires (Bug 5). Recorded in `models/lifecycle/changelog.md`. |
| Lifecycle model v0 fidelity fixes | Model artifacts corrected before any TLC run | Single START slot per client, an over-restrictive heartbeat guard, unbounded faults; see changelog. |
| Timing assumptions `AssumePromptRunningWrite`, `AssumePromptAbortMark`, scenario restriction `AbortOnlyRunning` | Exploration aids, not guarantees | Used only to look past MC-4a/MC-4b/MC-1; both timing assumptions are refuted by the controlled-timing reproductions. |
| Stored RUNNING/DISPATCHED statuses are never reconciled after a server restart (`update_unfinished_jobs` has no callers) | Out of scope (restart/HA recovery) | Observed during Bug 4's restart; not investigated further. |

---

## 6. Models, checks and coverage

**Lifecycle model** (`models/lifecycle/base.tla`, `MC.tla`). It covers:
- job-store status with unconditional writes and a split `update_meta` read/write;
- the JobRunner loop split at every store access (scan list/read, schedule, both status checks, deploy, DISPATCHED write, update_meta, SJ start, START collection, running_jobs add, RUNNING write, the three-step `except` block);
- per-job completion (classify with the outcome barrier and deadline, publish);
- SJ exits and `_remove_run_processes`;
- the client START/CJ exit/outcome report/ABORT/heartbeat reconciliation;
- admin `abort_job` (read/act/mark) and `delete_job` (pre-authz snapshot/act).

Faults are counter-bounded in MC. Invariants: AbortHonored, TerminalStatusStable, RunnerAlive, NoStaleAdmission, AbortOfLiveRunEndsAborted, plus diagnostic variants.

**Resource model** (`models/resources/base.tla`, `MC.tla`). It covers:
- CHECK reservation (with late processing after timeouts), CANCEL, expiry (abandoned vs in-use);
- START allocation → start_app early returns (real guards) → registration → launch/launch failure/pending abort;
- CJ exit, waiter free-at-exit, ABORT, heartbeat abort;
- runner success, skip and failure branches, max_jobs admission.

Invariants: ResourceConservation, NoOverAllocation, AllocationOwned, plus diagnostics.

| Run | Config / bounds | Result |
|---|---|---|
| lifecycle `mc_2` | Jobs 2, Clients 2, MaxJobs 1, all faults ≤1 | TerminalStatusStable violated (MC-4a), 17 states deep |
| `hunt_abort_1` (+2 variants) | 1 job, 1 client, abort | AbortHonored violated (MC-1) |
| `hunt_delete_1` (+2 variants) | 2 jobs, 1 client, delete | RunnerAlive violated (MC-2 a/b/c) |
| `hunt_overlap_2/3` | 1 job, 2 clients, faults ≤1, running-only abort, AssumePromptRunningWrite | v1 Case A; v2 violated (MC-4b) |
| `hunt_overlap_assume2_1` | same + AssumePromptAbortMark | complete, 269,871 distinct states, depth 35, no violation |
| `mc_assume_1c_1` | 2 jobs, 1 client, all faults ≤1, no admin, AssumePromptRunningWrite | complete, 644,171 states, depth 49, no violation |
| `mc_assume_2jobs_1` | 2 jobs, 1 client, MaxJobs 2, all faults ≤1, running-only aborts, AssumeBoth | complete, 49,563,357 states, depth 55, no violation |
| `mc_assume_1` | 2×2, all faults, AssumePromptRunningWrite | interrupted at 91M states (depth 44), no violation seen |
| `sim_2x2_1` | 2×2, MaxJobs 2, all faults ≤1, AssumeBoth, random simulation depth ≤120 | interrupted after 13,553,151 traces / 1.72e9 states, no violation |
| resources `mc_1` | 2 jobs, 2 clients, K=1, MaxAttempts 2, MaxJobs 2, all faults ≤1 | complete, 12,467,043 states, depth 49, no violation |
| resources diagnostics | leftover-reservation hunts | fire as expected (expiry-bounded) |

**Limits**:
- Clean runs certify only the recorded finite configurations and the modeled abstraction: resources as identical units, abstract workflow, one admin action per job, and outcome reports and heartbeats modeled per job without snapshot staleness.
- Liveness was checked on the real system, not with TLC fairness.
- The completion loop is modeled per job, which over-approximates the real single thread's interleavings between different jobs.

---

## 7. Answers to the investigation questions

1. **Concurrent reserve/acquire/release — ownership preserved?** In the client resource manager, yes within the checked bounds: no conflicting assignment and no permanent capacity loss was reachable in the model, and the real partial-start path released everything. The one latent hazard (unchecked double free, CR-2) has no reachable caller. Capacity is, however, lost *temporarily* whenever the server abandons a scheduled attempt (Bug 3).
2. **Partial deploy/startup — status and cleanup match the outcome?** Status: yes for partial deploy (FAILED_TO_RUN) and partial START (FAILED_TO_RUN with the started CJs aborted). Cleanup: no — after a deploy failure (and on the runner's skip paths) client reservations and deployed run directories are left behind (Bug 3). A client failure report that races the START collection is mislabeled (Bug 6).
3. **Cancellation/completion/cleanup overlap — lifecycle contracts preserved?** No:
   - an acknowledged abort of a job being dispatched is overwritten, and the job runs (Bug 2);
   - the runner's RUNNING write can resurrect a terminal status into a permanent zombie (Bug 4, controlled timing);
   - an aborted live run can be published as completed (Bug 5, controlled timing).
4. **Can remaining state from a failed ordinary operation affect a later eligible job?** Yes:
   - a job deletion can end the scheduling thread, so no later job is ever scheduled (Bug 1);
   - leftover reservations from a failed dispatch reject later eligible jobs for up to `expiration_period` and consume their scheduling budget (Bug 3);
   - a zombie RUNNING job blocks the standard shutdown helper (Bug 4).

---

## 8. Reproduction command index

```
cd .specula-lite/job-lifecycle-20260925/repro && source env.sh
python3 -m nvflare.cli poc prepare -i $R/project_custom.yml --force && python3 -m nvflare.cli poc start
timeout 300 python3 test_sanity.py                                                   # baseline
timeout 900 python3 test_bug1_abort_lost.py --when deploy --attempts 3 --out logs/bug1_deploy_L0_run1.json
timeout 900 python3 test_bug1_abort_lost.py --when dispatched --attempts 5 --out logs/bug1_dispatched_L0_run1.json
timeout 600 python3 test_bug2_delete_kills_runner.py --observe 90 --out logs/bug2_delete_L0_run1.json      # needs POC restart afterwards
timeout 900 python3 test_bug2b_delete_queued_scan_race.py --queued 150 --out logs/bug2b_scanrace_L0_run1.json  # needs the GPU site config below; restart afterwards
# Bug 3 site config: site-*/local/resources.json GPUResourceManager(num_of_gpus=1, mem_per_gpu_in_GiB=1, expiration_period=300,
#   ignore_host=True) + PassthroughResourceConsumer; site-2/local/privacy.json {"scopes":[{"name":"public","properties":{}}],"default_scope":"public"}
timeout 1500 python3 test_bug4_leftover_reservation.py --observe 840 --out logs/bug4_leftover_L0_run2.json
timeout 300 python3 test_q2_partial_start_cleanup.py                                   # site-2 consumer = GPUResourceConsumer
# controlled timing: restart the POC with PYTHONPATH=$R/l3_src and one of
#   SPECULA_DELAY_BEFORE_RUNNING=15 (Bug 4), SPECULA_DELAY_BEFORE_MARK_ABORTED=15 (Bug 5), SPECULA_DELAY_AFTER_START_CLIENTS=10 (Bug 6)
timeout 300 python3 test_bug3_running_overwrite.py --kind sjfail --observe 45 --out logs/bug3_sjfail_L3_run1.json
timeout 300 python3 test_mc4b_abort_vs_completion.py L3
timeout 200 python3 test_cr4_failrun_during_start.py L3
timeout 120 python3 test_cr3_gpu_expiration_validation.py
```
Model checks: `python3 $SKILL_DIR/scripts/tlc.py check MC.tla --config <cfg> --log output/<name>.log` from `models/lifecycle` or `models/resources` (logs and `.run.json` receipts in `output/`).

---

## 9. Notes and limitations

- Trace validation was not performed.
- All real-system runs used one host (POC over localhost). Timing-dependent windows are wider in real deployments with slower networks and larger apps, but the controlled-timing results (Bugs 4–6) do not establish natural occurrence rates.
- Novelty is relative to the reachable local history only; public trackers were not consulted by design of this pilot.
- The POC workspace was re-provisioned once (after Bug 4 left zombie RUNNING jobs that break `poc stop`); the earlier workspace, including its job store, is archived in `repro/archive/`.
- No product code was changed and no fixes were applied. The recommendations above are suggestions only.
