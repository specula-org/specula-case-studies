#!/usr/bin/env python3
"""Reproducible, pinned, observation-only source insertions (no checkout/reset)."""
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path("/home/ubuntu/nvflare-runs-20260913/source-fedavg")
HERE = Path(__file__).resolve().parents[1]
HEAD = "53ba7ee567468ea7971dad4faccef13c6cb35dc2"
edits = {}


def edit(file, old, new):
    edits.setdefault("nvflare/" + file, []).append((old, new))


def after(file, anchor, event, indent=None):
    spaces = indent if indent is not None else len(anchor) - len(anchor.lstrip())
    edit(file, anchor, anchor + "\n" + " " * spaces + f'_st.hook("{event}", locals())')


F = "app_common/workflows/fedavg.py"
after(F, "                self.event(AppEventType.ROUND_STARTED)", "FedAvgRoundStarted")
after(F, "                self._site_metric_weights = {}", "FedAvgResetAggregation")
edit(
    F,
    "                # Wait for all results to be processed",
    '                _st.pause("round_wait", locals())\n                # Wait for all results to be processed',
)
edit(
    F,
    "                while self.get_num_standing_tasks():",
    "                while _st.poll_standing(self, self.get_num_standing_tasks()):",
)
edit(
    F,
    "                    if self.abort_signal.triggered:",
    "                    if _st.poll_abort(self, self.abort_signal.triggered):",
)
after(F, "                    time.sleep(self._task_check_period)", "poll_sleep")
after(F, "                model = self.update_model(model, aggregate_results)", "BaseFedAvgUpdateModel")
edit(
    F,
    "                    self.save_model(model)\n\n                # Memory cleanup",
    '                    self.save_model(model)\n                    _st.hook("FedAvgSaveModel", locals())\n\n                # Memory cleanup',
)
after(F, "                self._maybe_cleanup_memory()", "FedAvgAdvanceRound")
after(F, '            self.warning(f"Empty result from client {client_name}, skipping.")', "FedAvgAggregateOneResult")
edit(
    F,
    "            self._aggr_helper.add(",
    '            _st.hook("FedAvgAggregateOneResult", locals())\n            self._aggr_helper.add(',
)
edit(F, "            if self._all_metrics and result.metrics:", "            if self._all_metrics and result.metrics:")
edit(
    F,
    "                aggregatable = filter_aggregatable_metrics(",
    '                _st.fault("metric_preparation", locals())\n                aggregatable = filter_aggregatable_metrics(',
)
edit(
    F,
    "                if aggregatable:",
    '                _st.hook("FedAvgProcessMetrics", locals())\n                if aggregatable:',
)
edit(
    F,
    "        self._received_count += 1",
    '            if not (self._all_metrics and result.metrics):\n                _st.hook("FedAvgProcessMetrics", locals())\n\n        self._received_count += 1',
)
after(F, "            aggr_stats = self._aggr_helper.get_aggregation_stats()", "FedAvgGetAggregationStats")
after(F, "            aggr_params = self._aggr_helper.get_result()", "WeightedGetParamResult")
after(
    F,
    "            aggr_metrics = self._aggr_metrics_helper.get_result() if self._all_metrics else None",
    "WeightedGetMetricResult",
)
edit(
    F,
    "            return FLModel(\n                params=aggr_params,",
    "            _st_result = FLModel(\n                params=aggr_params,",
)
edit(
    F,
    "    def _make_metrics_aggregation_info(self)",
    '            _st.hook("FedAvgBuildAggregateResult", locals())\n            return _st_result\n\n    def _make_metrics_aggregation_info(self)',
)

