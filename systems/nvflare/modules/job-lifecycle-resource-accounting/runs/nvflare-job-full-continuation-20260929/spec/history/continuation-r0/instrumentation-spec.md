# Instrumentation Spec: NVFlare job lifecycle and resource accounting

Maps every action of `base.tla` to the pinned source (53ba7ee5) so a harness can emit NDJSON traces that
`Trace.tla` replays. Paths are relative to the source root; short names are listed in the `base.tla` header.

Instrumentation must be **observation-only**: hooks read state and append a trace line. They must not change
control flow, locking or return values. The only permitted reproduction controls are timing controls that
choose *when* a concurrent operation runs. Examples: gating a thread at a hook, driving the expiry tick
explicitly, or injecting a stub reply or timeout at the RPC and process edge. These are the same
kinds of controls already used by `evidence/harness/*.py`.

## Section 1: Trace Event Schema

### 1.1 Lines

Every trace is one NDJSON file. It contains exactly one `config` line, followed by `trace` lines in
emission order.

```json
{"tag":"config","jobs":["j1","j2"],"clients":["c1","c2"],"units":["u0","u1"],"need":1,
 "deploy_sites":{"j1":["c1","c2"],"j2":["c1","c2"]},"min_sites":{"j1":1,"j2":1},
 "required":{"j1":[],"j2":[]},"max_jobs":1,"max_schedule_count":10,"expiry":3}

{"tag":"trace","seq":17,"event":{
   "name":"<SpecActionName>",
   "job":"j1" | "None",          // job parameter of the action (else "None")
   "cl":"c1"  | "None",          // client parameter of the action (else "None")
   "msg":{...} ,                 // only for message-consuming actions (Section 1.3)
   "arg":{...} ,                 // only for actions with extra parameters (Section 2)
   "state":{...}}}               // POST-action snapshot (Section 1.2), mandatory on every event
```

- **Job ids.** Real ids (UUIDs) are mapped to `j1, j2, ...` in submission order. The `jobs` list in
  `config` *is* `JobOrder`. All jobs must be submitted (SUBMITTED) before `JobRunner.run` is started, which
  matches `Init`.
- **Client names.** Site names are mapped to `c1, c2, ...`.
- **Units.** The harness uses `ListResourceManager({"gpu": [0, 1, ...]}, expiration_period=expiry)`, the
  same AutoClean base as the default `GPUResourceManager`. Resource spec is `{"gpu": need}`. Unit `i` maps
  to `"u<i>"`. With `need = 0` the default `GPUResourceManager(num_of_gpus=0)` may be used instead.
- **Tokens.** A reservation token (a per-client UUID) maps to the attempt id `att`. The attempt id is a
  harness counter, starting at 1, incremented at every `RunnerTryNext` event that sends CHECK_RESOURCE. It
  equals `nextAtt` before the step. The harness records `{(client, uuid) -> att}` from the CHECK replies.
- **Absent values** are the string `"None"`. Sets are JSON arrays. Records that may be absent carry
  `"present": true|false`.

### 1.2 State snapshot (`event.state`) → TLA+ variables

The snapshot is taken **after** the instrumented operation, while holding the harness trace lock (Section 3.1).

| Snapshot field | Implementation source | TLA+ variable |
|---|---|---|
| `tagged` | job ids whose store dir contains the `scheduled` tag file (`job_def_manager.py:113-120`) | `tagged` |
| `scheduled_jobs` | `DefaultJobScheduler.scheduled_jobs` | `slots` |
| `running_jobs` | `JobRunner.running_jobs.keys()` | `runningJobs` |
| `sessions` | names in `ClientManager.clients` | `sessions` |
| `jobs[j].status` | persisted meta `status` (`get_job(j).meta["status"]`), or `"DELETED"` when the object is gone | `status[j]` |
| `jobs[j].schedule_count` | persisted meta `schedule_count` (0 if absent) | `pCount[j]` |
| `jobs[j].run_aborted` | `running_jobs[j].run_aborted` if present, else the flag of the runner's current `ready_job` object if it is `j`, else `false` | `runAborted[j]` |
| `jobs[j].pending` | `{"present": j in _pending_client_outcomes, "set": [...]}` | `pending[j]` |
| `jobs[j].latched` | `_finished_job_states[j].status` or `"None"` | `latched[j]` |
| `jobs[j].run_process` | `engine.run_processes.get(j)`: `{present, finished: PROCESS_FINISHED, exe_error: PROCESS_EXE_ERROR, rc: PROCESS_RETURN_CODE or 0, parts: [participant names]}` | `rp[j]` |
| `jobs[j].exception_process` | `engine.exception_run_processes.get(j)`, same shape | `exc[j]` |
| `jobs[j].sj` | stub SJ process: `"None"` / `"Running"` / `"Exited"` | `sj[j]` |
| `clients[c].alive` | CP harness instance alive | `cpAlive[c]` |
| `clients[c].free` | `ListResourceManager.resources["gpu"]` as unit ids, **with multiplicity** | `free[c]` (bag) |
| `clients[c].reserved` | `reserved_resources`: `[{att, job, units, ttl}]` | `resv[c]` |
| `clients[c].jobs[j].registration` | `JobExecutor.run_processes.get(j)`: `{present, st: STATUS name, attached: handle is not a pending _PendingJobHandle or it has a real handle, abort_req: _abort_requested}` | `cjReg[c][j]` |
| `clients[c].jobs[j].starting` | units held by an in-progress `StartJobProcessor.process` for j (harness side table between allocate and the reply) | `cst[c][j]` |
| `clients[c].jobs[j].allocated` | `allocated_resource` held by the live `_wait_child_process_finish` thread of j | `alloc[c][j]` |
| `clients[c].jobs[j].cj` | stub CJ leader: `"None"` / `"Alive"` / `"Exited"` | `cjProc[c][j]` |

