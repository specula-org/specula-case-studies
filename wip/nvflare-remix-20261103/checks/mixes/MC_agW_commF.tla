---- MODULE MC_agW_commF ----
EXTENDS Mix, Props, AG, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "sjCrash", "taskTimeout", "abort", "netLoss", "cbFail", "prepFail", "deadClient", "minClients", "cancel", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "resExpiry"}
MCSym == Permutations(Sites)

====
