---- MODULE MC_agP_mixL ----
EXTENDS Mix, Props, AG, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "F", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "F", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "sjCrash", "taskTimeout", "abort", "abortCmdError", "netLoss", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "resExpiry", "deadClient", "launchError", "transportFail"}
MCSym == Permutations(Sites)

====
