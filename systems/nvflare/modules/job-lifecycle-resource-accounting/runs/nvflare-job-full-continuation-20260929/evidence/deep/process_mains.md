STATUS: IN PROGRESS

# Phase 3 deep analysis: job process mains, exit codes, status reports

Scope: SJ (server job process, runner_process.py) and CJ (client job process, worker_process.py) mains;
how their exit codes / rc files / UPDATE_RUN_STATUS feed ServerEngine.wait_for_complete,
fed_server UPDATE_RUN_STATUS, JobRunner._classify_finished_job_status,
JobExecutor._wait_child_process_finish, fed_server.process_job_failure.

Pinned source: /home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/full/source @ 53ba7ee5
Scratch scripts: evidence/deep/process_mains/

(Sections appended incrementally below.)

## 1. Mechanics recap (verified by reading pinned source)

### 1.1 Process mains and the MPM return-code funnel
- SJ main: `nvflare/private/fed/app/server/runner_process.py:195-203` -> `rc = mpm.run(main_func=main, run_dir=<ws>/<job_id>)`; `sys.exit(rc)`.
- CJ main: `nvflare/private/fed/app/client/worker_process.py:212-221` -> same funnel.
- `MainProcessMonitor.run` (`nvflare/fuel/f3/mpm.py:131-201`):
  - removes a pre-existing rc file first (`:150-151`);
  - maps `ConfigError`->103, `ComponentNotAuthorized`->102, other `Exception`->101 (`:154-164`); a normal return gives `rc=None` (both mains return None);
  - `BaseException` that is not `Exception` (e.g. `SystemExit` from `security_init_for_job` `fed_utils.py:275`, `worker_process.py:70`) is NOT caught: no rc file, no MPM shutdown, interpreter exit code from SystemExit;
  - rc file `_process_rc.txt` is written ONLY if non-daemon threads are still alive after cleanup (`:180-199`), using O_EXCL (a component-written file wins), then `os._exit(rc_to_write)`; otherwise `return rc` -> `sys.exit(rc)` and NO rc file is written.
- Only other rc-file writer on the local path: `ExternalProcessBackend._write_process_exit_code` (`app_common/executors/client_api/external_process_backend.py:1260-1271`, writes 101 into `workspace.get_run_dir(job_id)`), comment: "Preserve a reportable code across launchers that normalize nonzero child exits".
- rc-file location: `<workspace>/<job_id>/_process_rc.txt` for writer (mpm `run_dir`) and reader (`get_return_code`, `fed_utils.py:547-564`); `Workspace.get_run_dir` = realpath(root)/job_id (`WORKSPACE_PREFIX=""`, `workspace.py:232-234`). Per-job-run directory: CONFIRMED.

### 1.2 Launcher normalisation (default local launcher)
- `ProcessHandle.poll` (`app_common/job_launcher/process_launcher.py:29,51-55`): `{0:SUCCESS(0), 1:EXECUTION_ERROR(1), 9:ABORTED(9)}`, EVERYTHING else -> `EXECUTION_ERROR(1)`; `None` -> `UNKNOWN(127)`.
  So 101/102/103/104, 2, 255 and every signal death (-9, -15, ...) become 1 (U5 covers signals).
- `get_return_code` (`fed_utils.py:547-564`): rc file (if present and parseable) overrides the launcher code, except launcher code 104. A parse failure keeps the (bad) file (os.remove is inside the try).

### 1.3 Server consumers
- `ServerEngine.wait_for_complete` (`server_engine.py:203-234`): `process.wait()`; if run_processes entry still present: poll PROCESS_FINISHED up to 2 s, then under `engine.lock` read rc; nonzero rc recorded into `exception_run_processes` unless an entry already exists; pop run_processes.
- `UPDATE_RUN_STATUS` handler (`fed_server.py:594-604`): under FederatedServer.lock (NOT engine.lock), only if run_processes entry exists: `execution_error` -> PROCESS_EXE_ERROR + exception_run_processes; always PROCESS_FINISHED=True.
- SJ sends it from `ServerAppRunner.start_server_app` finally (`server_app_runner.py:89-90`) via `ServerEngine.update_job_run_status` = `cell.fire_and_forget` (`server_engine.py:873-884`); `execution_error` = sticky FATAL_SYSTEM_ERROR of the run manager context.
- `_classify_finished_job_status` (`job_runner.py:543-572`) and `run_aborted` precedence (`job_runner.py:485-489`).

### 1.4 Client consumer
- `JobExecutor._wait_child_process_finish` (`client_executor.py:622-688`): `wait()` on the CJ leader pid only; rc via `get_return_code`; if rc==1 and no abort requested: STARTING->104, STARTED->101, STOPPED->1; report CODE to server (REPORT_JOB_FAILURE, 5 s, optional); THEN `free_resources`; pop run_processes; fire JOB_COMPLETED.
- `process_job_failure` (`fed_server.py:906-957`): 103->fail_run(101); 101/104/9->fail_run(code); 102->stop_run (ABORTED); anything else (0, 1, 127) -> no action, outcome resolved.

## 2. Experiments (all product code unmodified; scratch under evidence/deep/process_mains/)

