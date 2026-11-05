---- MODULE MC_sim100b_FCFs2CCFFCFR_errors_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "C", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == ("RunCJ" :> (s1 :> "C" @@ s2 :> "F"))
MCFaults == {"cbFail", "deployError", "launchError", "outcomeTimeout", "payConsumer", "payProduce", "prepFail", "pullTimeout", "resExpiry", "rpcTimeout", "storeError", "submitTimeout", "txTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
