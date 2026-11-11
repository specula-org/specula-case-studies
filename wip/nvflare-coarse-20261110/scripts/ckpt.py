#!/usr/bin/env python3
"""Harvest checkpoint states for mid-job BFS (v7).

A checkpoint is the first state of a trace at which JobPhase reaches a given
level. It is found by simulation of the same mix, faults and profile as the BFS
that will start from it, with rare-event budget 0, so only free steps are taken
and the prefix is a behavior of that BFS's spec at cost 0. The BFS starts from
the checkpoint with `rare = 0` and explores up to its own budget K from there.

    ckpt.py KEY --grain JobSP=F,... --faults f1,f2 --sites 1 --launch 1 --attempt 2
            [--profile p1,p2] --phase 3 [--n 2]

Writes checks/ckpt/KEY/p<phase>_<i>.tla (the state predicate) and
p<phase>_<i>.trace (the full prefix, for reconstructing counterexamples).
Library use: harvest(key, kw, phase, n) -> list of state predicates.
"""
import argparse, os, re, signal, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CK = ROOT / "checks" / "ckpt"
sys.path.insert(0, str(ROOT / "scripts"))


def last_state(out):
    """The last state block of a TLC error trace, as a TLA+ conjunction."""
    lines = out.splitlines()
    heads = [i for i, l in enumerate(lines) if re.match(r"^State \d+: ", l)]
    if not heads:
        return None, None
    i = heads[-1] + 1
    blk = []
    while i < len(lines) and lines[i].strip() != "":
        blk.append(lines[i]); i += 1
    start = lines.index("Error: The behavior up to this point is:") if \
        "Error: The behavior up to this point is:" in lines else heads[0]
    return "\n".join(blk), "\n".join(lines[start:i])


def harvest(key, kw, phase, n=2, seeds=range(1, 13), timeout=180, workers=1, depth=1500):
    import mkmc
    out = CK / key
    out.mkdir(parents=True, exist_ok=True)
    have = {f.read_text() for f in sorted(out.glob(f"p{phase}_*.tla"))}
    if len(have) >= n:
        return sorted(have)[:n]
    name = f"ck_{key}_p{phase}"
    # Free steps that only drive a fault mechanism (rarity.json "actions" priced 0,
    # e.g. the CommSJ 30 s clock tick) are left out of the prefix: taken early they
    # lead to states whose only way on is a priced step (a forced task timeout), so
    # a budget-0 walk gets stuck. Pruning keeps the prefix a behavior of the spec.
    import json
    free = [a for a, w in json.loads(((Path(__import__("os").environ.get("MIX_SPEC") or (ROOT / "spec"))) / "rarity.json").read_text())["actions"].items() if w == 0]
    actcon = " /\\ ".join(f"~RStep_{a.replace('.', '_')}" for a in free) or None
    mkmc.build(name, grain=kw["grain"], faults=kw["faults"], sites=kw["sites"], launch=kw["launch"],
               attempt=kw["attempt"], profile=kw.get("profile", ()), inv=["CkNotPhase"], prop=[],
               symmetry=False, extends=("Mix", "JobPhase"), rarity=0, deadlock=False,
               extra_defs=f"CkNotPhase == ~(JobPhase >= {int(phase)} /\\ JobPhase < 6)", action_constraint=actcon)
    mix = ROOT / "checks" / "mixes"
    env = dict(os.environ, TLC_WORKERS=str(workers), TLC_HEAP="6g")
    for seed in seeds:
        if len(have) >= n:
            break
        p = subprocess.Popen([str(ROOT / "scripts" / "tlc.sh"), "tlc", str(mix), f"MC_{name}", f"MC_{name}.cfg",
                              "-simulate", "num=100000", "-depth", str(depth), "-seed", str(seed)],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
                             start_new_session=True)
        try:
            o, _ = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGTERM); o, _ = p.communicate(timeout=60)
        m = re.findall(r"(\d+) traces generated \(trace length: mean=(\d+)", o)
        with (out / "attempts.log").open("a") as fh:
            fh.write(f"p{phase} seed {seed}: {'hit' if 'Invariant CkNotPhase is violated' in o else 'miss'}"
                     f" traces/mean {m[-1] if m else '?'}\n")
        if "Invariant CkNotPhase is violated" not in o:
            continue
        st, trace = last_state(o)
        if not st or st in have:
            continue
        i = len(have)
        (out / f"p{phase}_{i}.tla").write_text(st)
        (out / f"p{phase}_{i}.trace").write_text(trace)
        have.add(st)
    return sorted(have)[:n]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("key"); ap.add_argument("--grain", required=True); ap.add_argument("--faults", default="")
    ap.add_argument("--sites", type=int, default=1); ap.add_argument("--launch", type=int, default=1)
    ap.add_argument("--attempt", type=int, default=1); ap.add_argument("--profile", default="")
    ap.add_argument("--phase", type=int, required=True); ap.add_argument("--n", type=int, default=2)
    a = ap.parse_args()
    kw = dict(grain=dict(x.split("=") for x in a.grain.split(",")), faults=[f for f in a.faults.split(",") if f],
              sites=a.sites, launch=a.launch, attempt=a.attempt, profile=[x for x in a.profile.split(",") if x])
    got = harvest(a.key, kw, a.phase, a.n)
    print(f"{a.key} phase {a.phase}: {len(got)} checkpoint(s)")


if __name__ == "__main__":
    main()
