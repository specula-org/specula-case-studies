#!/usr/bin/env python3
"""Harvest the checkpoints hunt8's C track starts from (2 per family and phase).
Run before `hunt.py hunt8 plans/hunt8.py`; idempotent (existing checkpoints are kept)."""
import runpy, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import ckpt, mkmc  # noqa: E402

h7 = runpy.run_path(str(ROOT / "plans" / "hunt8.py"))
F, grain = h7["F"], h7["grain"]
mkmc.build("ck_warmup", faults=[], sites=1, rarity=0)      # write MixR.tla once, before the parallel builds
jobs = []
for fam, (fl, fine, prof, net, smin) in F.items():
    s, l, a = h7["ck_inst"](fam)
    kw = dict(grain=grain(fine, net, fam == "allP"), faults=fl, sites=s, launch=l, attempt=a, profile=prof)
    for ph in h7["CK_PHASES"]:
        if ph == 4 and a < 2:
            continue
        jobs.append((h7["ck_key"](fam), kw, ph))


def one(j):
    key, kw, ph = j
    got = ckpt.harvest(key, kw, ph, 2, timeout=180)
    return f"{key} p{ph}: {len(got)}"


with ThreadPoolExecutor(12) as ex:
    for line in ex.map(one, jobs):
        print(line, flush=True)
