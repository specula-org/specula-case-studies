#!/usr/bin/env python3
"""Port-level trace validation for ANY mix (DESIGN.md §6).

Reads the real POC replay log (Codex's ObservedData.tla TraceLog: 120 steps
in causal order from run connected-1793718642318637337) and emits
checks/trace/TraceMix_<name>.tla/.cfg: a Mix (selected by --grain) plus a
cursor l. Every Mix step either produces exactly the next observed port event
(l advances) or produces no observable event (silent). Acceptance = l reaches
Len(TR)+1; checked as the witness invariant TraceNotAccepted being violated.

gen_trace.py NAME [--grain G=V,...] [--run] [--timeout S] [--workers N]
"""
import argparse, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import gen_mix, run_mc  # noqa: E402

OBS = Path("/home/ubuntu/nvflare-integrated-model-20261103/vertical-slice/evidence/integration/"
           "checked-model-snapshot-final/checks/integration/positive/ObservedData.tla")

# VSComposition action -> port event over (state, state'). c = site, None for server-level.
EVENTS = {
    "Reserve": 'NewMsg("RESOURCES_OK", CP(c), SP)',
    "ServerLaunch": "Became(pJobSP.sjLaunched)",
    "SendStart": 'NewMsg("START_JOB", SP, CP(c))',
    "Allocate": "Became(pJobCP[c].allocated)",
    "Launch": "(pJobCP[c].launch = 0 /\\ pJobCP'[c].launch = 1)",
    "InitializeRunner": '(pRunCJ[c][1].state = "none" /\\ pRunCJ\'[c][1].state /= "none")',
    "RunnerReady": "Became(pRunCJ[c][1].ready)",
    "SendReady": 'NewMsg("READY", CJ(c), CP(c))',
    "WorkflowOpened": "Became(pWfSJ.open)",
    "ScheduleTask": "(pWfSJ.scheduled = 0 /\\ pWfSJ'.scheduled = 1)",
    "RequestTask": 'NewMsg("GET_TASK", CJ(c), SJ)',
    "PublishAssignment": 'NewMsg("TASK_ASSIGNMENT", SJ, CJ(c))',
    "BuildSubmission": "(pTaskCJ[c][1].submission = None /\\ pTaskCJ'[c][1].submission /= None)",
    "RegisterResultPayload": "(pPaySrc[c][1].registered = None /\\ pPaySrc'[c][1].registered /= None)",
    "PublishResultEnvelope": 'NewMsg("RESULT_ENVELOPE", CJ(c), SJ)',
    "ReceiveEnvelope": "(pCommSJ.envelopes[c] = None /\\ pCommSJ'.envelopes[c] /= None)",
    "RequestPayload": 'NewMsg("PAYLOAD_PULL", SJ, CJ(c))',
    "AcquirePayload": 'NewMsg("PAYLOAD_REPLY", CJ(c), SJ)',
    "MaterializeResult": '(pPayRcv[c].status /= "materialized" /\\ pPayRcv\'[c].status = "materialized")',
    "SendConfirm": 'NewMsg("RECEIVER_CONFIRM", SJ, CJ(c))',
    "ClaimResult": "(c \\notin pCommSJ.claimed /\\ c \\in pCommSJ'.claimed)",
    "PublishDecision": "(c \\notin pWfSJ.accepted /\\ c \\in pWfSJ'.accepted)",
    "FinishContributionCallback": "(c \\notin pCommSJ.finished /\\ c \\in pCommSJ'.finished)",
    "PublishReceipt": 'NewMsg("RESULT_RECEIPT", SJ, CJ(c))',
    "ReceiveReceipt": "Became(pTaskCJ[c][1].done)",
    "CloseRound": '(pWfSJ.closed = "none" /\\ pWfSJ\'.closed /= "none")',
    "PublishAggregate": "(pWfSJ.aggregate = None /\\ pWfSJ'.aggregate /= None)",
    "SaveModel": "Became(pWfSJ.saved)",
    "WorkflowDone": "Became(pWfSJ.done)",
    "SendEndRun": 'NewMsg("END_RUN", SJ, CJ(c))',
    "StopClientRunner": '(pRunCJ[c][1].state /= "stopping" /\\ pRunCJ\'[c][1].state = "stopping")',
    "ObserveChildExit": '(pJobCP[c].exitSeen[1] = "none" /\\ pJobCP\'[c].exitSeen[1] /= "none")',
    "ServerExit": '(pWfSJ.sj /= "exited" /\\ pWfSJ\'.sj = "exited")',
    "ReportOutcome": 'NewMsg("OUTCOME", CP(c), SP)',
    "ObserveOutcome": '(pJobSP.outcomes[c] = "none" /\\ pJobSP\'.outcomes[c] /= "none")',
    "FreeAllocation": "(pJobCP[c].freed = 0 /\\ pJobCP'[c].freed = 1)",
    "FinalizeJob": '(pJobSP.terminal = "none" /\\ pJobSP\'.terminal /= "none")',
    "ReleaseSource": "Became(pPaySrc[c][1].released)",
    "RecordTransferOutcome": '(pPaySrc[c][1].outcome = "none" /\\ pPaySrc\'[c][1].outcome /= "none")',
    "CompleteSettlement": "Became(pPaySrc[c][1].settled)",
}
# Observed steps without a port effect in this framework (private to a group,
# or network delivery which is implicit): not in the vocabulary.
PRIVATE = {"DeliverMessage", "ReceiveReady", "StartRound", "CountContribution", "ReceivePayloadData",
           "ConfirmReceiver", "OutcomeReportReturned", "RetireTransaction", "DeliverAssignment",
           "ReceiveEndRun", "InProcessTrainerPublish",
           # port fields moved to private by the component agents (owner-only):
           "CompleteSettlement", "ReceiveReceipt", "CloseRound",
           # probe-semantics mismatch: the POC's RunnerReady probe is local readiness
           # BEFORE the READY notification (client_runner.py:798-800); pRunCJ.ready
           # means the main loop started (after READY), which has no probe.
           "RunnerReady"}


