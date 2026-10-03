"""Scratch harness: real server-parent objects (FederatedServer, ServerEngine, ClientManager,
JobRunner, DefaultJobScheduler, RunManager) with fakes only at the process / network edges.

Nothing in the pinned source tree is modified. Fakes:
  - FakeJobManager: in-memory job store (records set_status calls with timestamps)
  - FakeHandle: job handle whose wait()/poll()/terminate() are controllable
  - cell: a stub whose fire_and_forget/send_request record calls
"""

import argparse
import logging
import tempfile
import threading
import time

from nvflare.apis.client import Client
from nvflare.apis.event_type import EventType
from nvflare.apis.fl_component import FLComponent
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, SystemComponents
from nvflare.apis.fl_context import FLContext
from nvflare.apis.job_def import Job, JobMetaKey, RunStatus
from nvflare.apis.workspace import Workspace
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey
from nvflare.fuel.f3.message import Message as CellMessage
from nvflare.private.defs import CellMessageHeaderKeys, JobFailureMsgKey
from nvflare.private.fed.server.fed_server import FederatedServer
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.fed.server.run_manager import RunManager

logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(threadName)s %(name)s %(levelname)s %(message)s")

T0 = time.monotonic()


def now():
    return round(time.monotonic() - T0, 2)


class FakeJobManager:
    def __init__(self):
        self.jobs = {}
        self.status_log = []  # (t, job_id, status)
        self.lock = threading.Lock()

    def add(self, job):
        self.jobs[job.job_id] = job

    def get_job(self, jid, fl_ctx=None):
        return self.jobs.get(jid)

    def set_status(self, job_id, status, fl_ctx=None):
        with self.lock:
            self.status_log.append((now(), job_id, status))
            j = self.jobs.get(job_id)
            if j:
                j.meta[JobMetaKey.STATUS.value] = status

    def update_meta(self, *a, **k):
        pass

    def save_workspace(self, job_id, ws_dirs, fl_ctx):
        return "nowhere"

    def get_jobs_to_schedule(self, fl_ctx):
        return []


class FakeHandle:
    """Launcher job handle. wait() blocks until exit() is called."""

    def __init__(self, rc=0):
        self.rc = rc
        self._exited = threading.Event()
        self.terminate_calls = 0

    def exit(self, rc=None):
        if rc is not None:
            self.rc = rc
        self._exited.set()

    def wait(self):
        self._exited.wait()

    def poll(self):
        return self.rc if self._exited.is_set() else None

    def terminate(self):
        self.terminate_calls += 1
        self._exited.set()


class StubCell:
    def __init__(self):
        self.sent = []

    def fire_and_forget(self, targets=None, channel=None, topic=None, message=None, optional=False):
        self.sent.append(("faf", targets, channel, topic))

    def send_request(self, target=None, channel=None, topic=None, request=None, timeout=None, optional=False):
        self.sent.append(("req", target, channel, topic))
        return CellMessage({MessageHeaderKey.RETURN_CODE: "timeout"}, None)

    def get_fqcn(self):
        return "server"


def make_job(job_id, sites):
    meta = {
        JobMetaKey.JOB_ID.value: job_id,
        JobMetaKey.STATUS.value: RunStatus.RUNNING,
        JobMetaKey.SCHEDULE_COUNT.value: 1,
        JobMetaKey.LAST_SCHEDULE_TIME.value: time.time(),
        JobMetaKey.SCHEDULE_HISTORY.value: [],
    }
    return Job(job_id=job_id, resource_spec={s: {} for s in sites}, deploy_map={"app": ["server"] + sites}, meta=meta)


