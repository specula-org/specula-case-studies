# Blind rediscovery of H08 (LEnvMatchesAllocation) with the round-5 thread-death
# findings filtered (known=True: KnownStuck; their invariants left out).
import runpy, os
H = runpy.run_path(os.path.join(os.path.dirname(__file__), "hunt5.py"))
NEW, grain, sim, GINV, PINV = H["NEW"], H["grain"], H["sim"], H["GINV"], H["PINV"]
PLAN = []
for fam, inst in [("jobP", (1, 2, 2)), ("jobP", (2, 2, 2)), ("allP", (2, 2, 2))]:
    faults, fine, prof, net, smin = NEW[fam]
    faults = [f for f in faults if f != "slowAdminStop"]   # ABORT-classified-COMPLETED lead (timing-implausible)
    s, l, a = inst
    for T in (20, 50):
        PLAN.append(sim(f"h5H08b_{fam}_s{s}l{l}a{a}_t{T}", "H", fam, faults, grain(fine, net, fam == "allP"), prof,
                        s, l, a, T, timeout=900, workers=8, inv=GINV + PINV + ["LEnvMatchesAllocation"], known=True))
