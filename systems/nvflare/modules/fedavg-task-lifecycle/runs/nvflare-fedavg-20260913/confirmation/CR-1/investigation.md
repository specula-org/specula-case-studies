# CR-1 Investigation

## Finding

- Source: Code Review.
- Title: Protected broadcast input and outbound ownership boundaries.
- Current source head: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

## Step 1: Code Audit

- `nvflare/apis/impl/wf_comm_server.py:285-330`: `process_task_request` reaches `_try_to_get_task`, runs `before_task_sent_cb` under `task.cb_lock`, then for `BcastTaskManager` / `BcastForeverTaskManager` creates `task._broadcast_data = copy.deepcopy(task.data)` once and uses it as `task_data`.
- `nvflare/apis/impl/wf_comm_server.py:368-378`: after the snapshot selection, the current code calls `make_copy(task_data)` before setting `TASK_OPERATOR`, `TASK_ID`, `MSG_ROOT_ID`, and `MSG_ROOT_TTL`, so per-client headers are placed on a per-client envelope rather than on the shared broadcast payload.
- `nvflare/apis/shareable.py:157-171`: `make_copy` shallow-copies the `Shareable` payload and deep-copies headers. This is consistent with the current WFCommServer ownership boundary: payload data comes from the broadcast snapshot; per-client headers are independent.
- `nvflare/app_common/workflows/base_model_controller.py:221-233`: FedAvg/model broadcast creates a task whose `before_task_sent_cb` is `_prepare_task_data`; that callback fires `BEFORE_TRAIN_TASK` against `client_task.task.data`, so first-client callback mutations are captured before the snapshot.
- `nvflare/app_common/workflows/fedavg.py:224`: `FedAvg.run` uses `send_model(... callback=self._aggregate_one_result)`, which reaches the broadcast path for selected clients.
- `nvflare/private/fed/server/server_runner.py:329-345`: the outbound task-data filters run after the communicator returns task data. This means subset-specific filters are outside the WFCommServer snapshot boundary and must own copies if they mutate payloads.
- `nvflare/app_opt/pt/quantization/quantizer.py:235-244`: the quantizer comment explicitly notes that for 1-to-N server-client filters, if filters differ by client subset, the filter should deep-copy server data before applying a different filter.

Reachability: the normal Recipe/FedAvg path reaches the cited broadcast code through `FedAvg.run -> BaseModelController.send_model/broadcast_model -> Controller.broadcast -> WFCommServer.broadcast -> client task request`. The normal ServerRunner path then applies outbound filters after task retrieval.

Trigger candidate: a broadcast task is scheduled for two clients; one client retrieves the task, then the controller or aggregation logic mutates the original task data before a later client retrieves it. Pre-fix code could expose changed shared data to the later client or mutate shared headers before copying. Current source has a broadcast snapshot and per-client header copy at that boundary.

Safeguards observed: `task.cb_lock` serializes callbacks around snapshot creation; `_broadcast_data` is deep-copied for broadcast tasks; `make_copy` creates independent per-client headers; `_release_task_resources` and monitor cleanup delete `_broadcast_data` when tasks leave the communicator.

## Step 2: Developer-Knowledge Search

- Local `git log -- nvflare/apis/impl/wf_comm_server.py ...` shows `7d8a7df7a Fix potential data corrupt (#4129)`.
- `git blame -L 277,380 -- nvflare/apis/impl/wf_comm_server.py` attributes the `_broadcast_data` snapshot and per-client `make_copy` header fix to `7d8a7df7a`, with only Specula hook lines uncommitted in the current dirty checkout.
- `nvflare/apis/wf_comm_spec.py:64-69` documents the current developer contract: server-side broadcast creates an immutable snapshot of `task.data` to prevent data corruption, and non-serializable data marks the task error instead of raising.
- Existing tests in `tests/unit_test/apis/impl/controller_test.py` document that broadcast uses `_broadcast_data` and that per-client `before_task_sent_cb` customization is not supported, while `assert_task_data_valid` expects payload preservation plus per-client system headers.

## Step 3: Known Status / Precedent

Prior-report search covered upstream issue/PR tracker plus git history:

- GitHub issue/PR API query `repo:NVIDIA/NVFlare "Fix potential data corrupt"` returned PR #4129, closed/merged, `https://github.com/NVIDIA/NVFlare/pull/4129`.
- GitHub issue/PR API query `repo:NVIDIA/NVFlare "_broadcast_data"` returned PR #4126 and PR #4129, both closed/merged.
- GitHub issue/PR API query `repo:NVIDIA/NVFlare "min_responses" "corrupted data"` returned PRs #4056, #4100, #4121, #4126, and #4129, all closed/merged.
- GitHub issue/PR API query `repo:NVIDIA/NVFlare "task.data" "broadcast" "data corruption"` returned PRs #4100, #4121, #4124, #4126, and #4129, all closed/merged.

PR #4129 was merged into `NVIDIA:main` on 2026-02-05 and explicitly describes the same mechanism: server broadcast with `min_responses < total_clients`, aggregation mutating the global model while slower clients are still downloading shared data, and the WFCommServer fix of one `_broadcast_data` deep copy plus per-client `make_copy` headers. It also states the same remaining boundary for callback/filter ownership: per-client callback customization is not supported for broadcast, and subset-specific filters must copy before mutating.

Known-status result: `KNOWN (cite: https://github.com/NVIDIA/NVFlare/pull/4129; fix-status: fixed)`.
