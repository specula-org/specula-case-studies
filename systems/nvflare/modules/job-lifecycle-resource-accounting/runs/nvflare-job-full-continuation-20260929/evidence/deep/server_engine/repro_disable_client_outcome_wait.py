"""Lead from archaeology batch 4: disable_clients / remove_clients bypass notify_dead_client.

Real objects: FederatedServer (process_job_failure, client_heartbeat, _listen_command, logout_client),
ServerEngine (disable_clients, remove_clients, wait_for_complete), ClientManager, JobRunner
(_job_complete_process + outcome tracking), DefaultJobScheduler (slot accounting via JOB_* events).
Fakes: job store, job handle (process), cell.

client_outcome_wait_timeout is set to OUTCOME_TIMEOUT seconds (default 900 s in product) so the
wait can be measured quickly; the product value only scales the delay.
"""

import sys
import time

from harness import Env, now
from nvflare.apis.fl_constant import ServerCommandNames
from nvflare.apis.fl_context import FLContext
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey
from nvflare.fuel.f3.message import Message as CellMessage
from nvflare.private.defs import CellMessageHeaderKeys

OUTCOME_TIMEOUT = 4.0


def sj_finish(env, job_id, handle, execution_error=False, rc=0):
    # The SJ sends UPDATE_RUN_STATUS (real handler) and then exits.
    req = CellMessage(
        {CellMessageHeaderKeys.JOB_ID: job_id, MessageHeaderKey.TOPIC: ServerCommandNames.UPDATE_RUN_STATUS},
        {"execution_error": execution_error},
    )
    env.server._listen_command(req)
    handle.exit(rc)


def run(scenario):
    env = Env(outcome_timeout=OUTCOME_TIMEOUT, max_jobs=1)
    c1 = env.add_client("site-1")
    c2 = env.add_client("site-2")
    job, handle = env.start_job("J1", ["site-1", "site-2"])
    env.start_completer()
    time.sleep(0.3)

    # both clients were running J1 and had heartbeated it
    for c in (c1, c2):
        env.client_heartbeat(c.name, c.token, ["J1"])

    if scenario == "disable":
        res = env.engine.disable_clients(["site-2"])
        print(f"[{now()}] admin disable_client site-2 -> {res['clients'][0]['state']}")
    elif scenario == "remove":
        env.engine.remove_clients([c2.token])
        print(f"[{now()}] admin remove_client site-2 (token released)")
    elif scenario == "logout":
        env.server.logout_client(c2.token)
        print(f"[{now()}] control: dead-client path logout_client(site-2) -> notify_dead_client")
    print(f"    pending outcomes after admin op: {env.job_runner._pending_client_outcomes}")

    # site-2's CJ finishes and tries to report; its heartbeat also comes in
    rc = env.client_report("site-2", c2.token, "J1", 0)
    print(f"[{now()}] site-2 outcome report reply rc={rc}")
    if scenario != "remove":
        hb = env.client_heartbeat("site-2", c2.token, [])
        print(f"[{now()}] site-2 heartbeat reply rc={hb[0]}")

    # site-1 completes normally and reports
    rc = env.client_report("site-1", c1.token, "J1", 0)
    print(f"[{now()}] site-1 outcome report reply rc={rc}")
    print(f"    pending outcomes before SJ exit: {env.job_runner._pending_client_outcomes}")

    t_exit = time.monotonic()
    sj_finish(env, "J1", handle)
    print(f"[{now()}] SJ for J1 exited rc=0 (normal completion)")

    ctx = FLContext()
    blocked_samples = []
    while True:
        time.sleep(0.25)
        blocked_samples.append(env.scheduler._exceed_max_jobs(ctx))
        if any(e[1] == "_job_completed" or e[1].endswith("completed") for e in env.events if e[2] == "J1"):
            break
        if time.monotonic() - t_exit > OUTCOME_TIMEOUT + 5:
            break
    dt = time.monotonic() - t_exit
    print(f"[{now()}] J1 terminal status log: {env.status_of('J1')}")
    print(f"    events: {env.events}")
    print(
        f"    RESULT[{scenario}]: J1 finalized {dt:.2f}s after SJ exit; scheduler slot held (max_jobs=1 exceeded) in "
        f"{sum(blocked_samples)}/{len(blocked_samples)} samples during the wait"
    )
    env.stop()
    return dt


if __name__ == "__main__":
    results = {}
    for sc in sys.argv[1:] or ["logout", "disable", "remove"]:
        print(f"\n===== scenario: {sc} =====")
        results[sc] = run(sc)
    print("\nSUMMARY (seconds from SJ exit to JOB_COMPLETED):", {k: round(v, 2) for k, v in results.items()})
