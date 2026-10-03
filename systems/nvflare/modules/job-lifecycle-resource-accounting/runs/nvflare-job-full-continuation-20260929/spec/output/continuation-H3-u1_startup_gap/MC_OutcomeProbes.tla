------------------------- MODULE MC_OutcomeProbes -------------------------
EXTENDS MC

(* Historical MC-U1: an authoritative pending report is accepted in the gap
   between the SJ process entry disappearing and running_jobs insertion. This
   probe excludes the separately retained active fail_run/latch failure, solely
   in its oracle; MCSpec, all inputs and every transition remain unchanged.
   Use the cfg with MaxCjUnsafe=0 so failAccepted denotes authoritative codes.
   Post-finality acceptance races still require source/contract classification. *)
NoInactiveFailureSuccess ==
    \A j \in Jobs :
        ~(status[j] = COMPLETED /\ failAccepted[j] /\ ~failRunRec[j])

=============================================================================
