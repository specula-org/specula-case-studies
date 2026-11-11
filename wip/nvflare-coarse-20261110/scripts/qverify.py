#!/usr/bin/env python3
"""Re-check counterexamples of the quiescence properties (Q1-Q4): take the violating
(last) state, rebuild the cell's MC with that state as Init, and print ENABLED QNext with
a 1-worker BFS of depth 1. QEN = TRUE means the reported quiescence was spurious.
qverify.py TAG [--jobs 8]  -> checks/sweep/TAG.qverify.jsonl"""
import json, re, subprocess, sys, os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import ce
tag = sys.argv[1]; jobs = int(sys.argv[sys.argv.index("--jobs") + 1]) if "--jobs" in sys.argv else 8
tri = [json.loads(l) for l in (ROOT / "checks/sweep" / f"{tag}.triage.jsonl").read_text().splitlines()]
todo = [t for t in tri if t["prop"].lstrip("F_").startswith("Q") or t["prop"].startswith("F_Q")]
def one(t):
    name = t["name"]; sim = (ROOT / "logs" / f"{name}_s.log").exists() and "is violated" in (ROOT / "logs" / f"{name}_s.log").read_text()
    log = (ROOT / "logs" / (f"{name}_s.log" if sim else f"{name}.log")).read_text()
    i = log.index("Error: The behavior up to this point is:") if "Error: The behavior up to this point is:" in log else log.index("violated by the initial state")
    blocks = re.split(r"\n(?=State \d+: )", log[i:])
    last = blocks[-1].split("\n", 1)[1] if len(blocks) > 1 else log[i:].split("\n", 1)[1]
    last = "\n".join(l for l in last.splitlines() if l.startswith("/\\") or l.startswith(" "))
    import runpy, mkmc
    plan = runpy.run_path(str(ROOT / "plans/calib2.py")); c = plan["CONFIGS"][t["config"]]
    row = [json.loads(l) for l in (ROOT / "checks/sweep" / f"{tag}.jsonl").read_text().splitlines() if json.loads(l)["name"] == name][0]
    pname = f"qv_{name}"
    mkmc.build(pname, grain=c.get("grain", {}), faults=row["faults"], sites=c["sites"], launch=c["launch"], attempt=c["attempt"],
               profile=c.get("profile", []), inv=["QVProbe"], prop=[], symmetry=False, extends=("Mix", "StdProps", "JobPhase"),
               rarity=row["rarity"], init_states=[last],
               extra_defs='QVProbe == PrintT(<<"QEN", ENABLED QNext, "AtBound", AtBoundAny>>) /\\ FALSE')
    env = dict(os.environ, TLC_WORKERS="1", TLC_HEAP="3g")
    o = subprocess.run([str(ROOT / "scripts/tlc.sh"), "tlc", str(ROOT / "checks/mixes"), f"MC_{pname}", f"MC_{pname}.cfg"],
                       capture_output=True, text=True, env=env, timeout=300).stdout
    m = re.search(r'"QEN",\s*(TRUE|FALSE),\s*"AtBound",\s*(TRUE|FALSE)', o)
    return dict(name=name, prop=t["prop"], label=t["label"], sim=sim, qen=m.group(1) if m else None,
                atbound=m.group(2) if m else None, err=None if m else o[-400:])
with ThreadPoolExecutor(jobs) as ex:
    res = list(ex.map(one, todo))
(ROOT / "checks/sweep" / f"{tag}.qverify.jsonl").write_text("".join(json.dumps(r) + "\n" for r in res))
from collections import Counter
print(len(res), Counter((r["sim"], r["qen"]) for r in res))
