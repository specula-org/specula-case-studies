---- MODULE MC_ref_JobSP_F_C_neg_v5dn ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"abort", "rpcTimeout"}
MCProfile == {}
MCSym == Permutations(Sites)
BadStep == [][UNCHANGED <<JobSP_F!AbsC, Proj_JobSP>>]_allVars
====
