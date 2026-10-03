#!/usr/bin/env python3
"""Specula code-analysis verification harness: NVFlare server-side job lifecycle candidates.

REAL product code exercised (imported from the pinned checkout, unmodified):
  - nvflare.private.fed.server.job_runner.JobRunner: run(), _start_run(), _job_complete_process(),
    _stop_run(), stop_run(), mark_run_aborted(), and its exception handler
  - nvflare.app_common.job_schedulers.job_scheduler.DefaultJobScheduler (admission / scheduled_jobs accounting)
  - nvflare.apis.impl.job_def_manager.SimpleJobDefManager on nvflare.app_common.storages.filesystem_storage.FilesystemStorage
  - nvflare.private.fed.server.job_cmds.JobCommandModule.abort_job / delete_job (admin command handlers)
  - nvflare.private.fed.server.admin.check_client_replies (via _start_run)

STUBS (network / process edges only, documented per scenario):
  - FakeEngine: client RPC fan-out (check/cancel resources, START_JOB, ABORT) returns OK replies; start_app_on_server
    registers a run_processes entry exactly like ServerEngine._start_runner_process does (no real SJ process);
    sj_exit() mirrors ServerEngine.wait_for_complete (records a non-zero rc into exception_run_processes, pops entry).
  - JobRunner._deploy_job is replaced PER INSTANCE by a no-network success that returns (job_id, []) and sets
    JOB_DEPLOY_DETAIL, i.e. the documented contract "Returns: job id, failed_clients".
REPRODUCTION CONTROLS (behavior-preserving; they only choose WHEN a concurrent operation happens):
  - hook points inside the stubs run a real admin handler (abort_job / delete_job) at a chosen moment, emulating an
    admin command thread that arrives while the runner thread is at that step.
  - optional delay wrapper around job_manager.set_status(RUNNING) that waits for a bounded time (models the runner
    thread being descheduled between job_runner.py:710 and :711).
OBSERVATION HOOKS: a recording wrapper around job_manager.set_status (calls through unchanged), event log, and a
wrapper that records the exception that escapes JobRunner.run (the loop has already terminated at that point).
"""

import argparse
import json
import os
import sys
import tempfile
import threading
import time
import traceback
from types import SimpleNamespace

SOURCE = "/home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/full/source"

import nvflare  # noqa: E402

assert os.path.realpath(nvflare.__file__).startswith(SOURCE), nvflare.__file__

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager  # noqa: E402
from nvflare.apis.job_def import JobMetaKey, RunStatus  # noqa: E402
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.apis.utils.event import fire_event_to_components  # noqa: E402
from nvflare.apis.workspace import Workspace  # noqa: E402
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler  # noqa: E402
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage  # noqa: E402
from nvflare.fuel.common.exit_codes import ProcessExitCode  # noqa: E402
from nvflare.private.admin_defs import Message  # noqa: E402
from nvflare.private.defs import RequestHeader  # noqa: E402
from nvflare.private.fed.server.job_cmds import JobCommandModule  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.message_send import ClientReply  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402

LOG = []
LOG_LOCK = threading.Lock()
T0 = time.monotonic()


def log(msg):
    with LOG_LOCK:
        line = f"[{time.monotonic() - T0:7.3f}s][{threading.current_thread().name}] {msg}"
        LOG.append(line)
        print(line, flush=True)


class FakeAdminServer:
    timeout = 5.0

    def __init__(self, engine):
        self.engine = engine
        self.sai = engine
        self.sent = []

    def send_requests(self, requests, fl_ctx, timeout_secs=2.0, optional=False):
        replies = []
        for token, msg in requests.items():
            c = self.engine.client_manager.clients[token]
            self.sent.append((c.name, msg.topic, msg.get_header(RequestHeader.JOB_ID)))
            log(f"admin->client {c.name}: topic={msg.topic} job={msg.get_header(RequestHeader.JOB_ID)}")
            replies.append(ClientReply(token, c.name, msg, Message(topic="reply_" + msg.topic, body="OK")))
        return replies

    def send_requests_and_get_reply_dict(self, requests, timeout_secs=2.0):
        return {r.client_token: r.reply for r in self.send_requests(requests, None, timeout_secs)}


