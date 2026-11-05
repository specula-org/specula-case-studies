---- MODULE MC_ref_PaySrc_F_C_neg ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "taskTimeout"}
MCSym == Permutations(Sites)
BadStep == [][UNCHANGED <<PaySrc_F!AbsC, Proj_PaySrc>>]_allVars
====
