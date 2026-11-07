#!/usr/bin/env python3
"""Rarity pricing of mix steps (bounded rare-event budget) and the costed mix
root spec/MixR.tla.

rarity.py [--report]

Cost of one step (weights in spec/rarity.json, ~ -log10 likelihood of one
occurrence; a path's total approximates -log(probability)):
  static   the action is GATED by priced faults: a top-level conjunct
           `"f" \\in Faults` / `Faults \\cap {..} /= {}` (cheapest listed);
  dynamic  the action mentions Faults (directly or through operators of its
           module / the Ports modules) without a top-level gate, i.e. a fault
           only WIDENS what it may do (coarse actions, timing-assumption
           escapes such as `"slowSJTeardown" \\in Faults \\/ TimingOK`). The
           step is charged iff the same transition is NOT allowed with the
           priced faults removed:  IF G_V__N!A(args) THEN 0 ELSE w, where
           G_V__N is the variant instantiated WITH Faults <- NormalFaults;
  0        otherwise.
rarity.json "actions" {"G_V.Action": n} overrides a step's cost (static).

spec/MixR.tla (EXTENDS Mix): VARIABLE rare, CONSTANT RareBudget,
  RStep_X == Step_X's text with /\\ rare' = rare + cost /\\ rare' <= RareBudget
  (FStep_X: the same without the budget), RNext == \\/ RStep_X,
  RInit == Init /\\ rare = 0,
  OverBudget: some PRICED step would exceed the budget (deadlock checks treat
  such states as "bounded", not as hangs).
Also writes spec/step_costs.json. MIX_SPEC honored.
"""
import json, os, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = Path(os.environ.get("MIX_SPEC") or ROOT / "spec")

FAULT1 = re.compile(r'"(\w+)"\s*\\in\s*Faults')
# timing guards (spec/Timing.tla): TimingOK(Faults, "escape", holds) widens an
# action by the escape; seen for dynamic pricing only (not a static gate)
TIMINGOK = re.compile(r'TimingOK\(\s*Faults\s*,\s*"(\w+)"')
FAULTSET = re.compile(r'(?:Faults\s*\\cap\s*\{([^}]*)\}|\{([^}]*)\}\s*\\cap\s*Faults)\s*/=\s*\{\}')
PORT_MODULES = ["Consts", "Timing", "PortsJob", "PortsFed", "PortsPay", "PortsTrn", "PortsReg", "Ports"]


def bodies(text):
    """name -> body text (comments dropped) of every top-level definition."""
    out = {}
    lines = text.splitlines()
    starts = [(i, m.group(1)) for i, l in enumerate(lines)
              if (m := re.match(r"^(\w+)(?:\([^)]*\))?\s*==", l))]
    for k, (i, name) in enumerate(starts):
        j = starts[k + 1][0] if k + 1 < len(starts) else len(lines)
        body = [re.sub(r"\\\*.*$", "", l) for l in lines[i:j]]
        out[name] = "\n".join(l for l in body if l.strip())
    return out


def fault_names(text):
    names = set(FAULT1.findall(text)) | set(TIMINGOK.findall(text))
    for m in FAULTSET.finditer(text):
        names |= set(re.findall(r'"(\w+)"', m.group(1) or m.group(2)))
    return names


def closure(defs):
    """name -> set of fault names it may depend on (None entry '?' = Faults used
    without a literal name). Transitive over the given definitions."""
    direct = {}
    for n, b in defs.items():
        rhs = b.split("==", 1)[1] if "==" in b else b
        s = fault_names(rhs)
        if re.search(r"\bFaults\b", rhs) and not s:
            s = {"?"}
        direct[n] = s
    refs = {n: {m for m in defs if m != n and re.search(r"\b" + m + r"\b", b.split("==", 1)[-1])}
            for n, b in defs.items()}
    out = {n: set(s) for n, s in direct.items()}
    changed = True
    while changed:
        changed = False
        for n in out:
            for m in refs[n]:
                if not out[m] <= out[n]:
                    out[n] |= out[m]; changed = True
    return out


def top_conjuncts(body):
    lines = body.splitlines()
    ind = [len(l) - len(l.lstrip()) for l in lines[1:] if l.lstrip().startswith("/\\")]
    if not ind:
        return [lines[0]] if lines else []
    m = min(ind)
    return [lines[0]] + [l for l in lines[1:]
                         if l.lstrip().startswith("/\\") and len(l) - len(l.lstrip()) == m]


def depth0(s):
    """s with every parenthesized / braced / bracketed part blanked out."""
    out, d = [], 0
    for ch in s:
        if ch in "([{":
            d += 1; out.append(" "); continue
        if ch in ")]}":
            d -= 1; out.append(" "); continue
        out.append(ch if d == 0 else " ")
    return "".join(out)


def gate_cost(line, w):
    """Cost of the faults that a top-level conjunct line GATES: the line must
    be a pure conjunction chain at depth 0 (no \\/, IF, =>, quantifier); each
    chain term `"f" \\in Faults` / `Faults \\cap {..} /= {}` is a gate."""
    s = line.strip()
    s = s[2:].strip() if s.startswith("/\\") else s.split("==", 1)[-1].strip()
    flat = depth0(s)
    if re.search(r"\\/|=>|\bIF\b|\bLET\b|\\E\b|\\A\b|\bCASE\b", flat):
        return 0
    cs = [w.get(f, w["_default"]) for f in FAULT1.findall(s)]
    for m in FAULTSET.finditer(s):
        names = re.findall(r'"(\w+)"', m.group(1) or m.group(2))
        if names:
            cs.append(min(w.get(f, w["_default"]) for f in names))
    return sum(cs)


