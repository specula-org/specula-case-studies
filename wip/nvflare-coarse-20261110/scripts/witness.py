#!/usr/bin/env python3
"""Run the directed witnesses of checks/witness/plan.py by simulation from the configuration's
checkpoint (or Init for phase 0). witness.py [--only K1,K2] [--timeout 120] [--workers 8]
Results: checks/witness/results.jsonl"""
import argparse, json, runpy, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc, run_mc, ckpt
ap = argparse.ArgumentParser(); ap.add_argument("--only", default=""); ap.add_argument("--timeout", type=int, default=120)
ap.add_argument("--workers", type=int, default=8); ap.add_argument("--plan", default="plans/calib2.py")
ap.add_argument("--mode", default="sim"); ap.add_argument("--phase", type=int, default=None)
ap.add_argument("--wplan", default="checks/witness/plan.py"); ap.add_argument("--ckprefix", default="wit"); ap.add_argument("--out", default="checks/witness/results.jsonl")
a = ap.parse_args()
cal = runpy.run_path(str(ROOT / a.plan)); W = runpy.run_path(str(ROOT / a.wplan))["W"]
w = json.loads((Path(__import__("os").environ.get("MIX_SPEC") or (ROOT / "spec")) / "rarity.json").read_text())["weights"]
out = ROOT / a.out
for key, d in W.items():
    if a.only and key not in a.only.split(","):
        continue
    c = cal["CONFIGS"][d["config"]]
    kw = dict(grain=c.get("grain", {}), faults=[], sites=c["sites"], launch=c["launch"], attempt=c["attempt"], profile=c.get("profile", []))
    if a.phase is not None:
        d = dict(d, phase=a.phase)
    init = ckpt.harvest(f"{a.ckprefix}_{d['config']}", kw, d["phase"], n=1, timeout=240, workers=4) if d["phase"] else None
    name = a.ckprefix + "_" + key.replace("-", "") + ("" if a.mode == "sim" else f"_bfs{d['phase']}")
    defs = []; inv = []; prop = []
    if "inv" in d:
        defs.append(f"W_Inv == {d['inv']}"); inv = ["W_Inv"]
    if "act" in d:
        defs.append(f"W_Act == {d['act']}"); prop = ["W_Act"]
    K = 2 * sum(w.get(f, 4) for f in d["faults"])
    mkmc.build(name, grain=c.get("grain", {}), faults=d["faults"], sites=c["sites"], launch=c["launch"], attempt=c["attempt"],
               profile=c.get("profile", []), inv=inv, prop=prop, symmetry=False, extends=("Mix", "StdProps", "JobPhase"),
               rarity=K, deadlock=False, init_states=init, extra_defs="\n".join(defs))
    r = run_mc.run(name, a.timeout, a.workers, a.mode, (400, 10 ** 9), "8g")
    r.pop("cfg", None); r.update(key=key, faults=d["faults"], phase=d["phase"], config=d["config"], mode=a.mode)
    with out.open("a") as fh:
        fh.write(json.dumps(r) + "\n")
    print(key, r.get("result"), r.get("violated"), r.get("traces"), r.get("wall_seconds"), flush=True)
