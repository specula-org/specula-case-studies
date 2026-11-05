---- MODULE MC_refS23_WfSJ ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "F", Net |-> "R"]
MCFaults == {"taskTimeout"}
MCSym == Permutations(Sites)
CRef == INSTANCE WfSJ_C WITH wfSJ_c <- WfSJ_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<WfSJ_F!AbsC, Proj_WfSJ>>]_allVars
RefEnv == [][UNCHANGED <<wfSJ_f, Proj_WfSJ>> => UNCHANGED WfSJ_F!AbsC]_allVars
====
