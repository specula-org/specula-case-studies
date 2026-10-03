------------------------- MODULE MC_OutcomeProbes -------------------------
EXTENDS MC

(* Historical MC-U1: an authoritative pending report is accepted in the gap
   between the SJ process entry disappearing and running_jobs insertion. This
   probe excludes the separately retained active fail_run/latch failure, solely
   in its oracle; MCSpec, all inputs and every transition remain unchanged.
   Use the cfg with MaxCjUnsafe=0 so failAccepted denotes authoritative codes.
   Require the job still be tracked when success is published; deliberately
   ignored reports after final removal are outside this contract. *)
NoInactiveFailureSuccess ==
    \A j \in Jobs :
        ~(status[j] = COMPLETED /\ j \in runningJobs
          /\ failAccepted[j] /\ ~failRunRec[j])

=============================================================================
