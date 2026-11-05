#!/usr/bin/env python3
"""job agent wrapper around scripts/run_mc.py: runs NAME(s) and afterwards kills
any TLC JVM of those models left behind on timeout (run_mc.py only kills the
tlc.sh wrapper). job_run.py TIMEOUT WORKERS NAME... [--mode sim --depth d,n]"""
import os, subprocess, sys
from pathlib import Path
W = Path(__file__).resolve().parents[1]
os.environ.setdefault("MIX_BUILD", str(W / ".build" / "job"))
os.environ.setdefault("MIX_INCLUDE_WIP", "JobSP,JobCP,RunCJ")
t, w, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
names = [x for x in rest if not x.startswith("--") and not (rest.index(x) > 0 and rest[rest.index(x) - 1].startswith("--"))]
opts = [x for x in rest if x not in names]
try:
    subprocess.run([sys.executable, str(W / "scripts" / "run_mc.py"), *names, "--timeout", t,
                    "--workers", w, "--heap", os.environ.get("HEAP", "12g"), *opts])
finally:
    for n in names:
        subprocess.run(["pkill", "-f", f"tlc2.TLC .*MC_{n}.tla"])
