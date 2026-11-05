---- MODULE MC_ref_RunCJ_F_C ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"abort", "admissionError", "archiveError", "cjCrash", "deployError", "launchError", "outcomeReportFail", "outcomeTimeout", "resExpiry", "rpcTimeout", "storeError"}
MCSym == Permutations(Sites)
CRef == INSTANCE RunCJ_C WITH runCJ_c <- RunCJ_F!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<RunCJ_F!AbsC, Proj_RunCJ>>]_allVars
RefEnv == [][UNCHANGED <<runCJ_f, Proj_RunCJ>> => UNCHANGED RunCJ_F!AbsC]_allVars
====