Snapshot validation is uniform (`Trace.tla` `ValidatePostState`). Every field above is compared after every
event, so the harness must emit **all** of them on every event. Client fields other than `alive` are compared
only while the client is alive. Not captured, and checked only through action preconditions: `rpc` and
`cpc` program counters, `msgs`, `nextAtt`, `adm`, `sweeper`, `sjRC`, `wfc`, `rmp`, `shared`, `grp`,
`using`, `termP`, `cjAbortMsg`, `disabled`, and the history variables.

### 1.3 Message identity (`event.msg`)

This identifies the consumed message. The fields match `M(type, job, cl, att, ok, code, flag)` in `base.tla`.

| type | job | cl | att | ok | code | flag |
|---|---|---|---|---|---|---|
| CHECK | job | client | attempt | false | 0 | false |
| CHECK_REP | job | client | attempt | is_resource_enough | 0 | false |
| CANCEL | job | client | attempt | false | 0 | false |
| START | job | client | attempt (token) | false | 0 | false |
| START_REP | job | client | 0 | false | 0 | reply body starts with `ERROR_MSG_PREFIX` |
| ABORT | job | client | 0 | false | 0 | heartbeat_cleanup |
| REPORT | job | client | 0 | false | reported code | false |
| RUNSTATUS | job | "None" | 0 | false | 0 | execution_error |
| SJABORT | job | "None" | 0 | false | 0 | false |

## Section 2: Action-to-Code Mapping

The trigger point is "after X" unless stated. "Emit" means: append the event, with its post-state snapshot,
under the trace lock.

### 2.1 SP runner thread (`JobRunner.run`, `job_runner.py:633-731`)