B = "app_common/workflows/base_model_controller.py"
after(B, "        self.abort_signal = abort_signal", "bootstrap")
after(
    B,
    "            AppEventType.BEFORE_TRAIN_TASK, fl_ctx, AppConstants.TRAIN_SHAREABLE, client_task.task.data\n        )",
    "BasePrepareTaskData",
    8,
)
edit(
    B,
    "    def _prepare_task_data(self, client_task: ClientTask, fl_ctx: FLContext) -> None:",
    '    def _prepare_task_data(self, client_task: ClientTask, fl_ctx: FLContext) -> None:\n        _st.fault("before_send", locals())',
)
after(
    B,
    "            preliminarily_accepted = self._accept_train_result(client_name=client_name, result=result, fl_ctx=fl_ctx)",
    "BaseAcceptTrainResult",
)
edit(
    B,
    "                    result_model = FLModelUtils.from_shareable(result)",
    '                    _st.fault("conversion", locals())\n                    result_model = FLModelUtils.from_shareable(result)',
)
after(B, '                    result_model.meta["client_name"] = client_name', "BaseConvertResult")
after(B, "                            accepted = callback(result_model) is not False", "consumer_return")
after(
    B,
    '                    self.warning(f"Failed to convert result from {client_name} to FLModel: {e}")',
    "BaseConvertResultFailure",
)
after(
    B,
    '                            self.error(f"Unsuccessful callback {callback} for task {client_task.task.name}: {e}")',
    "consumer_failure",
)
after(B, "            self.event(AppEventType.AFTER_CONTRIBUTION_ACCEPT)", "BasePublishAcceptance")
after(B, "            client_task.result = None", "BaseClearTrainingResult")
edit(
    B,
    '        else:\n            self.error("Ignoring result from unknown task.")',
    '            _st.hook("BaseProcessUnknownResult", locals())\n        else:\n            self.error("Ignoring result from unknown task.")',
)

H = "app_common/aggregators/weighted_aggregation_helper.py"
after(H, "                self.key_contribution_counts[k] = self.key_contribution_counts.get(k, 0) + 1", "helper_stats")
edit(
    H,
    '                materialize_fn = getattr(v, "materialize", None)',
    '                _st.fault("helper_value", locals())\n                materialize_fn = getattr(v, "materialize", None)',
)
after(H, "                    self.counts[k] = self.counts[k] + weight", "helper_value", 16)
edit(H, "    def get_result(self):", '        _st.hook("helper_history", locals())\n\n    def get_result(self):')

