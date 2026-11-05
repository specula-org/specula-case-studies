#!/usr/bin/env python3
"""gen_ref.py with an explicit receipt name, so refinement receipts for several
fault profiles / site counts / Net variants of one group can coexist.
Same check: CRef!Init and [][CRef!Next \/ UNCHANGED <<AbsC, Proj_G>>]_allVars
(or the negative check BadStep with --negative).

fed_ref.py GROUP FINE COARSE --name NAME [--sites N] [--faults ...] [--grain G=V,...]
           [--launch N] [--attempt N] [--negative] [--constraint EXPR]
"""
import argparse, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import gen_mix, mkmc  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("group"); ap.add_argument("fine"); ap.add_argument("coarse")
    ap.add_argument("--name", required=True)
    ap.add_argument("--sites", type=int, default=1)
    ap.add_argument("--faults", default="")
    ap.add_argument("--grain", default="")
    ap.add_argument("--launch", type=int, default=1)
    ap.add_argument("--attempt", type=int, default=1, help="MaxAttempt = FedAvg rounds")
    ap.add_argument("--negative", action="store_true")
    ap.add_argument("--constraint")
    a = ap.parse_args()
    reg = gen_mix.load()
    gd = reg["groups"][a.group]
    cvars = gd["variants"][a.coarse]["vars"]
    cmod = gd["variants"][a.coarse]["module"]
    fin = f"{a.group}_{a.fine}"
    assert len(cvars) == 1
    grain = dict(x.split("=") for x in a.grain.split(",") if x)
    grain[a.group] = a.fine
    fvars = reg["groups"][a.group]["variants"][a.fine]["vars"]
    if a.negative:
        defs = [f"CBad == INSTANCE {cmod} WITH {cvars[0]} <- CHOOSE x \\in {{{fin}!AbsCInit}} : TRUE",
                f"BadStep == [][CBad!Next \\/ UNCHANGED <<{fin}!AbsCInit, Proj_{a.group}>>]_allVars"]
        props = ["BadStep"]
    else:
        defs = [f"CRef == INSTANCE {cmod} WITH {cvars[0]} <- {fin}!AbsC",
                "RefInit == CRef!Init",
                f"RefStep == [][CRef!Next \\/ UNCHANGED <<{fin}!AbsC, Proj_{a.group}>>]_allVars",
                f"RefEnv == [][UNCHANGED <<{', '.join(fvars)}, Proj_{a.group}>> => UNCHANGED {fin}!AbsC]_allVars"]
        props = ["RefInit", "RefStep", "RefEnv"]
    cons = None
    if a.constraint:
        defs.append(f"FedConstraint == {a.constraint}")
        cons = "FedConstraint"
    out, mod, g = mkmc.build(a.name, grain=grain, faults=[f for f in a.faults.split(",") if f],
                             sites=a.sites, launch=a.launch, attempt=a.attempt, inv=(), prop=props,
                             constraint=cons, extra_defs="\n".join(defs))
    print("wrote", out / f"{mod}.tla", g)


if __name__ == "__main__":
    main()