def mix_steps():
    import os
    mix = Path(os.environ.get("MIX_BUILD") or os.environ.get("MIX_SPEC") or (ROOT / "spec")) / "Mix.tla"
    return re.findall(r"^(Step_\w+) ==", mix.read_text(), flags=re.M)


def observed():
    txt = OBS.read_text()
    i = txt.index("TraceLog ==")
    steps = re.findall(r'\[action \|-> "(\w+)", site \|-> (None|"site-\d")', txt[i:])
    return [(a, None if s == "None" else s.strip('"')) for a, s in steps]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name"); ap.add_argument("--grain", default="")
    ap.add_argument("--run", action="store_true"); ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--drop", default="", help="extra observed actions to treat as unobserved")
    ap.add_argument("--silent", type=int, default=120, help="max consecutive silent steps (fine variants need ~100 between two observed events)")
    a = ap.parse_args()
    global SILENT
    SILENT = a.silent
    steps = observed()
    drop = PRIVATE | set(x for x in a.drop.split(",") if x)
    unknown = sorted({s for s, _ in steps if s not in EVENTS and s not in drop})
    if unknown:
        sys.exit(f"unmapped observed actions: {unknown}")
    tr = [(s, c) for s, c in steps if s in EVENTS and s not in drop]
    global SITE_ACTS
    SITE_ACTS = {s for s, c in tr if c is not None}
    reg = gen_mix.load()
    grain = {}
    for g, gd in reg["groups"].items():
        vs = list(gd["variants"]); grain[g] = "C" if "C" in vs else ("R" if "R" in vs else vs[0])
    grain.update(dict(x.split("=") for x in a.grain.split(",") if x))
    out = ROOT / "checks" / "trace"; out.mkdir(parents=True, exist_ok=True)
    mod = f"TraceMix_{a.name}"
    site = {"site-1": "s1", "site-2": "s2", None: "None"}
    acts = sorted({s for s, _ in tr})
    L = [f"---- MODULE {mod} ----", "EXTENDS Mix, TLC", "CONSTANTS s1, s2", "VARIABLE tpos, sil",
         "MCGrain == [" + ", ".join(f'{k} |-> "{v}"' for k, v in grain.items()) + "]",
         "MCFaults == {}",
         "MCSiteGrain == [g \\in {} |-> 0]",
         "Became(e) == ~e /\\ e'",
         "NewMsg(kind, from, to) == \\E k \\in DOMAIN net' \\ DOMAIN net :",
         "    net'[k].msg.kind = kind /\\ net'[k].msg.from = from /\\ net'[k].msg.to = to",
         "TR == <<" + ",\n    ".join(f'[a |-> "{s}", c |-> {site[c]}]' for s, c in tr) + ">>",
         "Ev(e) == LET c == e.c IN CASE " + "\n    [] ".join(f'e.a = "{s}" -> {EVENTS[s]}' for s in acts)
         + "\n    [] OTHER -> FALSE",
         "\\* the observable vocabulary: any instance of any mapped event, any site",
         "AnyObs == \\/ \\E s \\in {" + ", ".join(f'"{s}"' for s in acts if s in SITE_ACTS) + "}, c \\in Sites : Ev([a |-> s, c |-> c])",
         "          \\/ \\E s \\in {" + ", ".join(f'"{s}"' for s in acts if s not in SITE_ACTS) + "} : Ev([a |-> s, c |-> None])",
         "TInit == Init /\\ tpos = 1 /\\ sil = 0",
         "Match(p, d) == CASE d = 0 -> ~AnyObs",
         "                 [] d = 1 -> p <= Len(TR) /\\ Ev(TR[p]) /\\ ~(p + 1 <= Len(TR) /\\ Ev(TR[p+1]))",
         "                 [] d = 2 -> p + 1 <= Len(TR) /\\ Ev(TR[p]) /\\ Ev(TR[p+1]) /\\ ~(p + 2 <= Len(TR) /\\ Ev(TR[p+2]))",
         "                 [] d = 3 -> p + 2 <= Len(TR) /\\ Ev(TR[p]) /\\ Ev(TR[p+1]) /\\ Ev(TR[p+2])",
         "\\* sil counts consecutive silent steps (bounded by CONSTRAINT SilentBound); one step may produce up to 3 consecutive observed events (e.g. WorkflowDone + the END_RUN broadcast)",
         "TNext == \\E p \\in {tpos}, d \\in {0, 1, 2, 3}, q \\in {sil} : tpos' = p + d /\\ sil' = (IF d = 0 THEN q + 1 ELSE 0) /\\ (",
         "    \\/ " + "\n    \\/ ".join(f"({st} /\\ Match(p, d))" for st in mix_steps()) + ")",
         "TraceNotAccepted == tpos <= Len(TR)",
         f"SilentBound == sil <= {SILENT}",
         "Progress == tpos",
         "===="]
    import os
    mixsrc = (Path(os.environ.get("MIX_BUILD") or os.environ.get("MIX_SPEC") or (ROOT / "spec")) / "Mix.tla").read_text()
    body = mixsrc.split("\n", 1)[1]          # drop Mix module header
    body = body[:body.rstrip().rfind("\n")]  # drop the closing ==== line
    head = [f"---- MODULE {mod} ----", "\\* Mix copy + port-level trace cursor (see gen_trace.py)"]
    rest = [x for x in L[2:] if x != "===="]   # skip header and EXTENDS Mix line
    text = "\n".join(head) + "\n" + body.replace("EXTENDS Ports", "EXTENDS Ports, TLC", 1) + "\n" + "\n".join(rest) + "\n====\n"
    (out / f"{mod}.tla").write_text(text)
    cfg = ["CONSTANTS", "  Grain <- MCGrain", "  SiteGrain <- MCSiteGrain", "  Faults <- MCFaults", "  Sites = {s1, s2}", "  s1 = s1", "  s2 = s2",
           "  None = None", "  JobId = JobId", "  MaxLaunch = 1", "  MaxAttempt = 1", "  Profile = {}",
           "INIT TInit", "NEXT TNext", "INVARIANT TraceNotAccepted", "CONSTRAINT SilentBound", "CHECK_DEADLOCK FALSE"]
    (out / f"{mod}.cfg").write_text("\n".join(cfg) + "\n")
    print(f"wrote {out/mod}.tla: {len(tr)} observed port events (of {len(steps)} steps)", grain)
    if a.run:
        mixes = ROOT / "checks" / "mixes"
        # reuse run_mc by placing the module where it expects
        (mixes / f"MC_{mod}.tla").write_text((out / f"{mod}.tla").read_text().replace(f"MODULE {mod}", f"MODULE MC_{mod}"))
        (mixes / f"MC_{mod}.cfg").write_text((out / f"{mod}.cfg").read_text())
        r = run_mc.run(mod, a.timeout, a.workers, "bfs", (0, 0), "16g")
        acc = r.get("violated") == "TraceNotAccepted"
        print({k: v for k, v in r.items() if k != "cfg"})
        print("TRACE ACCEPTED" if acc else "TRACE NOT ACCEPTED (inspect logs/%s.log)" % mod)
        if not acc and r.get("result") == "pass_exhaustive":
            # find the furthest trace position any behavior reaches
            dump = ROOT / ".tmp" / f"{mod}_dump"
            subprocess.run([str(ROOT / "scripts" / "tlc.sh"), "tlc", str(mixes), f"MC_{mod}", f"MC_{mod}.cfg",
                            "-dump", str(dump)], capture_output=True)
            t = Path(str(dump) + ".dump").read_text()
            mx = max(int(x) for x in re.findall(r"/\\ tpos = (\d+)", t))
            print(f"STUCK: furthest position {mx}/{len(tr)}: next expected {tr[mx-1]}; "
                  f"previous {tr[max(0, mx-4):mx-1]}")
            Path(str(dump) + ".dump").unlink()


if __name__ == "__main__":
    main()
