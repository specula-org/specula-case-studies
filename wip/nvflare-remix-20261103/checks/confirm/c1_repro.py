"""C1 confirmation on the pinned source (c411a201), read-only via sys.path.

JobRunner.run() inserts the job into running_jobs before it writes RUNNING
(job_runner.py:767-770). If that write raises, the except branch removes the
job, stops it, and writes FAILED_TO_RUN unless the status is FINISHED_ABORTED
(job_runner.py:771-799). The completion thread (_job_complete_process,
job_runner.py:492-591) handles every job that is in running_jobs and no longer
in engine.run_processes, so it can pick the job up inside that window.

The real JobRunner, its run() loop and its completion thread are used
unchanged. Fakes stand in for the engine, the job store, the scheduler and
the workspace. Deployment is stubbed (_deploy_job), because it does not touch
the window. The SJ "crashes" during client start (it leaves run_processes with
return code EXCEPTION), like ServerEngine.wait_for_complete does. The store
fault is injected into the RUNNING write only; scheduling is forced with events.

  A  set_status(RUNNING) stalls, then raises; the completion thread finishes
     inside the stall -> FINISHED_EXECUTION_EXCEPTION is published, then
     overwritten by FAILED_TO_RUN (the model's C1 trace).
  A2 as A, but the job is short and its SJ finishes normally during the stall
     -> FINISHED:COMPLETED (results archived) is overwritten by FAILED_TO_RUN.
  B  set_status(RUNNING) raises while the completion thread is archiving the
     workspace -> the except branch deletes running_jobs[job_id] first and the
     completion thread's own `del self.running_jobs[job_id]` (line 583) raises
     KeyError; the thread dies, and a later, fault-free job is never finalized.
  C  control: same scenario without the store fault.
"""
import errno, os, shutil, sys, tempfile, threading, time, types
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.job_def import Job, JobMetaKey, RunStatus  # noqa: E402
from nvflare.apis.job_scheduler_spec import DispatchInfo  # noqa: E402
from nvflare.fuel.common.exit_codes import ProcessExitCode  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402

WAIT = 20.0
RUNNING, FAILED = RunStatus.RUNNING.value, RunStatus.FAILED_TO_RUN.value
EXC, DONE = RunStatus.FINISHED_EXECUTION_EXCEPTION.value, RunStatus.FINISHED_COMPLETED.value


class Store:
    """In-memory job store with the JobDefManager calls JobRunner makes."""

    def __init__(self):
        self.meta, self.history, self.lock = {}, [], threading.Lock()
        self.on_status = {}      # (job_id, status value) -> hook run before the write
        self.on_save_workspace = None

    def add(self, jid):
        self.meta[jid] = {JobMetaKey.STATUS.value: RunStatus.SUBMITTED.value, JobMetaKey.JOB_ID.value: jid,
                          JobMetaKey.SCHEDULE_COUNT.value: 1, JobMetaKey.LAST_SCHEDULE_TIME.value: 0,
                          JobMetaKey.SCHEDULE_HISTORY.value: []}

    def status(self, jid):
        return self.meta[jid][JobMetaKey.STATUS.value]

    def set_status(self, jid, status, fl_ctx):
        hook = self.on_status.pop((jid, RunStatus(status).value), None)
        if hook:
            hook()              # may block, may raise
        with self.lock:
            self.meta[jid][JobMetaKey.STATUS.value] = RunStatus(status).value
            self.history.append((threading.current_thread().name, jid, RunStatus(status).value))

    def get_job(self, jid, fl_ctx):
        m = self.meta.get(jid)
        return None if m is None else Job(jid, {}, {}, dict(m))

    def update_meta(self, jid, meta, fl_ctx):
        self.meta[jid].update(meta)

    def get_jobs_to_schedule(self, fl_ctx):
        return [self.get_job(j, fl_ctx) for j, m in self.meta.items()
                if m[JobMetaKey.STATUS.value] == RunStatus.SUBMITTED.value]

    def get_jobs_by_status(self, statuses, fl_ctx):
        vals = {RunStatus(s).value for s in statuses}
        return [self.get_job(j, fl_ctx) for j, m in self.meta.items() if m[JobMetaKey.STATUS.value] in vals]

    def save_workspace(self, jid, dirs, fl_ctx):
        if self.on_save_workspace:
            self.on_save_workspace(jid)
        return f"store://{jid}/workspace"


