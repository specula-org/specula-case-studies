# v10 task worker hunt, part 3: phase-gated BFS from harvested mid-job checkpoints (taskMode)
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
W = runpy.run_path(str(ROOT / "plans" / "hunt10_W.py"))
COMMON, FAM = W["COMMON"], W["FAM"]
CK = ROOT / "checks" / "ckpt"
PLAN = []
for fam, f in FAM.items():
    for ph in (2, 3, 4):
        d = CK / f"v10_{fam}_s1l2a2"
        st = [x.read_text() for x in sorted(d.glob(f"p{ph}_*.tla"))] if d.exists() else []
        if not st:
            continue
        PLAN.append(dict(COMMON, name=f"h10C_{fam}_p{ph}_k2", family=fam, faults=f, sites=1, launch=2, attempt=2,
                         rarity=2, deadlock=True, init_states=st, ckpt=f"v10_{fam}_s1l2a2/p{ph}", mode="bfs",
                         timeout=1200, workers=10))
