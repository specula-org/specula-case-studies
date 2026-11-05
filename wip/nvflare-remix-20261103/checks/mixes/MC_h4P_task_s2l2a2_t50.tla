---- MODULE MC_h4P_task_s2l2a2_t50 ----
EXTENDS MixR, Props, GenericProps, PropsMR, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == ("TaskCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "Trainer" :> (s1 :> "F" @@ s2 :> "C") @@ "PaySrc" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"trainerError", "resultWaitTimeout", "taskTimeout", "cbFail", "prepFail", "payCallback", "paySubmit", "payCompute", "payDelete", "payConsumer"}
MCProfile == {}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..50) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
