"""N2 (timing T4, round 8): a completed workflow's SJ panics during
finalization when a client's dead-client grace expires in that window.
Pinned source c411a201, read-only via sys.path.

WFCommServer._monitor_tasks (wf_comm_server.py:1201-1213) runs until
finalize_run sets _all_done (1033-1046). It promotes a reported client to
disconnected after _dead_client_grace (60 s from the report, 1179-1199) and
then checks the job policy (_job_policy_violated, 1369-1404): fewer alive
clients than min_sites, or a dead required site, triggers system_panic
("Aborting job due to deployment policy violation"). ServerRunner calls
finalize_run only after control_flow returned and stop_controller finished
(server_runner.py:153-172). So a client that died 60 s minus a little before
the workflow returned is deemed disconnected while the server is finalizing,
and a run whose workflow completed normally is aborted as a policy violation;
FATAL_SYSTEM_ERROR becomes UPDATE_RUN_STATUS{execution_error} and the job
FINISHED:EXECUTION_EXCEPTION (job_runner.py:594-622; l13_repro.py control).

Real code: WFCommServer.process_dead_client_report, _monitor_tasks,
_check_dead_clients, _job_policy_violated, finalize_run. Stubs: the engine
(two clients; job meta min_sites = 2; new_context), system_panic (recorder),
fire_event, the controller's stop_controller (1 s). The timing is the scenario:
site-2's dead-job report arrived 59.5 s before control_flow returned (its report
time is set back accordingly). Control: the report arrives at the return.
"""
import sys, threading, time, types
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)

from nvflare.apis.fl_constant import FLContextKey  # noqa: E402
from nvflare.apis.fl_context import FLContext  # noqa: E402
from nvflare.apis.impl.wf_comm_server import WFCommServer  # noqa: E402
from nvflare.apis.job_def import JobMetaKey  # noqa: E402


class Engine:
    def __init__(self):
        self.clients = [types.SimpleNamespace(name="site-1"), types.SimpleNamespace(name="site-2")]

    def get_clients(self):
        return self.clients

    def new_context(self):
        ctx = FLContext()
        ctx.set_prop(FLContextKey.JOB_META, {JobMetaKey.JOB_ID.value: "job1", JobMetaKey.JOB_NAME.value: "job1",
                                             JobMetaKey.MIN_CLIENTS.value: 2,
                                             JobMetaKey.DEPLOY_MAP.value: {"app": ["@ALL"]}}, private=True, sticky=False)
        return ctx

    def fire_event(self, *a, **k):
        pass


def scenario(report_age_at_return):
    comm = WFCommServer(task_check_period=0.05)
    comm._engine = Engine()
    comm.logger = MagicMock()
    panics = []
    comm.system_panic = lambda reason, fl_ctx: panics.append(reason)
    comm.fire_event = lambda *a, **k: None
    comm.log_warning = comm.log_error = comm.log_info = comm.log_debug = lambda *a, **k: None
    comm._cleanup_inflight_tensor_downloads = lambda fl_ctx: None
    comm._clear_standing_tasks = lambda fl_ctx: None
    monitor = threading.Thread(target=comm._monitor_tasks, daemon=True)
    monitor.start()
    # the workflow ran; site-2's CJ died and the SP reported it to the SJ
    comm.process_dead_client_report("site-2", FLContext())
    comm._dead_clients["site-2"].report_time = time.time() - report_age_at_return
    # control_flow returned (normal); ServerRunner: stop_controller (1 s), then finalize_run
    time.sleep(1.0)
    comm.finalize_run(FLContext())
    monitor.join(timeout=2)
    return panics


ctl = scenario(0.0)
n2 = scenario(59.5)
print("control (report at the workflow's return):", ctl)
print("N2 (report 59.5 s before the return):     ", n2)
ok = not ctl and n2 and "policy violation" in n2[0]
print("N2 REPRODUCED: a run whose workflow completed was aborted as a policy violation during finalization"
      if ok else "not reproduced")
