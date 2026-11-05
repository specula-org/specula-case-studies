---- MODULE MC_bfs1b_CCFCCCCCCR_crash_s1 ----
EXTENDS Mix, Props, GenericProps, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "outcomeTimeout", "pullTimeout", "resExpiry", "rpcTimeout", "submitTimeout", "txTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
