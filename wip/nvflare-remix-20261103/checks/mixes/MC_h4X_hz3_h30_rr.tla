---- MODULE MC_h4X_hz3_h30_rr ----
EXTENDS Mix, Props, GenericProps, PropsMR, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"minClients"}
MCProfile == {}
MCSym == Permutations(Sites)

====
