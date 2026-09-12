--------------------------- MODULE CacheWitness ---------------------------
EXTENDS MC
CONSTANTS c1,c2,u1,u2,v1,v2,h1,h2
VARIABLE step
wvars == <<s,faults,step>>
WInit == MCInit /\ step = 1
Step1 == /\ step = 1 /\ MCUpdateWorkflowExecution(c1,u1,"COMPLETED") /\ step' = step+1
Step2 == /\ step = 2 /\ MCUpdaterApplyRequestNew(c1) /\ step' = step+1
Step3 == /\ step = 3 /\ MCAddWorkflowTaskScheduledEvent /\ step' = step+1
Step4 == /\ step = 4 /\ MCAddWorkflowTaskToMatching(1) /\ step' = step+1
Step5 == /\ step = 5 /\ MCRecordWorkflowTaskStarted(1) /\ step' = step+1
Step6 == /\ step = 6 /\ MCCreateRecordWorkflowTaskStartedResponse /\ step' = step+1
Step7 == /\ step = 7 /\ MCWorkerAcceptance(Len(s.workers),u1) /\ step' = step+1
Step8 == /\ step = 8 /\ MCWorkerResponse(Len(s.workers),u1,"success",v1) /\ step' = step+1
Step9 == /\ step = 9 /\ MCWorkerSendCompletion(Len(s.workers)) /\ step' = step+1
Step10 == /\ step = 10 /\ MCRespondWorkflowTaskCompleted(Len(s.workers)) /\ step' = step+1
Step11 == /\ step = 11 /\ MCAddWorkflowTaskCompletedEvent /\ step' = step+1
Step12 == /\ step = 12 /\ MCOnAcceptanceMsg /\ step' = step+1
Step13 == /\ step = 13 /\ MCOnResponseMsg /\ step' = step+1
Step14 == /\ step = 14 /\ MCHandleCommandsDone /\ step' = step+1
Step15 == /\ step = 15 /\ MCPrepareWorkflowMutation /\ step' = step+1
Step16 == /\ step = 16 /\ MCUpdateWorkflowExecutionWithNew /\ step' = step+1
Step17 == /\ step = 17 /\ MCAppendHistoryNodes /\ step' = step+1
Step18 == /\ step = 18 /\ MCExecutionTransactionBegin /\ step' = step+1
Step19 == /\ step = 19 /\ MCExecutionTransactionNoncommit /\ step' = step+1
Step20 == /\ step = 20 /\ MCHandleWriteResult /\ step' = step+1
Step21 == /\ step = 21 /\ MCContextClearBegin /\ step' = step+1
Step22 == /\ step = 22 /\ MCRegistryClearAbort(1) /\ step' = step+1
Step23 == /\ step = 23 /\ MCRegistryClearAbortSecond /\ step' = step+1
Step24 == /\ step = 24 /\ MCContextClearDone /\ step' = step+1
Step25 == /\ step = 25 /\ MCBufferCancel /\ step' = step+1
Step26 == /\ step = 26 /\ MCBufferCancel /\ step' = step+1
Step27 == /\ step = 27 /\ MCBufferCancelDone /\ step' = step+1
Step28 == /\ step = 28 /\ MCWaitLifecycleStageOutcome(c1) /\ step' = step+1
Step29 == /\ step = 29 /\ MCWaitLifecycleStageAccepted(c1) /\ step' = step+1
Step30 == /\ step = 30 /\ MCCreateUpdateResponse(c1) /\ step' = step+1
Step31 == /\ step = 31 /\ MCReceiveUpdateResponse(c1) /\ step' = step+1
Step32 == /\ step = 32 /\ MCLoseShardOwnership /\ step' = step+1
Step33 == /\ step = 33 /\ MCContextClearBegin /\ step' = step+1
Step34 == /\ step = 34 /\ MCContextClearDone /\ step' = step+1
Step35 == /\ step = 35 /\ MCAcquireShard(h2) /\ step' = step+1
Step36 == /\ step = 36 /\ MCLoadMutableState /\ step' = step+1
Step37 == /\ step = 37 /\ MCUpdateWorkflowExecution(c2,u2,"COMPLETED") /\ step' = step+1
Step38 == /\ step = 38 /\ MCUpdaterApplyRequestNew(c2) /\ step' = step+1
Step39 == /\ step = 39 /\ MCAddWorkflowTaskScheduledEvent /\ step' = step+1
Step40 == /\ step = 40 /\ MCAddWorkflowTaskToMatching(1) /\ step' = step+1
Step41 == /\ step = 41 /\ MCRecordWorkflowTaskStarted(1) /\ step' = step+1
Step42 == /\ step = 42 /\ MCCreateRecordWorkflowTaskStartedResponse /\ step' = step+1
Step43 == /\ step = 43 /\ MCWorkerAcceptance(Len(s.workers),u2) /\ step' = step+1
Step44 == /\ step = 44 /\ MCWorkerResponse(Len(s.workers),u2,"success",v2) /\ step' = step+1
Step45 == /\ step = 45 /\ MCWorkerSendCompletion(Len(s.workers)) /\ step' = step+1
Step46 == /\ step = 46 /\ MCRespondWorkflowTaskCompleted(Len(s.workers)) /\ step' = step+1
Step47 == /\ step = 47 /\ MCAddWorkflowTaskCompletedEvent /\ step' = step+1
Step48 == /\ step = 48 /\ MCOnAcceptanceMsg /\ step' = step+1
Step49 == /\ step = 49 /\ MCOnResponseMsg /\ step' = step+1
Step50 == /\ step = 50 /\ MCHandleCommandsDone /\ step' = step+1
Step51 == /\ step = 51 /\ MCPrepareWorkflowMutation /\ step' = step+1
Step52 == /\ step = 52 /\ MCUpdateWorkflowExecutionWithNew /\ step' = step+1
Step53 == /\ step = 53 /\ MCAppendHistoryNodes /\ step' = step+1
Step54 == /\ step = 54 /\ MCExecutionTransactionBegin /\ step' = step+1
Step55 == /\ step = 55 /\ MCExecutionTransactionCommit /\ step' = step+1
Step56 == /\ step = 56 /\ MCHandleWriteResult /\ step' = step+1
Step57 == /\ step = 57 /\ MCBufferApplyFirst /\ step' = step+1
Step58 == /\ step = 58 /\ MCBufferApplyFirst /\ step' = step+1
Step59 == /\ step = 59 /\ MCBufferApplySecond /\ step' = step+1
Step60 == /\ step = 60 /\ MCBufferApplyDone /\ step' = step+1
Step61 == /\ step = 61 /\ MCCreateRespondWorkflowTaskCompletedResponse /\ step' = step+1
Step62 == /\ step = 62 /\ MCRespondWorkflowTaskCompletedReturn /\ step' = step+1
Step63 == /\ step = 63 /\ MCWaitLifecycleStageOutcome(c2) /\ step' = step+1
Step64 == /\ step = 64 /\ MCCreateUpdateResponse(c2) /\ step' = step+1
Step65 == /\ step = 65 /\ MCReceiveUpdateResponse(c2) /\ step' = step+1
Step66 == /\ step = 66 /\ MCLoseShardOwnership /\ step' = step+1
Step67 == /\ step = 67 /\ MCContextClearBegin /\ step' = step+1
Step68 == /\ step = 68 /\ MCContextClearDone /\ step' = step+1
Step69 == /\ step = 69 /\ MCAcquireShard(h1) /\ step' = step+1
Step70 == /\ step = 70 /\ MCLoadMutableState /\ step' = step+1
Step71 == /\ step = 71 /\ MCUpdateWorkflowExecution(c1,u2,"COMPLETED") /\ step' = step+1
Step72 == /\ step = 72 /\ MCGetUpdateOutcome(c1) /\ step' = step+1
Step73 == /\ step = 73 /\ MCCreateUpdateResponse(c1) /\ step' = step+1
Step74 == /\ step = 74 /\ MCReceiveUpdateResponse(c1) /\ step' = step+1
WNext == Step1 \/ Step2 \/ Step3 \/ Step4 \/ Step5 \/ Step6 \/ Step7 \/ Step8 \/ Step9 \/ Step10 \/ Step11 \/ Step12 \/ Step13 \/ Step14 \/ Step15 \/ Step16 \/ Step17 \/ Step18 \/ Step19 \/ Step20 \/ Step21 \/ Step22 \/ Step23 \/ Step24 \/ Step25 \/ Step26 \/ Step27 \/ Step28 \/ Step29 \/ Step30 \/ Step31 \/ Step32 \/ Step33 \/ Step34 \/ Step35 \/ Step36 \/ Step37 \/ Step38 \/ Step39 \/ Step40 \/ Step41 \/ Step42 \/ Step43 \/ Step44 \/ Step45 \/ Step46 \/ Step47 \/ Step48 \/ Step49 \/ Step50 \/ Step51 \/ Step52 \/ Step53 \/ Step54 \/ Step55 \/ Step56 \/ Step57 \/ Step58 \/ Step59 \/ Step60 \/ Step61 \/ Step62 \/ Step63 \/ Step64 \/ Step65 \/ Step66 \/ Step67 \/ Step68 \/ Step69 \/ Step70 \/ Step71 \/ Step72 \/ Step73 \/ Step74
WSpec == WInit /\ [][WNext]_wvars
WitnessReached == step = 75
=============================================================================
