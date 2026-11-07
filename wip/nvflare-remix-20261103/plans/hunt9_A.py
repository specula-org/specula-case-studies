# v9 A-group (promise-derived) properties: BFS over the startup phase from Init, K=2
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
H8 = runpy.run_path(str(ROOT / "plans" / "hunt8.py"))
NEW = ["GNoStartAfterEarlyTerminal", "GNoStartAfterDelete"]
PRE = "PreStartOrUntilRunning == ~pJobSP.sjLaunched \\/ JobPhase <= 2"
PLAN = []
for fam, sites, launch in (("del", 1, 2), ("job", 1, 2), ("multi", 1, 2), ("del", 2, 1), ("job", 2, 1)):
    base = [p for p in H8["PLAN"] if p.get("family") == fam and p["track"] == "S"][0]
    PLAN.append(dict(name=f"h9A_{fam}_s{sites}l{launch}", track="A", family=fam, grain=base["grain"],
                     faults=base["faults"], sites=sites, launch=launch, attempt=2, profile=base["profile"],
                     inv=base["inv"], prop=base["prop"] + NEW, extends=base["extends"] + ["JobPhase"],
                     extra_defs=PRE, constraint="PreStartOrUntilRunning", known=True, deadlock=False,
                     rarity=2, mode="bfs", timeout=1800, workers=16, heap="24g", symmetry=False))
