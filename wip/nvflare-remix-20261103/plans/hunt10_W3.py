# v10 part 2b: the same reachability witnesses by fused simulation (the paths are deep for BFS)
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
W2 = runpy.run_path(str(ROOT / "plans" / "hunt10_W2.py"))
W = runpy.run_path(str(ROOT / "plans" / "hunt10_W.py"))
PLAN = []
for k, expr in W2["WIT"].items():
    PLAN.append(dict(W["COMMON"], name=f"h10W3_simwit_{k}", family="wit", faults=W2["FAULT"][k], sites=1, launch=2,
                     attempt=2, inv=[f"Wit_{k}"], prop=[], rarity=4, throttle=20, fuse=True, deadlock=False,
                     extra_defs=f"Wit_{k} == ~({expr})", mode="sim", depth=2500, timeout=900, workers=8))
