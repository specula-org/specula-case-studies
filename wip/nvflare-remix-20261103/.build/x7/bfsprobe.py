#!/usr/bin/env python3
"""Explosion probe: fault-free BFS of the smallest instances with action coverage."""
import sys, os, subprocess, signal
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc
G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ"]
tag, gr, sites, secs, workers = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
faults = [f for f in (sys.argv[6].split(",") if len(sys.argv) > 6 and sys.argv[6] else [])]
grain = {k: gr for k in G}; grain["Net"] = "R"
out_dir, mod, _ = mkmc.build(f"x7b_{tag}", grain=grain, faults=faults, sites=sites, launch=1, attempt=1,
                             inv=[], prop=[], extends=("Mix", "Props", "GenericProps"), deadlock=True, known=True)
env = dict(os.environ, TLC_WORKERS=str(workers), TLC_HEAP="16g")
p = subprocess.Popen([str(ROOT / "scripts/tlc.sh"), "tlc", str(out_dir), mod, f"{mod}.cfg", "-coverage", "1"],
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, start_new_session=True)
try:
    out, _ = p.communicate(timeout=secs)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGTERM); out, _ = p.communicate(timeout=60)
(ROOT / ".build/x7" / f"b_{tag}.log").write_text(out)
print(tag, "done")
