# hit-rate measurement of the original simulated T2 / L13 regressions on the final model:
# 4 runs x 900 s each (unchanged configuration) and 1 run x 3600 s each
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
base = {p["name"]: p for p in runpy.run_path(str(ROOT / "plans" / "hunt8.py"))["PLAN"]}
PLAN = []
for n in ["h8D_t2sim_s2l1a1", "h8D_l13sim_s1l1a1"]:
    for i in range(1, 5):
        PLAN.append(dict(base[n], name=f"{n}_r{i}"))
    PLAN.append(dict(base[n], name=f"{n}_long", timeout=3600, workers=12))
