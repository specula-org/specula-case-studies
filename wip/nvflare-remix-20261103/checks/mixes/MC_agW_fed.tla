---- MODULE MC_agW_fed ----
EXTENDS Mix, Props, AG, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "sjCrash", "taskTimeout", "abort", "netLoss", "cbFail", "prepFail", "deadClient", "minClients", "cancel", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "resExpiry"}
MCSym == Permutations(Sites)

====