| Spec action | Code location | Trigger point | Event fields / notes |
|---|---|---|---|
| `RunnerScanList` | `job_def_manager.py:517-519` (`_scan` → `store.list_objects`) | after `list_objects` returns inside `get_jobs_to_schedule` (called at `job_runner.py:650`) | none. Only emitted when `engine.get_clients()` is non-empty (`:646-648`). |
| `RunnerScanReadDeleted` | `job_def_manager.py:526` | when `store.get_meta` raises for a listed object | none. The runner thread then dies. Emit from an `except` hook placed around the call site; it must re-raise. |
| `RunnerScanRead` | `job_runner.py:650-658`, `job_scheduler.py:339-344` | after `_exceed_max_jobs` in `_do_schedule_job`, or at `schedule_job` entry when the candidate list is empty | none. Tags written during the scan appear in `tagged`. |
| `RunnerTryNext` | `job_scheduler.py:346-365` and `_try_job :104-199` | per candidate: after `_update_schedule_history` for blocked jobs (`:353`); after `_try_job` returns NO_RESOURCE *without* CHECK (`:164`, `:176`, `:205`); when `_try_job` raises at `:166`; or just **before** `_check_client_resources` sends CHECK (`:199`) | `job` = candidate. For the CHECK branch the harness increments `att`. |
| `RunnerBackoffSkip` | `job_scheduler.py:360-362` | at the `continue` | `job` = candidate |
| `RunnerTryDone` | `job_scheduler.py:377-378` | before `return None, None` | none |
| `RunnerCheckCollect` | `server_engine.py:1024-1041` | after `_send_admin_requests` returns with a reply for every request | none. `schedule_count` of failed jobs changes only at the refresh. |
| `RunnerCheckTimeout` | same | when at least one reply is `None` (timeout) | none. Missing sites evaluate as `(False, "")`. |
| `RunnerRefreshRead` | `fs_storage.py:268-273` (via `job_scheduler.py:303/307`) | after `get_meta` inside `update_meta(replace=False)` | `job` = refreshed job. Also emitted (then aborted) when `_object_exists` raises. |
| `RunnerRefreshWrite` | `fs_storage.py:273-275` | after `_write` | `job` |
| `RunnerSetCantSched` | `job_scheduler.py:308` | after `set_status(FINISHED_CANT_SCHEDULE)`, or when it raises | `job` |
| `RunnerCheckSubmitted` | `job_runner.py:661-663`, `:736-739` | after `_check_job_status(SUBMITTED)` evaluates (or raises) | `job`. The skip branch leads to `RunnerScanList` next. |
| `RunnerDeployJob` | `job_runner.py:669`, `_deploy_job :149-285` | after `_deploy_job` returns or raises | `arg.failed` = failed / timed-out client names (`[]` when it raised "unknown clients") |
| `RunnerSetDispatched` | `job_runner.py:670` | after `set_status(DISPATCHED)` returns or raises | `job` |
| `RunnerMetaRead` | `fs_storage.py:268-273` via `job_runner.py:674` | after `get_meta` inside `update_meta` | `job` |
| `RunnerMetaWrite` | `fs_storage.py:273-275` via `:674` | after `_write` | `job` |
| `RunnerCheckDispatched` | `job_runner.py:697-701` | after `_check_job_status(DISPATCHED)` | `job` |
| `RunnerStartServerApp` | `job_runner.py:304-310` | after `start_app_on_server` returned `""`, after `_pending_client_outcomes[job]` was set, **before** `start_client_job` sends START_JOB | `job`. When `start_app_on_server` returns an error, emit `RunnerExceptStop` next instead. |
| `RunnerStartServerAppFail` | `server_engine.py:236-329` | when `_start_runner_process` raises (stub launcher raises) | `job` |
| `RunnerStartCollect` | `job_runner.py:310-364` | after `_fire_job_lifecycle_event(JOB_STARTED)`, or when `check_client_replies` / `:360` raises, with every START reply received | `job` |
| `RunnerStartTimeout` | same | same, with at least one START reply timed out | `job` |
| `RunnerInsertRunning` | `job_runner.py:709-710` | after the insert, releasing `self.lock` | `job` |
| `RunnerSetRunning` | `job_runner.py:711` | after `set_status(RUNNING)` returns or raises | `job` |
| `RunnerExceptStop` | `job_runner.py:714-719` | after `_stop_run` (or at the `except` entry when `job_id` is None) | `job` |
| `RunnerExceptSetFailed` | `job_runner.py:720` | after `set_status(FAILED_TO_RUN)` returns or raises | `job` |
| `RunnerExceptMeta` | `job_runner.py:722-728` | after `JOB_ABORTED` is fired, or when `update_meta` raises | `job` |

### 2.2 SP completion thread (`_job_complete_process`, `job_runner.py:441-541`)

| Spec action | Code location | Trigger point | Fields / notes |
|---|---|---|---|
| `CmpFinalizeBegin(j)` | `:444-492` | after `_finished_job_states[j]` holds the latch (or was already latched) and before archival | `job`. Do not emit on iterations that `continue` at `:471-472`. |
| `CmpOutcomeDeadline(j)` | `:466-476` | after `pending.clear()` | `job` |
| `CmpPublish` | `:523-530` | after `set_status(status)` returns, or in the `except` before `continue` | `job` |
| `CmpRemove` | `:531-540` | after `remove_exception_process`, or when `del running_jobs[j]` raises `KeyError` | `job` |

### 2.3 SP admin handlers (`job_cmds.py`)

| Spec action | Code location | Trigger point | Fields / notes |
|---|---|---|---|
| `AdminAbortBegin(j)` | `job_cmds.py:1058-1060` | after `get_job` and the status read | `job`. Emit only for SUBMITTED, DISPATCHED or RUNNING (other branches change nothing). |
| `AdminAbortWrite(j)` | `:1061-1066` | after `set_status(FINISHED_ABORTED)` returns or raises | `job` |
| `AdminStopRun(j)` | `job_runner.py:798-799` (`_stop_run`) | after `_stop_run` returns | `job` |
| `AdminMarkAborted(j)` | `job_runner.py:802-811` | after `mark_run_aborted` returns | `job` |
| `AdminDeleteAuthorize(j)` | `job_cmds.py:282-316` | after `conn.set_prop(self.JOB, job)` | `job` |
| `AdminDeleteExec(j)` | `job_cmds.py:507-535` | after the refusal or after `job_def_manager.delete` | `job` |
| `AdminDisable(c)` | `server_engine.py:620-644` | after `disable_client` removes the tokens | `cl` |

