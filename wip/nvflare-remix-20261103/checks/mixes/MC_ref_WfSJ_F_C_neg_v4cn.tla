---- MODULE MC_ref_WfSJ_F_C_neg_v4cn ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"taskTimeout"}
MCProfile == {}
MCSym == Permutations(Sites)
BadStep == [][UNCHANGED <<WfSJ_F!AbsC, Proj_WfSJ>>]_allVars
====
