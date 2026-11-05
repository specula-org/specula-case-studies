"""H08 confirmation on the pinned source (c411a201), read-only via sys.path.

The CP's START_JOB handler consumes a job's GPU allocation into the
process-global environment (scheduler_cmds.py:122-124 ->
GPUResourceConsumer.consume, gpu_resource_consumer.py:34:
os.environ["CUDA_VISIBLE_DEVICES"] = ...). ProcessJobLauncher.launch_job copies
os.environ at every spawn (process_launcher.py:130). A CJ restart
(ClientExecutor._restart_job -> _launch_job, client_executor.py:722-758,
375-415) launches again from the saved launcher and meta and does not consume
again, so a restarted CJ of job A inherits whatever the last START handler of
ANY job wrote.

Scenario: job A starts with GPU 0 and its CJ is spawned; job B then starts on
the same CP with GPU 1; A's CJ exits with EXECUTION_ERROR (restartable, the
default max_cj_restart_failures is 3) and is restarted. Real code: the GPU
consumer, ClientExecutor._launch_job / _restart_job, _JobRestart,
_PendingJobHandle, ProcessJobLauncher.launch_job, ProcessHandle (including
can_restart) and spawn_process. Stubs: host GPU probing, the engine, the
workspace object, and the launch command (a Python one-liner that records the
CUDA_VISIBLE_DEVICES it was started with, instead of the CJ worker).
"""
import copy, os, sys, tempfile, threading, time, types
from unittest.mock import MagicMock, patch

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)

import nvflare.app_common.resource_consumers.gpu_resource_consumer as grc  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.job_launcher_spec import JobProcessArgs, JobReturnCode  # noqa: E402
from nvflare.app_common.job_launcher.process_launcher import ProcessJobLauncher  # noqa: E402
from nvflare.private.fed.client import client_executor as ce  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".tmp")
os.makedirs(ROOT, exist_ok=True)
work = tempfile.mkdtemp(prefix="h08_", dir=ROOT)
out = os.path.join(work, "cvd.txt")


class EnvProbeLauncher(ProcessJobLauncher):
    """The real ProcessJobLauncher with the CJ worker command replaced."""

    def get_command(self, job_meta, fl_ctx):
        code = "import os,sys; open(sys.argv[1],'a').write(sys.argv[2]+'='+os.environ.get('CUDA_VISIBLE_DEVICES','<unset>')+chr(10)); sys.exit(1)"
        return f"{sys.executable} -c \"{code}\" {out} {job_meta['job_id']}"


class Ws:
    def get_root_dir(self):
        return work

    def get_app_custom_dir(self, job_id):
        return ""

    def get_app_dir(self, job_id):
        d = os.path.join(work, job_id, "app")
        os.makedirs(d, exist_ok=True)
        return d


eng = MagicMock()
mgr = FLContextManager(engine=eng, identity_name="site-1")


def new_ctx():
    ctx = mgr.new_context()
    ctx.set_prop(FLContextKey.WORKSPACE_OBJECT, Ws(), private=True, sticky=False)
    ctx.set_prop(FLContextKey.ARGS, types.SimpleNamespace(set=[], workspace=work), private=True, sticky=False)
    return ctx


executor = ce.JobExecutor.__new__(ce.JobExecutor)   # the concrete executor (client_executor.py:212)
executor.lock = threading.Lock()
executor.run_processes = {}
executor.max_cj_restart_failures = 3
executor.logger = MagicMock()
executor.client = types.SimpleNamespace(token="t", token_signature="s", ssid="d")
executor.abort_app = MagicMock()
launcher = EnvProbeLauncher()


def start(job_id, gpu):
    """START_JOB handler: consume the allocation, then launch (as start_app does)."""
    with patch.object(grc, "get_host_gpu_ids", return_value=[0, 1]), \
         patch.object(grc, "get_host_gpu_memory_free", return_value={0: 16000, 1: 16000}):
        grc.GPUResourceConsumer().consume({gpu: 1})
    job_args = {JobProcessArgs.OPTIONS: ("--set", ""), JobProcessArgs.AUTH_TOKEN: ("-t", "t"),
                JobProcessArgs.TOKEN_SIGNATURE: ("-ts", "s"), JobProcessArgs.SSID: ("-d", "d")}
    restart = ce._JobRestart(launcher, {"job_id": job_id}, job_args)
    pending = ce._PendingJobHandle()
    executor.run_processes[job_id] = {ce.RunProcessKey.JOB_HANDLE: pending,
                                      ce.RunProcessKey.STATUS: ce.ClientStatus.STARTING,
                                      ce._ABORT_REQUESTED_KEY: False, ce._RESTART_KEY: restart}
    ctx = new_ctx()
    executor._launch_job(job_id, restart, pending, ctx)
    return pending, ctx


def wait_lines(n):
    t = time.time() + 20
    while time.time() < t:
        if os.path.exists(out) and len(open(out).read().splitlines()) >= n:
            return
        time.sleep(0.05)


pa, ctx_a = start("jobA", 0)          # job A: GPU 0, CJ generation 1
wait_lines(1)
pb, _ = start("jobB", 1)              # job B on the same CP: GPU 1
wait_lines(2)
handle_a = executor.run_processes["jobA"][ce.RunProcessKey.JOB_HANDLE]
handle_a.wait()                       # A's CJ exited with an error (rc 1)
restarted = executor._restart_job("jobA", handle_a, JobReturnCode.EXECUTION_ERROR, ctx_a)
wait_lines(3)
lines = open(out).read().splitlines()
print("restart taken:", restarted)
for l in lines:
    print("  spawned", l)
gen2 = [l for l in lines if l.startswith("jobA=")][1:] if restarted else []
ok = restarted and lines[0] == "jobA=0" and gen2 == ["jobA=1"]
print("H08 REPRODUCED: restarted CJ of job A runs with job B's GPU" if ok else "not reproduced")
