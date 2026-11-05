---- MODULE MC_sm4_h4R_tail_s1l1a1_k2 ----
EXTENDS MixR, Props, GenericProps, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"taskTimeout", "minClients", "cancel", "slowEnvelope", "slowSJTeardown", "pullTimeout", "txTimeout", "sourceFailure", "payConsumer", "payProduce", "submitTimeout"}
MCProfile == {"wfTolerant"}
MCSym == Permutations(Sites)

GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
