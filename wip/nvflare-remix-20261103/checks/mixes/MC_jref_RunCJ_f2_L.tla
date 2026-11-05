---- MODULE MC_jref_RunCJ_f2_L ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "L"]
MCFaults == {"cjCrash", "abort", "outcomeReportFail", "deployError", "launchError", "storeError", "rpcTimeout", "outcomeTimeout", "archiveError", "admissionError", "resExpiry", "netLoss"}
MCSym == Permutations(Sites)
CRef == INSTANCE RunCJ_C WITH runCJ_c <- RunCJ_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<RunCJ_F!AbsC, Proj_RunCJ>>]_allVars
====
