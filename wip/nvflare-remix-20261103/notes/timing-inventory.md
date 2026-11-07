# Timing inventory (input for a timing spec)

The model has no time. Each row is a real time constant (pin c411a201), the ordering it decides, and how the model treats that ordering.

The guards live in `spec/Timing.tla`:
- rows #1, #2, #3 and #17 are `T1Holds`, `T2Holds`, `T3Holds` and `T4Holds`;
- each is used as `TimingOK(Faults, "<escape>", T?Holds(...))`;
- escape events and structural assumptions are listed there too.

Treatments:
- **guard**: a default-on timing assumption with a priced escape fault (T1–T3).
- **priced**: a fault with a rarity weight.
- **free**: allowed at any time at no cost.
- **gap**: the ordering is not represented.

| # | Constant (default) | Code | Ordering it decides | Model | Note |
|---|---|---|---|---|---|
| 1 | CJ `task_check_interval` 5 s (uninterruptible sleep before the CJ's DS shutdown) | client_runner.py:175,679,814-821 | CJ DS shutdown after the SJ's own | guard T1 (`CJTeardownTimingOK`, escape `slowSJTeardown`, w=2) | measured margin 7.6–7.9 s (poc-h30) |
| 2 | abort graceful wait 10 s | server_engine.py:362-374 | admin stop vs SJ graceful exit | guard T2 (escape `slowAdminStop`, w=3) | ABORT_classified_completed lead needs the escape |
| 3 | envelope 0.1 s vs round-to-DS-shutdown ≥ 1.9 s | poc-h30 REPORT | a download registered after the SJ DS shutdown | guard T3 (escape `slowEnvelope`, w=2) | |
| 4 | admin RPC timeouts: CHECK/DEPLOY 10 s, START 20 s, abort/cancel 2 s | server_engine.py:1008,1107; job_runner.py:460; admin.py:154-307 | reply vs timeout | priced `rpcTimeout` (w=1) | rule: process crashes come with rpcTimeout |
| 5 | client heartbeat 30 s; server `heart_beat_timeout` 600 s (60 s in server_json_config); cleanup pass 5 s | fed_client_base.py:419; fed_server.py:148,292; server_json_config.py:99 | client deemed dead vs alive | priced `deadClient` (w=1) | T2 and T3 race inside the cleanup pass |
| 6 | heartbeat job sync (`_sync_client_jobs`, `require_previous_report`) | fed_server.py:1013-1084 | "job not on client" detection vs CJ start | free (CP heartbeat steps) | R2 path; check that the model's first report cannot precede a real 30 s heartbeat ordering |
| 7 | SJ `task_check_period` 0.2 s; `_dead_client_grace` 60 s; task timeouts (0 = none) | wf_comm_server.py:100,117,850-1142 | task timeout / dead client / min-clients exit vs result | CommSJ_F 30 s tick free, the decision priced (`taskTimeout`, `deadClient`, `minClients`) | v7: the tick is refused before the fault phase |
| 8 | client get-task timeout, task fetch interval 0.5–2 s | client_runner.py:101; server_json_config.py:102; TaskCJ_F | assignment reply vs get-task timeout | priced (`netLoss`/`submitTimeout` via `FedLossyIn`) | free before v7 (TLC INSTANCE pitfall) |
| 9 | task-check / receipt wait (client submit) | TaskCJ_F:180,224; communicator.py:67-69 (5 s) | TASK_CHECK reply vs timeout | priced (as #8) | free before v7 |
| 10 | DownloadService pull/tx timeouts | PayRcv_F / PaySrc_F | chunk reply vs timeout | priced `pullTimeout`, `txTimeout`; `PullRetry` free tick | |
| 11 | settlement timeout 10 s, poll 0.05 s | task_execution_policy.py:102-103 | settlement vs callback | PaySrc settlers (priced pay* faults) | not re-checked in this round |
| 12 | result wait / finalization 30 s | client_api_task_runner.py:62 | trainer result vs deadline | priced `resultWaitTimeout` | |
| 13 | SJ exit: wait up to 2 s for UPDATE_RUN_STATUS before reading the return code | server_engine.py:204-235 | SJ's final status message vs process exit handling | **gap** | a status update later than 2 s leaves the return code as the only signal; worth modeling as a priced escape |
| 14 | `_remove_run_processes` 10 s; CJ `_terminate_job` 10 s | server_engine.py:386-410; client_executor.py:673-690 | graceful exit vs terminate() | partly (kill paths in JobSP/JobCP) | |
| 15 | SJ `sync_clients_from_main_process` 30 s, GET_CLIENTS 5 s | server_engine.py:828-862 | SJ start vs participant list | gap (SJ start is atomic in the model) | |
| 17 | workflow return → stop_controller + finalize_run (seconds) vs dead-client grace 60 s | server_runner.py:153-172; wf_comm_server.py:117,1179-1199 | a dead-client report after the workflow returned maturing into a policy panic before finalize | guard T4 (escape `slowFinalize`, w=2) | added after hunt8 (v8 coarse relaxation exposed it) |
| 16 | scheduler pass 1 s | job_scheduler.py / job_runner.py:695-712 | scan vs delete (T1) | free (passes need a SUBMITTED job since v7) | T1 window measured 2–26 ms per scan |

Open items for a timing module:
- Group every guard and escape here in one place, with each margin traced to the code constant.
- Add #13 as an escape (`slowStatusUpdate`).
- Check #6 against real heartbeat spacing.
- Decide whether #15 matters for the slice.
