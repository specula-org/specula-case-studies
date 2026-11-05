---- MODULE MC_refL_TaskCJ ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "L"]
MCFaults == {"netLoss", "submitTimeout", "resultWaitTimeout"}
MCSym == Permutations(Sites)
CRef == INSTANCE TaskCJ_C WITH taskCJ_c <- TaskCJ_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<TaskCJ_F!AbsC, Proj_TaskCJ>>]_allVars
====
