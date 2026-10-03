# MC-7 Investigation

## Code audit

Finding MC-7 concerns `FederatedServer.notify_dead_client` iterating the live server job table while another thread removes a job from that same table.

Relevant pinned source:

- `nvflare/private/fed/server/fed_server.py:286-304`: `BaseServer.deploy` starts `cleanup_thread = threading.Thread(target=self.client_cleanup)`. `client_cleanup` loops while `not self.shutdown`, calls `self.remove_dead_clients()` every five seconds, and has no `try/except` around that call.
- `nvflare/private/fed/server/fed_server.py:309-329`: `remove_dead_clients` scans `client_manager.get_clients().items()`, logs out expired clients, and `logout_client` calls `notify_dead_client(client)`.
- `nvflare/private/fed/server/fed_server.py:1096-1113`: `FederatedServer.notify_dead_client` first resolves pending outcome jobs, then executes `for job_id, process_info in self.engine.run_processes.items(): ... self._notify_dead_job(...)`. This is a live `dict.items()` iterator, not a snapshot.
- `nvflare/private/fed/server/server_engine.py:321-326`: `_start_runner_process` inserts `self.run_processes[job.job_id] = {JOB_HANDLE, JOB_ID, PARTICIPANTS}` under `self.lock`.
- `nvflare/private/fed/server/server_engine.py:226-233`: `wait_for_complete` records return-code information and then `self.run_processes.pop(job_id, None)`.
- `nvflare/private/fed/server/server_engine.py:404-409`: `_remove_run_processes` also `pop`s the job from `run_processes`.

No common lock covers the iterator in `notify_dead_client`: the iterator site is not under `ServerEngine.lock`, and the mutation sites use `ServerEngine.lock` only around their own reads/writes. In CPython, changing dict size while a live `.items()` iterator is between elements raises `RuntimeError: dictionary changed size during iteration`. `_notify_dead_job` can block in the child-process command path, so another process waiter can naturally run between iterator advances.

## Call chain and reachability

Normal call chain:

1. `BaseServer.deploy` starts the cleanup thread (`fed_server.py:286-288`).
2. `BaseServer.client_cleanup` periodically calls `remove_dead_clients` (`fed_server.py:290-304`).
3. A registered client whose `last_connect_time` is older than `heart_beat_timeout` is removed by `logout_client` (`fed_server.py:309-329`).
4. `FederatedServer.notify_dead_client` iterates all active server jobs in `engine.run_processes` to notify affected SJs (`fed_server.py:1096-1113`).
5. Independently, server job process completion or abort cleanup removes entries from `engine.run_processes` (`server_engine.py:233`, `server_engine.py:409`).

The precondition is reachable through normal operation: at least two server jobs are present in `run_processes`, a participating client expires, the sweeper begins notifying the first job, and another job exits or is abort-cleaned before the sweeper iterator advances to the next entry.

The observable consequence is not only the immediate `RuntimeError`. Because `client_cleanup` has no handler, the cleanup thread terminates. Later expired clients remain in `ClientManager.clients`; `ServerEngine.get_clients` exposes that live list (`server_engine.py:173-174`), and `JobRunner.run` uses `engine.get_clients()` to decide whether scheduling can proceed (`job_runner.py:646-648`). Pending client outcomes also lose the early dead-client resolution path and can wait for `client_outcome_wait_timeout` (`job_runner.py:466-476`).

## Safeguards checked

- `_notify_dead_job` catches exceptions from the child RPC helper, but the `RuntimeError` from the next iterator advance is outside that helper.
- `client_cleanup` catches nothing around `remove_dead_clients`.
- There is no thread restart after `BaseServer.deploy` starts the cleanup thread.
- `wait_for_complete` and `_remove_run_processes` tolerate missing keys with `.pop(..., None)`, but that does not protect an already-created iterator.
- Several other sites snapshot `run_processes` keys before iteration. Most notably `ServerEngine.get_engine_info` uses `keys = list(self.run_processes.keys())` at `server_engine.py:149`, showing the intended snapshot pattern.

## Developer knowledge and history

Local Git history for the relevant files shows commit `58eb05f6` ("Dead clients handle (#1136)") with message text:

> Changed the self.run_processes.items() to self.run_processes.keys().
> Changed to use keys = list(self.run_processes.keys())

This is direct developer precedent for the same dictionary-iteration hazard class in server job bookkeeping. It is not a filed report for the remaining `FederatedServer.notify_dead_client` iterator site, but it is evidence that snapshotting was the intended fix pattern.

Local history searches run:

- `git log --all --grep='notify_dead_client\|run_processes\|dictionary changed\|dead client\|client cleanup' --regexp-ignore-case -- ...`
- `git log --all -S'run_processes.items()' -- ...`
- `git log --all -S'list(self.run_processes.keys())' -- ...`
- `git log --all --format=... -- ... | rg -i 'notify_dead_client|run_processes\.items|dictionary changed|dict changed|dead client|client_cleanup|runtimeerror'`

The relevant local-history match was the `58eb05f6` developer precedent above. The searches did not find an already-filed report for `notify_dead_client` killing the cleanup thread after a concurrent `run_processes` pop.

## Known-status / precedent search

Public issue/PR search was targeted to the exact mechanism/site via GitHub issue search:

- `repo:NVIDIA/NVFlare notify_dead_client run_processes` -> `total_count: 0`
- `repo:NVIDIA/NVFlare client_cleanup RuntimeError` -> `total_count: 0`
- `repo:NVIDIA/NVFlare "dead client" run_processes` -> two closed PRs about hierarchical startup/dead-detection debounce, not the live-iterator cleanup-thread death
- `repo:NVIDIA/NVFlare "dictionary changed size"` -> four closed PRs, all different sites/mechanisms
- `repo:NVIDIA/NVFlare "Changed the self.run_processes.items"` -> `total_count: 0`

The closest issue-search hit was PR `#5117` ("Clean up clients after server job failure"). Its text-match snippet
describes `difference()` iterating `exception_run_processes` while other failure/status paths resize that dictionary,
causing a heartbeat cleanup-list failure. That is a different dictionary, caller, and consequence from MC-7's
`notify_dead_client` iteration of `run_processes.items()` inside the single `client_cleanup` thread.

Unauthenticated GitHub code search returned 401, so it was not used as evidence. The issue/PR search and local history search found no public report or merged/closed PR for this exact `notify_dead_client` live `run_processes.items()` iterator causing `client_cleanup` thread termination.

Known-status evidence supports `Novelty: NEW`.

## Trigger scenario

Concrete scenario to reproduce:

1. A server has two running server jobs, each represented in `engine.run_processes` as `_start_runner_process` creates it, with a shared participating client token.
2. That client stops heartbeating and becomes expired.
3. The cleanup thread calls `remove_dead_clients`, logs out the expired client, and enters `notify_dead_client`.
4. `notify_dead_client` advances the live `run_processes.items()` iterator to the first job and calls `_notify_dead_job`; the RPC body can block.
5. While the body is blocked, a job waiter/abort-cleanup thread removes the second job from `engine.run_processes`.
6. The cleanup thread resumes and the iterator's next advance raises `RuntimeError: dictionary changed size during iteration`.
7. Because `client_cleanup` has no handler, the thread exits. A later expired client is not removed.
