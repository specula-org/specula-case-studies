# v9 B-group: SP shutdown/restart (fault spShutdown, timing escape slowShutdownAbort)
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
H8 = runpy.run_path(str(ROOT / "plans" / "hunt8.py"))
base = [p for p in H8["PLAN"] if p.get("family") == "multi" and p["track"] == "S"][0]
# K variants exclude the reproduced S4 (pass in progress) and leave S1 to LShutdownStopsAllK
INV = base["inv"] + ["LShutdownStopsAllK"]
# TLC also checks invariants on states the constraint prunes, so the S1-free runs need it in the invariant
NOS1_DEF = "LShutdownStopsAllKNoS1 == jobSP_f.shut.err \\/ LShutdownStopsAllK"
NOS1_INV = base["inv"] + ["LShutdownStopsAllKNoS1"]
PROP = base["prop"] + ["GNoStartAfterEarlyTerminal", "GNoStartAfterDelete"]
# LNoSpawnAfterShutdown(K) left out: every spawn after a shutdown comes from a scheduling
# pass that began before ask_to_stop was set (S4) or from S1 (ask_to_stop never set)
GRAIN = dict(base["grain"])
COMMON = dict(track="B", family="shut", grain=GRAIN, profile=["multiJob"], inv=INV, prop=PROP,
              extends=base["extends"] + ["JobPhase"], known=True, heap="24g")
PLAN = []
for sites in (1, 2):
    for tag, f, k, con in (("slow", ["spShutdown", "slowShutdownAbort"], 3, "JobPhase <= 3"),
                           ("slowNoS1", ["spShutdown", "slowShutdownAbort"], 3, "JobPhase <= 3 /\\ ~jobSP_f.shut.err"),
                           ("fast", ["spShutdown"], 1, "JobPhase <= 3")):
        nos1 = tag.endswith("NoS1")
        PLAN.append(dict(COMMON, name=f"h9B_bfs_s{sites}_{tag}", faults=f, sites=sites,
                         launch=1, attempt=1, rarity=k, deadlock=False, symmetry=False,
                         inv=NOS1_INV if nos1 else INV,
                         extra_defs=f"UpToFirstResult == {con}" + ("\n" + NOS1_DEF if nos1 else ""),
                         constraint="UpToFirstResult", mode="bfs", timeout=1800, workers=16))
    for tag, extra in (("", {}), ("_noS1", dict(extra_defs="NoS1 == ~jobSP_f.shut.err\n" + NOS1_DEF,
                                                  constraint="NoS1", inv=NOS1_INV))):
        PLAN.append(dict(COMMON, name=f"h9B_sim_s{sites}{tag}", sites=sites, launch=2, attempt=2,
                         faults=["spShutdown", "slowShutdownAbort", "deleteJob", "abort", "storeError", "rpcTimeout",
                                 "deployError", "cjCrash", "spCrash"],
                         deadlock=True, throttle=20, fuse=True, rarity=4, symmetry=True,
                         mode="sim", depth=2500, timeout=1800, workers=8, **extra))
