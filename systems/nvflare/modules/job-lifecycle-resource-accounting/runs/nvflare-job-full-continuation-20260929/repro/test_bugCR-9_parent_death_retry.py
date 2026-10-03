#!/usr/bin/env python3
"""Reproduce CR-9: parent death does not interrupt ClientAppRunner notification retry.

The test uses real local processes and real CellNet cells:
  root process: a minimal server/root cell
  cp process: a client-parent-like cell that handles NOTIFY_JOB_STATUS
  child process: a client-job-like process running ClientAppRunner.notify_job_status

Flow:
  1. Control: child notifies CP successfully.
  2. The test kills the CP process. The child's real monitor_parent_process
     calls ClientAppRunner.stop(), which calls client_runner.abort().
  3. The child starts notify_job_status again. It does not return after
     retry_timeout, and continues to send attempts after parent death.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace


SOURCE = "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-9/worktree"
JOB_ID = "job-CR9"
CLIENT_FQCN = "site-1"
CHILD_FQCN = f"{CLIENT_FQCN}.{JOB_ID}"


def configure_imports() -> None:
    sys.path.insert(0, SOURCE)
    import nvflare  # noqa: PLC0415

    assert os.path.realpath(nvflare.__file__).startswith(SOURCE), nvflare.__file__


def pick_root_url() -> str:
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return f"tcp://127.0.0.1:{port}"


def wait_json(path: Path, predicate, timeout: float) -> dict:
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        if path.exists():
            try:
                data = json.loads(path.read_text())
                if predicate(data):
                    return data
            except Exception as e:  # JSON may be mid-write.
                last_error = e
        time.sleep(0.05)
    raise TimeoutError(f"timed out waiting for {path}; last_error={last_error}")


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def write_json(path: Path, data: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def root_role(root_url: str) -> None:
    configure_imports()
    logging.basicConfig(level=logging.CRITICAL)
    from nvflare.fuel.f3.cellnet.cell import Cell  # noqa: PLC0415

    root = Cell(fqcn="server", root_url=root_url, secure=False, credentials={}, create_internal_listener=False)
    root.start()
    print("READY", flush=True)
    while True:
        time.sleep(60)


def cp_role(root_url: str, out_path: Path) -> None:
    configure_imports()
    logging.basicConfig(level=logging.CRITICAL)
    from nvflare.fuel.f3.cellnet.cell import Cell  # noqa: PLC0415
    from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode  # noqa: PLC0415
    from nvflare.fuel.f3.message import Message as CellMessage  # noqa: PLC0415
    from nvflare.private.defs import CellChannel, TrainingTopic  # noqa: PLC0415

    cp = Cell(fqcn=CLIENT_FQCN, root_url=root_url, secure=False, credentials={}, create_internal_listener=True)

    def cb(request):
        reply = CellMessage()
        reply.set_header(MessageHeaderKey.RETURN_CODE, ReturnCode.OK)
        return reply

    cp.register_request_cb(channel=CellChannel.CLIENT_MAIN, topic=TrainingTopic.NOTIFY_JOB_STATUS, cb=cb)
    cp.start()
    cp_url = cp.get_internal_listener_url()

    child = subprocess.Popen(
        [sys.executable, __file__, "child", root_url, cp_url, str(out_path)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    print(f"CHILD {child.pid} {cp_url}", flush=True)
    while True:
        time.sleep(60)


def child_role(root_url: str, cp_url: str, out_path: Path) -> None:
    configure_imports()
    logging.basicConfig(level=logging.CRITICAL)
    from nvflare.fuel.f3.cellnet.cell import Cell  # noqa: PLC0415
    from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: PLC0415
    from nvflare.private.fed.app.utils import monitor_parent_process  # noqa: PLC0415
    from nvflare.private.fed.client.client_app_runner import ClientAppRunner  # noqa: PLC0415
    from nvflare.private.fed.client.client_status import ClientStatus  # noqa: PLC0415

    parent_pid = os.getppid()
    child = Cell(
        fqcn=CHILD_FQCN,
        root_url=root_url,
        secure=False,
        credentials={},
        create_internal_listener=False,
        parent_url=cp_url,
    )
    child.start()
    time.sleep(2.0)

    abort_calls = {"n": 0}

    def abort() -> None:
        abort_calls["n"] += 1

    runner = ClientAppRunner()
    runner.client_runner = SimpleNamespace(abort=abort)
    stop_event = threading.Event()
    monitor = threading.Thread(target=monitor_parent_process, args=(runner, parent_pid, stop_event), daemon=True)
    monitor.start()
    fc = SimpleNamespace(cell=child)

    t0 = time.time()
    runner.notify_job_status(fc, JOB_ID, ClientStatus.STARTED, timeout=2.0, retry_timeout=5.0)
    control_secs = time.time() - t0
    write_json(
        out_path,
        {
            "phase": "control_done",
            "child_pid": os.getpid(),
            "captured_parent_pid": parent_pid,
            "control_notify_secs": round(control_secs, 3),
            "monitor_abort_calls": abort_calls["n"],
        },
    )

    # Wait until the real monitor has observed parent death and called stop().
    deadline = time.time() + 8.0
    while time.time() < deadline and abort_calls["n"] == 0:
        time.sleep(0.05)

    attempts = {"n": 0}
    attempts_at = []
    rcs = []
    original_send_request = child.send_request

    def counting_send_request(**kwargs):
        attempts["n"] += 1
        now = time.time()
        attempts_at.append(now)
        reply = original_send_request(**kwargs)
        rcs.append(str(reply.get_header(MessageHeaderKey.RETURN_CODE)))
        return reply

    child.send_request = counting_send_request

    done = threading.Event()

    def retrying_notify() -> None:
        runner.notify_job_status(fc, JOB_ID, ClientStatus.STARTED, timeout=0.2, retry_timeout=1.0)
        done.set()

    start = time.time()
    retry_thread = threading.Thread(target=retrying_notify, daemon=True)
    retry_thread.start()
    time.sleep(1.4)
    attempts_after_retry_window_sample = attempts["n"]
    time.sleep(2.0)
    elapsed = time.time() - start
    returned = done.is_set()
    attempts_total = attempts["n"]

    stop_event.set()
    write_json(
        out_path,
        {
            "phase": "final",
            "child_pid": os.getpid(),
            "captured_parent_pid": parent_pid,
            "parent_pid_alive_when_retry_started": pid_alive(parent_pid),
            "control_notify_secs": round(control_secs, 3),
            "monitor_abort_calls": abort_calls["n"],
            "retry_elapsed_secs": round(elapsed, 3),
            "notify_returned_after_parent_death": returned,
            "attempts_after_1_4s": attempts_after_retry_window_sample,
            "attempts_after_3_4s": attempts_total,
            "attempts_1_4s_to_3_4s": attempts_total - attempts_after_retry_window_sample,
            "distinct_return_codes": sorted(set(rcs)),
            "first_return_codes": rcs[:5],
            "last_return_codes": rcs[-5:],
        },
    )
    os._exit(0)


def run_test() -> int:
    configure_imports()
    work_dir = Path(tempfile.mkdtemp(prefix="cr9-parent-death-"))
    out_path = work_dir / "child-report.json"
    root_url = pick_root_url()
    root = subprocess.Popen(
        [sys.executable, __file__, "root", root_url],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    cp = None
    child_pid = None
    try:
        ready = root.stdout.readline().strip()
        if ready != "READY":
            raise RuntimeError(f"root did not start: {ready!r}")

        cp = subprocess.Popen(
            [sys.executable, __file__, "cp", root_url, str(out_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        line = cp.stdout.readline().strip()
        parts = line.split()
        if len(parts) < 3 or parts[0] != "CHILD":
            raise RuntimeError(f"cp did not report child: {line!r}")
        child_pid = int(parts[1])

        control = wait_json(out_path, lambda d: d.get("phase") == "control_done", timeout=20.0)
        os.kill(cp.pid, signal.SIGKILL)
        cp.wait(timeout=10.0)
        final = wait_json(out_path, lambda d: d.get("phase") == "final", timeout=20.0)
        child_alive_during_retry = (
            not final["parent_pid_alive_when_retry_started"]
            and final["monitor_abort_calls"] >= 1
            and final["attempts_1_4s_to_3_4s"] > 0
            and not final["notify_returned_after_parent_death"]
        )
        result = {
            "work_dir": str(work_dir),
            "control": control,
            "final": final,
            "child_pid_observed": child_pid,
            "child_survived_parent_death_during_retry": child_alive_during_retry,
        }
        print(json.dumps(result, indent=2, sort_keys=True))
        if child_alive_during_retry:
            print("BUG_REPRODUCED: child notification retry continued after parent death and ClientAppRunner.stop().")
            return 0
        print("BUG_NOT_REPRODUCED: expected retry loop continuation was not observed.")
        return 1
    finally:
        if cp and cp.poll() is None:
            cp.kill()
        if root.poll() is None:
            root.kill()
        if child_pid and pid_alive(child_pid):
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def main() -> int:
    if len(sys.argv) > 1:
        role = sys.argv[1]
        if role == "root":
            root_role(sys.argv[2])
            return 0
        if role == "cp":
            cp_role(sys.argv[2], Path(sys.argv[3]))
            return 0
        if role == "child":
            child_role(sys.argv[2], sys.argv[3], Path(sys.argv[4]))
            return 0
        raise SystemExit(f"unknown role {role!r}")
    return run_test()


if __name__ == "__main__":
    raise SystemExit(main())
