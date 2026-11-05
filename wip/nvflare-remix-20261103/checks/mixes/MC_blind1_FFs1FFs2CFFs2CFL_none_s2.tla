---- MODULE MC_blind1_FFs1FFs2CFFs2CFL_none_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "F", Net |-> "L"]
MCSiteGrain == ("JobCP" :> (s1 :> "F" @@ s2 :> "C") @@ "TaskCJ" :> (s1 :> "C" @@ s2 :> "F") @@ "PayRcv" :> (s1 :> "C" @@ s2 :> "F"))
MCFaults == {}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
