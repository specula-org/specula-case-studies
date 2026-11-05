#!/usr/bin/env python3
"""Write refinement receipts (same JSON shape and key as gen_ref.py) for runs
made with scripts/fed_ref.py + scripts/fed_run.py, into checks/fed/receipts/.
Reads the MC cfg / module to recover the instance signature and the result
JSON in checks/results/. A receipt transfers only if exhaustive is true.

fed_receipt.py RUN [RUN...]
"""
import json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    out = ROOT / "checks" / "fed" / "receipts"
    out.mkdir(parents=True, exist_ok=True)
    for run in sys.argv[1:]:
        tla = (ROOT / "checks" / "mixes" / f"MC_{run}.tla").read_text()
        cfg = (ROOT / "checks" / "mixes" / f"MC_{run}.cfg").read_text()
        res = json.loads((ROOT / "checks" / "results" / f"{run}.json").read_text())
        grain = dict(re.findall(r'(\w+) \|-> "(\w)"', re.search(r"MCGrain == \[(.*?)\]", tla).group(1)))
        faults = sorted(re.findall(r'"(\w+)"', re.search(r"MCFaults == \{(.*?)\}", tla).group(1)))
        sites = len(re.search(r"Sites = \{(.*?)\}", cfg).group(1).split(","))
        launch = int(re.search(r"MaxLaunch = (\d+)", cfg).group(1))
        cons = re.search(r"FedConstraint == (.*)", tla)
        log = (ROOT / "logs" / f"{run}.log").read_text() if (ROOT / "logs" / f"{run}.log").exists() else ""
        tr = re.findall(r"Progress: (\d+) states checked, (\d+) traces generated", log)
        m = re.search(r"CRef == INSTANCE (\w+)_(\w) WITH", tla)
        group, coarse = m.group(1), m.group(2)
        fine = grain[group]
        sig = dict(sites=sites, faults=faults, net=grain.get("Net", "R"), launch=launch, attempt=1,
                   env={k: v for k, v in grain.items() if k != group})
        rec = dict(group=group, fine=fine, coarse=coarse, sig=sig, result=res.get("result"),
                   mode=res.get("mode"), distinct=res.get("distinct") or res.get("distinct_at_stop"),
                   violated=res.get("violated"), run=run,
                   sim_states=int(tr[-1][0]) if tr else None, sim_traces=int(tr[-1][1]) if tr else None,
                   constraint=cons.group(1) if cons else None,
                   exhaustive=res.get("result") == "pass_exhaustive" and res.get("mode") == "bfs",
                   props=["RefInit", "RefStep"] + (["RefEnv"] if "RefEnv ==" in tla else []))
        key = f"{group}_{fine}_{coarse}__s{sites}_n{sig['net']}_l{launch}_f{'-'.join(faults) or 'none'}"
        if cons:
            key += "__constrained"
        if res.get("mode") == "sim":
            key += "__sim"
        (out / f"{key}.json").write_text(json.dumps(rec, indent=1))
        print(key, rec["result"], rec["distinct"], "exhaustive" if rec["exhaustive"] else "")


if __name__ == "__main__":
    main()
