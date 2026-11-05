---- MODULE MC_h4R_task_s1l1a1_k2 ----
EXTENDS MixR, Props, GenericProps, PropsMR, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "F", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"trainerError", "resultWaitTimeout", "taskTimeout", "cbFail", "prepFail", "payCallback", "paySubmit", "payCompute", "payDelete", "payConsumer"}
MCProfile == {}
MCSym == Permutations(Sites)

GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
