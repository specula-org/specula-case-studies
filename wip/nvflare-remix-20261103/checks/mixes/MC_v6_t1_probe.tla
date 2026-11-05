---- MODULE MC_v6_t1_probe ----
EXTENDS Mix, Props, GenericProps, PropsLocal, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"deleteJob"}
MCProfile == {}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ ((AtBoundAny) /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
