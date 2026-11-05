---- MODULE MC_sim100c_FFs2FFs2Fs1Fs2FCCL_mixed_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "C", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == ("JobCP" :> (s1 :> "C" @@ s2 :> "F") @@ "TaskCJ" :> (s1 :> "C" @@ s2 :> "F") @@ "Trainer" :> (s1 :> "F" @@ s2 :> "C") @@ "PaySrc" :> (s1 :> "C" @@ s2 :> "F"))
MCFaults == {"abort", "cbFail", "cjCrash", "deadClient", "pullTimeout", "resExpiry", "rpcTimeout", "slowAdminStop", "slowSJTeardown", "submitTimeout", "taskTimeout", "txTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ (AtBoundAny /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