class FakeEngine:
    def __init__(self, root, clients):
        self.root = root
        for d in ("ws/startup", "ws/local", "store/jobs"):
            os.makedirs(os.path.join(root, d), exist_ok=True)
        self.storage = FilesystemStorage(root_dir=os.path.join(root, "store"), uri_root="/")
        self.job_manager = SimpleJobDefManager(uri_root=os.path.join(root, "store", "jobs"))
        self.scheduler = DefaultJobScheduler(
            max_jobs=1, max_schedule_count=10, min_schedule_interval=0.0, max_schedule_interval=1.0
        )
        self.job_runner = JobRunner(workspace_root=os.path.join(root, "ws"))
        self.job_def_manager = self.job_manager
        self.components = {
            "job_store": self.storage,
            SystemComponents.JOB_MANAGER: self.job_manager,
            SystemComponents.JOB_SCHEDULER: self.scheduler,
            SystemComponents.JOB_RUNNER: self.job_runner,
        }
        self.run_processes = {}
        self.exception_run_processes = {}
        self.lock = threading.Lock()
        self.client_manager = SimpleNamespace(clients={c.token: c for c in clients})
        self.server = SimpleNamespace(server_state=HotState(), admin_server=None)
        self.server.admin_server = FakeAdminServer(self)
        self.fl_ctx_mgr = FLContextManager(
            engine=self, identity_name="server", job_id="", public_stickers={}, private_stickers={}
        )
        self.workspace = Workspace(root_dir=os.path.join(root, "ws"), site_name="server")
        self.hooks = {}
        self.events = []
        self.cancelled = []
        self.sj_started = []
        self.sj_aborted = []

    # --- EngineSpec surface used by the real components ---
    def new_context(self):
        return self.fl_ctx_mgr.new_context()

    def get_component(self, cid):
        return self.components.get(cid)

    def get_workspace(self):
        return self.workspace

    def fire_event(self, event_type, fl_ctx):
        data = fl_ctx.get_prop(FLContextKey.EVENT_DATA)
        if event_type in (EventType.JOB_STARTED, EventType.JOB_COMPLETED, EventType.JOB_ABORTED):
            log(f"event {event_type} data={data}")
            self.events.append((event_type, data))
        fire_event_to_components(event_type, [self.scheduler], fl_ctx)

    def get_clients(self):
        return list(self.client_manager.clients.values())

    def get_client_from_name(self, name):
        for c in self.client_manager.clients.values():
            if c.name == name:
                return c
        return None

    def validate_targets(self, names):
        found, invalid = [], []
        for n in names:
            c = self.get_client_from_name(n)
            (found.append(c) if c else invalid.append(n))
        return found, invalid

    def get_job_clients(self, client_sites):
        return {c.token: c for c in (self.get_client_from_name(s) for s in client_sites) if c}

    def _hook(self, name, **kw):
        fn = self.hooks.get(name)
        if fn:
            log(f"hook '{name}' firing")
            fn(**kw)

    # --- stubbed RPC / process edges ---
    def check_client_resources(self, job, resource_reqs, fl_ctx):
        self._hook("check_client_resources", job=job)
        return {s: (True, f"tok-{job.job_id[:8]}-{s}") for s in resource_reqs if self.get_client_from_name(s)}

    def cancel_client_resources(self, resource_check_results, resource_reqs, fl_ctx):
        self.cancelled.append(dict(resource_check_results))
        log(f"cancel_client_resources {resource_check_results}")

    def start_app_on_server(self, fl_ctx, job=None, job_clients=None, snapshot=None):
        if job.job_id in self.run_processes:
            return f"Server run: {job.job_id} already started."
        with self.lock:
            self.run_processes[job.job_id] = {
                RunProcessKey.JOB_HANDLE: None,
                RunProcessKey.JOB_ID: job.job_id,
                RunProcessKey.PARTICIPANTS: job_clients,
            }
        self.sj_started.append(job.job_id)
        log(f"SJ launched for job {job.job_id[:8]}")
        self._hook("start_app_on_server", job=job)
        return ""

    def start_client_job(self, job, client_sites, fl_ctx):
        self._hook("start_client_job", job=job)
        replies = []
        for site in client_sites:
            c = self.get_client_from_name(site)
            log(f"START_JOB -> {site} job={job.job_id[:8]}")
            replies.append(ClientReply(c.token, c.name, None, Message(topic="reply_start_job", body="OK")))
        return replies

    def abort_app_on_server(self, job_id, turn_to_cold=False):
        self.sj_aborted.append(job_id)
        log(f"abort_app_on_server {job_id[:8]}")
        self.sj_exit(job_id, return_code=None)
        return ""

    def remove_exception_process(self, job_id):
        """Mirror of ServerEngine.remove_exception_process (server_engine.py:198-201)."""
        with self.lock:
            if job_id in self.exception_run_processes:
                self.exception_run_processes.pop(job_id)

    def sj_exit(self, job_id, return_code=None):
        """Mirror of ServerEngine.wait_for_complete bookkeeping (server_engine.py:203-234)."""
        with self.lock:
            info = self.run_processes.get(job_id)
            if info is not None:
                info[RunProcessKey.PROCESS_FINISHED] = return_code in (None, 0)
                if return_code:
                    if job_id not in self.exception_run_processes:
                        info[RunProcessKey.PROCESS_RETURN_CODE] = return_code
                        self.exception_run_processes[job_id] = info
                self.run_processes.pop(job_id, None)
        log(f"SJ exited job={job_id[:8]} rc={return_code}")


