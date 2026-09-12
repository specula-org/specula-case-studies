--------------------------- MODULE Fixture --------------------------------
EXTENDS base, Json
VARIABLE step
fvars == <<vars,step>>
Snapshot == [db |-> db,op |-> op,pending |-> pending,rt |-> rt,audit |-> audit,deletion |-> deletion,used |-> used]
FInit == /\ Init /\ step = 1 /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "Bootstrap", config |-> [revision |-> "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025", backend |-> "SQL", ioConcurrency |-> 1, historyLimit |-> 16, startMapPresent |-> TRUE, scannerAfterRequestDeadline |-> TRUE, runs |-> <<"a","b","c">>, ops |-> <<"p">>, resetIDs |-> <<"reset1">>, startIDs |-> <<"start1">>, updateIDs |-> <<"u1","u2">>, payloads |-> <<"x","y">>],state |-> Snapshot]))
FNext ==
    \/ /\ step = 1
       /\ StartWorkflowExecution("p","a","start1")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "StartWorkflowExecution",args |-> [p |-> "p", r |-> "a", id |-> "start1"],state |-> Snapshot']))
    \/ /\ step = 2
       /\ CreateWorkflowExecution_Start("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "CreateWorkflowExecution_Start",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 3
       /\ AppendHistoryNodes("a")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "AppendHistoryNodes",args |-> [r |-> "a"],state |-> Snapshot']))
    \/ /\ step = 4
       /\ CommitWorkflowExecution("a")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "CommitWorkflowExecution",args |-> [r |-> "a"],state |-> Snapshot']))
    \/ /\ step = 5
       /\ PersistenceReturn("a")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "PersistenceReturn",args |-> [r |-> "a"],state |-> Snapshot']))
    \/ /\ step = 6
       /\ Invoke_ReturnSuccess("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "Invoke_ReturnSuccess",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 7
       /\ ReleaseWorkflowLease_Success("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "ReleaseWorkflowLease_Success",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 8
       /\ ReceiveResetResponse("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "ReceiveResetResponse",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 9
       /\ AddWorkflowTaskStartedEvent("a")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "AddWorkflowTaskStartedEvent",args |-> [r |-> "a"],state |-> Snapshot']))
    \/ /\ step = 10
       /\ ResetWorkflowExecution("p","reset1","a",2,{})
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "ResetWorkflowExecution",args |-> [p |-> "p", q |-> "reset1", b |-> "a", cut |-> 2, ex |-> <<>>],state |-> Snapshot']))
    \/ /\ step = 11
       /\ GetWorkflowLease_Base("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "GetWorkflowLease_Base",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 12
       /\ GetCurrentWorkflowRunID("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "GetCurrentWorkflowRunID",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 13
       /\ GetWorkflowLease_Current("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "GetWorkflowLease_Current",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 14
       /\ Invoke_Deduplicate("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "Invoke_Deduplicate",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 15
       /\ Invoke_NewRunID("p","b")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "Invoke_NewRunID",args |-> [p |-> "p", r |-> "b"],state |-> Snapshot']))
    \/ /\ step = 16
       /\ ResetWorkflow_UpdateResetRunID("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "ResetWorkflow_UpdateResetRunID",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 17
       /\ ForkHistoryBranch("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "ForkHistoryBranch",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 18
       /\ Rebuild("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "Rebuild",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 19
       /\ ReadHistoryBranch("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "ReadHistoryBranch",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 20
       /\ ReapplyEventsFromBranch_NextRun("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "ReapplyEventsFromBranch_NextRun",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 21
       /\ ScheduleWorkflowTask("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "ScheduleWorkflowTask",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 22
       /\ UpdateWorkflowExecution_WithNew("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "UpdateWorkflowExecution_WithNew",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 23
       /\ AppendHistoryNodes_Current("b")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "AppendHistoryNodes_Current",args |-> [r |-> "b"],state |-> Snapshot']))
    \/ /\ step = 24
       /\ AppendHistoryNodes("b")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "AppendHistoryNodes",args |-> [r |-> "b"],state |-> Snapshot']))
    \/ /\ step = 25
       /\ CommitWorkflowExecution("b")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "CommitWorkflowExecution",args |-> [r |-> "b"],state |-> Snapshot']))
    \/ /\ step = 26
       /\ PersistenceReturn("b")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "PersistenceReturn",args |-> [r |-> "b"],state |-> Snapshot']))
    \/ /\ step = 27
       /\ Invoke_ReturnSuccess("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "Invoke_ReturnSuccess",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 28
       /\ ReleaseWorkflowLease_Success("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "ReleaseWorkflowLease_Success",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 29
       /\ ReceiveResetResponse("p")
       /\ step' = step+1
       /\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "ReceiveResetResponse",args |-> [p |-> "p"],state |-> Snapshot']))
    \/ /\ step = 30
       /\ UNCHANGED fvars
=============================================================================
