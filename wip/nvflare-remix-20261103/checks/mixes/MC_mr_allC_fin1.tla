---- MODULE MC_mr_allC_fin1 ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {}
MCSym == Permutations(Sites)

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
\* The job finished after both rounds were scheduled and the last round saved.
NotFinished2Rounds == ~(pJobSP.terminal = "FINISHED" /\ pWfSJ.scheduled = Rounds /\ pWfSJ.returned = "normal")

====
