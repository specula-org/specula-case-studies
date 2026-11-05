---- MODULE MC_zr_task_cF_s2l1a2_t200 ----
EXTENDS MixR, Props, GenericProps, PropsMR, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "F", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"trainerError", "resultWaitTimeout", "taskTimeout", "cbFail", "prepFail", "payCallback", "paySubmit", "payCompute", "payDelete", "payConsumer"}
MCProfile == {}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..200) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
