---- MODULE MC_ref_TaskCJ_F_C_neg ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {}
MCSym == Permutations(Sites)
CBad == INSTANCE TaskCJ_C WITH taskCJ_c <- CHOOSE x \in {TaskCJ_F!AbsCInit} : TRUE
BadStep == [][CBad!Next \/ UNCHANGED <<TaskCJ_F!AbsCInit, Proj_TaskCJ>>]_allVars
====
