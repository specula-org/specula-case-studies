---- MODULE MC_ref_JobCP_F_C_neg_v5bn ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "F", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"launchError"}
MCProfile == {"otherJob"}
MCSym == Permutations(Sites)
BadStep == [][UNCHANGED <<JobCP_F!AbsC, Proj_JobCP>>]_allVars
====
