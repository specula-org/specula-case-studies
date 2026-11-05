---- MODULE MC_sim100b_FCCCFs1CFFCL_errors_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == ("Trainer" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"cbFail", "deployError", "launchError", "outcomeTimeout", "payConsumer", "payProduce", "prepFail", "pullTimeout", "resExpiry", "rpcTimeout", "storeError", "submitTimeout", "txTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
