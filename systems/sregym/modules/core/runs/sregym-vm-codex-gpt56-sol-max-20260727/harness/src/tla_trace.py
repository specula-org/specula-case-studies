"""Observational NDJSON tracing for the SREGym lifecycle TLA+ model.

This module is copied into ``sregym/tla_trace.py`` by the harness.  It is
inactive unless explicitly initialized (or ``SREGYM_TRACE_FILE`` is set).
All shadow-state changes and serialization happen under one re-entrant lock,
so file order is the modeled Category-A action order.
"""

from __future__ import annotations

import contextlib
import contextvars
import copy
import json
import os
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Iterator


NO_RUN = -1
NO_REQUEST = "__none__"
PRE_RESOURCE = "preexisting-resource"
RUN_RESOURCE = "run-resource"
RESOURCES = (PRE_RESOURCE, RUN_RESOURCE)
STAGE_RANK = {
    "idle": 0,
    "setup": 1,
    "diagnosis": 2,
    "mitigation": 3,
    "tearing_down": 4,
    "done": 5,
}

INSTRUMENTED_EVENTS = (
    "StartProblem",
    "LoadBaselineState",
    "BeginBaselineCapture",
    "ObserveBaseline",
    "PersistBaselineState",
    "DeployProblem",
    "InjectFault",
    "AdvanceToFirstStage",
    "SendSubmission",
    "DelayOrDuplicate",
    "ReceiveSubmission",
    "RetrySubmission",
    "ConductorSubmitAccept",
    "ConductorSubmitDuplicate",
    "ConductorSubmitLate",
    "Acknowledge",
    "BeginEvaluation",
    "BeginOracle",
    "CompleteOracle",
    "CompleteEvaluation",
    "AdvanceStageAfterEvaluation",
    "FinishEvaluationFuture",
    "AgentMitigate",
    "AgentTimeout",
    "AgentExit",
    "AgentExitWaitTimeout",
    "AgentExitAfterEvaluation",
    "FinishProblemCheck",
    "BeginCleanup",
    "CompleteRecovery",
    "ReconcileDelete",
    "ReconcileRestore",
    "CompleteCleanup",
    "NoiseManagerStart",
    "BeginNoiseApply",
    "CompleteNoiseApply",
    "NoiseLoopExit",
    "NoiseManagerStop",
    "NoiseManagerJoinComplete",
    "NoiseManagerJoinTimeout",
    "NoiseManagerCleanupRecorded",
    "NoiseManagerForceRemove",
    "NoiseManagerStopReturn",
    "AgentMutate",
    "Crash",
    "Restart",
    "ReplaceCluster",
    "RestartPod",
    "ReattachFault",
)

_request_context: contextvars.ContextVar[tuple[str, int] | None] = contextvars.ContextVar(
    "sregym_trace_request", default=None
)
_cleanup_actor: contextvars.ContextVar[str] = contextvars.ContextVar(
    "sregym_trace_cleanup_actor", default="driver"
)
_noise_owner: contextvars.ContextVar[str] = contextvars.ContextVar(
    "sregym_trace_noise_owner", default="driver"
)
_noise_epoch: contextvars.ContextVar[int | None] = contextvars.ContextVar(
    "sregym_trace_noise_epoch", default=None
)


def _record_key(value: dict[str, Any]) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _append_unique(records: list[dict[str, Any]], record: dict[str, Any]) -> None:
    key = _record_key(record)
    if all(_record_key(existing) != key for existing in records):
        records.append(copy.deepcopy(record))


def _remove_at(values: list[Any], one_based_index: int) -> Any:
    if one_based_index < 1 or one_based_index > len(values):
        raise AssertionError(f"queue index {one_based_index} is outside 1..{len(values)}")
    return values.pop(one_based_index - 1)


