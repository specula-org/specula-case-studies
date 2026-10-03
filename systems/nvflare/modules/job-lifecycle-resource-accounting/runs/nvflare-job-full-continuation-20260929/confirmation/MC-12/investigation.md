# MC-12 Investigation

## Finding

- Source: model-checking
- Invariant: NoDeletedTrackedSlot
- Counterexample: `spec/output/continuation-H4-probe_deleted_slot/tlc.out`
- Title: Stale delete authorization can strand a running job and its admission slot

## Counterexample audit

The TLC trace reaches the stale-delete interleaving described by MC-12. The important actions are:

1. `MCAdminDeleteAuthorize` records a delete authorization snapshot for `j1` while the job is `SUBMITTED`.
2. The runner schedules, deploys, starts, inserts `j1` into `runningJobs`, and publishes `RUNNING`.
3. `MCAdminDeleteExec` executes the already-authorized delete using the stale `SUBMITTED` snapshot, deleting the job while `runningJobs=["j1"]` and the scheduler slot still contains `j1`.

The final trace state has `status.j1=DELETED`, `runningJobs=["j1"]`, `slots=["j1"]`, and later eligible work (`j2`) still `SUBMITTED`.

## Source audit

`nvflare/private/fed/server/job_cmds.py` registers `delete_job` with `authz_func=self.authorize_job` and `confirm=ConfirmMethod.AUTH`. `authorize_job_id` reads the job from storage and stores that `Job` object on the connection as `self.JOB` before the confirmed handler runs. `delete_job` later reads this cached job and checks `job.meta[status]` for `DISPATCHED` or `RUNNING` before calling `job_def_manager.delete(job_id, fl_ctx)`. There is no fresh status read in the confirmed handler.

`nvflare/apis/impl/job_def_manager.py` implements `delete` by deleting the job object from storage. `get_job` returns `None` after the storage object is missing, and `set_status` ultimately calls the storage layer to update the missing object.

`nvflare/app_common/storages/filesystem_storage.py` raises `StorageException` from `update_meta` when the object no longer exists.

`nvflare/private/fed/server/job_runner.py` adds a job to `running_jobs` after `_start_run` succeeds and then publishes `RUNNING`. Its completion loop publishes terminal status before deleting `running_jobs[job_id]` and before firing `JOB_COMPLETED`/`JOB_ABORTED`. If status publication raises, the loop logs and continues before both map removal and lifecycle release.

`nvflare/app_common/job_schedulers/job_scheduler.py` appends the job id to `scheduled_jobs` on `JOB_STARTED` and removes it only on `JOB_COMPLETED` or `JOB_ABORTED`. `_exceed_max_jobs` blocks scheduling when `len(scheduled_jobs) >= max_jobs`.

## Trigger reachability

The trigger is reachable through the normal confirmed-admin-command split:

1. A delete command for a `SUBMITTED` job runs `authorize_job_id`, which caches the `SUBMITTED` `Job` object on the connection.
2. Before the confirmed handler executes, the runner schedules and starts the job and publishes `RUNNING`.
3. The confirmed delete handler runs with the same connection and trusts the stale cached job object, so its running-job guard does not fire and it deletes the live job object.
4. When the server-side job process exits, the completion loop cannot publish terminal status to the missing object and therefore does not remove `running_jobs[job_id]` or fire the scheduler release event.

## Safeguards and masking

The completion loop retries failed publication, which masks transient storage failures. A stale delete removes the underlying object, so retries continue to fail and the release point remains unreachable. The scheduler has no independent reconciliation that removes a slot for a deleted running job; it depends on the lifecycle events fired after successful completion cleanup.

## Novelty search

Within the allowed pinned-source evidence, I searched local git history and in-tree documentation/tests for this mechanism. Same-area changes exist, including historical running-delete handling and local history mentioning concurrent lifecycle accounting, but I did not find a prior report or test for the specific stale authorization snapshot deleting a job that became `RUNNING` between authorization and confirmed execution, followed by completion-loop retry and scheduler-slot retention. Upstream tracker/PR discussion lookup was not performed because the continuation instructions prohibit consulting newer upstream discussions or external answers.

## Reproduction plan

The reproduction will create two jobs in the real filesystem-backed job store, authorize deletion of the first while `SUBMITTED`, let the real runner and scheduler start it under `max_jobs=1`, execute the confirmed delete through `JobCommandModule.delete_job`, finish the server process, and show that:

- the job object is gone from the store;
- the completion loop records repeated failure while the job remains in `running_jobs`;
- the scheduler still holds the first job in `scheduled_jobs`;
- the second job remains `SUBMITTED` rather than being admitted.
