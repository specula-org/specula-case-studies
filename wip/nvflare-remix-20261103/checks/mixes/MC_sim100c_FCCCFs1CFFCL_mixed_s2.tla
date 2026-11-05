---- MODULE MC_sim100c_FCCCFs1CFFCL_mixed_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == ("Trainer" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"abort", "cbFail", "cjCrash", "deadClient", "pullTimeout", "resExpiry", "rpcTimeout", "slowAdminStop", "slowSJTeardown", "submitTimeout", "taskTimeout", "txTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ (AtBoundAny /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
