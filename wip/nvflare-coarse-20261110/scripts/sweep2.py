#!/usr/bin/env python3
"""System sweep, gate-1 mechanism (PROMPT step 3; STANDARD 7, 10 v4).

sweep2.py TAG PLANFILE [--budget 64] [--bfs 90] [--sim 45] [--workers 2] [--heap 3g]
          [--only CFG,..] [--points P,..] [--kind single|pair|all] [--names-from FILE] [--dry]

Cells: single failure points (point + DEPS) and pairs (a non-operational fault x an
operational event, owners strictly adjacent, scripts/slice.py), each x lifecycle phase.

Per cell:
  * checkpoint of (config, phase): scripts/ckpt.py, fault-free, cost 0;
  * faults = the cell's faults; rare budget K (single 2w+deps+EXTRA, pair w1+w2+deps+EXTRA),
    priced with dedup (scripts/rarity.py);
  * slice: the groups that own the cell's faults plus their neighbours in the port
    read/write graph (both directions). The groups outside the slice still run (the job
    needs them), but their interleavings are not explored: whenever one of them can
    step, the first such group in registry order steps; the slice moves only when none
    can. Every explored path is a behavior of the full composition, and Q is the full
    composition's quiescence;
  * items: StdProps.StdItems (each its own invariant), QAll (Q items, one ENABLED QNext
    per state), S2 (action property); each filter exempts only the items it names;
  * bounded BFS (--bfs s); if it neither finished nor found a violation, simulation from
    the same checkpoint (--sim s).
Results: checks/sweep/TAG.jsonl and TAG.md.
"""
import argparse, json, runpy, sys, threading, time, shutil, re
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc, run_mc, ckpt, gen_mix  # noqa: E402
import slice as SL  # noqa: E402

OPS = {"spCrash", "cpCrash", "cjCrash", "sjCrash", "abort", "deleteJob", "spShutdown", "rpcTimeout", "outcomeTimeout",
       "taskTimeout", "submitTimeout", "resultWaitTimeout", "gatherTimeout", "txTimeout", "pullTimeout", "deadClient",
       "taskDeadline", "netLoss", "netLossJobSP", "netLossJobCP", "netLossRunCJ", "netLossTaskCJ", "netLossCommSJ",
       "netLossWfSJ", "netLossPaySrc", "netLossPayRcv", "netLossSwarm",
       # admin commands on the client registry (chunk 1): ops events like abort / shutdown
       "adminRemove", "adminDisable"}
_t = ((Path(__import__("os").environ.get("MIX_SPEC") or (ROOT / "spec"))) / "StdProps.tla").read_text()
ITEMS = re.findall(r'"(\w+)"', re.search(r"StdItems == <<(.*?)>>", _t, re.S).group(1))
QITEMS = ["Q1c", "Q2c", "Q3c", "Q4c"]


def weights():
    return json.loads(((Path(__import__("os").environ.get("MIX_SPEC") or (ROOT / "spec"))) / "rarity.json").read_text())["weights"]


def owners(f):
    info, ko = SL._G()
    o = SL.owners(info, f, None)
    if f == "netLoss":
        o.add("Net")
    return o


def adjacent_strict(f, e):
    info, ko = SL._G()
    ds = SL.deps(info, ko, strict=True)
    return any(a == b or a in ds[b] or b in ds[a] for a in owners(f) for b in owners(e))


def cells(plan, kind="all"):
    w = weights(); W = lambda f: w.get(f, w["_default"])
    extra = plan.get("BUDGET_EXTRA", 2)
    out = []
    for cname, c in plan["CONFIGS"].items():
        pts = [p for p in c["points"] if owners(p)]
        if kind in ("all", "single"):
            for f in pts:
                deps = [d for d in plan["DEPS"].get(f, []) if d != f]
                K = 2 * W(f) + sum(W(d) for d in deps) + extra
                for ph in c["phases"]:
                    out.append(dict(name=f"{plan['TAG_PREFIX']}_{cname}_{f}_p{ph}", config=cname, kind="single",
                                    point=f, faults=[f] + deps, phase=ph, rarity=K))
        if kind in ("all", "pair"):
            rare = [p for p in pts if p not in OPS]
            ops = [p for p in pts if p in OPS]
            for f in rare:
                for e in ops:
                    if not adjacent_strict(f, e):
                        continue
                    fs = list(dict.fromkeys([f, e] + plan["DEPS"].get(f, []) + plan["DEPS"].get(e, [])))
                    K = sum(W(x) for x in fs) + plan.get("PAIR_EXTRA", 0)
                    for ph in plan.get("PAIR_PHASES", c["phases"]):
                        if ph not in c["phases"]:
                            continue
                        out.append(dict(name=f"{plan['TAG_PREFIX']}_{cname}_{f}__{e}_p{ph}", config=cname,
                                        kind="pair", point=f"{f}__{e}", faults=fs, phase=ph, rarity=K))
    # a plan may keep a subset of its cells (e.g. a new chunk: only cells that involve its points)
    keep = plan.get("KEEP")
    return [c for c in out if keep(c)] if keep else out