class TraceRecorder:
    """Thread-safe full-state shadow recorder matching ``Trace.tla``."""

    def __init__(
        self,
        path: str | os.PathLike[str],
        request_ids: list[str] | tuple[str, ...],
        *,
        max_run: int = 2,
        max_noise_epoch: int = 4,
        strict: bool = True,
    ) -> None:
        if not request_ids:
            raise ValueError("request_ids must be declared before the first trace event")
        if len(set(request_ids)) != len(request_ids):
            raise ValueError("request_ids must be unique")

        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._file = self.path.open("w", encoding="utf-8")
        self.lock = threading.RLock()
        self.strict = strict
        self.max_run = max_run
        self.max_noise_epoch = max_noise_epoch
        self.sequence = 0
        self._closed = False
        self._reserved_requests: set[str] = set()
        self._baseline_field_ok = {"resources": True, "values": True}

        request_status = {request_id: "new" for request_id in request_ids}
        request_run = {request_id: NO_RUN for request_id in request_ids}
        request_stage = {request_id: "none" for request_id in request_ids}
        request_retries = {request_id: 0 for request_id in request_ids}

        self.state: dict[str, Any] = {
            "process_up": True,
            "run_gen": 0,
            "stage": "idle",
            "stage_owner": NO_RUN,
            "run_stage": ["idle"] * (max_run + 1),
            "max_stage_rank": [0] * (max_run + 1),
            "waiting_for_agent": False,
            "deployed_run": NO_RUN,
            "timeout_fired": set(),
            "agent_exit_state": "none",
            "done_runs": set(),
            "results_version": [0] * (max_run + 1),
            "done_results_version": [0] * (max_run + 1),
            "eval_in_flight": False,
            "eval_run": NO_RUN,
            "eval_stage": "none",
            "eval_request": NO_REQUEST,
            "eval_origin_run": NO_RUN,
            "eval_origin_stage": "none",
            "eval_phase": "idle",
            "cleanup_state": {"driver": "idle", "evaluator": "idle"},
            "cleanup_run": {"driver": NO_RUN, "evaluator": NO_RUN},
            "submission_queue": [],
            "received_queue": [],
            "pending_acks": [],
            "accepted_by_stage": [],
            "graded_acceptances": [],
            "timed_out_acceptances": [],
            "request_status": request_status,
            "request_origin_run": request_run,
            "request_origin_stage": request_stage,
            "request_retries": request_retries,
            "cluster_gen": 0,
            "baseline_gen": NO_RUN,
            "baseline_complete": False,
            "observed_fields": set(),
            "baseline_resources": set(),
            "baseline_values": {resource: "clean" for resource in RESOURCES},
            "baseline_capture_state": "unchecked",
            "baseline_authoritative": False,
            "persisted_baseline": {
                "exists": False,
                "resources": set(),
                "values": {resource: "clean" for resource in RESOURCES},
            },
            "persisted_baseline_gen": NO_RUN,
            "persisted_baseline_complete": False,
            "cluster_resources": {PRE_RESOURCE},
            "preexisting": {PRE_RESOURCE},
            "run_created": set(),
            "resource_value": {resource: "clean" for resource in RESOURCES},
            "pre_run_value": {resource: "clean" for resource in RESOURCES},
            "delete_issued": [],
            "noise_epoch": 0,
            "noise_run": NO_RUN,
            "noise_running": False,
            "live_noise_epochs": set(),
            "noise_epoch_run": [NO_RUN] * (max_noise_epoch + 1),
            "noise_loop_count": 0,
            "apply_in_flight": set(),
            "active_noise": set(),
            "noise_stop_state": "idle",
            "noise_stop_owner": "none",
            "fault_injected_runs": set(),
            "fault_effective": [False] * (max_run + 1),
            "workload_healthy": [True] * (max_run + 1),
            "pod_gen": [0] * (max_run + 1),
            "reinjection_active": set(),
            "reattach_pending": set(),
            "oracle_state": "idle",
            "oracle_run": NO_RUN,
            "oracle_stage": "none",
            "oracle_passed": set(),
            "quiescence_observed": [False] * (max_run + 1),
        }

    @property
    def closed(self) -> bool:
        return self._closed

    def close(self) -> None:
        with self.lock:
            if self._closed:
                return
            self._file.flush()
            os.fsync(self._file.fileno())
            self._file.close()
            self._closed = True

    def _json_value(self, value: Any) -> Any:
        if isinstance(value, set):
            values = [self._json_value(item) for item in value]
            return sorted(values, key=lambda item: json.dumps(item, sort_keys=True))
        if isinstance(value, dict):
            return {key: self._json_value(item) for key, item in value.items()}
        if isinstance(value, (list, tuple)):
            values = [self._json_value(item) for item in value]
            if values and all(isinstance(item, dict) for item in values):
                return sorted(values, key=_record_key)
            return values
        return value

    def snapshot(self) -> dict[str, Any]:
        return self._json_value(copy.deepcopy(self.state))

    def transition(
        self,
        name: str,
        params: dict[str, Any],
        update: Callable[[dict[str, Any]], None],
    ) -> None:
        with self.lock:
            if self._closed:
                return
            update(self.state)
            self.sequence += 1
            envelope = {
                "tag": "trace",
                "timestamp_ns": time.time_ns(),
                "sequence": self.sequence,
                "event": {
                    "name": name,
                    "params": copy.deepcopy(params),
                    "state": self.snapshot(),
                },
            }
            self._file.write(json.dumps(envelope, sort_keys=True, separators=(",", ":")) + "\n")
            self._file.flush()
            os.fsync(self._file.fileno())

    def declared_request(self, request_id: str) -> None:
        if request_id not in self.state["request_status"]:
            raise AssertionError(
                f"request {request_id!r} was not declared at initialize(); "
                "TraceRequestIds requires the same function domain on every line"
            )

    def next_request_id(self) -> str:
        with self.lock:
            for request_id in self.state["request_status"]:
                if request_id not in self._reserved_requests:
                    self._reserved_requests.add(request_id)
                    return request_id
        raise RuntimeError("all configured trace request IDs are already reserved")


_recorder_guard = threading.Lock()
_recorder: TraceRecorder | None = None


