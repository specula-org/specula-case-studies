---- MODULE MC_agP_allC ----
EXTENDS Mix, Props, AG, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "sjCrash", "taskTimeout", "abort", "abortCmdError", "netLoss", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "resExpiry", "deadClient", "launchError", "transportFail"}
MCSym == Permutations(Sites)

====
