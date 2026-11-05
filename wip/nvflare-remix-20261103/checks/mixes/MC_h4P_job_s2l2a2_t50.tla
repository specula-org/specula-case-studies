---- MODULE MC_h4P_job_s2l2a2_t50 ----
EXTENDS MixR, Props, GenericProps, PropsMR, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == ("JobCP" :> (s1 :> "F" @@ s2 :> "C") @@ "RunCJ" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"abort", "abortCmdError", "slowAdminStop", "storeError", "archiveError", "outcomeReportFail", "admissionError", "launchError", "deployError", "rpcTimeout"}
MCProfile == {}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..50) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
