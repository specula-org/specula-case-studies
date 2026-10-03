# CR-28 investigation

## Finding

CR-28 is code-review sourced. It alleges that a deploy failure after a partial server/client deployment leaves workspace state that later public operations can observe.

## Source path and contract

The deployment path in `nvflare/private/fed/server/job_runner.py` writes the server app before client deployment replies are evaluated. `JobRunner._deploy_job` creates the server app through `AppDeployer.deploy` before sending deploy requests to clients, then raises `RuntimeError("deploy failure", deploy_detail)` if the successful client count is below `job.min_sites` or a required client fails. The `run()` exception path sets `RunStatus.FAILED_TO_RUN` and fires `JOB_ABORTED`, but does not call `_save_workspace` and does not call `_delete_run`.

The apparent cleanup helper is `JobRunner._delete_run`, which sends `TrainingTopic.DELETE_RUN` to clients and then calls `engine.delete_job_id(job_id)`. A local source search found only its definition, not an active caller. The disabled admin command `DELETE_WORKSPACE` also calls equivalent cleanup but is registered with `enabled=False`.

The public workspace contract is not "best effort only": `docs/user_guide/core_concepts/workspace.rst` says that when a job has finished, the server workspace is removed and saved into job storage, and `download_job [JOB_ID]` downloads the server side workspace. `docs/user_guide/admin_guide/deployment/operation.rst` describes `download_job` as downloading the job and workspace from the job store. `docs/user_guide/nvflare_cli/job_cli.rst` says the job must be terminal before download.

Developer-history evidence reinforces that cleanup was intended: the HEAD-reachable commit `d3e32795` is titled "Added job FAILED_TO_RUN status. Changed the multi-run run_number format. (#492)" and includes "delete the workspace if job failed to run." Current HEAD has `FAILED_TO_RUN` handling but no active `_delete_run` caller for the partial deploy failure path.

## Reachability

The trigger uses a real scheduler/runner sequence. A normal submitted job targets the server, `site-1`, and `site-2` with `min_clients=2`. The scheduler dispatches the job while both clients are connected. Server deployment succeeds and creates `<workspace>/workspace_<job_id>/app_server`. Then one client returns a normal deploy error reply. That reply is reachable from the real client `DeployProcessor` in `nvflare/private/fed/client/training_cmds.py`, which returns `error_reply(...)` for bad app staging, signature, or app deployment errors. `JobRunner._deploy_job` counts the reply as a failed client, drops below `min_clients`, and raises.

## Later public observer

The later public operation is `JobCommandModule.download_job`. It accepts any status that starts with `FINISHED:`, then asks the job definition manager for `job.zip`, `meta.json`, and `workspace.zip`. For the filesystem store, `get_data_for_download` creates a symlink for an existing component, but if the requested component is absent it logs and skips the symlink without raising. Therefore a `FINISHED:FAILED_TO_RUN` job can be downloadable without `workspace.zip`, even though a live server run directory still exists outside the job store.

## Safeguards checked

The normal archive path `_job_complete_process -> _save_workspace` only iterates `running_jobs`, and this failure happens before the job is registered in `running_jobs`. `_stop_run` aborts live processes but does not archive or delete the workspace. `_delete_run` is not called. `delete_job` deletes the job store object and does not remove the live runtime workspace. The disabled `delete_workspace` command is not an active downstream public mechanism.

The residue is therefore persistent in the current server workspace and is not later reconciled into job storage by `download_job`.

## Prior-report search

External issue/PR tracker search was not performed because the continuation instructions prohibit consulting external/upstream discussions or newer commits. Within the allowed pinned local repository history, HEAD-reachable `git log HEAD --grep` and `git log HEAD -S'_delete_run'` searches found related lifecycle/history commits but no same-mechanism known report or fix that marks CR-28 already known.

