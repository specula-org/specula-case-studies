# MC-2 Investigation

## Scope and Handoff Material Inspected

- Finding: MC-2, model-checking source, invariant `RunnerAliveInv`, config `MC_seed_F2.cfg`.
- Handoff records inspected for MC-2 context: `handoff/conversations/README.md`, `index.json`, and targeted MC-2 / scan-delete references in `01-analysis.md`, `02-specification.md`, `03-harness.md`, `04-validation-and-hunting.md`, and `analysis-agent-a267668ab856685f8.md`.
- Prior conclusions were treated as evidence only. The source audit and reproduction below use the current confirmation worktree at commit `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

## Step 1: Code Audit

### Relevant Code

- `nvflare/apis/impl/job_def_manager.py:512-515`: `get_jobs_to_schedule` constructs `_ScheduleJobFilter`, then calls `_scan(..., skip_tag="scheduled")`.
- `nvflare/apis/impl/job_def_manager.py:517-527`: `_scan` calls `store.list_objects(self.uri_root, without_tag=skip_tag)`, then later loops over each URI and calls `store.get_meta(job_uri)`. There is no `try/except StorageException` around the per-listed-job metadata read.
- `nvflare/app_common/storages/filesystem_storage.py:277-308`: `FilesystemStorage.list_objects` snapshots object URIs found under the directory.
- `nvflare/app_common/storages/filesystem_storage.py:310-327`: `FilesystemStorage.get_meta` raises `StorageException("object ... does not exist")` when the listed object has disappeared.
- `nvflare/private/fed/server/job_runner.py:633-650`: `JobRunner.run` calls `job_manager.get_jobs_to_schedule(fl_ctx)` once per scheduler tick, before the deployment `try` that starts at line 666.
- `nvflare/private/fed/server/job_cmds.py:507-535`: public admin command handler `delete_job` deletes a job through `job_def_manager.delete` if the authorization-time job status is not DISPATCHED or RUNNING.
- `nvflare/apis/impl/job_def_manager.py:354-356`: `delete` removes the job object with `store.delete_object`.
- `nvflare/app_common/storages/filesystem_storage.py:415-432`: `delete_object` removes the filesystem object directory.

### Call Chain and Reachability

Normal scheduler path:

`JobRunner.run` -> `job_manager.get_jobs_to_schedule` -> `SimpleJobDefManager._scan` -> `FilesystemStorage.list_objects` -> `FilesystemStorage.get_meta`.

Normal delete path:

Flare API / admin `delete_job` command -> `JobCommandModule.delete_job` -> `SimpleJobDefManager.delete` -> `FilesystemStorage.delete_object`.

Reachability assessment:

- The runner loop is active during normal hot-server operation when any client is registered (`job_runner.py:641-650`).
- `delete_job` is a normal admin / Flare API operation. The handler refuses DISPATCHED/RUNNING jobs but permits deletion of SUBMITTED jobs (`job_cmds.py:516-521`).
- A SUBMITTED job can therefore be listed by `_scan` and deleted by a concurrent admin command before `_scan` reaches `get_meta`.
- The resulting `StorageException` is outside the runner's deployment `try/except`, so it escapes `JobRunner.run`. The runner is started once as a bare thread and there is no restart mechanism at this call site.

### Safeguards Checked

- `skip_tag="scheduled"` does not protect SUBMITTED jobs: `_ScheduleJobFilter` tags only non-SUBMITTED jobs (`job_def_manager.py:113-120`). The vulnerable listed object is a SUBMITTED job and is intentionally untagged.
- `JobCommandModule.delete_job` protects only DISPATCHED/RUNNING jobs, not SUBMITTED listed jobs (`job_cmds.py:516-521`).
- `SimpleJobDefManager.get_job` catches `StorageException` and returns `None` (`job_def_manager.py:379-385`), but `_scan` does not use that wrapper.
- `JobRunner.run` catches deployment/start exceptions only after a ready job has been chosen (`job_runner.py:666-731`). The scheduling scan at line 650 is not inside that handler.
- Existing storage tests assert the storage contract that `get_meta` on a non-existent object raises `StorageException` (`tests/unit_test/app_common/storages/storage_test.py:330-340`).

### Trigger Scenario

1. A server is hot, has at least one registered client, and the single `JobRunner.run` scheduler loop is active.
2. A SUBMITTED job exists in the job store.
3. The runner calls `get_jobs_to_schedule`; `_scan` lists the job object.
4. Before `_scan` calls `get_meta` for that listed job, an admin executes `delete_job <job_id>`. The delete is accepted because the job is still SUBMITTED.
5. `_scan` calls `get_meta` for the now-deleted job. `FilesystemStorage.get_meta` raises `StorageException`.
6. The exception escapes `JobRunner.run`, killing the scheduling thread.
7. A later SUBMITTED job remains eligible but is never passed to the scheduler because the only scheduling loop is gone.

## Step 2: Developer-Knowledge Search

### Local Git History / Merged PR Commit Messages

Searches run against pinned `HEAD` history only, not newer refs:

- `git log HEAD --grep='list_objects|get_jobs_to_schedule|scheduler thread|scan.*job|delete.*submitted|deleted.*job|job.*deleted|job runner|StorageException' -i -- ...`
- `git log HEAD --all-match --grep='delete' --grep='job' --grep='scan' --oneline -- ...`
- `git log HEAD --all-match --grep='StorageException' --grep='job' --oneline -- ...`
- `git log HEAD --merges --since='2026-08-01' --oneline -- ...`
- `git log HEAD -S 'get_jobs_to_schedule' --oneline -- ...`
- `git log HEAD -S 'TODO:: use try block around storage calls' -- ...`

Findings:

- `38fa2c75 Fix meta file processing in storage and improve schedule job retrieval (#2186)` introduced the optimized `get_jobs_to_schedule` / `scheduled` tag scan path and says "use mark file to reduce meta reading"; it does not mention deletion of a listed job or runner-thread death.
- The same commit removed an older generic comment `# TODO:: use try block around storage calls`, which is developer awareness of broad storage-call fragility but not an existing filed report for this exact mechanism.
- `def5c04c Delete job command enhance (#670)` added a guard not allowing running jobs to be deleted, but the current handler still permits deletion of SUBMITTED jobs. The message does not describe the list/read scan race.
- No pinned-history merge commit or local test found in the searched sites describes this exact defect: "delete listed SUBMITTED job between `list_objects` and `get_meta` kills `JobRunner.run` and prevents later scheduling."

### Comments / Tests / Docs

- Current code comments document the scan optimization: `_ScheduleJobFilter` skips future meta reads for non-SUBMITTED jobs by tagging them. This reinforces that SUBMITTED jobs remain scan/read candidates.
- Storage tests document/expect `get_meta` to raise on missing objects.
- No current test was found for deletion during `get_jobs_to_schedule` or for `JobRunner.run` surviving `StorageException` from the scan.

### Issue Tracker

External upstream issue / PR discussions and newer upstream refs were not consulted because the explicit continuation instructions forbid inspecting upstream issue/PR discussions, newer commits, or external answers. Within the permitted pinned git history and local tests, no same-mechanism prior report was found.

## Step 3: Known-Status / Precedent

Known-status assessment: no permitted evidence found that an existing public issue/PR/CVE/advisory or prior dataset entry already reports this exact mechanism at this site.

Novelty to report: `NEW`, with the caveat that the search was constrained to pinned local git history and local tests by the continuation rules.

## Phase 2 Reproduction Summary

Reproduction file:

`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-2_scan_delete_kills_runner.py`

Execution command:

`timeout 90s python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-2_scan_delete_kills_runner.py`

Escalation:

- Level 0: normal admin delete without timing help. The runner stayed alive and considered the later job. This was a control / unsuccessful trigger.
- Level 1: timing assistance only. The test pauses immediately before the real filesystem-backed `get_meta` for the listed job, then executes the normal `delete_job` command handler. The runner thread terminated with `StorageException`, and a later eligible job stayed SUBMITTED with zero scheduler calls after the runner death.

Captured output is saved at:

`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-2/repro-output.txt`
