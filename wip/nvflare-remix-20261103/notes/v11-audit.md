# v11 audit notes (breadth plan, DESIGN §16)

Pin `c411a201`, source `/home/ubuntu/nvflare-integrated-model-20261103/sources/current` (read only). This file collects the leads I came across while reading code for the v11 blocks. Leads here are recorded, not reproduced and not counted.

## Leads

| ID | Block | Where | What | Status |
|---|---|---|---|---|
| V1 | E | `app_opt/job_launcher/k8s_launcher.py:409-437` | `K8sJobHandle.terminate()` sets `terminal_state = TERMINATED` and calls `_release_job_resources()` (task owner release, workspace transfer `remove_job`, credential Secret delete) on any non-404 `ApiException` or other exception from `delete_namespaced_pod`, although the Pod may still run. Same as Phase 1 H20 (known-open). | known (H20) |
| V2 | E | `app_opt/job_launcher/docker_launcher.py:390-404` | Docker `terminate()` on `APIError` only logs and keeps the handle non-terminal (ownership retained), unlike K8s. Contrast for V1, no lead. | note |
| V3 | B | `app_common/workflows/scatter_and_gather.py:283-298` with `apis/impl/wf_comm_server.py:657-672` | A result callback that raises only sets the task's completion status to ERROR; SAG never reads the status after `broadcast_and_wait` and aggregates the accumulator, which `WeightedAggregationHelper.add` (`weighted_aggregation_helper.py:192-266`) may have mutated for some keys only (no rollback; `history` appended after the loop). Phase 1 H04. | known candidate (H04) |
| V4 | B | `app_common/workflows/cyclic_ctl.py` `_process_result` | A non-OK result or a conversion exception calls `_stop_workflow`; `control_flow` then returns normally (no `system_panic`), so the run ends as a normal finish after a client error. Intentional? Recorded for the status-mapping check. | to check |
| V4b | B | `app_common/workflows/cyclic_ctl.py` `_get_relay_orders` | Cyclic needs at least two active sites; with one it calls `system_panic` every round. Modeled as `RelayPanic` (the smoke uses two sites). | modeled |
| V5 | A | `app_common/np/np_model_persistor.py:103-114` | `save_model` calls `np.save` on the final path directly (no temp file and replace), so a failure mid-write leaves a truncated artifact; the PT persistor stages and replaces (`app_opt/pt/file_model_persistor.py:308-345`). Phase 1 H39 lists both. | known candidate (H39) |

## Pre-existing gaps seen during v11 smoke (not caused by v11)

- `AG_Trainer` (environment assumption of the Trainer harness receipt) is violated in the v10 baseline itself (no v11 switch; 2 sites, 1 round, faults cbFail and taskTimeout, simulation): TaskCJ_C publishes an input to a trainer whose port says `stopped` with `received = 0`, outside `Env_Trainer!FieldOK`. Its earlier discharge (RESULTS §7) ran without these faults. Left as is; the Trainer receipt's transfer needs a wider `Env_Trainer` before it is used with these faults.
- `AG_WfSJ`'s `CallOK` admits only `ResultValue(site, round)` as an APP_CALL value; with two rounds the coarse Trainer may publish an earlier generation, so a round-2 call carries round 1's value (seen under `cseServer`, also possible without v11 switches). With one round `AG_WfSJ`, `AG_Pay` and `AG_RunCJ` hold in every A/B mix (300 s each).

## Windows that need fine steps later

| Window | Code | Event that lands in it | Why coarse cannot show it |
|---|---|---|---|
| H24: the trainer clears `_result_send_active` before RESULT_SOURCE_SETTLED is acknowledged, while CJ finalize closes the Attach listener | `client/cell/api.py` send tail; `attach_backend.py:375-412` | CJ finalize (END_RUN) | Trainer_A merges settlement and finalize (`Finalize` clears the source in one step); the gap between the trainer's flag clear and the CJ's listener close needs separate trainer and CJ steps |
| Attach delivery: RESULT_READY arriving while `_deliver_task` still retries | `attach_backend.py:655-745` (`task.result_ready` checks) | trainer result during a lost TASK_ACCEPTED | Trainer_A delivers atomically (`Deliver`/`DeliverFail`); interleaving the retry loop with an early result needs the loop's steps |

## Deferred

| Item | Reason |
|---|---|
| Slurm launcher | batch scheduler semantics (queueing, `scancel`, accounting states) need cluster behavior; 2,148 lines under `app_opt/job_launcher/slurm/` |
| H31 (new transaction per submission try) | payload ports are keyed by attempt; a per-try transaction changes the port shape of PaySrc/PayRcv in both variants; contract baseline, the server deduplicates by receipt |
