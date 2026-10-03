# Copyright (c) 2026, NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""In-process NVFlare server parent (SP) + client parents (CP) built from REAL product objects.

Real product code (from the instrumented copy of the pinned source):
  SP: FederatedServer (process_job_failure, _sync_client_jobs, _listen_command, remove_dead_clients/
      notify_dead_client), ServerEngine (start_app_on_server/_start_runner_process, wait_for_complete,
      abort_app_on_server/_remove_run_processes, check/cancel_client_resources, start_client_job, disable_clients),
      ClientManager, RunManager, JobRunner (run, _deploy_job, _start_run, _job_complete_process, stop_run, fail_run),
      DefaultJobScheduler, SimpleJobDefManager + FilesystemStorage, JobCommandModule (abort_job, delete_job).
  CP: ClientEngine (start_app, abort_app, deploy_app), JobExecutor, ListResourceManager (AutoClean base) +
      ListResourceConsumer, request processors Check/Start/CancelResourceProcessor, AbortAppProcessor,
      DeployProcessor, NotifyJobStatusProcessor, Communicator._clean_up_runs.

Stubs (edges only, see INSTRUMENTATION.md):
  * CellNet: StubAdminServer / StubServerCell / StubClientCell / StubFedClient route requests to the real handlers
    in handler threads.  Request/reply semantics are preserved: a request can be delivered, held (the sender sees a
    timeout; the request may be processed later and its reply is discarded) or dropped (LoseMsg).  A dead CP never
    processes requests (the sender sees a timeout).
  * SJ / CJ processes: FakeProc adapters wrapped in the REAL ProcessHandle (return-code mapping), launched by stub
    JobLauncherSpec components.  SJ/CJ behaviour is driven by the scenario (SjFinish, CjExit, ...).
