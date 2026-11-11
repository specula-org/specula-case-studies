#!/usr/bin/env python3
"""System sweep (PROMPT step 5, STANDARD 7): one bounded BFS per
(deployment configuration x failure point x lifecycle phase) cell.

sweep_grid.py TAG PLANFILE [--budget 64] [--timeout 300] [--workers 4] [--only CFG,...] [--dry]

PLANFILE defines CONFIGS (name -> dict(profile, grain, sites, launch, attempt,
points, phases)), DEPS (fault -> faults it needs), FILTERS (optional: name ->
TLA+ predicate over the state; a state matching a filter is not reported, used
only for triage of already attributed root causes).

Each cell: checkpoint states of the configuration at that phase (scripts/ckpt.py,
harvested once per configuration and phase with no faults, so the prefix is a
cost-0 behavior of every cell's spec); faults = {point} + DEPS[point]; rare
budget = 2 * w(point) + sum w(deps); invariants = StdProps.StdInvariants (each
OR'ed with the filters); action property S2TerminalFinal; BFS for --timeout s.
Results: checks/sweep/TAG.jsonl (one line per cell) and TAG.md (coverage table).
"""
import argparse, json, runpy, sys, threading, time, shutil
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc, run_mc, ckpt  # noqa: E402

INVS = ["Q1Terminal", "Q2StatusAgrees", "Q3Released", "Q4NoOrphan", "S1ThreadsAlive", "S3Resources",
        "S4NoLostResult", "S4Completed", "S5StatusMeaning", "S6AckMeansDone",
        "S7StopHasSource", "S8LossNotified", "S4OutputsDelivered"]


def weights():
    return json.loads((ROOT / "spec" / "rarity.json").read_text())["weights"]


def cells(plan, only=None):
    w = weights()
    out = []
    for cname, c in plan["CONFIGS"].items():
        if only and cname not in only:
            continue
        for f in c["points"]:
            deps = [d for d in plan["DEPS"].get(f, []) if d != f]
            faults = [f] + deps
            K = 2 * w.get(f, w["_default"]) + sum(w.get(d, w["_default"]) for d in deps) + plan.get("BUDGET_EXTRA", 0)
            for ph in c["phases"]:
                out.append(dict(name=f"{plan['TAG_PREFIX']}_{cname}_{f}_p{ph}", config=cname, point=f, faults=faults,
                                phase=ph, rarity=K))
    return out


def build_cell(plan, cell, ckpts):
    c = plan["CONFIGS"][cell["config"]]
    flt = plan.get("FILTERS", {})
    defs = []
    if flt:
        defs.append("SweepFilter == " + " \\/ ".join(f"({v})" for v in flt.values()))
        invs = []
        for i in INVS:
            defs.append(f"F_{i} == {i} \\/ SweepFilter")
            invs.append(f"F_{i}")
        defs.append("F_S2 == [][~SweepFilter' => (Terminal => pJobSP'.status = pJobSP.status)]_portVars")
        prop = ["F_S2"]
    else:
        invs, prop = INVS, ["S2TerminalFinal"]
    init = ckpts if cell["phase"] > 0 else None
    mkmc.build(cell["name"], grain=c.get("grain", {}), faults=cell["faults"], sites=c["sites"], launch=c["launch"],
               attempt=c["attempt"], profile=c.get("profile", []), inv=invs, prop=prop, symmetry=False,
               extends=("Mix", "StdProps", "JobPhase"), rarity=cell["rarity"], deadlock=False,
               init_states=init, extra_defs="\n".join(defs))