def initialize(
    path: str | os.PathLike[str] | None = None,
    request_ids: list[str] | tuple[str, ...] | None = None,
    *,
    strict: bool = True,
) -> TraceRecorder:
    """Initialize a fresh trace file and its full initial shadow state."""

    global _recorder
    trace_path = path or os.environ.get("SREGYM_TRACE_FILE")
    if not trace_path:
        raise ValueError("trace path is required")
    ids = request_ids
    if ids is None:
        configured = os.environ.get("SREGYM_TRACE_REQUEST_IDS", "")
        ids = tuple(item for item in configured.split(",") if item)
    if not ids:
        ids = (f"req-{uuid.uuid4().hex}",)

    with _recorder_guard:
        if _recorder is not None:
            _recorder.close()
        _recorder = TraceRecorder(trace_path, list(ids), strict=strict)
        return _recorder


def _auto_initialize() -> TraceRecorder | None:
    global _recorder
    if _recorder is not None and not _recorder.closed:
        return _recorder
    trace_path = os.environ.get("SREGYM_TRACE_FILE")
    if not trace_path:
        return None
    return initialize(trace_path)


def recorder() -> TraceRecorder | None:
    return _auto_initialize()


def close() -> None:
    global _recorder
    with _recorder_guard:
        if _recorder is not None:
            _recorder.close()
        _recorder = None


def enabled() -> bool:
    current = recorder()
    return current is not None and not current.closed


@contextlib.contextmanager
def boundary_lock() -> Iterator[None]:
    current = recorder()
    if current is None:
        yield
        return
    with current.lock:
        yield


@contextlib.contextmanager
def request_context(request_id: str, received_index: int) -> Iterator[None]:
    token = _request_context.set((request_id, received_index))
    try:
        yield
    finally:
        _request_context.reset(token)


@contextlib.contextmanager
def cleanup_context(actor: str) -> Iterator[None]:
    actor_token = _cleanup_actor.set(actor)
    owner_token = _noise_owner.set(actor)
    try:
        yield
    finally:
        _noise_owner.reset(owner_token)
        _cleanup_actor.reset(actor_token)


@contextlib.contextmanager
def evaluation_context() -> Iterator[None]:
    actor_token = _cleanup_actor.set("evaluator")
    owner_token = _noise_owner.set("evaluation")
    try:
        yield
    finally:
        _noise_owner.reset(owner_token)
        _cleanup_actor.reset(actor_token)


@contextlib.contextmanager
def noise_loop_context(epoch: int) -> Iterator[None]:
    token = _noise_epoch.set(epoch)
    try:
        yield
    finally:
        _noise_epoch.reset(token)


def current_cleanup_actor() -> str:
    return _cleanup_actor.get()


def current_noise_owner() -> str:
    return _noise_owner.get()


def current_noise_epoch() -> int:
    epoch = _noise_epoch.get()
    if epoch is not None:
        return epoch
    current = recorder()
    return current.state["noise_epoch"] if current is not None else 0


def next_noise_epoch() -> int:
    current = recorder()
    if current is None:
        return 0
    with current.lock:
        return current.state["noise_epoch"] + 1


def new_request_id() -> str:
    current = recorder()
    if current is None:
        return f"req-{uuid.uuid4().hex}"
    return current.next_request_id()


def _acceptance(state: dict[str, Any], request_id: str) -> dict[str, Any]:
    return {
        "requestId": request_id,
        "originRun": state["request_origin_run"][request_id],
        "originStage": state["request_origin_stage"][request_id],
        "acceptedRun": state["run_gen"],
        "acceptedStage": state["stage"],
    }


def start_problem(conductor: Any) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        generation = state["run_gen"] + 1
        if generation > current.max_run:
            raise AssertionError("run generation exceeds Trace.cfg MaxRun")
        state["run_gen"] = generation
        state["stage"] = "setup"
        state["stage_owner"] = generation
        state["run_stage"][generation] = "setup"
        state["max_stage_rank"][generation] = STAGE_RANK["setup"]
        state["waiting_for_agent"] = False
        state["timeout_fired"].discard(generation)
        state["agent_exit_state"] = "none"
        state["results_version"][generation] = 0
        state["done_results_version"][generation] = 0
        state["eval_in_flight"] = False
        state["eval_run"] = NO_RUN
        state["eval_stage"] = "none"
        state["eval_request"] = NO_REQUEST
        state["eval_origin_run"] = NO_RUN
        state["eval_origin_stage"] = "none"
        state["eval_phase"] = "idle"
        state["cleanup_state"] = {"driver": "idle", "evaluator": "idle"}
        state["cleanup_run"] = {"driver": NO_RUN, "evaluator": NO_RUN}
        state["run_created"] = set()
        state["fault_effective"][generation] = False
        state["workload_healthy"][generation] = True
        state["pod_gen"][generation] = 0
        state["quiescence_observed"][generation] = False
        state["oracle_state"] = "idle"
        state["oracle_run"] = NO_RUN
        state["oracle_stage"] = "none"
        if getattr(conductor, "submission_stage", None) != "setup":
            raise AssertionError("StartProblem must observe submission_stage='setup'")

    current.transition("StartProblem", {}, update)