Reproduction controls (timing only): gated expiry ticks (the real AutoClean thread runs one real tick per release),
per-message network policies, tla_hooks gates, a small client_outcome_wait_timeout via ConfigService; the dead-client
sweeper thread is not started (heart_beat_timeout is large) and the harness calls the real remove_dead_clients on demand
after back-dating the crashed client's last_connect_time.
"""

import argparse
import io
import json
import logging
import os
import threading
import time
import types
import zipfile

import nvflare.app_common.resource_managers.auto_clean_resource_manager as _auto_clean_mod
from nvflare.apis.client import Client
from nvflare.apis.event_type import EventType
from nvflare.apis.fl_constant import (
    AdminCommandNames,
    FLContextKey,
    RunProcessKey,
    ServerCommandKey,
    ServerCommandNames,
    SystemComponents,
)
from nvflare.apis.job_def import JobMetaKey
from nvflare.apis.job_launcher_spec import JobLauncherSpec, add_launcher
from nvflare.apis.shareable import Shareable
from nvflare.apis.utils.fl_context_utils import gen_new_peer_ctx
from nvflare.apis.workspace import Workspace
from nvflare.app_common.job_launcher.process_launcher import ProcessHandle
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler
from nvflare.app_common.resource_consumers.list_resource_consumer import ListResourceConsumer
from nvflare.app_common.resource_managers.list_resource_manager import ListResourceManager
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager
from nvflare.apis.storage import StorageException
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey
from nvflare.fuel.f3.cellnet.defs import ReturnCode as CellReturnCode
from nvflare.fuel.f3.message import Message as CellMessage
from nvflare.fuel.utils import tla_hooks
from nvflare.fuel.utils.config_service import ConfigService
from nvflare.private.admin_defs import Message, error_reply
from nvflare.private.defs import (
    CellMessageHeaderKeys,
    JobFailureMsgKey,
    RequestHeader,
    TrainingTopic,
    new_cell_message,
)
from nvflare.private.fed.client.client_engine import ClientEngine
from nvflare.private.fed.client.client_status import ClientStatus
from nvflare.private.fed.client.communicator import Communicator
from nvflare.private.fed.client.scheduler_cmds import (
    CancelResourceProcessor,
    CheckResourceProcessor,
    StartJobProcessor,
)
from nvflare.private.fed.client.training_cmds import AbortAppProcessor, DeployProcessor, NotifyJobStatusProcessor
from nvflare.private.fed.server.fed_server import FederatedServer
from nvflare.private.fed.server.job_cmds import JobCommandModule
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.fed.server.message_send import ClientReply
from nvflare.private.fed.server.run_manager import RunManager
from nvflare.private.fed.server.server_state import HotState
from nvflare.private.scheduler_constants import ShareableHeader

from nvf_tracer import Tracer
from resource_observer import ResourceObserver

log = logging.getLogger("nvf_env")

JOB_RETURN_TIMEOUT_REPLY = CellReturnCode.TIMEOUT


def _timeout_cell_reply():
    m = CellMessage(headers={}, payload=None)
    m.set_header(MessageHeaderKey.RETURN_CODE, CellReturnCode.TIMEOUT)
    return m


def _ok_cell_reply():
    m = CellMessage(headers={}, payload=None)
    m.set_header(MessageHeaderKey.RETURN_CODE, CellReturnCode.OK)
    return m


# ============================================================================ process edge
class FakeProc:
    """Process-group stand-in used as the adapter of the real ProcessHandle.

    Mirrors ProcessAdapter semantics: poll() is None while the leader runs, else its raw exit code; wait() blocks until
    the leader exits and reaps it; terminate() is killpg(getpgid(leader)): it kills the leader and same-group
    descendants unless the leader was already reaped (then getpgid fails and nothing is killed)."""

    def __init__(self, env, kind, client, job_id):
        self.env = env
        self.kind = kind  # "sj" / "cj"
        self.client = client
        self.job_id = job_id
        self.leader_alive = True
        self.raw_rc = None
        self.reaped = False
        self.descendants = False
        self._exited = threading.Event()
        self.pid = id(self)

    def poll(self):
        return None if self.leader_alive else self.raw_rc

    def wait(self):
        self._exited.wait()
        if self.kind == "cj" and not self.env.cps[self.client].alive:
            threading.Event().wait()  # the CP process is gone: its waiter thread never runs again
        self.reaped = True

    def terminate(self):
        if self.reaped:
            return  # getpgid(pid) fails after the leader was reaped: nothing is killed (process_utils.py)
        if self.leader_alive:
            self._exit(-9)  # SIGKILL
        self.descendants = False

    def _exit(self, raw_rc):
        self.leader_alive = False
        self.raw_rc = raw_rc
        self._exited.set()


class StubSJLauncher(JobLauncherSpec):
    """Server job launcher (process edge): registers exactly like ProcessJobLauncher but launches a FakeProc."""

    def __init__(self, env):
        super().__init__()
        self.env = env

    def handle_event(self, event_type: str, fl_ctx):
        if event_type == EventType.BEFORE_JOB_LAUNCH:
            add_launcher(self, fl_ctx)

    def launch_job(self, job_meta: dict, fl_ctx):
        job_id = job_meta.get(JobMetaKey.JOB_ID.value)
        if self.env.sj_launch_fail.pop(job_id, False):
            tla_hooks.rename("RunnerStartServerAppFail")  # observation: this step is the launcher failure
            raise RuntimeError(f"(stub) SJ launcher failed for job {job_id}")
        proc = FakeProc(self.env, "sj", None, job_id)
        self.env.sj_procs[job_id] = proc
        return ProcessHandle(process_adapter=proc)


class StubCJLauncher(JobLauncherSpec):
    """Client job launcher (process edge) of one CP."""

    def __init__(self, env, client):
        super().__init__()
        self.env = env
        self.client = client

    def handle_event(self, event_type: str, fl_ctx):
        if event_type == EventType.BEFORE_JOB_LAUNCH:
            add_launcher(self, fl_ctx)

    def launch_job(self, job_meta: dict, fl_ctx):
        job_id = job_meta.get(JobMetaKey.JOB_ID.value)
        if self.env.cj_launch_fail.pop((self.client, job_id), False):
            raise RuntimeError(f"(stub) CJ launcher failed for job {job_id} on {self.client}")
        proc = FakeProc(self.env, "cj", self.client, job_id)
        self.env.cj_procs[(self.client, job_id)] = proc
        behavior = self.env.cj_behavior.get((self.client, job_id), self.env.cj_default_behavior)
        if behavior.get("auto_start", True):
            self.env.spawn(f"cj-{self.client}-{job_id[:6]}-start", self.env._cj_auto_start, self.client, job_id)
        return ProcessHandle(process_adapter=proc)


# ============================================================================ network edge
class Network:
    """Routes stub CellNet traffic to the real handlers; applies scenario policies (deliver / hold / drop / fail)."""

    def __init__(self, env):
        self.env = env
        self.policies = []  # list of (predicate(ident dict) -> bool, action)
        self.held = []  # list of (ident, deliver_fn)
        self.lock = threading.Lock()
        self.inflight = 0
        self.audit = []

    def set_policy(self, pred, action, once=False):
        self.policies.append([pred, action, once])

    def decide(self, ident):
        if ident is None:
            return "deliver"
        with self.lock:
            for p in list(self.policies):
                pred, action, once = p
                if pred(ident):
                    if once:
                        self.policies.remove(p)
                    return action
        return "deliver"

    def _run(self, name, fn, *args):
        def target():
            try:
                fn(*args)
            finally:
                with self.lock:
                    self.inflight -= 1

        with self.lock:
            self.inflight += 1
        t = threading.Thread(target=target, name=name, daemon=True)
        t.start()
        return t

    def quiesce(self, timeout=10.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            with self.lock:
                if self.inflight == 0:
                    return True
            time.sleep(0.02)
        return False

    def lose(self, ident):
        with self.env.tracer.section("LoseMsg", msg=ident):
            pass

    def hold(self, ident, fn):
        with self.lock:
            self.held.append((ident, fn))

    def _take_held(self, pred):
        # evaluate pred exactly once per held message (scenario predicates may be randomized)
        with self.lock:
            sel, keep = [], []
            for h in self.held:
                (sel if pred(h[0]) else keep).append(h)
            self.held = keep
        return sel

    def release(self, pred):
        """Deliver held messages matching pred (late processing)."""
        sel = self._take_held(pred)
        for ident, fn in sel:
            fn()
        return len(sel)

    def drop_held(self, pred):
        """Lose held messages matching pred (LoseMsg)."""
        sel = self._take_held(pred)
        for ident, _ in sel:
            if ident is not None:
                self.lose(ident)
        return len(sel)

    def purge_to_client(self, cl):
        """ClientCrash: requests addressed to a dead CP are never processed (they leave msgs silently)."""
        with self.lock:
            self.held = [h for h in self.held if not (h[0] is not None and h[0].get("_to") == cl)]

    # ------------------------------------------------------------ SP -> CP admin requests
    def send_admin(self, requests: dict, timeout_secs):
        env = self.env
        tracer = env.tracer
        results = []
        waits = []
        started = time.monotonic()
        deadline = started + max(0.0, timeout_secs)
        for token, req in requests.items():
            client = env.server.client_manager.clients.get(token)
            if not client:
                continue  # real send_requests skips targets it does not know
            cl = client.name
            cp = env.cps[cl]
            if req.topic == TrainingTopic.CHECK_RESOURCE:
                req._tla_att = tracer.current_check_att
            ident = env.admin_identity(req, cl)
            cr = ClientReply(client_token=token, client_name=cl, req=req, reply=None)
            cr._tla_deadline = deadline
            results.append(cr)
            if tracer.holding():
                # sender inside a traced step: deliver after the step's event; the sender sees a timeout (its reply,
                # if any, is discarded).  Only used for requests whose replies the product ignores (ABORT).
                tracer.defer(lambda cp=cp, req=req, ident=ident: self._route(cp, req, ident, None))
                continue
            ev = self._route(cp, req, ident, cr)
            if ev is not None:
                waits.append(ev)
        for ev in waits:
            ev.wait(timeout=max(0.0, deadline - time.monotonic()))
        self.audit.append({"operation": "admin_wait", "ts": time.time_ns(),
                           "requested_timeout_seconds": timeout_secs,
                           "elapsed_seconds": time.monotonic() - started,
                           "deferred_by_trace_lock": tracer.holding(),
                           "replies": [r.reply is not None for r in results]})
        return results

    def _route(self, cp, req, ident, cr):
        if not cp.alive:
            return None  # a dead CP never processes the request: the sender times out
        action = self.decide(ident)
        self.audit.append({"operation": "admin_route", "ts": time.time_ns(), "identity": ident, "policy": action})
        if action == "hold":
            self.hold(ident, lambda: self._dispatch(cp, req, None))
            return None
        if action == "drop":
            if ident is not None and ident.get("type") in self.env.MODELED_TYPES:
                self.lose(ident)
            return None
        if action == "fail":
            if cr is not None:
                cr.reply = error_reply(f"(stub) injected failure for {req.topic} on {cp.name}")
            return None
        delay = float(action.split(":", 1)[1]) if action.startswith("delay:") else 0.0
        return self._dispatch(cp, req, cr, delay=delay)

    def _dispatch(self, cp, req, cr, delay=0.0):
        done = threading.Event()

        def handle():
            try:
                if delay:
                    time.sleep(delay)  # labeled handler-admission timing control, outside trace/product locks
                if not cp.alive:
                    return
                proc = cp.processors.get(req.topic)
                if proc is None:
                    return
                reply = proc.process(req, cp.engine)
                if cr is not None and time.monotonic() < cr._tla_deadline:
                    cr.reply = reply
                self.audit.append({"operation": "admin_reply", "ts": time.time_ns(),
                                   "topic": req.topic, "client": cp.name,
                                   "reply_retained": cr is not None and cr.reply is not None})
            except Exception as e:
                self.env.tracer._harness_error(f"CP handler {req.topic} on {cp.name} raised {e!r}")
            finally:
                done.set()

        self._run(f"cp-{cp.name}-{req.topic.split('.')[-1]}", handle)
        return done

    # ------------------------------------------------------------ SP -> SJ commands
    def send_to_sj(self, job_id, topic, request, wait_reply):
        env = self.env
        self.audit.append({"operation": "sj_command", "ts": time.time_ns(), "topic": topic,
                           "job": env.jname(job_id), "wait_reply": wait_reply,
                           "stub_result": "immediate injected timeout" if wait_reply else "fire_and_forget",
                           "deferred_by_trace_lock": env.tracer.holding()})
        if topic == AdminCommandNames.ABORT:
            ident = {"type": "SJABORT", "job": env.jname(job_id), "cl": "None", "att": 0, "ok": False, "code": 0,
                     "flag": False}

            def deliver():
                action = self.decide(ident)
                if action == "drop":
                    self.lose(ident)
                elif action == "hold":
                    self.hold(ident, lambda: self._run(f"sj-{job_id[:6]}-abort", env.sj_handle_abort, job_id, ident))
                else:
                    self._run(f"sj-{job_id[:6]}-abort", env.sj_handle_abort, job_id, ident)

            if env.tracer.defer(deliver):
                return _timeout_cell_reply() if wait_reply else None
            deliver()
            return _timeout_cell_reply() if wait_reply else None
        # other SJ commands (handle_dead_job, ...) are not modeled: accepted and ignored by the stub SJ
        return _ok_cell_reply() if wait_reply else None

    # ------------------------------------------------------------ SJ -> SP (UPDATE_RUN_STATUS)
    def sj_update_run_status(self, job_id, execution_error):
        env = self.env
        request = new_cell_message({CellMessageHeaderKeys.JOB_ID: job_id}, {"execution_error": execution_error})
        request.set_header(MessageHeaderKey.TOPIC, ServerCommandNames.UPDATE_RUN_STATUS)
        ident = {"type": "RUNSTATUS", "job": env.jname(job_id), "cl": "None", "att": 0, "ok": False, "code": 0,
                 "flag": bool(execution_error)}

        def deliver():
            action = self.decide(ident)
            if action == "drop":
                self.lose(ident)
            elif action == "hold":
                self.hold(ident, lambda: self._run(f"sp-runstatus-{job_id[:6]}", env.server._listen_command, request))
            else:
                self._run(f"sp-runstatus-{job_id[:6]}", env.server._listen_command, request)

        if not env.tracer.defer(deliver):
            deliver()

    # ------------------------------------------------------------ CP -> SP (REPORT_JOB_FAILURE)
    def cp_report(self, cl, request):
        env = self.env
        cp = env.cps[cl]
        request.set_header(MessageHeaderKey.ORIGIN, cl)
        request.set_header(CellMessageHeaderKeys.TOKEN, cp.token)
        request._tla_from = cl
        payload = request.payload if isinstance(request.payload, dict) else {}
        ident = {"type": "REPORT", "job": env.jname(payload.get(JobFailureMsgKey.JOB_ID)), "cl": env.cname(cl),
                 "att": 0, "ok": False, "code": int(payload.get(JobFailureMsgKey.CODE) or 0), "flag": False}
        self.audit.append({"operation": "report_send", "ts": time.time_ns(), "identity": ident,
                           "stub_result": "immediate injected timeout",
                           "deferred_by_trace_lock": env.tracer.holding()})

        def deliver():
            action = self.decide(ident)
            self.audit.append({"operation": "report_route", "ts": time.time_ns(), "identity": ident, "policy": action})
            if action == "drop":
                self.lose(ident)
            elif action == "hold":
                self.hold(ident, lambda: self._run(f"sp-report-{cl}", env.server.process_job_failure, request))
            else:
                self._run(f"sp-report-{cl}", env.server.process_job_failure, request)

        if not env.tracer.defer(deliver):
            deliver()
        return _timeout_cell_reply()

    # ------------------------------------------------------------ CP -> CJ (ABORT fired to the job cell)
    def cp_to_cj(self, cl, job_id, topic):
        env = self.env
        if topic != AdminCommandNames.ABORT:
            return

        def deliver():
            self._run(f"cj-{cl}-{job_id[:6]}-abort", env._cj_on_abort, cl, job_id)

        if not env.tracer.defer(deliver):
            deliver()


class StubAdminServer:
    """Replaces FedAdminServer's CellNet fan-out (same request/reply contract as message_send.send_requests)."""

    def __init__(self, env):
        self.env = env
        self.timeout = 5.0
        self.sai = None  # set to the ServerEngine

    def send_requests(self, requests: dict, fl_ctx, timeout_secs=2.0, optional=False):
        # mirrors FedAdminServer.send_requests: BEFORE_SEND_ADMIN_COMMAND + peer context header, then the fan-out
        for _, request in requests.items():
            if fl_ctx is not None:
                self.sai.fire_event(EventType.BEFORE_SEND_ADMIN_COMMAND, fl_ctx)
                request.set_header(ServerCommandKey.PEER_FL_CONTEXT, gen_new_peer_ctx(fl_ctx))
        return self.env.net.send_admin(requests, timeout_secs)

    def send_requests_and_get_reply_dict(self, requests: dict, timeout_secs=2.0) -> dict:
        result = {}
        if requests:
            for token, _ in requests.items():
                result[token] = None
            with self.sai.new_context() as fl_ctx:
                replies = self.send_requests(requests, fl_ctx, timeout_secs=timeout_secs)
                for r in replies:
                    result[r.client_token] = r.reply
        return result

    def client_dead(self, token):
        pass

    def client_heartbeat(self, token, name, fqcn):
        pass


