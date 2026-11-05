---- MODULE MC_h4X_b2_CFs1CFs1Fs2CFs1CFR_none_s2 ----
EXTENDS Mix, Props, GenericProps, PropsMR, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "C", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == ("JobCP" :> (s1 :> "F" @@ s2 :> "C") @@ "TaskCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "Trainer" :> (s1 :> "C" @@ s2 :> "F"))
MCFaults == {}
MCProfile == {}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ ((AtBoundAny \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
