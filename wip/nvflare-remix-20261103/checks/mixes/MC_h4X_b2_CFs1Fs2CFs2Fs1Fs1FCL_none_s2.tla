---- MODULE MC_h4X_b2_CFs1Fs2CFs2Fs1Fs1FCL_none_s2 ----
EXTENDS Mix, Props, GenericProps, PropsMR, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == ("JobCP" :> (s1 :> "F" @@ s2 :> "C") @@ "RunCJ" :> (s1 :> "C" @@ s2 :> "F") @@ "Trainer" :> (s1 :> "C" @@ s2 :> "F") @@ "PaySrc" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {}
MCProfile == {}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ ((AtBoundAny \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
