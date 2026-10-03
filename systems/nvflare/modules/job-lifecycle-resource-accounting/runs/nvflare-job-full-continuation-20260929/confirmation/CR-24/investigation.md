# CR-24 Investigation

## Step 1: Code Audit

Source revision: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

Cited sites:

- `nvflare/private/fed/server/fed_server.py:1145-1149`: `FederatedServer.start_run` creates `engine_thread = threading.Thread(target=self.run_engine)`, starts it, then unconditionally writes `self.engine.engine_info.status = MachineStatus.STARTED` before polling until status becomes `STOPPED`.
- `nvflare/private/fed/server/fed_server.py:1199-1209`: `FederatedServer.run_engine` writes `STARTED`, calls `self.server_runner.run()`, then writes `STOPPED` after the runner returns.
- `nvflare/private/fed/server/server_app_runner.py:83-90`: `ServerAppRunner.start_server_app` calls `self.server.start_run(...)`; its `finally` calls `self.update_job_run_status()`. If `start_run` does not return, the normal SJ completion notification cannot be sent.
- `nvflare/private/fed/app/server/runner_process.py:124-131`: the server-job process constructs `ServerAppRunner` and calls `start_server_app` during ordinary server-job execution.
- `nvflare/private/fed/server/server_engine.py:203-234`: the server parent waits for the SJ process to exit and for `UPDATE_RUN_STATUS`; a stuck SJ keeps the server parent from observing normal completion.

Call chain and reachability:

`runner_process.py` normal SJ main -> `ServerAppRunner.start_server_app(...)` -> `FederatedServer.start_run(...)` -> starts a Python thread running `FederatedServer.run_engine(...)` -> `ServerRunner.run()`.

The trigger is reachable during ordinary server-job execution when a supported controller/workflow completes quickly. A custom controller that returns from `control_flow` immediately is a normal `Controller` implementation; the reproduction uses a real `ServerRunnerConfig`, real `ServerRunner.run`, and real `FederatedServer.start_run` with only process/network edges stubbed.

Trigger scenario:

1. The SJ process enters `ServerAppRunner.start_server_app` and calls `FederatedServer.start_run`.
2. `start_run` starts the engine thread at `fed_server.py:1146`.
3. The scheduler runs the engine thread first. `run_engine` runs the fast controller to completion, then writes `MachineStatus.STOPPED` at `fed_server.py:1209`.
4. The parent thread resumes and writes `MachineStatus.STARTED` at `fed_server.py:1148`, overwriting `STOPPED`.
5. The parent thread enters `while self.engine.engine_info.status != MachineStatus.STOPPED` and remains there, sending parent heartbeats, until an external `asked_to_stop` signal sets `STOPPED`.

Safeguards / masking checked:

- `start_run` has no compare-and-set or post-start recheck before writing `STARTED`.
- `run_engine` writes `STOPPED`, but the parent write can happen after it.
- The loop exits if `engine.asked_to_stop` becomes true. That is an external stop/parent-loss cleanup path, not a normal completion mechanism.
- `ServerAppRunner.start_server_app` would call `update_job_run_status` in `finally`, but this only runs after `start_run` returns, so it does not mask the hang.

## Step 2: Developer-Knowledge Search

Local git history/blame:

- `git blame -L 1115,1158 -- nvflare/private/fed/server/fed_server.py` shows the thread start and polling loop are old code from `e1e2e1dba` with line `1148` last touched by `d93b0c372`; the heartbeat in the loop was added by `8bb1b84cb`.
- `git blame -L 1199,1209 -- nvflare/private/fed/server/fed_server.py` shows `run_engine` and the `STOPPED` write are old code from `e1e2e1dba`.
- `git blame -L 83,92 -- nvflare/private/fed/server/server_app_runner.py` shows `start_server_app` calls `start_run` at line 83 and only sends `update_job_run_status` in `finally` at line 90.

Relevant historical PRs checked:

- PR #2235, "Fixed a race condition issue during the server start", changes `_check_server_state` and is about overseer callbacks before job_runner creation; it is not the `start_run` / `run_engine` `MachineStatus` lost update.
- PR #1023, "Enhance job run status", introduced/changed `update_job_run_status` at `ServerAppRunner` completion, but does not report this stuck-before-finally mechanism.
- PR #4209/#4288 cover hierarchical FL startup failures around deploy/start reply timeouts and `_sync_client_jobs`; not this SJ engine completion lost update.
- PR #5072 covers waiting for client terminal outcomes before finalizing jobs; not this SJ engine status race.
- PR #5194 covers client worker exit-code reporting; not this server-job `MachineStatus` lost update.
- Issue #1221 covers a client receiving `__end_run__` before workflow initialization; not this mechanism.

Tracker searches performed with GitHub issue/PR search:

- `repo:NVIDIA/NVFlare "MachineStatus.STARTED" "MachineStatus.STOPPED"` -> 0 results.
- `repo:NVIDIA/NVFlare "start_run" "run_engine" "MachineStatus"` -> 0 results.
- `repo:NVIDIA/NVFlare "ServerAppRunner" "update_job_run_status" "start_run"` -> 0 results.
- `repo:NVIDIA/NVFlare "check_engine_frequency" "asked_to_stop"` -> 0 results.
- `repo:NVIDIA/NVFlare "Fast SJ engine completion"` -> 0 results.
- `repo:NVIDIA/NVFlare "STARTED" "STOPPED" "fed_server.py"` -> one result, PR #5194, not same mechanism.
- `repo:NVIDIA/NVFlare is:pr "race condition" "server start"` -> included PR #2235 and unrelated PRs; PR #2235 is not same mechanism.
- `repo:NVIDIA/NVFlare is:issue "server start" "race"` -> issue #1221, not same mechanism.

No developer comment or test was found that treats `STARTED` overwriting an already completed `STOPPED` engine as intended.

## Step 3: Known-Status / Precedent

No existing issue, PR, CVE, advisory, or local git-history entry found reports this exact defect: `FederatedServer.start_run` overwriting a completed `run_engine` status with `MachineStatus.STARTED`, preventing `ServerAppRunner.start_server_app` from returning normally. Novelty is `NEW`.

## Phase 2 Reproduction Notes

Reproduction file: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-24_start_run_status_race.py`.

Escalation:

- Level 0: Control run uses real Python threads and the same fast controller; it returns normally with `engine_status_before_asked_to_stop=MachineStatus.STOPPED`.
- Level 1: Timing assistance only. The test replaces the `threading` module object seen by `fed_server.py` with a scheduler shim whose `Thread.start()` runs the target to completion before returning. This forces a legal interleaving: the child thread completes before the parent executes the next line after `start()`. Product source logic is not modified, and no product state is injected.
- Level 2/3: Not used.

Reproduction result saved in `repro-output.log`: the forced interleaving shows `returned_before_asked_to_stop=False` and `engine_status_before_asked_to_stop=MachineStatus.STARTED` after the engine had already completed all runner events. The test then sets `asked_to_stop` only to release the stuck loop and avoid leaving the test running.