def load_baseline_state() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        persisted = state["persisted_baseline"]
        state["baseline_resources"] = set(persisted["resources"])
        state["baseline_values"] = copy.deepcopy(persisted["values"])
        state["baseline_gen"] = state["persisted_baseline_gen"]
        state["baseline_complete"] = state["persisted_baseline_complete"]
        state["observed_fields"] = {"resources", "values"}
        state["baseline_capture_state"] = "captured"
        state["baseline_authoritative"] = True

    current.transition("LoadBaselineState", {}, update)


def begin_baseline_capture() -> None:
    current = recorder()
    if current is None:
        return
    current._baseline_field_ok = {"resources": True, "values": True}

    def update(state: dict[str, Any]) -> None:
        state["baseline_gen"] = state["cluster_gen"]
        state["baseline_complete"] = True
        state["observed_fields"] = set()
        state["baseline_resources"] = set()
        state["baseline_values"] = {resource: "clean" for resource in RESOURCES}
        state["baseline_capture_state"] = "capturing"

    current.transition("BeginBaselineCapture", {}, update)


def baseline_getter_failed(field: str) -> None:
    current = recorder()
    if current is not None:
        with current.lock:
            current._baseline_field_ok[field] = False


def observe_baseline(field: str) -> None:
    current = recorder()
    if current is None:
        return
    ok = bool(current._baseline_field_ok[field])

    def update(state: dict[str, Any]) -> None:
        state["observed_fields"].add(field)
        state["baseline_complete"] = state["baseline_complete"] and ok
        if field == "resources" and ok:
            state["baseline_resources"] = set(state["cluster_resources"])
        if field == "values" and ok:
            state["baseline_values"] = copy.deepcopy(state["resource_value"])

    current.transition("ObserveBaseline", {"field": field, "ok": ok}, update)


def persist_baseline_state() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        state["persisted_baseline"] = {
            "exists": True,
            "resources": set(state["baseline_resources"]),
            "values": copy.deepcopy(state["baseline_values"]),
        }
        state["persisted_baseline_gen"] = state["baseline_gen"]
        state["persisted_baseline_complete"] = state["baseline_complete"]
        state["baseline_capture_state"] = "captured"
        state["baseline_authoritative"] = True

    current.transition("PersistBaselineState", {}, update)


def deploy_problem(conductor: Any) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        generation = state["run_gen"]
        already_present = RUN_RESOURCE in state["cluster_resources"]
        state["deployed_run"] = generation
        state["cluster_resources"].add(RUN_RESOURCE)
        if not already_present:
            state["run_created"].add(RUN_RESOURCE)
            state["resource_value"][RUN_RESOURCE] = "clean"
        if getattr(conductor, "submission_stage", None) != "setup":
            raise AssertionError("DeployProblem must observe setup stage")

    current.transition("DeployProblem", {}, update)


def inject_fault(conductor: Any) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        generation = state["run_gen"]
        state["fault_injected_runs"].add(generation)
        state["fault_effective"][generation] = True
        state["workload_healthy"][generation] = False
        state["reinjection_active"].add(generation)
        if not bool(getattr(conductor, "fault_injected", False)):
            raise AssertionError("InjectFault must observe fault_injected=True")

    current.transition("InjectFault", {}, update)


def advance_to_first_stage(conductor: Any) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        generation = state["run_gen"]
        state["stage"] = "diagnosis"
        state["stage_owner"] = generation
        state["run_stage"][generation] = "diagnosis"
        state["max_stage_rank"][generation] = STAGE_RANK["diagnosis"]
        state["waiting_for_agent"] = True
        if getattr(conductor, "submission_stage", None) != "diagnosis":
            raise AssertionError("the modeled first stage must be diagnosis")

    current.transition("AdvanceToFirstStage", {}, update)


def send_submission(request_id: str | None = None) -> str:
    current = recorder()
    if current is None:
        return request_id or new_request_id()
    request_id = request_id or current.next_request_id()
    current.declared_request(request_id)

    def update(state: dict[str, Any]) -> None:
        message = {
            "requestId": request_id,
            "originRun": state["run_gen"],
            "originStage": state["stage"],
        }
        state["submission_queue"].append(message)
        state["request_status"][request_id] = "queued"
        state["request_origin_run"][request_id] = state["run_gen"]
        state["request_origin_stage"][request_id] = state["stage"]

    current.transition("SendSubmission", {"request_id": request_id}, update)
    return request_id


def delay_or_duplicate(request_id: str | None = None, queue_index: int | None = None) -> int:
    current = recorder()
    if current is None:
        return queue_index or 1
    with current.lock:
        queue = current.state["submission_queue"]
        if queue_index is None:
            queue_index = next(
                index
                for index, message in enumerate(queue, start=1)
                if request_id is None or message["requestId"] == request_id
            )

    def update(state: dict[str, Any]) -> None:
        state["submission_queue"].append(copy.deepcopy(state["submission_queue"][queue_index - 1]))

    current.transition(
        "DelayOrDuplicate",
        {
            "queue_index": queue_index,
            "request_id": request_id
            or current.state["submission_queue"][queue_index - 1]["requestId"],
        },
        update,
    )
    return queue_index