class Scheduler:
    def __init__(self):
        self.done = set()

    def schedule_job(self, job_manager, job_candidates, fl_ctx):
        for j in job_candidates:
            if j.job_id not in self.done:
                self.done.add(j.job_id)
                return j, {"site-1": DispatchInfo(app_name="app", resource_requirements={}, token="tok-1")}
        return None, None

    def remove_scheduled_job(self, job_id):
        pass

    def restore_scheduled_job(self, job_id):
        pass


class Workspace:
    def __init__(self, root):
        self.root = root

    def _d(self, jid, kind):
        p = os.path.join(self.root, jid, kind)
        os.makedirs(p, exist_ok=True)
        return p

    def get_run_dir(self, jid):
        return self._d(jid, "run")

    def get_result_root(self, jid):
        return self._d(jid, "result")

    def get_log_root(self, jid):
        return self._d(jid, "log")

    def get_audit_root(self, jid):
        return self._d(jid, "audit")


def make_engine(store, root, sj_crash):
    """sj_crash: job ids whose SJ exits with ProcessExitCode.EXCEPTION during client start."""
    eng = MagicMock()
    eng.server.server_state = HotState()
    client = Client("site-1", "tok-1")
    eng.get_clients.return_value = [client]
    eng.get_component.side_effect = lambda name: store if name == SystemComponents.JOB_MANAGER else MagicMock()
    eng.run_processes, eng.exception_run_processes, eng.lock = {}, {}, threading.Lock()
    eng.client_manager.clients = {}            # no abort RPCs needed for the window
    eng.validate_targets.return_value = ([], [])
    eng.get_workspace.return_value = Workspace(root)
    ctx_mgr = FLContextManager(engine=eng, identity_name="server")
    eng.new_context.side_effect = ctx_mgr.new_context
    eng.get_job_clients.side_effect = lambda sites: {"tok-1": client}
    eng.events = []
    eng.fire_event.side_effect = lambda ev, ctx: eng.events.append(
        (threading.current_thread().name, (ctx.get_prop(FLContextKey.EVENT_DATA) or {}).get(JobMetaKey.JOB_ID.value), ev))

    def start_app_on_server(fl_ctx, job, job_clients, snapshot=None):
        eng.run_processes[job.job_id] = {RunProcessKey.PARTICIPANTS: job_clients}
        return ""

    def start_client_job(job, client_sites, fl_ctx):
        if job.job_id in sj_crash:        # the SJ dies while the clients are being started
            with eng.lock:
                info = eng.run_processes.pop(job.job_id)
                info[RunProcessKey.PROCESS_RETURN_CODE] = ProcessExitCode.EXCEPTION
                eng.exception_run_processes[job.job_id] = info
        ok = types.SimpleNamespace(body="OK", get_header=lambda *a, **k: "OK")
        return [types.SimpleNamespace(client_name=s, reply=ok) for s in client_sites]

    eng.start_app_on_server.side_effect = start_app_on_server
    eng.start_client_job.side_effect = start_client_job
    eng.abort_app_on_server.return_value = ""
    eng.remove_exception_process.side_effect = lambda jid: eng.exception_run_processes.pop(jid, None)
    return eng


def wait_until(cond, what):
    t = time.time() + WAIT
    while not cond():
        if time.time() > t:
            raise TimeoutError(what)
        time.sleep(0.02)


