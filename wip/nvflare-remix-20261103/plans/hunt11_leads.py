# v11 lead properties under blind fused simulation (no action constraints, no directed witnesses):
# does search alone reach the consequences reproduced on real code (RESULTS 18)?
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
P = runpy.run_path(str(ROOT / "plans" / "hunt11.py"))["PLAN"]
by = {p["family"]: p for p in P if not p["name"].endswith("_b")}
LEADS = [("sag", "V11FinishedModelUsable"), ("k8s", "V11ResultsReturned"), ("k8s", "V11CompletedNotFailed"),
         ("swarm", "V11GatherComplete"), ("swarm", "V11NoSelfStop"), ("att", "V11AttachNoFalseSuccess")]
PLAN = []
for fam, prop in LEADS:
    base = by[fam]
    PLAN.append(dict(base, name=f"h11L_{fam}_{prop}", inv=[prop], prop=[], extends=base["extends"] + ["PropsV11"],
                     known=False, deadlock=False, timeout=900, workers=4))