### E1/E2 - exit status -> rc file -> launcher normalisation -> get_return_code (SJ view)
Script: `process_mains/e1_exit_code_chain.py` + `process_mains/child_mpm.py` (child runs `mpm.run` exactly like the mains; parent uses `spawn_process` + `ProcessHandle` + `get_return_code`). Output: `process_mains/e1_output.txt`.
```
mode     linger raw_exit rc_file  poll() get_rc  SJ terminal status
ok       False  0        None     0      0       FINISHED:COMPLETED
ok       True   0        0        0      0       FINISHED:COMPLETED
exc      False  101      None     1      1       FINISHED:EXECUTION_EXCEPTION
exc      True   101      101      1      101     FINISHED:EXECUTION_EXCEPTION
config   False  103      None     1      1       FINISHED:EXECUTION_EXCEPTION
config   True   103      103      1      103     FINISHED:EXECUTION_EXCEPTION
unsafe   False  102      None     1      1       FINISHED:EXECUTION_EXCEPTION
unsafe   True   102      102      1      102     FINISHED:EXECUTION_EXCEPTION
sysexit  False  1        None     1      1       FINISHED:EXECUTION_EXCEPTION
sysexit  True   1        None     1      1       FINISHED:EXECUTION_EXCEPTION   (SystemExit bypasses MPM: no rc file even with lingering thread)
sigkill  False  -9       None     1      1       FINISHED:EXECUTION_EXCEPTION   (U5: -9 never reaches the -9 branch)
```
Note: MPM always sleeps `shutdown_grace_time=3 s` because import-time cleanup callbacks are registered (`stream_shutdown`, `shutdown`), so a thread must outlive ~3 s + cleanup to trigger rc-file writing.

### E3/E4 - CJ path: `_wait_child_process_finish` remap -> reported code -> `process_job_failure` -> server status
Same script; the CP status column is `ClientStatus` (1=STARTING, 2=STARTED, 3=STOPPED); server side = real `FederatedServer.process_job_failure` + real `JobRunner.fail_run/stop_run` + `_classify_finished_job_status` on a fake engine.
```
mode     linger CP status raw   rc_file reported  server terminal status
exc      False  1         101   None    104       FINISHED:ABNORMAL
exc      False  2         101   None    101       FINISHED:EXECUTION_EXCEPTION
exc      False  3         101   None    1         FINISHED:COMPLETED
exc      True   1..3      101   101     101       FINISHED:EXECUTION_EXCEPTION
config   False  1         103   None    104       FINISHED:ABNORMAL
config   False  2         103   None    101       FINISHED:EXECUTION_EXCEPTION
config   False  3         103   None    1         FINISHED:COMPLETED
config   True   1..3      103   103     103       FINISHED:EXECUTION_EXCEPTION
unsafe   False  1         102   None    104       FINISHED:ABNORMAL
unsafe   False  2         102   None    101       FINISHED:EXECUTION_EXCEPTION
unsafe   False  3         102   None    1         FINISHED:COMPLETED
unsafe   True   1..3      102   102     102       FINISHED_ABORTED(run_aborted)
ok       *      *         0     *       0         FINISHED:COMPLETED
```

### E5 - REAL CJ main (`python -m nvflare.private.fed.app.client.worker_process`) on a POC-provisioned kit
Script: `process_mains/e5_real_cj_config_failure.py`; kit provisioned into `process_mains/poc_ws` with `nvflare.tool.poc.poc_commands.local_provision` (no HOME changes). Launch = `spawn_process(argv, env)` (posix_spawn + setsid, as `ProcessJobLauncher.launch_job`); CP-side = real `JobExecutor._wait_child_process_finish` with STATUS=STARTING (the CJ fails before it notifies STARTED); server side as in E4. Output: `process_mains/e5_output.txt`.
```
variant raw_exit rc_file reported reason                 -> server_terminal_status
unsafe  102      None    104      infrastructure error   -> FINISHED:ABNORMAL
   CJ log: ComponentNotAuthorized: ... Component 'my_custom_pkg.UnlistedExecutor' at config path 'executors.#1.executor' is not in allow_list
config  103      None    104      infrastructure error   -> FINISHED:ABNORMAL
   CJ log: ConfigError: Error processing '.../config_fed_client.json' in element '{"path": "...NPTrainer", "args": {"no_such_arg": 1}}' ...
```
The real CJ logs `MPM: Good Bye!` with no "still running thread" warning, i.e. no lingering non-daemon thread -> MPM takes the `return rc` path and never writes `_process_rc.txt`.

### E6 - SJ main-loop status lost update (forced interleaving harness)
Script: `process_mains/e6_sj_status_lost_update.py`; output `process_mains/e6_output.txt`. Runs the unmodified `FederatedServer.start_run` + `run_engine`; only the `threading` name seen by `fed_server` is replaced by a shim whose `Thread.start()` runs the target to completion (forces "engine thread finishes before the main thread's next statement"). `ServerRunner` is a fake whose `run()` takes 50 ms.
```
control (real threading)           start_run returned within 3s: True   engine_info.status after 3s: STOPPED
forced: engine finishes before (A) start_run returned within 3s: False  engine_info.status after 3s: STARTED  (released only via asked_to_stop)
```
