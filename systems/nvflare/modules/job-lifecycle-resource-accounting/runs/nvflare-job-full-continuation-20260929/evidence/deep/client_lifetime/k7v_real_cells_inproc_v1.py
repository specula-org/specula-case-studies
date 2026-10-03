#!/usr/bin/env python3
"""K7 variant with REAL CellNet cells: CP-like parent cell (internal listener) + CJ-like child cell.

1. child sends NOTIFY_JOB_STATUS STARTED via the real ClientAppRunner.notify_job_status -> parent replies OK (control)
2. parent cell is stopped (stand-in for CP process death); ClientAppRunner.stop() is invoked (what
   monitor_parent_process does on parent death); the child's STARTED notification loop is run again with the
   default retry_timeout semantics (shortened to 1 s) and we measure attempts/sec after the retry window.
Only the network topology is set up by the harness; message handling is the real cell + real notify loop.
"""
import json
import os
import sys
import threading
import time
from types import SimpleNamespace

SOURCE = "/home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/full/source"
import nvflare  # noqa: E402

assert os.path.realpath(nvflare.__file__).startswith(SOURCE)
import logging  # noqa: E402

logging.basicConfig(level=logging.CRITICAL)

from nvflare.fuel.f3.cellnet.cell import Cell  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode  # noqa: E402
from nvflare.fuel.f3.message import Message as CellMessage  # noqa: E402
from nvflare.private.defs import CellChannel, TrainingTopic  # noqa: E402
from nvflare.private.fed.client.client_app_runner import ClientAppRunner  # noqa: E402
from nvflare.private.fed.client.client_status import ClientStatus  # noqa: E402

out = sys.argv[1]
report = {}
received = []


def cb(request: CellMessage):
    received.append(request.payload.get_header("job_status"))
    m = CellMessage()
    m.set_header(MessageHeaderKey.RETURN_CODE, ReturnCode.OK)
    return m


import socket  # noqa: E402

_s = socket.socket()
_s.bind(("127.0.0.1", 0))
PORT = _s.getsockname()[1]
_s.close()
ROOT_URL = f"tcp://127.0.0.1:{PORT}"
root = Cell(fqcn="server", root_url=ROOT_URL, secure=False, credentials={}, create_internal_listener=False)
root.start()
parent = Cell(fqcn="site-1", root_url=ROOT_URL, secure=False, credentials={}, create_internal_listener=True)
parent.register_request_cb(channel=CellChannel.CLIENT_MAIN, topic=TrainingTopic.NOTIFY_JOB_STATUS, cb=cb)
parent.start()
url = parent.get_internal_listener_url()
child = Cell(fqcn="site-1.job-X", root_url=ROOT_URL, secure=False, credentials={}, create_internal_listener=False,
             parent_url=url)
child.start()
time.sleep(2.0)

fc = SimpleNamespace(cell=child)
runner = ClientAppRunner()
aborted = {"n": 0}
runner.client_runner = SimpleNamespace(abort=lambda: aborted.__setitem__("n", aborted["n"] + 1))

t = time.time()
runner.notify_job_status(fc, "job-X", ClientStatus.STARTED, timeout=2.0, retry_timeout=5.0)
report["control_notify_secs"] = round(time.time() - t, 3)
report["control_parent_received"] = list(received)

# --- parent (CP) dies
parent.stop()
time.sleep(1.0)
runner.stop()  # monitor_parent_process() -> runner.stop()
report["client_runner_abort_calls"] = aborted["n"]

counts = {"n": 0}
orig = child.send_request


rcs = []


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
t0 = time.time()
th.start()
time.sleep(3.0)
n3 = counts["n"]
time.sleep(2.0)
n5 = counts["n"]
report["attempts_first_3s"] = n3
report["attempts_3s_to_5s"] = n5 - n3
report["attempts_per_sec_after_retry_window"] = round((n5 - n3) / 2.0, 1)
report["notify_returned"] = done.is_set()
reply = orig(target="site-1", channel=CellChannel.CLIENT_MAIN, topic=TrainingTopic.NOTIFY_JOB_STATUS,
             request=CellMessage(), timeout=2.0, optional=True)
report["sample_reply_rc_after_parent_death"] = reply.get_header(MessageHeaderKey.RETURN_CODE)
report["parent_received_total"] = list(received)
report["per_attempt_secs_rc_first10"] = rcs[:10]
report["distinct_rcs"] = sorted({r for _, r in rcs})
with open(out, "w") as f:
    json.dump(report, f, indent=2)
print(json.dumps(report, indent=2))
sys.stdout.flush()
os._exit(0)
