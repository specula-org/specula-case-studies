---- MODULE MC_bfs1b_CCCCCCFCCR_loss_s1 ----
EXTENDS Mix, Props, GenericProps, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"netLoss", "outcomeTimeout", "pullTimeout", "resExpiry", "rpcTimeout", "submitTimeout", "txTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
