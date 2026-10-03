# MC-13 Investigation

## Candidate

MC-13 reports that a submitted job with `min_clients` encoded as the numeric string `"1"` is accepted by validation but persisted unchanged. When this job is later constructed from persisted metadata, `Job.min_sites` remains a string. `DefaultJobScheduler` compares integers to that string, raises `TypeError`, abandons the whole candidate list, and does not update retry history. A later valid `SUBMITTED` job can therefore remain unconsidered on repeated scans.

## Source Evidence

- `nvflare/private/fed/server/job_cmds.py:1586-1665` is the normal admin submission path. It calls `JobMetaValidator.validate(...)` and, when valid, passes the returned `meta` directly to `job_def_manager.create(...)`.
- `nvflare/private/fed/server/job_meta_validator.py:237-249` validates `min_clients` by assigning `min_clients = self._convert_value_to_int(value)` and checking the converted local value. It does not write the converted integer back to `meta`.
- `nvflare/apis/impl/job_def_manager.py:308-328` persists the accepted metadata while adding job id, submit time, and `SUBMITTED` status; it does not normalize `min_clients`.
- `nvflare/apis/impl/job_def_manager.py:512-515` returns `SUBMITTED` jobs for scheduling, and `_ScheduleJobFilter.filter_job` at `nvflare/apis/impl/job_def_manager.py:113-117` reconstructs them with `job_from_meta`.
- `nvflare/apis/job_def.py:227-243` constructs `Job(..., min_sites=meta.get(JobMetaKey.MIN_CLIENTS, 1), ...)`, preserving a string value from persisted metadata.
- `nvflare/app_common/job_schedulers/job_scheduler.py:166` compares `len(applicable_sites) < job.min_sites`, and `nvflare/app_common/job_schedulers/job_scheduler.py:229` compares `num_sites_ok < job.min_sites`; both are invalid when `job.min_sites` is a string.
- `nvflare/app_common/job_schedulers/job_scheduler.py:287-311` catches all exceptions from `_do_schedule_job` and returns `(None, None)`.
- `nvflare/app_common/job_schedulers/job_scheduler.py:364-369` calls `_try_job` before `_update_schedule_history`; therefore this `TypeError` occurs before the malformed job's `schedule_count`, `last_schedule_time`, or history are refreshed.
- `nvflare/private/fed/server/job_runner.py:650-670` is the real scheduling consumer. It calls `scheduler.schedule_job(...)` and only deploys or marks a job `DISPATCHED` when `ready_job` is returned.

## Developer Intent

`nvflare/apis/job_def.py:85-93` documents `MIN_CLIENTS` as a dedicated validated constructor field rather than arbitrary user metadata. The validator's `_convert_value_to_int` also shows intent to accept numeric forms only after conversion. The scheduler logic and `Job.__init__` type annotation at `nvflare/apis/job_def.py:144` expect `min_sites` to be an integer.

## Novelty Check

Prior-report search was performed before marking the finding new:

- Local git history: `git log --all --oneline --grep=min_clients -i`, `git log --all -S'min_clients' -- ...`, `git log --all -S'_convert_value_to_int' -- ...`, and `git log --all -S'len(applicable_sites) < job.min_sites' -- ...`.
- Upstream issue/PR search via GitHub issue search for exact mechanism terms: `"min_clients" "job_meta_validator"`, `"min_clients" "schedule_job"`, `"job_from_meta" "MIN_CLIENTS"`, `"len(applicable_sites) < job.min_sites"`, `"job.min_sites" "min_clients"`, and the Python int/string `TypeError`.

The searches found related `min_clients` work and unrelated scheduler PR hits, but no issue or PR for this mechanism: accepted numeric-string job metadata preserved into `Job.min_sites`, causing scheduler `TypeError` and starvation of later eligible `SUBMITTED` jobs.

## Reproduction

Reproduction test written and executed:

`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-13_min_clients_starvation.py`

Command:

```bash
timeout 5m env PYTHONPATH=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-13/worktree python /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-13_min_clients_starvation.py
```

Result:

```text
MC-13 reproduction: numeric-string min_clients can starve a later eligible job
source_root=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-13/worktree
validator accepted numeric-string min_clients: type=str value='1'
job_def_manager/job_from_meta preserved min_sites: type=str value='1'
submitted_jobs_from_manager=['bad-oldest', 'good-later']
attempt=1 ready_job=None dispatch_info=None exceptions=1 exception_type=TypeError resource_checks=[] store_meta_updates=[] bad_schedule_count=0 good_schedule_count=0 good_status='SUBMITTED'
attempt=2 ready_job=None dispatch_info=None exceptions=2 exception_type=TypeError resource_checks=[] store_meta_updates=[] bad_schedule_count=0 good_schedule_count=0 good_status='SUBMITTED'
control_int_min_clients: ready_job='int-oldest' dispatch_sites=['server', 'site-1'] exceptions=0 resource_checks=[('int-oldest', ['site-1'])] schedule_count=1 store_meta_updates=[]
control_later_job_without_bad_oldest: ready_job='good-later-alone' dispatch_sites=['server', 'site-1'] exceptions=0 resource_checks=[('good-later-alone', ['site-1'])] schedule_count=1
BUG_REPRODUCED: older accepted string min_clients job aborts each scheduler scan before later eligible job
```

## Verdict Basis

The trigger uses normal accepted job metadata produced by `JobMetaValidator.validate` from a valid uploaded job archive and persisted through `SimpleJobDefManager.create`/`get_jobs_to_schedule`; no source patch, direct private `_try_job` call, or unreachable state injection is used. The scheduler consumer observed the wrong outcome through `DefaultJobScheduler.schedule_job`: it returns no ready job even though the later job is eligible and schedules successfully when the malformed older job is absent. The runner at `nvflare/private/fed/server/job_runner.py:656-670` would therefore skip deployment and leave the later job `SUBMITTED`. The condition is not self-resolved by scheduler history/backoff because the exception occurs before `_update_schedule_history`, as shown by both attempts retaining `schedule_count=0` and no store metadata updates.
