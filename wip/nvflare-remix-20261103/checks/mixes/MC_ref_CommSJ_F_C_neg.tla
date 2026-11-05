---- MODULE MC_ref_CommSJ_F_C_neg ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {}
MCSym == Permutations(Sites)
CBad == INSTANCE CommSJ_C WITH commSJ_c <- CHOOSE x \in {CommSJ_F!AbsCInit} : TRUE
BadStep == [][CBad!Next \/ UNCHANGED <<CommSJ_F!AbsCInit, Proj_CommSJ>>]_allVars
====