def slice_next(faults):
    """SNext: whenever a group outside the slice can step, the first such group in registry
    order steps; the slice moves only when none can. Every path is a behavior of the full
    composition. (Needs the composition to have no unpriced step cycle; a cycle would let
    one group starve the rest.)"""
    own, sl = SL.slice_of(faults)
    groups = list(gen_mix.load()["groups"])
    outg = [g for g in groups if g not in sl]
    ing = [g for g in groups if g in sl]
    expr = "(" + " \\/ ".join(f"RNext_{g}" for g in ing) + ")" if ing else "RNext"
    for g in reversed(outg):
        expr = f"IF ENABLED RNext_{g} THEN RNext_{g} ELSE {expr}"
    return f"SNext == {expr}", ing, outg


def filter_defs(plan):
    """per item: the disjunction of the filters that name it."""
    flt = plan.get("FILTERS", {})
    defs, by = [], {}
    for name, f in flt.items():
        defs.append(f"Flt_{name} == {f['pred']}")
        for it in f["items"]:
            by.setdefault(it, []).append(f"Flt_{name}")
    return defs, by


def build_cell(plan, cell, ckpts):
    c = plan["CONFIGS"][cell["config"]]
    defs, by = filter_defs(plan)
    invs = []
    for it in ITEMS:
        if by.get(it):
            defs.append(f"I_{it} == {it} \\/ " + " \\/ ".join(by[it])); invs.append(f"I_{it}")
        else:
            invs.append(it)
    q = [("(" + " \\/ ".join(by[i]) + ")") if by.get(i) else "FALSE" for i in QITEMS]
    defs.append(f"I_Q == QAllF({', '.join(q)})"); invs.append("I_Q")
    defs.append("I_S2 == S2F(" + (("(" + " \\/ ".join(by["S2"]) + ")") if by.get("S2") else "FALSE") + ")")
    sn, ing, outg = slice_next(cell["faults"]) if plan.get("SLICE", True) else ("SNext == RNext", [], [])
    defs.append(sn)
    init = ckpts if cell["phase"] > 0 else None
    ph = sorted(c["phases"]); i = ph.index(cell["phase"])
    hi = (ph[i + 1] - 1) if i + 1 < len(ph) else 6
    window = list(range(cell["phase"], hi + 1)) if plan.get("WINDOW", True) else None
    mkmc.build(cell["name"], grain=c.get("grain", {}), faults=cell["faults"], sites=c["sites"], launch=c["launch"],
               attempt=c["attempt"], profile=c.get("profile", []), inv=invs, prop=["I_S2"], symmetry=False,
               extends=("Mix", "StdProps", "JobPhase"), rarity=cell["rarity"], deadlock=False,
               init_states=init, extra_defs="\n".join(defs), next_name="SNext", fault_phases=window)
    return ing, outg


