#!/usr/bin/env python3
"""Create an MC module + cfg for one mix.

mkmc.py NAME [--grain G=V,...] [--default C] [--faults f1,f2] [--sites N]
        [--launch N] [--attempt N] [--inv I1,I2] [--prop P1] [--symmetry]
        [--constraint EXPR] [--outdir DIR] [--extends M1,M2]
        [--rarity K] [--deadlock] [--throttle T]
Unlisted groups use --default when that variant exists, else their first variant.
"""
import argparse, json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PORT_INVS = ("ClaimNeedsMaterialized","MaterializedIsRegistered","AggregateIsAccepted","AcceptedWasClaimed","ReceivedReceiptMeansFinished","ReceivedMeansAccepted","NoFreeWhileChildAlive","AtMostOneFree","FinishedJobSaved","FinishedJobAllOk","NoReleaseBeforeMaterialize")


def build(name, grain=None, default="C", faults=(), sites=2, launch=1, attempt=1,
          inv=PORT_INVS, prop=(), symmetry=True, constraint=None,
          outdir=None, extends=("Mix", "Props"), extra_defs="", deadlock=False, rarity=None,
          throttle=None, profile=(), known=False):
    sys.path.insert(0, str(ROOT / "scripts"))
    import gen_mix
    reg = gen_mix.load()
    grain = dict(grain or {})
    g = {}
    persite = False
    def base_of(grp):
        vs = list(reg["groups"][grp]["variants"])
        return default if default in vs else vs[0]
    for grp, gd in reg["groups"].items():
        vs = list(gd["variants"])
        val = grain.get(grp) or (default if default in vs else vs[0])
        if isinstance(val, str) and "@" in val:      # e.g. "F@s1": F at s1, coarse elsewhere
            fv, at = val.split("@")
            base = default if default in vs else vs[0]
            val = {f"s{i+1}": (fv if f"s{i+1}" in at.split("+") else base) for i in range(sites)}
        if isinstance(val, dict):
            assert all(x in vs for x in val.values()), (grp, val, vs)
            persite = True
        else:
            assert val in vs, (grp, val, vs)
        g[grp] = val
    outdir = Path(outdir or ROOT / "checks" / "mixes")
    outdir.mkdir(parents=True, exist_ok=True)
    site_names = [f"s{i+1}" for i in range(sites)]
    mod = f"MC_{name}"
    tla = [f"---- MODULE {mod} ----",
           "EXTENDS " + ", ".join(extends) + ", TLC",
           ("CONSTANTS " + ", ".join(site_names)) if persite else "",
           "MCGrain == [" + ", ".join(f'{k} |-> "' + (v if isinstance(v, str) else base_of(k)) + '"'
                for k, v in g.items()) + "]",
           "MCSiteGrain == " + ("[g \\in {} |-> 0]" if not persite else
                "(" + " @@ ".join(f'"{k}" :> (' + " @@ ".join(f'{sname} :> "{sv}"' for sname, sv in v.items()) + ")"
                                  for k, v in g.items() if isinstance(v, dict)) + ")"),
           "MCFaults == {" + ", ".join(f'"{f}"' for f in faults) + "}",
           "MCProfile == {" + ", ".join(f'"{f}"' for f in profile) + "}",
           "MCSym == Permutations(Sites)",
           extra_defs,
           "===="]
    consts = ["CONSTANTS", "  Grain <- MCGrain", "  SiteGrain <- MCSiteGrain", "  Faults <- MCFaults", "  Profile <- MCProfile", "  Sites = {" + ", ".join(site_names) + "}"] + \
             ([f"  {sn} = {sn}" for sn in site_names] if persite else []) + [
              "  None = None", "  JobId = JobId", f"  MaxLaunch = {launch}", f"  MaxAttempt = {attempt}"]
    init, nxt = "Init", "Next"
    if throttle and rarity is None:
        rarity = 99          # throttling needs MixR's `rare`; 99 = no real budget
    if throttle:
        # simulation only: a priced step is accepted with probability 1/T unless
        # no free step is enabled (pruning only, so every trace is a behavior)
        tla.insert(-1, f"Throttle == rare' = rare \\/ RandomElement(1..{int(throttle)}) = 1"
                       " \\/ ~ENABLED (RNext /\\ rare' = rare)")
    if rarity is not None:
        # bounded rare-event budget (scripts/rarity.py -> MixR.tla)
        sys.path.insert(0, str(ROOT / "scripts"))
        import rarity as R
        if not getattr(R, "_written", False):   # once per process: running TLCs read it
            R.write_mixr(); R._written = True
        extends = tuple("MixR" if e == "Mix" else e for e in extends)
        tla[1] = "EXTENDS " + ", ".join(extends) + ", TLC"
        consts.append(f"  RareBudget = {int(rarity)}")
        init, nxt = "RInit", "RNext"
    if deadlock:
        if "GenericProps" not in extends:
            extends = tuple(extends) + ("GenericProps",)
            tla[1] = "EXTENDS " + ", ".join(extends) + ", TLC"
        if rarity is None:
            tla.insert(-1, "GNext == Next \\/ ((DoneStutter \\/ ((AtBoundAny" + (" \\/ KnownStuck" if known else "")
                       + ") /\\ UNCHANGED portVars)) /\\ UNCHANGED privVars)")
        else:
            tla.insert(-1, "GNext == RNext \\/ ((DoneStutter \\/ ((AtBoundAny \\/ OverBudget" + (" \\/ KnownStuck" if known else "")
                       + ") /\\ UNCHANGED portVars)) /\\ UNCHANGED <<privVars, rare>>)")
        nxt = "GNext"
    cfg = consts + ["INIT " + init, "NEXT " + nxt]
    # profile cseTasks fixes a site order (CommSJ_F LastSite): not symmetric
    if symmetry and sites > 1 and not persite and "cseTasks" not in (profile or ()):
        cfg.append("SYMMETRY MCSym")
    if constraint:
        cfg.append(f"CONSTRAINT {constraint}")
    if throttle:
        cfg.append("ACTION_CONSTRAINT Throttle")
    for i in inv:
        cfg.append(f"INVARIANT {i}")
    for p in prop:
        cfg.append(f"PROPERTY {p}")
    cfg.append("CHECK_DEADLOCK " + ("TRUE" if deadlock else "FALSE"))
    (outdir / f"{mod}.tla").write_text("\n".join(tla) + "\n")
    (outdir / f"{mod}.cfg").write_text("\n".join(cfg) + "\n")
    return outdir, mod, g


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--grain", default="")
    ap.add_argument("--default", default="C")
    ap.add_argument("--faults", default="")
    ap.add_argument("--sites", type=int, default=2)
    ap.add_argument("--launch", type=int, default=1)
    ap.add_argument("--attempt", type=int, default=1)
    ap.add_argument("--inv", default=",".join(PORT_INVS))
    ap.add_argument("--prop", default="")
    ap.add_argument("--no-symmetry", action="store_true")
    ap.add_argument("--constraint")
    ap.add_argument("--outdir")
    ap.add_argument("--rarity", type=int, help="rare-event budget K (MixR)")
    ap.add_argument("--deadlock", action="store_true")
    ap.add_argument("--profile", default="", help="Profile switches, comma-separated (Consts.ProfileSwitches)")
    ap.add_argument("--throttle", type=int, help="simulation only: accept priced steps with prob. 1/T")
    ap.add_argument("--extends", default="Mix,Props")
    a = ap.parse_args()
    grain = dict(x.split("=") for x in a.grain.split(",") if x)
    out, mod, g = build(a.name, grain, a.default, [f for f in a.faults.split(",") if f], a.sites,
                        a.launch, a.attempt, [i for i in a.inv.split(",") if i],
                        [p for p in a.prop.split(",") if p], not a.no_symmetry, a.constraint,
                        a.outdir, tuple(a.extends.split(",")), deadlock=a.deadlock, rarity=a.rarity,
                        throttle=a.throttle, profile=[x for x in a.profile.split(",") if x])
    print(out, mod, g)


if __name__ == "__main__":
    main()