class StubServerCell:
    def __init__(self, env):
        self.env = env
        self.core_cell = types.SimpleNamespace(get_fqcn=lambda: "server")

    def get_internal_listener_url(self):
        return "tcp://localhost:0"

    def get_root_url_for_child(self):
        return "tcp://localhost:0"

    def get_internal_listener_params(self):
        return None

    def get_fqcn(self):
        return "server"

    def send_request(self, target, channel, topic, request, timeout=10.0, optional=False, **kwargs):
        job_id = target.split(".", 1)[1] if "." in target else target
        return self.env.net.send_to_sj(job_id, topic, request, wait_reply=True)

    def fire_and_forget(self, targets, channel, topic, message, optional=False, **kwargs):
        target = targets if isinstance(targets, str) else list(targets)[0]
        job_id = target.split(".", 1)[1] if "." in target else target
        self.env.net.send_to_sj(job_id, topic, message, wait_reply=False)


class StubClientCell:
    def __init__(self, env, cl):
        self.env = env
        self.cl = cl
        self.core_cell = types.SimpleNamespace(get_fqcn=lambda: cl)

    def get_fqcn(self):
        return self.cl

    def get_internal_listener_url(self):
        return "tcp://localhost:0"

    def get_internal_listener_params(self):
        return None

    def fire_and_forget(self, targets, channel, topic, message, optional=False, **kwargs):
        target = targets if isinstance(targets, str) else list(targets)[0]
        job_id = target.split(".", 1)[1] if "." in target else target
        self.env.net.cp_to_cj(self.cl, job_id, topic)

    def send_request(self, target, channel, topic, request, timeout=10.0, optional=False, **kwargs):
        return _timeout_cell_reply()


