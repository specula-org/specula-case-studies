# CR-1 Investigation

Finding: Allocation identity crosses shared process environment.

Source checkout: `/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/confirmation/CR-1/worktree`

Revision: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

Note: the checkout already contained local Specula probe edits in lifecycle files. Code facts below cite the clean `HEAD` line numbers where relevant; the probe edits do not change the allocation/consume/snapshot logic.

## Step 1: Code Audit

- `nvflare/app_common/resource_consumers/list_resource_consumer.py:31-38`: `_GPUConsumer.consume()` converts an allocated list of GPU IDs to strings and writes `os.environ["CUDA_VISIBLE_DEVICES"] = ",".join(gpu_numbers)`. This is process-global state, not a job-local structure.
- `nvflare/private/fed/client/scheduler_cmds.py:114-128`: `StartJobProcessor.process()` calls `resource_manager.allocate_resources(...)`, then `resource_consumer.consume(allocated_resources)`, then `engine.start_app(...)`. There is no lock held across consume plus start.
- `nvflare/app_common/job_launcher/process_launcher.py:66-82`: `ProcessJobLauncher.launch_job()` copies `os.environ` into `new_env` before spawning the worker process. The child process therefore observes whatever `CUDA_VISIBLE_DEVICES` is in the parent at that snapshot.
- `nvflare/private/fed/client/client_engine.py:350-384` and `nvflare/private/fed/client/client_executor.py:199-341`: `ClientEngine.start_app()` delegates to `JobExecutor.start_app()`, which obtains the job launcher and calls `job_launcher.launch_job(...)`.
- `nvflare/app_common/resource_managers/list_resource_manager.py:69-76` and `nvflare/app_common/resource_managers/auto_clean_resource_manager.py:159-172`: `ListResourceManager` reserves concrete list entries and later allocates the exact reserved entries by token, so two jobs can hold distinct allocations such as `{"gpu": [0]}` and `{"gpu": [1]}`.
- `nvflare/private/fed/client/admin.py:78-83,100-177`: the client registers a `CLIENT_MAIN` request callback and dispatches `TrainingTopic.START_JOB` through `StartJobProcessor`.
- `nvflare/private/fed/server/server_engine.py:1078-1094`: `ServerEngine.start_client_job()` constructs `START_JOB` messages carrying the job ID, job meta, resource requirement, and reservation token, then waits up to 20 seconds for replies.
- `nvflare/private/fed/server/message_send.py:39-60,101-113` and `nvflare/fuel/f3/cellnet/core_cell.py:1480-1580`: admin request sending is blocking only until replies arrive or timeout; timeout replies are represented and late client work can still continue after the sender returns.
- `nvflare/private/fed/server/job_runner.py:291-371`: default `STRICT_START_JOB_REPLY_CHECK` is false. After start replies, `JobRunner` rebuilds active sites from actual replies, but does not cancel the timed-out client-side `START_JOB` work if the client later continues processing it.

Reachable trigger scenario:

1. A site uses `ListResourceManager` plus `ListResourceConsumer` and process launch.
2. Job A and Job B each require one GPU on the same client, while two GPUs are available.
3. Job A's `CHECK_RESOURCE` reserves GPU 0 and Job B's `CHECK_RESOURCE` reserves GPU 1, producing distinct tokens.
4. Job A's `START_JOB` reaches the client, allocates GPU 0, and `ListResourceConsumer` writes `CUDA_VISIBLE_DEVICES=0`.
5. Before Job A's `ProcessJobLauncher.launch_job()` copies `os.environ`, Job B's `START_JOB` reaches the same client process, allocates GPU 1, and writes `CUDA_VISIBLE_DEVICES=1`.
6. Job A resumes launching. Its child process snapshots `CUDA_VISIBLE_DEVICES=1` even though the resource manager allocated GPU 0 to Job A. Job B also launches with `CUDA_VISIBLE_DEVICES=1`.

Safeguards encountered:

- `AutoCleanResourceManager` protects reservation/allocated-resource data with a lock, but the lock is released before the resource consumer mutates `os.environ`, and the launcher snapshots the environment later.
- Resource reservation expiry only reclaims unallocated reservations. It does not make the process environment job-local after allocation.
- Child-exit cleanup frees the allocated resource recorded for the job; it does not detect or repair a child process that inherited another job's GPU env.
- Non-strict start-reply handling can exclude timed-out sites from server-side active metadata, but it does not stop a late client processor from mutating the client process environment and launching.

## Step 2: Developer-Knowledge Search

Local code/history:

