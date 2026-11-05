#!/usr/bin/env python3
"""Run campaigns over many mixes.

Mix selection strategies (--strategy):
  all        every combination of variants (product over groups)
  one-fine   all-coarse plus each single group at each non-coarse variant
  cover:T    greedy T-way covering array over (group -> variant): every
             combination of variants for every T groups appears in some mix
  list       mixes given in a JSON file (--mixes FILE: [{"name":..,"grain":{..}}])
Each mix is crossed with fault profiles (--faults "p1=a,b;p2=c") and site
counts (--sites 1,2). Runs execute in parallel (--parallel), each with its own
TLC worker count and timeout. Results: checks/sweeps/<tag>.jsonl and .md.

sweep.py TAG --strategy cover:2 --faults "none=;crash=cjCrash" --sites 1
         [--mode bfs|sim] [--timeout 120] [--workers 12] [--parallel 6]
         [--inv I1,I2] [--only-groups G1,G2] [--exclude-variants M]
"""
import argparse, itertools, json, random, sys, time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import gen_mix, mkmc, run_mc  # noqa: E402


GENERIC_INVS = ["GFinishedNoAbnormalExit", "GFinishedNoLiveChild", "GTerminalNoLiveSJ",
                "GFinishedAllOutcomes", "GFreeAtMostOnce", "GNoFreeWhileAlive",
                "GNoAllocAfterFree", "GNoChildWithoutAlloc", "GOneLiveLaunch"]
GENERIC_PROPS = ["GTerminalStable", "GStatusStable", "GOutcomeStable", "GExitStable"]


def variants(reg, only=None, exclude=()):
    out = {}
    for g, gd in reg["groups"].items():
        vs = [v for v in gd["variants"] if v not in exclude]
        if only and g not in only:
            vs = [vs[0]] if "C" not in vs else ["C"]
        out[g] = vs
    return out


def base_variant(vs):
    return "C" if "C" in vs else ("R" if "R" in vs else vs[0])


def strat_all(V):
    gs = list(V)
    for combo in itertools.product(*[V[g] for g in gs]):
        yield dict(zip(gs, combo))


def strat_one_fine(V):
    base = {g: base_variant(vs) for g, vs in V.items()}
    yield dict(base)
    for g, vs in V.items():
        for v in vs:
            if v != base[g]:
                m = dict(base); m[g] = v
                yield m


def strat_cover(V, t, seed=7):
    """Greedy t-way covering array (AETG-like)."""
    rnd = random.Random(seed)
    gs = [g for g in V if len(V[g]) > 1]
    fixed = {g: V[g][0] for g in V if len(V[g]) == 1}
    need = set()
    for sub in itertools.combinations(gs, min(t, len(gs))):
        for vals in itertools.product(*[V[g] for g in sub]):
            need.add(tuple(zip(sub, vals)))
    rows = []
    while need:
        best, best_cov = None, -1
        for _ in range(60):
            seed_tuple = rnd.choice(sorted(need))
            row = dict(seed_tuple)
            order = [g for g in gs if g not in row]
            rnd.shuffle(order)
            for g in order:
                scores = []
                for v in V[g]:
                    row[g] = v
                    cov = sum(1 for tup in need if all(row.get(a) == b for a, b in tup))
                    scores.append((cov, rnd.random(), v))
                row[g] = max(scores)[2]
            cov = sum(1 for tup in need if all(row.get(a) == b for a, b in tup))
            if cov > best_cov:
                best, best_cov = dict(row), cov
        need = {tup for tup in need if not all(best.get(a) == b for a, b in tup)}
        best.update(fixed)
        rows.append(best)
    return rows


def persite_groups():
    """per-site groups that can actually be split (no process-level actions)."""
    import os
    f = Path(os.environ.get("MIX_BUILD") or os.environ.get("MIX_SPEC") or (ROOT / "spec")) / "site_splittable.json"
    if f.exists():
        return set(json.loads(f.read_text()))
    return set(gen_mix.load().get("per_site_groups", []))


def expand(V, sites, ps):
    """factors: per-site groups become one factor per site, named G@sN."""
    out = {}
    for g, vs in V.items():
        if g in ps and sites > 1 and len(vs) > 1:
            for i in range(sites):
                out[f"{g}@s{i+1}"] = vs
        else:
            out[g] = vs
    return out


def fold(row, V):
    """back to mkmc grain: uniform string, or 'F@s1+s2' style for per-site."""
    g = {}
    for grp in V:
        ks = [k for k in row if k.startswith(grp + "@")]
        if not ks:
            g[grp] = row[grp]; continue
        vals = {k.split("@")[1]: row[k] for k in ks}
        if len(set(vals.values())) == 1:
            g[grp] = next(iter(vals.values()))
        else:
            fine = [s for s, v in vals.items() if v != base_variant(V[grp])]
            g[grp] = vals[fine[0]] + "@" + "+".join(fine)
    return g


