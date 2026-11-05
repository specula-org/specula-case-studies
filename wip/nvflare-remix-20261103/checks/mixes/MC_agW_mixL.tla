---- MODULE MC_agW_mixL ----
EXTENDS Mix, Props, AG, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "sjCrash", "taskTimeout", "abort", "netLoss", "cbFail", "prepFail", "deadClient", "minClients", "cancel", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "resExpiry"}
MCSym == Permutations(Sites)

====
