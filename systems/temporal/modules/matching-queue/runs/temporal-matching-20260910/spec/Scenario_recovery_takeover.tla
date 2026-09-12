---------------- MODULE Scenario_recovery_takeover ----------------
EXTENDS RecoveryFairness
CONSTANTS w1, w2
VARIABLE stage
scenarioVars == <<mcvars, stage>>
ScenarioInit == MCInit /\ stage = 0
SeedLength == 24
SeedAction ==
    CASE stage = 0 -> MCAddTask(1, w1, 1)
      [] stage = 1 -> (B!TrySyncMatchFallback(1) /\ UNCHANGED faults)
      [] stage = 2 -> (B!SpoolTask(1) /\ UNCHANGED faults)
      [] stage = 3 -> (B!TaskWriterDequeue(1) /\ UNCHANGED faults)
      [] stage = 4 -> (B!AssignTaskIDs(1) /\ UNCHANGED faults)
      [] stage = 5 -> (B!CreateTasksBegin(1) /\ UNCHANGED faults)
      [] stage = 6 -> (B!CreateTasksCommit(1) /\ UNCHANGED faults)
      [] stage = 7 -> (B!CreateTasksReturn(1, "ok") /\ UNCHANGED faults)
      [] stage = 8 -> (B!SignalNewTasksBypass(1) /\ UNCHANGED faults)
      [] stage = 9 -> (B!AddTaskToMatcher(1, 1) /\ UNCHANGED faults)
      [] stage = 10 -> (B!SignalReadersDone(1) /\ UNCHANGED faults)
      [] stage = 11 -> (B!TaskWriterPublish(1) /\ UNCHANGED faults)
      [] stage = 12 -> (B!AppendTaskReceive(1) /\ UNCHANGED faults)
      [] stage = 13 -> (B!AddTaskReply(1) /\ UNCHANGED faults)
      [] stage = 14 -> MCStopBegin(1)
      [] stage = 15 -> (B!StopRefreshAck(1) /\ UNCHANGED faults)
      [] stage = 16 -> (B!StopSyncState(1) /\ UNCHANGED faults)
      [] stage = 17 -> (B!UpdateTaskQueueCommit(1) /\ UNCHANGED faults)
      [] stage = 18 -> (B!UpdateTaskQueueReturn(1) /\ UNCHANGED faults)
      [] stage = 19 -> (B!StopCancel(1) /\ UNCHANGED faults)
      [] stage = 20 -> MCTakeOverTaskQueueBegin(2)
      [] stage = 21 -> (B!TakeOverTaskQueueSnapshot(2) /\ UNCHANGED faults)
      [] stage = 22 -> (B!UpdateTaskQueueCommit(2) /\ UNCHANGED faults)
      [] stage = 23 -> (B!UpdateTaskQueueReturn(2) /\ UNCHANGED faults)
      [] OTHER -> FALSE
ScenarioNext ==
    \/ /\ stage < SeedLength /\ Track(SeedAction) /\ stage' = stage + 1
    \/ /\ stage = SeedLength /\ ContractNext /\ UNCHANGED stage
ScenarioSpec == ScenarioInit /\ [][ScenarioNext]_scenarioVars
ScenarioLiveSpec == ScenarioSpec /\ WF_scenarioVars(stage < SeedLength /\ Track(SeedAction) /\ stage' = stage + 1) /\ RecoveryScheduling
ScenarioView == <<ContractView, stage>>
SeedReached == stage = SeedLength
=============================================================================
