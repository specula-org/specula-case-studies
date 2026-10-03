# CR-31 Investigation

## Step 1: Code Audit

Affected source:
- `nvflare/private/fed/server/server_engine.py:142-159`: `get_engine_info()` derives aggregate `engine_info.status` from `bool(self.run_processes)` and populates per-job app names.
- `nvflare/private/fed/server/server_engine.py:203-234`: `wait_for_complete()` pops the completed job from `run_processes`, then unconditionally writes `engine_info.status = STOPPED` at line 234.
- `nvflare/private/fed/server/server_engine.py:354-382`: `abort_app_on_server()` schedules cleanup for one job and unconditionally writes `engine_info.status = STOPPED` at line 382.
- `nvflare/private/fed/server/fed_server.py:1145-1157`: `FederatedServer.start_run()` starts `run_engine()` in a thread, writes `engine_info.status = STARTED` at line 1148, and loops until the same scalar becomes `STOPPED`.
- `nvflare/private/fed/server/fed_server.py:1199-1209`: `run_engine()` writes `STARTED`, runs the server runner, then writes `STOPPED`.

Reachability:
- Parent multi-job mismatch: normal server-job lifecycle calls `ServerEngine._start_runner_process()` to add one entry per job to `run_processes`, and each waiter calls `wait_for_complete()` when its process exits. With jobs A and B registered, A's `wait_for_complete()` can leave B in `run_processes` while writing the aggregate status to `STOPPED`.
- Server-job child lost update: normal `ServerAppRunner.run_serverapp()` calls `FederatedServer.start_run()`. `start_run()` starts `run_engine()` in a separate thread and then writes `STARTED`; if the engine thread finishes before the main thread reaches line 1148, line 1148 overwrites the `STOPPED` written by `run_engine()` at line 1209. The loop at line 1149 then observes `STARTED` even though the run engine has already ended.

Consumers and safeguards:
- Admin `check_status server` uses `TrainingCommandModule.check_status()` at `training_cmds.py:306-325`, which calls `engine.get_engine_info()` before reporting status. That recomputes from `run_processes`, so the parent-side stale `STOPPED` snapshot is masked for the visible status command.
- `TrainingCommandModule.shutdown()` gates shutdown on `engine.job_runner.running_jobs` at `training_cmds.py:164-170`, not on `engine_info.status`.
- Heartbeat reconciliation and client outcome handling use `engine.run_processes` / `exception_run_processes` (`fed_server.py:1004-1017`, `1086-1094`, `1108-1113`), not the scalar status.
- `ServerEngine.abort_app_on_clients()` at `server_engine.py:346-352` directly reads the stale scalar and can return "Server app has not started."; local search found no in-tree caller.
- `AbortCommand.process()` in `server_commands.py:106-118` loops on `engine.engine_info.status`, but this is the server-job child engine reached through the abort command. That consumer is relevant to the same status scalar but not to the parent multi-job `run_processes` mismatch.
- The live consequence found is `FederatedServer.start_run()` itself: its loop condition consumes the same global status and can hang after `run_engine()` has finished.

Trigger scenario:
1. A server job starts normally through `ServerAppRunner.run_serverapp()` -> `FederatedServer.start_run()`.
2. `start_run()` creates `engine_thread = threading.Thread(target=self.run_engine)` and calls `engine_thread.start()` at `fed_server.py:1145-1146`.
3. The scheduler runs the engine thread before the main thread executes line 1148.
4. `run_engine()` writes `STARTED` at `fed_server.py:1200`, the workload returns quickly, and `run_engine()` writes `STOPPED` at `fed_server.py:1209`.
5. The main thread resumes and writes `STARTED` at `fed_server.py:1148`, overwriting the terminal status.
6. The loop at `fed_server.py:1149` does not exit; the server-job process remains alive until an external stop sets `asked_to_stop`.

## Step 2: Developer-Knowledge Search

Local source comments/docs/tests:
- `training_cmds.py:307` says: `TODO:: Need more discussion on what status to be shown`, which is developer uncertainty about display semantics, not acceptance of a lifecycle hang.
- Docs state NVFLARE is a multi-job system allowing multiple concurrent jobs: `docs/user_guide/core_concepts/job.rst:395` and `docs/user_guide/admin_guide/configurations/communication_configuration.rst:12`.
- Existing tests `tests/unit_test/private/fed/server/training_cmds_status_test.py:26-38` cover `_server_status_value()` for a supplied `EngineInfo`, but they do not cover `get_engine_info()` recomputing from `run_processes` or the `start_run()` / `run_engine()` lost update.
- Existing server-engine tests around abort cleanup (`tests/unit_test/private/fed/server/server_engine_test.py:283-349`) validate cleanup thread behavior and handle termination, not aggregate status correctness.

Local git history / blame:
- `server_engine.py:144-147` was introduced with multi-run support in commit `36c3fc7b` ("Multi run support").
- `server_engine.py:234` comes from `6f75707f` around job-process waiting.
- `fed_server.py:1148`, `1157`, `1200`, and `1209` originate from early server lifecycle code (`d93b0c372` / `e1e2e1dba` in blame).
- Commit `9e1881da` is titled "Fix incorrect server status after job aborted and server restarted", but its diff only guards `UPDATE_RUN_STATUS` handling when a `run_processes` entry is already gone. It does not report or fix the `start_run()` line-1148 overwrite of `run_engine()` line-1209, nor the parent multi-job aggregate status mismatch.
- Local `git log --grep` for `engine_info`, `MachineStatus`, `status`, `STARTED`, `STOPPED`, `server status`, `check_status`, `multiple job`, and `multi run` found related lifecycle/status fixes but no exact report for this mechanism at these sites.

Known-status search:
- Searched in-tree docs/tests and pinned local git history through commit `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.
- External issue/PR discussions and newer commits were not opened because the continuation instructions explicitly prohibit consulting upstream issue/PR discussions, newer commits, or external answers.
- No exact same-site report was found in permitted evidence. Novelty is recorded as NEW.

## Phase 2 Reproduction Plan

Use `repro/test_bugCR-31_global_machine_status.py`.

Escalation:
- Parent multi-job status snapshot: use a reachable injected parent state with two `run_processes` entries, then call real `ServerEngine.wait_for_complete()` for one job. This shows the parent-side stale scalar and the `check_status` mask.
- Server-job child lost update: use timing assistance around the engine-thread start. The fake `ServerRunner.run()` represents a valid fast workload; the `Thread.start()` wrapper only delays the caller after starting the real engine thread so the engine thread can complete before `start_run()` executes line 1148.
