---- MODULE MC_ref_CommSJ_F_C ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"taskTimeout"}
MCSym == Permutations(Sites)
CRef == INSTANCE CommSJ_C WITH commSJ_c <- CommSJ_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<CommSJ_F!AbsC, Proj_CommSJ>>]_allVars
RefEnv == [][UNCHANGED <<commSJ_f, Proj_CommSJ>> => UNCHANGED CommSJ_F!AbsC]_allVars
====
