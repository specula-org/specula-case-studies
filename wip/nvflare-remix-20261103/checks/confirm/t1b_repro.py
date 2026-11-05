"""T1-b (thread audit, round 6): deleting a job while the runner deploys it
kills the scheduling thread. Pinned source c411a201, read-only via sys.path.

While _deploy_job runs (seconds: the deploy request goes to every client),
the job is still SUBMITTED, so admin delete_job accepts it (job_cmds.py:518:
only DISPATCHED/RUNNING are refused). After deployment, _check_job_status
reloads the job: get_job returns None for the deleted job (job_def_manager.py:
379-385) and `.meta` raises AttributeError inside the try (job_runner.py:735).
The except branch calls _check_job_status again (job_runner.py:794-797),
which raises the same AttributeError with no handler around it; it leaves
run(), and the server never schedules another job.

Real code: JobRunner.run with its try/except, SimpleJobDefManager,
FilesystemStorage. Stubs: engine, a scheduler that returns the job as ready,
and _deploy_job, which takes 2 s (the deploy round trip) and succeeds. The
admin delete simply happens during the deployment; no forcing.
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
work = tempfile.mkdtemp(prefix="t1b_", dir=ROOT)
store = FilesystemStorage(root_dir=work, uri_root="/")
jm = SimpleJobDefManager(uri_root="jobs", job_store_id="job_store")
eng = MagicMock(spec=ServerEngineSpec)
eng.get_component.side_effect = lambda n: {"job_store": store, SystemComponents.JOB_MANAGER: jm}.get(n)
eng.server = MagicMock(); eng.server.server_state = HotState()
eng.get_clients.return_value = [Client("site-1", "tok-1")]
eng.run_processes, eng.exception_run_processes, eng.lock = {}, {}, threading.Lock()
mgr = FLContextManager(engine=eng, identity_name="server")
eng.new_context.side_effect = mgr.new_context


def add_job():
    jid = str(uuid.uuid4())
    store.create_object(jm.job_uri(jid), b"job-data", {JobMetaKey.JOB_ID.value: jid,
                        JobMetaKey.STATUS.value: RunStatus.SUBMITTED.value}, overwrite_existing=True)
    return jid


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


deploying = threading.Event()


def slow_deploy(job, sites, fl_ctx):
    deploying.set()
    time.sleep(2.0)                      # deploy request to every client
    return job.job_id, []


crashes = []
threading.excepthook = lambda a: crashes.append((a.thread.name, a.exc_type.__name__, str(a.exc_value)[:100]))
runner = JobRunner(workspace_root=work)
runner.scheduler = ReadyScheduler()
runner._deploy_job = slow_deploy
t = threading.Thread(target=runner.run, args=(mgr.new_context(),), name="job_runner", daemon=True)
job1 = add_job()
t.start()
assert deploying.wait(10)
jm.delete(job1, mgr.new_context())       # admin delete_job: the job is still SUBMITTED
time.sleep(4.0)
print("scheduling thread alive after the delete:", t.is_alive(), "| exceptions:", crashes)
job2 = add_job()                         # a new submission
time.sleep(4.0)
print("job2 picked up by the scheduler:", job2 in runner.scheduler.given)
runner.ask_to_stop = True
ok = not t.is_alive() and job2 not in runner.scheduler.given
print("T1-b REPRODUCED: deleting a job during deployment stops all scheduling" if ok else "not reproduced")
shutil.rmtree(work, ignore_errors=True)
