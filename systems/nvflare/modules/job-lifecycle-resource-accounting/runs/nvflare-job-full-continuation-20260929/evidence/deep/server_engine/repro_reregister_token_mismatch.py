"""SE-3: a client parent (CP) that restarts mid-job re-registers with a NEW token.
PARTICIPANTS (engine.run_processes[job][PARTICIPANTS]) is keyed by the OLD token, so:
  - _sync_client_jobs never emits a dead-job notification for that client (fed_server.py:1062-1065),
  - authenticated_client() silently drops the old token (client_manager.py:332-337) without
    BaseServer.logout_client()/notify_dead_client(), so the dead-client path never runs either,
  - _stop_run/_get_active_job_participants excludes the client from ABORT targeting.
The SJ's controller learns about dead clients only through HANDLE_DEAD_JOB (wf_comm_server.py:181-188).

Real objects: FederatedServer.register_client/client_heartbeat/_sync_client_jobs/remove_dead_clients,
ClientManager.authenticate, ServerEngine.notify_dead_job/send_command_to_child_runner_process,
JobRunner. The cell is a stub that records fire_and_forget targets/topics.
"""

import time

from harness import Env, now
from nvflare.apis.fl_constant import RunProcessKey, ServerCommandNames
from nvflare.apis.shareable import Shareable
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey
from nvflare.fuel.f3.message import Message as CellMessage
from nvflare.private.defs import CellMessageHeaderKeys, ClientType
from nvflare.private.fed.server.job_runner import _get_active_job_participants


def register(env, name):
    req = CellMessage(
        {
            CellMessageHeaderKeys.CLIENT_NAME: name,
            CellMessageHeaderKeys.CLIENT_TYPE: ClientType.REGULAR,
            CellMessageHeaderKeys.PROJECT_NAME: "proj",
            CellMessageHeaderKeys.CLIENT_IP: "127.0.0.1",
            MessageHeaderKey.ORIGIN: name,
        },
        Shareable(),
    )
    reply = env.server.register_client(req)
    token = reply.payload[CellMessageHeaderKeys.TOKEN]
    return token


def dead_job_msgs(env, job_id):
    return [s for s in env.server.cell.sent if s[3] == ServerCommandNames.HANDLE_DEAD_JOB and s[1].endswith(job_id)]


def scenario(restart: bool):
    env = Env()
    t1 = register(env, "site-1")
    t2 = register(env, "site-2")
    env.start_job("J1", ["site-1", "site-2"])
    parts = env.engine.run_processes["J1"][RunProcessKey.PARTICIPANTS]
    print(f"  PARTICIPANTS tokens: {sorted(parts.keys())} (site-1={t1}, site-2={t2})")
    # both CJs are running and have been reported by heartbeat once
    env.client_heartbeat("site-1", t1, ["J1"])
    env.client_heartbeat("site-2", t2, ["J1"])

    if restart:
        # site-1 CP crashes; its CJ dies with it (CJ monitor_parent_process); a supervisor restarts the CP,
        # which registers again (fed_client_base.client_register runs only when self.token is empty).
        t1_new = register(env, "site-1")
        print(f"  site-1 re-registered: new token {t1_new}; old token still in client_manager? {t1 in env.cm.clients}")
        hb_token = t1_new
    else:
        # control: CP alive, only the CJ died -> heartbeat with the same token and no job
        hb_token = t1

    for _ in range(3):
        env.client_heartbeat("site-1", hb_token, [])
    env.server.remove_dead_clients()  # dead-client scan (old token is no longer listed)

    msgs = dead_job_msgs(env, "J1")
    active = _get_active_job_participants(connected_clients=env.cm.clients, participants=parts)
    print(f"  HANDLE_DEAD_JOB messages sent to SJ for J1: {len(msgs)}")
    print(f"  ABORT targets if J1 is stopped now (_get_active_job_participants): {active}")
    print(f"  pending outcomes: {env.job_runner._pending_client_outcomes}")
    env.stop()
    return len(msgs), active


if __name__ == "__main__":
    print("== control: CJ died, CP alive (same token) ==")
    ctl = scenario(restart=False)
    print("== CP restart + re-registration (new token) ==")
    res = scenario(restart=True)
    print(f"\nRESULT: dead-job notifications control={ctl[0]} restart={res[0]}; abort targets control={ctl[1]} restart={res[1]}")
