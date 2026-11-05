---- MODULE MC_h6smokeL_proc_s3l1a2_t20 ----
EXTENDS MixR, Props, GenericProps, PropsMR, PropsLocal, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"spCrash", "cpCrash", "cjCrash", "rpcTimeout", "taskTimeout", "deadClient", "abort"}
MCProfile == {"wfTolerant"}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..20) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
