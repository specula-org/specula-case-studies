---- MODULE MC_agP_payfed ----
EXTENDS Mix, Props, AG, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "sjCrash", "taskTimeout", "abort", "abortCmdError", "netLoss", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "resExpiry", "deadClient", "launchError", "transportFail"}
MCSym == Permutations(Sites)

====
