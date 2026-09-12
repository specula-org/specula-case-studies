-------------------------- MODULE TraceFixture --------------------------
EXTENDS base, Json
VARIABLE n, records, header, written
fvars == <<s,n,records,header,written>>
FInit == /\ Init /\ n=1 /\ records = <<>> /\ written=FALSE
    /\ header=[tag |-> "temporal-update.meta", schema |-> 1,
         sourceRevision |-> "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025",
         constants |-> [updates |-> <<"u1","u2">>, values |-> <<"v1","v2">>, clients |-> <<"c1","c2">>,
                        hosts |-> <<"h1","h2">>, initialHost |-> "h1", namespaceID |-> "namespace",
                        workflowID |-> "workflow",runID |-> "run",eventVersion |-> 1,hostCacheEnabled |-> TRUE],
         initialState |-> s]
Step1 == /\ n=1 /\ UpdateWorkflowExecution("c1","u1","COMPLETED")
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "UpdateWorkflowExecution", ordinal |-> n,
                                  params |-> [c |-> "c1", u |-> "u1", stage |-> "COMPLETED"], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step2 == /\ n=2 /\ UpdaterApplyRequestNew("c1")
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "UpdaterApplyRequestNew", ordinal |-> n,
                                  params |-> [c |-> "c1"], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step3 == /\ n=3 /\ AddWorkflowTaskScheduledEvent
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "AddWorkflowTaskScheduledEvent", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step4 == /\ n=4 /\ AddWorkflowTaskToMatching(1)
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "AddWorkflowTaskToMatching", ordinal |-> n,
                                  params |-> [i |-> 1], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step5 == /\ n=5 /\ RecordWorkflowTaskStarted(1)
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "RecordWorkflowTaskStarted", ordinal |-> n,
                                  params |-> [i |-> 1], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step6 == /\ n=6 /\ CreateRecordWorkflowTaskStartedResponse
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "CreateRecordWorkflowTaskStartedResponse", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step7 == /\ n=7 /\ RecordWorkflowTaskStartedReturn(1)
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "RecordWorkflowTaskStartedReturn", ordinal |-> n,
                                  params |-> [i |-> 1], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step8 == /\ n=8 /\ WorkerAcceptance(1,"u1")
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "WorkerAcceptance", ordinal |-> n,
                                  params |-> [i |-> 1, u |-> "u1"], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step9 == /\ n=9 /\ WorkerResponse(1,"u1","success","v1")
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "WorkerResponse", ordinal |-> n,
                                  params |-> [i |-> 1, u |-> "u1", k |-> "success", v |-> "v1"], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step10 == /\ n=10 /\ WorkerSendCompletion(1)
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "WorkerSendCompletion", ordinal |-> n,
                                  params |-> [i |-> 1], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step11 == /\ n=11 /\ RespondWorkflowTaskCompleted(1)
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "RespondWorkflowTaskCompleted", ordinal |-> n,
                                  params |-> [i |-> 1], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step12 == /\ n=12 /\ AddWorkflowTaskCompletedEvent
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "AddWorkflowTaskCompletedEvent", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step13 == /\ n=13 /\ OnAcceptanceMsg
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "OnAcceptanceMsg", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step14 == /\ n=14 /\ OnResponseMsg
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "OnResponseMsg", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step15 == /\ n=15 /\ HandleCommandsDone
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "HandleCommandsDone", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step16 == /\ n=16 /\ PrepareWorkflowMutation
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "PrepareWorkflowMutation", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step17 == /\ n=17 /\ UpdateWorkflowExecutionWithNew
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "UpdateWorkflowExecutionWithNew", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step18 == /\ n=18 /\ AppendHistoryNodes
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "AppendHistoryNodes", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step19 == /\ n=19 /\ ExecutionTransactionBegin
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "ExecutionTransactionBegin", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step20 == /\ n=20 /\ ExecutionTransactionCommit
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "ExecutionTransactionCommit", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step21 == /\ n=21 /\ HandleWriteResult
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "HandleWriteResult", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step22 == /\ n=22 /\ BufferApplyFirst
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "BufferApplyFirst", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step23 == /\ n=23 /\ BufferApplyFirst
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "BufferApplyFirst", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step24 == /\ n=24 /\ WaitLifecycleStageOutcome("c1")
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "WaitLifecycleStageOutcome", ordinal |-> n,
                                  params |-> [c |-> "c1"], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step25 == /\ n=25 /\ BufferApplySecond
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "BufferApplySecond", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step26 == /\ n=26 /\ BufferApplyDone
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "BufferApplyDone", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step27 == /\ n=27 /\ CreateRespondWorkflowTaskCompletedResponse
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "CreateRespondWorkflowTaskCompletedResponse", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step28 == /\ n=28 /\ RespondWorkflowTaskCompletedReturn
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "RespondWorkflowTaskCompletedReturn", ordinal |-> n,
                                  params |-> [x \in {} |-> x], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step29 == /\ n=29 /\ CreateUpdateResponse("c1")
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "CreateUpdateResponse", ordinal |-> n,
                                  params |-> [c |-> "c1"], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Step30 == /\ n=30 /\ ReceiveUpdateResponse("c1")
    /\ records'=Append(records,[tag |-> "temporal-update", event |-> "ReceiveUpdateResponse", ordinal |-> n,
                                  params |-> [c |-> "c1"], post |-> s'])
    /\ n'=n+1 /\ UNCHANGED <<header,written>>
Write == /\ n=31 /\ ~written /\ ndJsonSerialize("checks/synthetic-healthy.ndjson",<<header>> \o records)
    /\ written'=TRUE /\ UNCHANGED <<s,n,records,header>>
FNext == Step1 \/ Step2 \/ Step3 \/ Step4 \/ Step5 \/ Step6 \/ Step7 \/ Step8 \/ Step9 \/ Step10 \/ Step11 \/ Step12 \/ Step13 \/ Step14 \/ Step15 \/ Step16 \/ Step17 \/ Step18 \/ Step19 \/ Step20 \/ Step21 \/ Step22 \/ Step23 \/ Step24 \/ Step25 \/ Step26 \/ Step27 \/ Step28 \/ Step29 \/ Step30 \/ Write
FSpec == FInit /\ [][FNext]_fvars
=============================================================================