def receive_submission(request_id: str | None = None, queue_index: int | None = None) -> tuple[str, int]:
    current = recorder()
    if current is None:
        return request_id or NO_REQUEST, 1
    with current.lock:
        queue = current.state["submission_queue"]
        if queue_index is None:
            queue_index = next(
                index
                for index, message in enumerate(queue, start=1)
                if request_id is None or message["requestId"] == request_id
            )
        selected_id = queue[queue_index - 1]["requestId"]
        received_index = len(current.state["received_queue"]) + 1

    def update(state: dict[str, Any]) -> None:
        message = _remove_at(state["submission_queue"], queue_index)
        state["received_queue"].append(message)
        state["request_status"][message["requestId"]] = "received"

    current.transition(
        "ReceiveSubmission",
        {"queue_index": queue_index, "request_id": selected_id},
        update,
    )
    return selected_id, received_index


@contextlib.contextmanager
def received_submission_context(request_id: str | None = None) -> Iterator[str | None]:
    current = recorder()
    if current is None:
        yield request_id
        return
    claimed_id, received_index = receive_submission(request_id)
    with request_context(claimed_id, received_index):
        yield claimed_id


def _current_request(required: bool = True) -> tuple[str, int] | None:
    context = _request_context.get()
    if required and context is None:
        raise AssertionError("submission boundary has no trace request context")
    return context


def retry_submission() -> None:
    current = recorder()
    context = _current_request(required=current is not None)
    if current is None or context is None:
        return
    request_id, queue_index = context

    def update(state: dict[str, Any]) -> None:
        state["request_retries"][request_id] += 1

    current.transition(
        "RetrySubmission",
        {"queue_index": queue_index, "request_id": request_id},
        update,
    )


def conductor_submit_accept(conductor: Any) -> None:
    current = recorder()
    context = _current_request(required=current is not None)
    if current is None or context is None:
        return
    request_id, queue_index = context

    def update(state: dict[str, Any]) -> None:
        message = _remove_at(state["received_queue"], queue_index)
        state["pending_acks"].append(request_id)
        _append_unique(state["accepted_by_stage"], _acceptance(state, request_id))
        state["request_status"][request_id] = "accepted"
        state["waiting_for_agent"] = False
        state["eval_in_flight"] = True
        state["eval_run"] = state["run_gen"]
        state["eval_stage"] = state["stage"]
        state["eval_request"] = request_id
        state["eval_origin_run"] = message["originRun"]
        state["eval_origin_stage"] = message["originStage"]
        state["eval_phase"] = "accepted"
        if bool(getattr(conductor, "waiting_for_agent", True)):
            raise AssertionError("accepted submission must clear waiting_for_agent")

    current.transition(
        "ConductorSubmitAccept",
        {"queue_index": queue_index, "request_id": request_id},
        update,
    )


def conductor_submit_duplicate() -> None:
    current = recorder()
    context = _current_request(required=current is not None)
    if current is None or context is None:
        return
    request_id, queue_index = context

    def update(state: dict[str, Any]) -> None:
        _remove_at(state["received_queue"], queue_index)
        state["pending_acks"].append(request_id)
        state["request_status"][request_id] = "discarded"

    current.transition(
        "ConductorSubmitDuplicate",
        {"queue_index": queue_index, "request_id": request_id},
        update,
    )


def conductor_submit_late() -> None:
    current = recorder()
    context = _current_request(required=current is not None)
    if current is None or context is None:
        return
    request_id, queue_index = context

    def update(state: dict[str, Any]) -> None:
        _remove_at(state["received_queue"], queue_index)
        state["pending_acks"].append(request_id)
        state["request_status"][request_id] = "discarded"

    current.transition(
        "ConductorSubmitLate",
        {"queue_index": queue_index, "request_id": request_id},
        update,
    )


def acknowledge(request_id: str | None = None) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        acknowledged = _remove_at(state["pending_acks"], 1)
        state["request_status"][acknowledged] = "acked"

    params = {} if request_id is None else {"request_id": request_id}
    current.transition("Acknowledge", params, update)


def begin_evaluation() -> None:
    current = recorder()
    if current is None:
        return
    current.transition(
        "BeginEvaluation",
        {},
        lambda state: state.__setitem__("eval_phase", "stoppingNoise"),
    )


def begin_oracle() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        state["oracle_state"] = "evaluating"
        state["oracle_run"] = state["eval_run"]
        state["oracle_stage"] = state["eval_stage"]
        state["eval_phase"] = "oracleRunning"
        generation = state["eval_run"]
        state["quiescence_observed"][generation] = not state["active_noise"] and not state["apply_in_flight"]

    current.transition("BeginOracle", {}, update)


def complete_oracle(success: bool) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        generation = state["eval_run"]
        if (
            success
            and state["eval_stage"] == "mitigation"
            and not state["fault_effective"][generation]
            and state["workload_healthy"][generation]
        ):
            state["oracle_passed"].add(generation)
        state["oracle_state"] = "idle"
        state["oracle_run"] = NO_RUN
        state["oracle_stage"] = "none"
        state["eval_phase"] = "oracleComplete"

    current.transition("CompleteOracle", {}, update)


