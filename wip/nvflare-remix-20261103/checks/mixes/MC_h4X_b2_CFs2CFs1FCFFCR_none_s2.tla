---- MODULE MC_h4X_b2_CFs2CFs1FCFFCR_none_s2 ----
EXTENDS Mix, Props, GenericProps, PropsMR, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "F", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == ("JobCP" :> (s1 :> "C" @@ s2 :> "F") @@ "TaskCJ" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {}
MCProfile == {}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ ((AtBoundAny \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
