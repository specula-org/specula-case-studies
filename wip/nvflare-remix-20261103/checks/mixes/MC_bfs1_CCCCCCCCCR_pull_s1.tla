---- MODULE MC_bfs1_CCCCCCCCCR_pull_s1 ----
EXTENDS Mix, Props, GenericProps, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"pullTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
