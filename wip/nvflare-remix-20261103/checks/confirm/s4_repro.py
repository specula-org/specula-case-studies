"""S4 (v9, found by model checking first): a job the scheduler is deploying when the SP
shutdown/restart begins is still started. stop_all_runs (job_runner.py:944-951) stops only
what is in engine.run_processes and sets ask_to_stop; the scheduling loop reads ask_to_stop
only at its top (job_runner.py:695), so a pass in progress goes on to _start_run (SJ launch,
START to the clients, RUNNING). BaseServer.fl_shutdown then waits up to shutdown_period (30 s)
for clients to leave (fed_server.py:343-354) before the SP exits, leaving that job running
without its SP. Pinned source c411a201, read-only via sys.path.

Real code: JobRunner.run (scheduling loop and its try/except), JobRunner.stop_all_runs,
SimpleJobDefManager, FilesystemStorage. Stubs: engine, a scheduler that returns the job as
ready, _deploy_job (2 s, the deploy round trip) and _start_run (records when it is called).
Control: the shutdown comes before the job is submitted.
"""
import os, shutil, sys, tempfile, threading, time, uuid
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)
from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.fl_constant import SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager  # noqa: E402
from nvflare.apis.job_def import JobMetaKey, RunStatus  # noqa: E402
from nvflare.apis.job_scheduler_spec import DispatchInfo  # noqa: E402
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".tmp")
os.makedirs(ROOT, exist_ok=True)


class ReadyScheduler:
    def __init__(self):
        self.given = set()

    def schedule_job(self, job_manager, job_candidates, fl_ctx):
        for j in job_candidates:
            if j.job_id not in self.given:
                self.given.add(j.job_id)
                return j, {"site-1": DispatchInfo(app_name="app", resource_requirements={}, token="t")}
        return None, None

    def remove_scheduled_job(self, job_id):
        pass


def scenario(shutdown_during_deploy):
    work = tempfile.mkdtemp(prefix="s4_", dir=ROOT)
    store = FilesystemStorage(root_dir=work, uri_root="/")
    jm = SimpleJobDefManager(uri_root="jobs", job_store_id="job_store")
    eng = MagicMock(spec=ServerEngineSpec)
    eng.get_component.side_effect = lambda n: {"job_store": store, SystemComponents.JOB_MANAGER: jm}.get(n)
    eng.server = MagicMock(); eng.server.server_state = HotState()
    eng.get_clients.return_value = [Client("site-1", "tok-1")]
    eng.run_processes, eng.exception_run_processes, eng.lock = {}, {}, threading.Lock()
    eng.job_def_manager = jm
    mgr = FLContextManager(engine=eng, identity_name="server")
    eng.new_context.side_effect = mgr.new_context

    def add_job():
        jid = str(uuid.uuid4())
        store.create_object(jm.job_uri(jid), b"job-data", {JobMetaKey.JOB_ID.value: jid,
                            JobMetaKey.STATUS.value: RunStatus.SUBMITTED.value}, overwrite_existing=True)
        return jid

    deploying, started = threading.Event(), []

    def slow_deploy(job, sites, fl_ctx):
        deploying.set()
        time.sleep(2.0)
        return job.job_id, []

    runner = JobRunner(workspace_root=work)
    runner.scheduler = ReadyScheduler()
    runner._deploy_job = slow_deploy
    runner._start_run = lambda job_id, job, client_sites, fl_ctx: started.append((job_id, time.time()))
    t = threading.Thread(target=runner.run, args=(mgr.new_context(),), name="job_runner", daemon=True)
    t.start()
    if shutdown_during_deploy:
        job = add_job()
        assert deploying.wait(10)
    runner.stop_all_runs(mgr.new_context())   # fl_shutdown -> stop_all_jobs; run_processes is empty
    t_stop = time.time()
    if not shutdown_during_deploy:
        job = add_job()                          # submitted after the shutdown began
    time.sleep(4.0)
    status = jm.get_job(job, mgr.new_context()).meta.get(JobMetaKey.STATUS)
    late = [x for x in started if x[0] == job and x[1] > t_stop]
    res = dict(started_after_stop_all_runs=bool(late),
               seconds_after=round(late[0][1] - t_stop, 2) if late else None,
               status=status, ask_to_stop=runner.ask_to_stop, scheduler_thread_alive=t.is_alive())
    shutil.rmtree(work, ignore_errors=True)
    return res


if __name__ == "__main__":
    ctl = scenario(False)
    s4 = scenario(True)
    print("control (job submitted after the shutdown began):", ctl)
    print("S4 (shutdown while the job is being deployed):   ", s4)
    ok = not ctl["started_after_stop_all_runs"] and s4["started_after_stop_all_runs"] and s4["status"] == "RUNNING"
    print("S4 REPRODUCED: the job being deployed was started and set RUNNING after stop_all_runs returned"
          if ok else "not reproduced")
