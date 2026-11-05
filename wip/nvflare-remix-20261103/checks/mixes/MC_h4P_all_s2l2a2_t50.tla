---- MODULE MC_h4P_all_s2l2a2_t50 ----
EXTENDS MixR, Props, GenericProps, PropsMR, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "L"]
MCSiteGrain == ("JobCP" :> (s1 :> "F" @@ s2 :> "C") @@ "RunCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "TaskCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "Trainer" :> (s1 :> "F" @@ s2 :> "C") @@ "PaySrc" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"abort", "abortCmdError", "admissionError", "archiveError", "cancel", "cbFail", "cjCrash", "deadClient", "deployError", "launchError", "minClients", "netLoss", "outcomeReportFail", "payCallback", "payCompute", "payConsumer", "payDelete", "payProduce", "paySubmit", "prepFail", "pullTimeout", "resExpiry", "resultWaitTimeout", "rpcTimeout", "sjCrash", "slowAdminStop", "slowEnvelope", "slowSJTeardown", "sourceFailure", "storeError", "submitTimeout", "taskTimeout", "trainerError", "transportFail", "txTimeout"}
MCProfile == {}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..50) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