def price(spec=SPEC):
    cfg = json.loads((spec / "rarity.json").read_text())
    w = dict(cfg["weights"]); w.setdefault("_default", 1)
    over = cfg.get("actions", {})
    priced = sorted(f for f, v in w.items() if f != "_default" and v > 0)
    mix = (spec / "Mix.tla").read_text()
    steps = re.findall(r"^(Step_(\w+?)_([A-Z][A-Za-z]*?)_(\w+)) == (.*)$", mix, flags=re.M)
    port_defs = {}
    for pm in PORT_MODULES:
        p = spec / f"{pm}.tla"
        if p.exists():
            port_defs.update(bodies(p.read_text()))
    mods, clos = {}, {}
    info = {}
    for full, g, v, act, text in steps:
        mod = f"{g}_{v}"
        if mod not in mods:
            p = spec / f"{mod}.tla"
            mods[mod] = bodies(p.read_text()) if p.exists() else {}
            clos[mod] = closure({**port_defs, **mods[mod]})
        b = mods[mod].get(act, "")
        key = f"{mod}.{act}"
        call = re.search(r"\b" + mod + "!" + act + r"(\((?:[^()]|\([^()]*\))*\))?", text)
        args = call.group(1) or "" if call else ""
        if key in over:
            info[full] = dict(kind="override", cost=over[key], mod=mod, act=act, args=args)
            continue
        c = sum(gate_cost(l, w) for l in top_conjuncts(b))
        if c:
            info[full] = dict(kind="static", cost=c, mod=mod, act=act, args=args)
            continue
        dep = clos[mod].get(act, set())
        named = {f for f in dep if f != "?"}
        if dep and (not named or named & set(priced)):
            wc = min([w.get(f, w["_default"]) for f in named if w.get(f, w["_default"]) > 0] or [w["_default"]])
            info[full] = dict(kind="dynamic", cost=wc, mod=mod, act=act, args=args, faults=sorted(dep))
        else:
            info[full] = dict(kind="zero", cost=0, mod=mod, act=act, args=args)
    return info, priced, steps


def write_mixr(spec=SPEC):
    info, priced, steps = price(spec)
    dyn_mods = sorted({i["mod"] for i in info.values() if i["kind"] == "dynamic"})
    L = ["---------------------------- MODULE MixR ----------------------------",
         "\\* GENERATED by scripts/rarity.py from Mix.tla + rarity.json: the mix with a",
         "\\* bounded rare-event budget. Do not edit.",
         "EXTENDS Mix",
         "CONSTANT RareBudget",
         "VARIABLE rare",
         "PricedFaults == {" + ", ".join(f'"{f}"' for f in priced) + "}",
         "NormalFaults == Faults \\ PricedFaults"]
    L += [f"{m}__N == INSTANCE {m} WITH Faults <- NormalFaults" for m in dyn_mods]
    names, pricedsteps = [], []
    for full, g, v, act, text in steps:
        i = info[full]
        if i["kind"] == "dynamic":
            cost = f"(IF {i['mod']}__N!{i['act']}{i['args']} THEN 0 ELSE {i['cost']})"
        else:
            cost = str(i["cost"])
        assert text.rstrip().endswith(")"), full
        head = text.rstrip()[:-1]
        if cost == "0":
            L.append(f"R{full} == {head} /\\ rare' = rare)")
        else:
            # budgeted step (named, so counterexamples show the action) and its
            # unbudgeted twin used only by OverBudget
            L.append(f"R{full} == {head} /\\ rare' = rare + {cost} /\\ rare' <= RareBudget)")
            L.append(f"F{full} == {head} /\\ rare' = rare + {cost})")
            pricedsteps.append("F" + full)
        names.append("R" + full)
    L.append("RNext == " + "\n    \\/ ".join(names))
    L.append("RInit == Init /\\ rare = 0")
    L.append("FPriced == " + ("\n    \\/ ".join(pricedsteps) if pricedsteps else "FALSE"))
    L.append("\\* some priced step is enabled but over budget: a bounded state, not a hang")
    L.append("OverBudget == ENABLED (FPriced /\\ rare' > RareBudget)")
    L.append("=" * 77)
    (spec / "MixR.tla").write_text("\n".join(L) + "\n")
    (spec / "step_costs.json").write_text(json.dumps(info, indent=1))
    return info


if __name__ == "__main__":
    info = write_mixr()
    if "--report" in sys.argv:
        for k in ("static", "override", "dynamic"):
            xs = sorted((s, i) for s, i in info.items() if i["kind"] == k)
            print(f"{k}: {len(xs)}")
            for s, i in xs:
                print(f"  {i['cost']}  {s}" + (f"  {i.get('faults')}" if k == "dynamic" else ""))
        print(f"zero: {sum(1 for i in info.values() if i['kind'] == 'zero')} / {len(info)} steps")
