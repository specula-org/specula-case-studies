#!/usr/bin/env python3
"""Build an MC module for a mix (like mkmc.py) and add the fedavg invariants:
port-level FedAvg properties (defined here, over ports and net only) plus the
group-local invariants of every fed group that is fine in the mix
(CommSJ_F!CommSafety, WfSJ_F!WfSafety).

fed_mkmc.py NAME [--grain G=V,...] [--faults f1,f2] [--sites N] [--launch N]
            [--attempt N] [--inv I1,I2 | --inv default|fed|mr|none] [--extra-inv I1,I2]
            [--constraint EXPR]
--inv mr: MRPortSafety (per-round port invariants) + FedPortSafety (+ group safety).
"""
import argparse, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc  # noqa: E402

FED_DEFS = r"""
FedSent(kind) == {net[k].msg : k \in {k2 \in DOMAIN net : net[k2].msg.kind = kind}}
\* A resend keeps the authority: every ASSIGNED reply to a site for a round
\* carries the same assignment (seed AssignmentAuthorityPreserved).
ResendPreservesAuthority == \A m1, m2 \in FedSent("TASK_ASSIGNMENT") :
    (/\ m1.body.status = "ASSIGNED" /\ m2.body.status = "ASSIGNED" /\ m1.to = m2.to
     /\ m1.body.assignment.attempt = m2.body.assignment.attempt)
       => m1.body.assignment = m2.body.assignment
\* OneAssignmentRecordPerIdentity (S06), slice form: one client task per (site, round).
OneAssignmentRecordPerIdentity == \A m \in FedSent("TASK_ASSIGNMENT") :
    m.body.status = "ASSIGNED" =>
        \E c \in Sites : m.to = CJ(c) /\ m.body.assignment = Assignment(c, m.body.assignment.attempt)
\* An envelope only carries refs to a descriptor its source registered (no value).
\* (per transaction: the descriptor of the envelope's round, Tx(c, l, attempt)).
EnvelopeRefsRegistered == \A m \in FedSent("RESULT_ENVELOPE") :
    \A d \in m.body.refs : \E l \in Launches :
        LET r == pPaySrc[m.body.assignment.site][l].tx[m.body.assignment.attempt].registered
        IN r /= None /\ d.ref = r.ref
\* The aborted receipt (H30, TaskCJ_F-private; vacuous when TaskCJ = C) only follows an END_RUN.
AbortedOnlyAfterEndRun == \A c \in Sites, l \in Launches :
    TaskCJ_F!T(c, l).receipt = "aborted" => MsgKey("END_RUN", SJ, CJ(c), <<JobId, c>>) \in DOMAIN net
EndRunAfterDone == \A m \in FedSent("END_RUN") : pWfSJ.done
\* Publication only from a closed-ok round, and only of counted results.
SavedAfterOkClose == pWfSJ.aggregate /= None => pWfSJ.returned \in {"none", "normal"}
\* S10/H30 diagnostic without Ports!Flag: no SJ-fatal payload decode after run end.
FedNoSJDeathAfterDone == pWfSJ.done =>
    ~(\E c \in Sites : "fatal" \in DOMAIN pPayRcv[c] /\ pPayRcv[c]["fatal"] = TRUE)
FedPortSafety == ResendPreservesAuthority /\ OneAssignmentRecordPerIdentity
    /\ EnvelopeRefsRegistered /\ AbortedOnlyAfterEndRun /\ EndRunAfterDone
    /\ SavedAfterOkClose
\* --- witnesses (expected reachable)
\* H30/S10: a straggler's in-flight submission is abandoned by END_RUN while
\* the workflow saved a model.
NoStragglerAbortAfterSave == ~(pWfSJ.saved /\ \E c \in Sites, l \in Launches : TaskCJ_F!T(c, l).receipt = "aborted")
\* Late result: a claimed submission routed to the unknown-result hook.
NoLateCall == pCommSJ.call = None \/ pCommSJ.call.kind = "live"
\* Rejected-but-RECEIVED (receipt vs acceptance).
NoRejectedReceived == ~(\E m \in FedSent("RESULT_RECEIPT") : m.body = "RECEIVED" /\ \E c \in pWfSJ.rejected : m.to = CJ(c))
NoTaskCheck == ~(\E k \in DOMAIN net : net[k].msg.kind = "TASK_CHECK")
NoCheckReply == ~(\E k \in DOMAIN net : net[k].msg.kind = "TASK_CHECK_REPLY")
NoEnvelope == ~(\E k \in DOMAIN net : net[k].msg.kind = "RESULT_ENVELOPE")
\* --- per-round (per-transaction) forms of the Props port invariants (port request
\* 2026-11-04, notes/port-requests.md); identical to Props at MaxAttempt = 1.
RClaimNeedsMaterialized == \A c \in pCommSJ.claimed :
    pCommSJ.envelopes[c] /= None =>
        pPayRcv[c].rx[pCommSJ.envelopes[c].assignment.attempt].status = "materialized"
RMaterializedIsRegistered == \A c \in Sites, a \in Attempts :
    pPayRcv[c].rx[a].materialized /= None =>
        \E l \in Launches : /\ pPaySrc[c][l].tx[a].registered /= None
                            /\ pPaySrc[c][l].tx[a].registered.value = pPayRcv[c].rx[a].materialized
RAggregateIsAccepted == pWfSJ.aggregate /= None =>
    pWfSJ.aggregate = {pPayRcv[c].rx[pWfSJ.scheduled].materialized : c \in pWfSJ.accepted}
RNoReleaseBeforeMaterialize == \A c \in Sites, l \in Launches, a \in Attempts :
    (pPaySrc[c][l].tx[a].released /\ pPaySrc[c][l].tx[a].outcome = "completed")
        => pPayRcv[c].rx[a].status = "materialized"
\* Receipt properties restricted to the current round's envelopes (a RECEIVED
\* receipt of an earlier round stays in net after pCommSJ.finished is reset).
REnvRound(c, id) == LET k == MsgKey("RESULT_ENVELOPE", CJ(c), SJ, id)
                    IN IF k \in DOMAIN net THEN net[k].msg.body.assignment.attempt ELSE 0
RReceivedReceiptMeansFinished == \A m \in FedSent("RESULT_RECEIPT") :
    m.body = "RECEIVED" => \E c \in Sites : m.to = CJ(c) /\
        (REnvRound(c, m.id) = pCommSJ.round => c \in pCommSJ.finished)
\* Rounds >= 2 safety set: round-agnostic Props invariants + the per-round forms.
MRPortSafety == RClaimNeedsMaterialized /\ RMaterializedIsRegistered /\ RAggregateIsAccepted
    /\ AcceptedWasClaimed /\ NoFreeWhileChildAlive /\ AtMostOneFree /\ FinishedJobSaved
    /\ RNoReleaseBeforeMaterialize
\* Multi-round witnesses (expected reachable): round 2 saved / round-2 input delivered.
NotRound2Saved == ~(pWfSJ.scheduled >= 2 /\ pWfSJ.saved /\ pWfSJ.returned = "normal")
NotRound2Input == \A c \in Sites, l \in Launches : pTrainer[c][l].received < 2
\* S02 restricted to the genuine successor: the clobbered input is the round-2
\* task (assignment attempt 2), not a coarse re-assignment of round 1.
S02Round2 == \A c \in Sites, l \in Launches :
    LET P == pTrainer[c][l]
        I == pTaskCJ[c][l].input
    IN (/\ I /= None /\ I.assignment /= None /\ I.assignment.attempt = 2 /\ P.received = I.gen
        /\ P.received > (IF P.published = None THEN 0 ELSE P.published.gen))
       => P.slot = P.received
\* Directed search for S02 (CONSTRAINT, prunes only): a trainer that published a
\* result stays in its send() tail (does not reach receive() again) until a
\* newer input generation was delivered.
S02Directed == \A c \in Sites, l \in Launches :
    ~(pTrainer[c][l].published /= None /\ pTrainer[c][l].received <= pTrainer[c][l].published.gen
      /\ Trainer_F!T(c, l).pc \in {"waiting", "training", "publishing"} /\ pTrainer[c][l].slot = 0)
\* The job finished after both rounds were scheduled and the last round saved.
NotFinished2Rounds == ~(pJobSP.terminal = "FINISHED" /\ pWfSJ.scheduled = Rounds /\ pWfSJ.returned = "normal")
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--grain", default="")
    ap.add_argument("--faults", default="")
    ap.add_argument("--sites", type=int, default=1)
    ap.add_argument("--launch", type=int, default=1)
    ap.add_argument("--attempt", type=int, default=1, help="MaxAttempt = FedAvg rounds")
    ap.add_argument("--inv", default="default")
    ap.add_argument("--extra-inv", default="")
    ap.add_argument("--constraint")
    ap.add_argument("--no-symmetry", action="store_true")
    a = ap.parse_args()
    grain = dict(x.split("=") for x in a.grain.split(",") if x)
    if a.inv == "default":
        inv = list(mkmc.PORT_INVS) + ["FedPortSafety"]
    elif a.inv == "mr":
        inv = ["MRPortSafety", "FedPortSafety"]
    elif a.inv == "fed":
        inv = ["FedPortSafety"]
    elif a.inv == "none":
        inv = []
    else:
        inv = [i for i in a.inv.split(",") if i]
    if a.inv in ("default", "fed", "mr"):
        if grain.get("CommSJ") == "F":
            inv.append("CommSJ_F!CommSafety")
        if grain.get("WfSJ") == "F":
            inv.append("WfSJ_F!WfSafety")
    inv += [i for i in a.extra_inv.split(",") if i]
    # TLC cfg INVARIANT needs an identifier: wrap instance-qualified names
    defs, names = [FED_DEFS], []
    for i in inv:
        if "!" in i:
            n = "Fed_" + i.replace("!", "_")
            defs.append(f"{n} == {i}")
            names.append(n)
        else:
            names.append(i)
    out, mod, g = mkmc.build(a.name, grain=grain, faults=[f for f in a.faults.split(",") if f],
                             sites=a.sites, launch=a.launch, attempt=a.attempt, inv=names,
                             symmetry=not a.no_symmetry, constraint=a.constraint,
                             extra_defs="\n".join(defs))
    print(out / f"{mod}.tla", g)


if __name__ == "__main__":
    main()
