---- MODULE MC_mr_ref2_WfSJ_neg ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {}
MCSym == Permutations(Sites)
CBad == INSTANCE WfSJ_C WITH wfSJ_c <- CHOOSE x \in {WfSJ_F!AbsCInit} : TRUE
BadStep == [][CBad!Next \/ UNCHANGED <<WfSJ_F!AbsCInit, Proj_WfSJ>>]_allVars
====
