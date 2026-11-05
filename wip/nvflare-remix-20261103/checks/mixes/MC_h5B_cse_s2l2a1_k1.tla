---- MODULE MC_h5B_cse_s2l2a1_k1 ----
EXTENDS MixR, Props, GenericProps, PropsMR, PropsLocal, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"netLoss", "cjCrash", "rpcTimeout", "submitTimeout", "taskTimeout", "pullTimeout", "deadClient"}
MCProfile == {"cseTasks", "wfTolerant"}
MCSym == Permutations(Sites)

GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
