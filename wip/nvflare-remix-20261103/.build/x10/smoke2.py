"""v10 taskMode smoke: compile + short BFS/sim with the GW properties."""
import sys, json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc, run_mc

GW_INV = ["GWOneUnsettled", "GWNoOldLaunchPod", "GWNoDeadEnd", "GWCommittedNotErrored"]
GW_PROP = ["GWNoRecomputeAfterCommit", "GWCkptMonotone", "GWNoCommitAfterAbort"]
BASE_INV = ["GFinishedNoAbnormalExitK2", "GFinishedNoLiveChildK", "GTerminalNoLiveSJ", "GFinishedAllOutcomesK",
            "GDoneSavedCompletedK", "GFreeAtMostOnce", "GNoFreeWhileAliveK", "GNoAllocAfterFree",
            "GNoChildWithoutAlloc", "GOneLiveLaunch", "GFinishedNoPanicK8"]
EXT = ["Mix", "Props", "GenericProps", "PropsMR", "PropsLocal"]
G_ALLF = dict(JobSP="C", JobCP="F", RunCJ="F", TaskCJ="F", Trainer="C", PaySrc="C", PayRcv="C",
              CommSJ="C", WfSJ="C", Reg="C", Worker="F", Net="R")


def go(name, grain, faults, sites=1, launch=2, attempt=1, mode="sim", depth=(300, 2000), timeout=300,
       inv=None, prop=None, deadlock=False, constraint=None, extra_defs="", workers=8, **kw):
    mkmc.build(name, grain=grain, faults=faults, sites=sites, launch=launch, attempt=attempt,
               inv=list(inv if inv is not None else BASE_INV + GW_INV),
               prop=list(prop if prop is not None else GW_PROP), symmetry=False, deadlock=deadlock,
               profile=["taskMode"], constraint=constraint, extra_defs=extra_defs, extends=EXT, **kw)
    r = run_mc.run(name, timeout, workers, mode, depth, "16g")
    r.pop("cfg", None)
    print(name, json.dumps({k: v for k, v in r.items() if k in ("result", "violated", "distinct", "depth", "traces", "error", "secs")}), flush=True)
    return r


if __name__ == "__main__":
    which = sys.argv[1]
    if which == "bfs0":
        go("x10_bfs0", G_ALLF, [], mode="bfs", timeout=600, workers=16)
    elif which == "sim0":
        go("x10_sim0", G_ALLF, [], mode="sim", deadlock=True, timeout=300)
    elif which == "simW":
        go("x10_simW", G_ALLF, ["workerCrash", "workerFail", "ctrlLoss", "taskDeadline", "taskStageFail",
                                 "settleTimeout", "cjCrash", "abort"], mode="sim", deadlock=True, timeout=600)
    elif which == "simWC":
        go("x10_simWC", dict(G_ALLF, Worker="C"), ["workerCrash", "workerFail", "ctrlLoss", "taskDeadline",
                                 "taskStageFail", "settleTimeout", "cjCrash", "abort"], mode="sim", deadlock=True, timeout=600)