class StubFedClient:
    """The FederatedClient attributes used by ClientEngine / JobExecutor; REPORT_JOB_FAILURE goes to the SP."""

    def __init__(self, env, cl, token, components):
        self.env = env
        self.client_name = cl
        self.token = token
        self.token_signature = "NA"
        self.ssid = "ssid"
        self.client_args = {}
        self.secure_train = False
        self.components = components
        self.cell = StubClientCell(env, cl)
        self.engine = None
        self.multi_gpu = False

    def send_request_before_shutdown(self, target, channel, topic, request, timeout, optional=False):
        return self.env.net.cp_report(self.client_name, request)


class GatedTime:
    """Stands in for the `time` module of auto_clean_resource_manager: the expiry thread's sleep() returns only when
    the harness releases one tick for that resource manager (reproduction control: explicit expiry ticks)."""

    def __init__(self, real_time):
        self._real = real_time
        self.gates = {}  # thread -> (semaphore, done-event)

    def register(self, thread):
        self.gates[thread] = [threading.Semaphore(0), threading.Event()]

    def sleep(self, secs):
        g = self.gates.get(threading.current_thread())
        if g is None:
            return self._real.sleep(secs)
        g[1].set()  # previous tick (if any) completed; now idle
        g[0].acquire()
        g[1].clear()

    def tick(self, thread, timeout=10.0):
        g = self.gates[thread]
        g[1].clear()
        g[0].release()
        # wait until the thread is back in sleep() (tick body done)
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if g[1].is_set():
                return True
            time.sleep(0.005)
        return False

    def __getattr__(self, item):
        return getattr(self._real, item)


