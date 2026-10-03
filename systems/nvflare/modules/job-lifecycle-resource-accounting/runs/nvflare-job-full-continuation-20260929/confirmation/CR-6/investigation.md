# CR-6 Investigation: live dictionary iteration disrupts lifecycle services

## Step 1: Code audit

Source checkout: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-6/worktree`, commit `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

Relevant code:

- `nvflare/private/fed/server/fed_server.py:290-304`: `client_cleanup()` has no `try` around `remove_dead_clients()`. An exception in dead-client cleanup terminates the cleanup thread.
- `nvflare/private/fed/server/fed_server.py:309-330`: `remove_dead_clients()` iterates `self.client_manager.get_clients().items()` from `ClientManager.get_clients()`, which returns the live `self.clients` dict (`client_manager.py:431-437`). It later calls `logout_client(token)` for tokens captured in a stale list; `logout_client()` does not tolerate `remove_client(token)` returning `None`.
- `nvflare/private/fed/server/fed_server.py:1096-1113`: `notify_dead_client()` iterates live `self.engine.run_processes.items()` while `ServerEngine.wait_for_complete()` / `_remove_run_processes()` may pop entries (`server_engine.py:233`, `:408-409`).
- `nvflare/private/fed/server/job_runner.py:854-861`: `stop_all_runs()` iterates live `engine.run_processes.keys()`, calls `stop_run()`, and sets `ask_to_stop` only after the loop finishes.
- `nvflare/private/fed/server/training_cmds.py:158-170`: admin `shutdown` iterates live `engine.job_runner.running_jobs.items()` without `JobRunner.lock`.

Reachability / callers:

- `client_cleanup()` is started by `FederatedServer.start()` (`fed_server.py:286-288`) and repeatedly calls `remove_dead_clients()`.
- `logout_client()` is called from `remove_dead_clients()` and `quit_client()` (`fed_server.py:895`).
- `notify_dead_client()` is called from `logout_client()` and is part of dead-client cleanup.
- `stop_all_runs()` is called by `ServerEngine.stop_all_jobs()` (`server_engine.py:1089-1091`), which is called on server shutdown (`server_engine.py:1104-1110`, `fed_server.py:1243-1247`).
- `TrainingCommandModule.shutdown()` is the admin shutdown command path.

Trigger scenarios:

- A client cleanup scan iterates `client_manager.clients` while a concurrent quit/remove path removes a client token. Python raises `RuntimeError: dictionary changed size during iteration`; because `client_cleanup()` has no handler, the cleanup thread exits.
- `remove_dead_clients()` builds a delete list, then another normal path removes the same token before `logout_client(token)` runs. `logout_client()` passes `None` to `notify_dead_client()`, which dereferences `client.name` and raises `AttributeError`; the cleanup thread exits.
- `notify_dead_client()` iterates `engine.run_processes.items()` while a wait/cleanup thread pops a run process. Python raises `RuntimeError`; when called from cleanup, this exits the cleanup thread.
- `stop_all_runs()` iterates `engine.run_processes.keys()` while aborting a job removes the first run process. Python raises before later jobs are stopped and before `ask_to_stop` is set.
- Admin shutdown iterates `running_jobs.items()` while the completion thread removes a job; the admin command thread raises `RuntimeError`.

Safeguards found:

- Some code uses snapshots elsewhere, e.g. `ServerEngine.get_engine_info()` uses `list(self.run_processes.keys())` (`server_engine.py:149`) and `pause_server_jobs()` uses `list(self.run_processes.keys())` (`server_engine.py:1094`). The cited sites do not snapshot.
- `client_cleanup()` has no exception guard around `remove_dead_clients()`.
- `stop_all_runs()` has no `try/finally`; `ask_to_stop` is skipped if iteration raises.
- No caller guard was found for admin `shutdown` iteration over `running_jobs`.

## Step 2: Developer-knowledge search

Local pinned-history and source/test search only, per continuation constraints. Commands run:

- `git log --grep='stop_all_runs\|dictionary changed\|dead client\|notify_dead_client\|remove_dead_clients\|running_jobs\|run_processes\|shutdown' HEAD -- ...`
- `git log --oneline HEAD -- nvflare/private/fed/server/fed_server.py nvflare/private/fed/server/job_runner.py nvflare/private/fed/server/training_cmds.py`
- `rg 'dictionary changed|stop_all_runs|notify_dead_client|remove_dead_clients|client_cleanup|running_jobs\.items\(|run_processes\.items\(|run_processes\.keys\(\)' nvflare tests docs`
- `git blame` on the cited spans.

Relevant findings:

- Commit `1a0289d0` (`FLARE-3096: Downgrade harmless abort and fail logs to INFO (#5051)`) says late stop/abort/failure for a job already out of `running_jobs` is expected, and validation added coverage for `stop_all_runs()` encountering an untracked process. The current test `tests/unit_test/private/fed/server/job_runner_test.py:803-821` covers a single untracked entry and expects `ask_to_stop=True`; it does not cover mutation during the iteration.
- Commit `46cfc517` introduced the terminal client-outcome barrier and dead-client outcome resolution. The current test `tests/unit_test/private/fed/server/fed_server_test.py:911-926` covers `notify_dead_client()` resolving a barrier-only job with `engine.run_processes={}`, not live `run_processes` mutation.
- Commit `f948b6ec` is "Improve dead client handling (#2506)", but local commit text does not report the live-dict mutation or stale logout-token failure.
- No in-tree test, comment, or local commit message found a prior report for the exact live-dictionary mutation mechanism at these sites. No `dictionary changed size during iteration` match exists for these files in source/tests/docs.

Blame:

- `fed_server.py:309-330` dates to `e1e2e1d`, `62ac8c6`, and token redaction commit `1884fe0`; no local message says this is intentional.
- `fed_server.py:1096-1113` comes from dead-client handling (`58eb05f`, `f948b6e`) and outcome-barrier changes (`46cfc5`).
- `job_runner.py:854-861` comes from 2022 shutdown logic and 2023 aborted-job shutdown check.
- `training_cmds.py:164` comes from `9f49a109` ("update the aborted job status immediately; Enhance the shutdown server running job check").

## Step 3: Known-status / precedent

This is code-review sourced. I found adjacent lifecycle work and tests, but no existing issue/PR/commit/test in the pinned local history that reports this exact defect: live iteration of `client_manager.clients`, `engine.run_processes`, or `running_jobs` causing dead-client cleanup termination, partial stop-all shutdown, or admin command failure at the cited sites. Novelty for the final report is therefore `NEW` under the available/allowed search evidence.
