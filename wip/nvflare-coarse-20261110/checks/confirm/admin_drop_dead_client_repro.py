"""Chunk-1 candidate (ledger Reg.admin.remove / Reg.admin.disable, cause record pReg.dropped):
an admin remove_client / disable_client drops a participant's token without the dead-client
processing the cleanup thread does (notify_dead_client: resolve the pending outcome, send
HANDLE_DEAD_JOB to the job's SJ). If the client is dead, or dies later while disabled, its
job's SJ is never told; the SJ learns about disconnected clients only from that report.
Pinned source c411a201, read-only via sys.path.

Real code: ClientManager (authenticate, heartbeat, remove_client, disable_client,
is_from_authorized_client), ServerEngine.remove_clients / _remove_dead_client /
disable_clients, FederatedServer.remove_dead_clients / logout_client / notify_dead_client /
_notify_dead_job, WFCommServer.process_dead_client_report / _check_dead_clients.
Stubs: the SP shell around them (run_processes with the job's participants, the job
runner's pending outcomes, engine.notify_dead_job forwards to the SJ's WFCommServer, the
admin server). Time: a dead client's last_connect_time is moved back by the heartbeat
timeout. No fault injection, no forced scheduling: an admin command and a dead client.
Control: the same dead client without the admin command, handled by the cleanup thread.
"""
import sys
import time
import types
from unittest.mock import Mock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey  # noqa: E402
from nvflare.apis.fl_context import FLContext, FLContextManager  # noqa: E402
from nvflare.apis.impl.wf_comm_server import WFCommServer  # noqa: E402
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.apis.shareable import Shareable  # noqa: E402
from nvflare.fuel.f3.message import Message as CellMessage  # noqa: E402
from nvflare.private.defs import CellMessageHeaderKeys, ClientType  # noqa: E402
from nvflare.private.fed.server.client_manager import ClientManager  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
from nvflare.private.fed.server.server_engine import ServerEngine  # noqa: E402

JOB = "job1"


def sj_comm():
    """the job's SJ side: a real WFCommServer whose CLIENT_DISCONNECTED events are recorded"""
    engine = Mock(spec=ServerEngineSpec)
    fl_ctx = FLContextManager(engine, "server", JOB, {}, {}).new_context()
    engine.new_context.side_effect = lambda: fl_ctx
    comm = WFCommServer()
    comm._engine = engine
    comm._dead_client_grace = 0.0
    events = []
    comm.fire_event = lambda event_type, fl_ctx: events.append((event_type, fl_ctx.get_prop(FLContextKey.DISCONNECTED_CLIENT_NAME)))
    return comm, fl_ctx, events


def sp(comm, sj_ctx):
    cm = ClientManager(project_name="p", min_num_clients=1, max_num_clients=10)
    srv = types.SimpleNamespace(client_manager=cm, admin_server=None, heart_beat_timeout=60.0, logger=cm.logger)
    srv.remove_client_data = lambda token: None
    resolved = []
    srv._resolve_missing_client_outcome = lambda client, job_id, reason: resolved.append((client.name, job_id))
    eng = types.SimpleNamespace(server=srv, run_processes={},
                                job_runner=types.SimpleNamespace(get_client_outcome_jobs=lambda name: [JOB]),
                                notify_dead_job=lambda job_id, name, reason: comm.process_dead_client_report(name, sj_ctx))
    eng._remove_dead_client = lambda token: ServerEngine._remove_dead_client(eng, token)
    srv.engine = eng
    srv.logger = cm.logger
    for m in ("notify_dead_client", "_notify_dead_job", "logout_client", "remove_dead_clients"):
        setattr(srv, m, getattr(FederatedServer, m).__get__(srv))
    return cm, srv, eng, resolved


def login(cm, name):
    req = CellMessage(headers={CellMessageHeaderKeys.CLIENT_NAME: name, CellMessageHeaderKeys.CLIENT_TYPE: ClientType.REGULAR,
                               CellMessageHeaderKeys.PROJECT_NAME: "p", CellMessageHeaderKeys.CLIENT_IP: "127.0.0.1"},
                      payload=Shareable())
    return cm.authenticate(req, FLContext())


def run(admin):
    comm, sj_ctx, events = sj_comm()
    cm, srv, eng, resolved = sp(comm, sj_ctx)
    c = login(cm, "site-2")
    eng.run_processes[JOB] = {RunProcessKey.PARTICIPANTS: {c.token: c}}
    if admin == "disable":
        ServerEngine.disable_clients(eng, ["site-2"])     # the CP is alive when it is disabled
    c.last_connect_time = time.time() - 3600               # the client dies (heartbeats stop)
    if admin == "remove":
        ServerEngine.remove_clients(eng, [c.token])        # the admin removes the dead client's token
    for _ in range(3):                                     # cleanup passes
        srv.remove_dead_clients()
    comm._check_dead_clients()                             # the SJ's task monitor
    disconnected = [e for e in events if e[0] == EventType.CLIENT_DISCONNECTED]
    outcome_accepted = cm.is_from_authorized_client(c.token)
    return dict(sj_reports=len(comm._dead_clients), sj_disconnected=len(disconnected),
                outcome_resolved=len(resolved), outcome_report_accepted=outcome_accepted)


res = {k: run(k) for k in ("control", "remove", "disable")}
for k, v in res.items():
    print(f"{k:8s} {v}")
ok = (res["control"]["sj_reports"] == 1 and res["control"]["sj_disconnected"] == 1 and res["control"]["outcome_resolved"] == 1
      and all(res[k]["sj_reports"] == 0 and res[k]["sj_disconnected"] == 0 and res[k]["outcome_resolved"] == 0
              and not res[k]["outcome_report_accepted"] for k in ("remove", "disable")))
print("REPRODUCED (no forcing, no injection): after admin remove_client / disable_client of a dead participant the SJ "
      "never receives a dead-client report and the pending outcome is never resolved; the CP's own outcome report "
      "would be dropped as unauthorized" if ok else "not reproduced")
