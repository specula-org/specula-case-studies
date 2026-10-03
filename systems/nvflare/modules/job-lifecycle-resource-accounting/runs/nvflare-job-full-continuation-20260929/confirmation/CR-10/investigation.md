# CR-10 Investigation

## Candidate

Code-review finding CR-10 claims that disabling an active client removes the client's session but skips the normal dead-client outcome-resolution path. A server job that already finished on the server can therefore remain non-terminal until `client_outcome_wait_timeout` expires, keeping the job scheduler's `max_jobs` slot occupied.

## Source audit

- `nvflare/private/fed/server/training_cmds.py:222-234` exposes the admin `disable_client` command and dispatches it to `engine.disable_clients(client_names)`.
- `nvflare/private/fed/server/server_engine.py:620-644` implements `ServerEngine.disable_clients`. It calls `client_manager.disable_client`, removes active client data, and informs admin bookkeeping through `admin_server.client_dead(token)`. It does not call `FederatedServer.notify_dead_client`.
- `nvflare/private/fed/server/client_manager.py:117-140` adds the client name to `disabled_clients`, removes active tokens from `clients`, and removes the name mapping.
- `nvflare/private/fed/server/admin.py:258-265` shows that `admin_server.client_dead(token)` only removes the admin-server client record. It does not resolve pending job outcomes.
- The normal dead-client path is different: `nvflare/private/fed/server/fed_server.py:309-330` removes dead clients through `logout_client`, and `logout_client` calls `notify_dead_client(client)`. `nvflare/private/fed/server/fed_server.py:1096-1106` then resolves every pending client outcome for that client through `_resolve_missing_client_outcome`.
- `nvflare/private/fed/server/job_runner.py:287-364` creates `_pending_client_outcomes[job_id]` for started clients. `nvflare/private/fed/server/job_runner.py:441-480` refuses to publish terminal status while pending outcomes remain, records a deadline of `time.monotonic() + client_outcome_wait_timeout`, and only clears unresolved outcomes at the deadline. The default is 900 seconds in `nvflare/private/fed/server/job_runner.py:99-111`.
- `nvflare/app_common/job_schedulers/job_scheduler.py:263-285` keeps a job id in `scheduled_jobs` from `JOB_STARTED` until `JOB_COMPLETED` or `JOB_ABORTED`; `_exceed_max_jobs` blocks later work when `len(scheduled_jobs) >= max_jobs`.
- A disabled client cannot normally clear the outcome itself after removal. `nvflare/private/fed/server/fed_server.py:906-918` rejects terminal reports from a token no longer authorized by `client_manager`. `nvflare/private/fed/server/fed_server.py:970-989` rejects heartbeat from disabled clients before `_sync_client_jobs` can run. `nvflare/private/fed/server/client_manager.py:267-270` and `325-330` reject disabled registration.

## Reachability

The pending outcome is reachable in the normal lifecycle: `JobRunner.run` calls `_start_run`, `_start_run` initializes `_pending_client_outcomes`, fires `JOB_STARTED`, and `JobRunner.run` records the job in `running_jobs` before publishing `RUNNING` (`nvflare/private/fed/server/job_runner.py:703-711`). The public admin command can then disable one of the active client names. When the server-side process finishes cleanly before the client reports its terminal outcome, `_job_complete_process` sees no server failure and waits for the missing client outcome.

## Developer intent

The dead-client path already resolves missing outcomes explicitly. The docs and API describe `disable_client` as an administrative operation that disables a client identity and removes its active session, not as a request to keep finished jobs in progress. `docs/user_guide/nvflare_cli/system_command.rst:220-225` documents that a disabled client is removed from the active registry and later registration/heartbeat is rejected until re-enabled.

The outcome barrier was introduced by commit `46cfc5170` ("Wait for client terminal outcomes before finalizing jobs (#5072)") and refined by `535373a08` ("Finalize failed jobs with missing client outcomes (#5221)"). I found no local commit or upstream issue/PR metadata matching the disable-client/missing-outcome mechanism. GitHub issue/PR searches for `disable_client client_outcome`, `disable client terminal outcome`, `client_outcome_wait_timeout disable`, `pending client outcomes disable`, `missing client outcomes disable`, `notify_dead_client disable_client`, `disable_clients pending`, and `disable_clients outcome` found no same-mechanism report or fix.

## Safeguards and masks

The state is bounded, not permanent: `JobRunner._job_complete_process` clears the pending outcome after `client_outcome_wait_timeout`. That downstream timeout does not prevent the externally observable delay. During the grace window the job remains in `running_jobs`, no terminal status is published, and the default scheduler continues to count the job against `max_jobs`.

`remove_clients` has a similar missing call to `_remove_dead_client`, but unlike `disable_clients` it does not block the client name from re-registering. A later reconnect/heartbeat can reach `_sync_client_jobs` and resolve or fail the missing outcome path. Re-enable similarly makes a future registration/heartbeat possible. The problematic disable case is the one where the disabled identity is intentionally prevented from reaching those normal sync paths until an admin enables it or the timeout expires.
