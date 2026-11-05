---- MODULE MC_ref_RunCJ_F_C_neg ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "abort", "launchError"}
MCSym == Permutations(Sites)
BadStep == [][UNCHANGED <<RunCJ_F!AbsC, Proj_RunCJ>>]_allVars
====
