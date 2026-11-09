"""v11 step 4: refinement of the existing groups whose coarse module changed (all v11
switches off), harness receipts compared with the pre-v11 tree, negative controls."""
import json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
OLD = ROOT / ".tmp" / "v10ws"
ENV = dict(os.environ, MIX_INCLUDE_WIP="all", PYTHONDONTWRITEBYTECODE="1")
def run(ws, script, args, tag):
    p = subprocess.run([sys.executable, "-B", str(ws / "scripts" / script)] + args + ["--run"],
                       capture_output=True, text=True, env=ENV, cwd=ws)
    out = p.stdout + p.stderr
    keep = [l for l in out.splitlines() if "'result'" in l or "receipt" in l or "rror" in l]
    return tag + ": " + " | ".join(keep)[-700:]
H = "gen_harness.py"; R = "gen_ref.py"
jobs = [
  (OLD, H, ["Trainer", "F", "C", "--env", "Env_Trainer", "--sites", "1", "--launch", "2", "--const", "MaxGen=3", "--timeout", "900", "--workers", "16"], "trainer_old"),
  (ROOT, H, ["Trainer", "F", "C", "--env", "Env_Trainer", "--sites", "1", "--launch", "2", "--const", "MaxGen=3", "--timeout", "900", "--workers", "16"], "trainer_new"),
  (ROOT, H, ["Trainer", "F", "C", "--env", "Env_Trainer", "--sites", "1", "--launch", "2", "--const", "MaxGen=3", "--negative", "--timeout", "300", "--workers", "4"], "trainer_neg"),
  (OLD, H, ["RunCJ", "F", "C", "--env", "Env_RunCJ", "--sites", "1", "--launch", "2", "--faults", "cjCrash,netLoss,slowSJTeardown", "--timeout", "900", "--workers", "16"], "runcj_old"),
  (ROOT, H, ["RunCJ", "F", "C", "--env", "Env_RunCJ", "--sites", "1", "--launch", "2", "--faults", "cjCrash,netLoss,slowSJTeardown", "--timeout", "900", "--workers", "16"], "runcj_new"),
  (ROOT, R, ["CommSJ", "F", "C", "--sites", "1", "--attempt", "2", "--faults", "cbFail,taskTimeout,cjCrash", "--timeout", "1500", "--workers", "16", "--tag", "v11"], "commsj"),
  (ROOT, R, ["CommSJ", "F", "C", "--sites", "1", "--attempt", "2", "--faults", "cbFail,taskTimeout,cjCrash", "--negative", "--timeout", "600", "--workers", "4", "--tag", "v11n"], "commsj_neg"),
  (ROOT, R, ["TaskCJ", "F", "C", "--sites", "1", "--launch", "2", "--faults", "cjCrash,submitTimeout,taskTimeout", "--timeout", "1500", "--workers", "16", "--tag", "v11"], "taskcj"),
  (ROOT, R, ["TaskCJ", "F", "C", "--sites", "1", "--launch", "2", "--faults", "cjCrash,submitTimeout,taskTimeout", "--negative", "--timeout", "600", "--workers", "4", "--tag", "v11n"], "taskcj_neg"),
  (ROOT, R, ["JobCP", "F", "C", "--sites", "1", "--launch", "2", "--faults", "cjCrash,abort,cpCrash,rpcTimeout", "--timeout", "1500", "--workers", "16", "--tag", "v11"], "jobcp"),
  (ROOT, R, ["JobCP", "F", "C", "--sites", "1", "--launch", "2", "--faults", "cjCrash,abort,cpCrash,rpcTimeout", "--negative", "--timeout", "600", "--workers", "4", "--tag", "v11n"], "jobcp_neg"),
]
with ThreadPoolExecutor(len(jobs)) as ex:
    fs = [ex.submit(run, *j) for j in jobs]
    for f in fs:
        print(f.result(), flush=True)
