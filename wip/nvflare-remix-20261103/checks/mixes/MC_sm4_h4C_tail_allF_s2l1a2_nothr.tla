---- MODULE MC_sm4_h4C_tail_allF_s2l1a2_nothr ----
EXTENDS Mix, Props, GenericProps, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"taskTimeout", "minClients", "cancel", "slowEnvelope", "slowSJTeardown", "pullTimeout", "txTimeout", "sourceFailure", "payConsumer", "payProduce", "submitTimeout"}
MCProfile == {"wfTolerant"}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ (AtBoundAny /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
