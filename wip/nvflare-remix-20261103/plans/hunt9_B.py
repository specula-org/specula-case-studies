# v9 B-group: SP shutdown/restart (fault spShutdown, timing escape slowShutdownAbort)
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
H8 = runpy.run_path(str(ROOT / "plans" / "hunt8.py"))
base = [p for p in H8["PLAN"] if p.get("family") == "multi" and p["track"] == "S"][0]
# K variants exclude the reproduced S4 (pass in progress) and leave S1 to LShutdownStopsAllK
INV = base["inv"] + ["LShutdownStopsAllK"]
PROP = base["prop"] + ["GNoStartAfterEarlyTerminal", "GNoStartAfterDelete", "LNoSpawnAfterShutdownK"]
GRAIN = dict(base["grain"])
COMMON = dict(track="B", family="shut", grain=GRAIN, profile=["multiJob"], inv=INV, prop=PROP,
              extends=base["extends"] + ["JobPhase"], known=True, heap="24g")
PLAN = []
for sites in (1, 2):
    for tag, f, k, con in (("slow", ["spShutdown", "slowShutdownAbort"], 3, "JobPhase <= 3"),
                           ("slowNoS1", ["spShutdown", "slowShutdownAbort"], 3, "JobPhase <= 3 /\\ ~jobSP_f.shut.err"),
                           ("fast", ["spShutdown"], 1, "JobPhase <= 3")):
        PLAN.append(dict(COMMON, name=f"h9B_bfs_s{sites}_{tag}", faults=f, sites=sites,
                         launch=1, attempt=1, rarity=k, deadlock=False, symmetry=False,
                         extra_defs=f"UpToFirstResult == {con}", constraint="UpToFirstResult",
                         mode="bfs", timeout=1800, workers=16))
    PLAN.append(dict(COMMON, name=f"h9B_sim_s{sites}", sites=sites, launch=2, attempt=2,
                     faults=["spShutdown", "slowShutdownAbort", "deleteJob", "abort", "storeError", "rpcTimeout",
                             "deployError", "cjCrash", "spCrash"],
                     deadlock=True, throttle=20, fuse=True, rarity=4, symmetry=True,
                     mode="sim", depth=2500, timeout=1800, workers=8))
