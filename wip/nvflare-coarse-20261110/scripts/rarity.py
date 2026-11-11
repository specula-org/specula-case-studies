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
PORT_MODULES = ["Consts", "Timing", "PortsJob", "PortsFed", "PortsPay", "PortsTrn", "PortsReg", "PortsWrk", "PortsModel", "PortsSwarm", "Ports"]


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


def gate_names(line):
    """fault names a top-level conjunct line gates (same rule as gate_cost)."""
    s = line.strip()
    s = s[2:].strip() if s.startswith("/\\") else s.split("==", 1)[-1].strip()
    if re.search(r"\\/|=>|\bIF\b|\bLET\b|\\E\b|\\A\b|\bCASE\b", depth0(s)):
        return set()
    out = set(FAULT1.findall(s))
    for m in FAULTSET.finditer(s):
        out |= set(re.findall(r'"(\w+)"', m.group(1) or m.group(2)))
    return out


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
            gates = set().union(*[gate_names(l) for l in top_conjuncts(b)])
            info[full] = dict(kind="static", cost=c, mod=mod, act=act, args=args, faults=sorted(gates))
            continue
        dep = clos[mod].get(act, set())
        named = {f for f in dep if f != "?"}
        if dep and (not named or named & set(priced)):
            wc = min([w.get(f, w["_default"]) for f in named if w.get(f, w["_default"]) > 0] or [w["_default"]])
            info[full] = dict(kind="dynamic", cost=wc, mod=mod, act=act, args=args, faults=sorted(dep))
        else:
            info[full] = dict(kind="zero", cost=0, mod=mod, act=act, args=args)
    return info, priced, steps


def _tset(xs):
    return "{" + ", ".join(f'"{f}"' for f in sorted(xs)) + "}"


def write_mixr(spec=SPEC):
    """MixR: Mix with a rare-event budget.
    rare: total price paid on the path; paid: the faults already paid for.
    STANDARD 6 (v4) price dedup: a static step (the fault's occurrence, gated by it) is
    charged every time and marks its faults paid; a dynamic step (a fault only widens
    what it may do: a consequence) is free if the transition is allowed without priced
    faults, or if one of the faults that widen it was already paid on this path.
    """
    info, priced, steps = price(spec)
    dyn_mods = sorted({i["mod"] for i in info.values() if i["kind"] == "dynamic"})
    L = ["---------------------------- MODULE MixR ----------------------------",
         "\\* GENERATED by scripts/rarity.py from Mix.tla + rarity.json: the mix with a",
         "\\* bounded rare-event budget and price dedup. Do not edit.",
         "EXTENDS Mix, JobPhase",
         "CONSTANT RareBudget, FaultPhases",
         "VARIABLE rare, paid",
         "\\* a sweep cell's fault occurs first in its lifecycle phase window (JobPhase in",
         "\\* FaultPhases); its consequences, and later occurrences, are unrestricted",
         "InWindow == JobPhase \\in FaultPhases",
         "MaxFaultPhase == CHOOSE p \\in FaultPhases : \\A q \\in FaultPhases : q <= p",
         "\\* no fault yet and the window has passed: nothing of this cell can happen any more",
         "WindowCon == paid /= {} \\/ JobPhase <= MaxFaultPhase",
         "PricedFaults == " + _tset(priced),
         "NormalFaults == Faults \\ PricedFaults"]
    L += [f"{m}__N == INSTANCE {m} WITH Faults <- NormalFaults" for m in dyn_mods]
    names, pricedsteps, bygroup = [], [], {}
    for full, g, v, act, text in steps:
        i = info[full]
        assert text.rstrip().endswith(")"), full
        head = text.rstrip()[:-1]
        if i["kind"] == "dynamic":
            D = _tset(f for f in i.get("faults", []) if f != "?") if [f for f in i.get("faults", []) if f != "?"] else "PricedFaults"
            use = f"({D} \\cap Faults /= {{}} /\\ ~{i['mod']}__N!{i['act']}{i['args']})"
            tail = (f" /\\ LET u == {use} IN LET dc == (IF u /\\ {D} \\cap Faults \\cap paid = {{}} THEN {i['cost']} ELSE 0) IN"
                    f" ((u /\\ paid = {{}}) => InWindow) /\\"
                    f" (rare' = rare + dc /\\ paid' = (IF u THEN paid \\cup ({D} \\cap Faults) ELSE paid)")
            L.append(f"R{full} == {head}{tail} /\\ rare' <= RareBudget))")
            L.append(f"F{full} == {head}{tail}))")
            pricedsteps.append("F" + full)
        elif i["cost"]:
            G = _tset(i.get("faults", []))
            tail = f" /\\ (paid = {{}} => InWindow) /\\ rare' = rare + {i['cost']} /\\ paid' = paid \\cup ({G} \\cap Faults)"
            L.append(f"R{full} == {head}{tail} /\\ rare' <= RareBudget)")
            L.append(f"F{full} == {head}{tail})")
            pricedsteps.append("F" + full)
        else:
            L.append(f"R{full} == {head} /\\ rare' = rare /\\ paid' = paid)")
        names.append("R" + full)
        bygroup.setdefault(g, []).append("R" + full)
    L.append("RNext == " + "\n    \\/ ".join(names))
    for g, ns in bygroup.items():
        L.append(f"RNext_{g} == " + "\n    \\/ ".join(ns))
    # Quiescence (STANDARD 7): every step with the fault set replaced by the default
    # timers; Q == ~ENABLED QNext. Only enabledness matters, so the frame and the net
    # discipline assertion are left out of the Q steps.
    cfg = json.loads((spec / "rarity.json").read_text())
    L.append("DefaultTimers == " + _tset(cfg.get("default_timers", [])))
    L.append("QFaults == (Faults \\ PricedFaults) \\cup DefaultTimers")
    qmods = sorted({f"{g}_{v}" for _, g, v, _, _ in steps})
    L += [f"{m}__Q == INSTANCE {m} WITH Faults <- QFaults" for m in qmods]
    qn = []
    for full, g, v, act, text in steps:
        mod = f"{g}_{v}"
        t = re.sub(r"\s*/\\ UNCHANGED <<[^>]*>>", "", text)
        t = re.sub(r'\s*/\\ Assert\(.*?, "net discipline: [^"]*"\)', "", t)
        L.append(f"Q{full} == " + t.replace(f"{mod}!", f"{mod}__Q!"))
        qn.append("Q" + full)
    L.append("QNext == " + "\n    \\/ ".join(qn))
    L.append("RInit == Init /\\ rare = 0 /\\ paid = {}")
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
