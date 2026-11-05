"""R1 (process restart, round 6): after the server parent (SP) restarts, a job
that was RUNNING stays RUNNING forever and can be neither aborted nor deleted.
Pinned source c411a201, read-only via sys.path.

The recovery helpers JobRunner.update_abnormal_finished_jobs and
update_unfinished_jobs (job_runner.py:852-883) have no caller anywhere in the
tree (and on upstream main), so a restarted SP never rewrites the status the
crashed one left in the job store. The admin commands then refuse the job:
- abort_job (job_cmds.py:1073-1105): abort_before_start only handles SUBMITTED
  and DISPATCHED; for RUNNING it calls stop_run, which answers "not running"
  because the new runner's running_jobs is empty;
- delete_job (job_cmds.py:509-523) refuses DISPATCHED and RUNNING.

Real code: SimpleJobDefManager + FilesystemStorage (the persisted store the
restarted SP reads), a fresh JobRunner whose run() loop is running, and
JobCommandModule.authorize_job_id / authorize_job / abort_job / delete_job.
Stubs: the engine and an admin connection object. A DISPATCHED job is the
control (abort_before_start can still finish it).
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
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage  # noqa: E402
from nvflare.private.fed.server.job_cmds import JobCommandModule  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".tmp")
os.makedirs(ROOT, exist_ok=True)
work = tempfile.mkdtemp(prefix="r1_", dir=ROOT)
store = FilesystemStorage(root_dir=work, uri_root="/")
jm = SimpleJobDefManager(uri_root="jobs", job_store_id="job_store")


def persisted(status):
    jid = str(uuid.uuid4())
    store.create_object(jm.job_uri(jid), b"job-data", {JobMetaKey.JOB_ID.value: jid, JobMetaKey.STATUS.value: status,
                        JobMetaKey.SUBMITTER_NAME.value: "admin@x", JobMetaKey.SUBMITTER_ORG.value: "x",
                        JobMetaKey.SUBMITTER_ROLE.value: "project_admin"}, overwrite_existing=True)
    return jid


# what the crashed SP left behind
running_job = persisted(RunStatus.RUNNING.value)
dispatched_job = persisted(RunStatus.DISPATCHED.value)

# the restarted SP
eng = MagicMock(spec=ServerEngineSpec)
eng.get_component.side_effect = lambda n: {"job_store": store, SystemComponents.JOB_MANAGER: jm}.get(n)
eng.server = MagicMock(); eng.server.server_state = HotState()
eng.get_clients.return_value = [Client("site-1", "tok-1")]
eng.run_processes, eng.exception_run_processes, eng.lock = {}, {}, threading.Lock()
eng.client_manager = MagicMock(); eng.client_manager.clients = {}
mgr = FLContextManager(engine=eng, identity_name="server")
eng.new_context.side_effect = mgr.new_context
runner = JobRunner(workspace_root=work)
runner.scheduler = MagicMock(); runner.scheduler.schedule_job.return_value = (None, None)
eng.job_runner, eng.job_def_manager = runner, jm
threading.Thread(target=runner.run, args=(mgr.new_context(),), daemon=True).start()
time.sleep(3.0)


class Conn:
    """The admin connection object the command handlers use (props + replies)."""
    def __init__(self):
        self.app_ctx, self.props, self.out = eng, {}, []

    def get_prop(self, k, default=None):
        return self.props.get(k, default)

    def set_prop(self, k, v):
        self.props[k] = v

    def append_error(self, msg, meta=None):
        self.out.append(("error", msg))

    def append_string(self, msg, meta=None):
        self.out.append(("string", msg))

    def append_success(self, msg, meta=None):
        self.out.append(("success", msg))


cmds = JobCommandModule()
cmds._apply_study_role_for_authz = lambda conn: True     # authorization is not under test


def admin(cmd, jid):
    c = Conn()
    getattr(cmds, "authorize_job")(c, [cmd, jid])
    getattr(cmds, cmd)(c, [cmd, jid])
    return [m for k, m in c.out if k in ("error", "string")]


status = lambda j: jm.get_job(j, mgr.new_context()).meta[JobMetaKey.STATUS.value]
print("after restart, store status of the interrupted job:", status(running_job))
print("abort_job  ->", admin("abort_job", running_job))
print("delete_job ->", admin("delete_job", running_job))
time.sleep(2.0)
print("status now:", status(running_job))
print("control: abort_job on the DISPATCHED job ->", admin("abort_job", dispatched_job), "status:", status(dispatched_job))
runner.ask_to_stop = True
ok = status(running_job) == RunStatus.RUNNING.value and jm.get_job(running_job, mgr.new_context()) is not None
print("R1 REPRODUCED: the interrupted RUNNING job can be neither aborted nor deleted" if ok else "not reproduced")
shutil.rmtree(work, ignore_errors=True)
