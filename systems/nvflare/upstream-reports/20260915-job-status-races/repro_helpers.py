import io
import os
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace
from zipfile import ZipFile

from nvflare.apis.client import Client
from nvflare.apis.fl_constant import RunProcessKey, SiteType, SystemComponents
from nvflare.apis.fl_context import FLContextManager
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager
from nvflare.apis.job_def import JobMetaKey, RunStatus
from nvflare.apis.job_scheduler_spec import DispatchInfo, JobSchedulerSpec
from nvflare.apis.server_engine_spec import ServerEngineSpec
from nvflare.apis.workspace import Workspace
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage
from nvflare.fuel.flare_api.api_spec import MonitorReturnCode
from nvflare.fuel.flare_api.flare_api import Session
from nvflare.fuel.hci.conn import Connection
from nvflare.private.admin_defs import Message, ReturnCode
from nvflare.private.fed.server.job_cmds import JobCommandModule
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.fed.server.message_send import ClientReply
from nvflare.private.fed.server.server_state import HotState


SITE_NAME = "site-1"
CLIENT_TOKEN = "token-site-1"
APP_NAME = "client_app"
JOB_FOLDER = "specula_job"


def print_source_info():
    import nvflare

    source_root = Path(nvflare.__file__).resolve().parents[1]
    result = subprocess.run(
        ["git", "-C", str(source_root), "rev-parse", "HEAD"],
        text=True,
        capture_output=True,
        check=False,
    )
    head = result.stdout.strip() if result.returncode == 0 else "unknown"
    version = getattr(nvflare, "__version__", "unknown")
    print(f"NVFlare version: {version}")
    print(f"NVFlare source HEAD: {head}")


def require_event(event: threading.Event, label: str, timeout: float = 8.0):
    if not event.wait(timeout):
        raise AssertionError(f"timed out waiting for {label}")


def require_thread_done(thread: threading.Thread, label: str, timeout: float = 8.0):
    thread.join(timeout)
    if thread.is_alive():
        raise AssertionError(f"{label} did not stop")


def make_job_zip() -> bytes:
    buffer = io.BytesIO()
    with ZipFile(buffer, "w") as zf:
        zf.writestr(f"{JOB_FOLDER}/{APP_NAME}/config/config_fed_client.json", "{}\n")
        zf.writestr(f"{JOB_FOLDER}/{APP_NAME}/config/config_fed_server.json", "{}\n")
    return buffer.getvalue()


class RecordingJobDefManager(SimpleJobDefManager):
    def __init__(self, uri_root: str):
        super().__init__(uri_root=uri_root)
        self.transitions = []
        self._condition = threading.Condition()

    def set_status(self, jid: str, status: RunStatus, fl_ctx):
        self._before_status_write(jid, status, fl_ctx)
        before = self.current_status(jid, fl_ctx)
        super().set_status(jid, status, fl_ctx)
        after = self.current_status(jid, fl_ctx)
        with self._condition:
            self.transitions.append((before, status.value, after))
            self._condition.notify_all()

    def _before_status_write(self, jid: str, status: RunStatus, fl_ctx):
        pass

    def current_status(self, jid: str, fl_ctx):
        job = self.get_job(jid, fl_ctx)
        if not job:
            return None
        return job.meta.get(JobMetaKey.STATUS.value)

    def wait_for_status(self, jid: str, status: RunStatus, fl_ctx, timeout: float = 8.0):
        deadline = time.monotonic() + timeout
        with self._condition:
            while time.monotonic() < deadline:
                if self.current_status(jid, fl_ctx) == status.value:
                    return
                remaining = deadline - time.monotonic()
                self._condition.wait(timeout=min(0.1, max(remaining, 0.0)))
        raise AssertionError(f"timed out waiting for persisted status {status.value}")


class GatedRunningJobDefManager(RecordingJobDefManager):
    def __init__(self, uri_root: str):
        super().__init__(uri_root=uri_root)
        self.gate_running_writes = False
        self.running_write_entered = threading.Event()
        self.allow_running_write = threading.Event()
        self.terminal_status_written = threading.Event()
        self.running_status_written = threading.Event()

    def _before_status_write(self, jid: str, status: RunStatus, fl_ctx):
        if status == RunStatus.RUNNING:
            self.running_write_entered.set()
            if self.gate_running_writes:
                require_event(self.allow_running_write, "release of delayed RUNNING status write")

    def set_status(self, jid: str, status: RunStatus, fl_ctx):
        super().set_status(jid, status, fl_ctx)
        if status == RunStatus.RUNNING:
            self.running_status_written.set()
        elif status.value.startswith("FINISHED:"):
            self.terminal_status_written.set()