### 2.4 SP cell handlers and SJ-related threads

| Spec action | Code location | Trigger point | Fields / notes |
|---|---|---|---|
| `SpUpdateRunStatus(m)` | `fed_server.py:594-604` | before returning the reply | `msg` = RUNSTATUS |
| `SpProcessJobFailure(m)` | `fed_server.py:906-957` | before every return, including the drop paths | `msg` = REPORT (`cl` = reporting site) |
| `SpWaitForComplete(j)` | `server_engine.py:203-234` | after `run_processes.pop` (or after the `if run_process_info` check fails) | `job` |
| `SpRemoveRunProcesses(j)` | `server_engine.py:385-409` | after the final `run_processes.pop` | `job` |
| `SweepBegin(c)` | `fed_server.py:309-317,324-330,1096-1107` | after the pending-outcome loop of `notify_dead_client` | `cl` |
| `SweepEnd` | `fed_server.py:1108-1113` | after the `run_processes` loop ends or raises | none |

### 2.5 SJ process (stubbed at the process edge)

The SJ is a stub process or thread that registers exactly like `_start_runner_process` does. Its actions
are harness-driven:

| Spec action | Code location mirrored | Trigger point | Fields |
|---|---|---|---|
| `SjFinish(j, ee, rc)` | `server_app_runner.py:55-99` (finally → `update_job_run_status`) | after the stub fires UPDATE_RUN_STATUS and exits | `job`, `arg.execution_error`, `arg.rc` (0 or 1, normalised as `process_launcher.py:51-55`) |
| `SjCrash(j)` | process killed | after the stub exits without a report | `job` |
| `SjHandleAbort(m)` | `server_commands` ABORT → `ServerRunner.abort` | after the stub consumes the ABORT command (it reports and exits 0 when running) | `msg` = SJABORT |

### 2.6 Client parent (`scheduler_cmds.py`, `client_engine.py`, `client_executor.py`)

| Spec action | Code location | Trigger point | Fields / notes |
|---|---|---|---|
| `CpCheckResource(m)` | `scheduler_cmds.py:61-92` → `auto_clean.py:119-137` | after `check_resources` returns | `msg` = CHECK. Reserved units appear in `reserved`. |
| `CpCancelResource(m)` | `scheduler_cmds.py:140-157` | after `cancel_resources` | `msg` = CANCEL |
| `CpStartAllocate(m)` | `scheduler_cmds.py:100-121`, `client_engine.py:357-359` | after `allocate_resources` returns (units → `starting`) or raises, or after the "already started" return | `msg` = START |
| `CpStartAllocateAppMissing(m)` | `client_engine.py:365-367` | after the error-string return (UNSUPPORTED trigger only) | `msg` = START |
| `CpStartRegister(c, j)` | `client_executor.py:299-307` | after the STARTING entry is registered, or when "still registered" raises | `cl`, `job` |
| `CpStartLaunch(c, j)` | `client_executor.py:308-334` | after the waiter thread starts | `cl`, `job` |
| `CpStartLaunchFail(c, j)` | `client_executor.py:308-316`, `scheduler_cmds.py:129-133` | after `free_resources` in the exception path | `cl`, `job` |
| `CpAbortApp(m)` | `training_cmds.py:37-46` → `client_engine.py:390-404` → `client_executor.py:486-547` | after `abort_app` has recorded the request (before its `_terminate_job` join) | `msg` = ABORT (flag = heartbeat_cleanup) |
| `CpTerminateJob(c, j)` | `client_executor.py:581-601` | at the early return (`:587-589`), or after `terminate()` | `cl`, `job` |
| `CpChildFinished(c, j)` | `client_executor.py:622-688` | after `run_processes.pop` (`:680-681`) | `cl`, `job`. The REPORT it sends is in flight. |
| `CpTick(c)` | `auto_clean.py:102-117` | after one tick body under `_lock` | `cl`. The harness should drive ticks explicitly (Section 3.3). |
| `Heartbeat(c)` | `communicator.py:580-649`, `fed_server.py:959-1077` | after `_sync_client_jobs` returns on the server | `cl`. The ABORT jobs listed are in flight to the CP. |
| `ClientCrash(c)` | CP harness instance stopped | after the harness stops the CP and its stub CJs | `cl` |

### 2.7 Client job process (stubbed at the process edge)

