#!/usr/bin/env python3
"""Triage of a sweep: one line per counterexample cell with the violated
property, the priced events on the path (and their total weight), the
likelihood tier, and a mechanism label from port evidence in the final states.
Labels name mechanisms (which operation failed, which status overwrote which),
not bugs; mapping labels to root causes is done by hand in RESULTS.md.

classify.py TAG [--md]   -> checks/sweep/TAG.triage.jsonl (and .triage.md)
"""
import json, re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import ce

COSTS = json.loads((ROOT / "spec" / "step_costs.json").read_text())
TIERS = json.loads((ROOT / "spec" / "rarity.json").read_text())["tiers"]


def tier(w):
    for name, (lo, hi) in TIERS.items():
        if lo <= w <= hi:
            return name
    return "?"


def field(rec, name):
    m = re.search(r"\b" + name + r' \|-> ("[^"]*"|TRUE|FALSE|\d+|\{[^}]*\})', rec)
    return m.group(1) if m else None


def label(prop, st):
    prop = prop[2:] if prop.startswith("F_") else prop
    if prop == "S2":
        prop = "S2TerminalFinal"
    last = st[-1][1]
    prev = st[-2][1] if len(st) > 1 else last
    sp = last.get("pJobSP", ""); cp = last.get("pJobCP", ""); reg = last.get("pReg", "")
    if prop == "S1ThreadsAlive":
        sc = field(sp, "schedulerCrashed")
        if sc and sc != '"no"':
            return "thread:scheduler@" + sc.strip('"')
        cc0 = field(sp, "completionCrashed")
        if cc0 and cc0 not in ('"no"', "FALSE"):
            return "thread:completion@" + cc0.strip('"')
        mc = field(last.get("pCommSJ", ""), "monitorCrashed")
        if mc and mc not in ('"no"', "FALSE"):
            return "thread:taskMonitor@" + mc.strip('"')
        cc = field(reg, "cleanupCrashed")
        if cc and cc != '"no"':
            return "thread:cleanup@" + cc.strip('"')
        return "thread:?"
    if prop in ("S2TerminalFinal", "F_S2"):
        a, b = field(prev.get("pJobSP", ""), "status"), field(sp, "status")
        return f"overwrite:{(a or '?').strip(chr(34))}->{(b or '?').strip(chr(34))}"
    if prop.endswith("Q1Terminal"):
        st_ = (field(sp, "status") or "?").strip('"')
        if field(sp, "spRestarted") == "TRUE":
            return f"hang:afterSPRestart:{st_}"
        if field(sp, "spDown") == "TRUE":
            return f"hang:afterSPShutdown:{st_}"
        if "cpRestarted |-> TRUE" in cp:
            return f"hang:afterCPRestart:{st_}"
        if field(sp, "other") in ('"queued"', '"running"', '"exited"'):
            return f"hang:otherJob:{field(sp, 'other')}"
        return f"hang:{st_}"
    if prop.endswith("Q2StatusAgrees"):
        return "status:completedWorkflow->" + (field(sp, "status") or "?").strip('"') + \
               (":afterCPRestart" if "cpRestarted |-> TRUE" in cp else "")
    if prop.endswith("S3Resources"):
        if re.search(r"gpu \|-> <<[^>]*2", cp) or re.search(r"gpu \|-> \(1 :> 2", cp):
            return "resource:usesOtherJobUnit"
        if re.search(r"j2 \|-> \[[^\]]*gpu \|-> 1", cp):
            return "resource:otherJobUsesOurUnit"
        if "allocated |-> FALSE" in cp:
            return "resource:liveWithoutAllocation" + (":afterCPRestart" if "cpRestarted |-> TRUE" in cp else "")
        return "resource:?"
    if prop.endswith("S4Completed"):
        if "artifact" in last.get("pModel", "") and re.search(r'kind \|-> "(poisoned|corrupt)"', last.get("pModel", "")):
            return "completed:badArtifact"
        if field(last.get("pWfSJ", ""), "panic") == "TRUE" or field(last.get("pCommSJ", ""), "panic") == "TRUE":
            return "completed:afterPanic"
        return "completed:workflowNotDone"
    if prop.endswith("S4NoLostResult"):
        return "lost:gatherAfterClose" if "gather" in last.get("pSwarm", "") else "lost:aggregate"
    if prop.endswith("S7StopHasSource"):
        m = re.search(r'stopBy \|-> "(\w+)"', last.get("pSwarm", "")) and re.findall(r'stopBy \|-> "(\w+)"', last.get("pSwarm", ""))
        return "stop:withoutRequest:" + ",".join(sorted(set(x for x in (m or []) if x not in ("none", "endRun", "endWf"))))
    if prop.endswith("S8LossNotified"):
        return "loss:sourceTornDownUnnotified"
    if prop.endswith("S4OutputsDelivered"):
        return "output:workspaceResultsNotReturned"
    if prop.endswith("S6AckMeansDone"):
        return "ack:successWithoutAcceptance"
    if prop.endswith("Q4NoOrphan"):
        return "orphan:" + ("SJ" if "sj |-> \"running\"" in last.get("pWfSJ", "") else "CJ")
    if prop.endswith("Q3Released"):
        return "release:allocationKept"
    if prop.endswith("S5StatusMeaning"):
        return "meaning:" + (field(sp, "status") or "?").strip('"')
    return prop