class OneShotScheduler(JobSchedulerSpec):
    def __init__(self):
        self.scheduled = False

    def schedule_job(self, job_manager, job_candidates, fl_ctx):
        if self.scheduled or not job_candidates:
            return None, None
        self.scheduled = True
        job = job_candidates[0]
        job.meta[JobMetaKey.SCHEDULE_COUNT.value] = int(job.meta.get(JobMetaKey.SCHEDULE_COUNT.value, 0)) + 1
        job.meta[JobMetaKey.LAST_SCHEDULE_TIME.value] = time.time()
        history = list(job.meta.get(JobMetaKey.SCHEDULE_HISTORY.value, []))
        history.append({"site": SITE_NAME, "time": job.meta[JobMetaKey.LAST_SCHEDULE_TIME.value]})
        job.meta[JobMetaKey.SCHEDULE_HISTORY.value] = history
        return job, {SITE_NAME: DispatchInfo(app_name=APP_NAME, resource_requirements={}, token=None)}


class FakeAdminServer:
    def __init__(self, engine):
        self.engine = engine
        self.timeout = 2.0
        self.sai = SimpleNamespace(new_context=engine.new_context)
        self.block_deploy_reply = False
        self.deploy_entered = threading.Event()
        self.release_deploy_reply = threading.Event()

    def send_requests_and_get_reply_dict(self, requests, timeout_secs=None):
        self.deploy_entered.set()
        if self.block_deploy_reply:
            require_event(self.release_deploy_reply, "release of delayed deploy replies")
        replies = {}
        for token in requests:
            reply = Message(topic="reply", body="ok")
            reply.set_header("_rtnCode", ReturnCode.OK)
            replies[token] = reply
        return replies


class FakeServerEngine(ServerEngineSpec):
    def __init__(self, workspace_root: str, manager, scheduler, store):
        self.workspace_root = workspace_root
        self.job_def_manager = manager
        self.scheduler = scheduler
        self.store = store
        self.job_runner = None
        self.client = Client(SITE_NAME, CLIENT_TOKEN)
        self.lock = threading.RLock()
        self.run_processes = {}
        self.exception_run_processes = {}
        self.client_manager = SimpleNamespace(clients={CLIENT_TOKEN: self.client})
        self.components = {
            SystemComponents.JOB_MANAGER: manager,
            SystemComponents.JOB_SCHEDULER: scheduler,
            "job_store": store,
        }
        self._ctx_manager = FLContextManager(engine=self, identity_name=SiteType.SERVER)
        self.started_jobs = []
        self.started_event = threading.Event()
        self.events = []
        self.admin_server = FakeAdminServer(self)
        self.server = SimpleNamespace(server_state=HotState(), admin_server=self.admin_server)

    def fire_event(self, event_type: str, fl_ctx):
        self.events.append(event_type)

    def get_clients(self):
        return [self.client]

    def sync_clients_from_main_process(self):
        return self.get_clients()

    def update_job_run_status(self):
        return None

    def new_context(self):
        return self._ctx_manager.new_context()

    def get_workspace(self):
        return Workspace(root_dir=self.workspace_root, site_name=SiteType.SERVER)

    def add_component(self, component_id: str, component):
        self.components[component_id] = component

    def get_component(self, component_id: str):
        return self.components.get(component_id)

    def register_aux_message_handler(self, topic: str, message_handle_func):
        return None

    def send_aux_request(self, targets, topic: str, request, timeout: float, fl_ctx, optional=False, secure=False):
        return {}

    def multicast_aux_requests(self, topic: str, target_requests: dict, timeout: float, fl_ctx, optional=False, secure=False):
        return {}

    def get_widget(self, widget_id: str):
        return None

    def persist_components(self, fl_ctx, completed: bool):
        return None

    def restore_components(self, snapshot, fl_ctx):
        return None

    def start_client_job(self, job, client_sites, fl_ctx):
        request = Message(topic="start", body="")
        reply = Message(topic="reply", body="ok")
        reply.set_header("_rtnCode", ReturnCode.OK)
        return [ClientReply(CLIENT_TOKEN, SITE_NAME, request, reply)]

    def check_client_resources(self, job, resource_reqs: dict, fl_ctx):
        return {SITE_NAME: (True, None)}

    def cancel_client_resources(self, resource_check_results: dict, resource_reqs: dict, fl_ctx):
        return None

    def get_client_name_from_token(self, token: str):
        return SITE_NAME if token == CLIENT_TOKEN else ""

    def validate_targets(self, target_names: list[str]):
        valid = [self.client for name in target_names if name == SITE_NAME]
        invalid = [name for name in target_names if name != SITE_NAME]
        return valid, invalid

    def get_job_clients(self, client_sites):
        return {CLIENT_TOKEN: self.client for name in client_sites if name == SITE_NAME}

    def start_app_on_server(self, fl_ctx, job, job_clients, snapshot=None):
        run_dir = self.get_workspace().get_run_dir(job.job_id)
        os.makedirs(run_dir, exist_ok=True)
        Path(run_dir, "log.txt").write_text("server app started\n", encoding="utf-8")
        with self.lock:
            self.run_processes[job.job_id] = {RunProcessKey.PARTICIPANTS: job_clients}
        self.started_jobs.append(job.job_id)
        self.started_event.set()
        return ""

    def abort_app_on_server(self, job_id):
        with self.lock:
            self.run_processes.pop(job_id, None)
        return ""

    def remove_exception_process(self, job_id):
        with self.lock:
            self.exception_run_processes.pop(job_id, None)


