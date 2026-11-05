#!/usr/bin/env python3
"""Summarize a TLC counterexample from logs/NAME.log: one line per step with the
action (module!operator) and the top-level variables it changed; with -v also
prints changed sub-fields (diff of TLA+ value text by top-level record key).

ce.py NAME [-v] [--vars v1,v2]
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def states(text):
    i = text.find("Error: The behavior up to this point is:")
    if i < 0:
        return []
    body = text[i:]
    parts = re.split(r"\n(?=State \d+: )", body)[1:]
    out = []
    for p in parts:
        head, _, rest = p.partition("\n")
        m = re.match(r"State (\d+): <(\w+)(?:\(([^)]*)\))? line \d+, col \d+ to line \d+, col \d+ of module (\w+)>", head)
        act = (m.group(4) + "!" + m.group(2) + ("(" + m.group(3) + ")" if m.group(3) else "")) if m else head.strip()
        vals = {}
        cur = None
        for line in rest.splitlines():
            mm = re.match(r"^/\\ (\w+) = (.*)$", line)
            if mm:
                cur = mm.group(1); vals[cur] = mm.group(2)
            elif cur and line.strip() and not line.startswith("State"):
                vals[cur] += " " + line.strip()
            if line.startswith("Error") or line.startswith("The number"):
                break
        out.append((act, vals))
    return out


def split_top(v):
    """split a TLA record/function text into top-level 'k |-> v' chunks."""
    v = v.strip()
    if not (v.startswith("[") and v.endswith("]")):
        return {"": v}
    inner = v[1:-1]
    depth = 0; cur = ""; chunks = []
    for ch in inner:
        if ch in "[(<{":
            depth += 1
        elif ch in "])>}":
            depth -= 1
        if ch == "," and depth == 0:
            chunks.append(cur); cur = ""
        else:
            cur += ch
    chunks.append(cur)
    d = {}
    for c in chunks:
        if "|->" in c:
            k, _, val = c.partition("|->")
            d[k.strip()] = val.strip()
        else:
            d[c.strip()] = ""
    return d


def main():
    name = sys.argv[1]
    verbose = "-v" in sys.argv
    only = None
    if "--vars" in sys.argv:
        only = set(sys.argv[sys.argv.index("--vars") + 1].split(","))
    text = (ROOT / "logs" / f"{name}.log").read_text()
    m = re.search(r"Invariant (\w+) is violated|Action property (\w+)|Temporal properties", text)
    print("violation:", m.group(0) if m else "?")
    st = states(text)
    prev = None
    for i, (act, vals) in enumerate(st, 1):
        changed = [k for k in vals if prev is None or prev.get(k) != vals[k]] if prev else []
        if only:
            changed = [k for k in changed if k in only]
        print(f"{i:3d} {act}  {' '.join(changed)}")
        if verbose and prev:
            for k in changed:
                a, b = split_top(prev[k]), split_top(vals[k])
                for kk in b:
                    if a.get(kk) != b[kk]:
                        print(f"      {k}.{kk}: {a.get(kk)} -> {b[kk]}"[:400])
        prev = vals


if __name__ == "__main__":
    main()
