---- MODULE MC_jref_JobSP_neg ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCFaults == {"cjCrash", "abort", "outcomeReportFail", "deployError", "launchError", "storeError", "rpcTimeout", "outcomeTimeout", "archiveError", "admissionError", "resExpiry"}
MCSym == Permutations(Sites)
CBad == INSTANCE JobSP_C WITH jobSP_c <- CHOOSE x \in {JobSP_F!AbsCInit} : TRUE
BadStep == [][CBad!Next \/ UNCHANGED <<JobSP_F!AbsCInit, Proj_JobSP>>]_allVars
====
