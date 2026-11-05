---- MODULE MC_demofree_FCFCFCFCFL_mixed_s2 ----
EXTENDS Mix, Props, GenericProps, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "F", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "C", WfSJ |-> "F", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"abort", "cjCrash", "deadClient", "pullTimeout", "resExpiry", "rpcTimeout", "submitTimeout", "taskTimeout", "txTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ (AtBoundAny /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
