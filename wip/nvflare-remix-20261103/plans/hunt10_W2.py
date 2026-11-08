# v10 task worker hunt, part 2: reachability witnesses for the paths W1-W6 depend on
# (a violated witness = the path is reached, with its depth) and 1-site fused simulations.
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
W = runpy.run_path(str(ROOT / "plans" / "hunt10_W.py"))
COMMON, FAM, ALL = W["COMMON"], W["FAM"], W["ALL"]
WIT = {
    "recovered": '\\E c \\in Sites, l \\in Launches : pWorker[c].out[l] /= None /\\ pWorker[c].out[l].reason = "recovered"',
    "saved": '\\E c \\in Sites, l \\in Launches : pWorker[c].out[l] /= None /\\ pWorker[c].out[l].reason = "saved"',
    "restartAfterWorker": '\\E c \\in Sites : pJobCP[c].launch = 2 /\\ \\E w \\in WAttempts : w[1] = 1 /\\ pWorker[c].att[w] /= "none"',
    "released": '\\E c \\in Sites, w \\in WAttempts : pWorker[c].store[w].completion /\\ ~pWorker[c].store[w].payload',
    "fenced": '\\E c \\in Sites, l \\in Launches : pWorker[c].out[l] /= None /\\ pWorker[c].out[l].reason = "unconfirmed"',
    "commit2": '\\E c \\in Sites : 2 \\in pWorker[c].committed',
}
FAULT = {"recovered": FAM["rec"], "saved": ["netLoss", "submitTimeout"], "restartAfterWorker": FAM["rec"],
         "released": [], "fenced": ["settleTimeout", "ctrlLoss"], "commit2": FAM["rec"]}
PLAN = []
for k, expr in WIT.items():
    PLAN.append(dict(COMMON, name=f"h10W2_wit_{k}", family="wit", faults=FAULT[k], sites=1, launch=2, attempt=2,
                     inv=[f"Wit_{k}"], prop=[], rarity=2, deadlock=False,
                     extra_defs=f"UpToEndRun == JobPhase <= 5\nWit_{k} == ~({expr})", constraint="UpToEndRun",
                     mode="bfs", timeout=900, workers=6))
for fam, f in list(FAM.items()) + [("all", ALL)]:
    PLAN.append(dict(COMMON, name=f"h10W2_sim_{fam}_s1l2a2", family=fam, faults=f, sites=1, launch=2, attempt=2,
                     rarity=4, throttle=20, fuse=True, deadlock=True, mode="sim", depth=2500, timeout=1800, workers=8))
