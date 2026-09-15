# Phase 3: client lifecycle and process ownership

Pinned source: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Category A distributed job protocol with explicit local thread/process boundaries. No code was changed or executed; statements below are source analysis, not controlled-fault confirmation, trace conformance or model counterexamples.

## Full-read inventory

Read completely with numbered source output:

- `nvflare/private/fed/client/client_engine.py` (527 lines)
- `nvflare/private/fed/client/client_executor.py` (696)
- `nvflare/app_common/job_launcher/process_launcher.py` (101)
- `nvflare/app_common/job_launcher/client_process_launcher.py` (21)
- `nvflare/utils/process_utils.py` (352)
- `nvflare/private/fed/client/scheduler_cmds.py` (184)
- `nvflare/private/fed/client/admin.py` (191)
- `nvflare/private/event.py` (29)
- `nvflare/apis/utils/event.py` (84)
- `nvflare/app_common/resource_managers/auto_clean_resource_manager.py` (176)
- `nvflare/app_common/resource_managers/list_resource_manager.py` (82)
- `nvflare/app_common/resource_consumers/list_resource_consumer.py` (52)
- `tests/unit_test/private/fed/client/client_executor_test.py` (725)
- `tests/unit_test/private/fed/client/scheduler_cmds_test.py` (48)
- `tests/unit_test/utils/process_utils_test.py` (344)

Targeted adjacent reads (not claimed full): `fed_utils.py:547-564,618-641`; `fed_client_base.py:396-449`; `communicator.py:581-649`; `client_app_runner.py:49-89,166-233`; `training_cmds.py:202-213`; `server_engine.py:1068-1083`; `job_runner.py:270-389`; `cellnet/core_cell.py:1326-1363,1806-1851,1940-2029,2041-2250`; `cellnet/cell.py:448-510,660-684`; `sfm/conn_manager.py:340-398` and pool setup. Developer-signal search (`TODO/FIXME/HACK/XXX/BUG/WARN`) found no literal marker in the five initially assigned core files. Historical issue/PR review is separately in `issues-b.md`.

## Ownership and atomicity map

1. **Reservation transfer:** `StartJobProcessor` calls allocation before resource consumption and engine startup (`scheduler_cmds.py:114-128`). `AutoCleanResourceManager.allocate_resources` removes the reservation under its lock (`auto_clean_resource_manager.py:153-164`). An expired/cancelled token raises; no fallback steals an unreserved unit. Successful transfer removes the TTL entry, so subsequent TTL/cancel cannot free this allocation.
2. **Process binding:** `ListResourceConsumer` writes process-global `CUDA_VISIBLE_DEVICES` (`list_resource_consumer.py:31-37`). The launcher later copies `os.environ` (`process_launcher.py:66-81`). No lock spans consumption and the environment snapshot.
3. **Pending launch ownership:** `JobExecutor` installs a per-job pending handle under `self.lock` before calling the launcher (`client_executor.py:299-309`); launch failure removes only that same pending handle (`:312-316`). A second registration for the same job raises instead of replacing an existing owner (`:301-302`). Abort before handle attachment is saved and replayed (`:52-91,318-320`).
4. **OS process creation:** default launcher spawns a new session (`process_utils.py:333-352`), wraps it in a handle, and returns it (`process_launcher.py:80-83`). A process has been created before AFTER_JOB_LAUNCH and before waiter-thread start (`client_executor.py:322-334`).
5. **Status is separate from physical liveness:** status notifications only update the job dictionary (`client_executor.py:347-350`). The child sends STARTED before running and STOPPED after the runner returns (`client_app_runner.py:71-89`). STOPPED does not remove the registered handle or free resources. `ClientEngine.abort_app` explicitly retains STOPPED registered jobs for bounded cleanup (`client_engine.py:390-404`).
6. **Termination:** STARTING can terminate its pending/attached handle immediately; STARTED gets a fire-and-forget abort command and bounded wait; STOPPED gets bounded grace (`client_executor.py:486-545,581-601`). Actual kill sends a process-group signal; it does not wait or free resources (`process_utils.py:226-232,293-316`).
7. **Normal cleanup owner:** one child waiter calls `job_handle.wait()` before return-code/report/free (`client_executor.py:622-688`). Resource free precedes registry removal, then JOB_COMPLETED. `free_resources` trusts its caller and does not validate token/idempotence (`auto_clean_resource_manager.py:166-172`); ListResourceManager appends supplied IDs back to its deque (`list_resource_manager.py:52-55`). Therefore the protocol, not the resource manager, must ensure exactly one release owner.
8. **Reporting:** report exceptions are caught before release (`client_executor.py:648-674`); `send_request_before_shutdown` serializes against session closure (`fed_client_base.py:423-443`). A delayed report can delay resource availability but ordinarily has a configured request timeout; a missing acknowledgment does not itself leak the allocation.

