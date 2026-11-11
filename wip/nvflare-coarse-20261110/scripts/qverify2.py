#!/usr/bin/env python3
"""Re-check Q-item counterexamples of a v4 sweep (STANDARD 10): for every triaged CE whose
item is a Q item, take its last state, copy the cell's MC with that state as the only
initial state, and print ENABLED QNext and AtBoundAny with a depth-1 BFS. QEN = TRUE
means the reported quiescence was spurious.
qverify2.py TRIAGE_NAME [--jobs 8]  -> checks/sweep/TRIAGE_NAME.qverify.jsonl"""
import json, re, subprocess, sys, os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
MIX = ROOT / "checks" / "mixes"


def last_state(log):
    i = log.index("Error: The behavior up to this point is:") if "Error: The behavior up to this point is:" in log \
        else log.index("violated by the initial state")
    blocks = re.split(r"\n(?=State \d+: )", log[i:])
    body = blocks[-1].split("\n", 1)[1] if len(blocks) > 1 else log[i:].split("\n", 1)[1]
    return "\n".join(l for l in body.splitlines() if l.startswith("/\\") or l.startswith(" "))


def one(x):
    name = x["name"]
    log = (ROOT / "logs" / (f"{name}_s.log" if x["sim"] else f"{name}.log")).read_text()
    st = last_state(log)
    mc = (MIX / f"MC_{name}.tla").read_text()
    cfg = (MIX / f"MC_{name}.cfg").read_text()
    q = f"qv2_{name}"
    mc = mc.replace(f"MODULE MC_{name}", f"MODULE MC_{q}")
    fl = qfilters(mc)
    mc = mc.replace("\n====", "\nQVInit ==\n" + "\n".join("    " + l for l in st.splitlines())
                    + '\nQVProbe == PrintT(<<"QEN", ENABLED QNext, "AtBound", AtBoundAny, "QI", <<Q1c, Q2c, Q3c, Q4c>>, '
                    + '"QF", <<' + ", ".join(fl) + '>> >>) /\\ FALSE\n====')
    cfg = re.sub(r"INIT \w+", "INIT QVInit", cfg)
    cfg = re.sub(r"NEXT \w+", "NEXT RNext", cfg)
    cfg = "\n".join(l for l in cfg.splitlines() if not l.startswith(("INVARIANT", "PROPERTY", "CONSTRAINT"))) + "\nINVARIANT QVProbe\n"
    if "CONSTANTS s1" not in mc and "s1 = s1" not in cfg:
        n = len(re.findall(r"s\d", re.search(r"Sites = \{([^}]*)\}", cfg).group(1)))
        names = ", ".join(f"s{k}" for k in range(1, n + 1))
        mc = mc.replace("EXTENDS", f"CONSTANTS {names}\nEXTENDS", 1) if False else mc.replace(
            "\nMCGrain", f"\nCONSTANTS {names}\nMCGrain", 1)
        cfg = cfg.replace("CONSTANTS", "CONSTANTS\n" + "\n".join(f"  s{k} = s{k}" for k in range(1, n + 1)), 1)
    (MIX / f"MC_{q}.tla").write_text(mc); (MIX / f"MC_{q}.cfg").write_text(cfg)
    env = dict(os.environ, TLC_WORKERS="1", TLC_HEAP="3g")
    try:
        o = subprocess.run([str(ROOT / "scripts/tlc.sh"), "tlc", str(MIX), f"MC_{q}", f"MC_{q}.cfg"],
                           capture_output=True, text=True, env=env, timeout=300).stdout
    except subprocess.TimeoutExpired:
        o = "timeout"
    m = re.search(r'"QEN",\s*(TRUE|FALSE),\s*"AtBound",\s*(TRUE|FALSE),\s*"QI",\s*<<([^>]*)>>,\s*"QF",\s*<<([^>]*)>>', o)
    items = None
    if m:
        qi = [v.strip() == "TRUE" for v in m.group(3).split(",")]
        qf = [v.strip() == "TRUE" for v in m.group(4).split(",")]
        # the items that fail and are not exempted by their filter
        items = [f"Q{k + 1}c" for k in range(4) if not qi[k] and not qf[k]]
        allq = [f"Q{k + 1}c" for k in range(4) if not qi[k]]
    return dict(name=name, item=x["item"], sim=x["sim"], qen=m.group(1) if m else None,
                atbound=m.group(2) if m else None, items=items, allq=allq if m else None,
                err=None if m else o[-300:])


def qfilters(mc):
    """the four filter arguments of I_Q in the cell's MC (FALSE when the cell has none)."""
    m = re.search(r"^I_Q == QAllF\((.*)\)\s*$", mc, re.M)
    if not m:
        return ["FALSE"] * 4
    args, depth, cur = [], 0, ""
    for ch in m.group(1):
        if ch == "," and depth == 0:
            args.append(cur.strip()); cur = ""; continue
        depth += ch in "([{"; depth -= ch in ")]}"
        cur += ch
    args.append(cur.strip())
    assert len(args) == 4, args
    return args


def main():
    tname = sys.argv[1]; jobs = int(sys.argv[sys.argv.index("--jobs") + 1]) if "--jobs" in sys.argv else 8
    xs = [json.loads(l) for l in (ROOT / "checks/sweep" / f"{tname}.triage.jsonl").read_text().splitlines()]
    todo = [x for x in xs if x["item"].startswith("Q")]
    with ThreadPoolExecutor(jobs) as ex:
        res = list(ex.map(one, todo))
    (ROOT / "checks/sweep" / f"{tname}.qverify.jsonl").write_text("".join(json.dumps(r) + "\n" for r in res))
    from collections import Counter
    print(len(res), Counter((r["sim"], r["qen"]) for r in res), Counter(",".join(r["items"] or ["?"]) for r in res))


if __name__ == "__main__":
    main()
