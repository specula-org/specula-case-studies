#!/usr/bin/env python3
"""CR-4 lifecycle/resource-accounting confirmation probe.

This script exercises the current NVFlare head through normal scheduler,
resource-manager, client start, client abort, child-exit cleanup, and terminal
outcome paths. It intentionally asserts the suspected bad states directly:
early allocation to a second job, duplicate free, omitted free, and stale
outcome mutation of another job's pending outcome.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import time
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch


SPEC_OUTPUT = Path(__file__).resolve().parents[1]
WORKTREE = SPEC_OUTPUT / "confirmation" / "CR-4" / "worktree"
sys.path.insert(0, str(WORKTREE))

from nvflare.apis.client import Client
from nvflare.apis.event_type import EventType
from nvflare.apis.fl_constant import FLContextKey, JobConstants, RunProcessKey, SystemComponents
from nvflare.apis.fl_context import FLContext, FLContextManager
from nvflare.apis.job_def import Job
from nvflare.apis.job_launcher_spec import JobHandleSpec, JobLauncherSpec, JobReturnCode, add_launcher
from nvflare.apis.resource_manager_spec import ResourceConsumerSpec
from nvflare.apis.server_engine_spec import ServerEngineSpec
from nvflare.apis.workspace import Workspace
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler
from nvflare.app_common.resource_managers.list_resource_manager import ListResourceManager
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey
from nvflare.fuel.f3.cellnet.defs import ReturnCode as F3ReturnCode
from nvflare.fuel.f3.cellnet.fqcn import FQCN
from nvflare.private.admin_defs import Message as AdminMessage
from nvflare.private.defs import CellMessageHeaderKeys, JobFailureMsgKey, RequestHeader, TrainingTopic, new_cell_message
from nvflare.private.fed.client.client_engine import ClientEngine
from nvflare.private.fed.client.client_engine_internal_spec import ClientEngineInternalSpec
from nvflare.private.fed.client.client_executor import JobExecutor
from nvflare.private.fed.client.client_status import ClientStatus
from nvflare.private.fed.client.scheduler_cmds import CheckResourceProcessor, StartJobProcessor
from nvflare.private.fed.server.fed_server import FederatedServer
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.scheduler_constants import ShareableHeader
from nvflare.security.study_registry import StudyRegistryService


EVENTS: list[str] = []


def assert_equal(actual, expected, label: str):
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def assert_true(condition: bool, label: str):
    if not condition:
        raise AssertionError(label)


class CountingListResourceManager(ListResourceManager):
    def __init__(self, resources: dict, expiration_period: int = 30):
        super().__init__(resources=resources, expiration_period=expiration_period)
        self.check_calls = []
        self.allocate_calls = []
        self.cancel_calls = []
        self.free_calls = []

    def check_resources(self, resource_requirement: dict, fl_ctx: FLContext):
        result = super().check_resources(resource_requirement, fl_ctx)
        self.check_calls.append((resource_requirement.copy(), result))
        return result

    def allocate_resources(self, resource_requirement: dict, token: str, fl_ctx: FLContext) -> dict:
        result = super().allocate_resources(resource_requirement, token, fl_ctx)
        self.allocate_calls.append((resource_requirement.copy(), token, _copy_resources(result)))
        EVENTS.append(f"allocate:{token}:{result}")
        return result

    def cancel_resources(self, resource_requirement: dict, token: str, fl_ctx: FLContext):
        self.cancel_calls.append((resource_requirement.copy(), token))
        EVENTS.append(f"cancel:{token}")
        return super().cancel_resources(resource_requirement, token, fl_ctx)

    def free_resources(self, resources: dict, token: str, fl_ctx: FLContext):
        self.free_calls.append((_copy_resources(resources), token))
        EVENTS.append(f"free:{token}:{resources}")
        return super().free_resources(resources, token, fl_ctx)


def _copy_resources(resources: dict | None):
    if not resources:
        return resources
    return {k: list(v) if isinstance(v, list) else v for k, v in resources.items()}


class RecordingConsumer(ResourceConsumerSpec):
    def __init__(self):
        self.consumed = []

    def consume(self, resources: dict):
        self.consumed.append(_copy_resources(resources))
        EVENTS.append(f"consume:{resources}")


class Site:
    def __init__(self, name: str, resource_manager):
        self.name = name
        self.resource_manager = resource_manager


class NullJobManager:
    def set_status(self, job_id: str, status: str, fl_ctx: FLContext):
        EVENTS.append(f"job_manager_status:{job_id}:{status}")

    def get_app(self, job: Job, app_name: str, fl_ctx: FLContext) -> bytes:
        return b""

    def get_jobs_to_schedule(self, fl_ctx: FLContext) -> list[Job]:
        return []

    def refresh_meta(self, job: Job, meta_keys: list, fl_ctx: FLContext):
        EVENTS.append(f"refresh_meta:{job.job_id}:{meta_keys}")

    def get_job(self, job_id: str, fl_ctx: FLContext) -> Job | None:
        return None

    def clone_job(self, from_jid: str, meta: dict, fl_ctx: FLContext) -> str | None:
        return None


class SchedulerServerEngine(ServerEngineSpec):
    def __init__(self, sites: dict[str, Site]):
        self.sites = sites
        self.ctx_mgr = FLContextManager(engine=self, identity_name="server", job_id="server")
        self.job_manager = NullJobManager()
        self.events = []

    def fire_event(self, event_type: str, fl_ctx: FLContext):
        self.events.append(event_type)

    def get_clients(self) -> list[Client]:
        return [Client(name=name, token=f"token-{name}") for name in self.sites]

    def sync_clients_from_main_process(self):
        return None

    def update_job_run_status(self):
        return None

    def new_context(self) -> FLContext:
        return self.ctx_mgr.new_context()

    def get_workspace(self):
        return None

    def add_component(self, component_id: str, component):
        if component_id == SystemComponents.JOB_MANAGER:
            self.job_manager = component

    def get_component(self, component_id: str) -> object:
        if component_id == SystemComponents.JOB_MANAGER:
            return self.job_manager
        return None

    def register_aux_message_handler(self, topic: str, message_handle_func):
        return None

    def send_aux_request(self, targets: [], topic: str, request, timeout: float, fl_ctx: FLContext, optional=False, secure=False) -> dict:
        return {}

    def multicast_aux_requests(self, topic: str, target_requests, timeout: float, fl_ctx: FLContext, optional: bool = False, secure: bool = False) -> dict:
        return {}

    def get_widget(self, widget_id: str):
        return None

    def persist_components(self, fl_ctx: FLContext, completed: bool):
        return None

    def restore_components(self, snapshot, fl_ctx: FLContext):
        return None

    def start_client_job(self, job, client_sites, fl_ctx: FLContext):
        return []

    def check_client_resources(self, job: Job, resource_reqs: dict[str, dict], fl_ctx: FLContext) -> dict[str, tuple[bool, str | None]]:
        results = {}
        for site_name, req in resource_reqs.items():
            results[site_name] = self.sites[site_name].resource_manager.check_resources(req, fl_ctx)
        return results

    def cancel_client_resources(self, resource_check_results: dict[str, tuple[bool, str]], resource_reqs: dict[str, dict], fl_ctx: FLContext):
        for site_name, (ok, token) in resource_check_results.items():
            if ok and token:
                self.sites[site_name].resource_manager.cancel_resources(resource_reqs[site_name], token, fl_ctx)

    def get_client_name_from_token(self, token: str) -> str:
        return token.replace("token-", "")

    def validate_targets(self, target_names: list[str]) -> tuple[list, list[str]]:
        return target_names, []


class BlockingJobHandle(JobHandleSpec):
    def __init__(self):
        self.wait_entered = threading.Event()
        self.release = threading.Event()
        self.terminated = 0
        self.heartbeat_terminations = 0
        self.return_code = JobReturnCode.ABORTED

    def terminate(self, heartbeat_cleanup=False):
        self.terminated += 1
        if heartbeat_cleanup:
            self.heartbeat_terminations += 1
        EVENTS.append(f"terminate:heartbeat={heartbeat_cleanup}")
        self.release.set()

    def poll(self):
        if self.release.is_set():
            return self.return_code
        return None

    def wait(self):
        self.wait_entered.set()
        assert_true(self.release.wait(2.0), "child waiter never observed release")
        return self.return_code


class FakeLauncher(JobLauncherSpec):
    def __init__(self, handle: BlockingJobHandle):
        super().__init__()
        self.handle = handle

    def launch_job(self, job_meta: dict, fl_ctx: FLContext) -> JobHandleSpec:
        EVENTS.append(f"launch:{job_meta[JobConstants.JOB_ID]}")
        return self.handle


class FakeCell:
    def __init__(self):
        self.fire_and_forget_calls = []

    def get_internal_listener_url(self):
        return "tcp://parent:8002"

    def get_internal_listener_params(self):
        return {}

    def get_fqcn(self):
        return "site-1"

    def fire_and_forget(self, **kwargs):
        self.fire_and_forget_calls.append(kwargs)
        EVENTS.append(f"fire_and_forget:{kwargs.get('topic')}")


class OutcomeClient:
    def __init__(self):
        self.client_name = "site-1"
        self.token = "token-site-1"
        self.token_signature = "sig-site-1"
        self.ssid = "ssid-1"
        self.cell = FakeCell()
        self.engine = None
        self.sent_outcomes = []
        self.multi_gpu = False

    def send_request_before_shutdown(self, target, channel, topic, request, timeout, optional=True):
        payload = request.payload
        self.sent_outcomes.append((target, channel, topic, payload))
        EVENTS.append(f"outcome:{payload}")
        return new_cell_message({MessageHeaderKey.RETURN_CODE: F3ReturnCode.OK}, None)


class FakeClientEngine(ClientEngineInternalSpec):
    def __init__(self, workspace: Workspace, resource_manager: CountingListResourceManager, launcher: FakeLauncher, consumer: RecordingConsumer):
        self.client = OutcomeClient()
        self.client.engine = self
        self.args = SimpleNamespace(workspace=workspace.get_root_dir(), set=[])
        self.rank = 0
        self.client_executor = JobExecutor(client=self.client, startup=workspace.get_startup_kit_dir())
        self.resource_manager = resource_manager
        self.consumer = consumer
        self.launcher = launcher
        self.workspace = workspace
        self.ctx_mgr = FLContextManager(engine=self, identity_name="site-1", job_id="")
        self.events = []
        self.logger = MagicMock()

    def fire_event(self, event_type: str, fl_ctx: FLContext):
        self.events.append(event_type)
        EVENTS.append(f"event:{event_type}")
        if event_type == EventType.BEFORE_JOB_LAUNCH:
            add_launcher(self.launcher, fl_ctx)

    def new_context(self) -> FLContext:
        ctx = self.ctx_mgr.new_context()
        ctx.set_prop(FLContextKey.WORKSPACE_OBJECT, self.workspace, private=True, sticky=False)
        ctx.set_prop(FLContextKey.SERVER_CONFIG, [{"service": {"scheme": "grpc", "target": "parent:8002"}}], private=True, sticky=False)
        return ctx

    def add_component(self, component_id: str, component):
        if component_id == SystemComponents.RESOURCE_MANAGER:
            self.resource_manager = component
        elif component_id == SystemComponents.RESOURCE_CONSUMER:
            self.consumer = component

    def get_component(self, component_id: str) -> object:
        if component_id == SystemComponents.RESOURCE_MANAGER:
            return self.resource_manager
        if component_id == SystemComponents.RESOURCE_CONSUMER:
            return self.consumer
        return None

    def get_engine_status(self):
        return None

    def get_client_name(self) -> str:
        return self.client.client_name

    def deploy_app(self, app_name: str, job_id: str, job_meta: dict, client_name: str, app_data) -> str:
        return ""

    def start_app(self, job_id: str, job_meta: dict, allocated_resource=None, token=None, resource_manager=None) -> str:
        return ClientEngine.start_app(self, job_id, job_meta, allocated_resource, token, resource_manager)

    def notify_job_status(self, job_id: str, job_status):
        self.client_executor.notify_job_status(job_id, job_status)

    def abort_app(self, job_id: str, heartbeat_cleanup: bool = False) -> str:
        return ClientEngine.abort_app(self, job_id, heartbeat_cleanup=heartbeat_cleanup)

    def abort_task(self, job_id: str) -> str:
        return ""

    def delete_run(self, job_id: str) -> str:
        return ""

    def shutdown(self) -> str:
        return ""

    def restart(self) -> str:
        return ""

    def get_all_job_ids(self) -> []:
        return self.client_executor.get_run_processes_keys()


def make_job(job_id: str) -> Job:
    return Job(
        job_id=job_id,
        resource_spec={"site-1": {"gpu": 1}},
        deploy_map={"app": ["server", "site-1"]},
        min_sites=1,
        required_sites=["site-1"],
        meta={"submit_time": 0.0},
    )


def make_workspace(root: Path, job_id: str, job_meta: dict) -> Workspace:
    (root / "startup").mkdir(parents=True, exist_ok=True)
    (root / "local").mkdir(parents=True, exist_ok=True)
    workspace = Workspace(str(root), site_name="site-1")
    Path(workspace.get_app_config_dir(job_id)).mkdir(parents=True, exist_ok=True)
    Path(workspace.get_job_meta_path(job_id)).parent.mkdir(parents=True, exist_ok=True)
    with open(workspace.get_job_meta_path(job_id), "w", encoding="utf-8") as f:
        json.dump(job_meta, f)
    return workspace


def schedule(scheduler: DefaultJobScheduler, engine: SchedulerServerEngine, jobs: list[Job]):
    with engine.new_context() as fl_ctx:
        return scheduler.schedule_job(engine.job_manager, jobs, fl_ctx)


def level0_scheduler_does_not_reallocate_before_physical_free():
    EVENTS.clear()
    rm = CountingListResourceManager({"gpu": ["gpu0"]})
    engine = SchedulerServerEngine({"site-1": Site("site-1", rm)})
    scheduler = DefaultJobScheduler(max_jobs=1, max_schedule_count=5, min_schedule_interval=0.0)
    StudyRegistryService.reset()

    job1 = make_job("job-1")
    job2 = make_job("job-2")

    ready, dispatch = schedule(scheduler, engine, [job1])
    assert_equal(ready.job_id, "job-1", "job-1 first schedule")
    token1 = dispatch["site-1"].token
    allocated = rm.allocate_resources(dispatch["site-1"].resource_requirements, token1, engine.new_context())
    assert_equal(allocated, {"gpu": ["gpu0"]}, "job-1 allocation")
    assert_equal(rm.report_resources(engine.new_context())["resources"], {"gpu": []}, "free pool while job-1 is active")

    with engine.new_context() as fl_ctx:
        fl_ctx.set_prop(FLContextKey.CURRENT_JOB_ID, "job-1", private=True, sticky=True)
        scheduler.handle_event(EventType.JOB_STARTED, fl_ctx)
        scheduler.handle_event(EventType.JOB_COMPLETED, fl_ctx)
    assert_equal(scheduler.scheduled_jobs, [], "scheduler logical membership after completion event")

    ready2, dispatch2 = schedule(scheduler, engine, [job2])
    assert_true(ready2 is None and dispatch2 is None, "job-2 scheduled before job-1 physical free")
    assert_equal(rm.report_resources(engine.new_context())["resources"], {"gpu": []}, "free pool after premature job-2 attempt")
    assert_equal(len(rm.free_calls), 0, "no cleanup free before child waiter")

    rm.free_resources(allocated, token1, engine.new_context())
    ready3, dispatch3 = schedule(scheduler, engine, [job2])
    assert_equal(ready3.job_id, "job-2", "job-2 schedule after physical free")
    assert_true(dispatch3["site-1"].token, "job-2 received new reservation token")

    print(
        "LEVEL 0 PASS: scheduler logical JOB_COMPLETED removed job-1 from scheduled_jobs, "
        "but ListResourceManager kept gpu0 unavailable until free_resources; job-2 was not admitted early."
    )


def level1_client_cleanup_owns_free_after_child_exit():
    EVENTS.clear()
    with tempfile.TemporaryDirectory(prefix="cr4-client-") as td:
        job_id = "job-1"
        job_meta = {JobConstants.JOB_ID: job_id}
        workspace = make_workspace(Path(td), job_id, job_meta)
        rm = CountingListResourceManager({"gpu": ["gpu0"]})
        consumer = RecordingConsumer()
        handle = BlockingJobHandle()
        launcher = FakeLauncher(handle)
        engine = FakeClientEngine(workspace, rm, launcher, consumer)

        check_req = AdminMessage(topic=TrainingTopic.CHECK_RESOURCE, body={"gpu": 1})
        check_req.set_header(RequestHeader.JOB_ID, job_id)
        check_reply = CheckResourceProcessor().process(check_req, engine)
        token = check_reply.body.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN)
        assert_true(check_reply.body.get_header(ShareableHeader.IS_RESOURCE_ENOUGH), "resource check succeeded")
        assert_true(token, "reservation token returned")

        start_req = AdminMessage(topic=TrainingTopic.START_JOB, body={"gpu": 1})
        start_req.set_header(RequestHeader.JOB_ID, job_id)
        start_req.set_header(RequestHeader.JOB_META, job_meta.copy())
        start_req.set_header(ShareableHeader.RESOURCE_RESERVE_TOKEN, token)
        start_reply = StartJobProcessor().process(start_req, engine)
        assert_equal(start_reply.body, "Start the client app...", "start reply")
        assert_true(handle.wait_entered.wait(2.0), "cleanup waiter started")

        assert_equal(rm.report_resources(engine.new_context())["resources"], {"gpu": []}, "resource remains unavailable before child exit")
        assert_equal(rm.free_calls, [], "no free before child exit")
        assert_true(job_id in engine.client_executor.get_run_processes_keys(), "process still registered before child exit")

        engine.notify_job_status(job_id, ClientStatus.STOPPED)
        with (
            patch("nvflare.private.fed.client.client_executor.time.time", side_effect=[0.0, 0.0, 10.1]),
            patch("nvflare.private.fed.client.client_executor.time.sleep", return_value=None),
        ):
            abort_result = engine.abort_app(job_id, heartbeat_cleanup=True)

        assert_equal(abort_result, "Abort signal has been sent to the client App.", "registered STOPPED abort result")
        deadline = time.time() + 2.0
        while job_id in engine.client_executor.get_run_processes_keys() and time.time() < deadline:
            time.sleep(0.01)
        assert_true(job_id not in engine.client_executor.get_run_processes_keys(), "cleanup waiter removed process")

        assert_equal(len(rm.free_calls), 1, "exactly one physical free")
        assert_equal(rm.report_resources(engine.new_context())["resources"], {"gpu": ["gpu0"]}, "resource restored once")
        assert_equal(len(engine.client.sent_outcomes), 1, "exactly one terminal outcome report")
        assert_true(EventType.JOB_COMPLETED in engine.events, "client JOB_COMPLETED event fired")

        interesting = [event.split(":", 1)[0] for event in EVENTS if event.startswith(("outcome:", "free:", "event:_job_completed"))]
        assert_equal(interesting, ["outcome", "free", "event"], "outcome/free/completed order")
        print(
            "LEVEL 1 PASS: normal CHECK_RESOURCE/START_JOB plus STOPPED heartbeat abort kept gpu0 allocated "
            "until the child waiter returned; outcome was sent before the single free and JOB_COMPLETED event."
        )


def level2_server_outcome_keys_prevent_late_duplicate_wrong_job_mutation():
    EVENTS.clear()
    runner = JobRunner(workspace_root="/tmp")
    runner._pending_client_outcomes = {"job-1": {"site-1"}, "job-2": {"site-1"}}
    runner.stop_run = MagicMock()
    runner.fail_run = MagicMock()

    server = object.__new__(FederatedServer)
    server.logger = MagicMock()
    site_client = MagicMock()
    site_client.name = "site-1"
    server.client_manager = MagicMock()
    server.client_manager.is_from_authorized_client.return_value = True
    server.client_manager.clients = {"token-site-1": site_client}
    server.engine = MagicMock()
    server.engine.job_runner = runner
    server.engine.new_context.return_value = nullcontext(MagicMock())

    def make_report(job_id: str, code=JobReturnCode.SUCCESS):
        return new_cell_message(
            {
                CellMessageHeaderKeys.TOKEN: "token-site-1",
                MessageHeaderKey.ORIGIN: "site-1",
            },
            {
                JobFailureMsgKey.JOB_ID: job_id,
                JobFailureMsgKey.CODE: code,
                JobFailureMsgKey.REASON: "probe",
            },
        )

    first = server.process_job_failure(make_report("job-1"))
    duplicate = server.process_job_failure(make_report("job-1"))
    unknown = server.process_job_failure(make_report("job-unknown"))

    assert_equal(first.get_header(MessageHeaderKey.RETURN_CODE), F3ReturnCode.OK, "first outcome reply")
    assert_equal(duplicate.get_header(MessageHeaderKey.RETURN_CODE), F3ReturnCode.OK, "duplicate outcome reply")
    assert_equal(unknown.get_header(MessageHeaderKey.RETURN_CODE), F3ReturnCode.OK, "unknown outcome reply")
    assert_equal(runner._pending_client_outcomes["job-1"], set(), "job-1 resolved once")
    assert_equal(runner._pending_client_outcomes["job-2"], {"site-1"}, "job-2 unaffected by stale job-1 reports")
    runner.fail_run.assert_not_called()
    runner.stop_run.assert_not_called()

    print(
        "LEVEL 2 PASS: with the reachable pending-outcome state seeded by JobRunner._start_run, "
        "late duplicate and unknown job reports were ACKed but ignored and did not alter job-2."
    )


def level3_timing_equivalent_does_not_change_result():
    print(
        "LEVEL 3 PASS: no source patch applied; Level 1 already held the child at the exact waiter boundary "
        "and Level 2 injected only the pending-outcome state that JobRunner._start_run creates. "
        "Patching logic to remove those guards would manufacture the symptom."
    )


def main():
    print(f"NVFlare worktree: {WORKTREE}")
    os.environ.pop("NVFLARE_LIFECYCLE_RAW", None)
    level0_scheduler_does_not_reallocate_before_physical_free()
    level1_client_cleanup_owns_free_after_child_exit()
    level2_server_outcome_keys_prevent_late_duplicate_wrong_job_mutation()
    level3_timing_equivalent_does_not_change_result()
    print("RESULT: no early free, duplicate free, omitted free, or wrong-job outcome mutation reproduced")


if __name__ == "__main__":
    main()