W = "apis/impl/wf_comm_server.py"
after(W, "                self._dead_clients[client_name] = _DeadClientStatus()", "WFCommReportDeadClient")
edit(
    W,
    "        with task.cb_lock:\n            # Note:",
    '        with task.cb_lock:\n            _st.hook("request_selected", locals())\n            # Note:',
)
after(
    W,
    '                    task.exception = e\n\n            self.logger.debug("before_task_sent_cb done on client_task_to_send: {}".format(client_task_to_send))',
    "BasePrepareTaskDataFailure",
    12,
)
# The preceding hook is conditional in the observer: only an actual exception emits it.
after(W, '            task_data = getattr(task, "_broadcast_data", task.data)', "protect")
edit(
    W,
    "                        task._broadcast_data = copy.deepcopy(task.data)",
    '                        _st.fault("protect", locals())\n                        task._broadcast_data = copy.deepcopy(task.data)',
)
edit(
    W,
    "            if not can_send_task:\n                return self._try_again()",
    '            _st.hook("WFCommCheckCanSend", locals())\n            if not can_send_task:\n                return self._try_again()',
)
edit(
    W,
    "        with self._controller_lock:\n            self._do_process_submission(client, task_name, task_id, result, fl_ctx)",
    '        with self._controller_lock:\n            _st.hook("WFCommAcquireSubmission", locals())\n            self._do_process_submission(client, task_name, task_id, result, fl_ctx)',
)
edit(
    W,
    "        if client_task is None:\n            if (",
    '        if client_task is None:\n            _st.hook("dispatch_missing", locals())\n            if (',
)
edit(
    W,
    "            if task.completion_status is not None:\n                # the task is already finished",
    '            _st.hook("dispatch_live", locals())\n            if task.completion_status is not None:\n                # the task is already finished',
)
after(W, "            client_task.result_received_time = time.time()", "receipt_observed")
after(W, "            self._tasks.append(task)", "WFCommScheduleTask")
after(W, "\n        task.completion_status = completion_status", "WFCommCancelTask", 8)
after(W, "            self._all_done = True", "WFCommFinalizeRun")
edit(
    W,
    "        if not self._dead_clients:\n            return",
    '        _st.hook("monitor_begin", locals())\n        if not self._dead_clients:\n            _st.hook("monitor_dead_end", locals())\n            return',
)
edit(
    W,
    "            for client_name, status in self._dead_clients.items():",
    '            for client_name, status in self._dead_clients.items():\n                _st.hook("dead_next", locals())',
)
edit(
    W,
    "    def _monitor_tasks(self):",
    '        _st.hook("monitor_dead_end", locals())\n\n    def _monitor_tasks(self):',
)
edit(
    W,
    "        while not self._all_done:\n            # determine",
    '        while not self._all_done:\n            _st.pause("monitor", locals())\n            if self._all_done:\n                return\n            # determine',
)
after(W, "            should_abort_job = self._job_policy_violated()", "policy_result")
after(
    W,
    '                    self.system_panic("Aborting job due to deployment policy violation", fl_ctx)',
    "WFCommJobPolicyDecision",
)
after(W, "        with self._controller_lock:\n            self._do_check_tasks()", "monitor_return", 8)
edit(
    W,
    "        exit_tasks = []\n        with self._task_lock:\n            for task in self._tasks:",
    '        exit_tasks = []\n        with self._task_lock:\n            _st.hook("WFCommMonitorAcquire", locals())\n            for task in self._tasks:',
)
edit(
    W,
    "                if task.completion_status is not None:\n                    exit_tasks.append(task)",
    '                if task.completion_status is not None:\n                    _st.hook("monitor_terminal_selected", locals())\n                    exit_tasks.append(task)',
)
after(W, "                    should_exit, exit_status = manager.check_task_exit(task)", "WFCommMonitorSelect")
after(W, "                        task.completion_status = exit_status", "WFCommMonitorMarkTerminal")
after(W, "                dead_clients = self._get_task_dead_clients(task)", "WFCommTaskDeadCheckDone")
after(W, "                    task.completion_status = TaskCompletionStatus.CLIENT_DEAD", "WFCommMonitorMarkTerminal")
after(W, "                    self._client_task_map.pop(client_task.id)", "WFCommMonitorRemove", 16)
edit(
    W,
    "            if self.get_client_disconnect_time(target):",
    '            _st_dead_time = self.get_client_disconnect_time(target)\n            _st.hook("WFCommReadTaskDeadClient", locals())\n            if _st_dead_time:',
)
edit(
    W,
    "                if self.get_client_disconnect_time(client.name):",
    '                _st_dead_time = self.get_client_disconnect_time(client.name)\n                _st.hook("WFCommReadPolicyClient", locals())\n                if _st_dead_time:',
)

R = "private/fed/server/server_runner.py"
after(R, "                        self.current_wf = None", "ServerRunnerCloseWorkflow")
after(R, '        self._report_client_active("getTask", fl_ctx)', "ServerRunnerTaskRequestActive")
edit(
    R,
    "            if not task_name or task_name == SpecialTaskName.TRY_AGAIN:\n                return self._task_try_again()",
    '            if not task_name or task_name == SpecialTaskName.TRY_AGAIN:\n                _st.hook("request_return_empty", locals())\n                return self._task_try_again()\n            _st.hook("WFCommPublishClientTask", locals())',
)
edit(
    R,
    '            except Exception as e:\n                self.log_exception(\n                    fl_ctx,\n                    "processing error in task data filter',
    '            except Exception as e:\n                _st.hook("ServerRunnerFilterFailure", locals())\n                self.log_exception(\n                    fl_ctx,\n                    "processing error in task data filter',
)
after(
    R,
    "                        self.current_wf.controller.communicator.handle_exception(task_id, fl_ctx)",
    "WFCommHandleException",
    16,
)
edit(
    R,
    "            return task_name, task_id, task_data\n        except Exception as e:",
    '            _st.hook("ServerRunnerFilterTask", locals())\n            return task_name, task_id, task_data\n        except Exception as e:',
)
edit(
    R,
    "            with self.wf_lock:\n                if self.current_wf is None:\n                    self.log_debug",
    '            with self.wf_lock:\n                _st.hook("ServerRunnerAcquireTaskRequest", locals())\n                if self.current_wf is None:\n                    self.log_debug',
)
edit(
    R,
    '        with self.wf_lock:\n            if self.status != "started" or self.current_wf is None:',
    '        with self.wf_lock:\n            _st.hook("ServerRunnerProcessSubmission", locals())\n            if self.status != "started" or self.current_wf is None:',
)
edit(
    R,
    "                return\n            return self._process_submission(client, task_name, task_id, result, fl_ctx)",
    '                _st.hook("ServerRunnerDropClosedSubmission", locals())\n                return\n            self._process_submission(client, task_name, task_id, result, fl_ctx)\n        _st.hook("submission_return", locals())',
)
after(R, '        self._report_client_active("submitTaskResult", fl_ctx)', "ServerRunnerSubmissionActive")
after(R, '        self._report_client_active("taskCheck", fl_ctx)', "ServerRunnerCheckTaskActive")
after(R, '        self._report_client_active("jobHeartbeat", fl_ctx)', "WFCommClientIsActive")
# Capture check after the real lookup and lock release using an observer return wrapper.
edit(
    R,
    '                return make_reply(ReturnCode.OK)\n            else:\n                self.log_info(fl_ctx, f"task {task_id} is not found")\n                return make_reply(ReturnCode.TASK_UNKNOWN)',
    '                _st_check_reply = make_reply(ReturnCode.OK)\n            else:\n                self.log_info(fl_ctx, f"task {task_id} is not found")\n                _st_check_reply = make_reply(ReturnCode.TASK_UNKNOWN)\n        _st.hook("ClientCheckTask", locals())\n        return _st_check_reply',
)

