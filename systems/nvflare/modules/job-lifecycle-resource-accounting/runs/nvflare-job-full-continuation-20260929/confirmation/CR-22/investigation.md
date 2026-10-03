# CR-22 Investigation

## Finding

CR-22 is code-review sourced. The candidate mechanism is that a same-name client can register again while a job started with that client's earlier token is still running. Registration removes the old active token and issues a new token, but the running job's `RunProcessKey.PARTICIPANTS` map remains keyed by the old token.

## Code Audit

Relevant code:

- `nvflare/private/fed/server/client_manager.py:166` `ClientManager.authenticate()` calls `login_client()`, then records the returned regular client in `name_to_clients` and `clients` at lines 176-179.
- `nvflare/private/fed/server/client_manager.py:332` `authenticated_client()` finds every active token whose `client.name == client_name`, removes those entries from `self.clients`, and removes the name mapping before creating a fresh `Client(client_name, str(uuid.uuid4()))` at line 339.
- `nvflare/private/fed/server/fed_server.py:791` `FederatedServer.register_client()` is the CellNet registration callback and calls `self.client_manager.authenticate()` at line 841. On success it adds only the new token to `self.tokens` at line 850 and returns the new token.
- `nvflare/private/fed/server/server_engine.py:321` records a running job as `self.run_processes[job.job_id] = {..., RunProcessKey.PARTICIPANTS: job_clients}`. `job_clients` is keyed by the client token selected at job start (`server_engine.py:331-338`).
- `nvflare/private/fed/server/fed_server.py:1004` `_sync_client_jobs()` receives the current heartbeat token. For a running server job missing from the client's heartbeat, it only notifies if `participating_clients.get(client_token)` succeeds at lines 1058-1069.
- `nvflare/private/fed/server/fed_server.py:1096` `notify_dead_client()` also checks `if participating_clients and client.token in participating_clients` before notifying at lines 1109-1113.
- `nvflare/private/fed/server/server_engine.py:886` is the real downstream notification path; it sends `HANDLE_DEAD_JOB` to the child server runner. `server_commands.py:254-280` then invokes `ServerRunner.handle_dead_job()`, which calls `controller.communicator.process_dead_client_report()` at `server_runner.py:431-439`.

Reachable sequence:

1. A regular client registers through `FederatedServer.register_client()` and receives token T1.
2. A job starts for that client. `ServerEngine.start_app_on_server()` records `RunProcessKey.PARTICIPANTS = {T1: Client(site, T1)}`.
3. The same site registers again through the normal registration callback. `ClientManager.authenticated_client()` removes T1 from active clients and creates token T2.
4. The restarted/re-registered site heartbeats with T2 and no local job IDs. `_sync_client_jobs()` examines the running job but skips notification because the participant map is keyed by T1, not T2.
5. Dead-client cleanup for the active client object also uses T2 and skips the old participant entry.

Safeguards observed:

- `sync_client_jobs_require_previous_report` defaults to true and requires a prior positive job heartbeat before "missing job on client" is reported. Existing tests assert this behavior. The candidate scenario satisfies that requirement with a prior positive heartbeat from T1, but the later T2 heartbeat cannot use the recorded T1 participant entry.
- If the old process still heartbeats with T1, `_sync_client_jobs()` can still notify despite `ClientManager.heartbeat()` setting a communication error for "already registered with another token." The problematic normal scenario is a restarted site where only the new T2 process heartbeats.
- No observed downstream sync maps the new token back to the running participant. Repeated T2 heartbeats and `notify_dead_client(T2)` keep skipping the job while `run_processes` retains the old T1 participant key.

## Developer-Knowledge Search

Local history and docs searched, constrained to the pinned checkout/handoff instructions:

- `git log --oneline -- nvflare/private/fed/server/client_manager.py nvflare/private/fed/server/fed_server.py nvflare/private/fed/server/job_runner.py ...`
- `git blame` on `client_manager.py:320-345`, `fed_server.py:1004-1076`, and `fed_server.py:1096-1114`.
- `git log --all --regexp-ignore-case --grep='re-register|relogin|re-login|token|heartbeat|participant|missing job|dead job|outcome'`.
- `git log --all --regexp-ignore-case --grep='remove_client|reconnect|register again|client may register'`.
- Repository docs search for `remove_client`, `missing job on client`, and token/participant language.

Findings:

- The token-replacement behavior comes from commit `99c91c8a1` ("Support client hierarchy (#3234)") without a note about running-job participants.
- `_sync_client_jobs()` prior-positive heartbeat behavior comes from `f8efaeb78` ("Fix hierarchical FL startup failures: deployment timeouts, selective client exclusion, and dead-detection debounce (#4209) (#4288)"). Its commit message states that the default requires a prior positive report to avoid premature dead-job detection.
- Terminal-outcome/dead-client cleanup logic around client outcomes comes from `46cfc5170`, `21253dddc`, and `535373a0`. These address missing outcomes and cleanup but do not describe same-site re-registration replacing tokens still referenced by active job participants.
- `docs/migration_guide.rst:199-203` and `docs/design/nvflare_cli.md:1898-1901` explicitly say legacy `remove_client` releases only the active token so the client can register again and does not stop the client process, revoke credentials, or prevent reconnect.
- Existing unit tests in `tests/unit_test/private/fed/server/fed_server_test.py:570-628` assert that same-token missing-job heartbeats call `engine.notify_dead_job()` after prior positive observation.

Known-status/precedent:

- No local issue/PR/commit message in the pinned git history was found that reports this exact same-site re-registration / running-job participant-token mismatch. Searches did find related dead-job and outcome-barrier fixes, but they cover startup debounce, server-failure cleanup, and missing terminal outcomes, not re-registration token replacement at the participant map site.
- The run instructions also prohibit consulting external answers and upstream issue/PR discussions outside the pinned handoff/source, so known-status evidence is limited to the local issue/PR history available in the checkout.
