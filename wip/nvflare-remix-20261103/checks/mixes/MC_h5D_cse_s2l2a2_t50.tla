---- MODULE MC_h5D_cse_s2l2a2_t50 ----
EXTENDS MixR, Props, GenericProps, PropsMR, PropsLocal, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"netLoss", "cjCrash", "rpcTimeout", "submitTimeout", "taskTimeout", "pullTimeout", "deadClient"}
MCProfile == {"cseTasks", "wfTolerant"}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..50) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
