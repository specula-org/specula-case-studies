#!/usr/bin/env python3
"""Generate the composition root (spec/Mix.tla) from spec/registry.json and run
static decoupling checks on every group module. Coarse variants only: each group
has one module, except Trainer, whose deployment modes (C in-process, X external
process, A attach) are selected by the constant Grain. No per-site grain, no
covering arrays, no refinement receipts (those belonged to the multi-grained remix).

Static checks (fail closed):
  * a variant primes only its own private vars, its group's port var, and net;
  * a variant only constructs messages (Msg("KIND", ...)) of kinds owned by its group;
  * a variant declares exactly the private vars listed in the registry;
  * a variant references no other variant's private variables.

Usage: gen_mix.py [--check-only]
"""
import json, os, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = Path(os.environ.get("MIX_SPEC") or (ROOT / "spec"))


def load():
    """Core registry plus per-component fragments in spec/registry.d/*.json."""
    reg = json.loads((SPEC / "registry.json").read_text())
    groups = dict(reg["groups"])
    for f in sorted((SPEC / "registry.d").glob("*.json")):
        for g, gd in json.loads(f.read_text())["groups"].items():
            assert g not in groups, f"group {g} defined twice ({f.name})"
            gd["component_file"] = f.name
            groups[g] = gd
    order = reg.get("group_order", [])
    reg["groups"] = {g: groups[g] for g in order if g in groups}
    reg["groups"].update({g: v for g, v in groups.items() if g not in reg["groups"]})
    return reg


def all_private(reg):
    out = []
    for g, gd in reg["groups"].items():
        for v, vd in gd["variants"].items():
            out += vd["vars"]
    return out


def strip_comments(s):
    s = re.sub(r"\(\*.*?\*\)", "", s, flags=re.S)
    return "\n".join(line.split("\\*")[0] for line in s.splitlines())


ALLOWED_IMPORTS = {"Ports", "Consts", "PortsJob", "PortsFed", "PortsPay", "PortsTrn", "PortsWrk", "PortsModel", "PortsSwarm", "PortsReg", "Timing", "Naturals",
                   "Integers", "Sequences", "FiniteSets", "TLC", "SequencesExt", "Bags"}


WARNINGS = []


def static_check(reg):
    errors = []
    privs = all_private(reg)
    for g, gd in reg["groups"].items():
        for v, vd in gd["variants"].items():
            f = SPEC / (vd["module"] + ".tla")
            if not f.exists():
                errors.append(f"{g}/{v}: missing {f.name}")
                continue
            src = strip_comments(f.read_text())
            own = set(vd["vars"]) | ({gd["port"]} if gd["port"] else set())
            if gd["kinds"] or gd.get("writes_net_loss"):
                own.add("net")
            primed = set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)'", src))
            bad = primed - own
            if bad:
                errors.append(f"{g}/{v}: primes non-owned {sorted(bad)}")
            if re.search(r"\.lost\b", src) and not gd.get("writes_net_loss"):
                (errors if os.environ.get("STRICT_LOST") else WARNINGS).append(
                    f"{g}/{v}: reads/writes net loss flags (oracle; only Net may)")
            for m in re.finditer(r"\b(EXTENDS|INSTANCE)\s+([A-Za-z_][A-Za-z0-9_, ]*)", src):
                for mod in [x.strip() for x in m.group(2).split(",") if x.strip()]:
                    if m.group(1) == "INSTANCE":
                        mod = mod.split()[0]
                    if mod not in ALLOWED_IMPORTS:
                        errors.append(f"{g}/{v}: {m.group(1)} {mod} not in allowlist")
            kinds = set(re.findall(r'Msg\(\s*"([A-Z_]+)"', src))
            badk = kinds - set(gd["kinds"])
            if badk:
                errors.append(f"{g}/{v}: sends non-owned kinds {sorted(badk)}")
            decl = set()
            for m in re.finditer(r"\bVARIABLES?\b([^\n]*)", src):
                decl |= {x.strip() for x in m.group(1).split(",") if x.strip()}
            if decl != set(vd["vars"]):
                errors.append(f"{g}/{v}: declares {sorted(decl)} expected {vd['vars']}")
            others = [p for p in privs if p not in vd["vars"]]
            for p in others:
                if re.search(r"\b" + re.escape(p) + r"\b", src):
                    errors.append(f"{g}/{v}: references foreign private var {p}")
    return errors


