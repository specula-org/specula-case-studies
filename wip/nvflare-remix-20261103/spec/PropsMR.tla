------------------------------ MODULE PropsMR ------------------------------
\* Port invariants that hold for any number of rounds (MaxAttempt >= 1): the
\* fedavg port checks and the per-round forms of the Props port invariants
\* (from scripts/fed_mkmc.py FED_DEFS; identical to Props at MaxAttempt = 1).
\* Only port variables and net are referenced, so every mix can use them.
EXTENDS Props
FedSent(kind) == {net[k].msg : k \in {k2 \in DOMAIN net : net[k2].msg.kind = kind}}
ResendPreservesAuthority == \A m1, m2 \in FedSent("TASK_ASSIGNMENT") :
    (/\ m1.body.status = "ASSIGNED" /\ m2.body.status = "ASSIGNED" /\ m1.to = m2.to
     /\ m1.body.assignment.attempt = m2.body.assignment.attempt)
       => m1.body.assignment = m2.body.assignment
OneAssignmentRecordPerIdentity == \A m \in FedSent("TASK_ASSIGNMENT") :
    m.body.status = "ASSIGNED" =>
        \E c \in Sites : m.to = CJ(c) /\ m.body.assignment = Assignment(c, m.body.assignment.attempt)
EnvelopeRefsRegistered == \A m \in FedSent("RESULT_ENVELOPE") :
    \A d \in m.body.refs : \E l \in Launches :
        LET r == pPaySrc[m.body.assignment.site][l].tx[m.body.assignment.attempt].registered
        IN r /= None /\ d.ref = r.ref
EndRunAfterDone == \A m \in FedSent("END_RUN") : pWfSJ.done
SavedAfterOkClose == pWfSJ.aggregate /= None => pWfSJ.returned \in {"none", "normal"}
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
REnvRound(c, id) == LET k == MsgKey("RESULT_ENVELOPE", CJ(c), SJ, id)
                    IN IF k \in DOMAIN net THEN net[k].msg.body.assignment.attempt ELSE 0
RReceivedReceiptMeansFinished == \A m \in FedSent("RESULT_RECEIPT") :
    m.body = "RECEIVED" => \E c \in Sites : m.to = CJ(c) /\
        (REnvRound(c, m.id) = pCommSJ.round => c \in pCommSJ.finished)
MRPortInvs == RClaimNeedsMaterialized /\ RMaterializedIsRegistered /\ RAggregateIsAccepted
    /\ AcceptedWasClaimed /\ RReceivedReceiptMeansFinished /\ RNoReleaseBeforeMaterialize
    /\ ResendPreservesAuthority /\ OneAssignmentRecordPerIdentity /\ EnvelopeRefsRegistered
    /\ EndRunAfterDone /\ SavedAfterOkClose
=============================================================================