| Spec action | Code location mirrored | Trigger point | Fields |
|---|---|---|---|
| `CjNotifyStarted(c, j)` | `client_app_runner.py:71-78` → `client_executor.py:347-350` | after the CP's `notify_job_status` wrote STARTED | `cl`, `job` |
| `CjNotifyStopped(c, j)` | `client_app_runner.py:80-88` | after STOPPED is written | `cl`, `job` |
| `CjHandleAbort(c, j)` | CJ `ClientRunner.abort` on the CP's ABORT | after the stub handles it (STOPPED written when running) | `cl`, `job` |
| `CjExit(c, j, rc, desc)` | worker process exit (`mpm.py:131-201`) | after the stub leader exits | `cl`, `job`, `arg.rc` ∈ {0, 1, 102}, `arg.descendants` |
| `CjGroupExit(c, j)` | same-group descendants exit | after the stub's descendants exit | `cl`, `job` |

### 2.8 Network

| Spec action | Trigger point | Fields |
|---|---|---|
| `LoseMsg(m)` | when the harness drops a message at the stub network edge (fault injection) | `msg` = dropped message |

## Section 3: Special Considerations

### 3.1 One linear order over several threads

The SP and CP run several threads (runner, completion, admin, cell handlers, waiters, expiry, heartbeat).
The harness wraps each instrumented operation in a single process-wide trace lock. The lock covers the
state change being traced and the snapshot. This makes the NDJSON order a valid linearisation. It
serialises only the traced sections and does not change what the code does. For multi-step operations
(`update_meta` read, then write; the scan list, then read), hook each half separately, so other
threads can interleave between the halves exactly as the spec allows.

### 3.2 Run the SP and CPs in one process with real product objects

Use the real `JobRunner`, `DefaultJobScheduler`, `SimpleJobDefManager` with `FilesystemStorage`,
`JobCommandModule` handlers, `FederatedServer.process_job_failure` and `_sync_client_jobs`, `ServerEngine`
bookkeeping, `Check`/`Start`/`CancelResourceProcessor`, `ClientEngine.start_app`/`abort_app`, `JobExecutor`
and `ListResourceManager`. Stub only the CellNet edge and the SJ/CJ processes, as
`evidence/harness/lifecycle_harness.py` and `client_harness.py` do. Stubbed RPCs must preserve
request/reply semantics:
- a reply that arrives after the sender timed out is discarded;
- a request that timed out at the sender may still be processed later (`RunnerCheckTimeout` followed by
  a late `CpCheckResource`).

### 3.3 Expiry ticks and timeouts are reproduction controls

Construct the resource manager with a very large `check_period`, so the real thread never ticks. Drive the
tick body (`auto_clean.py:105-117`) from the harness, under `_lock`, and emit `CpTick`. RPC timeouts
(`RunnerCheckTimeout`, `RunnerStartTimeout`) are produced by the stub edge withholding replies. The outcome
deadline (`CmpOutcomeDeadline`) is reached by constructing `JobRunner` with a small
`client_outcome_wait_timeout` via `ConfigService`, not by editing code.

### 3.4 Bootstrap

`Init` has every job SUBMITTED, every client registered with a full pool, and nothing running. So the harness:
1. submits all jobs before starting `JobRunner.run`;
2. registers every client before the first `RunnerScanList`;
3. fires `SYSTEM_START` for the resource managers.

`JobOrder` equals the submit order, and `SUBMIT_TIME` must be strictly increasing in that order.

### 3.5 Granularity rules that affect event placement

- `set_status` is one event (blind write). The three RMW writers that can revert status
  (`job_scheduler.py:303/307` refresh and `job_runner.py:674`) are two events each (read, then write).
- `RunnerStartServerApp` covers SJ launch, pending registration and the START fan-out. Emit it once, before
  `start_client_job`.
- `SpProcessJobFailure` covers the whole handler, including `fail_run` / `stop_run` and
  `resolve_client_outcome`.
- `AdminStopRun` and `AdminMarkAborted` are separate events: the admin thread can be descheduled between
  `_stop_run` and `mark_run_aborted`.
- `CpChildFinished` covers reap, rc remap, report send, free and pop. The report is a message consumed later
  by `SpProcessJobFailure`.

### 3.6 Serialization quirks

- `PROCESS_RETURN_CODE` is `None` until set; emit `0` for None.
- Status strings are emitted verbatim (`"FINISHED:COMPLETED"`, ...). A deleted job is `"DELETED"`.
- `free` must list duplicates when a unit appears twice in the deque. Bag equality is how `Trace.tla` detects
  duplication.