# ---------------------------------------------------------------- Next parser
# Variants should write Next as a disjunction of action applications, possibly
# under \E quantifiers whose domains use only Ports-level names. Then the mix
# root wraps each action separately so TLC counterexamples name the action
# (Step_<Group>_<V>_<Action>). Anything else falls back to one Step per variant.
def _split_top(text, sep):
    """split text on sep at bracket depth 0 (brackets: () [] {} << >>)."""
    out, depth, cur, i = [], 0, "", 0
    while i < len(text):
        if text.startswith("<<", i):
            depth += 1; cur += "<<"; i += 2; continue
        if text.startswith(">>", i):
            depth -= 1; cur += ">>"; i += 2; continue
        ch = text[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if depth == 0 and text.startswith(sep, i) and not (sep == ":" and text.startswith(":>", i)):
            out.append(cur); cur = ""; i += len(sep); continue
        cur += ch; i += 1
    out.append(cur)
    return out


def _depth_ok(text):
    d = 0
    for ch in text:
        d += ch in "([{"; d -= ch in ")]}"
        if d < 0:
            return False
    return d == 0


def _strip_parens(t):
    t = t.strip()
    while t.startswith("(") and t.endswith(")") and _depth_ok(t[1:-1]):
        t = t[1:-1].strip()
    return t


def _parse_block(lines, binders, out):
    """lines: raw source lines of one disjunction (bulleted or inline)."""
    lines = [l for l in lines if l.strip()]
    if not lines:
        return False
    first = lines[0]
    fs = first.lstrip()
    if fs.startswith("\\/"):
        col = len(first) - len(fs)
        items = []
        for l in lines:
            ls = l.lstrip(); c = len(l) - len(ls)
            if ls.startswith("\\/") and c == col:
                items.append([" " * (c + 2) + ls[2:]])
            elif c <= col and items:
                return False
            else:
                if not items:
                    return False
                items[-1].append(l)
        return all(_parse_block(it, binders, out) for it in items)
    if fs.startswith("\\E"):
        joined = "\n".join(lines)
        i = joined.index("\\E") + 2
        segs = _split_top(joined[i:], ":")
        if len(segs) < 2:
            return False
        bnd = " ".join(segs[0].split())
        body = ":".join(segs[1:])
        return _parse_block(body.split("\n"), binders + [bnd], out)
    inline = " ".join(" ".join(lines).split())
    parts = [x.strip() for x in _split_top(inline, "\\/") if x.strip()]
    if len(parts) > 1:
        for k, part in enumerate(parts):
            if part.startswith("\\E"):
                # quantifier scope extends to the end of the inline disjunction
                return _parse_block([" \\/ ".join(parts[k:])], binders, out)
            if not _parse_block([part], binders, out):
                return False
        return True
    t = _strip_parens(inline)
    if t != inline:
        return _parse_block([t], binders, out)
    m = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)\s*(\((.*)\))?", t, flags=re.S)
    if not m or not (m.group(3) is None or _depth_ok(m.group(3))):
        return False
    if m.group(1) == "FALSE":
        return True  # no actions
    if m.group(1) in ("TRUE", "UNCHANGED"):
        return False
    out.append((list(binders), m.group(1), m.group(3)))
    return True


def parse_next(src):
    m = re.search(r"^Next\s*==(.*?)(?=^\S|\Z)", src, flags=re.S | re.M)
    if not m:
        return None
    body = m.group(1)
    lines = body.split("\n")
    # first line may hold inline content after "Next =="
    lines[0] = " " * (len("Next ==")) + lines[0]
    out = []
    try:
        ok = _parse_block(lines, [], out)
    except Exception:
        ok = False
    return out if ok else None

