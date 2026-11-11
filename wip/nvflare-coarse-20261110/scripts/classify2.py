#!/usr/bin/env python3
"""Triage for the v4 sweep (scripts/sweep2.py).

classify2.py TAG [TAG...] [--out NAME]
For every counterexample cell: the violated item (Q items are recomputed on the last
state from its ports), the cause records present in the last state (non-"none" ledger
ids, non-empty cause sets), the priced events (actual `rare` increments), likelihood
tier (STANDARD 6) and severity class (STANDARD 7). A mechanism = (item, cause records).
If NAME.qverify.jsonl exists (scripts/qverify2.py on a first triage), Q items come from it:
the first failing item its filter does not exempt; `allq` lists every failing Q item.
Writes checks/sweep/NAME.triage.jsonl and NAME.triage.md, ranked by severity then
likelihood.
"""
import json, re, sys
from pathlib import Path
from collections import defaultdict
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import ce

TIERS = json.loads(((Path(__import__("os").environ.get("MIX_SPEC") or (ROOT / "spec"))) / "rarity.json").read_text())["tiers"]
SEV = {"S1Sched": "server", "S1Compl": "server", "S1Cleanup": "server", "S1Monitor": "job",
       "S3Alloc": "job", "S3Gpu": "job", "S3J2Gpu": "job", "S3FreeOnce": "job",
       "S4Aggregate": "data", "S4Gather": "data", "S4Artifact": "data", "S4OutputsDelivered": "data",
       "S4CompletedWf": "status", "S5StatusMeaning": "status", "S6AckMeansDone": "status",
       "S7StopHasSource": "job", "S8LossNotified": "job",
       "Q1c": "job", "Q2c": "status", "Q3c": "job", "Q4c": "job", "S2": "status"}
SEVRANK = {"server": 0, "data": 1, "job": 2, "status": 3}
TIERRANK = {"high": 0, "medium": 1, "low": 2, "very_low": 3}
# cause records: (port variable, field, kind) -- kind "str": a ledger id unless none/no,
# "set": a non-empty set
CAUSES = [("pJobSP", f, "str") for f in ("schedulerCrashed", "completionCrashed", "overwrite", "staleBy", "exitObs",
                                         "termEarly", "unfinalized", "failBy", "stopSkipped", "lateStart", "exitUnseen")] + \
         [("pJobCP", f, "str") for f in ("freedBy", "endBy", "allocLost", "gpuBy", "wsRemovedBy", "orphanBy")] + \
         [("pWfSJ", "lateAccept", "str")] + \
         [("pCommSJ", "monitorCrashed", "str"), ("pCommSJ", "panicBy", "str"), ("pReg", "cleanupCrashed", "str"), ("pReg", "unmatched", "set"),
          ("pTrainer", "ackInferred", "set"), ("pTrainer", "staleStop", "set"), ("pSwarm", "stopBy", "str"),
          ("pSwarm", "raced", "set"), ("pModel", "poisoned", "set"),
          # chunk 1
          ("pReg", "dropped", "str"), ("pLogin", "connErr", "str")]


def tier(w):
    for name, (lo, hi) in TIERS.items():
        if lo <= w <= hi:
            return name
    return "?"


def causes(state):
    out = set()
    for var, f, kind in CAUSES:
        txt = state.get(var, "")
        if kind == "str":
            for v in re.findall(r"\b" + f + r' \|-> "([^"]*)"', txt):
                # endRun / endWf: stop requested by another unit; JobCP.exec.free: the normal free
                if v not in ("none", "no", "endRun", "endWf", "JobCP.exec.free"):
                    out.add(f"{f}={v}")
        else:
            for v in re.findall(r"\b" + f + r" \|-> \{([^}]*)\}", txt):
                if v.strip():
                    out.add(f"{f}")
    return sorted(out)


def q_item(state):
    """which Q item fails in the last state (port evidence)."""
    sp = state.get("pJobSP", "")
    st = re.search(r'status \|-> "(\w+)"', sp)
    st = st.group(1) if st else "?"
    term = st in ("ABORTED", "COMPLETED", "FAILED", "FAILED_TO_RUN", "CANT_SCHEDULE")
    if not term and "deleted |-> TRUE" not in sp:
        return "Q1c", st
    if re.search(r'other \|-> "(queued|running|exited)"', sp):
        return "Q1c", "otherJob"
    if "allocated |-> TRUE" in state.get("pJobCP", ""):
        return "Q3c", st
    if term and st != "COMPLETED":
        return "Q2c", st
    return "Q4c", st


