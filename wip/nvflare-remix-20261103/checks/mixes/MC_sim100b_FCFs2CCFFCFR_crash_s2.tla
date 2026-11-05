---- MODULE MC_sim100b_FCFs2CCFFCFR_crash_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "C", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == ("RunCJ" :> (s1 :> "C" @@ s2 :> "F"))
MCFaults == {"cjCrash", "outcomeTimeout", "pullTimeout", "resExpiry", "rpcTimeout", "sjCrash", "submitTimeout", "txTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
