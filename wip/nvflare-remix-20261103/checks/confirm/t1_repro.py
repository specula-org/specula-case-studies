"""T1 (thread audit, round 6): the job runner's scheduling thread dies when a
queued job is deleted while the 1 s scheduling scan reads the job store.
Pinned source c411a201, read-only via sys.path.

JobRunner.run (job_runner.py:695-716) calls job_manager.get_jobs_to_schedule
and _check_job_status OUTSIDE its try block. get_jobs_to_schedule ->
SimpleJobDefManager._scan (job_def_manager.py:517-531) lists the job objects
and then reads each one's meta; FilesystemStorage.get_meta raises
StorageException for an object that no longer exists (filesystem_storage.py:
326-327), and delete_object removes it with a non-atomic rmtree. Admin
delete_job is allowed for SUBMITTED jobs (job_cmds.py:518). A delete that lands
between the listing and the meta read propagates out of run(): the scheduling
loop ends, and no job is ever scheduled again (until the server restarts).

Real code: JobRunner (run loop + its completion thread), SimpleJobDefManager,
FilesystemStorage on a temp dir. Stubs: the engine (spec=ServerEngineSpec) and
a scheduler that keeps every job waiting (e.g. resources busy). No forced
scheduling: an admin-like thread deletes queued jobs at a steady pace while the
runner scans; the race is natural.
"""
import os, random, shutil, sys, tempfile, threading, time, uuid
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
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402

N_JOBS = int(sys.argv[1]) if len(sys.argv) > 1 else 300
DELETE_EVERY = float(sys.argv[2]) if len(sys.argv) > 2 else 0.05   # mean gap between deletes
LIMIT = 120.0

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".tmp")
os.makedirs(ROOT, exist_ok=True)
work = tempfile.mkdtemp(prefix="t1_", dir=ROOT)
store = FilesystemStorage(root_dir=work, uri_root="/")
jm = SimpleJobDefManager(uri_root="jobs", job_store_id="job_store")

eng = MagicMock(spec=ServerEngineSpec)
eng.get_component.side_effect = lambda n: {"job_store": store, SystemComponents.JOB_MANAGER: jm}.get(n)
eng.server = MagicMock()
eng.server.server_state = HotState()
eng.get_clients.return_value = [Client("site-1", "tok-1")]
eng.run_processes, eng.exception_run_processes, eng.lock = {}, {}, threading.Lock()
mgr = FLContextManager(engine=eng, identity_name="server")
eng.new_context.side_effect = mgr.new_context

jobs = []
for _ in range(N_JOBS):
    jid = str(uuid.uuid4())
    store.create_object(jm.job_uri(jid), b"job-data",
                        {JobMetaKey.JOB_ID.value: jid, JobMetaKey.STATUS.value: RunStatus.SUBMITTED.value},
                        overwrite_existing=True)
    jobs.append(jid)


class BusyScheduler:
    """Every job stays queued (resources busy); counts scheduling passes."""
    passes = 0

    def schedule_job(self, job_manager, job_candidates, fl_ctx):
        BusyScheduler.passes += 1
        return None, None


crashes = []
threading.excepthook = lambda a: crashes.append((a.thread.name, a.exc_type.__name__, str(a.exc_value)[:120]))
runner = JobRunner(workspace_root=work)
runner.scheduler = BusyScheduler()
run_thread = threading.Thread(target=runner.run, args=(mgr.new_context(),), name="job_runner", daemon=True)
run_thread.start()

deleted, t0 = 0, time.time()
ctx = mgr.new_context()
while run_thread.is_alive() and jobs and time.time() - t0 < LIMIT:
    jm.delete(jobs.pop(), ctx)          # admin delete_job of a SUBMITTED job
    deleted += 1
    time.sleep(random.uniform(0.0, 2 * DELETE_EVERY))   # random phase vs the 1 s scan
time.sleep(1.5)
dead = not run_thread.is_alive()
print(f"jobs={N_JOBS} delete_every={DELETE_EVERY}s deleted={deleted} elapsed={time.time()-t0:.1f}s "
      f"scheduling passes={BusyScheduler.passes}")
print("scheduling thread alive:", not dead, "| exceptions:", crashes)
runner.ask_to_stop = True
print("T1 REPRODUCED (natural race): the scheduling loop died" if dead and crashes else "not reproduced")
shutil.rmtree(work, ignore_errors=True)
