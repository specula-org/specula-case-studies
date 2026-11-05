---- MODULE MC_v5_h11_probe ----
EXTENDS Mix, Props, GenericProps, PropsLocal, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"netLoss"}
MCProfile == {"cseTasks"}
MCSym == Permutations(Sites)

====
