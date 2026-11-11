#!/usr/bin/env python3
"""Gate-1 recall: map triaged mechanisms (item | cause records) to the remix root causes.
The table below is the triage attribution (it reads the CEs' cause records); it is not
used by the sweep. recall.py TRIAGE.jsonl [...] -> prints the recall table (markdown)."""
import json, sys
from collections import defaultdict

# root cause -> (tier, list of (item, required cause substrings))
RC = {
    "R2":   (1, [("Q1c", ["unmatched"])]),
    "R1":   (1, [("Q1c", ["staleBy=JobSP.proc.SP"])]),
    "H08":  (1, [("S3Gpu", ["gpuBy=JobCP.res.gpuEnv"]), ("S3J2Gpu", ["gpuBy=JobCP.res.gpuEnv"])]),
    "T1":   (1, [("S1Sched", ["schedulerCrashed=JobSP.sched.scan"])]),
    "T1-b": (1, [("S1Sched", ["schedulerCrashed=JobSP.runner.except"])]),
    "H11":  (1, [("S1Monitor", ["monitorCrashed=CommSJ.wfc.resendDup"])]),
    "S1":   (2, [(None, ["stopSkipped=JobSP.admin.shutdownLoop"])]),
    "S4":   (2, [(None, ["lateStart=JobSP.state.askToStop"])]),
    "V7":   (2, [("Q2c", ["allocLost=JobCP.container.lifetime"])]),
    "H06":  (2, [("S7StopHasSource", ["stopBy=event"])]),
    "H05":  (2, [("S4Gather", ["raced"])]),
    "C1-A": (3, [("S2", ["overwrite=JobSP.runner.except"])]),
    "C1-B": (3, [("S1Compl", ["completionCrashed=JobSP.complete.del"])]),
    "T2":   (3, [("S1Cleanup", ["cleanupCrashed=Reg.cleanup.logoutNone"])]),
    "T3":   (3, [("S1Cleanup", ["cleanupCrashed=Reg.cleanup.notifyIterate"])]),
    "L13":  (3, [("S4CompletedWf", ["exitObs=JobSP.engine.waiter"])]),
    "N2":   (3, [("Q2c", ["panicBy=CommSJ.wfc.deadClients"])]),
    "H03":  (3, [("S8LossNotified", ["staleStop"])]),
    "H01":  (3, [("S6AckMeansDone", ["ackInferred"])]),
    "H07":  (3, [("S4OutputsDelivered", ["wsRemovedBy=JobCP.k8s.publish"])]),
    "H04":  (3, [("S4Artifact", ["poisoned"])]),
}


def match(x, item, need):
    # a Q item that failed but was exempted by a filter still identifies the mechanism
    its = [x["item"]] + (x.get("allq") or [])
    return (item is None or item in its) and all(any(n in c for c in x["causes"]) for n in need) \
        and not x.get("qspurious")


def main():
    xs = []
    for f in sys.argv[1:]:
        xs += [json.loads(l) for l in open(f)]
    rows = []
    found = defaultdict(list)
    for rc, (tier, sigs) in RC.items():
        hits = [x for x in xs if any(match(x, it, nd) for it, nd in sigs)]
        found[rc] = hits
    attributed = set()
    for rc, hits in found.items():
        for h in hits:
            attributed.add(h["name"])
    for rc, (tier, _) in RC.items():
        hits = found[rc]
        if hits:
            b = min(hits, key=lambda h: (h["weight"], h["depth"]))
            rows.append(f"| {tier} | {rc} | {len(hits)} | `{b['name'].split('_', 1)[1]}`, {b['item']}, depth {b['depth']}, "
                        f"w{b['weight']} {b['tier']}{' (sim)' if b.get('sim') else ''} | {', '.join(b['causes'])} |")
        else:
            rows.append(f"| {tier} | {rc} | 0 | - | - |")
    print("| tier | root cause | CE cells | best (cell, item, depth, weight) | cause records |")
    print("|---|---|---:|---|---|")
    print("\n".join(rows))
    other = defaultdict(list)
    for x in xs:
        if x["name"] not in attributed:
            other[x["mech"]].append(x)
    print("\nunattributed mechanisms:")
    for m, hs in sorted(other.items(), key=lambda kv: -len(kv[1])):
        b = min(hs, key=lambda h: (h["weight"], h["depth"]))
        print(f"  {len(hs):4d}  {m}  e.g. {b['name']} d{b['depth']} w{b['weight']} {b['severity']}")
    t1 = [rc for rc, (t, _) in RC.items() if t == 1 and found[rc]]
    t2 = [rc for rc, (t, _) in RC.items() if t == 2 and found[rc]]
    print(f"\ntier 1: {len(t1)}/6 {t1}; tier 2: {len(t2)}/5 {t2}")


if __name__ == "__main__":
    main()
