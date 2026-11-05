---- MODULE MC_blind2_FFs2CFs2Fs2CCFFL_mixed_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "F", Net |-> "L"]
MCSiteGrain == ("JobCP" :> (s1 :> "C" @@ s2 :> "F") @@ "TaskCJ" :> (s1 :> "C" @@ s2 :> "F") @@ "Trainer" :> (s1 :> "C" @@ s2 :> "F"))
MCFaults == {"cjCrash", "taskTimeout", "abort", "pullTimeout", "cbFail", "slowSJTeardown"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
