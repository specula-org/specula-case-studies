---- MODULE MC_jref_JobCP_neg ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "F", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCFaults == {"cjCrash", "abort", "outcomeReportFail", "deployError", "launchError", "storeError", "rpcTimeout", "outcomeTimeout", "archiveError", "admissionError", "resExpiry"}
MCSym == Permutations(Sites)
CBad == INSTANCE JobCP_C WITH jobCP_c <- CHOOSE x \in {JobCP_F!AbsCInit} : TRUE
BadStep == [][CBad!Next \/ UNCHANGED <<JobCP_F!AbsCInit, Proj_JobCP>>]_allVars
====
