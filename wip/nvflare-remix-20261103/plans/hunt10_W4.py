# v10 part 3b: do the checkpoint BFS runs reach recovery? Same witnesses, from the rec checkpoints.
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
W2 = runpy.run_path(str(ROOT / "plans" / "hunt10_W2.py"))
W = runpy.run_path(str(ROOT / "plans" / "hunt10_W.py"))
CK = ROOT / "checks" / "ckpt"
PLAN = []
for k in ("recovered", "restartAfterWorker", "commit2"):
    for ph in (2, 3):
        st = [x.read_text() for x in sorted((CK / "v10_rec_s1l2a2").glob(f"p{ph}_*.tla"))]
        PLAN.append(dict(W["COMMON"], name=f"h10W4_ckwit_{k}_p{ph}", family="wit", faults=W["FAM"]["rec"], sites=1,
                         launch=2, attempt=2, inv=[f"Wit_{k}"], prop=[], rarity=2, deadlock=False, init_states=st,
                         extra_defs=f"Wit_{k} == ~({W2['WIT'][k]})", mode="bfs", timeout=600, workers=6))
