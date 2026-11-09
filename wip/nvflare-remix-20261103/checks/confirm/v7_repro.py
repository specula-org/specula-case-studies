"""V7 (v11 lead): under the Kubernetes job launcher, a CP restart turns a run that
the surviving CJ completed into FINISHED_ABNORMAL. Pinned source c411a201,
read-only via sys.path.

Premise (static, from the code): the CJ runs in its own Pod with no
ownerReference to the CP (k8s_launcher.py: only the credential Secret is owned,
by the CJ Pod), so a CP restart does not stop it; the restarted CP keeps no
handle for it (client recovery after a CP restart is out of scope upstream,
docs/design/client_job_recovery.md) and never reports the site's outcome.

Executed path (real code): ClientManager.authenticate for the first login and
the re-login after the restart (new token), FederatedServer._sync_client_jobs
and _resolve_missing_client_outcome, JobRunner.is_client_outcome_pending /
get_client_outcome_jobs / fail_run, JobRunner._classify_finished_job_status.
Stubs: the engine (run_processes, exception_run_processes, lock) and
JobRunner._stop_run. The SJ has exited normally (the workflow finished, so the
job is no longer in run_processes) and the job runner still waits for site-1's
outcome; the restarted CP's heartbeats list no job.
Control: the CP is not restarted and reports site-1's outcome before its next
heartbeat (resolve_client_outcome), as the process launcher's CP does after the
CJ exits: no failure.
"""
import sys, threading
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)
from nvflare.apis.fl_constant import RunProcessKey  # noqa: E402
from nvflare.apis.fl_context import FLContext  # noqa: E402
from nvflare.apis.shareable import Shareable  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: E402
from nvflare.fuel.f3.message import Message  # noqa: E402
from nvflare.private.defs import CellMessageHeaderKeys, ClientType  # noqa: E402
from nvflare.private.fed.server.client_manager import ClientManager  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402


def scenario(cp_restart):
    cm = ClientManager(project_name="p", min_num_clients=1, max_num_clients=10)

    def login(name):
        req = Message(headers={CellMessageHeaderKeys.CLIENT_NAME: name, MessageHeaderKey.ORIGIN: name,
                               CellMessageHeaderKeys.PROJECT_NAME: "p",
                               CellMessageHeaderKeys.CLIENT_TYPE: ClientType.REGULAR,
                               CellMessageHeaderKeys.CLIENT_IP: "10.0.0.1"}, payload=Shareable())
        return cm.authenticate(req, FLContext())

    c1 = login("site-1")
    eng = MagicMock()
    eng.lock = threading.Lock()
    eng.exception_run_processes = {}
    eng.run_processes = {"job1": {RunProcessKey.PARTICIPANTS: {c1.token: c1}}}   # SJ running
    jr = JobRunner.__new__(JobRunner)                                             # real outcome tracking
    jr.lock = threading.Lock()
    jr.running_jobs = {"job1": MagicMock(job_id="job1")}
    jr._pending_client_outcomes = {"job1": {"site-1"}}
    jr._client_outcome_deadlines = {}
    jr._stop_run = lambda job_id, fl_ctx: None
    jr.log_info = lambda *a, **k: None
    eng.job_runner = jr
    eng.new_context.return_value.__enter__.return_value = MagicMock(get_engine=lambda: eng)
    srv = FederatedServer.__new__(FederatedServer)
    srv.client_manager, srv.engine, srv.logger = cm, eng, MagicMock()
    srv._job_reported_clients, srv._job_reported_clients_lock = {}, threading.Lock()

    def heartbeat(token, jobs):
        return srv._sync_client_jobs(Message(headers={CellMessageHeaderKeys.JOB_IDS: list(jobs)}), token)

    heartbeat(c1.token, ["job1"])                  # the CP reports the running job
    token = c1.token
    if cp_restart:
        token = login("site-1").token              # CP restarted: re-login with a new token; the CJ Pod runs on
    del eng.run_processes["job1"]                  # the workflow finished, the SJ exited normally
    if not cp_restart:
        jr.resolve_client_outcome("job1", "site-1")    # the CP reports the CJ's outcome after it exits
    for _ in range(3):                             # heartbeats: no job listed (CJ done / unknown to the new CP)
        heartbeat(token, [])
    rp = eng.exception_run_processes.get("job1")
    status = JobRunner._classify_finished_job_status(rp) if rp is not None else "FINISHED_COMPLETED (no failure recorded)"
    return token != c1.token, status


ctl = scenario(cp_restart=False)
v7 = scenario(cp_restart=True)
print("control (no CP restart, outcome reported): new token:", ctl[0], "| job status:", ctl[1])
print("CP restarted (K8s, CJ Pod completed):       new token:", v7[0], "| job status:", v7[1])
ok = "ABNORMAL" in str(v7[1]) and "COMPLETED" in str(ctl[1])
print("V7 REPRODUCED (server logic): the completed run is recorded FINISHED_ABNORMAL after the CP restart"
      if ok else "not reproduced")
