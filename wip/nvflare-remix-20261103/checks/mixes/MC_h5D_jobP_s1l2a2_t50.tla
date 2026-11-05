---- MODULE MC_h5D_jobP_s1l2a2_t50 ----
EXTENDS MixR, Props, GenericProps, PropsMR, PropsLocal, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"rpcTimeout", "cjCrash", "launchError", "storeError", "abort", "outcomeReportFail", "sjCrash", "taskTimeout"}
MCProfile == {"nonStrictStart", "otherJob"}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..50) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