# ============================================================================ CP bundle
class ClientParent:
    def __init__(self, env, name, token, units, expiry):
        self.env = env
        self.name = name
        self.token = token
        self.alive = True
        self.ws = os.path.join(env.root, name)
        for d in ("startup", "local"):
            os.makedirs(os.path.join(self.ws, d), exist_ok=True)
        self.rm = ListResourceManager({"gpu": list(units)}, expiration_period=expiry)
        self.consumer = ListResourceConsumer()
        self.launcher = StubCJLauncher(env, name)
        components = {
            SystemComponents.RESOURCE_MANAGER: self.rm,
            SystemComponents.RESOURCE_CONSUMER: self.consumer,
            "job_launcher": self.launcher,
        }
        self.fed_client = StubFedClient(env, name, token, components)
        self.args = argparse.Namespace(workspace=self.ws, set=[], config_folder="config")
        self.engine = ClientEngine(self.fed_client, self.args, rank=0)
        self.fed_client.engine = self.engine
        self.executor = self.engine.client_executor
        workspace = Workspace(root_dir=self.ws, site_name=name)
        with self.engine.new_context() as fl_ctx:
            fl_ctx.set_prop(FLContextKey.SERVER_CONFIG, [{"service": {"scheme": "grpc", "target": "localhost:8002"}}],
                            private=True, sticky=True)
            fl_ctx.set_prop(FLContextKey.WORKSPACE_OBJECT, workspace, private=True, sticky=True)
            fl_ctx.set_prop(FLContextKey.ARGS, self.args, private=True, sticky=True)
            fl_ctx.set_prop(FLContextKey.SITE_OBJ, self.fed_client, private=True, sticky=True)
        self.processors = {
            TrainingTopic.CHECK_RESOURCE: CheckResourceProcessor(),
            TrainingTopic.START_JOB: StartJobProcessor(),
            TrainingTopic.CANCEL_RESOURCE: CancelResourceProcessor(),
            TrainingTopic.ABORT: AbortAppProcessor(),
            TrainingTopic.DEPLOY: DeployProcessor(),
            TrainingTopic.NOTIFY_JOB_STATUS: NotifyJobStatusProcessor(),
        }
        self.comm = Communicator.__new__(Communicator)
        self.comm.logger = logging.getLogger(f"Communicator[{name}]")


