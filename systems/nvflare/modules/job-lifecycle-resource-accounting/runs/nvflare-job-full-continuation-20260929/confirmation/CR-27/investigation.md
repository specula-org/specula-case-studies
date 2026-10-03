# CR-27 investigation

## Step 1: Code audit

Finding source: Code Review, Scenario 27.

Cited worker bootstrap:

- `nvflare/private/fed/app/client/worker_process.py:61-67`: `main()` downloads any transferred workspace, constructs `Workspace(args.workspace, args.client_name, config_folder)`, then calls `remove_restart_file(workspace)` before job security setup and `ClientAppRunner.start_run(...)`.
- `nvflare/private/fed/app/client/worker_process.py:72-74`: `main()` then independently checks and removes `restart.fl` again.
- `nvflare/private/fed/app/client/worker_process.py:197-209`: `remove_restart_file()` unlinks both `restart.fl` and `shutdown.fl` from `workspace.get_file_path_in_root(...)`.

Marker ownership and consumers:

- `nvflare/apis/fl_constant.py:444-446` documents `restart.fl` and `shutdown.fl` as files "used by shell scripts to determine restart / shutdown".
- `nvflare/private/fed/client/client_engine.py:442-447` creates `shutdown.fl` through the client shutdown path, and `client_engine.py:512-514` touches the file before closing the federated client.
- `nvflare/private/fed/client/client_engine.py:453-458` creates `restart.fl` through the client restart path.
- `nvflare/private/fed/client/training_cmds.py:67-92` maps normal training topics `SHUTDOWN` and `RESTART` to `engine.shutdown()` and `engine.restart()`.
- `nvflare/private/fed/server/training_cmds.py:136-143` sends shutdown requests to clients; `server/training_cmds.py:180-182` invokes that path for `shutdown client/all`.
- `nvflare/lighter/templates/master_template.yml:723-728` is the provisioned wrapper consumer for a dead child process: if `shutdown.fl` is present it prints "Gracefully shutdown." and breaks; otherwise it starts FL again.
- `nvflare/lighter/templates/master_template.yml:731-739` is the provisioned wrapper consumer for a live child process: it stops on `shutdown.fl` and restarts on `restart.fl`.

Reachable same-workspace path:

- `nvflare/private/fed/client/client_executor.py:276-289` prepares the client job process args and sets `JobProcessArgs.WORKSPACE` to `args.workspace`, while `JobProcessArgs.EXE_MODULE` is `nvflare.private.fed.app.client.worker_process`.
- `nvflare/app_common/job_launcher/process_launcher.py:66-83` launches the job process using those args via the normal process job launcher.
- Therefore a normal client job child starts `worker_process.main()` against the same workspace root watched by the provisioned shell loop.

Concrete trigger scenario:

1. A provisioned client is running under `sub_start.sh`; the wrapper has `pid.fl` for the top-level client process.
2. An admin/operator initiates client shutdown, reaching `ClientEngine.shutdown()` and `shutdown_client()`, which touches `$WORKSPACE/shutdown.fl`.
3. A client job worker starts concurrently with the same `args.workspace`.
4. `worker_process.main()` calls `remove_restart_file(workspace)` and removes `$WORKSPACE/shutdown.fl`.
5. The top-level client process exits because shutdown is in progress.
6. The shell wrapper next evaluates its dead-process branch. Without `shutdown.fl`, it takes "start fl because process ... does not exist" instead of "Gracefully shutdown."

Safeguards/masks:

- For `restart.fl`, the admin restart path also closes the client process; if the process dies, the wrapper can still restart via the dead-process fallback even if the marker was removed. This can mask the restart-marker consequence for that path.
- For `shutdown.fl`, the dead-process fallback is the wrong outcome: marker loss converts a requested graceful shutdown into a restart. No downstream resend or loopback was found in the shell loop.
- The top-level `client_train.py:59-66` and `server_train.py:56-63` also remove stale markers during site startup. That is distinct from the per-job worker cleanup because the worker is a child process that can run while the site wrapper still owns and consumes the root markers.

## Step 2: Developer-knowledge search

Comments/docs:

- `fl_constant.py:444-446` says the two files are for shell scripts to determine restart/shutdown.
- `worker_process.py:197-203` only documents "To remove the restart.fl file"; it does not explain why `shutdown.fl` is also removed by a job worker.
- `master_template.yml:548-558` tells operators that `stop_fl.sh` creates `shutdown.fl` and waits for the local FL process to shut down.

Tests:

- `tests/unit_test/lighter/static_file_builder_test.py:318` checks that `stop_fl.sh` contains `touch "$WORKSPACE/shutdown.fl"`.
- `tests/unit_test/lighter/poc_commands_test.py:309-315`, `tests/unit_test/tool/poc/poc_output_test.py:1379-1380`, and `tests/unit_test/tool/deploy/deploy_commands_test.py:91` assert shutdown marker creation in generated commands.
- No existing test found for a job worker removing a concurrently created root `shutdown.fl`/`restart.fl` before the shell wrapper observes it.

Commits/blame:

- `git blame` shows the worker cleanup call and helper edits came from `e5e8c15a` ("Dev authz integrate (#856)") and older initial/docstring commits; the commit message is broad and does not describe marker-race intent.
- Local git history searches run:
  - `git log --oneline --decorate -- nvflare/private/fed/app/client/worker_process.py`
  - `git log --grep='worker.*restart|restart.*worker|shutdown.*worker|marker|restart.fl|shutdown.fl' --regexp-ignore-case HEAD`
  - `git log -S'restart.fl' -- nvflare/private/fed/app/client/worker_process.py nvflare/private/fed/app/client/client_train.py nvflare/lighter/templates/master_template.yml nvflare/private/fed/client/client_engine.py`
  - `git log -S'shutdown.fl' -- nvflare/private/fed/app/client/worker_process.py nvflare/private/fed/app/client/client_train.py nvflare/lighter/templates/master_template.yml nvflare/private/fed/client/client_engine.py`
- These found marker-related commits and PR-numbered commit messages, but no local report or fix message for the exact mechanism "client worker bootstrap removes a pending root shutdown/restart marker before the shell owner consumes it."

Issue/PR tracker note:

- The continuation instructions prohibited consulting external upstream issue/PR discussions or newer source beyond the pinned experiment revision. Known-status was therefore checked via the pinned checkout's git history, commit messages, local docs, and tests.

## Step 3: Known-status / precedent

No existing local issue/PR/CVE/advisory or prior-report evidence was found for this exact mechanism at this exact site. The finding proceeds to Phase 2 as code-review sourced and not dropped.