def complete_evaluation() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        generation = state["eval_run"]
        state["results_version"][generation] += 1
        acceptance = {
            "requestId": state["eval_request"],
            "originRun": state["eval_origin_run"],
            "originStage": state["eval_origin_stage"],
            "acceptedRun": generation,
            "acceptedStage": state["eval_stage"],
        }
        _append_unique(state["graded_acceptances"], acceptance)
        state["request_status"][state["eval_request"]] = "graded"
        state["eval_phase"] = "completed"

    current.transition("CompleteEvaluation", {}, update)


def advance_stage_after_evaluation(conductor: Any, evaluated_stage: str) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        if evaluated_stage == "diagnosis":
            generation = state["eval_run"]
            state["stage"] = "mitigation"
            state["stage_owner"] = generation
            state["run_stage"][generation] = "mitigation"
            state["max_stage_rank"][generation] = max(
                state["max_stage_rank"][generation], STAGE_RANK["mitigation"]
            )
            state["waiting_for_agent"] = True
            if getattr(conductor, "submission_stage", None) != "mitigation":
                raise AssertionError("diagnosis completion must expose mitigation")
        elif evaluated_stage == "mitigation":
            state["cleanup_state"]["evaluator"] = "requested"
            state["cleanup_run"]["evaluator"] = state["eval_run"]
        else:
            raise AssertionError(f"unexpected evaluated stage {evaluated_stage!r}")
        state["eval_phase"] = "advanced"

    current.transition("AdvanceStageAfterEvaluation", {}, update)


def finish_evaluation_future() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        state["eval_in_flight"] = False
        state["eval_run"] = NO_RUN
        state["eval_stage"] = "none"
        state["eval_request"] = NO_REQUEST
        state["eval_origin_run"] = NO_RUN
        state["eval_origin_stage"] = "none"
        state["eval_phase"] = "idle"

    current.transition("FinishEvaluationFuture", {}, update)


def agent_mitigate() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        generation = state["run_gen"]
        state["fault_effective"][generation] = False
        state["workload_healthy"][generation] = not state["active_noise"]

    current.transition("AgentMitigate", {}, update)


def agent_timeout(conductor: Any) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        generation = state["run_gen"]
        state["timeout_fired"].add(generation)
        state["results_version"][generation] += 1
        graded = {_record_key(record) for record in state["graded_acceptances"]}
        for acceptance in state["accepted_by_stage"]:
            if acceptance["acceptedRun"] == generation and _record_key(acceptance) not in graded:
                _append_unique(state["timed_out_acceptances"], acceptance)
        state["cleanup_state"]["driver"] = "requested"
        state["cleanup_run"]["driver"] = generation
        if not bool(getattr(conductor, "results", {}).get("timed_out")):
            raise AssertionError("AgentTimeout must observe written timeout results")

    current.transition("AgentTimeout", {}, update)


def agent_exit(eval_in_flight: bool) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        state["agent_exit_state"] = "waiting" if eval_in_flight else "expired"
        if not eval_in_flight:
            state["cleanup_state"]["driver"] = "requested"
            state["cleanup_run"]["driver"] = state["run_gen"]

    current.transition("AgentExit", {}, update)


def agent_exit_wait_timeout() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        state["agent_exit_state"] = "expired"
        state["cleanup_state"]["driver"] = "requested"
        state["cleanup_run"]["driver"] = state["run_gen"]

    current.transition("AgentExitWaitTimeout", {}, update)


def agent_exit_after_evaluation() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        state["agent_exit_state"] = "expired"
        state["cleanup_state"]["driver"] = "requested"
        state["cleanup_run"]["driver"] = state["run_gen"]

    current.transition("AgentExitAfterEvaluation", {}, update)


def finish_problem_check(actor: str, already_finishing: bool) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        state["cleanup_state"][actor] = "complete" if already_finishing else "checked"

    current.transition("FinishProblemCheck", {"actor": actor}, update)


def begin_cleanup(conductor: Any, actor: str) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        generation = state["run_gen"]
        state["cleanup_state"][actor] = "stoppingNoise"
        state["stage"] = "tearing_down"
        state["stage_owner"] = state["cleanup_run"][actor]
        state["run_stage"][generation] = "tearing_down"
        state["max_stage_rank"][generation] = max(
            state["max_stage_rank"][generation], STAGE_RANK["tearing_down"]
        )
        state["waiting_for_agent"] = False
        if getattr(conductor, "submission_stage", None) != "tearing_down":
            raise AssertionError("BeginCleanup must observe tearing_down")

    current.transition("BeginCleanup", {"actor": actor}, update)


def complete_recovery(actor: str) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        generation = state["run_gen"]
        state["cleanup_state"][actor] = "reconciling"
        if state["deployed_run"] == generation:
            state["deployed_run"] = NO_RUN
        state["fault_effective"][generation] = False
        state["workload_healthy"][generation] = not state["active_noise"]
        state["reinjection_active"].discard(generation)
        state["reattach_pending"].discard(generation)

    current.transition("CompleteRecovery", {"actor": actor}, update)