def scenario(name, fault):
    root = tempfile.mkdtemp(prefix=f"c1_{name}_", dir=os.path.join(os.path.dirname(__file__), "..", "..", ".tmp"))
    store, crashes = Store(), []
    eng = make_engine(store, root, sj_crash=set() if fault == "A2" else {"job1"})
    runner = JobRunner(workspace_root=root)
    runner.scheduler = Scheduler()
    runner._deploy_job = lambda job, sites, fl_ctx: (job.job_id, [])
    old_hook = threading.excepthook
    threading.excepthook = lambda a: crashes.append((a.thread.name, a.exc_type.__name__, str(a.exc_value)))
    in_archive, removed = threading.Event(), threading.Event()

    if fault == "A":
        def running_write():            # stalls until the completion thread has finished, then fails
            wait_until(lambda: any(e[1] == "job1" and e[2] == EventType.JOB_COMPLETED for e in eng.events),
                       "completion thread did not finish job1")
            raise OSError(errno.EIO, "Input/output error")
        store.on_status[("job1", RUNNING)] = running_write
    elif fault == "A2":
        def running_write():            # the short job finishes normally during the stall, then the write fails
            with eng.lock:
                eng.run_processes.pop("job1")[RunProcessKey.PROCESS_FINISHED] = True
            runner.resolve_client_outcome("job1", "site-1")
            wait_until(lambda: any(e[1] == "job1" and e[2] == EventType.JOB_COMPLETED for e in eng.events),
                       "completion thread did not finish job1")
            raise OSError(errno.EIO, "Input/output error")
        store.on_status[("job1", RUNNING)] = running_write
    elif fault == "B":
        def running_write():            # fails while the completion thread is archiving the workspace
            assert in_archive.wait(WAIT), "completion thread did not reach the archive step"
            raise OSError(errno.EIO, "Input/output error")

        def archive(jid):
            if jid == "job1":
                in_archive.set()
                wait_until(lambda: "job1" not in runner.running_jobs, "except branch did not remove job1")
        store.on_status[("job1", RUNNING)] = running_write
        store.on_save_workspace = archive

    store.add("job1")
    ctx = eng.new_context()
    t = threading.Thread(target=runner.run, args=(ctx,), name="run", daemon=True)
    t.start()
    out = {}
    try:
        wait_until(lambda: any(h[1] == "job1" and h[0] == "run" and h[2] in (RUNNING, FAILED)
                               for h in store.history), "run thread did not finish starting job1")
        time.sleep(2.5)                 # let both threads settle (completion scans every 1 s)
        out["job1_history"] = [h for h in store.history if h[1] == "job1"]
        out["job1_final"] = store.status("job1")
        out["job1_events"] = [(e[0], e[2]) for e in eng.events if e[1] == "job1"]
        # a second, fault-free job: its SJ finishes normally right after RUNNING
        store.add("job2")
        wait_until(lambda: store.status("job2") == RUNNING, "job2 did not start")
        with eng.lock:
            eng.run_processes.pop("job2")[RunProcessKey.PROCESS_FINISHED] = True
        runner.resolve_client_outcome("job2", "site-1")   # the CJ's outcome report arrives
        try:
            wait_until(lambda: store.status("job2") != RUNNING, "job2 not finalized")
        except TimeoutError:
            pass
        out["job2_final"] = store.status("job2")
        out["job2_in_running_jobs"] = "job2" in runner.running_jobs
        out["thread_crashes"] = list(crashes)
    finally:
        runner.ask_to_stop = True
        t.join(5)
        threading.excepthook = old_hook
        shutil.rmtree(root, ignore_errors=True)
    return out


if __name__ == "__main__":
    os.makedirs(os.path.join(os.path.dirname(__file__), "..", "..", ".tmp"), exist_ok=True)
    verdict = {}
    for name in sys.argv[1:] or ["C", "A", "A2", "B"]:
        r = scenario(name, name)
        print(f"== scenario {name}")
        for k, v in r.items():
            print(f"  {k}: {v}")
        statuses = [h[2] for h in r["job1_history"]]
        if name == "A2":
            verdict[name] = (DONE in statuses and r["job1_final"] == FAILED and statuses.index(DONE) < len(statuses) - 1)
        elif name == "A":
            verdict[name] = (EXC in statuses and r["job1_final"] == FAILED and statuses.index(EXC) < len(statuses) - 1)
        elif name == "B":
            verdict[name] = (any(c[1] == "KeyError" for c in r["thread_crashes"]) and r["job2_final"] == RUNNING
                             and r["job2_in_running_jobs"])
        else:
            verdict[name] = (r["job1_final"] == EXC and r["job2_final"] == DONE
                             and not r["thread_crashes"])
    for k, v in verdict.items():
        print(f"{k}: {'REPRODUCED' if v and k != 'C' else ('control OK' if v else 'NOT as expected')}")
