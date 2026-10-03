#!/usr/bin/env python3
"""MC-7 repro: live run_processes iteration can kill dead-client cleanup.

This is a per-finding reproduction harness, not a product fix.  It drives the
real BaseServer.client_cleanup(), BaseServer.remove_dead_clients(),
FederatedServer.notify_dead_client(), and ServerEngine.wait_for_complete()
methods from the pinned source.  The object graph is injected at the same
reachable state that _start_runner_process creates: multiple entries in
engine.run_processes, each with RunProcessKey.PARTICIPANTS.
"""

from __future__ import annotations

import os
import sys
import tempfile
import threading
import time
from types import SimpleNamespace


SOURCE = "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-7/worktree"
sys.path.insert(0, SOURCE)

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.fl_constant import RunProcessKey  # noqa: E402
from nvflare.private.fed.server.client_manager import ClientManager  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
from nvflare.private.fed.server.server_engine import ServerEngine  # noqa: E402


class _Logger:
    def __init__(self):
        self.messages = []

    def _record(self, level, msg):
        self.messages.append((level, str(msg)))

    def debug(self, msg, *args, **kwargs):
        self._record("debug", msg)

    def info(self, msg, *args, **kwargs):
        self._record("info", msg)

    def warning(self, msg, *args, **kwargs):
        self._record("warning", msg)

    def error(self, msg, *args, **kwargs):
        self._record("error", msg)


class _JobRunner:
    def get_client_outcome_jobs(self, client_name=None):
        return set()

    def is_client_outcome_pending(self, job_id, client_name):
        return False


class _FinishedProcess:
    def wait(self):
        return 0

    def poll(self):
        return 0


def _start_cleanup_thread(server):
    errors = []

    def target():
        try:
            server.client_cleanup()
        except BaseException as e:
            errors.append(e)

    thread = threading.Thread(target=target, name="client_cleanup_repro")
    thread.start()
    return thread, errors


def _make_server(job_ids, notify_dead_job):
    logger = _Logger()
    client_manager = ClientManager(project_name="repro", min_num_clients=1, max_num_clients=10)
    clients = {
        "token-dead": Client("site-dead", "token-dead"),
        "token-later": Client("site-later", "token-later"),
    }
    now = time.time()
    for client in clients.values():
        client.last_connect_time = now + 3600.0
    client_manager.set_clients(dict(clients))

    engine = ServerEngine.__new__(ServerEngine)
    engine.lock = threading.Lock()
    engine.run_processes = {}
    engine.exception_run_processes = {}
    engine.logger = logger
    engine.engine_info = SimpleNamespace(status=None)
    engine.client_manager = client_manager
    engine.job_runner = _JobRunner()
    engine.notify_dead_job = notify_dead_job

    for job_id in job_ids:
        engine.run_processes[job_id] = {
            RunProcessKey.JOB_ID: job_id,
            RunProcessKey.PARTICIPANTS: {"token-dead": clients["token-dead"]},
            RunProcessKey.PROCESS_FINISHED: True,
        }

    server = object.__new__(FederatedServer)
    server.logger = logger
    server.shutdown = False
    server.heart_beat_timeout = 0.1
    server.client_manager = client_manager
    server.admin_server = None
    server.tokens = {}
    server.engine = engine
    return server, engine, client_manager


def _wait_for(predicate, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


def control_without_concurrent_mutation():
    notified = threading.Event()

    def notify_dead_job(job_id, client_name, reason):
        notified.set()

    server, _engine, client_manager = _make_server(["job-control"], notify_dead_job)
    client_manager.clients["token-dead"].last_connect_time = time.time() - 10.0

    thread, errors = _start_cleanup_thread(server)
    removed = _wait_for(lambda: "token-dead" not in client_manager.clients)
    alive_after_first_pass = thread.is_alive()
    server.shutdown = True
    thread.join(timeout=2.0)

    print("CONTROL no concurrent run_processes mutation:")
    print(f"  dead token removed={removed}")
    print(f"  cleanup thread alive after first pass={alive_after_first_pass}")
    print(f"  captured exceptions={[repr(e) for e in errors]}")

    assert removed, "control failed: expired client was not removed"
    assert notified.is_set(), "control failed: dead-job notification path was not reached"
    assert alive_after_first_pass, "control failed: cleanup thread died without concurrent mutation"
    assert not errors, "control failed: unexpected exception without concurrent mutation"


def reproduce_mc7():
    entered_dead_job_rpc = threading.Event()
    removal_done = threading.Event()
    notifications = []

    def notify_dead_job(job_id, client_name, reason):
        notifications.append((job_id, client_name, reason))
        if job_id == "job-A":
            entered_dead_job_rpc.set()
            if not removal_done.wait(timeout=5.0):
                raise RuntimeError("test harness timed out waiting for concurrent run_processes removal")

    server, engine, client_manager = _make_server(["job-A", "job-B"], notify_dead_job)
    client_manager.clients["token-dead"].last_connect_time = time.time() - 10.0

    thread, errors = _start_cleanup_thread(server)
    if not entered_dead_job_rpc.wait(timeout=5.0):
        server.shutdown = True
        thread.join(timeout=2.0)
        raise AssertionError("cleanup thread did not enter _notify_dead_job for job-A")

    with tempfile.TemporaryDirectory() as workspace:
        engine.wait_for_complete(workspace=workspace, job_id="job-B", process=_FinishedProcess())

    job_b_removed = "job-B" not in engine.run_processes
    removal_done.set()
    thread.join(timeout=5.0)

    cleanup_thread_dead = not thread.is_alive()
    captured = [repr(e) for e in errors]
    runtime_error = any(isinstance(e, RuntimeError) and "dictionary changed size during iteration" in str(e) for e in errors)

    # Demonstrate the live consequence: the only periodic cleanup thread is gone,
    # so a later expired client remains registered after more than one cleanup interval.
    client_manager.clients["token-later"].last_connect_time = time.time() - 10.0
    time.sleep(5.4)
    later_client_still_registered = "token-later" in client_manager.clients
    engine_clients_after_later_expiry = [client.name for client in engine.get_clients()]

    server.shutdown = True
    thread.join(timeout=1.0)

    print("REPRO concurrent ServerEngine.wait_for_complete removal during notify_dead_client:")
    print(f"  notifications_before_failure={notifications}")
    print(f"  job-B removed by real wait_for_complete={job_b_removed}")
    print(f"  cleanup thread dead={cleanup_thread_dead}")
    print(f"  captured exceptions={captured}")
    print(f"  later expired client still registered after >5s={later_client_still_registered}")
    print(f"  ServerEngine.get_clients() after later expiry={engine_clients_after_later_expiry}")

    assert job_b_removed, "setup failed: real wait_for_complete did not remove job-B"
    assert cleanup_thread_dead, "bug did not trigger: cleanup thread is still alive"
    assert runtime_error, "bug did not trigger: expected dictionary-size RuntimeError"
    assert later_client_still_registered, "bug consequence masked: later expired client was cleaned up"
    assert "site-later" in engine_clients_after_later_expiry, "bug consequence masked: engine no longer exposes later expired client"


def main():
    print("source:", os.path.realpath(SOURCE))
    print("escalation:")
    print("  Level 0/1 full-deployment trigger: not reproduced in this compact worker harness")
    print("  Level 2 reachable state injection: run_processes populated as _start_runner_process does")
    print("  Timing assistance: fake child RPC blocks while real ServerEngine.wait_for_complete pops job-B")
    control_without_concurrent_mutation()
    reproduce_mc7()
    print("RESULT: MC-7 reproduced")


if __name__ == "__main__":
    main()
