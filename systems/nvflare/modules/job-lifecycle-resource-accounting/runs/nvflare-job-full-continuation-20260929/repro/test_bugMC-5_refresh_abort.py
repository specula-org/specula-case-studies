#!/usr/bin/env python3
"""MC-5 reproduction: scheduler refresh_meta restores SUBMITTED over an acknowledged abort.

The system under test is the pinned NVFlare source.  The fake engine below only
stands in for server/network/process edges; job metadata storage, scheduling,
the job runner loop, and the admin abort handler are real product code.
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace


SPECULA_OUTPUT = Path(__file__).resolve().parents[1]
SOURCE = SPECULA_OUTPUT / "confirmation" / "MC-5" / "worktree"
sys.path.insert(0, str(SOURCE))

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import RunProcessKey, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.job_def import JobMetaKey, RunStatus  # noqa: E402
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.apis.workspace import Workspace  # noqa: E402
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler  # noqa: E402
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage  # noqa: E402
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager  # noqa: E402
from nvflare.private.admin_defs import Message, ok_reply  # noqa: E402
from nvflare.private.fed.server.job_cmds import JobCommandModule  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.message_send import ClientReply  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402


class FakeConnection:
    def __init__(self, engine, job_id: str):
        self.app_ctx = engine
        self.props = {JobCommandModule.JOB_ID: job_id}
        self.strings: list[str] = []
        self.errors: list[str] = []
        self.successes: list[str] = []

    def get_prop(self, key, default=None):
        return self.props.get(key, default)

    def append_string(self, s, meta=None):
        self.strings.append(s)

    def append_success(self, s, meta=None):
        self.successes.append(s)

    def append_error(self, s, meta=None):
        self.errors.append(s)


class FakeEngine(ServerEngineSpec):
    def __init__(self, root: Path):
        self.root = root
        (root / "workspace").mkdir(parents=True, exist_ok=True)
        self.storage = FilesystemStorage(root_dir=str(root / "store"), uri_root="/")
        old_cwd = os.getcwd()
        os.chdir(root)
        try:
            self.job_def_manager = SimpleJobDefManager(uri_root="jobs")
        finally:
            os.chdir(old_cwd)
        self.scheduler = DefaultJobScheduler(max_jobs=1, min_schedule_interval=0.0)
        self.job_runner = JobRunner(workspace_root=str(root / "workspace"))
        self.job_runner.scheduler = self.scheduler
        self.job_runner._deploy_job = lambda job, sites, fl_ctx: (job.job_id, [])
        self.ctx_mgr = FLContextManager(engine=self, identity_name="server", job_id="")
        self.server = SimpleNamespace(server_state=HotState())
        self.client = Client("site-1", "tok-site-1")
        self.resources_ok = False
        self.resource_checks: list[tuple[str, bool]] = []
        self.cancel_calls = 0
        self.run_processes = {}
        self.exception_run_processes = {}
        self.lock = threading.Lock()
        self.sj_started: list[str] = []
        self.events: list[tuple[str, str | None]] = []

    def validate_targets(self, target_names):
        valid = [self.client for name in target_names if name == self.client.name]
        invalid = [name for name in target_names if name != self.client.name]
        return valid, invalid

    def fire_event(self, event_type: str, fl_ctx):
        data = fl_ctx.get_prop("__event_data__", None) or fl_ctx.get_prop("event_data", None)
        job_id = data.get("job_id") if isinstance(data, dict) else fl_ctx.get_job_id("")
        self.events.append((event_type, job_id))
        if event_type in (EventType.JOB_STARTED, EventType.JOB_COMPLETED, EventType.JOB_ABORTED):
            self.scheduler.handle_event(event_type, fl_ctx)

    def get_clients(self):
        return [self.client]

    def sync_clients_from_main_process(self):
        return None

    def update_job_run_status(self):
        return None

    def new_context(self):
        return self.ctx_mgr.new_context()

    def get_workspace(self):
        return Workspace(root_dir=str(self.root / "workspace"), site_name="server")

    def add_component(self, component_id: str, component):
        raise NotImplementedError(component_id)

    def get_component(self, component_id: str):
        if component_id == "job_store":
            return self.storage
        if component_id == SystemComponents.JOB_MANAGER:
            return self.job_def_manager
        return None

    def register_aux_message_handler(self, topic: str, message_handle_func):
        return None

    def send_aux_request(self, targets, topic, request, timeout, fl_ctx, optional=False, secure=False):
        return {}

    def multicast_aux_requests(self, topic, target_requests, timeout, fl_ctx, optional=False, secure=False):
        return {}

    def get_widget(self, widget_id: str):
        return None

    def persist_components(self, fl_ctx, completed: bool):
        return None

    def restore_components(self, snapshot, fl_ctx):
        return None

    def get_job_clients(self, client_sites):
        return {self.client.token: self.client for name in client_sites if name == self.client.name}

    def start_app_on_server(self, fl_ctx, job=None, job_clients=None):
        self.run_processes[job.job_id] = {
            RunProcessKey.JOB_ID: job.job_id,
            RunProcessKey.PARTICIPANTS: job_clients or {},
        }
        self.sj_started.append(job.job_id)
        return ""

    def start_client_job(self, job, client_sites, fl_ctx):
        req = Message(topic="start_job", body="")
        return [ClientReply(self.client.token, self.client.name, req, ok_reply(body="started"))]

    def check_client_resources(self, job, resource_reqs, fl_ctx):
        self.resource_checks.append((job.job_id, self.resources_ok))
        return {
            site_name: (self.resources_ok, f"token-{job.job_id[:8]}-{site_name}" if self.resources_ok else "not enough resource")
            for site_name in resource_reqs
        }

    def cancel_client_resources(self, resource_check_results, resource_reqs, fl_ctx):
        self.cancel_calls += 1

    def get_client_name_from_token(self, token: str):
        return self.client.name if token == self.client.token else ""


def wait_until(predicate, timeout_s: float, interval_s: float = 0.02) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return predicate()


def store_status(engine: FakeEngine, job_id: str) -> str:
    with engine.new_context() as fl_ctx:
        job = engine.job_def_manager.get_job(job_id, fl_ctx)
    return job.meta.get(JobMetaKey.STATUS.value) if job else "<missing>"


def submit_job(engine: FakeEngine) -> str:
    meta = {
        JobMetaKey.JOB_NAME.value: "mc5-refresh-abort",
        JobMetaKey.DEPLOY_MAP.value: {"app": ["server", "site-1"]},
        JobMetaKey.MIN_CLIENTS.value: 1,
        JobMetaKey.RESOURCE_SPEC.value: {},
    }
    with engine.new_context() as fl_ctx:
        created = engine.job_def_manager.create(meta, b"minimal job payload", fl_ctx)
    return created[JobMetaKey.JOB_ID.value]


def admin_abort(engine: FakeEngine, job_id: str) -> FakeConnection:
    conn = FakeConnection(engine, job_id)
    JobCommandModule().abort_job(conn, ["abort_job", job_id])
    if conn.errors:
        raise RuntimeError(f"abort_job failed: {conn.errors}")
    return conn


def start_runner(engine: FakeEngine):
    result = {"exception": None}

    def target():
        try:
            with engine.new_context() as fl_ctx:
                engine.job_runner.run(fl_ctx)
        except BaseException as e:
            result["exception"] = f"{type(e).__name__}: {e}"

    t = threading.Thread(target=target, name="JobRunner.run")
    t.start()
    return t, result


def stop_runner(engine: FakeEngine, runner_thread: threading.Thread):
    engine.job_runner.ask_to_stop = True
    runner_thread.join(timeout=3.0)
    for t in list(threading.enumerate()):
        if t is not threading.current_thread() and "_job_complete_process" in t.name:
            t.join(timeout=3.0)


def build_engine(prefix: str) -> tuple[FakeEngine, Path]:
    root = Path(tempfile.mkdtemp(prefix=prefix))
    return FakeEngine(root), root


def run_level0_unassisted_control():
    engine, root = build_engine("mc5-level0-")
    t = None
    try:
        job_id = submit_job(engine)
        t, result = start_runner(engine)
        time.sleep(1.25)
        conn = admin_abort(engine, job_id)
        engine.resources_ok = True
        time.sleep(1.75)
        status = store_status(engine, job_id)
        launched = job_id in engine.sj_started
        stop_runner(engine, t)
        print("LEVEL0 bounded unassisted run:")
        print(f"  abort_reply={conn.strings}")
        print(f"  final_status={status}")
        print(f"  launched_after_abort={launched}")
        print(f"  runner_exception={result['exception']}")
        return status, launched
    finally:
        if t is not None and t.is_alive():
            stop_runner(engine, t)
        shutil.rmtree(root, ignore_errors=True)


def run_level1_timing_assisted_repro():
    engine, root = build_engine("mc5-level1-")
    t = None
    try:
        job_id = submit_job(engine)
        real_refresh_meta = engine.job_def_manager.refresh_meta
        real_get_meta = engine.storage.get_meta
        tls = threading.local()
        abort_info = {"reply": None, "status_after_abort": None}
        abort_done = threading.Event()

        def refresh_meta_ctl(job, meta_keys, fl_ctx):
            tls.in_refresh = job.job_id
            try:
                return real_refresh_meta(job, meta_keys, fl_ctx)
            finally:
                tls.in_refresh = None

        def get_meta_ctl(uri):
            meta = real_get_meta(uri)
            in_refresh = getattr(tls, "in_refresh", None)
            if in_refresh == job_id and Path(uri).name == job_id and not abort_done.is_set():
                print(f"LEVEL1 refresh_meta RMW read status={meta.get(JobMetaKey.STATUS.value)}")

                def abort_target():
                    conn = admin_abort(engine, job_id)
                    abort_info["reply"] = list(conn.strings)
                    abort_info["status_after_abort"] = store_status(engine, job_id)

                abort_thread = threading.Thread(target=abort_target, name="ADMIN-abort_job")
                abort_thread.start()
                abort_thread.join(timeout=5.0)
                if abort_thread.is_alive():
                    raise RuntimeError("admin abort did not finish")
                abort_done.set()
                print(f"LEVEL1 status immediately after abort={abort_info['status_after_abort']}")
                engine.resources_ok = True
            return meta

        engine.job_def_manager.refresh_meta = refresh_meta_ctl
        engine.storage.get_meta = get_meta_ctl

        t, result = start_runner(engine)
        if not abort_done.wait(timeout=8.0):
            raise AssertionError("timing hook did not observe scheduler refresh_meta")
        if not wait_until(lambda: store_status(engine, job_id) == RunStatus.SUBMITTED.value, timeout_s=3.0):
            raise AssertionError(f"refresh write did not restore SUBMITTED; status={store_status(engine, job_id)}")
        status_after_refresh = store_status(engine, job_id)
        print(f"LEVEL1 status after refresh write={status_after_refresh}")

        if not wait_until(lambda: store_status(engine, job_id) == RunStatus.RUNNING.value, timeout_s=8.0):
            raise AssertionError(f"aborted job did not reach RUNNING; status={store_status(engine, job_id)}")
        final_status = store_status(engine, job_id)
        launched = job_id in engine.sj_started
        stop_runner(engine, t)
        print("LEVEL1 timing-assisted run:")
        print(f"  abort_reply={abort_info['reply']}")
        print(f"  status_after_abort={abort_info['status_after_abort']}")
        print(f"  status_after_refresh_write={status_after_refresh}")
        print(f"  final_status={final_status}")
        print(f"  launched_after_acknowledged_abort={launched}")
        print(f"  resource_checks={engine.resource_checks}")
        print(f"  cancel_calls={engine.cancel_calls}")
        print(f"  lifecycle_events={engine.events}")
        print(f"  runner_exception={result['exception']}")

        assert abort_info["status_after_abort"] == RunStatus.FINISHED_ABORTED.value
        assert status_after_refresh == RunStatus.SUBMITTED.value
        assert final_status == RunStatus.RUNNING.value
        assert launched
        assert result["exception"] is None
        return final_status, launched
    finally:
        if t is not None and t.is_alive():
            stop_runner(engine, t)
        shutil.rmtree(root, ignore_errors=True)


def main():
    import nvflare

    assert str(Path(nvflare.__file__).resolve()).startswith(str(SOURCE)), nvflare.__file__
    print(f"nvflare_source={Path(nvflare.__file__).resolve()}")
    run_level0_unassisted_control()
    final_status, launched = run_level1_timing_assisted_repro()
    print(f"REPRODUCED: final_status={final_status} launched_after_abort={launched}")


if __name__ == "__main__":
    main()
