---- MODULE MC_jref_RunCJ_neg ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCFaults == {"cjCrash", "abort", "outcomeReportFail", "deployError", "launchError", "storeError", "rpcTimeout", "outcomeTimeout", "archiveError", "admissionError", "resExpiry"}
MCSym == Permutations(Sites)
CBad == INSTANCE RunCJ_C WITH runCJ_c <- CHOOSE x \in {RunCJ_F!AbsCInit} : TRUE
BadStep == [][CBad!Next \/ UNCHANGED <<RunCJ_F!AbsCInit, Proj_RunCJ>>]_allVars
====
