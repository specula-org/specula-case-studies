# CR-20 Investigation

## Step 1: Code audit

Finding source is code review. No model-checking counterexample was supplied.

Relevant client code:

- `nvflare/private/fed/client/scheduler_cmds.py:96-137` handles `TrainingTopic.START_JOB`. It allocates a reserved resource token, calls the resource consumer, then calls `engine.start_app(...)`.
- `nvflare/private/fed/client/client_engine.py:349-382` checks the job status and deployed app path, then calls `self.client_executor.start_app(...)`.
- `nvflare/private/fed/client/client_executor.py:221-298` performs metadata checks, rewrites the job metadata file, fires `BEFORE_JOB_LAUNCH` through `get_job_launcher(...)`, prepares job process args, and only then creates the pending handle and registers `run_processes[job_id]` at `client_executor.py:299-307`.
- `nvflare/private/fed/utils/fed_utils.py:618-640` shows that `get_job_launcher(...)` creates a new context and fires `EventType.BEFORE_JOB_LAUNCH` before returning the launcher. Components in this event path can perform real work and can block.
- `nvflare/private/fed/client/training_cmds.py:37-49` handles `TrainingTopic.ABORT` by calling `engine.abort_app(job_id)` and returning an OK reply with the returned body.
- `nvflare/private/fed/client/client_engine.py:390-404` checks the executor status before calling `client_executor.abort_app`. For an unregistered job, `JobExecutor.get_status` returns `STOPPED` by default (`client_executor.py:690-692`), so `ClientEngine.abort_app` returns `"Client app already stopped."` at `client_engine.py:396-397` and does not record abort intent.
- Once the job is registered, `client_executor.py:299-320` installs `_PendingJobHandle`; `client_executor.py:486-545` records `_ABORT_REQUESTED_KEY` and terminates `STARTING`/`STARTED`/registered `STOPPED` jobs. `_PendingJobHandle` at `client_executor.py:52-91` preserves aborts that arrive after registration but before the real handle is attached.

Call chain for normal usage:

1. Server start path creates a START_JOB admin message in `nvflare/private/fed/server/server_engine.py:1068-1083`.
2. Client `StartJobProcessor.process` receives it and calls `engine.start_app` (`scheduler_cmds.py:122-128`).
3. Server abort of a running server-side job sends `TrainingTopic.ABORT` to clients in `nvflare/private/fed/server/job_runner.py:395-410`.
4. Client `AbortAppProcessor.process` receives the ABORT (`training_cmds.py:41-49`) and calls `ClientEngine.abort_app`.

Reachable trigger scenario:

1. A client receives `START_JOB`; resource allocation and consumption succeed.
2. The start path reaches `BEFORE_JOB_LAUNCH` in `get_job_launcher(...)`, before `JobExecutor.start_app` registers the pending STARTING handle.
3. An abort message for the same job arrives in another client request-handler thread.
4. Because `run_processes` has no job entry yet, `ClientEngine.abort_app` returns `"Client app already stopped."` and records no abort intent.
5. The START handler resumes, registers the pending handle, launches the job, and returns `"Start the client app..."`.
6. Since the dropped abort is not replayed, the client child process remains alive until a later independent cleanup mechanism aborts it.

Safeguards found:

- `_PendingJobHandle` preserves abort intent after `run_processes[job_id]` is registered and before the launcher returns a real handle (`client_executor.py:299-320`). This masks the older launch window but not the earlier `BEFORE_JOB_LAUNCH` window.
- Later heartbeat cleanup can terminate a client job that the server no longer thinks should be running (`nvflare/private/fed/client/communicator.py:622-646`, `client_engine.py:390-404`). This is a downstream reconciliation path, not an immediate honoring of the original client ABORT.
- `abort_task` has similar status guards (`client_engine.py:430-440`, `client_executor.py:603-620`), but this investigation focused on the job-level ABORT because it is the lifecycle command sent by `JobRunner.abort_client_run`.

## Step 2: Developer-knowledge search

Local git history on the affected files was searched:

- `git log --oneline --decorate --all -- nvflare/private/fed/client/client_engine.py nvflare/private/fed/client/client_executor.py tests/unit_test/private/fed/client/client_executor_test.py`
- `git log --all --format=... --grep='abort|launch|registration|client job' -- nvflare/private/fed/client/client_engine.py nvflare/private/fed/client/client_executor.py tests/unit_test/private/fed/client/client_executor_test.py`
- `git blame -L 390,404 nvflare/private/fed/client/client_engine.py`
- `git blame -L 299,320 nvflare/private/fed/client/client_executor.py`
- `git blame -L 486,545 nvflare/private/fed/client/client_executor.py`
- `rg -n "abort.*registration|registration.*abort|abort.*launch|launch.*abort|before registration|pending handle|Preserve abort requests|Client app has not started|Client app already stopped" . docs tests nvflare -g '*.{py,md,rst,txt}'`

Developer evidence:

- Commit `cb784550` / PR `#4904`, "Fix abort for registered STARTING jobs", says the old guards acknowledged abort requests without acting while a job was already registered in `STARTING`. This is adjacent but applies after a `run_processes` entry exists.
- Commit `a18489e4` / PR `#4910`, "Preserve abort requests during client job launch", says: "Previously, the job was not added to `run_processes` until after `launch_job()` returned, so an abort received during that window saw the app as stopped and was discarded. The job could then finish launching and continue despite the abort request." The fix registers `_PendingJobHandle` before `launch_job()`, but current code still fires `BEFORE_JOB_LAUNCH` before the pending handle registration.
- Current tests in `tests/unit_test/private/fed/client/client_executor_test.py:216-251` assert that abort intent is preserved while `launch_job` is running. No test was found for an abort that arrives before `JobExecutor.start_app` reaches `client_executor.py:299`.
- The handoff conversation records were searched for CR-20 and the client abort-window text. Relevant prior evidence identified the same boundary: "abort intent is preserved from client registration onward" and the pending handle makes launch visible as `STARTING`; that evidence does not cover the pre-registration `BEFORE_JOB_LAUNCH` window.

Issue tracker / PR discussion pages were not opened because the continuation instructions prohibit inspecting upstream issue/PR discussions. The local git history includes recently merged PR numbers, subjects, bodies, touched files, and tests. No local commit body or in-tree test found a report of this exact residual pre-registration event-hook window.

## Step 3: Known-status / precedent

Known related fixes exist:

- `cb784550` / `#4904`: registered `STARTING` abort guard.
- `a18489e4` / `#4910`: abort during blocking `launch_job()` before a real handle is available.

These are same-area precedents, but not an exact report of the current residual mechanism: the present trigger is before the `_PendingJobHandle` registration, during `get_job_launcher(...)->BEFORE_JOB_LAUNCH`, and the current tests only cover aborts after registration. Therefore this code-review finding proceeds to reproduction and is treated as new for this mechanism based on local git-history and in-tree searches.
