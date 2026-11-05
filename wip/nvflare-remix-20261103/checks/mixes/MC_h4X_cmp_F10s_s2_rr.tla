---- MODULE MC_h4X_cmp_F10s_s2_rr ----
EXTENDS Mix, Props, GenericProps, PropsMR, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"minClients"}
MCProfile == {}
MCSym == Permutations(Sites)

====
