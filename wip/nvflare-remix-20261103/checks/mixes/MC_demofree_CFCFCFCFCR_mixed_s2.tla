---- MODULE MC_demofree_CFCFCFCFCR_mixed_s2 ----
EXTENDS Mix, Props, GenericProps, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "F", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"abort", "cjCrash", "deadClient", "pullTimeout", "resExpiry", "rpcTimeout", "submitTimeout", "taskTimeout", "txTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ (AtBoundAny /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
