#!/usr/bin/env python3
"""Write the job groups' refinement models (fine F refines coarse C on Proj_G)
for the campaign instances: 1 site, all job faults, Net R and Net L (+netLoss),
MaxLaunch 2 for JobCP/RunCJ. Same definitions as scripts/gen_ref.py.
Names: jref_<Group>_f<launch>_<R|L>; negative: jref_<Group>_neg."""
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc, gen_mix  # noqa: E402
from job_mixes import JOB_FAULTS  # noqa: E402

reg = gen_mix.load()
for g, launch in [("RunCJ", 2), ("JobCP", 2), ("JobSP", 1)]:
    gd = reg["groups"][g]
    cv = gd["variants"]["C"]["vars"][0]
    cm = gd["variants"]["C"]["module"]
    fin = f"{g}_F"
    for net in ["R", "L"]:
        name = f"jref_{g}_f{launch}_{net}"
        faults = JOB_FAULTS + (["netLoss"] if net == "L" else [])
        defs = [f"CRef == INSTANCE {cm} WITH {cv} <- {fin}!AbsC", "RefInit == CRef!Init",
                f"RefStep == [][CRef!Next \\/ UNCHANGED <<{fin}!AbsC, Proj_{g}>>]_allVars"]
        mkmc.build(name, grain={g: "F", "Net": net}, faults=faults, sites=1, launch=launch,
                   inv=(), prop=["RefInit", "RefStep"], extra_defs="\n".join(defs))
        print(name)
    defs = [f"CBad == INSTANCE {cm} WITH {cv} <- CHOOSE x \\in {{{fin}!AbsCInit}} : TRUE",
            f"BadStep == [][CBad!Next \\/ UNCHANGED <<{fin}!AbsCInit, Proj_{g}>>]_allVars"]
    mkmc.build(f"jref_{g}_neg", grain={g: "F"}, faults=JOB_FAULTS, sites=1, launch=launch,
               inv=(), prop=["BadStep"], extra_defs="\n".join(defs))
    print(f"jref_{g}_neg")
