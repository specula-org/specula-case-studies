---- MODULE MC_jref_JobSP_f1_R ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCFaults == {"cjCrash", "abort", "outcomeReportFail", "deployError", "launchError", "storeError", "rpcTimeout", "outcomeTimeout", "archiveError", "admissionError", "resExpiry"}
MCSym == Permutations(Sites)
CRef == INSTANCE JobSP_C WITH jobSP_c <- JobSP_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<JobSP_F!AbsC, Proj_JobSP>>]_allVars
====
