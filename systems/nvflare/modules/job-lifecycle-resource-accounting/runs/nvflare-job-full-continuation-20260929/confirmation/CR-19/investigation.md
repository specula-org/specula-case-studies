# CR-19 Investigation

## Finding

Code-review finding CR-19: `ServerEngine._start_runner_process` replaces an empty `job_clients` mapping with `self.client_manager.clients`, then stores that object as `RunProcessKey.PARTICIPANTS`.

## Code Audit

- Cited site: `nvflare/private/fed/server/server_engine.py:318-325`. If `job_clients` is falsy, line 319 assigns the live client registry (`self.client_manager.clients`), and line 325 stores that same object in `self.run_processes[job_id][RunProcessKey.PARTICIPANTS]`.
- Caller: `JobRunner._start_run` builds `job_clients = engine.get_job_clients(client_sites)` at `nvflare/private/fed/server/job_runner.py:295-304` and passes it to `engine.start_app_on_server`. `ServerEngine.get_job_clients` returns a token-to-client dict only for currently registered clients at `server_engine.py:331-338`, so it can return `{}` when scheduled/deployable client sites have disconnected by the start-server-app point.
- Reachability from normal flow: `JobRunner.run` schedules a job, deploys it, writes `DISPATCHED`, computes `deployable_clients`, then calls `_start_run` at `job_runner.py:703-708`. The scheduler selects only currently online sites (`job_scheduler.py:106-137`) and `_deploy_job` tolerates non-required failed deploys only when `min_sites` still holds (`job_runner.py:241-285`). A client can disconnect after those checks and before `_start_run` calls `get_job_clients`.
- Mutators of the aliased object: `ClientManager.authenticate` registers clients by updating `self.clients` at `client_manager.py:176-179`; heartbeat reactivation also updates it at `client_manager.py:412-416`; `remove_client` pops from it at `client_manager.py:202-209`; `disable_client` removes tokens at `client_manager.py:117-140`.
- Consumers of `PARTICIPANTS`:
  - `JobRunner._stop_run` computes active participants from `engine.client_manager.clients` and stored `PARTICIPANTS`, then sends `ABORT` to those names (`job_runner.py:381-409`).
  - `JobRunner._get_finished_job_status` does the same for exception finalization (`job_runner.py:574-585`).
  - `FederatedServer._listen_command(GET_CLIENTS)` sends the stored `PARTICIPANTS` object to the server job process (`fed_server.py:584-593`).
  - `FederatedServer._sync_client_jobs` uses `PARTICIPANTS` to decide whether a missing client job is a dead job (`fed_server.py:1039-1069`).
  - `FederatedServer.notify_dead_client` has no prior-positive-heartbeat debounce; it iterates `run_processes` and calls `_notify_dead_job` if the dead client's token is in `PARTICIPANTS` (`fed_server.py:1105-1113`).
  - `ServerEngine.notify_dead_job` forwards the report into the SJ via `HANDLE_DEAD_JOB` (`server_engine.py:886-897`), and the server runner passes it to workflow communication (`server_runner.py:431-439`, `wf_comm_server.py:181-186`).

## Trigger Scenario

1. A normal job is scheduled with at least one client site, and deployment succeeds or is tolerated.
2. Before `_start_run` calls `engine.get_job_clients(client_sites)`, all deployable client sites are no longer registered. This makes `job_clients == {}`.
3. `start_app_on_server` starts the server job and stores `self.client_manager.clients` as `PARTICIPANTS`.
4. A different client later registers or is reactivated. Because `PARTICIPANTS` aliases the live registry, this non-participant token appears in the job's participant set.
5. If that unrelated client is later removed as dead, `notify_dead_client` reports it to the SJ as a dead participant of the running job.

Safeguards checked:
- `sync_client_jobs_require_previous_report=true` masks the heartbeat missing-job path for first missing reports (`fed_server.py:1067-1069`; docs say this prevents false dead-job reports), but `notify_dead_client` does not use that guard.
- A direct `ABORT` sent to a non-participant client is mostly masked by `ClientEngine.abort_app`, which returns "Client app has not started" for `NOT_STARTED` jobs (`client_engine.py:390-404`). This does not mask the dead-client notification path.
- A snapshot participant dict avoids the effect: adding a later client does not mutate the stored `PARTICIPANTS` dict, and `notify_dead_client` does not notify the SJ.

## Developer Knowledge

- `git blame -L 318,325 -- server_engine.py` attributes the fallback and participant storage to `26d931cf` ("keep running clients for job", 2022-04-18), with later launcher refactors preserving the fallback.
- `git log -L 318,325:nvflare/private/fed/server/server_engine.py` shows the original code used all clients with a TODO "each run will have its own participants. Use all clients for now." Commit `26d931cf` replaced that with `job_clients`, but retained `if not job_clients: job_clients = self.client_manager.clients`.
- Docs and tests show false dead-job reports are not intended: `docs/programming_guide/timeouts.rst:2468-2471`, `docs/user_guide/timeout_troubleshooting.rst:303-304`, and `tests/unit_test/private/fed/server/fed_server_test.py:630-657`.
- No nearby comment or test says that an empty job-specific participant set should dynamically mean all currently registered clients.

## Known Status

Searches performed in the pinned local history through `HEAD`:
- `git log --oneline HEAD --grep='participant|job_clients|start_app_on_server|client_manager.clients|GET_CLIENTS|dead client|abort_job' -- ...`
- `git log --oneline HEAD -G'job_clients = self\.client_manager\.clients|RunProcessKey\.PARTICIPANTS: job_clients|PARTICIPANTS' -- ...`
- `git blame -L 318,325 -- nvflare/private/fed/server/server_engine.py`
- `git log -L 318,325:nvflare/private/fed/server/server_engine.py`

The search found participant/dead-client history and related PR-numbered commits (for example `26d931cf`, `1571296f`, `f948b6ec`, `572990d1`, `46cfc517`), but no prior report or fix for the exact mechanism: empty `job_clients` aliasing the live client registry and later causing a non-participant dead-job notification. Per the continuation instructions, I did not inspect newer commits or upstream issue/PR discussion pages.
