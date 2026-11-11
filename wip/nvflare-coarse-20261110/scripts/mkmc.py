#!/usr/bin/env python3
"""Create an MC module + cfg for one mix.

mkmc.py NAME [--grain G=V,...] [--default C] [--faults f1,f2] [--sites N]
        [--launch N] [--attempt N] [--inv I1,I2] [--prop P1] [--symmetry]
        [--constraint EXPR] [--outdir DIR] [--extends M1,M2]
        [--rarity K] [--deadlock] [--throttle T]
Coarse variants only. --grain selects the Trainer deployment mode (Trainer=C|X|A);
every other group has a single module.
"""
import argparse, json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PORT_INVS = ("ClaimNeedsMaterialized","MaterializedIsRegistered","AggregateIsAccepted","AcceptedWasClaimed","ReceivedReceiptMeansFinished","ReceivedMeansAccepted","NoFreeWhileChildAlive","AtMostOneFree","FinishedJobSaved","FinishedJobAllOk","NoReleaseBeforeMaterialize")


def build(name, grain=None, default="C", faults=(), sites=2, launch=1, attempt=1,
          inv=PORT_INVS, prop=(), symmetry=True, constraint=None,
          outdir=None, extends=("Mix", "Props"), extra_defs="", deadlock=False, rarity=None,
          throttle=None, profile=(), known=False, fuse=False, init_states=None, action_constraint=None,
          extra_stutter=(), next_name=None, fault_phases=None, init_extra=None):
    """fuse (simulation, with throttle): each trace draws a phase (JobPhase.FusePhases)
    at its initial state; priced steps are refused before the job reaches it (unless no
    free step is enabled), and accepted with probability 1/T from then on.
    init_states: list of TLA+ state predicates (checkpoints, scripts/ckpt.py); the run
    starts from their disjunction instead of the spec's Init (no symmetry)."""
    sys.path.insert(0, str(ROOT / "scripts"))
    import gen_mix
    reg = gen_mix.load()
    grain = dict(grain or {})
    g = {}
    for grp, gd in reg["groups"].items():
        vs = list(gd["variants"])
        val = grain.get(grp) or (default if default in vs else vs[0])
        assert val in vs, (grp, val, vs)
        g[grp] = val
    outdir = Path(outdir or ROOT / "checks" / "mixes")
    outdir.mkdir(parents=True, exist_ok=True)
    site_names = [f"s{i+1}" for i in range(sites)]
    if fuse:
        assert throttle, "fuse needs a throttle"
    if (fuse or init_states) and "JobPhase" not in extends:
        extends = tuple(extends) + ("JobPhase",)
    declare_sites = bool(init_states)
    mod = f"MC_{name}"
    tla = [f"---- MODULE {mod} ----",
           "EXTENDS " + ", ".join(extends) + ", TLC",
           ("CONSTANTS " + ", ".join(site_names)) if declare_sites else "",
           "VARIABLE fuse" if fuse else "",
           "MCGrain == [" + ", ".join(f'{k} |-> "{v}"' for k, v in g.items()) + "]",
           "MCFaults == {" + ", ".join(f'"{f}"' for f in faults) + "}",
           "MCProfile == {" + ", ".join(f'"{f}"' for f in profile) + "}",
           "MCSym == Permutations(Sites)",
           extra_defs,
           "===="]
    consts = ["CONSTANTS", "  Grain <- MCGrain", "  Faults <- MCFaults", "  Profile <- MCProfile", "  Sites = {" + ", ".join(site_names) + "}"] + \
             ([f"  {sn} = {sn}" for sn in site_names] if declare_sites else []) + [
              "  None = None", "  JobId = JobId", f"  MaxLaunch = {launch}", f"  MaxAttempt = {attempt}"]
    init, nxt = "Init", "Next"
    if throttle and rarity is None:
        rarity = 99          # throttling needs MixR's `rare`; 99 = no real budget
    if throttle:
        # simulation only: a priced step is accepted with probability 1/T unless
        # no free step is enabled (pruning only, so every trace is a behavior)
        # with fuse, every ENABLED also fixes fuse' so its search determines the
        # whole successor state
        gate = "JobPhase >= fuse /\\ " if fuse else ""
        frame = " /\\ fuse' = fuse" if fuse else ""
        thr = (f"(rare' = rare \\/ ({gate}RandomElement(1..{int(throttle)}) = 1)"
               f" \\/ ~ENABLED (RNext /\\ rare' = rare{frame}))")
        if fuse:
            # before the fuse, free steps that only drive a fault mechanism (rarity.json
            # actions priced 0, e.g. the CommSJ clock tick) are refused too: taken early
            # they leave a priced step (a forced task timeout) as the only way on, which
            # the no-free-step escape would then let through
            free = [a for a, w in json.loads(((Path(__import__("os").environ.get("MIX_SPEC") or (ROOT / "spec"))) / "rarity.json").read_text())["actions"].items()
                    if w == 0]
            if free:
                # cheap pre-filter: such a step changes no port and only its group's
                # private variable (G_V -> g_v), so the RStep formulas are evaluated
                # for few successors
                pv = sorted({(a.split(".")[0].split("_")[0][0].lower() + a.split(".")[0].split("_")[0][1:]
                              + "_" + a.split(".")[0].split("_")[1].lower()) for a in free})
                ports = "<<pJobSP, pJobCP, pRunCJ, pTaskCJ, pPaySrc, pPayRcv, pCommSJ, pWfSJ, pTrainer>>"
                tla.insert(-1, f"FDCand == UNCHANGED {ports} /\\ (" + " \\/ ".join(f"{v}' /= {v}" for v in pv) + ")")
                tla.insert(-1, "FaultDriving == " + " \\/ ".join(f"RStep_{a.replace('.', '_')}" for a in free))
                thr = f"(JobPhase >= fuse \\/ ~(FDCand /\\ FaultDriving)) /\\ {thr}"
        tla.insert(-1, f"Throttle == {thr}")
    if rarity is not None:
        # bounded rare-event budget (scripts/rarity.py -> MixR.tla)
        sys.path.insert(0, str(ROOT / "scripts"))
        import rarity as R
        if not getattr(R, "_written", False):   # once per process: running TLCs read it
            R.write_mixr(); R._written = True
        extends = tuple("MixR" if e == "Mix" else e for e in extends)
        tla[1] = "EXTENDS " + ", ".join(extends) + ", TLC"
        consts.append(f"  RareBudget = {int(rarity)}")
        consts.append("  FaultPhases = {" + ", ".join(str(x) for x in (fault_phases or range(0, 7))) + "}")
        init, nxt = "RInit", "RNext"
    if deadlock:
        if "GenericProps" not in extends:
            extends = tuple(extends) + ("GenericProps",)
            tla[1] = "EXTENDS " + ", ".join(extends) + ", TLC"
        if rarity is None:
            tla.insert(-1, "GNext == Next \\/ ((DoneStutter \\/ ((AtBoundAny" + (" \\/ KnownStuck" if known else "")
                       + "".join(f" \\/ {x}" for x in extra_stutter)
                       + ") /\\ UNCHANGED portVars)) /\\ UNCHANGED privVars)")
        else:
            ob = "OverBudget"
            if fuse:
                tla.insert(-1, "OverBudgetF == ENABLED (FPriced /\\ rare' > RareBudget /\\ fuse' = fuse)")
                ob = "OverBudgetF"
            tla.insert(-1, "GNext == RNext \\/ ((DoneStutter \\/ ((AtBoundAny \\/ " + ob + (" \\/ KnownStuck" if known else "")
                       + "".join(f" \\/ {x}" for x in extra_stutter)
                       + ") /\\ UNCHANGED portVars)) /\\ UNCHANGED <<privVars, rare, paid>>)")
        nxt = "GNext"
    if fuse:
        tla.insert(-1, f"FInit == {init} /\\ fuse \\in FusePhases")
        tla.insert(-1, f"FNext == {nxt} /\\ UNCHANGED fuse")
        init, nxt = "FInit", "FNext"
    if init_states:
        tla.insert(-1, "CInit ==\n" + "\n".join("    \\/ (" + st.strip().replace("\n", "\n       ") + ")"
                                                for st in init_states))
        init = "CInit"
    if next_name:            # a next-state relation defined in extra_defs (e.g. a sliced schedule)
        nxt = next_name

    if init_extra:           # extra initial conditions (variables declared in extra_defs)
        tla.insert(-1, f"XInit == {init} /\\ {init_extra}")
        init = "XInit"
    cfg = consts + ["INIT " + init, "NEXT " + nxt]
    # profile cseTasks fixes a site order (CommSJ_F LastSite): not symmetric
    if symmetry and sites > 1 and not init_states and not ({"cseTasks", "swarm"} & set(profile or ())):
        cfg.append("SYMMETRY MCSym")
    if constraint:
        cfg.append(f"CONSTRAINT {constraint}")
    if fault_phases is not None and rarity is not None:
        cfg.append("CONSTRAINT WindowCon")
    if action_constraint:
        tla.insert(-1, f"MCActCon == {action_constraint}")
        cfg.append("ACTION_CONSTRAINT MCActCon")
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
    ap.add_argument("--fuse", action="store_true", help="simulation: phase-gated fault throttle")
    a = ap.parse_args()
    grain = dict(x.split("=") for x in a.grain.split(",") if x)
    out, mod, g = build(a.name, grain, a.default, [f for f in a.faults.split(",") if f], a.sites,
                        a.launch, a.attempt, [i for i in a.inv.split(",") if i],
                        [p for p in a.prop.split(",") if p], not a.no_symmetry, a.constraint,
                        a.outdir, tuple(a.extends.split(",")), deadlock=a.deadlock, rarity=a.rarity,
                        throttle=a.throttle, profile=[x for x in a.profile.split(",") if x], fuse=a.fuse)
    print(out, mod, g)


if __name__ == "__main__":
    main()
