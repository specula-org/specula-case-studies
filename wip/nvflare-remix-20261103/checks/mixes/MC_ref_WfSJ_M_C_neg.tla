---- MODULE MC_ref_WfSJ_M_C_neg ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "M", Net |-> "R"]
MCFaults == {}
MCSym == Permutations(Sites)
CBad == INSTANCE WfSJ_C WITH wfSJ_c <- CHOOSE x \in {WfSJ_M!AbsCInit} : TRUE
BadStep == [][CBad!Next \/ UNCHANGED <<WfSJ_M!AbsCInit, Proj_WfSJ>>]_allVars
====
