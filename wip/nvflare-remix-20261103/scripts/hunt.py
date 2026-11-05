#!/usr/bin/env python3
"""Bug-hunting campaign: a fixed list of heterogeneous TLC runs (throttled deep
simulation, rarity-bounded BFS, plain simulation controls, AG checks) executed
under a global TLC-worker budget. Plans are Python files defining PLAN, a list
of dicts accepted by mkmc.build plus run keys:

  name, grain, faults, sites, launch, attempt, profile, inv, prop, deadlock,
  rarity, throttle, constraint, extends,
  mode ("bfs" | "sim"), depth (sim depth), timeout (s), workers, heap

hunt.py TAG PLANFILE [--budget 80] [--dry]
Results: checks/sweeps/<TAG>.jsonl (one line per finished run, appended as they
finish) and <TAG>.md. Violations keep their full TLC log in logs/<name>.log.
"""
import argparse, json, runpy, sys, threading, time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc, run_mc  # noqa: E402

BUILD_KEYS = ("grain", "faults", "sites", "launch", "attempt", "inv", "prop", "constraint",
              "extends", "deadlock", "rarity", "throttle", "profile", "symmetry", "default", "known")


class Budget:
    def __init__(self, n):
        self.n, self.cv = n, threading.Condition()

    def take(self, k):
        with self.cv:
            while self.n < k:
                self.cv.wait()
            self.n -= k

    def give(self, k):
        with self.cv:
            self.n += k
            self.cv.notify_all()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tag"); ap.add_argument("plan")
    ap.add_argument("--budget", type=int, default=80, help="total TLC workers at any time")
    ap.add_argument("--bfs-slots", type=int, default=2,
                    help="concurrent BFS runs (their state queues live on disk)")
    ap.add_argument("--min-free-gb", type=int, default=60,
                    help="do not start a BFS run while the workspace disk has less free space")
    ap.add_argument("--dry", action="store_true")
    a = ap.parse_args()
    plan = runpy.run_path(a.plan)["PLAN"]
    names = [p["name"] for p in plan]
    assert len(names) == len(set(names)), "duplicate run names"
    tot = sum(p["timeout"] for p in plan)
    print(f"{len(plan)} runs, sum of timeouts {tot/3600:.1f} h, worker budget {a.budget}", file=sys.stderr)
    if a.dry:
        for p in plan:
            print(p["name"], p.get("mode"), p.get("timeout"), p.get("workers"))
        return
    out = ROOT / "checks" / "sweeps" / f"{a.tag}.jsonl"
    out.parent.mkdir(parents=True, exist_ok=True)
    done = {json.loads(l)["name"] for l in out.read_text().splitlines()} if out.exists() else set()
    bud = Budget(a.budget)
    bfs_sem = threading.Semaphore(a.bfs_slots)
    import shutil

    def disk_ok():
        return shutil.disk_usage(ROOT).free / 2**30 >= a.min_free_gb
    lock = threading.Lock()

    def one(p):
        kw = {k: p[k] for k in BUILD_KEYS if k in p}
        if "extends" in kw:
            kw["extends"] = tuple(kw["extends"])
        if not p.get("prebuilt"):   # prebuilt: checks/mixes/MC_<name>.{tla,cfg} exist
            with lock:          # build writes MixR.tla / mixes; serialize
                mkmc.build(p["name"], **kw)
        w = p.get("workers", 4)
        is_bfs = p.get("mode", "bfs") == "bfs"
        if is_bfs:
            bfs_sem.acquire()
            while not disk_ok():
                time.sleep(30)
        bud.take(w)
        try:
            depth = (p.get("depth", 400), 10 ** 9) if p.get("mode") == "sim" else (0, 0)
            r = run_mc.run(p["name"], p["timeout"], w, p.get("mode", "bfs"), depth, p.get("heap", "12g"))
        finally:
            bud.give(w)
            if is_bfs:
                bfs_sem.release()
        r["free_gb_after"] = round(shutil.disk_usage(ROOT).free / 2**30)
        r.pop("cfg", None)
        r.update({k: p[k] for k in ("grain", "faults", "sites", "launch", "attempt", "profile",
                                    "rarity", "throttle", "mode", "family", "track") if k in p})
        return r

    todo = [p for p in plan if p["name"] not in done]
    # long runs first so the tail of the campaign is short runs
    todo.sort(key=lambda p: -p["timeout"] * p.get("workers", 4))
    t0 = time.time()
    with ThreadPoolExecutor(max(1, a.budget // 2)) as ex, out.open("a") as fh:
        futs = [ex.submit(one, p) for p in todo]
        for f in as_completed(futs):
            try:
                r = f.result()
            except Exception as e:  # keep the campaign alive
                r = {"name": "?", "result": "driver_error", "error": repr(e)}
            fh.write(json.dumps(r) + "\n"); fh.flush()
            print(f"[{round(time.time()-t0)}s] {r.get('name')}: {r.get('result')} {r.get('violated', '')}",
                  file=sys.stderr, flush=True)
    rows = [json.loads(l) for l in out.read_text().splitlines()]
    md = [f"# Hunt {a.tag}", "", f"{len(rows)} runs; wall {round(time.time()-t0)} s", "",
          "| run | track | family | mode | result | violated | states/traces | s |",
          "|---|---|---|---|---|---|---:|---:|"]
    for r in sorted(rows, key=lambda r: r.get("name", "")):
        md.append(f"| {r.get('name')} | {r.get('track','')} | {r.get('family','')} | {r.get('mode','')} | "
                  f"{r.get('result')} | {r.get('violated','') or ''} | "
                  f"{r.get('distinct', r.get('distinct_at_stop', r.get('traces', '')))} | {r.get('wall_seconds','')} |")
    (out.parent / f"{a.tag}.md").write_text("\n".join(md) + "\n")


if __name__ == "__main__":
    main()
