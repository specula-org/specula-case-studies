---- MODULE MC_refK_CommSJ ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "C", Net |-> "R"]
MCFaults == {}
MCSym == Permutations(Sites)
CRef == INSTANCE CommSJ_C WITH commSJ_c <- CommSJ_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<CommSJ_F!AbsC, Proj_CommSJ>>]_allVars
FedConstraint == SJAlive \/ ~pJobSP.sjLaunched
====