def short(grain, V):
    out = ""
    for g in V:
        if len(V[g]) <= 1:
            continue
        v = grain[g]
        out += v[0] if "@" not in v else v.replace("@", "").replace("+", "")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tag")
    ap.add_argument("--strategy", default="one-fine")
    ap.add_argument("--mixes")
    ap.add_argument("--faults", default="none=")
    ap.add_argument("--sites", default="1")
    ap.add_argument("--launch", type=int, default=1)
    ap.add_argument("--attempt", type=int, default=1, help="MaxAttempt (= FedAvg rounds)")
    ap.add_argument("--mode", default="bfs")
    ap.add_argument("--depth", default="300,4000")
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--workers", type=int, default=12)
    ap.add_argument("--parallel", type=int, default=6)
    ap.add_argument("--heap", default="6g")
    ap.add_argument("--inv", default=",".join(mkmc.PORT_INVS))
    ap.add_argument("--only-groups")
    ap.add_argument("--exclude-variants", default="")
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--generic", action="store_true", help="hypothesis-free GenericProps + deadlock")
    ap.add_argument("--timers", default="",
                    help="always-present timers added to EVERY fault profile (a real system always has them; "
                         "without them the deadlock check reports timer-less hangs)")
    ap.add_argument("--skip-props", default="", help="generic properties to leave out (known findings)")
    ap.add_argument("--per-site", action="store_true", help="treat each (per-site group, site) as a factor")
    a = ap.parse_args()
    reg = gen_mix.load()
    V = variants(reg, set(a.only_groups.split(",")) if a.only_groups else None,
                 [x for x in a.exclude_variants.split(",") if x])
    if a.strategy == "all":
        mixes = list(strat_all(V))
    elif a.strategy == "one-fine":
        mixes = list(strat_one_fine(V))
    elif a.strategy.startswith("cover:"):
        if a.per_site:
            ns = max(int(x) for x in a.sites.split(","))
            F = expand(V, ns, persite_groups())
            mixes = [fold(r, V) for r in strat_cover(F, int(a.strategy.split(":")[1]))]
        else:
            mixes = strat_cover(V, int(a.strategy.split(":")[1]))
    elif a.strategy == "list":
        mixes = [m["grain"] for m in json.loads(Path(a.mixes).read_text())]
    else:
        sys.exit("unknown strategy")
    profiles = []
    timers = [t for t in a.timers.split(",") if t]
    for p in a.faults.split(";"):
        n, _, fs = p.partition("=")
        profiles.append((n, sorted(set([f for f in fs.split(",") if f] + timers))))
    skip = set(x for x in a.skip_props.split(",") if x)
    ginv = [i for i in GENERIC_INVS if i not in skip]
    gprop = [i for i in GENERIC_PROPS if i not in skip]
    sites = [int(s) for s in a.sites.split(",")]
    jobs = []
    for grain in mixes:
        for pn, fs in profiles:
            for s in sites:
                name = f"{a.tag}_{short(grain, V)}_{pn}_s{s}"
                jobs.append((name, grain, pn, fs, s))
    print(f"{len(mixes)} mixes x {len(profiles)} profiles x {len(sites)} sites = {len(jobs)} runs",
          file=sys.stderr)
    if a.dry:
        for j in jobs:
            print(j[0], j[1])
        return
    outdir = ROOT / "checks" / "sweeps"; outdir.mkdir(parents=True, exist_ok=True)
    out = outdir / f"{a.tag}.jsonl"
    depth = tuple(int(x) for x in a.depth.split(","))

    def one(j):
        name, grain, pn, fs, s = j
        if a.generic:
            mkmc.build(name, grain=grain, faults=fs, sites=s, launch=a.launch, attempt=a.attempt,
                       inv=ginv, prop=gprop,
                       extends=("Mix", "Props", "GenericProps"), deadlock=True)
        else:
            mkmc.build(name, grain=grain, faults=fs, sites=s, launch=a.launch,
                       inv=[i for i in a.inv.split(",") if i])
        r = run_mc.run(name, a.timeout, a.workers, a.mode, depth, a.heap)
        r.pop("cfg", None)
        r.update(grain=grain, profile=pn, faults=fs, sites=s)
        return r

    t0 = time.time()
    with ThreadPoolExecutor(a.parallel) as ex, out.open("a") as fh:
        futs = [ex.submit(one, j) for j in jobs]
        for f in as_completed(futs):
            r = f.result()
            fh.write(json.dumps(r) + "\n"); fh.flush()
            print(f"{r['name']}: {r.get('result')} {r.get('violated', '')} "
                  f"distinct={r.get('distinct', r.get('distinct_at_stop'))} {r['wall_seconds']}s",
                  file=sys.stderr)
    rows = [json.loads(l) for l in out.read_text().splitlines()]
    md = [f"# Sweep {a.tag}", "", f"strategy={a.strategy} profiles={a.faults} sites={a.sites} "
          f"mode={a.mode} timeout={a.timeout}s; wall {round(time.time()-t0)}s", "",
          "| run | grain | result | violated | distinct | depth | s |", "|---|---|---|---|---:|---:|---:|"]
    for r in sorted(rows, key=lambda r: r["name"]):
        gstr = ",".join(f"{g}={v}" for g, v in r["grain"].items()
                        if not (isinstance(v, str) and v in ("C", "R")))
        md.append(f"| {r['name']} | {gstr or 'all-coarse'} | {r.get('result')} | {r.get('violated','')} | "
                  f"{r.get('distinct', r.get('distinct_at_stop',''))} | {r.get('depth','')} | {r['wall_seconds']} |")
    (outdir / f"{a.tag}.md").write_text("\n".join(md) + "\n")


if __name__ == "__main__":
    main()
