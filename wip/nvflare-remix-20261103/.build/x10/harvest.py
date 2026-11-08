"""Harvest taskMode checkpoints (phases 2-4) for hunt10_C (mid-job BFS from a free prefix)."""
import runpy, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT = Path("/home/ubuntu/nvflare-remix-20261103")
sys.path.insert(0, str(ROOT / "scripts"))
import ckpt, mkmc
W = runpy.run_path(str(ROOT / "plans" / "hunt10_W.py"))
FAM, GRAIN = W["FAM"], W["GRAIN"]
mkmc.build("ck_warmup_v10", grain=GRAIN, faults=[], sites=1, rarity=0, profile=["taskMode"])
jobs = [(f"v10_{fam}_s1l2a2", dict(grain=GRAIN, faults=f, sites=1, launch=2, attempt=2, profile=["taskMode"]), ph)
        for fam, f in FAM.items() for ph in (2, 3, 4)]
def one(j):
    key, kw, ph = j
    return f"{key} p{ph}: {len(ckpt.harvest(key, kw, ph, 2, timeout=300))}"
with ThreadPoolExecutor(12) as ex:
    for line in ex.map(one, jobs):
        print(line, flush=True)
