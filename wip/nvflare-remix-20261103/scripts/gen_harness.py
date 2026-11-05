#!/usr/bin/env python3
"""Assume-guarantee refinement harness for one group (DESIGN.md §2.1).

gen_harness.py GROUP FINE COARSE --env Env_<G> [--const NAME=VAL,...]
               [--sites N] [--launch N] [--faults f1,f2] [--run] [--negative]
               [--timeout S] [--workers N]

The harness contains ONLY the group's fine variant plus its environment
module's generator form (EnvNext), which over-approximates every neighbor on
the ports the group reads. It checks, exhaustively and cheaply:
  RefInit / RefStep  fine refines coarse on Proj_G (coarse private := AbsC)
  RefEnv             AbsC is stable under environment steps
  EnvSound           every generated environment step satisfies the checker
                     form EnvAllowed (generator within assumption)
--negative checks BadStep == [][UNCHANGED <<AbsC, Proj_G>>] (must FAIL).
A receipt with kind "harness" goes to checks/receipts/.
The assumption itself is discharged separately: AG_<G> (spec/AG.tla) is a
property over any mix, checked by campaigns (mkmc --prop AG_<G>).
"""
import argparse, json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import gen_mix, run_mc  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("group"); ap.add_argument("fine"); ap.add_argument("coarse")
    ap.add_argument("--env", required=True)
    ap.add_argument("--const", default="")
    ap.add_argument("--sites", type=int, default=1)
    ap.add_argument("--launch", type=int, default=1)
    ap.add_argument("--faults", default="")
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--negative", action="store_true")
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--workers", type=int, default=16)
    a = ap.parse_args()
    import os
    os.environ.setdefault("MIX_INCLUDE_WIP", "all")
    reg = gen_mix.load()
    gd = reg["groups"][a.group]
    fv = gd["variants"][a.fine]; cv = gd["variants"][a.coarse]
    port = gd["port"]; kinds = gd["kinds"]
    ports = reg["port_vars"]
    env_src = (Path(os.environ.get("MIX_SPEC") or ROOT / "spec") / f"{a.env}.tla").read_text()
    m = re.search(r"^EnvVars\s*==\s*<<(.*?)>>", env_src, flags=re.M)
    env_vars = [x.strip() for x in m.group(1).split(",")] if m else []
    env_consts = re.findall(r"^CONSTANTS?\s+(.*)$", env_src, flags=re.M)
    env_consts = [x.strip() for c in env_consts for x in c.split(",") if x.strip()]
    consts = dict(x.split("=") for x in a.const.split(",") if x)
    fprivs = fv["vars"]
    hv = ports + fprivs
    g_own = {port} | ({"net"} if kinds else set()) | set(fprivs)
    g_frame = [x for x in hv if x not in g_own]
    e_own = set(env_vars)
    e_frame = [x for x in hv if x not in e_own]
    name = f"H_{a.group}_{a.fine}_{a.coarse}" + ("_neg" if a.negative else "")
    ks = "{" + ", ".join(f'"{k}"' for k in kinds) + "}"
    if len(cv["vars"]) != 1:
        sys.exit("coarse variant must have exactly one private var")
    L = [f"---- MODULE {name} ----", "EXTENDS Ports, TLC"]
    if env_consts:
        L.append("CONSTANTS " + ", ".join(env_consts))
    L.append("CONSTANTS " + ", ".join(f"s{i+1}" for i in range(a.sites)))
    L += [f"VARIABLES {', '.join(fprivs)}",
          f"hvars == <<{', '.join(hv)}>>",
          f"FV == INSTANCE {fv['module']}",
          f"E == INSTANCE {a.env}",
          f"CRef == INSTANCE {cv['module']} WITH {cv['vars'][0]} <- FV!AbsC",
          "SentKinds(kk) == {net[k].msg : k \\in {k2 \\in DOMAIN net : net[k2].msg.kind \\in kk}}",
          f"ProjG == <<{port}, SentKinds({ks})>>",
          "NetKeep == DOMAIN net \\subseteq DOMAIN net' /\\ \\A k \\in DOMAIN net : net'[k] = net[k]",
          f"GStep == FV!Next /\\ UNCHANGED <<{', '.join(g_frame)}>>",
          f"    /\\ Assert(NetKeep /\\ \\A k \\in DOMAIN net' \\ DOMAIN net : net'[k].msg.kind \\in {ks}, \"net discipline (group)\")",
          f"EStep == E!EnvNext /\\ UNCHANGED <<{', '.join(e_frame)}>>",
          "HInit == PortsInit /\\ FV!Init",
          "HNext == GStep \\/ EStep",
          "RefInit == CRef!Init",
          "RefStep == [][CRef!Next \\/ UNCHANGED <<FV!AbsC, ProjG>>]_hvars",
          f"RefEnv == [][UNCHANGED <<{', '.join(fprivs)}, ProjG>> => UNCHANGED FV!AbsC]_hvars",
          "EnvSound == [][EStep => E!EnvAllowed]_hvars",
          "BadStep == [][UNCHANGED <<FV!AbsC, ProjG>>]_hvars",
          "===="]
    out = ROOT / "checks" / "harness"; out.mkdir(parents=True, exist_ok=True)
    mixes = ROOT / "checks" / "mixes"
    (out / f"{name}.tla").write_text("\n".join(L) + "\n")
    faults = [f for f in a.faults.split(",") if f]
    cfg = ["CONSTANTS", "  Sites = {" + ", ".join(f"s{i+1}" for i in range(a.sites)) + "}"]
    cfg += [f"  s{i+1} = s{i+1}" for i in range(a.sites)]
    cfg += ["  None = None", "  JobId = JobId", f"  MaxLaunch = {a.launch}", "  MaxAttempt = 1", "  Profile = {}",
            "  Faults = {" + ", ".join(f'"{f}"' for f in faults) + "}"]
    cfg += [f"  {k} = {v}" for k, v in consts.items()]
    cfg += ["INIT HInit", "NEXT HNext"]
    cfg += ["PROPERTY BadStep"] if a.negative else ["PROPERTY RefInit", "PROPERTY RefStep",
                                                     "PROPERTY RefEnv", "PROPERTY EnvSound"]
    cfg.append("CHECK_DEADLOCK FALSE")
    (out / f"{name}.cfg").write_text("\n".join(cfg) + "\n")
    # run_mc expects checks/mixes/MC_<name>
    (mixes / f"MC_{name}.tla").write_text((out / f"{name}.tla").read_text().replace(f"MODULE {name}", f"MODULE MC_{name}"))
    (mixes / f"MC_{name}.cfg").write_text((out / f"{name}.cfg").read_text())
    print("wrote", out / f"{name}.tla", "env writes", env_vars)
    if a.run:
        r = run_mc.run(name, a.timeout, a.workers, "bfs", (0, 0), "16g")
        r.pop("cfg", None)
        print({k: v for k, v in r.items()})
        if not a.negative:
            sig = dict(sites=a.sites, faults=sorted(faults), net="harness", launch=a.launch, env=a.env,
                       consts=consts)
            rec = dict(kind="harness", group=a.group, fine=a.fine, coarse=a.coarse, sig=sig,
                       result=r.get("result"), distinct=r.get("distinct"), violated=r.get("violated"),
                       run=name, exhaustive=r.get("result") == "pass_exhaustive",
                       discharge=f"AG_{a.group} (spec/AG.tla) must hold in every mix used")
            rd = ROOT / "checks" / "receipts"; rd.mkdir(parents=True, exist_ok=True)
            key = f"{a.group}_{a.fine}_{a.coarse}__harness_s{a.sites}_l{a.launch}_f{'-'.join(sorted(faults)) or 'none'}"
            (rd / f"{key}.json").write_text(json.dumps(rec, indent=1))
            print("receipt:", key, rec["result"])


if __name__ == "__main__":
    main()
