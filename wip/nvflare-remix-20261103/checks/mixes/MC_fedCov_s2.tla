---- MODULE MC_fedCov_s2 ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCFaults == {"minClients", "submitTimeout"}
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
EnvelopeRefsRegistered == \A m \in FedSent("RESULT_ENVELOPE") :
    \A d \in m.body.refs : \E l \in Launches :
        pPaySrc[m.body.assignment.site][l].registered /= None
        /\ d.ref = pPaySrc[m.body.assignment.site][l].registered.ref
\* The aborted receipt (H30) only follows an END_RUN to that site.
AbortedOnlyAfterEndRun == \A c \in Sites, l \in Launches :
    pTaskCJ[c][l].receipt = "aborted" => MsgKey("END_RUN", SJ, CJ(c), <<JobId, c>>) \in DOMAIN net
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
NoStragglerAbortAfterSave == ~(pWfSJ.saved /\ \E c \in Sites, l \in Launches : pTaskCJ[c][l].receipt = "aborted")
\* Late result: a claimed submission routed to the unknown-result hook.
NoLateCall == pCommSJ.call = None \/ pCommSJ.call.kind = "live"
\* Rejected-but-RECEIVED (receipt vs acceptance).
NoRejectedReceived == ~(\E m \in FedSent("RESULT_RECEIPT") : m.body = "RECEIVED" /\ \E c \in pWfSJ.rejected : m.to = CJ(c))

====
