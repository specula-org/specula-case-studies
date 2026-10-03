# Deep analysis: server_engine / fed_server / client_manager / admin

STATUS: IN PROGRESS

Pinned source: /home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/full/source @ 53ba7ee5
Scratch scripts: /home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/full/run/nvflare-job/.specula-output/evidence/deep/server_engine/

Files read completely:
- nvflare/private/fed/server/server_engine.py (1115 lines)
- nvflare/private/fed/server/fed_server.py (1253 lines)
- nvflare/private/fed/server/client_manager.py (474 lines)
- nvflare/private/fed/server/admin.py (343 lines)
- (adjacent) nvflare/private/fed/server/job_runner.py (869 lines)

## Findings (appended as verified)

### SE-L4 (coordinator lead, archaeology batch 4): disable_client / remove_client bypass the dead-client outcome resolution -> finished job holds its admission slot for client_outcome_wait_timeout

- Claim: `ServerEngine.disable_clients` (server_engine.py:620-644) and `ServerEngine.remove_clients` ->
  `_remove_dead_client` (:610-614, :666-670) pop the client's token from `ClientManager.clients`
  (client_manager.py:117-140 / :193-209), `FederatedServer.tokens` and `admin_server.clients`, but never call
  `FederatedServer.notify_dead_client` (fed_server.py:1096-1113). The only callers of `notify_dead_client` are
  `BaseServer.logout_client` (fed_server.py:324-330), reached from `remove_dead_clients` (:309-322) and
  `quit_client` (:882-904) (grep: no other caller). So `JobRunner._pending_client_outcomes[job]` keeps the
  client's name.
- Why nothing else resolves it:
  - `remove_dead_clients` scans only `client_manager.get_clients()`; the token is already gone (fed_server.py:313).
  - disabled client: its heartbeat is rejected before `_sync_client_jobs` (fed_server.py:978-979) and its outcome
    report is rejected (`is_from_authorized_client`, fed_server.py:916-918); `quit_client` needs a valid token
    (client_manager.py:245).
  - `_sync_client_jobs` of *other* clients only resolves the heartbeating client's own outcomes
    (fed_server.py:1053-1055).
  - `_job_complete_process` then waits until `client_outcome_wait_timeout` (default 900 s, job_runner.py:109-111,
    466-476) unless the server job failed (:457-465) or `run_aborted`.
  - The DefaultJobScheduler slot is released only on JOB_COMPLETED/JOB_ABORTED (job_scheduler.py:281-285), fired
    after terminal publication (job_runner.py:536-538). `restart`/`shutdown` admin commands also refuse while
    the job is in `running_jobs` (training_cmds.py:164-170, 265-268).
- Compensating mechanisms checked: the 900 s deadline bounds the delay. `enable_client` lets a live client
  re-activate its old token through heartbeat (client_manager.py:399-417). The outcome is then resolved, but as
  `fail_run(INFRASTRUCTURE_ERROR)` if the SJ is already gone (fed_server.py:1090-1093). For `remove_client` of a
  *live* client the next heartbeat re-activates the same token, so only a report that lands in the gap is lost
  (-> FINISHED_ABNORMAL through the same path). For a *dead* client, admin `remove_client` skips the
  heartbeat-timeout dead-client path that would have resolved it.
- Reproduction (real FederatedServer.process_job_failure/client_heartbeat/_listen_command/logout_client,
  real ServerEngine.disable_clients/remove_clients/wait_for_complete, real ClientManager, real JobRunner
  `_job_complete_process`, real DefaultJobScheduler; fake job store/handle/cell; outcome timeout set to 4 s):
  `server_engine/repro_disable_client_outcome_wait.py` -> `server_engine/out_disable_client_outcome_wait.txt`:
  - control `logout_client` (dead-client path): pending resolved at once, J1 finalized 0.75 s after SJ exit.
  - `disable_client site-2`: report and heartbeat from site-2 -> `unauthenticated`; pending stays `{site-2}`;
    J1 finalized 4.75 s after SJ exit (= timeout + 1 s poll). `_exceed_max_jobs` was True (max_jobs=1) in 18/19
    samples during the wait.
  - `remove_client site-2` (client silent afterwards): identical 4.75 s.
- Side effect: the disabled client's CJ is never told to abort. Its heartbeat never reaches `_sync_client_jobs`,
  and `_get_active_job_participants` excludes it (job_runner.py:78-96). So that client's resources are
  released only when its CJ ends by itself (client-side, not verified here).
- Verdict: CONFIRMED (bounded by client_outcome_wait_timeout). Severity: Medium-Low. A supported admin operation
  can delay terminal status by up to 900 s after a normal finish and hold the only admission slot
  (default max_jobs=1), blocking later eligible jobs and restart/shutdown.
