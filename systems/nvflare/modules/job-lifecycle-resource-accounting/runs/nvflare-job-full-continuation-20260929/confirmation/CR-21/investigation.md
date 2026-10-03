# CR-21 Investigation

## Code audit

The cited client shutdown/restart methods create `shutdown.fl` or `restart.fl`, fire `SYSTEM_END`, start a `shutdown_client` thread, and return without coordinating with `JobExecutor.run_processes` or the per-job wait thread (`nvflare/private/fed/client/client_engine.py:442`, `:453`, `:512`). `shutdown_client` sets `heartbeat_done`, closes the federated client, and closes security state.

Client worker cleanup is owned by `JobExecutor._wait_child_process_finish`: it waits for the job handle, optionally reports terminal outcome, calls `resource_manager.free_resources(...)`, and only then removes `run_processes[job_id]` (`nvflare/private/fed/client/client_executor.py:622`, `:676`, `:681`). `ClientAppRunner` reports `ClientStatus.STOPPED` after the runner returns but before process-local cleanup finishes (`nvflare/private/fed/client/client_app_runner.py:82`), so the client parent can have a STOPPED-but-still-owned child.

Normal server admin shutdown/restart rejects non-aborted running jobs (`nvflare/private/fed/server/training_cmds.py:164`, `:265`). That guard does not cover the STOPPED cleanup window after the server-side running job gate has cleared. Once the command is sent, the client-side `RestartClientProcessor` calls `engine.restart()` directly (`nvflare/private/fed/client/training_cmds.py:81`).

The default local job launcher starts child job processes in their own process group (`nvflare/utils/process_utils.py:333`, `:348`). The worker process watches its parent PID and calls `ClientAppRunner.stop()` when the parent disappears (`nvflare/private/fed/app/client/worker_process.py:49`, `:122`; `nvflare/private/fed/app/utils.py:45`), but this is cooperative: `ClientAppRunner.stop()` only calls `ClientRunner.abort()` (`nvflare/private/fed/client/client_app_runner.py:233`), and a task executor that is blocked or ignores `abort_signal` can delay exit (`nvflare/private/fed/client/client_runner.py:386`, `:837`).

The later real consumer is resource admission. `CheckResourceProcessor.process()` calls the client resource manager and returns `IS_RESOURCE_ENOUGH` plus a reservation token (`nvflare/private/fed/client/scheduler_cmds.py:83`, `:90`). `JobScheduler` treats each true resource response as dispatchable site info (`nvflare/app_common/job_schedulers/job_scheduler.py:212`, `:214`).

## Developer knowledge / known-status search

Local pinned git history for the cited files was searched with `git log --ancestry-path ... --grep` terms for shutdown, restart, child worker cleanup, resource ownership, missing client jobs, and marker files. Relevant lifecycle hardening exists, especially PR `#5097` / commit `9b5dddfd` ("Harden Client API and Swarm abort cleanup"), but that report is about Client API accepted result sources and CJ-owned trainer groups after abrupt CJ death; it is related precedent, not the same CP shutdown/restart resource-ownership site. No local ancestor issue/PR text found the exact CR-21 mechanism at the cited client parent/executor sites.

The continuation instructions prohibit consulting newer upstream issue/PR discussions or external answers, so novelty evidence is limited to pinned/local git history. Within that allowed search scope, this mechanism is NEW.

## Reachability and safeguards

Level 0 public admin shutdown/restart while a job is still running is guarded by `TrainingCommandModule.shutdown/restart`. The remaining reachable window is after server running-job state is clear but the client parent still owns a STOPPED child whose `_wait_child_process_finish` has not freed resources. In that window restart/shutdown can proceed, parent process state can be lost, and the new parent constructs a fresh in-memory resource manager from static config while the previous child still holds the resource.

Safeguards observed: server/client heartbeat sync can fail or abort jobs missing from one side (`nvflare/private/fed/server/fed_server.py:1004`), and worker parent-PID monitoring cooperatively aborts the child. These do not preserve the old client parent's in-memory resource manager allocation, and they do not force-kill a child that ignores or delays cooperative abort before a later resource check.
