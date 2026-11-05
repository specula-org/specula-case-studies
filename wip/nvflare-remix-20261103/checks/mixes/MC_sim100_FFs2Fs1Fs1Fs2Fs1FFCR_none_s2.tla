---- MODULE MC_sim100_FFs2Fs1Fs1Fs2Fs1FFCR_none_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == ("JobCP" :> (s1 :> "C" @@ s2 :> "F") @@ "RunCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "TaskCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "Trainer" :> (s1 :> "C" @@ s2 :> "F") @@ "PaySrc" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
