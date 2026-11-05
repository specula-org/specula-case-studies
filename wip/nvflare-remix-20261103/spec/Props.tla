------------------------------- MODULE Props -------------------------------
\* Cross-component properties over PORT state only, so they are meaningful in
\* every mix. Group-internal properties live with their variants.
EXTENDS Ports

SentMsgs(kind) == {net[k].msg : k \in {k2 \in DOMAIN net : net[k2].msg.kind = kind}}

\* --- payload / workflow data path
\* Only payload-carrying submissions need a materialized payload: error replies
\* (no refs) are claimed without one, and CommSJ only exposes envelopes with refs.
ClaimNeedsMaterialized == \A c \in pCommSJ.claimed :
    pCommSJ.envelopes[c] /= None =>
        pPayRcv[c].rx[pCommSJ.envelopes[c].assignment.attempt].status = "materialized"
MaterializedIsRegistered == \A c \in Sites, a \in Attempts :
    pPayRcv[c].rx[a].materialized /= None =>
        \E l \in Launches : /\ pPaySrc[c][l].tx[a].registered /= None
                            /\ pPaySrc[c][l].tx[a].registered.value = pPayRcv[c].rx[a].materialized
AggregateIsAccepted == pWfSJ.aggregate /= None =>
    pWfSJ.aggregate = {pPayRcv[c].rx[pWfSJ.scheduled].materialized : c \in pWfSJ.accepted}
AcceptedWasClaimed == pWfSJ.accepted \subseteq pCommSJ.claimed

\* --- receipts and authority
\* Receipts are per round: a RECEIVED receipt of an earlier round stays in net
\* after pCommSJ.finished / pWfSJ.accepted are reset for the next round.
EnvRound(c, id) == LET k == MsgKey("RESULT_ENVELOPE", CJ(c), SJ, id)
                   IN IF k \in DOMAIN net THEN net[k].msg.body.assignment.attempt ELSE 0
ReceivedReceiptMeansFinished == \A m \in SentMsgs("RESULT_RECEIPT") :
    m.body = "RECEIVED" => \E c \in Sites : m.to = CJ(c) /\
        (EnvRound(c, m.id) = pCommSJ.round => c \in pCommSJ.finished)
\* A client told RECEIVED must have its contribution accepted (not rejected).
ReceivedMeansAccepted == \A m \in SentMsgs("RESULT_RECEIPT") :
    m.body = "RECEIVED" => \E c \in Sites : m.to = CJ(c) /\
        (EnvRound(c, m.id) = pWfSJ.scheduled => c \in pWfSJ.accepted)
\* --- resources and process lifecycle
NoFreeWhileChildAlive == \A c \in Sites :
    pJobCP[c].freed > 0 => \A l \in Launches : ~CJAlive(c, l)
AtMostOneFree == \A c \in Sites : pJobCP[c].freed <= 1
FinishedJobSaved == pJobSP.terminal = "FINISHED" => pWfSJ.saved
FinishedJobAllOk == pJobSP.terminal = "FINISHED" =>
    \A c \in pJobSP.startSent : pJobSP.outcomes[c] = "ok"

\* --- source lifetime vs. data consumption
\* A source released while its receiver still needs the data loses the result.
NoReleaseBeforeMaterialize == \A c \in Sites, l \in Launches, a \in Attempts :
    (pPaySrc[c][l].tx[a].released /\ pPaySrc[c][l].tx[a].outcome = "completed")
        => pPayRcv[c].rx[a].status = "materialized"
PortSafety ==
    /\ ClaimNeedsMaterialized /\ MaterializedIsRegistered /\ AggregateIsAccepted
    /\ AcceptedWasClaimed /\ ReceivedReceiptMeansFinished /\ ReceivedMeansAccepted
    /\ NoFreeWhileChildAlive /\ AtMostOneFree /\ FinishedJobSaved /\ FinishedJobAllOk
    /\ NoReleaseBeforeMaterialize


\* --- diagnostics derived from Phase 1 hazards (notes/phase1-hazards.md);
\* a violation is a behavior to explain, not automatically a bug.
\* S10 (H29/H30): a workflow that completed and persisted its model should not
\* end as a failed job because of a late transfer/decode failure.
OutcomeReflectsWorkflow == (pJobSP.terminal /= "none" /\ pWfSJ.saved /\ pWfSJ.done)
                              => pJobSP.terminal = "FINISHED"
\* S10: the SJ must not die (os._exit) after its workflow completed.
NoSJDeathAfterWorkflowDone == pWfSJ.done => ~SJFatal

\* S02 (H02, Phase 1 v2 MC-2/TP-C): an input generation accepted by the API's
\* GLOBAL_RESULT callback must stay in fl_model until the trainer has published
\* a result for it; the previous send()'s clear_cache tail must not null it.
SuccessorInputPreserved == \A c \in Sites, l \in Launches :
    LET P == pTrainer[c][l] IN
    P.received > (IF P.published = None THEN 0 ELSE P.published.gen) => P.slot = P.received

\* Same as NoSJDeathAfterWorkflowDone, written directly over PayRcv's fatal flag
\* (works around a TLC evaluation error seen with SJFatal/Flag in some mixes).
NoPayFatalAfterDoneP == pWfSJ.done => \A c \in Sites : ~(pPayRcv[c].fatal = TRUE)

\* --- witnesses (expected reachable; used as non-vacuity checks)
NotJobFinished == pJobSP.terminal /= "FINISHED"
NotJobFailed == pJobSP.terminal /= "ABORTED_OR_FAILED"
NotAllFreed == \E c \in Sites : pJobCP[c].freed = 0
=============================================================================
