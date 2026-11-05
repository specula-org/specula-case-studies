---- MODULE MC_h4C_restart_allF_s2l1a2_nothr ----
EXTENDS Mix, Props, GenericProps, PropsMR, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "sjCrash", "launchError", "deployError", "abort", "resExpiry", "rpcTimeout", "taskTimeout"}
MCProfile == {"wfTolerant"}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ ((AtBoundAny \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