ServerEngineSpec.register(FakeEngine)


class FakeConn:
    def __init__(self, engine, props):
        self.app_ctx = engine
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


def admin_abort(engine, job_id):
    conn = FakeConn(engine, {JobCommandModule.JOB_ID: job_id})
    JobCommandModule().abort_job(conn, ["abort_job", job_id])
    log(f"ADMIN abort_job({job_id[:8]}) -> {conn.out}")
    return conn.out


def admin_delete(engine, job_id):
    with engine.new_context() as fl_ctx:
        job = engine.job_manager.get_job(job_id, fl_ctx)
    conn = FakeConn(engine, {JobCommandModule.JOB_ID: job_id, JobCommandModule.JOB: job})
    JobCommandModule().delete_job(conn, ["delete_job", job_id])
    log(f"ADMIN delete_job({job_id[:8]}) -> {conn.out}")
    return conn.out


def store_status(engine, job_id):
    with engine.new_context() as fl_ctx:
        job = engine.job_manager.get_job(job_id, fl_ctx)
    return None if job is None else job.meta.get(JobMetaKey.STATUS)


def submit(engine, name):
    meta = {
        JobMetaKey.JOB_NAME.value: name,
        JobMetaKey.DEPLOY_MAP.value: {"app": ["server", "site-1", "site-2"]},
        JobMetaKey.MIN_CLIENTS.value: 1,
        JobMetaKey.RESOURCE_SPEC.value: {},
    }
    with engine.new_context() as fl_ctx:
        meta = engine.job_manager.create(meta, b"PK-not-used-by-stubbed-deploy", fl_ctx)
    log(f"submitted {name} job_id={meta[JobMetaKey.JOB_ID.value]}")
    return meta[JobMetaKey.JOB_ID.value]


def install_observers(engine, delay_running_until=None):
    """Recording wrapper around set_status (observation), optional bounded delay for RUNNING (reproduction control)."""
    real_set_status = engine.job_manager.set_status
    history = []

    def recording_set_status(jid, status, fl_ctx):
        if delay_running_until is not None and status == RunStatus.RUNNING:
            log("reproduction control: delaying set_status(RUNNING) until completion thread publishes (<=15s)")
            delay_running_until.wait(timeout=15.0)
        try:
            real_set_status(jid, status, fl_ctx)
            history.append((round(time.monotonic() - T0, 3), threading.current_thread().name, jid[:8], status.value))
            log(f"set_status({jid[:8]}, {status.value}) OK")
        except Exception as e:
            history.append((round(time.monotonic() - T0, 3), threading.current_thread().name, jid[:8],
                            f"{status.value} RAISED {type(e).__name__}"))
            log(f"set_status({jid[:8]}, {status.value}) RAISED {type(e).__name__}: {e}")
            raise

    engine.job_manager.set_status = recording_set_status
    return history


def stub_deploy(engine):
    runner = engine.job_runner

    def _deploy_job(job, sites, fl_ctx):
        fl_ctx.set_prop(FLContextKey.JOB_DEPLOY_DETAIL, ["server: OK"] + [f"{s}: OK" for s in sites if s != "server"])
        log(f"(stub) deploying job {job.job_id[:8]} to {sorted(sites)}")
        engine._hook("deploy", job=job)
        return job.job_id, []

    runner._deploy_job = _deploy_job


