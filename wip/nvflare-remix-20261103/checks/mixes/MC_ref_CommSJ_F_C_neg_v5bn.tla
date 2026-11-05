---- MODULE MC_ref_CommSJ_F_C_neg_v5bn ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"taskTimeout"}
MCProfile == {"cseTasks"}
MCSym == Permutations(Sites)
BadStep == [][UNCHANGED <<CommSJ_F!AbsC, Proj_CommSJ>>]_allVars
====
