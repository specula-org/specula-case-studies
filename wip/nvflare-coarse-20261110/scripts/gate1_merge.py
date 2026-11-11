#!/usr/bin/env python3
"""Gate-1 final cell set: pass A results, overridden by pass B (and its reruns) for the cells
pass B ran; pass A's all-kinds netLoss cells are replaced by the per-channel cells (STANDARD 12).
gate1_merge.py A.jsonl B.jsonl [B2.jsonl ...] -> checks/sweep/g1_final.jsonl and a summary"""
import json, sys
from collections import Counter
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
key = lambda r: r["name"].split("_", 1)[1]
fin = {}
A = [json.loads(l) for l in open(sys.argv[1])]
for r in A:
    if "netLoss" in r["point"].split("__"):
        continue
    fin[key(r)] = dict(r, src="A")
for f in sys.argv[2:]:
    for l in open(f):
        r = json.loads(l)
        if r.get("result") == "error":
            continue
        fin[key(r)] = dict(r, src=Path(f).stem)
out = ROOT / "checks" / "sweep" / "g1_final.jsonl"
out.write_text("".join(json.dumps(r) + "\n" for r in fin.values()))
c = Counter(r["result"] for r in fin.values())
n = len(fin)
print(n, dict(c), "stopped %.1f%%" % (100 * c["budget_stopped"] / n))
print("by source", Counter(r["src"] for r in fin.values()))
print("by kind", {k: (sum(1 for r in fin.values() if r["kind"] == k and r["result"] == "budget_stopped"),
                      sum(1 for r in fin.values() if r["kind"] == k)) for k in ("single", "pair")})
