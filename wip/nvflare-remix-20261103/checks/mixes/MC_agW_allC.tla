---- MODULE MC_agW_allC ----
EXTENDS Mix, Props, AG, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "sjCrash", "taskTimeout", "abort", "netLoss", "cbFail", "prepFail", "deadClient", "minClients", "cancel", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "resExpiry"}
MCSym == Permutations(Sites)

====
