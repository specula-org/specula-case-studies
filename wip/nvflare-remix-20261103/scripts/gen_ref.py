#!/usr/bin/env python3
"""Generate and optionally run the interaction-preservation (refinement) check
for one group: fine variant F must refine coarse variant C on Proj_G.

gen_ref.py GROUP FINE COARSE [--sites N] [--faults ...] [--grain G=V,...]
           [--run] [--timeout S] [--workers N] [--negative]
The fine module must define AbsC == <value of C's private variable(s)>; for a
coarse variant with several private vars, AbsC is a record keyed by var name.
--negative adds a deliberately wrong mapping check (must FAIL) to show the
check is not vacuous: C's private var mapped to its Init value.
"""
import argparse, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("group"); ap.add_argument("fine"); ap.add_argument("coarse")
    ap.add_argument("--sites", type=int, default=1)
    ap.add_argument("--faults", default="")
    ap.add_argument("--grain", default="")
    ap.add_argument("--launch", type=int, default=1)
    ap.add_argument("--attempt", type=int, default=1, help="MaxAttempt (= Rounds)")
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--negative", action="store_true")
    ap.add_argument("--constraint")
    ap.add_argument("--tag", default="", help="run-name suffix (parallel runs of one group)")
    ap.add_argument("--profile", default="", help="Profile switches (Consts.ProfileSwitches)")
    a = ap.parse_args()
    prof = [x for x in a.profile.split(",") if x]
    import gen_mix
    reg = gen_mix.load()
    gd = reg["groups"][a.group]
    cvars = gd["variants"][a.coarse]["vars"]
    cmod = gd["variants"][a.coarse]["module"]
    fin = f"{a.group}_{a.fine}"
    if len(cvars) == 1:
        subst = f"{cvars[0]} <- {fin}!AbsC"
        bad = f"{cvars[0]} <- {a.group}_{a.coarse}!InitValue"
    else:
        subst = ", ".join(f'{v} <- {fin}!AbsC["{v}"]' for v in cvars)
        bad = None
    name = f"ref_{a.group}_{a.fine}_{a.coarse}" + ("_neg" if a.negative else "") + ("_" + a.tag if a.tag else "")
    grain = dict(x.split("=") for x in a.grain.split(",") if x)
    grain[a.group] = a.fine
    fvars = reg["groups"][a.group]["variants"][a.fine]["vars"]
    defs = [f"CRef == INSTANCE {cmod} WITH {subst}",
            "RefInit == CRef!Init",
            f"RefStep == [][CRef!Next \\/ UNCHANGED <<{fin}!AbsC, Proj_{a.group}>>]_allVars",
            # AbsC must be stable under steps that change neither G's privates nor its port
            f"RefEnv == [][UNCHANGED <<{', '.join(fvars)}, Proj_{a.group}>> => UNCHANGED {fin}!AbsC]_allVars"]
    props = ["RefInit", "RefStep", "RefEnv"]
    if a.negative:
        # generic non-vacuity control: a "coarse" spec that allows only stuttering
        # on G's projection must be refuted, i.e. the check really observes G's
        # port-visible steps (works also when the coarse private is trivial).
        defs = [f"BadStep == [][UNCHANGED <<{fin}!AbsC, Proj_{a.group}>>]_allVars"]
        props = ["BadStep"]
    out, mod, g = mkmc.build(name, grain=grain, faults=[f for f in a.faults.split(",") if f],
                             sites=a.sites, launch=a.launch, attempt=a.attempt, inv=(), prop=props,
                             constraint=a.constraint, extra_defs="\n".join(defs), profile=prof)
    print("wrote", out / f"{mod}.tla", g)
    if a.run:
        import run_mc
        r = run_mc.run(name, a.timeout, a.workers, "bfs", (0, 0), "16g")
        r.pop("cfg", None)
        print({k: v for k, v in r.items()})
        if not a.negative:
            # receipt keyed by the full instance signature (faults are not monotone)
            sig = dict(sites=a.sites, faults=sorted(f for f in a.faults.split(",") if f),
                       net=g.get("Net", "R"), launch=a.launch, attempt=a.attempt, profile=sorted(prof),
                       env={k: v for k, v in g.items() if k != a.group})
            rec = dict(group=a.group, fine=a.fine, coarse=a.coarse, sig=sig, result=r.get("result"),
                       distinct=r.get("distinct"), violated=r.get("violated"), run=name,
                       exhaustive=r.get("result") == "pass_exhaustive")
            rd = ROOT / "checks" / "receipts"; rd.mkdir(parents=True, exist_ok=True)
            att = ("_a" + str(a.attempt)) if a.attempt > 1 else ""
            key = f"{a.group}_{a.fine}_{a.coarse}__s{a.sites}_n{sig['net']}_l{a.launch}{att}_f{'-'.join(sig['faults']) or 'none'}" + (f"_p{'-'.join(sig['profile'])}" if prof else "")
            (rd / f"{key}.json").write_text(json.dumps(rec, indent=1))
            print("receipt:", key, rec["result"])


if __name__ == "__main__":
    main()
