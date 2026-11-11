#!/usr/bin/env python3
"""Build notes/ledger.csv from notes/ledger.d/*.py and check it against the spec
(STANDARD.md section 10).

ledger.py build      write notes/ledger.csv
ledger.py annotate   insert/refresh `\\* @L <ids>` above every action definition
ledger.py check      every Next action is annotated with ledger ids that exist;
                     every modeled row's actions exist; no finding ids in spec/
"""
import csv, re, runpy, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SPEC = Path(__import__("os").environ.get("MIX_SPEC") or (ROOT / "spec"))
COLS = ["id", "file_line", "unit_type", "group", "outcomes", "reasons", "effects", "status", "actions",
        "lifetime", "sharing"]
FINDING = re.compile(r"\b(H\d\d|C1-?[AB]?|T[1-4](-b)?|R[12]|L\d{1,2}|N[12]|S\d{1,2}|V\d|K\d{1,2}|X[12])\b|#\d{3,5}")


def rows():
    out = []
    for f in sorted((ROOT / "notes" / "ledger.d").glob("*.py")):
        for r in runpy.run_path(str(f))["ROWS"]:
            assert len(r) == len(COLS), (f.name, r[0], len(r))
            out.append(dict(zip(COLS, r)))
    ids = [r["id"] for r in out]
    dup = {i for i in ids if ids.count(i) > 1}
    assert not dup, f"duplicate ids {dup}"
    return out


def actions_of_module(mod):
    sys.path.insert(0, str(ROOT / "scripts"))
    import gen_mix
    src = gen_mix.strip_comments((SPEC / f"{mod}.tla").read_text())
    return [op for _, op, _ in (gen_mix.parse_next(src) or [])]


def modules():
    import json
    reg = json.loads((SPEC / "registry.json").read_text())
    mods = [vd["module"] for gd in reg["groups"].values() for vd in gd["variants"].values()]
    for f in sorted((SPEC / "registry.d").glob("*.json")):
        for gd in json.loads(f.read_text())["groups"].values():
            mods += [vd["module"] for vd in gd["variants"].values()]
    return mods


def amap(rs):
    m = {}
    for r in rs:
        for a in [x for x in r["actions"].split(";") if x]:
            m.setdefault(a, []).append(r["id"])
    return m


def build():
    rs = rows()
    with (ROOT / "notes" / "ledger.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=COLS); w.writeheader(); w.writerows(rs)
    print(f"wrote notes/ledger.csv: {len(rs)} rows")


def annotate():
    m = amap(rows())
    for mod in modules():
        p = SPEC / f"{mod}.tla"
        lines = [l for l in p.read_text().splitlines() if not l.startswith("\\* @L ")]
        out = []
        for l in lines:
            mm = re.match(r"^(\w+)(\(.*\))?\s*==", l)
            if mm and f"{mod}!{mm.group(1)}" in m:
                out.append("\\* @L " + ", ".join(m[f"{mod}!{mm.group(1)}"]))
            out.append(l)
        p.write_text("\n".join(out) + "\n")
    print("annotated")


def check():
    rs = rows(); ids = {r["id"] for r in rs}; errs = []
    m = amap(rs)
    for mod in modules():
        text = (SPEC / f"{mod}.tla").read_text()
        for op in dict.fromkeys(actions_of_module(mod)):
            mm = re.search(r"^\\\* @L ([^\n]*)\n" + re.escape(op) + r"(\(.*\))?\s*==", text, flags=re.M)
            if not mm:
                errs.append(f"{mod}!{op}: no @L annotation")
                continue
            for i in [x.strip() for x in mm.group(1).split(",")]:
                if i not in ids:
                    errs.append(f"{mod}!{op}: unknown ledger id {i}")
    for a in m:
        mod, op = a.split("!")
        if (SPEC / f"{mod}.tla").exists() and op not in actions_of_module(mod):
            errs.append(f"ledger maps {a} but {mod} has no such action in Next")
    for f in sorted(SPEC.glob("*.tla")):
        if f.name in ("Mix.tla", "MixR.tla"):
            continue
        for i, l in enumerate(f.read_text().splitlines(), 1):
            if "\\*" in l and FINDING.search(l[l.index("\\*"):]):
                errs.append(f"{f.name}:{i}: finding id in a comment: {l.strip()[:80]}")
    st = {}
    for r in rs:
        k = r["status"].split(":")[0]; st[k] = st.get(k, 0) + 1
    print("rows", len(rs), st, "| actions annotated:", sum(len(set(actions_of_module(x))) for x in modules()))
    for e in errs:
        print("LEDGER-CHECK:", e)
    return not errs


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "build": build()
    elif cmd == "annotate": annotate()
    elif cmd == "check": sys.exit(0 if check() else 1)
