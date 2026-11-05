---- MODULE MC_refS10_TaskCJ ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCFaults == {"cjCrash", "taskTimeout"}
MCSym == Permutations(Sites)
CRef == INSTANCE TaskCJ_C WITH taskCJ_c <- TaskCJ_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<TaskCJ_F!AbsC, Proj_TaskCJ>>]_allVars
RefEnv == [][UNCHANGED <<taskCJ_f, Proj_TaskCJ>> => UNCHANGED TaskCJ_F!AbsC]_allVars
====
