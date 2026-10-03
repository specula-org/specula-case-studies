#!/usr/bin/env python3
"""Process-edge stub used in place of the CJ executable (nvflare...worker_process).

Records what the launched job process can observe (its env binding of CUDA_VISIBLE_DEVICES, pid, pgid, sid)
into a JSON file, optionally forks a grandchild that stays in the same process group, then sleeps.

usage: child_stub.py OUT_JSON SLEEP_SECS [grandchild_sleep_secs]
"""
import json
import os
import subprocess
import sys
import time

out, secs = sys.argv[1], float(sys.argv[2])
gc_secs = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
info = {
    "pid": os.getpid(),
    "pgid": os.getpgid(0),
    "sid": os.getsid(0),
    "CUDA_VISIBLE_DEVICES": os.environ.get("CUDA_VISIBLE_DEVICES", "<unset>"),
    "t_start": time.time(),
}
if gc_secs > 0:
    # grandchild inherits the process group (no setsid), like a training subprocess launched by the CJ
    gc = subprocess.Popen([sys.executable, "-c", f"import time; time.sleep({gc_secs})"])
    info["grandchild_pid"] = gc.pid
with open(out, "w") as f:
    json.dump(info, f)
time.sleep(secs)