## Verified candidate mechanisms

### C1: job-local allocation is bound through shared parent environment

**Classification:** high-priority model-checkable ownership/interleaving question with verified source mechanism; no executed reproduction.

`ListResourceManager` can legitimately allocate different IDs to A and B under its lock. `StartJobProcessor` then calls the same `ListResourceConsumer`, whose GPU consumer writes parent `os.environ` (`scheduler_cmds.py:119-121`; `list_resource_consumer.py:31-37`). Client startup performs metadata I/O and launcher selection before `ProcessJobLauncher.launch_job` takes an environment snapshot (`client_executor.py:221-252,299-309`; `process_launcher.py:68`). The allocation dict is passed to the waiter for eventual release, but it is not used to derive a fresh per-job child environment.

Two supported starts can overlap: a first site's START_JOB callback can remain in progress after the server's 20-second wait returns (`server_engine.py:1082`), while non-strict mode accepts missing replies without treating them as hard errors (`job_runner.py:313-353`). Production FedAdminAgent calls processors without a global start lock (`admin.py:164-165`); F3 delivers frames through a 100-worker frame pool (`conn_manager.py:43,91,374,396`), and Cell registers the normal callback in core transport (`cell.py:678-684`). This is not a Simulator-only concurrency assumption.

**Concrete permitted sequence for model design:** site-2 has free resource IDs 0 and 1, scheduler permits two jobs, A also has an acknowledged required site-1 satisfying min_sites=1. A on site-2 allocates 0, consumes it into the parent environment, then is delayed before the launcher's environment snapshot. A's site-2 reply times out, while A runs at site-1; the scheduling loop can admit B at site-2 using remaining ID 1. B consumes 1 into the same environment. Both children then snapshot/use visibility 1 even though A's ledger says it owns 0. Root independently checked this server-side participant/scheduler path during cross-review.

**Compensations checked:** resource lock protects deque ownership but ends before consume/launch; TTL is absent after transfer; pending-handle lock covers only same-job registration and does not cover environment access. Child environment is copied, but the copy happens after the competing write. No malicious participant, duplicate START, GPU computation or alternate launcher is required.

**Observable consequence:** mismatch between allocated ID and child process visibility, potentially simultaneous use of one ID while another allocated ID is idle. This is resource binding, not physical GPU memory measurement. Actual training consequences remain untested.

**Model proposal:** separate `Allocate`, `ConsumeToParentEnvironment`, `SnapshotChildEnvironment`, `Launch`, and `FreeAfterExit`; maintain both ledger allocation and process binding, and require each active child's binding to belong to its allocated units. Include server timeout followed by B scheduling to establish reachability rather than injecting arbitrary concurrent starts. Later local regression can inspect inherited environment without executing GPU workloads.

### C2: failure to start cleanup waiter after successful process launch

**Classification:** code-review/controlled-fault testing candidate first; small optional ownership scenario, not a confirmed production incident.

After local process creation (`client_executor.py:309`; `process_launcher.py:80-83`), the executor attaches the real handle and only later starts its cleanup thread (`client_executor.py:318-334`). A normal Python runtime failure starting that thread propagates to `StartJobProcessor`, whose broad exception handler frees any allocation (`scheduler_cmds.py:129-133`). No rollback terminates/waits the already launched child, and no waiter owns eventual registry removal. Therefore a still-running child can retain its assigned ID while the ID is returned to the pool and allocated to a later job. Heartbeat abort may later kill the child, but that does not repair the unsafe interval or create the missing waiter.

**Important evidence boundary:** ordinary AFTER_JOB_LAUNCH component exceptions are swallowed and recorded by real event dispatch (`apis/utils/event.py:54-82`). A fake `engine.fire_event` throwing directly is not a faithful trigger. The specific ordinary failure point is `thread.start()` (e.g. inability to create a thread after spawn), or another independently established runtime failure after launch. Do not count an arbitrary launcher that spawns then raises as the selected default backend's behavior.

**Model/test obligation:** cleanup ownership must transfer atomically enough that a post-launch startup failure cannot invoke pre-launch resource rollback while an OS child is live. A future controlled local test should fail only waiter startup while preserving the real dispatcher, handle registry, actual local process and ListResourceManager. No such test was run here; no occurrence rate is claimed.

### C3: engine returned errors bypass start-processor allocation rollback

**Classification:** code-review-only candidate with unresolved supported reachability; do not promote to a model hunt without closing that boundary.

`ClientEngine.start_app` returns strings for an already STARTED job and a missing deployed app directory (`client_engine.py:357-367`). The caller has already consumed the reservation (`scheduler_cmds.py:116-128`), and it only frees resources for raised exceptions (`:129-133`). A returned failure therefore leaves that allocation without a new waiter owner. TTL cannot reclaim a successfully transferred allocation.

