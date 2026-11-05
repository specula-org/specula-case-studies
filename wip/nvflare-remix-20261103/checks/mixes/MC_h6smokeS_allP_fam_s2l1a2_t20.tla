---- MODULE MC_h6smokeS_allP_fam_s2l1a2_t20 ----
EXTENDS MixR, Props, GenericProps, PropsMR, PropsLocal, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "L"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"abort", "abortCmdError", "admissionError", "archiveError", "cancel", "cbFail", "cjCrash", "cpCrash", "deadClient", "deleteJob", "deployError", "launchError", "minClients", "netLoss", "outcomeReportFail", "payCallback", "payCompute", "payConsumer", "payDelete", "payProduce", "paySubmit", "prepFail", "pullTimeout", "resExpiry", "resultWaitTimeout", "rpcTimeout", "sjCrash", "slowEnvelope", "slowSJTeardown", "sourceFailure", "spCrash", "storeError", "submitTimeout", "taskTimeout", "trainerError", "transportFail", "txTimeout"}
MCProfile == {"nonStrictStart", "otherJob", "errResilient", "cseTasks", "wfTolerant", "lossBudget3"}
MCSym == Permutations(Sites)

Throttle == rare' = rare \/ RandomElement(1..20) = 1 \/ ~ENABLED (RNext /\ rare' = rare)
GNext == RNext \/ ((DoneStutter \/ ((AtBoundAny \/ OverBudget \/ KnownStuck) /\ UNCHANGED portVars)) /\ UNCHANGED <<privVars, rare>>)
====