# ============================================================================ environment
class Env:
    MODELED_TYPES = {"CHECK", "CANCEL", "START", "ABORT", "REPORT", "RUNSTATUS", "SJABORT", "CHECK_REP", "START_REP"}
    RESERVE_TOKEN_HEADER = ShareableHeader.RESOURCE_RESERVE_TOKEN
    CELL_JOB_ID_HEADER = CellMessageHeaderKeys.JOB_ID

    def __init__(self, root, trace_path, cfg):
        self.root = root
        self.cfg = cfg
        os.makedirs(root, exist_ok=True)
        self.client_names = list(cfg["clients"])
        self.units = list(cfg.get("units", [0, 1]))
        self.need = int(cfg.get("need", 1))
        self.expiry = int(cfg.get("expiry", 3))
        self.sj_procs = {}
        self.cj_procs = {}
        self.sj_launch_fail = {}
        self.cj_launch_fail = {}
        self.cj_default_behavior = dict(cfg.get("cj_behavior", {"auto_start": True, "on_abort": "stop_exit"}))
        self.cj_behavior = {}
        self.job_ids = []
        self._jname = {}
        self._threads = []
        self.net = Network(self)

        # ---- ConfigService (supported configuration mechanism) ----
        cfg_dir = os.path.join(root, "config")
        os.makedirs(cfg_dir, exist_ok=True)
        ConfigService.reset()
        ConfigService.initialize(
            section_files={},
            config_path=[cfg_dir],
            var_dict={
                "client_outcome_wait_timeout": float(cfg.get("client_outcome_wait_timeout", 900.0)),
                "strict_start_job_reply_check": False,
            },
        )

        # ---- tracer (installed later, after bootstrap) ----
        self.tracer = Tracer(self, trace_path)

        # ---- expiry tick gating ----
        if not isinstance(_auto_clean_mod.time, GatedTime):
            _auto_clean_mod.time = GatedTime(_auto_clean_mod.time)
        self.gated_time = _auto_clean_mod.time

        # ---- server parent ----
        self.server_ws = os.path.join(root, "server")
        for d in ("startup", "local"):
            os.makedirs(os.path.join(self.server_ws, d), exist_ok=True)
        self.server_args = argparse.Namespace(workspace=self.server_ws, set=[], job_id=None, config_folder="config")
        self.server = FederatedServer(
            project_name="nvf-trace",
            min_num_clients=1,
            max_num_clients=100,
            cmd_modules=None,
            heart_beat_timeout=cfg.get("heart_beat_timeout", 3600.0),
            args=self.server_args,
            secure_train=False,
            snapshot_persistor=None,
        )
        self.engine = self.server.engine
        self.client_manager = self.server.client_manager
        self.server.cell = StubServerCell(self)
        self.admin_server = StubAdminServer(self)
        self.admin_server.sai = self.engine
        self.server.admin_server = self.admin_server
        self.server.server_state = HotState(host="localhost", port="8002")

        store_root = os.path.join(root, "jobs-storage")
        self.store = FilesystemStorage(root_dir=store_root, uri_root="/")
        self.job_manager = SimpleJobDefManager(uri_root=os.path.join(store_root, "jobs"))
        self.scheduler = DefaultJobScheduler(
            max_jobs=int(cfg.get("max_jobs", 1)),
            max_schedule_count=int(cfg.get("max_schedule_count", 10)),
            min_schedule_interval=float(cfg.get("min_schedule_interval", 0.0)),
            max_schedule_interval=float(cfg.get("max_schedule_interval", 600.0)),
        )
        self.runner = JobRunner(workspace_root=self.server_ws)
        self.sj_launcher = StubSJLauncher(self)
        components = {
            "job_store": self.store,
            SystemComponents.JOB_MANAGER: self.job_manager,
            SystemComponents.JOB_SCHEDULER: self.scheduler,
            SystemComponents.JOB_RUNNER: self.runner,
            "sj_launcher": self.sj_launcher,
        }
        handlers = [self.job_manager, self.scheduler, self.runner, self.sj_launcher]
        self.server_workspace = Workspace(root_dir=self.server_ws, site_name="server")
        self.run_manager = RunManager(
            server_name="server",
            engine=self.engine,
            job_id="",
            workspace=self.server_workspace,
            components=components,
            client_manager=self.client_manager,
            handlers=handlers,
        )
        self.engine.set_run_manager(self.run_manager)
        self.engine.set_job_runner(self.runner, self.job_manager)
        with self.engine.new_context() as fl_ctx:
            fl_ctx.set_prop(FLContextKey.WORKSPACE_OBJECT, self.server_workspace, private=True, sticky=True)
            fl_ctx.set_prop(FLContextKey.ARGS, self.server_args, private=True, sticky=True)
            fl_ctx.set_prop(FLContextKey.SITE_OBJ, self.server, private=True, sticky=True)

        # ---- client parents ----
        self.resource_observer = ResourceObserver(self)
        self.cps = {}
        self._engine_to_client = {}
        self._rm_to_client = {}
        self._executor_to_client = {}
        for i, cl in enumerate(self.client_names):
            cp = ClientParent(self, cl, f"token-{cl}", self.units, self.expiry)
            self.cps[cl] = cp
            self._engine_to_client[id(cp.engine)] = cl
            self._rm_to_client[id(cp.rm)] = cl
            self._executor_to_client[id(cp.executor)] = cl
            self.resource_observer.install(cp)

    # ------------------------------------------------------------ name mapping
    def jname(self, job_id):
        if job_id is None:
            return "None"
        return self._jname.get(job_id, f"?{job_id}")

    def cname(self, cl):
        if cl is None:
            return "None"
        if cl in self.cps:
            return f"c{self.client_names.index(cl) + 1}"
        return f"?{cl}"

    def unit_name(self, u):
        return f"u{u}"

    def real_job(self, jn):
        for k, v in self._jname.items():
            if v == jn:
                return k
        return None

    def real_client(self, cn):
        for cl in self.client_names:
            if self.cname(cl) == cn:
                return cl
        return None

    def client_name_of_engine(self, engine):
        return self._engine_to_client.get(id(engine))

    def client_name_of_rm(self, rm):
        return self._rm_to_client.get(id(rm))

    def client_name_of_executor(self, executor):
        return self._executor_to_client.get(id(executor))

    def map_arg(self, arg):
        out = {}
        for k, v in arg.items():
            if k == "failed":
                out[k] = sorted(self.cname(c) for c in v)
            else:
                out[k] = v
        return out

    def admin_identity(self, req, cl):
        topic = req.topic
        job_id = req.get_header(RequestHeader.JOB_ID)
        if topic == TrainingTopic.CHECK_RESOURCE:
            return {"type": "CHECK", "job": self.jname(job_id), "cl": self.cname(cl),
                    "att": getattr(req, "_tla_att", -1), "ok": False, "code": 0, "flag": False, "_to": cl}
        if topic == TrainingTopic.START_JOB:
            tok = req.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN)
            att, _ = self.tracer.token_info.get((cl, tok), (-1, None))
            return {"type": "START", "job": self.jname(job_id), "cl": self.cname(cl), "att": att, "ok": False,
                    "code": 0, "flag": False, "_to": cl}
        if topic == TrainingTopic.CANCEL_RESOURCE:
            tok = req.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN)
            att, jid = self.tracer.token_info.get((cl, tok), (-1, None))
            return {"type": "CANCEL", "job": self.jname(jid), "cl": self.cname(cl), "att": att, "ok": False,
                    "code": 0, "flag": False, "_to": cl}
        if topic == TrainingTopic.ABORT:
            return {"type": "ABORT", "job": self.jname(job_id), "cl": self.cname(cl), "att": 0, "ok": False,
                    "code": 0, "flag": False, "_to": cl}
        if topic == TrainingTopic.DEPLOY:
            return {"type": "DEPLOY", "job": self.jname(job_id), "cl": self.cname(cl), "_to": cl}
        return None

    # ------------------------------------------------------------ observation helpers (used by the tracer)
    def _job_dir(self, job_id):
        return self.store._object_path(self.job_manager.job_uri(job_id))

    def read_meta(self, job_id):
        try:
            return self.store.get_meta(self.job_manager.job_uri(job_id))
        except StorageException:
            return None

    def has_scheduled_tag(self, job_id):
        return os.path.exists(os.path.join(self._job_dir(job_id), "scheduled"))

    def sj_state(self, job_id):
        p = self.sj_procs.get(job_id)
        if p is None:
            return "None"
        return "Running" if p.leader_alive else "Exited"

    def cj_state(self, cl, job_id):
        p = self.cj_procs.get((cl, job_id))
        if p is None:
            return "None"
        return "Alive" if p.leader_alive else "Exited"

    # ------------------------------------------------------------ bootstrap
    def spawn(self, name, fn, *args):
        def target():
            try:
                fn(*args)
            except BaseException as e:  # noqa
                self.tracer.close_thread_sections(f"{type(e).__name__}: {e}")
                self.tracer._harness_error(f"thread {name} raised {e!r}")

        t = threading.Thread(target=target, name=name, daemon=True)
        t.start()
        self._threads.append(t)
        return t

    def register_clients(self):
        for cl in self.client_names:
            cp = self.cps[cl]
            c = Client(cl, cp.token)
            c.set_fqcn(cl)
            c.last_connect_time = time.time()
            with self.client_manager.lock:
                self.client_manager.clients[cp.token] = c
                self.client_manager.name_to_clients[cl] = c

    def system_start(self):
        with self.engine.new_context() as fl_ctx:
            self.engine.fire_event(EventType.SYSTEM_START, fl_ctx)
        for cl in self.client_names:
            cp = self.cps[cl]
            self.gated_time.register(cp.rm._cleanup_thread)
            with cp.engine.new_context() as fl_ctx:
                cp.engine.fire_event(EventType.SYSTEM_START, fl_ctx)

    @staticmethod
    def _job_zip(folder_name):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr(f"{folder_name}/meta.json", json.dumps({"name": folder_name}))
            z.writestr(f"{folder_name}/app/config/config_fed_server.json", json.dumps({"format_version": 2}))
            z.writestr(f"{folder_name}/app/config/config_fed_client.json", json.dumps({"format_version": 2}))
        return buf.getvalue()

    def submit_jobs(self, jobs):
        """jobs: list of dicts {name, deploy_sites, min_sites, required}. Submitted in order (SUBMIT_TIME increasing)."""
        for i, j in enumerate(jobs):
            folder = j["name"]
            meta = {
                JobMetaKey.JOB_NAME.value: j["name"],
                JobMetaKey.JOB_FOLDER_NAME.value: folder,
                JobMetaKey.DEPLOY_MAP.value: {"app": ["server"] + list(j["deploy_sites"])},
                JobMetaKey.MIN_CLIENTS.value: j["min_sites"],
                JobMetaKey.MANDATORY_CLIENTS.value: list(j.get("required", [])),
                JobMetaKey.RESOURCE_SPEC.value: {s: {"gpu": self.need} for s in j["deploy_sites"]},
                JobMetaKey.SUBMITTER_NAME.value: "admin@nvidia.com",
                JobMetaKey.SUBMITTER_ORG.value: "nvidia",
                JobMetaKey.SUBMITTER_ROLE.value: "project_admin",
            }
            with self.engine.new_context() as fl_ctx:
                meta = self.job_manager.create(meta, self._job_zip(folder), fl_ctx)
            jid = meta[JobMetaKey.JOB_ID.value]
            self.job_ids.append(jid)
            self._jname[jid] = f"j{i + 1}"
            time.sleep(0.02)  # strictly increasing SUBMIT_TIME
        self.jobs_cfg = jobs

    def config_line(self):
        c = self.cfg
        jobs = {self.jname(jid): j for jid, j in zip(self.job_ids, self.jobs_cfg)}
        return {
            "jobs": [self.jname(j) for j in self.job_ids],
            "clients": [self.cname(c_) for c_ in self.client_names],
            "units": [self.unit_name(u) for u in self.units],
            "need": self.need,
            "deploy_sites": {jn: sorted(self.cname(s) for s in j["deploy_sites"]) for jn, j in jobs.items()},
            "min_sites": {jn: j["min_sites"] for jn, j in jobs.items()},
            "required": {jn: sorted(self.cname(s) for s in j.get("required", [])) for jn, j in jobs.items()},
            "max_jobs": int(c.get("max_jobs", 1)),
            "max_schedule_count": int(c.get("max_schedule_count", 10)),
            "expiry": self.expiry,
            "scenario": c.get("scenario", ""),
            "real_job_ids": {self.jname(j): j for j in self.job_ids},
            "real_clients": {self.cname(c_): c_ for c_ in self.client_names},
        }

    def start_tracing(self):
        self.tracer.write_config(self.config_line())
        tla_hooks.install(self.tracer)

    def start_runner(self):
        fl_ctx = self.engine.new_context()
        self.runner_result = {"exception": None}

        def target():
            try:
                self.runner.run(fl_ctx)
            except BaseException as e:  # observation only: run() has already terminated here
                self.tracer.close_thread_sections(f"{type(e).__name__}: {e}")
                self.runner_result["exception"] = f"{type(e).__name__}: {e}"
                log.warning(f"JobRunner.run terminated by exception: {e!r}")

        self.runner_thread = threading.Thread(target=target, name="JobRunner.run", daemon=True)
        self.runner_thread.start()

    # ------------------------------------------------------------ SJ behaviour (process edge)
    def sj_finish(self, job_id, execution_error=False, rc=0):
        """SjFinish: ServerAppRunner's finally sends UPDATE_RUN_STATUS (fire-and-forget), then the process exits."""
        proc = self.sj_procs[job_id]
        with self.tracer.section("SjFinish", job=job_id, arg={"execution_error": bool(execution_error), "rc": rc}) as sec:
            if not proc.leader_alive:
                sec.cancel()
                return False
            self.net.sj_update_run_status(job_id, bool(execution_error))
            proc._exit(rc)
        return True

    def sj_crash(self, job_id):
        proc = self.sj_procs[job_id]
        with self.tracer.section("SjCrash", job=job_id) as sec:
            if not proc.leader_alive:
                sec.cancel()
                return False
            proc._exit(-9)
        return True

    def sj_handle_abort(self, job_id, ident):
        """SjHandleAbort: ABORT command reaches the SJ cell; a running SJ aborts, reports and exits 0."""
        proc = self.sj_procs.get(job_id)
        with self.tracer.section("SjHandleAbort", msg=ident):
            if proc is not None and proc.leader_alive:
                self.net.sj_update_run_status(job_id, False)
                proc._exit(0)

    # ------------------------------------------------------------ CJ behaviour (process edge)
    def _notify(self, cl, job_id, status):
        cp = self.cps[cl]
        req = Message(topic=TrainingTopic.NOTIFY_JOB_STATUS, body="")
        req.set_header(RequestHeader.JOB_ID, job_id)
        req.set_header(RequestHeader.JOB_STATUS, status)
        cp.processors[TrainingTopic.NOTIFY_JOB_STATUS].process(req, cp.engine)

    def _cj_auto_start(self, cl, job_id):
        time.sleep(0.05)
        self.cj_notify_started(cl, job_id)

    def cj_notify_started(self, cl, job_id):
        proc = self.cj_procs.get((cl, job_id))
        cp = self.cps[cl]
        with self.tracer.section("CjNotifyStarted", cl=cl, job=job_id) as sec:
            reg = cp.executor.run_processes.get(job_id)
            if not (cp.alive and proc and proc.leader_alive and reg and reg.get(RunProcessKey.STATUS) == ClientStatus.STARTING):
                sec.cancel()  # the CJ is not running as STARTING (e.g. killed at attach): nothing is reported
                return
            self._notify(cl, job_id, ClientStatus.STARTED)

    def cj_notify_stopped(self, cl, job_id):
        proc = self.cj_procs.get((cl, job_id))
        cp = self.cps[cl]
        with self.tracer.section("CjNotifyStopped", cl=cl, job=job_id) as sec:
            reg = cp.executor.run_processes.get(job_id)
            if not (cp.alive and proc and proc.leader_alive and reg and reg.get(RunProcessKey.STATUS) == ClientStatus.STARTED):
                sec.cancel()
                return
            self._notify(cl, job_id, ClientStatus.STOPPED)

    def _cj_on_abort(self, cl, job_id):
        """CjHandleAbort: the CJ's runner aborts on the CP's ABORT and reports STOPPED (when STARTED).

        CJ behaviours: "stop_exit" (default: handle, then exit 0), "stop_only" (handle, but slow teardown: the CJ does
        not exit, so the CP's _terminate_job kills it after its grace), "ignore" (unresponsive CJ: the ABORT is never
        handled, no event)."""
        proc = self.cj_procs.get((cl, job_id))
        cp = self.cps[cl]
        behavior = self.cj_behavior.get((cl, job_id), self.cj_default_behavior)
        on_abort = behavior.get("on_abort", "stop_exit")
        if on_abort == "ignore":
            return
        with self.tracer.section("CjHandleAbort", cl=cl, job=job_id):
            reg = cp.executor.run_processes.get(job_id)
            if (
                cp.alive
                and proc
                and proc.leader_alive
                and reg
                and reg.get(RunProcessKey.STATUS) == ClientStatus.STARTED
            ):
                self._notify(cl, job_id, ClientStatus.STOPPED)
        if on_abort == "stop_exit" and cp.alive and proc and proc.leader_alive:
            time.sleep(0.05)
            self.cj_exit(cl, job_id, 0, False)

    def cj_exit(self, cl, job_id, rc=0, descendants=False):
        """CjExit: the CJ leader exits with rc in {0, 1, 102}; rc 102 is conveyed by the rc file (mpm.py)."""
        proc = self.cj_procs[(cl, job_id)]
        cp = self.cps[cl]
        with self.tracer.section("CjExit", cl=cl, job=job_id, arg={"rc": rc, "descendants": bool(descendants)}) as sec:
            reg = cp.executor.run_processes.get(job_id)
            st = reg.get(RunProcessKey.STATUS) if reg else None
            # cooperative CJ: exit 0 only after its runner started; the UNSAFE rc file only while STARTING (mpm.py)
            if (
                not cp.alive
                or not proc.leader_alive
                or (rc == 0 and st not in (ClientStatus.STARTED, ClientStatus.STOPPED))
                or (rc == 102 and st != ClientStatus.STARTING)
            ):
                sec.cancel()
                return False
            if rc == 102:
                run_dir = os.path.join(cp.ws, job_id)
                os.makedirs(run_dir, exist_ok=True)
                with open(os.path.join(run_dir, "_process_rc.txt"), "w") as f:
                    f.write("102")
            proc.descendants = bool(descendants)
            proc._exit(rc)
        return True

    def cj_group_exit(self, cl, job_id):
        proc = self.cj_procs[(cl, job_id)]
        with self.tracer.section("CjGroupExit", cl=cl, job=job_id) as sec:
            if not proc.descendants:
                sec.cancel()
                return
            proc.descendants = False

    def finish_client_job(self, cl, job_id, rc=0):
        self.cj_notify_stopped(cl, job_id)
        self.cj_exit(cl, job_id, rc, False)

    # ------------------------------------------------------------ CP-level actions
    def tick(self, cl):
        """CpTick: release one real AutoClean expiry tick of cl's resource manager."""
        cp = self.cps[cl]
        ok = self.gated_time.tick(cp.rm._cleanup_thread)
        if not ok:
            self.tracer._harness_error(f"tick on {cl} did not complete")

    def heartbeat(self, cl):
        """Heartbeat: CP job list -> FederatedServer._sync_client_jobs -> abort list processed by the CP."""
        cp = self.cps[cl]
        with self.tracer.section("Heartbeat", cl=cl) as sec:
            if not cp.alive or cp.token not in self.client_manager.clients:
                sec.cancel()  # only a live, registered CP heartbeats
                return []
            job_ids = cp.engine.get_all_job_ids()
            req = CellMessage(headers={}, payload=Shareable())
            req.set_header(CellMessageHeaderKeys.JOB_IDS, job_ids)
            req.set_header(CellMessageHeaderKeys.TOKEN, cp.token)
            req.set_header(CellMessageHeaderKeys.CLIENT_NAME, cl)
            req.set_header(MessageHeaderKey.ORIGIN, cl)
            abort_jobs = self.server._sync_client_jobs(req, cp.token)
        if abort_jobs:
            cp.comm._clean_up_runs(cp.engine, abort_jobs)
        return abort_jobs

    def client_crash(self, cl):
        cp = self.cps[cl]
        with self.tracer.section("ClientCrash", cl=cl):
            cp.alive = False
            for (c2, jid), proc in list(self.cj_procs.items()):
                if c2 == cl:
                    if proc.leader_alive:
                        proc._exit(-9)  # CJs stop on parent death
                    proc.descendants = False
            self.net.purge_to_client(cl)

    def sweep_dead_client(self, cl):
        """Dead-client sweeper iteration (BaseServer.client_cleanup -> remove_dead_clients) for a CP that stopped
        heartbeating: its last_connect_time is older than heart_beat_timeout."""
        cp = self.cps[cl]
        c = self.client_manager.clients.get(cp.token)
        if c is not None:
            c.last_connect_time = 0.0
        self.server.remove_dead_clients()

    # ------------------------------------------------------------ admin commands (real JobCommandModule)
    def _conn(self, props):
        env = self

        class FakeConn:
            def __init__(self):
                self.app_ctx = env.engine
                self.props = dict(props)
                self.out = []

            def get_prop(self, k, default=None):
                return self.props.get(k, default)

            def set_prop(self, k, v):
                self.props[k] = v

            def append_string(self, s, meta=None):
                self.out.append(("string", s))

            def append_success(self, s, meta=None):
                self.out.append(("success", s))

            def append_error(self, s, meta=None):
                self.out.append(("error", s))

        return FakeConn()

    def admin_abort(self, job_id):
        conn = self._conn({JobCommandModule.JOB_ID: job_id})
        JobCommandModule().abort_job(conn, ["abort_job", job_id])
        return conn.out

    def admin_delete(self, job_id):
        cmd = JobCommandModule()
        conn = self._conn({})
        with self.tracer.context("admin_delete"):
            rc = cmd.authorize_job_id(conn, ["delete_job", job_id])
            if conn.get_prop(JobCommandModule.JOB) is not None:
                cmd.delete_job(conn, ["delete_job", job_id])
        return conn.out

    def admin_disable(self, cl):
        return self.engine.disable_clients([cl])
