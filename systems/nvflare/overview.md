# NVFlare

## Scope

Specula analyzed and tested NVFlare's training coordination, model-data delivery, and job/resource lifecycle, including contribution acceptance, aggregation, transfer completion, receiver coordination, job startup and cancellation, resource ownership, and cleanup across sites.

## Bugs

The September 13–14 studies recorded 11 findings classified as new at intake:

- **Fixed:** A lazy tensor materialization failure can leave partial aggregation from a rejected contribution in the global model; see [PR #5295](https://github.com/NVIDIA/NVFlare/pull/5295).
- A duplicate result arriving after completed-task cache eviction remains retained in controller context until context replacement, even though it is not aggregated again; related unknown-task cleanup behavior is discussed in [PR #4520](https://github.com/NVIDIA/NVFlare/pull/4520#issuecomment-4383038805).
- **Fixed:** An executor submission failure after enqueueing can cause inline fallback and a later worker to repeat settlement callbacks and source-release attempts; see [PR #5296](https://github.com/NVIDIA/NVFlare/pull/5296).
- Pipelined EOF can publish completed source progress after receiver cancellation, while receiver status and the final transfer outcome remain failed.
- **Fixed:** Multi-target stream sends omit the expected receiver count, allowing the first receiver's completion to retire the source before later targets download it; see [PR #5297](https://github.com/NVIDIA/NVFlare/pull/5297).
- **Diagnostics:** The receiver-idle warning incorrectly says the budget cannot fire, even though another receiver can refresh transaction activity while a stalled receiver reaches its idle limit.
- Startup rollback after cleanup-waiter installation fails can reassign a GPU while the original child process is still alive.
- **Reported:** A stale deployment status write can overwrite an acknowledged pre-run abort and allow the job to enter startup; [issue #5300](https://github.com/NVIDIA/NVFlare/issues/5300) has an open fix in [PR #5305](https://github.com/NVIDIA/NVFlare/pull/5305) as of 2026-10-03.
- **Confirmed, not planned:** A delayed startup status write can replace a completed job's terminal status with RUNNING, causing the job-monitoring API to time out. The maintainer accepted [issue #5301](https://github.com/NVIDIA/NVFlare/issues/5301) as valid P3 and deferred a fix because practical occurrence was not established.
- Overlapping job starts can overwrite the shared parent environment, causing a child to inherit a GPU binding different from its recorded allocation.
- Status-storage failures during startup and its failure handler can skip scheduler cleanup, leaving stale job accounting that blocks later eligible jobs.

## Later job lifecycle experiments

The [2026-09-25 Lite run](modules/job-lifecycle-resource-accounting/runs/nvflare-job-lite-20260925/README.md) and [full run with continuation](modules/job-lifecycle-resource-accounting/runs/nvflare-job-full-continuation-20260929/README.md) preserve seven and 39 source report entries respectively. The full report labels 38 as reproduced and one as a false positive. These counts overlap each other and the earlier findings. The [reconciliation ledger](modules/job-lifecycle-resource-accounting/runs/nvflare-job-full-continuation-20260929/review/findings.md) records duplicates, prior matches, evidence limitations, and candidates awaiting review; no combined new-bug count is assigned.
