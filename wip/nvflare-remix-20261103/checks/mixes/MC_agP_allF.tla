---- MODULE MC_agP_allF ----
EXTENDS Mix, Props, AG, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "sjCrash", "taskTimeout", "abort", "abortCmdError", "netLoss", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "resExpiry", "deadClient", "launchError", "transportFail"}
MCSym == Permutations(Sites)

====
