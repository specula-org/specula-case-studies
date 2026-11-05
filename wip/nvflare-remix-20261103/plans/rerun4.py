# Re-runs after hunt4: runs that ended in "error" (two model errors fixed during
# the campaign: coarse CommSJ double receipt, JobSP re-send after a loss; plus
# old prebuilt modules lacking SiteGrain), on the fixed model.
import json, pathlib, runpy
here = pathlib.Path(__file__).resolve()
H = runpy.run_path(str(here.with_name("hunt4.py")))
by_name = {p["name"]: p for p in H["PLAN"]}
rows = [json.loads(l) for l in (here.parents[1] / "checks" / "sweeps" / "hunt4.jsonl").read_text().splitlines()]
bad = {r["name"] for r in rows if r.get("result") in ("error", "worker_exception", "driver_error")}
PLAN = []
for n in sorted(bad):
    p = by_name.get(n)
    if p is None or p.get("prebuilt"):
        continue
    q = dict(p); q["name"] = n + "_rr"; PLAN.append(q)
# the two old prebuilt H30-hunting modules, rebuilt (grain/faults/invariants as before)
G30 = {"JobSP": "C", "JobCP": "C", "RunCJ": "C", "TaskCJ": "F", "Trainer": "C", "PaySrc": "F",
       "PayRcv": "F", "CommSJ": "F", "WfSJ": "F", "Net": "R"}
for n, inv in (("cmp_F10s_s2", ["OutcomeReflectsWorkflow", "NoSJDeathAfterWorkflowDone"]),
               ("hz3_h30", ["NoSJDeathAfterWorkflowDone", "OutcomeReflectsWorkflow"] + H["PINV"] + H["GINV"])):
    PLAN.append(dict(name="h4X_" + n + "_rr", track="X", family="minClients", grain=G30, faults=["minClients"],
                     sites=2, launch=1, attempt=1, inv=inv, prop=[], extends=H["EXT"], deadlock=False,
                     mode="sim", depth=1500, timeout=600, workers=4, heap="10g"))
