# Zoom-in of the lead "RECEIVED receipt for a result the workflow did not accept"
# (seen with coarse CommSJ after a workflow error): same family, CommSJ fine.
import runpy, pathlib
H = runpy.run_path(str(pathlib.Path(__file__).with_name("hunt4.py")))
PLAN = []
for fam in ("task", "restart"):
    g = H["grain"](fam); g["CommSJ"] = "F"; g["WfSJ"] = "F"
    for T in (20, 200):
        p = H["sim"](f"zr_{fam}_cF_s2l1a2_t{T}", fam, g, 2, 1, 2, T, timeout=900, workers=6, track="Z")
        p["inv"] = p["inv"] + ["ReceivedMeansAccepted", "RReceivedReceiptMeansFinished"]
        PLAN.append(p)