- `git blame` on `list_resource_consumer.py:27-38`, `scheduler_cmds.py:114-128`, and `process_launcher.py:66-83` attributes the base logic to the pinned grafted commit; local probe lines are uncommitted instrumentation.
- The shallow local history only showed adjacent resource-admission commits (`#5143`, `#5148`, `#5149`) and no local commit message mentioning this environment-snapshot race.

Docs/comments:

- `docs/user_guide/core_concepts/job.rst:310-316` says the Resource Manager allocates GPU IDs and the Resource Consumer sets `CUDA_VISIBLE_DEVICES`; it states this ensures concurrent jobs use different GPU devices. This is evidence of intended per-job GPU isolation, not tolerance for shared-env crossover.
- `docs/design/job_launcher_and_job_handle.md:251-258` describes `ProcessJobLauncher` as copying `os.environ` before spawning.
- `docs/design/job_launcher_and_job_handle.md:506-514` lists process launcher GPU config as `GPUResourceManager` / `CUDA_VISIBLE_DEVICES`, with no start verification.
- `docs/programming_guide/resource_manager_and_consumer.rst:13-20` says NVFlare assumes a site can start a job if the Resource Manager says enough resources exist.

Issue/PR tracker search:

- `gh issue list --repo NVIDIA/NVFlare --state all --search 'CUDA_VISIBLE_DEVICES resource allocation environment' --limit 20`: no matches.
- `gh pr list --repo NVIDIA/NVFlare --state all --search 'CUDA_VISIBLE_DEVICES resource allocation environment' --limit 20`: no matches.
- `gh search issues 'CUDA_VISIBLE_DEVICES ListResourceConsumer' -R NVIDIA/NVFlare --include-prs --state open/closed --limit 20`: no matches.
- `gh search issues 'ProcessJobLauncher os.environ.copy' -R NVIDIA/NVFlare --include-prs --state open/closed --limit 20`: no matches.
- `gh search issues 'resource_consumer.consume allocate_resources START_JOB' -R NVIDIA/NVFlare --include-prs --state open/closed --limit 20`: no matches.
- `gh search issues 'CUDA_VISIBLE_DEVICES resource manager' -R NVIDIA/NVFlare --include-prs --state open/closed --limit 20`: no exact mechanism match.
- `gh search issues 'GPU resource consumer environment' -R NVIDIA/NVFlare --include-prs --state open/closed --limit 20`: no exact mechanism match.
- `gh search issues 'START_JOB CUDA_VISIBLE_DEVICES' -R NVIDIA/NVFlare --include-prs --state open/closed --limit 20`: no matches.
- Broader `gh pr list --repo NVIDIA/NVFlare --state merged/closed --search 'CUDA_VISIBLE_DEVICES' --limit 30` found adjacent PRs #99, #4563, #4595, #5050, etc.

Reviewed adjacent PRs:

- PR #5191 (`https://github.com/NVIDIA/NVFlare/pull/5191`) is open and concerns admission-exception cleanup, retry bookkeeping, cancellation acknowledgements, and reservation expiry. It does not report the process-global `CUDA_VISIBLE_DEVICES` crossover between distinct allocated jobs.
- PR #4563 (`https://github.com/NVIDIA/NVFlare/pull/4563`) and PR #4595 (`https://github.com/NVIDIA/NVFlare/pull/4595`) concern `GPUResourceManager` respecting inherited `CUDA_VISIBLE_DEVICES` at resource-manager initialization and host validation. They do not report a job-start race where `ListResourceConsumer`/`GPUResourceConsumer` mutates the shared parent env before `ProcessJobLauncher` snapshots it.
- PR #99 (`https://github.com/NVIDIA/NVFlare/pull/99`) yielded startup `CUDA_VISIBLE_DEVICES` settings to users by removing shell-script resets. It is not the same mechanism.
- PR #5050 (`https://github.com/NVIDIA/NVFlare/pull/5050`) is an example migration and reports a one-GPU SplitNN validation environment; it is not the same mechanism.

Tests:

- Existing `tests/unit_test/private/fed/client/scheduler_cmds_test.py:27-47` calls `CheckResourceProcessor.process()` directly at the same request-processor boundary used by the reproduction harness.
- Existing resource-manager tests cover distinct reservations/allocations, but no found test asserts that a child process inherits the specific allocation's GPU identity when two starts overlap.

## Step 3: Known-Status / Precedent

No public issue, PR, CVE, advisory, or prior dataset entry found in the allowed searches reports this exact defect: a per-job allocated GPU identity being overwritten through shared parent `CUDA_VISIBLE_DEVICES` before `ProcessJobLauncher` snapshots the environment. Adjacent public work addresses initial visible-GPU scoping or admission/cancellation cleanup, not this allocation-to-child-env mismatch.

Phase-1 pre-filter does not apply: this is code-review-sourced, but no exact already-reported duplicate was found.
