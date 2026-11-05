---- MODULE MC_h4C_all_allF_s2l1a2_nothr ----
EXTENDS Mix, Props, GenericProps, PropsMR, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"abort", "abortCmdError", "admissionError", "archiveError", "cancel", "cbFail", "cjCrash", "deadClient", "deployError", "launchError", "minClients", "netLoss", "outcomeReportFail", "payCallback", "payCompute", "payConsumer", "payDelete", "payProduce", "paySubmit", "prepFail", "pullTimeout", "resExpiry", "resultWaitTimeout", "rpcTimeout", "sjCrash", "slowAdminStop", "slowEnvelope", "slowSJTeardown", "sourceFailure", "storeError", "submitTimeout", "taskTimeout", "trainerError", "transportFail", "txTimeout"}
MCProfile == {}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ ((AtBoundAny \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
