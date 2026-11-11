#!/usr/bin/env python3
"""Compact counterexample view for triage: the action sequence (priced steps
marked with their cost) and the port fields that changed in the last steps.
tri.py NAME [--last N]"""
import json, re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import ce
name = sys.argv[1]
last = int(sys.argv[sys.argv.index("--last") + 1]) if "--last" in sys.argv else 4
costs = json.loads((ROOT / "spec" / "step_costs.json").read_text())
text = (ROOT / "logs" / f"{name}.log").read_text()
m = re.search(r"Invariant (\w+) is violated|Action property (\w+)|Temporal properties", text)
print("violation:", m.group(0) if m else "?")
st = ce.states(text)
OWN = {"pJobSP": "JobSP", "jobSP_c": "JobSP", "pJobCP": "JobCP", "jobCP_c": "JobCP", "pRunCJ": "RunCJ", "runCJ_c": "RunCJ",
       "pTaskCJ": "TaskCJ", "taskCJ_c": "TaskCJ", "pTrainer": "Trainer", "trainer_c": "Trainer", "trainer_x": "Trainer",
       "trainer_a": "Trainer", "pPaySrc": "PaySrc", "paySrc_c": "PaySrc", "pPayRcv": "PayRcv", "payRcv_c": "PayRcv",
       "pCommSJ": "CommSJ", "commSJ_c": "CommSJ", "pWfSJ": "WfSJ", "wfSJ_c": "WfSJ", "pReg": "Reg", "reg_c": "Reg",
       "pWorker": "Worker", "worker_c": "Worker", "pModel": "Model", "model_c": "Model", "pSwarm": "Swarm",
       "swarm_c": "Swarm", "net_l": "Net"}
seq = []
prev = int(st[0][1].get("rare", "0") or 0)
pv = st[0][1]
for act, vals in st[1:]:
    a = act.split("!")[-1].split("(")[0]
    a = re.sub(r"^R?Step_", "", a)
    if a in ("SNext", "RNext", "Next"):          # sliced schedule: name the group by the variables it changed
        gs = sorted({OWN[k] for k in vals if k in OWN and pv.get(k) != vals[k]})
        a = "+".join(gs) or "stutter"
        if "net" in vals and pv.get("net") != vals["net"] and not gs:
            a = "net"
    pv = vals
    rr = int(vals.get("rare", prev)); c = rr - prev; prev = rr   # the step's actual price
    seq.append(a + (f"[{c}]" if c else ""))
print(" -> ".join(seq))
for i in range(max(1, len(st) - last), len(st)):
    prev, cur = st[i - 1][1], st[i][1]
    ch = [k for k in cur if prev.get(k) != cur[k]]
    print(f"  {i+1} {seq[i-1] if i-1 < len(seq) else ''}:")
    for k in ch:
        a, b = ce.split_top(prev[k]), ce.split_top(cur[k])
        for kk in b:
            if a.get(kk) != b[kk]:
                print(f"      {k}.{kk}: {str(a.get(kk))[:150]} -> {b[kk][:150]}")
