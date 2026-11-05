#!/usr/bin/env python3
"""Run Phase-1 scenario campaigns defined in checks/scenarios.json.

Each scenario: {id, title, fine: [groups], grain: {G: V} (optional explicit),
faults: [...], sites: [1,2], launch, attempt, inv: [...], mode: bfs|sim,
timeout, depth: [D, num], expect: "violation"|"pass"|"witness"}.
Groups listed in `fine` get their finest available variant (F > M > C);
all others stay coarse (C) / reliable net (R) unless overridden in `grain`.

campaign.py [--only S10,S12] [--parallel 3] [--workers 24]
Results: checks/campaign/<id>_s<N>.json and checks/campaign/SUMMARY.md
"""
import argparse, json, sys, time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import gen_mix, mkmc, run_mc  # noqa: E402

ORDER = ["F", "M", "C"]


def grain_for(reg, sc):
    g = {}
    for grp, gd in reg["groups"].items():
        vs = list(gd["variants"])
        if grp in sc.get("fine", []):
            g[grp] = next((v for v in ORDER if v in vs), vs[0])
        else:
            g[grp] = "C" if "C" in vs else ("R" if "R" in vs else vs[0])
    g.update(sc.get("grain", {}))
    return g


def transfer(reg, grain, faults, sites, launch):
    """Which groups lack an exhaustive receipt (finest ⊑ chosen) for this instance."""
    rd = ROOT / "checks" / "receipts"
    missing = []
    for g, v in grain.items():
        vs = list(reg["groups"][g]["variants"])
        fin = next((x for x in ORDER if x in vs), v)
        if g == "Net" or v == fin:
            continue
        key = f"{g}_{fin}_{v}__s{sites}_n{grain.get('Net','R')}_l{launch}_f{'-'.join(sorted(faults)) or 'none'}"
        f = rd / f"{key}.json"
        if not (f.exists() and json.loads(f.read_text()).get("exhaustive")):
            missing.append(g)
    return missing


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    ap.add_argument("--parallel", type=int, default=3)
    ap.add_argument("--workers", type=int, default=24)
    ap.add_argument("--heap", default="16g")
    ap.add_argument("--file", default=str(ROOT / "checks" / "scenarios.json"))
    a = ap.parse_args()
    reg = gen_mix.load()
    scs = json.loads(Path(a.file).read_text())
    if a.only:
        keep = set(a.only.split(","))
        scs = [s for s in scs if s["id"] in keep]
    out = ROOT / "checks" / "campaign"; out.mkdir(parents=True, exist_ok=True)
    jobs = []
    for sc in scs:
        for s in sc.get("sites", [1]):
            jobs.append((sc, s))

    def one(job):
        sc, s = job
        name = f"cmp_{sc['id']}_s{s}"
        g = grain_for(reg, sc)
        mkmc.build(name, grain=g, faults=sc.get("faults", []), sites=s,
                   launch=sc.get("launch", 1), attempt=sc.get("attempt", 1),
                   inv=sc.get("inv", list(mkmc.PORT_INVS)), constraint=sc.get("constraint"),
                   prop=sc.get("prop", []), extends=("Mix", "Props", "AG"))
        d = tuple(sc.get("depth", [300, 20000]))
        r = run_mc.run(name, sc.get("timeout", 600), a.workers, sc.get("mode", "bfs"), d, a.heap)
        r.pop("cfg", None)
        miss = transfer(reg, g, sc.get("faults", []), s, sc.get("launch", 1))
        r.update(id=sc["id"], title=sc.get("title", ""), grain=g, faults=sc.get("faults", []),
                 sites=s, expect=sc.get("expect", ""), transfer_missing=miss,
                 transfers_to_all_fine=not miss)
        (out / f"{name}.json").write_text(json.dumps(r, indent=1))
        return r

    rows = []
    with ThreadPoolExecutor(a.parallel) as ex:
        for f in as_completed([ex.submit(one, j) for j in jobs]):
            r = f.result(); rows.append(r)
            print(f"{r['name']}: {r.get('result')} {r.get('violated','')} "
                  f"distinct={r.get('distinct', r.get('distinct_at_stop'))} {r['wall_seconds']}s", file=sys.stderr)
    # merge into summary (keep previous rows of scenarios not rerun)
    allr = {}
    for f in sorted(out.glob("cmp_*.json")):
        r = json.loads(f.read_text()); allr[r["name"]] = r
    md = ["# Scenario campaign summary", "",
          "transfer = a pass in this mix implies a pass in all-fine (every coarse group has an exhaustive receipt for this exact instance); otherwise the missing groups are listed.", "",
          "| run | scenario | fine groups | faults | result | violated | distinct | depth | wall s | transfer |",
          "|---|---|---|---|---|---|---:|---:|---:|---|"]
    for n in sorted(allr):
        r = allr[n]
        fine = ",".join(f"{g}={v}" for g, v in r["grain"].items() if v not in ("C", "R"))
        md.append(f"| {n} | {r['id']} {r.get('title','')[:50]} | {fine} | {','.join(r['faults'])} | {r.get('result')} | "
                  f"{r.get('violated','')} | {r.get('distinct', r.get('distinct_at_stop',''))} | {r.get('depth','')} | {r['wall_seconds']} | "
                  f"{'yes' if r.get('transfers_to_all_fine') else 'missing: ' + ','.join(r.get('transfer_missing', []))} |")
    (out / "SUMMARY.md").write_text("\n".join(md) + "\n")


if __name__ == "__main__":
    main()
