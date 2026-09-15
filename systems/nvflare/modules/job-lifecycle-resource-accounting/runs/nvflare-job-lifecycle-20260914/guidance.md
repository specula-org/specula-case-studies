# NVFlare Job Lifecycle and Resource Accounting

## Goal
Assess whether training jobs start, stop, and share site resources correctly when admission, startup, termination, and cleanup overlap or fail.

## Scope
- Follow job admission, resource reservation, deployment, allocation, process startup, completion/abort, and resource release across the server and participating sites.
- Focus on competing jobs using the default local process-launch path and a built-in resource manager with real reservation and allocation accounting. ListResourceManager is a suitable starting point.
- Follow adjacent callers, event handlers, and cleanup paths where they determine job status, resource ownership, or availability for another job.
- Exclude training-round aggregation, model-transfer internals, GPU computation, external-trainer lifecycle, alternative launcher backends, and HA/crash recovery. Workspace contents are outside scope; cleanup failures matter where they delay lifecycle completion.

## Priority Questions
1. When reservation expiry or cancellation overlaps a delayed start request, can a site allocate unavailable resources, assign the same resource to competing jobs, or return an allocated resource to the free pool?
   Expected contract: reservation, allocation, and release preserve resource ownership and available capacity; expiry of a reservation is distinct from cleanup of an active allocation.
2. When deployment or startup succeeds at some sites and fails at others, can resources or scheduling slots remain owned without a live job, or can startup be reported inconsistently?
   Expected contract: outcomes follow the configured participant policy, and every acquired resource has a cleanup owner. Follow both returned errors and raised exceptions.
3. When abort, normal completion, and child-process exit overlap, can cleanup release a resource more than once, release it while the job still uses it, or omit its release?
   Expected contract: cleanup follows actual process/resource ownership; a stop request or logical terminal status alone does not establish that resource use has ended.
4. When delayed replies or repeated lifecycle notifications arrive while another job is being admitted or completed, can they change the wrong job's status, reservation, or scheduling count?
   Expected contract: replies and events remain associated with the correct job and supported scheduling attempt; repeated notifications do not corrupt another job's accounting.
5. When one job fails admission or cleanup while another is eligible to run, can the first job unnecessarily block later scheduling or corrupt retry accounting?
   Expected contract: scheduling proceeds according to the configured concurrency limits, retry policy, and cleanup guarantees. Establish the conditions for progress rather than requiring success despite permanently unavailable sites.

## Must-cover Interactions
- DefaultJobScheduler and JobRunner with server resource-check, cancellation, deployment, and start requests.
- Client resource/start processors with ClientEngine, JobExecutor, resource consumption, and child-exit cleanup.
- Reservation expiry and cancellation with allocation/free operations; job lifecycle events with scheduler and runner bookkeeping.

## Assumptions and Evidence
- Participants are cooperative, jobs use supported APIs, and failures are ordinary runtime errors, timeouts, delayed replies, or process exits. Keep implementation checks local and focused on functional correctness.
- Use NVFlare revision 53ba7ee567468ea7971dad4faccef13c6cb35dc2 and record the selected resource manager and startup policy.
- Preserve reservation TTL cleanup. A missing cancellation acknowledgement does not by itself prove a permanent leak; expiry does not reclaim allocations already transferred to a running job.
- Establish min_sites, required_sites, and strict/non-strict start-reply semantics from the selected configuration; do not assume every targeted site must start.
- Preserve production event-dispatch and error-handling behavior. Existing simplified scheduler mocks or Simulator alone do not establish correctness of the production reservation/start/cleanup chain.
- Distinguish a command being sent, acknowledged, executed, and cleaned up. Connect suspected accounting errors to observable capacity, process ownership, job status, or subsequent scheduling.

## Known Incidents and References
- https://github.com/NVIDIA/NVFlare/pull/5191 discusses admission-exception cleanup, retry bookkeeping, and missing cancellation acknowledgements. Read the full discussion and verify its current status before classifying overlapping findings as new.
- https://github.com/NVIDIA/NVFlare/pull/5191#issuecomment-5432240101 explains the reservation-expiry backstop and the tradeoff between stopping a scheduling pass and logging cancellation failures. Treat proposed changes separately from the pinned implementation.

## Suggested Starting Points
- nvflare/app_common/job_schedulers/job_scheduler.py: DefaultJobScheduler._try_job, _do_schedule_job, handle_event
- nvflare/private/fed/server/job_runner.py: JobRunner.run, _deploy_job, _start_run, _stop_run, _job_complete_process
- nvflare/private/fed/server/server_engine.py: ServerEngine.check_client_resources, cancel_client_resources, start_client_job
- nvflare/private/fed/client/scheduler_cmds.py: CheckResourceProcessor, StartJobProcessor, CancelResourceProcessor
- nvflare/private/fed/client/client_engine.py: ClientEngine.start_app
- nvflare/private/fed/client/client_executor.py: JobExecutor.start_app, abort_app, _wait_child_process_finish
- nvflare/app_common/resource_managers/auto_clean_resource_manager.py: AutoCleanResourceManager
- nvflare/app_common/resource_managers/list_resource_manager.py: ListResourceManager
- tests/unit_test/app_common/job_schedulers/job_scheduler_test.py and tests/unit_test/app_common/resource_managers/list_resource_manager_test.py
- tests/unit_test/private/fed/server/job_runner_deploy_test.py, tests/unit_test/private/fed/client/scheduler_cmds_test.py, and tests/unit_test/private/fed/client/client_executor_test.py

## Coverage
Address every priority question without presuming a defect. Expected contracts are properties to investigate, not assumptions that exclude violations. Explore adjacent risks within this lifecycle boundary, and distinguish model counterexamples, trace conformance, controlled-fault evidence, known issues, and untested production consequences.
