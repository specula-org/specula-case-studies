---- MODULE MC_h4A_all_s2l2a2_t50 ----
EXTENDS MixR, Props, GenericProps, PropsMR, AG, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"abort", "abortCmdError", "admissionError", "archiveError", "cancel", "cbFail", "cjCrash", "deadClient", "deployError", "launchError", "minClients", "netLoss", "outcomeReportFail", "payCallback", "payCompute", "payConsumer", "payDelete", "payProduce", "paySubmit", "prepFail", "pullTimeout", "resExpiry", "resultWaitTimeout", "rpcTimeout", "sjCrash", "slowAdminStop", "slowEnvelope", "slowSJTeardown", "sourceFailure", "storeError", "submitTimeout", "taskTimeout", "trainerError", "transportFail", "txTimeout"}
MCProfile == {}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..50) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
