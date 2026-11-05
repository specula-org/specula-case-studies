---- MODULE MC_h6smokeL_net_s3l1a2_t20 ----
EXTENDS MixR, Props, GenericProps, PropsMR, PropsLocal, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"netLoss", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "transportFail", "deadClient", "taskTimeout"}
MCProfile == {"wfTolerant", "lossBudget3"}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..20) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
