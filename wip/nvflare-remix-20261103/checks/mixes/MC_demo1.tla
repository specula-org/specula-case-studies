---- MODULE MC_demo1 ----
EXTENDS Mix, Props, GenericProps, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "F", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "taskTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ (AtBoundAny /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
