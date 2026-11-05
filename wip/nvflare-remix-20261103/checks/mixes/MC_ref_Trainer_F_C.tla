---- MODULE MC_ref_Trainer_F_C ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "F", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCFaults == {}
MCSym == Permutations(Sites)
CRef == INSTANCE Trainer_C WITH trainer_c <- Trainer_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<Trainer_F!AbsC, Proj_Trainer>>]_allVars
RefEnv == [][UNCHANGED <<trainer_f, Proj_Trainer>> => UNCHANGED Trainer_F!AbsC]_allVars
====