- Suggested verification: model check (admin disable/remove as an action that removes a session without
  resolving outcomes; property "finished server job is published within bounded steps once no participant can
  report") + unit test like the repro.

### SE-1: One exception kills the dead-client detection thread for the rest of the server parent's life (three reachable triggers)

- Claim: `BaseServer.client_cleanup` (fed_server.py:290-304) is the only periodic dead-client detector. It runs
  `remove_dead_clients()` with no try/except. Three ordinary interleavings raise inside it. After that the
  thread is gone, so for the rest of the parent's life a silent client is never logged out.
  `notify_dead_client` never runs again: no HANDLE_DEAD_JOB reaches the SJ, pending client outcomes of dead
  clients are never resolved early, and dead clients stay in `client_manager.clients` / `engine.get_clients()`.
  - A (same mechanism as K4, new site): `remove_dead_clients` iterates the live dict
    `self.client_manager.get_clients().items()` (fed_server.py:313; `get_clients` returns the live `self.clients`,
    client_manager.py:431-437) without `ClientManager.lock`. Every writer takes the lock
    (authenticate :176-179, authenticated_client :325-337, heartbeat re-activation :388-417,
    disable_client :118-126, remove_client :202-205), but that does not protect an unlocked Python-level loop.
    A registration/re-activation/disable/quit during the scan gives
    `RuntimeError: dictionary changed size during iteration`.
  - B (K4 mechanism, new site): `FederatedServer.notify_dead_client` iterates the live
    `self.engine.run_processes.items()` (fed_server.py:1109) with no lock. Its body `_notify_dead_job` ->
    `ServerEngine.notify_dead_job` -> `send_command_to_child_runner_process` blocks on `engine.lock` (held up
    to 5 s by other SJ commands, server_engine.py:899-928) and does cell I/O. If any job is inserted
    (`_start_runner_process` :321-326) or popped (`wait_for_complete` :233, `_remove_run_processes` :409)
    meanwhile -> RuntimeError.
  - C (stale snapshot): `remove_dead_clients` collects tokens first (:313-315) and logs them out later
    (:316-317) without re-checking. Each `logout_client` can take seconds (fail_run -> `_stop_run` ->
    `abort_client_run` 2 s + `abort_app_on_server` 1 s). If the stale client re-registers in between
    (`authenticated_client` pops the old token, client_manager.py:332-337) or quits / is disabled, then
    `remove_client` returns None (:203-209) and `notify_dead_client(None)` raises AttributeError on
    `client.name` (fed_server.py:1105; also :319).
- Compensating mechanisms checked: none restart the thread (only started in `BaseServer.deploy`, :286-288).
  CoreCell converts callback exceptions into PROCESS_EXCEPTION replies (core_cell.py:1791-1795). So the same
  exceptions reached through `quit_client` only lose that quit's notifications (no thread death). Pending
  outcomes are still bounded by `client_outcome_wait_timeout` (900 s). The SJ gets no dead-client signal at all
  (see SE-3), so SAG-style workflows (train_timeout=0 default, scatter_and_gather.py:47) can wait
  indefinitely for a dead site. Later jobs: dead-but-listed clients are offered to the scheduler
  (`_try_job` uses `engine.get_clients()`). Every CHECK_RESOURCE to them blocks the single JobRunner thread for
  15 s (server_engine.py:1023). `shutdown server` refuses while "active clients" are listed
  (training_cmds.py:172-178).
- Reproduction: `server_engine/repro_client_cleanup_thread_death.py` -> `out_client_cleanup_thread_death.txt`.
  Uses the real `client_cleanup` thread body, real register_client/ClientManager/wait_for_complete/
  notify_dead_client and a stub cell. The interleaving is forced with `sys.settrace` inside the cleanup thread
  only (scheduling control, no product object modified):
  - N (control): thread alive; site-3 goes silent -> logged out, 1 HANDLE_DEAD_JOB, outcome resolved.
  - A: `RuntimeError('dictionary changed size during iteration')` at fed_server.py:313 -> thread dead ->
    site-3 goes silent: still listed, 0 HANDLE_DEAD_JOB, pending `{site-1, site-2, site-3}` stays.
  - B: RuntimeError at fed_server.py:1109 (J2's SJ exited during the body) -> same consequences.
  - C: `AttributeError: 'NoneType' object has no attribute 'name'` at fed_server.py:1105 -> same consequences.
- Verdict: CONFIRMED (mechanism and consequence). Trigger probability per scan is low for A (small window) and
  higher for B/C (blocking bodies, seconds-long logout loop). The impact is permanent and silent: only a
  thread traceback on stderr, no recovery. Severity: Medium.
- Suggested verification: model check (a dead-client-detector process that can crash on a concurrent
  add/remove; liveness "every client silent > timeout is eventually logged out") plus the forced-interleaving
  test above. Code review: wrap the loop body, iterate a snapshot, re-check `last_connect_time` and handle a
  None result from `remove_client` (fix not applied, per rules).

