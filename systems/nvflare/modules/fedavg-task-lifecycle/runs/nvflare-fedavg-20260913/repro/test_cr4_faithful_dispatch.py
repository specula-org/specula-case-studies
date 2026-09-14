from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace

from nvflare.apis.client import Client
from nvflare.apis.fl_component import FLComponent
from nvflare.apis.fl_constant import FLContextKey
from nvflare.apis.impl.wf_comm_server import WFCommServer
from nvflare.apis.signal import Signal
from nvflare.app_common.abstract.fl_model import FLModel
from nvflare.app_common.abstract.model import ModelLearnableKey
from nvflare.app_common.app_constant import AppConstants
from nvflare.app_common.app_event_type import AppEventType
from nvflare.app_common.utils.fl_model_utils import FLModelUtils
from nvflare.app_common.workflows.fedavg import FedAvg
from nvflare.fuel.utils import fobs
from nvflare.private.fed.server.run_manager import RunManager
from nvflare.private.fed.server.server_engine import ServerEngine


SOURCE_ROOT = Path(__file__).resolve().parents[1] / "source"
ORDINARY_HANDLER_ERROR = "simulated user event handler failure before sending train task"


class RecordingBeforeTrainHandler(FLComponent):
    def __init__(self, fail: bool = False):
        super().__init__()
        self.fail = fail
        self.events = []

    def handle_event(self, event_type: str, fl_ctx) -> None:
        self.events.append(event_type)
        if self.fail and event_type == AppEventType.BEFORE_TRAIN_TASK:
            raise RuntimeError(ORDINARY_HANDLER_ERROR)


class StaticClientManager:
    def __init__(self, clients):
        self._clients = {c.name: c for c in clients}

    def get_clients(self):
        return self._clients

    def has_relays(self):
        return False

    def get_all_clients_from_inputs(self, client_names):
        found = []
        missing = []
        for name in client_names or []:
            client = self._clients.get(name)
            if client:
                found.append(client)
            else:
                missing.append(name)
        return found, missing


class LocalWorkspace:
    def __init__(self, root: Path, job_id: str):
        self.root = root
        self.job_id = job_id
        self.run_dir = root / "run"
        self.app_dir = root / "app"
        self.meta_path = root / f"{job_id}_meta.json"
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.app_dir.mkdir(parents=True, exist_ok=True)
        self.meta_path.write_text(json.dumps({}), encoding="utf-8")

    def get_job_meta_path(self, job_id: str) -> str:
        return str(self.meta_path)

    def get_app_dir(self, job_id: str) -> str:
        return str(self.app_dir)

    def get_run_dir(self, job_id: str) -> str:
        return str(self.run_dir)


@dataclass
class Runtime:
    engine: ServerEngine
    run_manager: RunManager
    workspace: LocalWorkspace
    clients: list[Client]


