# CR-23 Investigation

## Step 1: Code audit

Source: Code Review. The relevant path is reachable through the default local-process job launch path.

Cited sites:
- `nvflare/fuel/f3/mpm.py:153-163`: `MainProcessMonitor.run()` catches `ConfigError`, `ComponentNotAuthorized`, and generic `Exception` and assigns typed process codes `103`, `102`, and `101`.
- `nvflare/fuel/f3/mpm.py:180-199`: `_process_rc.txt` is written only on the still-running non-daemon-thread force-exit path. If no non-daemon thread remains, `run()` returns the typed code to the script entry point without writing an rc file.
- `nvflare/private/fed/app/client/worker_process.py:219-221`: the normal client job process entry point calls `mpm.run(..., run_dir=<workspace>/<job_id>)` and then `sys.exit(rc)`.
- `nvflare/app_common/job_launcher/process_launcher.py:51-55`: the local `ProcessHandle.poll()` maps raw OS exit codes only for `0`, `1`, and `9`; any other raw code, including `101`, `102`, or `103`, becomes `JobReturnCode.EXECUTION_ERROR` (`1`).
- `nvflare/private/fed/utils/fed_utils.py:547-564`: `get_return_code()` reads `_process_rc.txt` if present and returns that typed integer; otherwise it falls back to `job_handle.poll()`. It only gives launcher-side `INFRASTRUCTURE_ERROR` precedence over an rc-file value.
- `nvflare/private/fed/client/client_executor.py:630-643`: `JobExecutor._wait_child_process_finish()` remaps generic `EXECUTION_ERROR` by client status: `STARTING -> INFRASTRUCTURE_ERROR`, `STARTED -> EXCEPTION`, `STOPPED -> EXECUTION_ERROR`, unless a parent abort was requested.
- `nvflare/private/fed/client/client_executor.py:647-664`: the client sends the resulting code and reason to the server as `REPORT_JOB_FAILURE`.
- `nvflare/private/fed/server/fed_server.py:942-955`: the server treats `CONFIG_ERROR`, `EXCEPTION`, `INFRASTRUCTURE_ERROR`, and `ABORTED` as `fail_run(...)`, but treats `UNSAFE_COMPONENT` as `stop_run(...)`.

Reachability:
- `JobExecutor.start_app()` creates the normal `run_processes[job_id]` entry as `STARTING`, attaches the launcher handle, and starts `_wait_child_process_finish()` (`nvflare/private/fed/client/client_executor.py:298-334`).
- The client job process normally reports `STARTED` before running app code (`nvflare/private/fed/client/client_app_runner.py:71-80`), and the parent applies this through `notify_job_status()` (`nvflare/private/fed/client/client_executor.py:347-350`).
- A `ComponentNotAuthorized` from normal component authorization raises through the job process as `ProcessExitCode.UNSAFE_COMPONENT` via `mpm.run()`. If no non-daemon thread remains, no `_process_rc.txt` is written and the parent only sees the raw process exit code through `ProcessHandle.poll()`.

Trigger scenario:
1. A local client job worker is launched with `ProcessJobLauncher`.
2. The worker reaches `STARTED`.
3. App execution raises `ComponentNotAuthorized`, so `MainProcessMonitor.run()` computes `UNSAFE_COMPONENT` (`102`).
4. No still-running non-daemon thread forces the rc-file path, so the entry point exits via `sys.exit(102)` without `_process_rc.txt`.
5. The local launcher maps raw `102` to generic `EXECUTION_ERROR` (`1`).
6. The parent, seeing status `STARTED`, remaps generic `1` to `EXCEPTION` (`101`) and reports that to the server.
7. The server calls `fail_run(job_id, 101, ...)`; if `102` had survived, the server would call `stop_run(job_id, ...)`.

Safeguards and masks:
- `_process_rc.txt` masks the problem when it exists: `get_return_code()` preserves `102`, and the server takes the `stop_run` path.
- The mask does not fire on the ordinary no-lingering-thread `sys.exit(rc)` path.
- The server has no downstream correction once it receives `101`; `process_job_failure()` calls `fail_run()` and then resolves the client outcome.

## Step 2: Developer-knowledge search

Existing tests show the intended server distinction:
- `tests/unit_test/private/fed/server/fed_server_test.py:778-815` asserts `ProcessExitCode.UNSAFE_COMPONENT` calls `job_runner.stop_run()` and not `fail_run()`.
- `tests/unit_test/private/fed/server/fed_server_test.py:818-868` asserts `CONFIG_ERROR`, `EXCEPTION`, `INFRASTRUCTURE_ERROR`, and `ABORTED` call `fail_run()`.
- `tests/unit_test/private/fed/client/client_executor_test.py:619-666` asserts the current generic `EXECUTION_ERROR` status remapping, including `STARTED -> EXCEPTION`.

Relevant local git history:
- `52c966d1` / PR `#5194` ("Report active client process exit failures") intentionally maps active generic client-worker exit code `1` to `EXCEPTION`, and explicitly lists `STARTED + EXECUTION_ERROR -> EXCEPTION`. It says canonical process failures are unchanged, but it does not address local raw `102` becoming generic `1` when `_process_rc.txt` is absent.
- `71fbcaae` / PR `#5047` ("Fix K8s child failure propagation") preserves deliberate NVFlare child exit codes for the selected K8s container and fixes RC-file loss for K8s. Its scope says it does not redesign separate client-side timing issues, and it does not change local `ProcessHandle.poll()`.
- `00589c73` / PR `#4986` and `196a3fdd` / PR `#5094` distinguish infrastructure failures, especially Slurm, and intentionally preserve launcher infrastructure codes over rc-file values.
- `510150ce` / PR `#4576` narrows generic `JobReturnCode.EXECUTION_ERROR` reporting because teardown noise could fail already-finished jobs.
- `3f125217` / PR `#4766` fixes the MPM rc-file content when the rc-file path is used, but not local raw typed exits without an rc file.

Issue/PR search performed:
- GitHub issue/PR search query `repo:NVIDIA/NVFlare "UNSAFE_COMPONENT" "_process_rc.txt"` returned 0 results.
- Query `repo:NVIDIA/NVFlare "UNSAFE_COMPONENT" "EXECUTION_ERROR"` returned related closed PRs `#5047`, `#4576`, `#4592`, `#4552`, and `#4582`, but these do not report the same local-process no-rc-file mechanism at `ProcessHandle.poll()`/`ClientExecutor._wait_child_process_finish()`.
- Queries `repo:NVIDIA/NVFlare "ProcessExitCode.UNSAFE_COMPONENT" "ProcessHandle"`, `repo:NVIDIA/NVFlare "typed process" "return code"`, and `repo:NVIDIA/NVFlare "ComponentNotAuthorized" "return code"` returned 0 results.

## Step 3: Known-status / precedent

Known-status outcome: NEW. Related PRs show developer intent and nearby repairs, but I found no existing issue, PR, CVE, advisory, or prior dataset entry reporting this exact mechanism: local raw `UNSAFE_COMPONENT`/typed `mpm.run()` exit without `_process_rc.txt` is normalized by `ProcessHandle.poll()` to generic `EXECUTION_ERROR`, then remapped by client status to a different server action.

The code-review pre-filter does not apply because the exact defect was not already reported.
