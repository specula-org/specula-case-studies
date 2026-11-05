"""R2 (process restart, round 6): when a client parent (CP) restarts while a
job runs, the server never tells the job's SJ that this client's job is gone.
Pinned source c411a201, read-only via sys.path.

The CJ dies with its CP (monitor_parent_process). The restarted CP logs in
again and gets a NEW token (client_manager.py:330-339; the old token is
popped silently, without notify_dead_client). Its heartbeats no longer list
the job. FederatedServer._sync_client_jobs (fed_server.py:1013-1084) handles
"running on the server but not on the client" only for a token found in the
job's PARTICIPANTS, which hold the tokens from job start (and, with the default
require_previous_report=True, only after that token reported the job once).
The new token matches neither, so no _notify_dead_job reaches the SJ; the
client is never reported dead (it is alive under the new token), and a FedAvg
task without a timeout waits for this client forever.

Real code: ClientManager.authenticate (non-secure mode) for both logins,
FederatedServer._sync_client_jobs. Stubs: the engine (run_processes with the
job's participants, notify_dead_job recorder) and the job runner (the site's
outcome is still pending). Control: the same CJ death without a CP restart
(same token) is notified.
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


def scenario(restart_cp):
    cm = ClientManager(project_name="p", min_num_clients=1, max_num_clients=10)

    def login(name):
        req = Message(headers={CellMessageHeaderKeys.CLIENT_NAME: name, MessageHeaderKey.ORIGIN: name,
                               CellMessageHeaderKeys.PROJECT_NAME: "p",
                               CellMessageHeaderKeys.CLIENT_TYPE: ClientType.REGULAR,
                               CellMessageHeaderKeys.CLIENT_IP: "10.0.0.1"}, payload=Shareable())
        return cm.authenticate(req, FLContext())

    c1 = login("site-1")
    notified = []
    eng = MagicMock()
    eng.run_processes = {"job1": {RunProcessKey.PARTICIPANTS: {c1.token: c1}}}   # SJ alive, started with c1
    eng.exception_run_processes = {}
    eng.notify_dead_job.side_effect = lambda job_id, client_name, reason: notified.append((job_id, client_name, reason))
    eng.job_runner.get_client_outcome_jobs.return_value = {"job1"}
    eng.job_runner.is_client_outcome_pending.return_value = True
    srv = FederatedServer.__new__(FederatedServer)
    srv.client_manager, srv.engine, srv.logger = cm, eng, MagicMock()
    srv._job_reported_clients, srv._job_reported_clients_lock = {}, threading.Lock()

    def heartbeat(token, jobs):
        return srv._sync_client_jobs(Message(headers={CellMessageHeaderKeys.JOB_IDS: list(jobs)}), token)

    heartbeat(c1.token, ["job1"])               # the CP reports the running job
    token = c1.token
    if restart_cp:                              # CP crashes; its CJ dies with it; the CP restarts
        c2 = login("site-1")
        token = c2.token
    for _ in range(5):                          # heartbeats without the job
        heartbeat(token, [])
    return token != c1.token, c1.token in cm.clients, notified


ctl = scenario(restart_cp=False)
r2 = scenario(restart_cp=True)
print("control (CJ died, same CP):  new token:", ctl[0], "| SJ notified:", ctl[2])
print("CP restarted:                new token:", r2[0], "| old token still registered:", r2[1], "| SJ notified:", r2[2])
ok = ctl[2] and r2[0] and not r2[2]
print("R2 REPRODUCED: after a CP restart the SJ is never told that the client's job died" if ok else "not reproduced")
