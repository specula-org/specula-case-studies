---- MODULE MC_h4X_b2_CFFs1FFFFs2CCL_none_s2 ----
EXTENDS Mix, Props, GenericProps, PropsMR, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "F", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "C", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == ("RunCJ" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {}
MCProfile == {}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ ((AtBoundAny \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
