---- MODULE MC_h5S_cse_fam_s2l1a2_t200 ----
EXTENDS MixR, Props, GenericProps, PropsMR, PropsLocal, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"netLoss", "cjCrash", "rpcTimeout", "submitTimeout", "taskTimeout", "pullTimeout", "deadClient"}
MCProfile == {"cseTasks", "wfTolerant"}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..200) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