C = "private/fed/client/client_runner.py"
edit(
    C,
    "    def _process_task(self, task: TaskAssignment, fl_ctx: FLContext) -> Shareable:\n        reply",
    '    def _process_task(self, task: TaskAssignment, fl_ctx: FLContext) -> Shareable:\n        _st.hook("ClientReceiveTask", locals())\n        reply',
)
after(C, "        reply.set_header(ReservedHeaderKey.TASK_ID, task.task_id)", "client_processed")
edit(
    C,
    '            self.log_debug(fl_ctx, f"try #{try_count}: sending task result to server")',
    '            if try_count > 1:\n                _st.hook("ClientRetryResult", locals())\n            self.log_debug(fl_ctx, f"try #{try_count}: sending task result to server")',
)
after(
    C,
    "        reply_sent = self.engine.send_task_result(result, fl_ctx, timeout=self.submit_task_result_timeout)",
    "dispatch_ack",
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    assert subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip() == HEAD
    manifest_path = HERE / "applied.json"
    previous = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    prepared = {}
    patch = []
    for name, changes in edits.items():
        original = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{HEAD}:{name}"], text=True)
        value = original
        for old, new in changes:
            assert value.count(old) == 1, (name, old, value.count(old))
            value = value.replace(old, new, 1)
        # All target files have imports after the license; no future imports here.
        i = value.index("\nimport ") if "\nimport " in value else value.index("\nfrom ")
        value = value[:i] + "\nfrom nvflare import _specula_trace as _st\n" + value[i:]
        current = (ROOT / name).read_bytes()
        assert (
            current == original.encode() or digest(current) == previous.get(name) or current == value.encode()
        ), f"Unowned edits: {name}"
        prepared[name] = value.encode()
        patch.extend(
            difflib.unified_diff(
                original.splitlines(True), value.splitlines(True), fromfile="a/" + name, tofile="b/" + name
            )
        )
    name = "nvflare/_specula_trace.py"
    value = (HERE / "src/trace_observer.py").read_bytes()
    if (ROOT / name).exists():
        current = (ROOT / name).read_bytes()
        assert current == value or digest(current) == previous.get(name), f"Unowned edits: {name}"
    prepared[name] = value
    (HERE / "patches").mkdir(exist_ok=True)
    (HERE / "patches/instrumentation.patch").write_text("".join(patch))
    for name, data in prepared.items():
        (ROOT / name).write_bytes(data)
    manifest_path.write_text(json.dumps({n: digest(v) for n, v in prepared.items()}, indent=2) + "\n")
    print(f"Applied pinned instrumentation to {len(prepared)} files")


if __name__ == "__main__":
    main()
