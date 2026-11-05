---- MODULE MC_h4S_job_fam_s2l1a2_t20 ----
EXTENDS MixR, Props, GenericProps, PropsMR, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"abort", "abortCmdError", "slowAdminStop", "storeError", "archiveError", "outcomeReportFail", "admissionError", "launchError", "deployError", "rpcTimeout"}
MCProfile == {}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..20) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