def _depth(name):
    import re
    t = (ROOT / "logs" / f"{name}.log").read_text() if (ROOT / "logs" / f"{name}.log").exists() else ""
    m = re.findall(r"Progress\((\d+)\)", t) or re.findall(r"depth of the complete state graph search is (\d+)", t)
    return int(m[-1]) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tag"); ap.add_argument("plan")
    ap.add_argument("--budget", type=int, default=64)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--heap", default="6g")
    ap.add_argument("--only", default="")
    ap.add_argument("--points", default="", help="only these failure points")
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--sim", type=int, default=0, help="after a non-exhaustive clean BFS, simulate this many seconds")
    a = ap.parse_args()
    plan = runpy.run_path(a.plan)
    plan.setdefault("TAG_PREFIX", a.tag)
    only = set(x for x in a.only.split(",") if x)
    todo = cells(plan, only)
    if a.points:
        todo = [c for c in todo if c["point"] in a.points.split(",")]
    out = ROOT / "checks" / "sweep" / f"{a.tag}.jsonl"
    out.parent.mkdir(parents=True, exist_ok=True)
    done = {json.loads(l)["name"] for l in out.read_text().splitlines()} if out.exists() else set()
    todo = [c for c in todo if c["name"] not in done]
    print(f"{len(todo)} cells to run ({len(done)} done), est {len(todo) * a.timeout * a.workers / a.budget / 3600:.1f} h max",
          file=sys.stderr)
    if a.dry:
        for c in todo[:20]:
            print(c)
        return
    # checkpoints per (config, phase), harvested with no faults (cost-0 prefixes)
    ck = {}
    import rarity as R
    R.write_mixr(); R._written = True        # once, before any parallel build reads MixR.tla
    need = sorted({(c["config"], c["phase"]) for c in todo if c["phase"] > 0})
    hlock = threading.Lock()
    def harvest_one(cp):
        cname, ph = cp; c = plan["CONFIGS"][cname]
        kw = dict(grain=c.get("grain", {}), faults=[], sites=c["sites"], launch=c["launch"], attempt=c["attempt"],
                  profile=c.get("profile", []))
        got = ckpt.harvest(f"{plan['TAG_PREFIX']}_{cname}", kw, ph, n=1, timeout=240, workers=4)
        with hlock:
            ck[(cname, ph)] = got
            print(f"checkpoint {cname} p{ph}: {len(got)}", file=sys.stderr, flush=True)
    with ThreadPoolExecutor(max(1, a.budget // 8)) as hx:
        list(hx.map(harvest_one, need))
    lock = threading.Lock()
    sem = threading.Semaphore(max(1, a.budget // a.workers))

    def one(cell):
        if cell["phase"] > 0 and not ck.get((cell["config"], cell["phase"])):
            return dict(cell, result="no_checkpoint")
        with lock:
            build_cell(plan, cell, ck.get((cell["config"], cell["phase"])))
        with sem:
            r = run_mc.run(cell["name"], a.timeout, a.workers, "bfs", (0, 0), a.heap)
        r.pop("cfg", None)
        r["depth_reached"] = _depth(cell["name"])
        if a.sim and r.get("result") not in ("violation", "violation_evalerror", "pass_exhaustive"):
            # deep sampling from the same checkpoints and the same single failure point
            mix = ROOT / "checks" / "mixes"
            for ext in ("tla", "cfg"):
                src = (mix / f"MC_{cell['name']}.{ext}").read_text()
                (mix / f"MC_{cell['name']}_s.{ext}").write_text(src.replace(f"MC_{cell['name']}", f"MC_{cell['name']}_s"))
            with sem:
                rs = run_mc.run(cell["name"] + "_s", a.sim, a.workers, "sim", (400, 10 ** 9), a.heap)
            r.update(sim_result=rs.get("result"), sim_violated=rs.get("violated"), sim_traces=rs.get("traces"),
                     sim_wall=rs.get("wall_seconds"))
            if rs.get("result") in ("violation", "violation_evalerror"):
                r.update(result="violation_sim", violated=rs.get("violated"))
        r.update({k: cell[k] for k in ("config", "point", "faults", "phase", "rarity")})
        r["free_gb_after"] = round(shutil.disk_usage(ROOT).free / 2**30)
        return r

    t0 = time.time()
    with ThreadPoolExecutor(max(1, a.budget // a.workers)) as ex, out.open("a") as fh:
        futs = [ex.submit(one, c) for c in todo]
        for f in as_completed(futs):
            try:
                r = f.result()
            except Exception as e:
                r = {"name": "?", "result": "driver_error", "error": repr(e)}
            fh.write(json.dumps(r) + "\n"); fh.flush()
            print(f"[{round(time.time() - t0)}s] {r.get('name')}: {r.get('result')} {r.get('violated', '')}",
                  file=sys.stderr, flush=True)
    summarize(a.tag)


def summarize(tag):
    out = ROOT / "checks" / "sweep" / f"{tag}.jsonl"
    rows = [json.loads(l) for l in out.read_text().splitlines()]
    md = [f"# Sweep {tag}", "", f"{len(rows)} cells", "",
          "| config | point | phase | result | violated | distinct | depth | s |", "|---|---|---:|---|---|---:|---:|---:|"]
    for r in sorted(rows, key=lambda r: (r.get("config", ""), r.get("point", ""), r.get("phase", 0))):
        md.append(f"| {r.get('config')} | {r.get('point')} | {r.get('phase')} | {r.get('result')} | {r.get('violated', '') or ''} | "
                  f"{r.get('distinct', r.get('distinct_at_stop', ''))} | {r.get('depth', '')} | {r.get('wall_seconds', '')} |")
    (out.parent / f"{tag}.md").write_text("\n".join(md) + "\n")


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--summarize":
        summarize(sys.argv[2])
    else:
        main()