def reconcile_delete(resource: str, actor: str | None = None) -> None:
    current = recorder()
    if current is None:
        return
    actor = actor or current_cleanup_actor()
    with current.lock:
        # Many concrete Kubernetes objects collapse to one abstract identity.
        # Emit once for the identity class actually targeted.
        if resource not in current.state["cluster_resources"]:
            return

    def update(state: dict[str, Any]) -> None:
        ledger = {
            "run": state["cleanup_run"][actor],
            "resource": resource,
            "owned": resource in state["run_created"],
        }
        _append_unique(state["delete_issued"], ledger)
        state["cluster_resources"].discard(resource)

    current.transition(
        "ReconcileDelete",
        {"actor": actor, "resource": resource},
        update,
    )


def reconcile_restore(resource: str, actor: str | None = None) -> bool:
    current = recorder()
    if current is None:
        return False
    actor = actor or current_cleanup_actor()
    with current.lock:
        if current.state["resource_value"][resource] == current.state["baseline_values"][resource]:
            return False

    def update(state: dict[str, Any]) -> None:
        state["resource_value"][resource] = state["baseline_values"][resource]

    current.transition(
        "ReconcileRestore",
        {"actor": actor, "resource": resource},
        update,
    )
    return True


def complete_cleanup(conductor: Any, actor: str) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        generation = state["run_gen"]
        first_completion = generation not in state["done_runs"]
        state["cleanup_state"][actor] = "complete"
        state["stage"] = "done"
        state["stage_owner"] = state["cleanup_run"][actor]
        state["run_stage"][generation] = "done"
        state["max_stage_rank"][generation] = STAGE_RANK["done"]
        state["waiting_for_agent"] = False
        state["done_runs"].add(generation)
        if first_completion:
            state["done_results_version"][generation] = state["results_version"][generation]
        if getattr(conductor, "submission_stage", None) != "done":
            raise AssertionError("CompleteCleanup must observe done")

    current.transition("CompleteCleanup", {"actor": actor}, update)


def noise_manager_start(epoch: int) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        if epoch > current.max_noise_epoch:
            raise AssertionError("noise epoch exceeds Trace.cfg MaxNoiseEpoch")
        state["noise_epoch"] = epoch
        state["noise_run"] = state["run_gen"]
        state["noise_running"] = True
        state["live_noise_epochs"].add(epoch)
        state["noise_epoch_run"][epoch] = state["run_gen"]
        state["noise_loop_count"] += 1

    current.transition("NoiseManagerStart", {}, update)


def begin_noise_apply(epoch: int | None = None) -> bool:
    current = recorder()
    if current is None:
        return False
    epoch = epoch if epoch is not None else current_noise_epoch()
    with current.lock:
        # A model epoch abstracts one injection cycle, even though the concrete
        # catalog may apply multiple Chaos Mesh CRs in that same cycle.
        if epoch in current.state["apply_in_flight"] or epoch in current.state["active_noise"]:
            return False
    current.transition(
        "BeginNoiseApply",
        {},
        lambda state: state["apply_in_flight"].add(epoch),
    )
    return True


def complete_noise_apply(epoch: int | None = None) -> None:
    current = recorder()
    if current is None:
        return
    epoch = epoch if epoch is not None else current_noise_epoch()

    def update(state: dict[str, Any]) -> None:
        state["apply_in_flight"].discard(epoch)
        state["active_noise"].add(epoch)
        generation = state["noise_epoch_run"][epoch]
        state["workload_healthy"][generation] = False

    current.transition("CompleteNoiseApply", {"epoch": epoch}, update)


def noise_loop_exit(epoch: int | None = None) -> None:
    current = recorder()
    if current is None:
        return
    epoch = epoch if epoch is not None else current_noise_epoch()

    def update(state: dict[str, Any]) -> None:
        state["live_noise_epochs"].discard(epoch)
        state["noise_loop_count"] -= 1

    current.transition("NoiseLoopExit", {"epoch": epoch}, update)


def noise_manager_stop(owner: str | None = None) -> None:
    current = recorder()
    if current is None:
        return
    owner = owner or current_noise_owner()

    def update(state: dict[str, Any]) -> None:
        state["noise_running"] = False
        state["noise_stop_state"] = "joining"
        state["noise_stop_owner"] = owner

    current.transition("NoiseManagerStop", {"owner": owner}, update)


def noise_manager_join_complete() -> None:
    current = recorder()
    if current is None:
        return
    current.transition(
        "NoiseManagerJoinComplete",
        {},
        lambda state: state.__setitem__("noise_stop_state", "cleaning"),
    )


def noise_manager_join_timeout() -> None:
    current = recorder()
    if current is None:
        return
    current.transition(
        "NoiseManagerJoinTimeout",
        {},
        lambda state: state.__setitem__("noise_stop_state", "cleaning"),
    )


