# NVFlare

## Scope

Specula analyzed and tested NVFlare's training coordination, model-data delivery, and job/resource lifecycle, including contribution acceptance, aggregation, transfer completion, receiver coordination, job startup and cancellation, resource ownership, and cleanup across sites.

## Bugs

Specula found 10 new bugs and reproduced 1 previously discussed bug:

- **Fixed:** A lazy tensor materialization failure can leave partial aggregation from a rejected contribution in the global model; see [PR #5295](https://github.com/NVIDIA/NVFlare/pull/5295).
- **Known:** A duplicate result arriving after completed-task cache eviction remains retained in controller context until context replacement, even though it is not aggregated again; the unknown-task cleanup gap was previously discussed in [PR #4520](https://github.com/NVIDIA/NVFlare/pull/4520#issuecomment-4383038805).
- **Fixed:** An executor submission failure after enqueueing can cause inline fallback and a later worker to repeat settlement callbacks and source-release attempts; see [PR #5296](https://github.com/NVIDIA/NVFlare/pull/5296).
- Pipelined EOF can publish completed source progress after receiver cancellation, while receiver status and the final transfer outcome remain failed.
- **Fixed:** Multi-target stream sends omit the expected receiver count, allowing the first receiver's completion to retire the source before later targets download it; see [PR #5297](https://github.com/NVIDIA/NVFlare/pull/5297).
- **Diagnostics:** The receiver-idle warning incorrectly says the budget cannot fire, even though another receiver can refresh transaction activity while a stalled receiver reaches its idle limit.
- Startup rollback after cleanup-waiter installation fails can reassign a GPU while the original child process is still alive.
- A stale deployment status write can overwrite an acknowledged pre-run abort and allow the job to enter startup.
- A delayed startup status write can replace a completed job's terminal status with RUNNING, causing the job-monitoring API to time out.
- Overlapping job starts can overwrite the shared parent environment, causing a child to inherit a GPU binding different from its recorded allocation.
- Status-storage failures during startup and its failure handler can skip scheduler cleanup, leaving stale job accounting that blocks later eligible jobs.
