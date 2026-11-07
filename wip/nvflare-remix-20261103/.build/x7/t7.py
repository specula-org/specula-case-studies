#!/usr/bin/env python3
"""v7 mechanism tests: checkpoint BFS (normal, R1 and R2 rediscovery from a mid-job checkpoint)."""
import sys, runpy, json
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
ROOT = Path("/home/ubuntu/nvflare-remix-20261103"); sys.path.insert(0, str(ROOT / "scripts"))
import mkmc, run_mc, ckpt
h6 = runpy.run_path(str(ROOT / "plans/hunt6.py"))
G = h6["G"]; grain = {k: ("F" if k in ["JobSP", "JobCP", "RunCJ", "CommSJ", "TaskCJ"] else "C") for k in G}; grain["Net"] = "R"
PROC = ["spCrash", "cpCrash", "cjCrash", "rpcTimeout", "taskTimeout", "deadClient", "abort"]
base = dict(grain=grain, sites=1, launch=1, attempt=2, profile=["wfTolerant"])


def ck(key, faults, phase):
    return ckpt.harvest(key, dict(base, faults=faults), phase, 2)


s_proc3 = ck("test_proc_s1l1a2", PROC, 3)
s_r2 = ck("test_cpr_s1l1a2", ["cpCrash", "rpcTimeout"], 3)
print("checkpoints", len(s_proc3), len(s_r2), flush=True)
common = dict(base, inv=h6["GINV"] + h6["PINV"], prop=h6["GPROP"], extends=tuple(h6["EXT"]), deadlock=True)
mkmc.build("t7_ck_proc_p3_k1", faults=PROC, rarity=1, known=True, init_states=s_proc3, **common)
mkmc.build("t7_ck_R1_p3_k2", faults=PROC, rarity=2, known=True, init_states=s_proc3,
           **dict(common, inv=common["inv"] + ["GNoStaleStatusAfterRestart"]))
mkmc.build("t7_ck_R2_p3_k3", faults=["cpCrash", "rpcTimeout"], rarity=3, known=False, init_states=s_r2, **common)
with ThreadPoolExecutor(3) as ex:
    fs = {n: ex.submit(run_mc.run, n, 300, 10, "bfs", (0, 0), "16g") for n in
          ["t7_ck_proc_p3_k1", "t7_ck_R1_p3_k2", "t7_ck_R2_p3_k3"]}
    for n, f in fs.items():
        r = f.result(); r.pop("cfg", None); print(json.dumps(r), flush=True)
