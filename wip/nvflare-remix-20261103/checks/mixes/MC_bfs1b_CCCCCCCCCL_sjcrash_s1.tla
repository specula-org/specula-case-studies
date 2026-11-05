---- MODULE MC_bfs1b_CCCCCCCCCL_sjcrash_s1 ----
EXTENDS Mix, Props, GenericProps, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"outcomeTimeout", "pullTimeout", "resExpiry", "rpcTimeout", "sjCrash", "submitTimeout", "txTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
