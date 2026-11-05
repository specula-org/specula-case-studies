---- MODULE MC_pref_rcv_s19L ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "C", WfSJ |-> "C", Net |-> "L"]
MCFaults == {"pullTimeout", "txTimeout", "netLoss"}
MCSym == Permutations(Sites)
CRef == INSTANCE PayRcv_C WITH payRcv_c <- PayRcv_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<PayRcv_F!AbsC, Proj_PayRcv>>]_allVars
RefEnv == [][UNCHANGED <<payRcv_f, Proj_PayRcv>> => UNCHANGED PayRcv_F!AbsC]_allVars
====
