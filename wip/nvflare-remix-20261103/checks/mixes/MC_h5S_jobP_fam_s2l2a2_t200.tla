---- MODULE MC_h5S_jobP_fam_s2l2a2_t200 ----
EXTENDS MixR, Props, GenericProps, PropsMR, PropsLocal, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"rpcTimeout", "cjCrash", "launchError", "storeError", "abort", "outcomeReportFail", "sjCrash", "taskTimeout"}
MCProfile == {"nonStrictStart", "otherJob"}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..200) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
