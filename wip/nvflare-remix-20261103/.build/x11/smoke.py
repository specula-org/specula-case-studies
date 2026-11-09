"""v11 smoke: build a mix and run one witness / invariant check (sim or bfs)."""
import sys, json, concurrent.futures as cf
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc, run_mc

EXT = ["Mix", "Props", "GenericProps", "WitV11"]
OUT = ROOT / ".build" / "x11" / "results.jsonl"


def go(name, profile, faults, inv, sites=1, launch=1, attempt=2, mode="sim", depth=(400, 4000),
       timeout=240, grain=None, deadlock=False, workers=4, constraint=None, prop=(), tag=""):
    mkmc.build(name, grain=grain or {}, faults=faults, sites=sites, launch=launch, attempt=attempt,
               inv=list(inv), prop=list(prop), symmetry=False, deadlock=deadlock, profile=list(profile),
               constraint=constraint, extends=EXT)
    r = run_mc.run(name, timeout, workers, mode, depth, "8g")
    r.pop("cfg", None)
    keep = {k: v for k, v in r.items() if k in ("result", "violated", "distinct", "depth", "traces", "error", "secs", "wall_seconds")}
    rec = dict(name=name, tag=tag, profile=list(profile), faults=list(faults), inv=list(inv), mode=mode, **keep)
    with open(OUT, "a") as f:
        f.write(json.dumps(rec) + "\n")
    print(name, json.dumps(keep), flush=True)
    return rec


def batch(jobs, par=8):
    with cf.ThreadPoolExecutor(par) as ex:
        return list(ex.map(lambda j: go(**j), jobs))