**Boundaries:** the user excludes workspace contents, so externally deleting the app directory is not an acceptable primary modeled trigger. A duplicated START with the same token fails during allocation and never reaches this return, so it is not this bug. A different valid token for an already-running same job would require a supported second scheduling attempt, not a forged command. Root should retain the local return/exception inconsistency in code-review-only findings, but the current audit has not established a supported full-chain path satisfying those preconditions.

### C4: startup status-notification retry deadline is not an exit condition

**Classification:** low-priority code-review-only discrepancy; ordinary retry/liveness context, not allocation-leak confirmation.

`ClientAppRunner.notify_job_status` documents `retry_timeout` as maximum retry duration (`client_app_runner.py:171-185`), but once duration exceeds it, `:217-222` only logs and continues the unbounded `while True`. STARTED notification is invoked before `client_runner.run` (`:71-80`). Thus the configured retry deadline does not bound startup. A future check must distinguish finite delay/timeout (eventual good reply permits progress), sustained unavailable parent communication (no unconditional success required), and independent server/heartbeat cleanup. This does not warrant claiming a permanent leak under one lost reply.

## Exclusions and checked compensations

- **Reservation expiry releasing an active allocation:** excluded in AutoCleanResourceManager: allocate removes the TTL entry under the same lock; cancellation/expiry only pop reserved entries. Missing/stale token fails rather than silently reserving different free capacity (`:140-164`).
- **Abort before launcher handle return is lost:** excluded for the pin's pending-handle mechanism (`client_executor.py:52-91,299-320`), with explicit tests `client_executor_test.py:184-321`. This is fixed behavior/reference, not a hunt target.
- **STOPPED causes immediate premature resource release:** excluded; the registered handle remains, abort gives bounded cleanup grace, and release follows wait (`client_engine.py:390-404`; `client_executor.py:513-520,622-681`). Existing tests at `client_executor_test.py:71-145` cover retained STOPPED handle decisions; they use mock handles, not actual reservation/process integration.
- **Stop command sent means process exited:** explicitly rejected. `fire_and_forget` and a successful kill call are separate from `wait`; progress assumptions must require eventual effective exit. Kill permission errors are logged (`process_utils.py:315-316`) and do not themselves free resources while the waiter blocks. Do not promise cleanup despite permanently ineffective termination.
- **Any failed terminal report leaks resources:** excluded. Errors/non-OK/None are handled and release continues (`client_executor.py:665-679`); tests `:671-725` cover registry/event behavior but pass `allocated_resource=None`, so they do not validate real capacity restoration.
- **Return-code file parse or remove error aborts all cleanup:** excluded for the checked helper (`fed_utils.py:552-561` catches these). The linked #1985 review explicitly requested and obtained that compensation.
- **Repeated abort directly double-frees:** excluded in the normal path: abort never calls `free_resources`; a single waiter owns the release. Non-idempotent manager free is a protocol obligation, not a proven duplicate call by itself.
- **Job IDs are ignored:** excluded: dictionary status updates, waiters, outbound commands and notifications carry job IDs (`client_executor.py:347-353,622-687`; `training_cmds.py:210-213`). No claim of wrong-job corruption without a supported old/new attempt mapping. Same-job delayed status regression remains an optional source-review question, not proven cross-job corruption.
- **Concurrent `wait`/`poll` necessarily corrupts PID adapter return code:** not promoted. Adapter lacks an explicit lock, but selected executor's normal `poll` occurs after its sole waiter returns, and terminate does not poll. A concurrent caller must be established before modeling that race.
- **Any child cannot terminate because wait has no timeout:** not promoted. Wait intentionally follows actual process lifetime; MPM and server/heartbeat abort provide termination mechanisms. Historical #1985 review confirms this intent. Unbounded application execution is not a proof that resource cleanup is missing.

## Verification coverage and handoff

No tests, process experiments, TLC or trace validation were run in this subtask. Full existing client tests were read. They exercise pending ownership, duplicate registration, abort routing, status-to-exit mapping and report failure handling, largely through mocked launchers/handles/engines; cleanup tests mostly use no allocated resources. `scheduler_cmds_test.py` tests resource-check exception reporting only. ProcessAdapter tests mock OS operations. None establishes the production ListResourceManager -> consumer -> local launch -> actual exit -> free chain under overlapping jobs.

Recommended priority: C1 is the strongest independently source-grounded interleaving scenario; C2 is a focused functional fault/regression candidate; C3 and C4 belong in code-review-only handoff with explicit reachability/progress limitations. Preserve Category A message/timeouts and the default ListResourceManager/ListResourceConsumer/local process binding instead of substituting simplified simulator scheduling.