def start_runner(engine):
    runner = engine.job_runner
    runner.scheduler = engine.scheduler  # equivalent to handle_event(SYSTEM_START)
    result = {"exception": None}

    def target():
        fl_ctx = engine.new_context()
        try:
            runner.run(fl_ctx)
        except BaseException as e:  # observation only: run() has already terminated here
            result["exception"] = "".join(traceback.format_exception_only(type(e), e)).strip()
            log(f"!!! JobRunner.run() TERMINATED by exception: {result['exception']}")
            log("traceback:\n" + traceback.format_exc())

    t = threading.Thread(target=target, name="JobRunner.run", daemon=True)
    t.start()
    return t, result


def wait_until(pred, timeout, step=0.1):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(step)
    return pred()


def finish_normally(engine, job_id):
    engine.sj_exit(job_id, return_code=None)
    for site in ("site-1", "site-2"):
        engine.job_runner.resolve_client_outcome(job_id, site)  # mirrors process_job_failure() resolution


def scenario(name, root):
    clients = [Client("site-1", "tok-site-1"), Client("site-2", "tok-site-2")]
    engine = FakeEngine(root, clients)
    stub_deploy(engine)
    released = threading.Event()
    history = install_observers(engine, delay_running_until=released if name == "B_running_overwrite" else None)
    report = {"scenario": name}

    if name == "S0_control":
        j1 = submit(engine, "job1")
        j2 = submit(engine, "job2")
        t, res = start_runner(engine)
        wait_until(lambda: store_status(engine, j1) == RunStatus.RUNNING.value, 10)
        finish_normally(engine, j1)
        wait_until(lambda: store_status(engine, j2) == RunStatus.RUNNING.value, 15)
        finish_normally(engine, j2)
        wait_until(lambda: str(store_status(engine, j2)).startswith("FINISHED"), 10)
        report.update(final={"job1": store_status(engine, j1), "job2": store_status(engine, j2)})

    elif name in ("A1_abort_during_deploy", "A2_abort_during_start"):
        j1 = submit(engine, "job1")
        replies = {}
        hook_name = "deploy" if name.startswith("A1") else "start_client_job"
        engine.hooks[hook_name] = lambda job: replies.setdefault("abort", admin_abort(engine, job.job_id)) and \
            log(f"store status right after admin abort: {store_status(engine, job.job_id)}")
        t, res = start_runner(engine)
        wait_until(lambda: j1 in engine.job_runner.running_jobs, 10)
        time.sleep(1.5)
        report["status_while_running"] = store_status(engine, j1)
        report["sj_started_after_abort"] = j1 in engine.sj_started
        report["start_job_sent"] = [s for s in engine.server.admin_server.sent] + ["(START_JOB via start_client_job)"]
        report["scheduler_slots"] = list(engine.scheduler.scheduled_jobs)
        finish_normally(engine, j1)
        wait_until(lambda: j1 not in engine.job_runner.running_jobs, 10)
        report["admin_reply"] = replies.get("abort")
        report["final"] = store_status(engine, j1)

    elif name == "B_running_overwrite":
        j1 = submit(engine, "job1")

        def sj_crashes_during_client_start(job):
            engine.sj_exit(job.job_id, return_code=ProcessExitCode.EXCEPTION)  # SJ fails early (e.g. config error)

        engine.hooks["start_client_job"] = sj_crashes_during_client_start
        real_fire = engine.fire_event

        def fire_and_release(event_type, fl_ctx):
            real_fire(event_type, fl_ctx)
            if event_type == EventType.JOB_COMPLETED:
                released.set()

        engine.fire_event = fire_and_release
        t, res = start_runner(engine)
        wait_until(lambda: released.is_set(), 20)
        time.sleep(2.0)
        report["final"] = store_status(engine, j1)
        report["running_jobs"] = list(engine.job_runner.running_jobs)
        report["scheduler_slots"] = list(engine.scheduler.scheduled_jobs)
        report["abort_after"] = admin_abort(engine, j1)
        report["delete_after"] = admin_delete(engine, j1)

    elif name in ("G1_delete_during_schedule", "G2_delete_during_deploy"):
        j1 = submit(engine, "job1")
        hook_name = "check_client_resources" if name.startswith("G1") else "deploy"
        fired = {}

        def delete_it(job):
            if job.job_id == j1 and not fired:
                fired["x"] = admin_delete(engine, job.job_id)

        engine.hooks[hook_name] = delete_it
        t, res = start_runner(engine)
        wait_until(lambda: not t.is_alive(), 10)
        j2 = submit(engine, "job2-later-eligible")
        time.sleep(5.0)
        report["delete_reply"] = fired.get("x")
        report["runner_thread_alive"] = t.is_alive()
        report["runner_exception"] = res["exception"]
        report["later_job_status_after_5s"] = store_status(engine, j2)
        report["later_job_ever_scheduled"] = j2 in engine.sj_started

    elif name == "K_failrun_during_start":
        # A client's CJ fails right after launch; its CP reports REPORT_JOB_FAILURE(EXCEPTION) while the runner thread
        # is still inside _start_run (START_JOB replies not yet processed). fed_server.process_job_failure ->
        # is_client_outcome_pending (true: set at job_runner.py:309) -> fail_run(job, EXCEPTION). Here the hook calls
        # the same two JobRunner methods process_job_failure calls (fed_server.py:938-956), in the same order.
        j1 = submit(engine, "job1")

        def client_reports_failure(job):
            jr = engine.job_runner
            pending = jr.is_client_outcome_pending(job.job_id, "site-1")
            with engine.new_context() as fl_ctx:
                msg = jr.fail_run(job.job_id, ProcessExitCode.EXCEPTION, fl_ctx)
            jr.resolve_client_outcome(job.job_id, "site-1")
            log(f"process_job_failure path: pending={pending} fail_run -> {msg!r}")

        engine.hooks["start_client_job"] = client_reports_failure
        t, res = start_runner(engine)
        wait_until(lambda: str(store_status(engine, j1)).startswith("FINISHED"), 10)
        time.sleep(2.0)
        report["final"] = store_status(engine, j1)
        report["exception_run_processes_left"] = [k[:8] for k in engine.exception_run_processes]
        report["scheduler_slots"] = list(engine.scheduler.scheduled_jobs)

    elif name == "H_stop_all_runs":
        # Two RUNNING jobs (max_jobs raised to 2). Server shutdown calls JobRunner.stop_all_runs(), which iterates the
        # live engine.run_processes.keys() view. The first job's SJ exits while the loop is still running (the real
        # wait_for_complete / _remove_run_processes threads pop the entry); here abort_app_on_server pops it
        # synchronously, which is the same interleaving with the SJ exit landing before the loop advances.
        engine.scheduler.max_jobs = 2
        j1 = submit(engine, "job1")
        j2 = submit(engine, "job2")
        t, res = start_runner(engine)
        wait_until(lambda: len(engine.job_runner.running_jobs) == 2, 15)
        report["running_before"] = [j[:8] for j in engine.run_processes]
        err = None
        try:
            with engine.new_context() as fl_ctx:
                engine.job_runner.stop_all_runs(fl_ctx)
        except Exception as e:
            err = f"{type(e).__name__}: {e}"
            log(f"stop_all_runs raised {err}")
        report["stop_all_runs_exception"] = err
        report["sj_aborted"] = [j[:8] for j in engine.sj_aborted]
        report["still_running_sj"] = [j[:8] for j in engine.run_processes]
        report["runner_ask_to_stop"] = engine.job_runner.ask_to_stop
        report["run_aborted_flags"] = {j[:8]: job.run_aborted for j, job in engine.job_runner.running_jobs.items()}

    engine.job_runner.ask_to_stop = True
    report["status_history"] = history
    report["events"] = [(e, (d or {}).get("job_id", "")[:8]) for e, d in engine.events]
    report["cancel_calls"] = len(engine.cancelled)
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    root = tempfile.mkdtemp(prefix=f"nvf-{a.scenario}-")
    rep = scenario(a.scenario, root)
    log("REPORT " + json.dumps(rep, indent=2, default=str))
    with open(a.out, "w") as f:
        f.write("\n".join(LOG) + "\n")
    time.sleep(0.5)
    os._exit(0)


if __name__ == "__main__":
    main()
