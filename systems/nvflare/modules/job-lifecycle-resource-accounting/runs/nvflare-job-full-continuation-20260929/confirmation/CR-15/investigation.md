# CR-15 Investigation

## Candidate

Ordinary local restart can leave a persisted job in `RUNNING` even though the new server parent has empty in-memory process tables. The affected source is pinned at commit `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

## Phase 1 Code Audit

The supported admin shutdown and restart path is implemented in `nvflare/private/fed/server/server_engine.py:416-437`. The asynchronous shutdown path reaches `server_shutdown` at `server_engine.py:1104-1114`, then `FederatedServer.fl_shutdown()` at `nvflare/private/fed/server/fed_server.py:1243-1247`, which calls `engine.stop_all_jobs()` before firing `SYSTEM_END`.

`ServerEngine.stop_all_jobs()` at `server_engine.py:1089-1091` delegates to `JobRunner.stop_all_runs()`. That runner path at `nvflare/private/fed/server/job_runner.py:854-861` iterates the current `engine.run_processes`, calls `stop_run()` for each, and then sets `ask_to_stop=True`. The normal completion publisher is gated by `while not self.ask_to_stop` at `job_runner.py:441-443`, and the terminal status persistence in `_job_complete_process()` at `job_runner.py:523-538` is therefore bypassed once shutdown asks the runner to stop.

The source contains reconciliation helpers:

- `restore_running_job()` at `job_runner.py:744-760`
- `update_abnormal_finished_jobs()` at `job_runner.py:762-777`
- `update_unfinished_jobs()` at `job_runner.py:779-796`

`update_unfinished_jobs()` is the helper relevant to a fresh local parent because it queries persisted `RUNNING` and `DISPATCHED` jobs and marks them `FINISHED:ABANDONED`. A repository search across `nvflare`, `tests`, and `docs` found no caller for this helper or the adjacent restart helpers beyond their definitions.

The fresh-server deploy path at `nvflare/private/fed/server/fed_server.py:1216-1224` sets the server state to hot and initializes communicators, but it does not call any of the restart reconciliation helpers. A local restart naturally creates empty `engine.run_processes` and `job_runner.running_jobs` tables while reusing the same persisted job store.

This trigger is reachable without patching source. `JobRunner.schedule_job()` persists `RUNNING` after the child starts at `job_runner.py:711`. Admin abort for a persisted `RUNNING` job calls `job_runner.stop_run()` through `nvflare/private/fed/server/job_cmds.py:1051-1078`. After that, admin shutdown is allowed for an aborted running job by `nvflare/private/fed/server/training_cmds.py:158-170`; the guard rejects only non-aborted running jobs. The stricter `restart` command guard at `training_cmds.py:260-268` does not cover the supported `shutdown server` plus local marker/script restart path.

Real consumers observe the stale state:

- `JobRunner.mark_run_aborted()` returns `Job <id> is not running.` when the fresh parent's `running_jobs` table lacks the persisted job (`job_runner.py:802-811`), and `abort_job` reports this through `nvflare/private/fed/server/job_cmds.py:1072-1076`.
- `delete_job` rejects persisted `DISPATCHED` and `RUNNING` jobs at `job_cmds.py:516-521`.
- The job CLI terminal-status helper treats `RUNNING` as non-terminal at `nvflare/tool/job/job_cli.py:1926-1936`, so wait/status flows keep seeing the job as unfinished instead of `ABANDONED`.

## Phase 1 Developer Intent and Known-Status Check

The product documentation exposes ordinary server shutdown and restart operations in `docs/user_guide/admin_guide/deployment/operation.rst:63-66` and `docs/user_guide/nvflare_cli/system_command.rst:167-208`. The job CLI documentation treats `ABANDONED` / `FINISHED:ABANDONED` as a terminal failure state in `docs/user_guide/nvflare_cli/job_cli.rst:236-274`.

Developer history shows this behavior has been intentionally handled before:

- `9e1881da167aa4db0d59bb4bfb63aaa330517b11` is titled `Fix incorrect server status after job aborted and server restarted`.
- `195110c225579ec78767678654d6c13c4ba53f7f` is titled `Job status management enhancement (#1613)` and added broader status-management/HA behavior.
- `4e090892baa795362dca6ea6d142224d7778ec78` is titled `Remove HA/Overseer (#4503)` and removed the hot/cold recovery path where this family of helper calls previously belonged.

Permitted prior-report search in this continuation was limited to the source git history and local tracker-equivalent history. Searches over commit subjects/bodies for restart, abandoned jobs, aborted jobs, and server status found historical same-symptom work, but no current post-HA-removal report or fix for the no-caller regression. I did not consult external issue or PR discussions because the continuation instructions prohibit inspecting newer upstream discussions or external answers.

## Phase 2 Reproduction Summary

Reproduction script:

`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-15_restart_stale_running.py`

The script uses real NVFlare classes for persisted job creation/status (`SimpleJobDefManager`, `FilesystemStorage`), real `JobRunner.stop_run()`, `JobRunner.stop_all_runs()`, `JobRunner.mark_run_aborted()`, `JobRunner.update_unfinished_jobs()`, and the real CLI terminal-status helper. It uses a minimal `ServerEngineSpec` implementation only to supply required engine callbacks and in-memory process tables. The Level 2 injected precondition is a persisted `RUNNING` job, which is reachable through the documented real sequence: submit job, scheduler persists `DISPATCHED`/`RUNNING`, admin aborts the running job, then shutdown is allowed because `job.run_aborted=True`.

The executed repro shows:

- Supported abort before shutdown succeeds and sets `job.run_aborted=True`.
- Shutdown/stop-all leaves persisted status as `RUNNING`.
- A fresh parent starts with empty `run_processes` and `running_jobs`.
- The persisted status remains `RUNNING`.
- A real later abort consumer sees `Job <id> is not running.`
- The delete guard would reject the stale job.
- The CLI wait helper sees the stale `RUNNING` status as non-terminal.
- Manual `update_unfinished_jobs()` control converts the same state to `FINISHED:ABANDONED`, proving the missing ordinary caller is the defect.
