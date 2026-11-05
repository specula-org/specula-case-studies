# zoom-in of the hunt5 smoke GTerminalNoLiveSJ leads: JobSP (coarse in the CE) made fine
import runpy, os
H = runpy.run_path(os.path.join(os.path.dirname(__file__), "hunt5.py"))
NEW, grain, sim, GINV, PINV = H["NEW"], H["grain"], H["sim"], H["GINV"], H["PINV"]
PLAN = []
for fam in ["err", "cse"]:
    faults, fine, prof, net, smin = NEW[fam]
    PLAN.append(sim(f"h5zoom_{fam}_JobSPF", "Z", fam, faults, grain(fine + ["JobSP"], net), prof, 2, 2, 2, 20,
                    timeout=600, workers=8, inv=["GTerminalNoLiveSJ"]))
    PLAN.append(sim(f"h5zoom_{fam}_JobSPJobCPF", "Z", fam, faults, grain(fine + ["JobSP", "JobCP"], net), prof, 2, 2, 2,
                    20, timeout=600, workers=8, inv=["GTerminalNoLiveSJ"]))