class StoreBackedSession(Session):
    def __init__(self, harness):
        self.harness = harness

    def get_job_meta(self, job_id: str):
        job = self.harness.manager.get_job(job_id, self.harness.engine.new_context())
        return job.meta if job else None


class JobHarness:
    def __init__(self, manager_cls=RecordingJobDefManager):
        for key in ("NVFL_JOB_STORE_ROOT", "NVFL_RESULT_ROOT", "NVFL_LOG_ROOT", "NVFL_AUDIT_ROOT"):
            os.environ.pop(key, None)
        self.tmp = tempfile.TemporaryDirectory(prefix="nvflare-job-status-race-")
        self.root = Path(self.tmp.name)
        self.workspace_root = str(self.root / "workspace")
        Path(self.workspace_root, "startup").mkdir(parents=True)
        Path(self.workspace_root, "local").mkdir(parents=True)
        self.store = FilesystemStorage()
        self.manager = manager_cls(uri_root=str(self.root / "job-store"))
        self.scheduler = OneShotScheduler()
        self.engine = FakeServerEngine(self.workspace_root, self.manager, self.scheduler, self.store)
        self.runner = JobRunner(workspace_root=self.workspace_root)
        self.runner.scheduler = self.scheduler
        self.runner.client_outcome_wait_timeout = 0.2
        self.engine.job_runner = self.runner
        self.fl_ctx = self.engine.new_context()
        self.job_id = self._create_job()

    def _create_job(self):
        meta = {
            JobMetaKey.JOB_NAME.value: "specula-job-status-race",
            JobMetaKey.JOB_FOLDER_NAME.value: JOB_FOLDER,
            JobMetaKey.DEPLOY_MAP.value: {APP_NAME: [SITE_NAME]},
            JobMetaKey.RESOURCE_SPEC.value: {},
            JobMetaKey.MIN_CLIENTS.value: 1,
            JobMetaKey.MANDATORY_CLIENTS.value: [],
            JobMetaKey.SUBMITTER_NAME.value: "specula",
            JobMetaKey.SUBMITTER_ORG.value: "specula",
            JobMetaKey.SUBMITTER_ROLE.value: "researcher",
            JobMetaKey.SCHEDULE_COUNT.value: 0,
            JobMetaKey.SCHEDULE_HISTORY.value: [],
            JobMetaKey.LAST_SCHEDULE_TIME.value: "",
        }
        created = self.manager.create(meta, make_job_zip(), self.fl_ctx)
        return created[JobMetaKey.JOB_ID.value]

    def start_runner(self):
        thread = threading.Thread(target=self.runner.run, args=(self.fl_ctx,), daemon=True)
        thread.start()
        return thread

    def stop_runner(self, thread):
        self.runner.stop()
        require_thread_done(thread, "JobRunner")

    def current_status(self):
        return self.manager.current_status(self.job_id, self.engine.new_context())

    def abort_before_running(self):
        conn = Connection(app_ctx=self.engine)
        conn.set_prop(JobCommandModule.JOB_ID, self.job_id)
        JobCommandModule().abort_job(conn, [])
        return conn.close()

    def mark_server_process_finished(self):
        self.runner.resolve_client_outcome(self.job_id, SITE_NAME)
        with self.engine.lock:
            self.engine.run_processes.pop(self.job_id, None)

    def monitor_once(self, timeout=0.5, poll_interval=0.1):
        return StoreBackedSession(self).monitor_job_and_return_job_meta(
            self.job_id, timeout=timeout, poll_interval=poll_interval
        )

    def cleanup(self):
        self.tmp.cleanup()
