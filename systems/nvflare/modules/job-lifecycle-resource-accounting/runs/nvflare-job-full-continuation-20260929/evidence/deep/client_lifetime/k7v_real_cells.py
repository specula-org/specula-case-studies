#!/usr/bin/env python3
"""K7 variant with REAL CellNet cells in separate processes:
   process R: root cell "server" (stays alive, like the FL server)
   process P: CP-like cell "site-1" with internal listener, replying OK to NOTIFY_JOB_STATUS (killed with SIGKILL
              to model CP process death)
   this process: CJ-like child cell "site-1.job-X" (parent_url = P's internal listener, root_url = R)

1. control: real ClientAppRunner.notify_job_status STARTED -> P replies OK
2. SIGKILL P; call ClientAppRunner.stop() (what monitor_parent_process does on parent death); run the STARTED
   notification loop again (retry_timeout shortened to 1 s from the 15 s default) and measure attempts/sec and
   the reply codes after the retry window.
Only topology/timing is set up by the harness; message handling is the real cell stack + real notify loop.
(The earlier in-process attempt, k7v_real_cells_inproc_v1.py, is kept: Cell.stop() in-process did not model
process death -- the stopped parent still answered.)
"""
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from types import SimpleNamespace

SOURCE = "/home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/full/source"
ROLE = sys.argv[1]

import nvflare  # noqa: E402

assert os.path.realpath(nvflare.__file__).startswith(SOURCE)
import logging  # noqa: E402

logging.basicConfig(level=logging.CRITICAL)

from nvflare.fuel.f3.cellnet.cell import Cell  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode  # noqa: E402
from nvflare.fuel.f3.message import Message as CellMessage  # noqa: E402
from nvflare.private.defs import CellChannel, TrainingTopic  # noqa: E402

if ROLE == "root":
    root = Cell(fqcn="server", root_url=sys.argv[2], secure=False, credentials={}, create_internal_listener=False)
    root.start()
    print("READY", flush=True)
    time.sleep(3600)

if ROLE == "cp":

    def cb(request):
        m = CellMessage()
        m.set_header(MessageHeaderKey.RETURN_CODE, ReturnCode.OK)
        return m

    cp = Cell(fqcn="site-1", root_url=sys.argv[2], secure=False, credentials={}, create_internal_listener=True)
    cp.register_request_cb(channel=CellChannel.CLIENT_MAIN, topic=TrainingTopic.NOTIFY_JOB_STATUS, cb=cb)
    cp.start()
    print("URL " + cp.get_internal_listener_url(), flush=True)
    time.sleep(3600)

# ---- CJ role (main)
from nvflare.private.fed.client.client_app_runner import ClientAppRunner  # noqa: E402
from nvflare.private.fed.client.client_status import ClientStatus  # noqa: E402

out = sys.argv[2]
report = {}
s = socket.socket()
s.bind(("127.0.0.1", 0))
port = s.getsockname()[1]
s.close()
root_url = f"tcp://127.0.0.1:{port}"
me = os.path.abspath(__file__)
pr = subprocess.Popen([sys.executable, me, "root", root_url], stdout=subprocess.PIPE, text=True)
assert pr.stdout.readline().startswith("READY")
pp = subprocess.Popen([sys.executable, me, "cp", root_url], stdout=subprocess.PIPE, text=True)
line = pp.stdout.readline().strip()
cp_url = line.split(" ", 1)[1]
report["cp_internal_url"] = cp_url
try:
    child = Cell(fqcn="site-1.job-X", root_url=root_url, secure=False, credentials={},
                 create_internal_listener=False, parent_url=cp_url)
    child.start()
    time.sleep(2.0)
    fc = SimpleNamespace(cell=child)
    runner = ClientAppRunner()
    aborted = {"n": 0}
    runner.client_runner = SimpleNamespace(abort=lambda: aborted.__setitem__("n", aborted["n"] + 1))

    t = time.time()
    runner.notify_job_status(fc, "job-X", ClientStatus.STARTED, timeout=2.0, retry_timeout=5.0)
    report["control_notify_secs"] = round(time.time() - t, 3)

    os.kill(pp.pid, signal.SIGKILL)  # CP process death
    pp.wait()
    time.sleep(1.0)
    runner.stop()  # monitor_parent_process() -> runner.stop()
    report["client_runner_abort_calls"] = aborted["n"]

    counts = {"n": 0}
    rcs = []
    orig = child.send_request

    def counting_send_request(**kw):
        counts["n"] += 1
        t1 = time.time()
        r = orig(**kw)
        rcs.append((round(time.time() - t1, 3), r.get_header(MessageHeaderKey.RETURN_CODE)))
        return r

    child.send_request = counting_send_request
    done = threading.Event()

    def run():
        runner.notify_job_status(fc, "job-X", ClientStatus.STARTED, timeout=2.0, retry_timeout=1.0)
        done.set()

    th = threading.Thread(target=run, daemon=True)
    th.start()
    time.sleep(4.0)
    n4 = counts["n"]
    time.sleep(4.0)
    n8 = counts["n"]
    report["attempts_first_4s"] = n4
    report["attempts_4s_to_8s"] = n8 - n4
    report["attempts_per_sec_after_retry_window"] = round((n8 - n4) / 4.0, 1)
    report["notify_returned_after_parent_death"] = done.is_set()
    report["per_attempt_secs_rc_first5"] = rcs[:5]
    report["per_attempt_secs_rc_last3"] = rcs[-3:]
    report["distinct_rcs"] = sorted({r for _, r in rcs})
finally:
    for p in (pp, pr):
        try:
            p.kill()
        except Exception:
            pass
with open(out, "w") as f:
    json.dump(report, f, indent=2)
print(json.dumps(report, indent=2))
sys.stdout.flush()
os._exit(0)
