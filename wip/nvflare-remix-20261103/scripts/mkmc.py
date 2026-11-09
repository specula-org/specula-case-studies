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
# v11 (DESIGN 16.1): profile switches whose behavior exists only in the coarse
# module of these groups; a mix that picks another variant for them is refused.
COARSE_ONLY = {
    "sjModel": ["WfSJ"], "sag": ["WfSJ"], "cyclic": ["WfSJ"], "cseServer": ["WfSJ", "CommSJ"],
    "swarm": ["WfSJ", "CommSJ", "TaskCJ"], "k8sJob": ["JobCP"], "dockerJob": ["JobCP"],
    "multiJobCP": ["JobCP"], "sampling": ["WfSJ", "CommSJ"],
}


# grain-level rules: a variant whose port effects only the coarse module of a
# neighbor reads (Trainer_A sets pTrainer.err, read by TaskCJ_C only)
GRAIN_COARSE_ONLY = {("Trainer", "A"): ["TaskCJ"]}


# v11: faults whose events exist only in the coarse module of these groups
COARSE_ONLY_FAULTS = {"sjSyncFail": ["WfSJ"], "taskDataFail": ["TaskCJ"], "podDeleteFail": ["JobCP"],
                      "slowPublish": ["JobCP"], "acceptRaise": ["WfSJ"], "saveFail": ["WfSJ"]}


def check_coarse_only(grain, profile, faults=()):
    for f in faults or ():
        for grp in COARSE_ONLY_FAULTS.get(f, ()):
            v = grain.get(grp)
            bad = (set(v.values()) if isinstance(v, dict) else {v}) - {"C"}
            assert not bad, f"fault {f}: group {grp} must be coarse (C), got {sorted(bad)}"
    for (grp0, var0), groups in GRAIN_COARSE_ONLY.items():
        v0 = grain.get(grp0)
        if var0 in (set(v0.values()) if isinstance(v0, dict) else {v0}):
            for grp in groups:
                v = grain.get(grp)
                bad = (set(v.values()) if isinstance(v, dict) else {v}) - {"C"}
                assert not bad, f"{grp0}={var0}: group {grp} must be coarse (C), got {sorted(bad)}"
    for sw in profile or ():
        for grp in COARSE_ONLY.get(sw, ()):
            v = grain.get(grp)
            vals = set(v.values()) if isinstance(v, dict) else {v}
            bad = vals - {"C"}
            assert not bad, f"profile {sw}: group {grp} must be coarse (C), got {sorted(bad)}"


PORT_INVS = ("ClaimNeedsMaterialized","MaterializedIsRegistered","AggregateIsAccepted","AcceptedWasClaimed","ReceivedReceiptMeansFinished","ReceivedMeansAccepted","NoFreeWhileChildAlive","AtMostOneFree","FinishedJobSaved","FinishedJobAllOk","NoReleaseBeforeMaterialize")


def build(name, grain=None, default="C", faults=(), sites=2, launch=1, attempt=1,
          inv=PORT_INVS, prop=(), symmetry=True, constraint=None,
          outdir=None, extends=("Mix", "Props"), extra_defs="", deadlock=False, rarity=None,
          throttle=None, profile=(), known=False, fuse=False, init_states=None, action_constraint=None,
          extra_stutter=()):
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
    check_coarse_only(g, profile, faults)
    outdir = Path(outdir or ROOT / "checks" / "mixes")
    outdir.mkdir(parents=True, exist_ok=True)
    site_names = [f"s{i+1}" for i in range(sites)]
    if fuse:
        assert throttle, "fuse needs a throttle"
    if (fuse or init_states) and "JobPhase" not in extends:
        extends = tuple(extends) + ("JobPhase",)
    declare_sites = persite or bool(init_states)
    mod = f"MC_{name}"
    tla = [f"---- MODULE {mod} ----",
           "EXTENDS " + ", ".join(extends) + ", TLC",
           ("CONSTANTS " + ", ".join(site_names)) if declare_sites else "",
           "VARIABLE fuse" if fuse else "",
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
            free = [a for a, w in json.loads((ROOT / "spec" / "rarity.json").read_text())["actions"].items()
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
                       + ") /\\ UNCHANGED portVars)) /\\ UNCHANGED <<privVars, rare>>)")
        nxt = "GNext"
    if fuse:
        tla.insert(-1, f"FInit == {init} /\\ fuse \\in FusePhases")
        tla.insert(-1, f"FNext == {nxt} /\\ UNCHANGED fuse")
        init, nxt = "FInit", "FNext"
    if init_states:
        tla.insert(-1, "CInit ==\n" + "\n".join("    \\/ (" + st.strip().replace("\n", "\n       ") + ")"
                                                for st in init_states))
        init = "CInit"
    cfg = consts + ["INIT " + init, "NEXT " + nxt]
    # profile cseTasks fixes a site order (CommSJ_F LastSite): not symmetric
    if symmetry and sites > 1 and not persite and not init_states and not ({"cseTasks", "swarm"} & set(profile or ())):
        cfg.append("SYMMETRY MCSym")
    if constraint:
        cfg.append(f"CONSTRAINT {constraint}")
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
