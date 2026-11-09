----------------------------- MODULE PropsV11 -----------------------------
\* v11 consequence properties (RESULTS 17.5 leads). Each names the outcome a
\* user would care about; the v11 smoke already showed most are reachable, so
\* the hunt (plans/hunt11.py) keeps them out of its invariant set and the lead
\* runs (plans/hunt11_leads.py) produce counterexamples for reproduction.
EXTENDS Mix
\* H04 / H39: a job recorded COMPLETED leaves a usable model file
V11FinishedModelUsable == SJModel /\ pJobSP.terminal = "FINISHED" => pModel.artifact.kind \notin {"poisoned", "corrupt"}
\* H07: every launch's results come back (k8s workspace transfer)
V11ResultsReturned == "k8sJob" \in Profile => \A c \in Sites : pJobCP[c].wsLost = {}
\* V7: a run that completed on a surviving CJ is not recorded as failed
V11CompletedNotFailed == ~(CJContainer /\ pWfSJ.saved /\ pJobSP.terminal = "ABORTED_OR_FAILED"
                           /\ \E c \in Sites : CPRestarted(c) /\ pRunCJ[c][1].exit = "ok")
\* H05: a closed gather aggregated every reply it counted
V11GatherComplete == SwarmOn => \A c \in Sites, l \in Launches :
    pSwarm[c][l].gather /= None /\ pSwarm[c][l].gather.done => pSwarm[c][l].gather.gathered = pSwarm[c][l].gather.replied
\* H06: a client controller stops only when asked (END_RUN / END_WF), not by its own abort
V11NoSelfStop == SwarmOn => \A c \in Sites, l \in Launches :
    pSwarm[c][l].learn.st = "aborted" => pSwarm[c][l].ended \/ \E k \in DOMAIN net : InInbox(k, CJ(c), "END_RUN")
\* H01: the attached trainer never believes in an acceptance the CJ did not make
V11AttachNoFalseSuccess == Grain["Trainer"] = "A" => \A c \in Sites, l \in Launches :
    trainer_a[c][l].tpOut.out = "inferred" => trainer_a[c][l].auth >= trainer_a[c][l].tpOut.gen
=============================================================================
