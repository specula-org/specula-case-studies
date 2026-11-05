#!/usr/bin/env python3
"""Run the job groups' refinement receipts through scripts/gen_ref.py --run
(writes checks/receipts/*.json) for the campaign instances: 1 site, all job
faults, Net R and Net L (+netLoss), MaxLaunch 2 for JobCP/RunCJ.
job_receipts.py CHAIN TIMEOUT WORKERS   (CHAIN = comma list of Group:Net)"""
import os, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from job_mixes import JOB_FAULTS  # noqa: E402
os.environ.setdefault("MIX_BUILD", str(ROOT / ".build" / "job"))
os.environ.setdefault("MIX_INCLUDE_WIP", "JobSP,JobCP,RunCJ")
LAUNCH = {"JobSP": 1, "JobCP": 2, "RunCJ": 2}
chain, timeout, workers = sys.argv[1].split(","), sys.argv[2], sys.argv[3]
for item in chain:
    g, net = item.split(":")
    faults = JOB_FAULTS + (["netLoss"] if net == "L" else [])
    cmd = [sys.executable, str(ROOT / "scripts" / "gen_ref.py"), g, "F", "C", "--sites", "1",
           "--faults", ",".join(faults), "--launch", str(LAUNCH[g]), "--grain", f"Net={net}",
           "--run", "--timeout", timeout, "--workers", workers]
    print(" ".join(cmd), flush=True)
    # other agents edit their modules concurrently: rebuild our Mix first
    subprocess.run([sys.executable, str(ROOT / "scripts" / "gen_mix.py")], check=True)
    subprocess.run(cmd)
    # gen_ref reuses one model name per group; keep this instance's log/result
    import shutil
    for src, dst in [(ROOT / "logs" / f"ref_{g}_F_C.log", ROOT / "logs" / f"ref_{g}_F_C__{net}.log"),
                     (ROOT / "checks" / "results" / f"ref_{g}_F_C.json",
                      ROOT / "checks" / "results" / f"ref_{g}_F_C__{net}.json")]:
        if src.exists():
            shutil.copy(src, dst)