def gen_mix(reg):
    privs = all_private(reg)
    allv = reg["port_vars"] + privs
    L = []
    L.append("-------------------------------- MODULE Mix --------------------------------")
    L.append("\\* GENERATED by scripts/gen_mix.py from spec/registry.json. Do not edit.")
    L.append("\\* One module per group (coarse variants only). Grain selects the Trainer")
    L.append("\\* deployment mode; the private variables of unselected modes stay at Init.")
    L.append("EXTENDS Ports, TLC")
    L.append("CONSTANT Grain")
    L.append("VARIABLES " + ", ".join(privs))
    L.append("privVars == <<" + ", ".join(privs) + ">>")
    L.append("allVars == <<portVars, privVars>>")
    L.append("Groups == {" + ", ".join(f'"{g}"' for g in reg["groups"]) + "}")
    L.append("VariantsOf == [g \\in Groups |-> CASE " + "\n    [] ".join(
        f'g = "{g}" -> {{' + ", ".join(f'"{v}"' for v in gd["variants"]) + "}"
        for g, gd in reg["groups"].items()) + "]")
    L.append("ASSUME DOMAIN Grain = Groups /\\ \\A g \\in Groups : Grain[g] \\in VariantsOf[g]")
    L.append("KindOwner(kind) == CASE " + "\n    [] ".join(
        f'kind \\in {{' + ", ".join(f'"{k}"' for k in gd["kinds"]) + f'}} -> "{g}"'
        for g, gd in reg["groups"].items() if gd["kinds"]) + '\n    [] OTHER -> "none"')
    L.append("\\* Net discipline (asserted on every step): existing messages are immutable;")
    L.append("\\* new keys carry only kinds owned by the stepping group and start not-lost;")
    L.append("\\* only the Net group flips lost flags (FALSE -> TRUE) and adds nothing.")
    L.append("NetKeep == DOMAIN net \\subseteq DOMAIN net' /\\ \\A k \\in DOMAIN net : net'[k] = net[k]")
    L.append("NetOK(g) == NetKeep /\\ \\A k \\in DOMAIN net' \\ DOMAIN net :")
    L.append("    KindOwner(net'[k].msg.kind) = g /\\ ~net'[k].lost /\\ net'[k].msg.from \\in Processes")
    L.append("NetLossOK == DOMAIN net' = DOMAIN net /\\ \\A k \\in DOMAIN net :")
    L.append("    net'[k].msg = net[k].msg /\\ (net[k].lost => net'[k].lost)")
    for g, gd in reg["groups"].items():
        for v, vd in gd["variants"].items():
            L.append(f"{g}_{v} == INSTANCE {vd['module']}")
    L.append("")
    L.append("Init == /\\ PortsInit")
    for g, gd in reg["groups"].items():
        for v in gd["variants"]:
            L.append(f"        /\\ {g}_{v}!Init")
    L.append("")
    steps = []
    for g, gd in reg["groups"].items():
        for v, vd in gd["variants"].items():
            own = set(vd["vars"]) | ({gd["port"]} if gd["port"] else set())
            if gd["kinds"] or gd.get("writes_net_loss"):
                own.add("net")
            frame = [x for x in allv if x not in own]
            chk = "NetLossOK" if gd.get("writes_net_loss") else (f'NetOK("{g}")' if "net" in own else "TRUE")
            frame_s = f"UNCHANGED <<{', '.join(frame)}>>"
            src = strip_comments((SPEC / (vd["module"] + ".tla")).read_text())
            acts = parse_next(src)
            guard = f'Grain["{g}"] = "{v}"'
            if acts is None or vd.get("no_split"):
                name = f"Step_{g}_{v}"
                steps.append(name)
                L.append(f'{name} == /\\ {guard} /\\ {g}_{v}!Next')
                L.append(f"    /\\ {frame_s}")
                L.append(f'    /\\ Assert({chk}, "net discipline: {name}")')
                continue
            seen = {}
            for bnds, op, args in acts:
                n = seen.get(op, 0); seen[op] = n + 1
                name = f"Step_{g}_{v}_{op}" + (f"_{n}" if n else "")
                steps.append(name)
                call = f"{g}_{v}!{op}" + (f"({args})" if args is not None else "")
                # process-liveness guard of the group (registry "guard"): a dead process
                # takes no step, except the listed restart actions
                pg = (f' /\\ {gd["guard"]}' if gd.get("guard") and op not in gd.get("guard_except", []) else "")
                body = (f'/\\ {guard}{pg} /\\ {call} /\\ {frame_s}'
                        f' /\\ Assert({chk}, "net discipline: {name}")')
                q = "".join(f"\\E {b.strip()} : " for b in bnds)
                L.append(f"{name} == {q}({body})")
    L.append("")
    L.append("Next == " + ("\n    \\/ ".join(steps) if steps else "FALSE"))
    L.append("Spec == Init /\\ [][Next]_allVars")
    # finite-instance bound hooks: a module may define AtBound (blocked only by a
    # model bound); the deadlock / quiescence checks treat such states as bounded out.
    hooks = []
    for g, gd in reg["groups"].items():
        for v, vd in gd["variants"].items():
            src = strip_comments((SPEC / (vd["module"] + ".tla")).read_text())
            if re.search(r"^AtBound\s*==", src, flags=re.M):
                hooks.append(f'(Grain["{g}"] = "{v}" /\\ {g}_{v}!AtBound)')
    L.append("AtBoundAny == " + (" \\/ ".join(hooks) if hooks else "FALSE"))
    L.append("")
    L.append("\\* Port projection of a group: its port variable and the messages it sent.")
    L.append("SentKinds(ks) == {net[k].msg : k \\in {k2 \\in DOMAIN net : net[k2].msg.kind \\in ks}}")
    for g, gd in reg["groups"].items():
        if not gd["kinds"] and not gd["port"]:
            continue
        ks = "{" + ", ".join(f'"{k}"' for k in gd["kinds"]) + "}"
        port = gd["port"] if gd["port"] else "<<>>"
        L.append(f"Proj_{g} == <<{port}, SentKinds({ks})>>")
    L.append("=" * 77)
    out = Path(os.environ.get("MIX_BUILD") or SPEC)
    out.mkdir(parents=True, exist_ok=True)
    (out / "Mix.tla").write_text("\n".join(L) + "\n")


def main():
    reg = load()
    errs = static_check(reg)
    for w in WARNINGS:
        print("STATIC-CHECK WARNING (will become an error):", w)
    for e in errs:
        print("STATIC-CHECK ERROR:", e)
    if errs:
        sys.exit(1)
    print("static checks passed for",
          sum(len(gd["variants"]) for gd in reg["groups"].values()), "variants")
    if "--check-only" not in sys.argv:
        gen_mix(reg)
        print("wrote", Path(os.environ.get("MIX_BUILD") or SPEC) / "Mix.tla")


if __name__ == "__main__":
    main()
