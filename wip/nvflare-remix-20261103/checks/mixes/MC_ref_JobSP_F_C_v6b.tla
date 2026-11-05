---- MODULE MC_ref_JobSP_F_C_v6b ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"deleteJob", "rpcTimeout"}
MCProfile == {"nonStrictStart"}
MCSym == Permutations(Sites)
CRef == INSTANCE JobSP_C WITH jobSP_c <- JobSP_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<JobSP_F!AbsC, Proj_JobSP>>]_allVars
RefEnv == [][UNCHANGED <<jobSP_f, Proj_JobSP>> => UNCHANGED JobSP_F!AbsC]_allVars
====