def wait_until(label: str, predicate, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {label}")


def assert_clean_source_imports():
    import nvflare
    import nvflare.apis.impl.wf_comm_server as wf_comm_server
    import nvflare.apis.utils.event as event_utils
    import nvflare.app_common.workflows.fedavg as fedavg
    import nvflare.private.event as private_event
    import nvflare.private.fed.server.run_manager as run_manager
    import nvflare.private.fed.server.server_engine as server_engine

    for module in [
        nvflare,
        event_utils,
        private_event,
        server_engine,
        run_manager,
        wf_comm_server,
        fedavg,
    ]:
        module_path = Path(module.__file__).resolve()
        assert str(module_path).startswith(str(SOURCE_ROOT.resolve())), module_path


def build_runtime(tmp_path: Path, handlers: list[FLComponent]) -> Runtime:
    job_id = "job-cr4"
    clients = [Client(name="site-1", token="token-1")]
    client_manager = StaticClientManager(clients)
    args = SimpleNamespace(set=[], workspace=str(tmp_path))
    engine = ServerEngine(
        server=SimpleNamespace(),
        args=args,
        client_manager=client_manager,
        snapshot_persistor=None,
        workers=1,
    )
    workspace = LocalWorkspace(tmp_path, job_id)
    run_manager = RunManager(
        server_name="server",
        engine=engine,
        job_id=job_id,
        workspace=workspace,
        components={},
        client_manager=client_manager,
        handlers=list(handlers),
    )
    engine.set_run_manager(run_manager)
    return Runtime(engine=engine, run_manager=run_manager, workspace=workspace, clients=clients)


def shutdown_runtime(runtime: Runtime, communicator: WFCommServer | None = None, fl_ctx=None) -> None:
    if communicator is not None:
        communicator.finalize_run(fl_ctx or runtime.engine.new_context())
        communicator._task_monitor.join(timeout=2.0)
    runtime.engine.executor.shutdown(wait=True, cancel_futures=True)


def exception_summary(fl_ctx, handler: RecordingBeforeTrainHandler):
    exceptions = fl_ctx.get_prop(FLContextKey.EXCEPTIONS) or {}
    exc = exceptions.get(handler.name)
    return {
        "has_exceptions": bool(exceptions),
        "handler_recorded": handler.name in exceptions,
        "exception_type": type(exc).__name__ if exc else None,
        "exception_message": str(exc) if exc else None,
    }


def test_production_event_dispatch_records_normal_and_ordinary_handler_error(tmp_path):
    assert_clean_source_imports()

    normal_handler = RecordingBeforeTrainHandler(fail=False)
    normal_runtime = build_runtime(tmp_path / "normal", [normal_handler])
    try:
        normal_ctx = normal_runtime.engine.new_context()
        normal_runtime.engine.fire_event(AppEventType.BEFORE_TRAIN_TASK, normal_ctx)
        normal_observed = {
            "events_seen": list(normal_handler.events),
            "exceptions": normal_ctx.get_prop(FLContextKey.EXCEPTIONS),
        }
        print(f"OBSERVED normal_dispatch={normal_observed}")
        assert normal_handler.events == [AppEventType.BEFORE_TRAIN_TASK]
        assert normal_ctx.get_prop(FLContextKey.EXCEPTIONS) is None
    finally:
        shutdown_runtime(normal_runtime)

    failing_handler = RecordingBeforeTrainHandler(fail=True)
    failing_runtime = build_runtime(tmp_path / "failing", [failing_handler])
    try:
        failing_ctx = failing_runtime.engine.new_context()
        failing_runtime.engine.fire_event(AppEventType.BEFORE_TRAIN_TASK, failing_ctx)
        observed = exception_summary(failing_ctx, failing_handler)
        print(f"OBSERVED failing_dispatch={observed}")
        assert failing_handler.events == [AppEventType.BEFORE_TRAIN_TASK]
        assert observed == {
            "has_exceptions": True,
            "handler_recorded": True,
            "exception_type": "RuntimeError",
            "exception_message": ORDINARY_HANDLER_ERROR,
        }
    finally:
        shutdown_runtime(failing_runtime)


def test_train_task_remains_assignable_after_ordinary_handler_error(tmp_path):
    assert_clean_source_imports()
    failing_handler = RecordingBeforeTrainHandler(fail=True)
    runtime = build_runtime(tmp_path, [failing_handler])
    communicator = WFCommServer(task_check_period=0.02)
    fl_ctx = runtime.engine.new_context()
    try:
        controller = FedAvg(
            num_clients=1,
            num_rounds=1,
            task_check_period=0.02,
            model={"w": 10.0},
            persistor_id="",
            save_filename="FL_global_model.pt",
        )
        controller.set_communicator(communicator)
        controller.initialize(fl_ctx)
        communicator.initialize_run(fl_ctx)

        model = FLModel(params={"w": 10.0}, current_round=0, total_rounds=1)
        controller.send_model(
            task_name=AppConstants.TASK_TRAIN,
            targets=[runtime.clients[0].name],
            data=model,
            callback=lambda _: True,
        )
        wait_until("scheduled train task", lambda: controller.get_num_standing_tasks() == 1)

        request_ctx = runtime.engine.new_context()
        task_name, task_id, task_data = communicator.process_task_request(runtime.clients[0], request_ctx)
        with communicator._task_lock:
            task_statuses = [task.completion_status for task in communicator._tasks]
            outstanding_ids = list(communicator._client_task_map)

        observed = {
            "task_name": task_name,
            "task_id_present": bool(task_id),
            "task_data_present": task_data is not None,
            "task_statuses": [str(status) for status in task_statuses],
            "standing_tasks": controller.get_num_standing_tasks(),
            "outstanding_client_task_count": len(outstanding_ids),
            "event_error": exception_summary(request_ctx, failing_handler),
        }
        print(f"OBSERVED assignable_after_error={observed}")

        assert task_name == AppConstants.TASK_TRAIN
        assert task_id
        assert task_data is not None
        assert task_statuses == [None]
        assert controller.get_num_standing_tasks() == 1
        assert len(outstanding_ids) == 1
        assert observed["event_error"]["exception_type"] == "RuntimeError"
        assert observed["event_error"]["exception_message"] == ORDINARY_HANDLER_ERROR
    finally:
        shutdown_runtime(runtime, communicator=communicator, fl_ctx=fl_ctx)


def test_complete_fedavg_round_accepts_valid_contribution_despite_contained_handler_error(tmp_path):
    assert_clean_source_imports()
    failing_handler = RecordingBeforeTrainHandler(fail=True)
    runtime = build_runtime(tmp_path, [failing_handler])
    communicator = WFCommServer(task_check_period=0.02)
    run_ctx = runtime.engine.new_context()
    abort_signal = Signal()
    run_errors = []
    runner = None

    try:
        controller = FedAvg(
            num_clients=1,
            num_rounds=1,
            task_check_period=0.02,
            model={"w": 10.0},
            persistor_id="",
            save_filename="FL_global_model.pt",
        )
        controller.set_communicator(communicator)
        controller.initialize(run_ctx)
        communicator.initialize_run(run_ctx)

        def run_controller():
            try:
                controller.control_flow(abort_signal, run_ctx)
            except BaseException as exc:
                run_errors.append(exc)

        runner = threading.Thread(target=run_controller, name="fedavg-control-flow")
        runner.start()
        wait_until("FedAvg broadcast task to be scheduled", lambda: controller.get_num_standing_tasks() == 1)

        request_ctx = runtime.engine.new_context()
        task_name, task_id, task_data = communicator.process_task_request(runtime.clients[0], request_ctx)
        with communicator._task_lock:
            task_status_after_request = [task.completion_status for task in communicator._tasks]

        contribution = FLModel(
            params={"w": 20.0},
            metrics={"loss": 0.25},
            current_round=0,
            total_rounds=1,
        )
        contribution_shareable = FLModelUtils.to_shareable(contribution)
        submission_ctx = runtime.engine.new_context()
        communicator.process_submission(
            runtime.clients[0],
            task_name,
            task_id,
            contribution_shareable,
            submission_ctx,
        )

        wait_until("completed task to be removed", lambda: controller.get_num_standing_tasks() == 0)
        runner.join(timeout=5.0)
        if runner.is_alive():
            abort_signal.trigger(True)
            raise AssertionError("FedAvg control_flow did not return")
        if run_errors:
            raise AssertionError(f"FedAvg control_flow raised unexpectedly: {run_errors[0]!r}")

        saved_path = runtime.workspace.run_dir / "FL_global_model.pt"
        saved_model = fobs.loadf(str(saved_path))
        global_model = controller.fl_ctx.get_prop(AppConstants.GLOBAL_MODEL)
        aggregation_stats = controller.fl_ctx.get_prop(AppConstants.AGGREGATION_STATS)

        observed = {
            "task_name": task_name,
            "task_id_present": bool(task_id),
            "task_data_present": task_data is not None,
            "task_status_after_request": [str(status) for status in task_status_after_request],
            "request_event_error": exception_summary(request_ctx, failing_handler),
            "standing_tasks_after_monitor": controller.get_num_standing_tasks(),
            "fedavg_received_count": controller._received_count,
            "aggregation_stats": aggregation_stats,
            "global_model_weights": global_model[ModelLearnableKey.WEIGHTS],
            "saved_model_params": saved_model.params,
        }
        print(f"OBSERVED complete_round={observed}")

        assert task_name == AppConstants.TASK_TRAIN
        assert task_id
        assert task_data is not None
        assert task_status_after_request == [None]
        assert observed["request_event_error"]["exception_type"] == "RuntimeError"
        assert controller._received_count == 1
        assert aggregation_stats["accepted_contributions"] == 1
        assert aggregation_stats["contributors"] == [runtime.clients[0].name]
        assert global_model[ModelLearnableKey.WEIGHTS] == {"w": 20.0}
        assert saved_model.params == {"w": 20.0}
    finally:
        if runner and runner.is_alive():
            abort_signal.trigger(True)
            runner.join(timeout=2.0)
        shutdown_runtime(runtime, communicator=communicator, fl_ctx=controller.fl_ctx if "controller" in locals() else run_ctx)
