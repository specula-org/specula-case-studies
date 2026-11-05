---- MODULE MC_ref_JobCP_F_C_v6c ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "F", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cpCrash", "cjCrash", "rpcTimeout", "launchError"}
MCProfile == {}
MCSym == Permutations(Sites)
CRef == INSTANCE JobCP_C WITH jobCP_c <- JobCP_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<JobCP_F!AbsC, Proj_JobCP>>]_allVars
RefEnv == [][UNCHANGED <<jobCP_f, Proj_JobCP>> => UNCHANGED JobCP_F!AbsC]_allVars
====