def main():
    tag = sys.argv[1]
    rows = [json.loads(l) for l in (ROOT / "checks" / "sweep" / f"{tag}.jsonl").read_text().splitlines()]
    out = []
    for r in rows:
        if r.get("result") not in ("violation", "violation_evalerror", "violation_sim"):
            continue
        text = (ROOT / "logs" / (f"{r['name']}_s.log" if r["result"] == "violation_sim" else f"{r['name']}.log")).read_text()
        st = ce.states(text)
        if not st and "is violated by the initial state" in text:
            # the checkpoint itself violates the property (reached by cost-0 steps)
            i = text.index("is violated by the initial state")
            st = ce.states("Error: The behavior up to this point is:\nState 1: <Initial predicate>\n"
                           + text[i:].split("\n", 1)[1])
        if not st:
            continue
        priced, w = [], 0
        acts = []
        prev_rare = int(st[0][1].get("rare", "0") or 0)
        for act, vals in st[1:]:
            a = re.sub(r"^R?Step_", "", act.split("!")[-1].split("(")[0])
            acts.append(a)
            rr = int(vals.get("rare", prev_rare))
            if rr > prev_rare:          # the step's actual price (dynamic steps cost 0 when allowed without faults)
                priced.append(f"{a}[{rr - prev_rare}]"); w += rr - prev_rare
            prev_rare = rr
        prop = r["violated"]
        out.append(dict(name=r["name"], config=r["config"], point=r["point"], phase=r["phase"], prop=prop,
                        label=label(prop, st), depth=len(st) - 1, weight=w, tier=tier(w), priced=priced,
                        wall=r.get("wall_seconds"), tail=acts[-6:]))
    p = ROOT / "checks" / "sweep" / f"{tag}.triage.jsonl"
    p.write_text("".join(json.dumps(x) + "\n" for x in out))
    if "--md" in sys.argv:
        from collections import defaultdict
        g = defaultdict(list)
        for x in out:
            g[(x["prop"], x["label"])].append(x)
        md = [f"# Triage {tag}", "", f"{len(out)} counterexample cells, {len(g)} (property, mechanism) groups", "",
              "| property | mechanism | cells | min depth | min weight (tier) | configs x points | example |", "|---|---|---:|---:|---|---|---|"]
        for (prop, lab), xs in sorted(g.items(), key=lambda kv: -len(kv[1])):
            best = min(xs, key=lambda x: (x["weight"], x["depth"]))
            cp = sorted({f"{x['config']}:{x['point']}" for x in xs})
            md.append(f"| {prop} | {lab} | {len(xs)} | {min(x['depth'] for x in xs)} | {best['weight']} ({best['tier']}) | "
                      f"{', '.join(cp[:8])}{' ...' if len(cp) > 8 else ''} | {best['name']} |")
        (ROOT / "checks" / "sweep" / f"{tag}.triage.md").write_text("\n".join(md) + "\n")
    print(len(out), "counterexamples")


if __name__ == "__main__":
    main()
