"""SE-1: BaseServer.client_cleanup (fed_server.py:290-304) has no exception handling; three ordinary
interleavings raise inside it and kill the dead-client detection thread for the rest of the server's life.

  A: remove_dead_clients iterates the LIVE ClientManager.clients dict (fed_server.py:313) without
     ClientManager.lock while a registration adds/removes a token     -> RuntimeError
  B: notify_dead_client iterates the LIVE engine.run_processes dict (fed_server.py:1109) while its
     body blocks in _notify_dead_job; another job's SJ exits meanwhile (wait_for_complete pops) -> RuntimeError
  C: remove_dead_clients acts on a stale snapshot: the stale client re-registers (old token popped)
     between the scan and logout_client(token) (fed_server.py:316-317); remove_client returns None and
     notify_dead_client(None) dereferences client.name (fed_server.py:1105)            -> AttributeError

The interleaving is forced with sys.settrace inside the cleanup thread only (a scheduling control: the
hook runs the competing real operation at a chosen line and waits for it; no product object is modified).
After the thread dies, a client that goes silent is never logged out: notify_dead_client never runs,
its pending outcome is never resolved and the SJ never receives HANDLE_DEAD_JOB.
"""

import sys
import threading
import time

import nvflare.private.fed.server.fed_server as fed_server_mod
from harness import Env
from nvflare.apis.fl_constant import ServerCommandNames
from nvflare.apis.shareable import Shareable
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey
from nvflare.fuel.f3.message import Message as CellMessage
from nvflare.private.defs import CellMessageHeaderKeys, ClientType

FED_FILE = fed_server_mod.__file__


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
    return env.server.register_client(req).payload[CellMessageHeaderKeys.TOKEN]


def line_of(func, text):
    import inspect

    src, start = inspect.getsourcelines(func)
    for i, s in enumerate(src):
        if text in s:
            return start + i
    raise ValueError(text)


def make_tracer(func_name, line_no, action):
    state = {"fired": False}

    def local(frame, event, arg):
        if event == "line" and frame.f_lineno == line_no and not state["fired"]:
            state["fired"] = True
            action()
        return local

    def tracer(frame, event, arg):
        if event == "call" and frame.f_code.co_filename == FED_FILE and frame.f_code.co_name == func_name:
            return local
        return None

    return tracer, state


def run_in_other_thread(fn):
    t = threading.Thread(target=fn, name="competitor")
    t.start()
    t.join()


def dead_job_msgs(env):
    return [s for s in env.server.cell.sent if s[3] == ServerCommandNames.HANDLE_DEAD_JOB]


def scenario(variant):
    env = Env()
    env.server.heart_beat_timeout = 1.0
    srv = env.server
    tokens = {n: register(env, n) for n in ("site-1", "site-2", "site-3")}
    env.start_job("J1", ["site-1", "site-2", "site-3"])
    if variant == "B":
        _, h2 = env.start_job("J2", ["site-2", "site-3"])

    # live clients keep heart-beating through the real ClientManager.heartbeat
    from nvflare.apis.fl_context import FLContext

    alive = {"site-2": tokens["site-2"], "site-3": tokens["site-3"]}
    stop_ka = threading.Event()

    def keepalive():
        while not stop_ka.is_set():
            for n, t in list(alive.items()):
                with FLContext() as c:
                    srv.client_manager.heartbeat(t, n, n, c)
            time.sleep(0.2)

    threading.Thread(target=keepalive, name="keepalive", daemon=True).start()

    # site-1 goes silent (its heartbeat stops): make it stale
    stale = srv.client_manager.clients[tokens["site-1"]]
    stale.last_connect_time = time.time() - 10

    if variant == "A":
        line = line_of(fed_server_mod.BaseServer.remove_dead_clients, "if client.last_connect_time <")
        tracer, st = make_tracer("remove_dead_clients", line, lambda: run_in_other_thread(lambda: register(env, "site-4")))
    elif variant == "B":
        line = line_of(fed_server_mod.FederatedServer.notify_dead_client, 'self._notify_dead_job(client, job_id, "client dead")')

        def j2_finishes():
            h2.exit(0)  # J2's SJ exits; the real wait_for_complete pops run_processes["J2"] (after <=2s)
            t_end = time.time() + 5
            while "J2" in env.engine.run_processes and time.time() < t_end:
                time.sleep(0.05)

        tracer, st = make_tracer("notify_dead_client", line, j2_finishes)
    elif variant == "N":  # control: no forced interleaving
        tracer, st = make_tracer("remove_dead_clients", -1, lambda: None)
    else:  # C
        line = line_of(fed_server_mod.BaseServer.remove_dead_clients, "client = self.logout_client(token)")
        tracer, st = make_tracer(
            "remove_dead_clients", line, lambda: run_in_other_thread(lambda: register(env, "site-1"))
        )

    errors = []

    def cleanup_thread_body():
        sys.settrace(tracer)
        try:
            srv.client_cleanup()  # the real thread body (no try/except inside)
        except BaseException as e:  # record what kills the real thread
            errors.append(repr(e))
            raise

    th = threading.Thread(target=cleanup_thread_body, name="client_cleanup")
    th.start()
    th.join(timeout=8)
    alive_after = th.is_alive()
    print(f"  hook fired={st['fired']}; client_cleanup thread alive={alive_after}; exception={errors}")

    # Consequence: site-3 now dies (goes silent) -> should be logged out after heart_beat_timeout (1s)
    n_before = len(dead_job_msgs(env))
    alive.pop("site-3")
    srv.client_manager.clients[tokens["site-3"]].last_connect_time = time.time() - 10
    time.sleep(6)  # > remove_interval (5s)
    still_listed = tokens["site-3"] in srv.client_manager.clients
    new_msgs = len(dead_job_msgs(env)) - n_before
    print(
        f"  after site-3 went silent: still listed as connected={still_listed}; new HANDLE_DEAD_JOB msgs={new_msgs}; "
        f"pending outcomes={env.job_runner._pending_client_outcomes}"
    )
    stop_ka.set()
    srv.shutdown = True
    th.join(timeout=2)
    env.stop()
    return (not alive_after) and bool(errors), still_listed


if __name__ == "__main__":
    import logging

    logging.getLogger().setLevel(logging.ERROR)
    results = {}
    for v in sys.argv[1:] or ["N", "A", "B", "C"]:
        print(f"== variant {v} ==")
        results[v] = scenario(v)
    print("\nRESULT (thread_died, later_dead_client_never_removed):", results)
