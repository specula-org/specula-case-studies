#!/usr/bin/env python3
"""Summarize hunt4 (+ parallel BFS share, re-runs): per track result counts,
simulation traces / mean length, BFS distinct states."""
import json, collections, re
from pathlib import Path
W = Path(__file__).resolve().parents[1]
rows = []
for tag in ("hunt4", "hunt4p", "rerun4"):
    p = W / "checks" / "sweeps" / f"{tag}.jsonl"
    if p.exists():
        for l in p.read_text().splitlines():
            r = json.loads(l); r["_tag"] = tag; rows.append(r)
# a superseded run (error, or stopped as a duplicate) is replaced by its *_rr / *_p twin
names = {r["name"] for r in rows}
final = [r for r in rows if not (r.get("result") in ("error", "incomplete") and
                                 (r["name"] + "_rr" in names or r["name"] + "_p" in names))]
def bfs_distinct(r):
    if r.get("distinct") or r.get("distinct_at_stop"):
        return r.get("distinct") or r.get("distinct_at_stop")
    lg = W / "logs" / f"{r['name']}.log"
    m = re.findall(r"([\d,]+) distinct states found", lg.read_text()) if lg.exists() else []
    return int(m[-1].replace(",", "")) if m else 0
by = collections.defaultdict(list)
for r in final:
    by[r.get("track", "?")].append(r)
tot_tr = tot_ds = 0
print("| track | runs | budget_stopped | violation | error/other | sim traces | sim states | BFS distinct |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for t in sorted(by):
    rs = by[t]
    c = collections.Counter(r.get("result") for r in rs)
    tr = sum(r.get("traces") or 0 for r in rs)
    ml = [r["trace_mean"] for r in rs if r.get("trace_mean")]
    ds = sum(bfs_distinct(r) for r in rs if r.get("mode") == "bfs")
    tot_tr += tr; tot_ds += ds
    other = len(rs) - c["budget_stopped"] - c["violation"]
    print(f"| {t} | {len(rs)} | {c['budget_stopped']} | {c['violation']} | {other} | "
          f"{tr:,} | {sum(r.get('sim_states') or 0 for r in rs):,} | {ds:,} |")
print(f"\ntotal final runs {len(final)}; traces {tot_tr:,}; BFS distinct {tot_ds:,}; "
      f"run-hours {sum(r.get('wall_seconds', 0) for r in rows)/3600:.1f}")
print("\nviolations / errors in final set:")
for r in final:
    if r.get("result") not in ("budget_stopped",):
        print(" ", r["name"], r.get("result"), r.get("violated"))
