# T4 check: the two hunt8 C runs that reported GDoneSavedCompletedK, after the fix,
# as is and with the slowFinalize escape enabled
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
base = {p["name"]: p for p in runpy.run_path(str(ROOT / "plans" / "hunt8.py"))["PLAN"]}
PLAN = []
for n in ["h8C_del_p5_k2", "h8C_job_p5_k2"]:
    p = base[n]
    PLAN.append(dict(p, name=n + "_t4"))
    PLAN.append(dict(p, name=n + "_t4slow", faults=list(p["faults"]) + ["slowFinalize"], rarity=4))
