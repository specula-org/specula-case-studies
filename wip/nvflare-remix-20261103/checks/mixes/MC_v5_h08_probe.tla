---- MODULE MC_v5_h08_probe ----
EXTENDS Mix, Props, GenericProps, PropsLocal, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash"}
MCProfile == {"otherJob"}
MCSym == Permutations(Sites)

====
