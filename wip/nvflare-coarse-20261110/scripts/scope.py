#!/usr/bin/env python3
"""Apply notes/scope_rules.py to every .py file of the pinned nvflare package.

scope.py  -> notes/scope.csv (file, lines, decision, label) and a per-decision summary
"""
import collections, csv, runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SRC = Path("/home/ubuntu/nvflare-integrated-model-20261103/sources/current/nvflare")


def files():
    return sorted(str(p.relative_to(SRC)) for p in SRC.rglob("*.py"))


def decide(f, rules, calib):
    if f in calib:
        return "calib", "calibration region (step 2)"
    for pre, dec, _ in rules:
        if f.startswith(pre):
            return dec, ""
    return "unassigned", ""


def table():
    sr = runpy.run_path(str(ROOT / "notes" / "scope_rules.py"))
    calib = {l.strip() for l in (ROOT / "notes" / "region-calib.txt").read_text().splitlines()
             if l.strip() and not l.startswith("#")}
    out = []
    for f in files():
        n = sum(1 for _ in open(SRC / f, errors="ignore"))
        d, _ = decide(f, sr["RULES"], calib)
        out.append(dict(file=f, lines=n, decision=d))
    return out, sr


def main():
    out, sr = table()
    with (ROOT / "notes" / "scope.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["file", "lines", "decision"]); w.writeheader(); w.writerows(out)
    agg = collections.defaultdict(lambda: [0, 0])
    for r in out:
        agg[r["decision"]][0] += r["lines"]; agg[r["decision"]][1] += 1
    for k in sorted(agg):
        print(f"{k:12s} {agg[k][0]:7d} lines {agg[k][1]:4d} files")
    print("total", sum(r["lines"] for r in out), len(out))


if __name__ == "__main__":
    main()
