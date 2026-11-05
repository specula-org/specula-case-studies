---- MODULE MC_ref_WfSJ_M_C ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "M", Net |-> "R"]
MCFaults == {"cjCrash", "sjCrash", "taskTimeout", "pullTimeout", "txTimeout", "abort"}
MCSym == Permutations(Sites)
CRef == INSTANCE WfSJ_C WITH wfSJ_c <- WfSJ_M!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<WfSJ_M!AbsC, Proj_WfSJ>>]_allVars
====