def _update_noise_health(state: dict[str, Any], affected_epochs: set[int]) -> None:
    affected_runs = {state["noise_epoch_run"][epoch] for epoch in affected_epochs}
    for generation in affected_runs:
        state["workload_healthy"][generation] = not state["fault_effective"][generation]


def noise_manager_cleanup_recorded() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        affected = set(state["active_noise"])
        state["active_noise"] = set()
        _update_noise_health(state, affected)
        state["noise_stop_state"] = "forceRemoving"

    current.transition("NoiseManagerCleanupRecorded", {}, update)


def noise_manager_force_remove() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        affected = set(state["active_noise"])
        state["active_noise"] = set()
        _update_noise_health(state, affected)
        state["noise_stop_state"] = "complete"

    current.transition("NoiseManagerForceRemove", {}, update)


def noise_manager_stop_return() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        owner = state["noise_stop_owner"]
        if owner == "evaluation":
            state["eval_phase"] = "oracleReady"
        elif owner in {"driver", "evaluator"}:
            state["cleanup_state"][owner] = "recovering"
        state["noise_stop_state"] = "idle"
        state["noise_stop_owner"] = "none"

    current.transition("NoiseManagerStopReturn", {}, update)


def agent_mutate(resource: str, kind: str) -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        if kind == "create":
            state["cluster_resources"].add(resource)
            state["run_created"].add(resource)
            state["resource_value"][resource] = "agent"
        elif kind == "overwrite":
            state["resource_value"][resource] = "agent"
        elif kind == "delete":
            state["cluster_resources"].discard(resource)
            state["run_created"].discard(resource)
        else:
            raise AssertionError(f"unknown mutation kind {kind!r}")

    current.transition(
        "AgentMutate",
        {"resource": resource, "kind": kind},
        update,
    )


def crash() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        state["process_up"] = False
        state["stage"] = "idle"
        state["stage_owner"] = NO_RUN
        state["waiting_for_agent"] = False
        state["agent_exit_state"] = "none"
        state["eval_in_flight"] = False
        state["eval_run"] = NO_RUN
        state["eval_stage"] = "none"
        state["eval_request"] = NO_REQUEST
        state["eval_origin_run"] = NO_RUN
        state["eval_origin_stage"] = "none"
        state["eval_phase"] = "idle"
        state["cleanup_state"] = {"driver": "idle", "evaluator": "idle"}
        state["cleanup_run"] = {"driver": NO_RUN, "evaluator": NO_RUN}
        state["submission_queue"] = []
        state["received_queue"] = []
        state["pending_acks"] = []
        state["baseline_gen"] = NO_RUN
        state["baseline_complete"] = False
        state["observed_fields"] = set()
        state["baseline_resources"] = set()
        state["baseline_values"] = {resource: "clean" for resource in RESOURCES}
        state["baseline_capture_state"] = "unchecked"
        state["baseline_authoritative"] = False
        state["noise_run"] = NO_RUN
        state["noise_running"] = False
        state["live_noise_epochs"] = set()
        state["noise_loop_count"] = 0
        state["apply_in_flight"] = set()
        state["noise_stop_state"] = "idle"
        state["noise_stop_owner"] = "none"
        state["reinjection_active"] = set()
        state["reattach_pending"] = set()
        state["oracle_state"] = "idle"
        state["oracle_run"] = NO_RUN
        state["oracle_stage"] = "none"

    current.transition("Crash", {}, update)


def restart_if_needed() -> None:
    current = recorder()
    if current is None:
        return
    with current.lock:
        needs_restart = not current.state["process_up"]
    if needs_restart:
        current.transition(
            "Restart",
            {},
            lambda state: state.__setitem__("process_up", True),
        )


def replace_cluster() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        state["cluster_gen"] += 1
        state["cluster_resources"] = set(RESOURCES)
        state["preexisting"] = set(RESOURCES)
        state["run_created"] = set()
        state["resource_value"] = {resource: "replacement" for resource in RESOURCES}
        state["pre_run_value"] = {resource: "replacement" for resource in RESOURCES}
        state["delete_issued"] = []
        state["deployed_run"] = NO_RUN
        state["active_noise"] = set()
        state["fault_effective"] = [False] * (current.max_run + 1)
        state["workload_healthy"] = [True] * (current.max_run + 1)
        state["pod_gen"] = [0] * (current.max_run + 1)
        state["reinjection_active"] = set()
        state["reattach_pending"] = set()

    current.transition("ReplaceCluster", {}, update)


def restart_pod() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        generation = state["run_gen"]
        state["fault_effective"][generation] = False
        state["workload_healthy"][generation] = True
        state["pod_gen"][generation] += 1
        state["reattach_pending"].add(generation)

    current.transition("RestartPod", {}, update)


def reattach_fault() -> None:
    current = recorder()
    if current is None:
        return

    def update(state: dict[str, Any]) -> None:
        generation = state["run_gen"]
        state["fault_effective"][generation] = True
        state["workload_healthy"][generation] = False
        state["reattach_pending"].discard(generation)

    current.transition("ReattachFault", {}, update)
