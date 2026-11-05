---- MODULE MC_sm4_h4P_tail_s2l2a2_t50 ----
EXTENDS MixR, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == ("RunCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "TaskCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "PaySrc" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"taskTimeout", "minClients", "cancel", "slowEnvelope", "slowSJTeardown", "pullTimeout", "txTimeout", "sourceFailure", "payConsumer", "payProduce", "submitTimeout"}
MCProfile == {"wfTolerant"}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..50) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