def _depth(name):
    p = ROOT / "logs" / f"{name}.log"
    t = p.read_text() if p.exists() else ""
    m = re.findall(r"Progress\((\d+)\)", t) or re.findall(r"depth of the complete state graph search is (\d+)", t)
    return int(m[-1]) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tag"); ap.add_argument("plan")
    ap.add_argument("--budget", type=int, default=64)
    ap.add_argument("--bfs", type=int, default=90)
    ap.add_argument("--sim", type=int, default=45)
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--heap", default="3g")
    ap.add_argument("--only", default="")
    ap.add_argument("--points", default="")
    ap.add_argument("--kind", default="all")
    ap.add_argument("--names-from", default="")
    ap.add_argument("--dry", action="store_true")
    a = ap.parse_args()
    plan = runpy.run_path(a.plan)
    plan.setdefault("TAG_PREFIX", a.tag)
    todo = cells(plan, a.kind)
    if a.only:
        todo = [c for c in todo if c["config"] in a.only.split(",")]
    if a.points:
        todo = [c for c in todo if c["point"] in a.points.split(",")]
    if a.names_from:
        keep = {l.strip() for l in Path(a.names_from).read_text().splitlines() if l.strip()}
        todo = [c for c in todo if c["name"].split("_", 1)[1] in keep]
    out = ROOT / "checks" / "sweep" / f"{a.tag}.jsonl"
    out.parent.mkdir(parents=True, exist_ok=True)
    done = {json.loads(l)["name"] for l in out.read_text().splitlines()} if out.exists() else set()
    todo = [c for c in todo if c["name"] not in done]
    par = max(1, a.budget // a.workers)
    print(f"{len(todo)} cells ({len(done)} done); max {len(todo) * (a.bfs + a.sim) / par / 3600:.1f} h", file=sys.stderr)
    if a.dry:
        for c in todo[:10]:
            print(c, slice_next(c["faults"])[2])
        return
    import rarity as R
    R.write_mixr(); R._written = True
    need = sorted({(c["config"], c["phase"]) for c in todo if c["phase"] > 0})
    ck, hlock = {}, threading.Lock()

    def harvest_one(cp):
        cname, ph = cp; c = plan["CONFIGS"][cname]
        kw = dict(grain=c.get("grain", {}), faults=[], sites=c["sites"], launch=c["launch"], attempt=c["attempt"],
                  profile=c.get("profile", []))
        got = ckpt.harvest(f"{plan['TAG_PREFIX']}_{cname}", kw, ph, n=1, timeout=240, workers=2)
        with hlock:
            ck[(cname, ph)] = got
    with ThreadPoolExecutor(max(1, a.budget // 2)) as hx:
        list(hx.map(harvest_one, need))
    print("checkpoints:", sum(1 for v in ck.values() if v), "of", len(need), file=sys.stderr, flush=True)
    lock, sem = threading.Lock(), threading.Semaphore(par)

    def one(cell):
        if cell["phase"] > 0 and not ck.get((cell["config"], cell["phase"])):
            return dict(cell, result="no_checkpoint")
        with lock:
            ing, outg = build_cell(plan, cell, ck.get((cell["config"], cell["phase"])))
        with sem:
            r = run_mc.run(cell["name"], a.bfs, a.workers, "bfs", (0, 0), a.heap)
        r.pop("cfg", None)
        r["depth_reached"] = _depth(cell["name"])
        if a.sim and r.get("result") == "budget_stopped":
            mix = ROOT / "checks" / "mixes"
            for ext in ("tla", "cfg"):
                src = (mix / f"MC_{cell['name']}.{ext}").read_text()
                (mix / f"MC_{cell['name']}_s.{ext}").write_text(src.replace(f"MC_{cell['name']}", f"MC_{cell['name']}_s"))
            with sem:
                rs = run_mc.run(cell["name"] + "_s", a.sim, a.workers, "sim", (300, 10 ** 9), a.heap)
            r.update(sim_result=rs.get("result"), sim_violated=rs.get("violated"), sim_wall=rs.get("wall_seconds"))
            if rs.get("result") in ("violation", "violation_evalerror"):
                r.update(result="violation_sim", violated=rs.get("violated"))
        r.update({k: cell[k] for k in ("config", "kind", "point", "faults", "phase", "rarity")})
        r.update(slice_in=ing, slice_out=outg)
        r["free_gb_after"] = round(shutil.disk_usage(ROOT).free / 2**30)
        return r

    t0 = time.time()
    with ThreadPoolExecutor(par) as ex, out.open("a") as fh:
        futs = [ex.submit(one, c) for c in todo]
        for f in as_completed(futs):
            try:
                r = f.result()
            except Exception as e:
                r = {"name": "?", "result": "driver_error", "error": repr(e)}
            fh.write(json.dumps(r) + "\n"); fh.flush()
            print(f"[{round(time.time() - t0)}s] {r.get('name')}: {r.get('result')} {r.get('violated', '') or ''}",
                  file=sys.stderr, flush=True)
    summarize(a.tag)


def summarize(tag):
    out = ROOT / "checks" / "sweep" / f"{tag}.jsonl"
    rows = [json.loads(l) for l in out.read_text().splitlines()]
    from collections import Counter
    c = Counter(r.get("result") for r in rows)
    md = [f"# Sweep {tag}", "", f"{len(rows)} cells: {dict(c)}", "",
          "| config | point | phase | result | violated | distinct | depth | s |", "|---|---|---:|---|---|---:|---:|---:|"]
    for r in sorted(rows, key=lambda r: (r.get("config", ""), r.get("point", ""), r.get("phase", 0))):
        md.append(f"| {r.get('config')} | {r.get('point')} | {r.get('phase')} | {r.get('result')} | {r.get('violated', '') or ''} | "
                  f"{r.get('distinct', r.get('distinct_at_stop', ''))} | {r.get('depth_reached', '')} | {r.get('wall_seconds', '')} |")
    (out.parent / f"{tag}.md").write_text("\n".join(md) + "\n")


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--summarize":
        summarize(sys.argv[2])
    else:
        main()
