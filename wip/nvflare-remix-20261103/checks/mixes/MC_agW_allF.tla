---- MODULE MC_agW_allF ----
EXTENDS Mix, Props, AG, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "sjCrash", "taskTimeout", "abort", "netLoss", "cbFail", "prepFail", "deadClient", "minClients", "cancel", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "resExpiry"}
MCSym == Permutations(Sites)

====
