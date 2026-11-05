---- MODULE MC_sim100b_CFFs1FFCCCCL_mixed_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "F", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == ("RunCJ" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"abort", "cbFail", "cjCrash", "outcomeTimeout", "pullTimeout", "resExpiry", "rpcTimeout", "slowSJTeardown", "submitTimeout", "taskTimeout", "txTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
