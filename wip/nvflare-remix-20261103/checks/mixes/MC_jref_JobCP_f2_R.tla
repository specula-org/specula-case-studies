---- MODULE MC_jref_JobCP_f2_R ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "F", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCFaults == {"cjCrash", "abort", "outcomeReportFail", "deployError", "launchError", "storeError", "rpcTimeout", "outcomeTimeout", "archiveError", "admissionError", "resExpiry"}
MCSym == Permutations(Sites)
CRef == INSTANCE JobCP_C WITH jobCP_c <- JobCP_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<JobCP_F!AbsC, Proj_JobCP>>]_allVars
====
