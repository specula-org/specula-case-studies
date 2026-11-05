---- MODULE MC_agR_job ----
EXTENDS Mix, Props, AG, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "sjCrash", "taskTimeout", "abort", "netLoss", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "resExpiry", "deadClient", "launchError"}
MCSym == Permutations(Sites)

====
