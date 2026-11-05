---- MODULE MC_pref_rcv_s10 ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "taskTimeout"}
MCSym == Permutations(Sites)
CRef == INSTANCE PayRcv_C WITH payRcv_c <- PayRcv_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<PayRcv_F!AbsC, Proj_PayRcv>>]_allVars
RefEnv == [][UNCHANGED <<payRcv_f, Proj_PayRcv>> => UNCHANGED PayRcv_F!AbsC]_allVars
====
