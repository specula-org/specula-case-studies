#!/usr/bin/env python3
"""Counterexample triage by zooming in (DESIGN.md §4).

zoom.py NAME [--run] [--timeout S] [--workers N]
Reads logs/NAME.log (a violation) and checks/results/NAME.json, finds the
groups whose COARSE variants took steps in the counterexample, and builds the
next mix NAME_z with those groups switched to their finest available variant
(F > M > C). Same faults/sites/invariants. With --run executes it and reports
whether the violation survives refinement:
  survives      -> not an artifact of coarsening those groups
  disappears    -> artifact of the coarse variants involved (or needs deeper search)
Repeats until no coarse group with a finer variant remains in the CE.
"""
import argparse, json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import gen_mix, mkmc, run_mc, ce  # noqa: E402

ORDER = ["F", "M", "C"]


def ce_groups(name):
    text = (ROOT / "logs" / f"{name}.log").read_text()
    used = {}
    for act, _ in ce.states(text):
        m = re.search(r"Step_([A-Za-z]+)_([A-Z])", act)
        if m:
            used.setdefault(m.group(1), set()).add(m.group(2))
    return used


def parse_cfg(cfgtext):
    faults = re.search(r"MCFaults == \{(.*?)\}", cfgtext)
    return faults


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name"); ap.add_argument("--run", action="store_true")
    ap.add_argument("--timeout", type=int, default=600); ap.add_argument("--workers", type=int, default=24)
    ap.add_argument("--max-rounds", type=int, default=3)
    a = ap.parse_args()
    reg = gen_mix.load()
    name = a.name
    for rnd in range(a.max_rounds):
        res = json.loads((ROOT / "checks" / "results" / f"{name}.json").read_text())
        if res.get("result") != "violation":
            print(f"{name}: {res.get('result')} -- nothing to zoom"); return
        tla = (ROOT / "checks" / "mixes" / f"MC_{name}.tla").read_text()
        cfg = (ROOT / "checks" / "mixes" / f"MC_{name}.cfg").read_text()
        grain = dict(re.findall(r'(\w+) \|-> "(\w)"', re.search(r"MCGrain == \[(.*?)\]", tla).group(1)))
        faults = re.findall(r'"(\w+)"', re.search(r"MCFaults == \{(.*?)\}", tla).group(1))
        sites = len(re.search(r"Sites = \{(.*?)\}", cfg).group(1).split(","))
        launch = int(re.search(r"MaxLaunch = (\d+)", cfg).group(1))
        attempt = int(re.search(r"MaxAttempt = (\d+)", cfg).group(1))
        invs = re.findall(r"^INVARIANT (\w+)", cfg, flags=re.M)
        used = ce_groups(name)
        new = dict(grain); changed = []
        for g, vs in used.items():
            avail = list(reg["groups"][g]["variants"])
            finest = next((v for v in ORDER if v in avail), grain[g])
            if ORDER.index(finest) < ORDER.index(grain[g]) if grain[g] in ORDER else False:
                new[g] = finest; changed.append(f"{g}:{grain[g]}->{finest}")
        print(f"[{name}] violated {res.get('violated')}; CE groups {sorted(used)}; refine {changed or 'nothing'}")
        if not changed:
            print("fully refined w.r.t. available variants: candidate for source-level confirmation")
            return
        nxt = f"{a.name}_z{rnd+1}"
        mkmc.build(nxt, grain=new, faults=faults, sites=sites, launch=launch, attempt=attempt, inv=invs)
        if not a.run:
            print("built", nxt); return
        r = run_mc.run(nxt, a.timeout, a.workers, "bfs", (200, 1000), "16g")
        print(f"  {nxt}: {r.get('result')} {r.get('violated','')} distinct={r.get('distinct', r.get('distinct_at_stop'))}")
        if r.get("result") != "violation":
            print("  violation DISAPPEARS after refinement -> coarse artifact (or not reached within budget)")
            return
        if r.get("violated") != res.get("violated"):
            print("  a different property is violated after refinement; inspect both")
        name = nxt


if __name__ == "__main__":
    main()
