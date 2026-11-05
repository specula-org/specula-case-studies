---- MODULE MC_h4B_net_s1l2a1_k1 ----
EXTENDS MixR, Props, GenericProps, PropsMR, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"netLoss", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "transportFail", "deadClient", "taskTimeout"}
MCProfile == {"wfTolerant", "lossBudget3"}
MCSym == Permutations(Sites)

GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
