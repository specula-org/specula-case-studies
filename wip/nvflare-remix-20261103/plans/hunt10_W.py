# v10 task worker hunt (profile taskMode): phase-gated BFS from Init + fused simulation
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
P8 = runpy.run_path(str(ROOT / "plans" / "hunt8.py"))["PLAN"]
base = [p for p in P8 if p.get("family") == "multi" and p["track"] == "S"][0]
GRAIN = dict(JobSP="F", JobCP="F", RunCJ="F", TaskCJ="F", Worker="F", CommSJ="F", WfSJ="F",
             Trainer="C", PaySrc="C", PayRcv="C", Reg="C", Net="R")
GW_INV = ["GWOneUnsettled", "GWNoOldLaunchPod", "GWNoDeadEnd", "GWCommittedNotErrored", "LWAtMostOnce"]
# GWNoCommitAfterAbort (W4) restates two local guards and is not hunted (RESULTS 16.2)
GW_PROP = ["GWNoRecomputeAfterCommit", "GWCkptMonotone"]
COMMON = dict(track="W", grain=GRAIN, profile=["taskMode"], inv=base["inv"] + GW_INV, prop=base["prop"] + GW_PROP,
              extends=base["extends"] + ["JobPhase"], known=True, heap="24g", symmetry=False)
FAM = {
    "rec": ["workerCrash", "cjCrash"],
    "ctl": ["ctrlLoss", "settleTimeout", "taskDeadline", "taskStageFail"],
    "fail": ["workerFail", "abort"],
    "net": ["netLoss", "submitTimeout", "workerCrash"],
}
ALL = ["workerCrash", "workerFail", "taskStageFail", "ctrlLoss", "settleTimeout", "taskDeadline",
       "cjCrash", "abort", "netLoss", "submitTimeout", "deleteJob", "taskTimeout"]
PLAN = []
for fam, f in FAM.items():
    PLAN.append(dict(COMMON, name=f"h10W_bfs_{fam}_s1l2a2", family=fam, faults=f, sites=1, launch=2, attempt=2,
                     rarity=2, deadlock=False, extra_defs="UpToEndRun == JobPhase <= 5", constraint="UpToEndRun",
                     mode="bfs", timeout=1800, workers=16))
    PLAN.append(dict(COMMON, name=f"h10W_sim_{fam}_s2l2a2", family=fam, faults=f, sites=2, launch=2, attempt=2,
                     rarity=4, throttle=20, fuse=True, deadlock=True, mode="sim", depth=2500, timeout=1800, workers=8))
for sites in (1, 2):
    PLAN.append(dict(COMMON, name=f"h10W_sim_all_s{sites}l2a2", family="all", faults=ALL, sites=sites, launch=2, attempt=2,
                     rarity=4, throttle=20, fuse=True, deadlock=True, mode="sim", depth=2500, timeout=1800, workers=8))