def main():
    args = [x for x in sys.argv[1:] if not x.startswith("--")]
    outname = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else args[0]
    args = [x for x in args if x != outname] or [outname]
    out = []
    # exact Q items from a BFS re-check of the last state (scripts/qverify2.py), when present
    qv = {}
    qp = ROOT / "checks" / "sweep" / f"{outname}.qverify.jsonl"
    if qp.exists():
        qv = {q["name"]: q for q in map(json.loads, qp.read_text().splitlines())}
    for tag in args:
        for l in (ROOT / "checks" / "sweep" / f"{tag}.jsonl").read_text().splitlines():
            r = json.loads(l)
            if r.get("result") not in ("violation", "violation_evalerror", "violation_sim"):
                continue
            log = ROOT / "logs" / (f"{r['name']}_s.log" if r["result"] == "violation_sim" else f"{r['name']}.log")
            text = log.read_text()
            st = ce.states(text)
            if not st and "is violated by the initial state" in text:
                i = text.index("is violated by the initial state")
                st = ce.states("Error: The behavior up to this point is:\nState 1: <Initial predicate>\n" + text[i:].split("\n", 1)[1])
            if not st:
                continue
            item = r["violated"]
            item = item[2:] if item.startswith("I_") else item
            item = "S2" if item in ("S2F", "S2TerminalFinal") else item
            extra, allq, qspur = "", [], None
            if item == "Q":
                item, extra = q_item(st[-1][1])
                q = qv.get(r["name"])
                if q and q.get("items") is not None:
                    item = q["items"][0] if q["items"] else "Q?"
                    allq = q["allq"]
                    qspur = q["qen"] == "TRUE" or q["atbound"] == "TRUE"
            priced, w, prev = [], 0, int(st[0][1].get("rare", "0") or 0)
            prevpaid = set(re.findall(r'"(\w+)"', st[0][1].get("paid", "")))
            acts = []
            for i, (act, vals) in enumerate(st[1:], 2):
                a = re.sub(r"^R?Step_", "", act.split("!")[-1].split("(")[0]); acts.append(a)
                rr = int(vals.get("rare", prev) or prev)
                pd = set(re.findall(r'"(\w+)"', vals.get("paid", "")))
                if rr > prev:
                    priced.append(f"{','.join(sorted(pd - prevpaid)) or 'again'}@{i}[{rr - prev}]"); w += rr - prev
                prev, prevpaid = rr, pd
            cz = causes(st[-1][1])
            out.append(dict(tag=tag, name=r["name"], config=r["config"], kind=r.get("kind"), point=r["point"],
                            phase=r["phase"], item=item, detail=extra, causes=cz, mech=f"{item}|{','.join(cz) or '-'}",
                            severity=SEV.get(item, "?"), weight=w, tier=tier(w), depth=len(st) - 1, priced=priced,
                            sim=r["result"] == "violation_sim", tail=acts[-8:], wall=r.get("wall_seconds"),
                            allq=allq, qspurious=qspur))
    p = ROOT / "checks" / "sweep" / f"{outname}.triage.jsonl"
    p.write_text("".join(json.dumps(x) + "\n" for x in out))
    g = defaultdict(list)
    for x in out:
        g[x["mech"]].append(x)
    rows = []
    for mech, xs in g.items():
        best = min(xs, key=lambda x: (x["weight"], x["depth"]))
        rows.append((SEVRANK.get(best["severity"], 9), TIERRANK.get(best["tier"], 9), mech, xs, best))
    rows.sort(key=lambda r: (r[0], r[1], -len(r[3])))
    md = [f"# Triage {outname}", "", f"{len(out)} counterexample cells, {len(g)} mechanisms (item | cause records)", "",
          "| severity | likelihood (w) | item | cause records | cells | min depth | example | priced |", "|---|---|---|---|---:|---:|---|---|"]
    for _, _, mech, xs, b in rows:
        it, cz = mech.split("|")
        md.append(f"| {b['severity']} | {b['tier']} ({b['weight']}) | {it} | {cz} | {len(xs)} | {min(x['depth'] for x in xs)} | "
                  f"{b['name']} | {' '.join(b['priced'])} |")
    (ROOT / "checks" / "sweep" / f"{outname}.triage.md").write_text("\n".join(md) + "\n")
    print(len(out), "counterexamples,", len(g), "mechanisms")


if __name__ == "__main__":
    main()
