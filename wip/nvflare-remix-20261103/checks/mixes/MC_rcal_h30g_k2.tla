---- MODULE MC_rcal_h30g_k2 ----
EXTENDS MixR, Props, GenericProps, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "C", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"taskTimeout", "cancel", "slowSJTeardown", "slowEnvelope"}
MCSym == Permutations(Sites)

GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
