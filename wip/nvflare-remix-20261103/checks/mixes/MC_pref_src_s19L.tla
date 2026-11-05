---- MODULE MC_pref_src_s19L ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "L"]
MCFaults == {"pullTimeout", "txTimeout", "netLoss"}
MCSym == Permutations(Sites)
CRef == INSTANCE PaySrc_C WITH paySrc_c <- PaySrc_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<PaySrc_F!AbsC, Proj_PaySrc>>]_allVars
RefEnv == [][UNCHANGED <<paySrc_f, Proj_PaySrc>> => UNCHANGED PaySrc_F!AbsC]_allVars
====