class Env:
    """A server parent with real bookkeeping objects."""

    def __init__(self, outcome_timeout=4.0, max_jobs=1):
        self.tmp = tempfile.mkdtemp(prefix="se_harness_")
        import os

        os.makedirs(os.path.join(self.tmp, "startup"), exist_ok=True)
        os.makedirs(os.path.join(self.tmp, "local"), exist_ok=True)
        args = argparse.Namespace(workspace=self.tmp, set=[], config_folder="")
        self.server = FederatedServer(project_name="proj", min_num_clients=1, max_num_clients=100, args=args)
        self.server.cell = StubCell()
        self.engine = self.server.engine
        self.cm = self.server.client_manager
        self.job_manager = FakeJobManager()
        self.scheduler = DefaultJobScheduler(max_jobs=max_jobs)
        self.job_runner = JobRunner(workspace_root=self.tmp)
        self.job_runner.client_outcome_wait_timeout = outcome_timeout
        self.job_runner.scheduler = self.scheduler
        self.events = []  # (t, event, job_id)
        env = self

        class EventRecorder(FLComponent):
            def handle_event(self, event_type, fl_ctx):
                data = fl_ctx.get_prop(FLContextKey.EVENT_DATA)
                jid = data.get("job_id") if isinstance(data, dict) else None
                if event_type in (EventType.JOB_STARTED, EventType.JOB_COMPLETED, EventType.JOB_ABORTED):
                    env.events.append((now(), event_type, jid))

        workspace = Workspace(root_dir=self.tmp, site_name="server")
        self.run_manager = RunManager(
            server_name="proj",
            engine=self.engine,
            job_id=None,
            workspace=workspace,
            components={
                SystemComponents.JOB_MANAGER: self.job_manager,
                SystemComponents.JOB_SCHEDULER: self.scheduler,
            },
            client_manager=self.cm,
            handlers=[self.scheduler, EventRecorder()],
        )
        self.engine.set_run_manager(self.run_manager)
        self.engine.set_job_runner(self.job_runner, self.job_manager)
        self.completer = None

    # ---- clients -------------------------------------------------------
    def add_client(self, name, token=None):
        """Registers a client through the real heartbeat re-activation path of ClientManager."""
        token = token or f"tok-{name}"
        with FLContext() as ctx:
            created = self.cm.heartbeat(token, name, name, ctx)
        assert created, f"client {name} not created"
        self.server.tokens[token] = self.server.task_meta_info(name)
        return self.cm.clients[token]

    # ---- job start (state exactly as JobRunner._start_run + run() leave it) ----
    def start_job(self, job_id, site_names, handle=None):
        job = make_job(job_id, site_names)
        self.job_manager.add(job)
        handle = handle or FakeHandle()
        job_clients = self.engine.get_job_clients({s: None for s in site_names})
        with self.engine.lock:
            self.engine.run_processes[job_id] = {
                RunProcessKey.JOB_HANDLE: handle,
                RunProcessKey.JOB_ID: job_id,
                RunProcessKey.PARTICIPANTS: job_clients,
            }
        threading.Thread(
            target=self.engine.wait_for_complete, args=[self.tmp, job_id, handle], name=f"wfc-{job_id}", daemon=True
        ).start()
        with self.job_runner.lock:
            self.job_runner._pending_client_outcomes[job_id] = set(site_names)
            self.job_runner.running_jobs[job_id] = job
        with self.engine.new_context() as ctx:
            self.job_runner._fire_job_lifecycle_event(EventType.JOB_STARTED, job_id, ctx)
        return job, handle

    def start_completer(self):
        self.completer = threading.Thread(
            target=self.job_runner._job_complete_process, args=[self.engine], name="job_complete", daemon=True
        )
        self.completer.start()

    # ---- messages ------------------------------------------------------
    def client_report(self, client_name, token, job_id, code):
        req = CellMessage(
            {MessageHeaderKey.ORIGIN: client_name, CellMessageHeaderKeys.TOKEN: token},
            {JobFailureMsgKey.JOB_ID: job_id, JobFailureMsgKey.CODE: code, JobFailureMsgKey.REASON: "x"},
        )
        reply = self.server.process_job_failure(req)
        return reply.get_header(MessageHeaderKey.RETURN_CODE)

    def client_heartbeat(self, client_name, token, job_ids):
        from nvflare.apis.shareable import Shareable

        req = CellMessage(
            {
                CellMessageHeaderKeys.TOKEN: token,
                CellMessageHeaderKeys.CLIENT_NAME: client_name,
                MessageHeaderKey.ORIGIN: client_name,
                CellMessageHeaderKeys.JOB_IDS: list(job_ids),
                CellMessageHeaderKeys.PROJECT_NAME: "proj",
            },
            Shareable(),
        )
        reply = self.server.client_heartbeat(req)
        return reply.get_header(MessageHeaderKey.RETURN_CODE), reply.get_header(CellMessageHeaderKeys.ABORT_JOBS)

    def status_of(self, job_id):
        return [(t, s) for (t, j, s) in self.job_manager.status_log if j == job_id]

    def stop(self):
        self.job_runner.ask_to_stop = True
        self.server.shutdown = True
