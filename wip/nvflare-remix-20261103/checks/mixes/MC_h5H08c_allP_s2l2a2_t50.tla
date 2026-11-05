---- MODULE MC_h5H08c_allP_s2l2a2_t50 ----
EXTENDS MixR, Props, GenericProps, PropsMR, PropsLocal, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"abort", "abortCmdError", "admissionError", "archiveError", "cancel", "cbFail", "cjCrash", "deadClient", "deployError", "launchError", "minClients", "netLoss", "outcomeReportFail", "payCallback", "payCompute", "payConsumer", "payDelete", "payProduce", "paySubmit", "prepFail", "pullTimeout", "resExpiry", "resultWaitTimeout", "sjCrash", "slowEnvelope", "slowSJTeardown", "sourceFailure", "storeError", "submitTimeout", "taskTimeout", "trainerError", "transportFail", "txTimeout"}
MCProfile == {"nonStrictStart", "otherJob", "errResilient", "cseTasks", "wfTolerant", "lossBudget3"}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..50) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
