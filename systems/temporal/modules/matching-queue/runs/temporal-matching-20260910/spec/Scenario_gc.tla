---------------- MODULE Scenario_gc ----------------
EXTENDS RecoveryFairness
CONSTANTS w1, w2
VARIABLE stage
scenarioVars == <<mcvars, stage>>
ScenarioInit == MCInit /\ stage = 0
SeedLength == 32
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
      [] stage = 14 -> MCAddTask(2, w2, 1)
      [] stage = 15 -> (B!TrySyncMatchFallback(2) /\ UNCHANGED faults)
      [] stage = 16 -> (B!SpoolTask(2) /\ UNCHANGED faults)
      [] stage = 17 -> (B!TaskWriterDequeue(1) /\ UNCHANGED faults)
      [] stage = 18 -> (B!AssignTaskIDs(1) /\ UNCHANGED faults)
      [] stage = 19 -> (B!CreateTasksBegin(1) /\ UNCHANGED faults)
      [] stage = 20 -> (B!CreateTasksCommit(1) /\ UNCHANGED faults)
      [] stage = 21 -> (B!CreateTasksReturn(1, "ok") /\ UNCHANGED faults)
      [] stage = 22 -> (B!SignalNewTasksBypass(1) /\ UNCHANGED faults)
      [] stage = 23 -> (B!AddTaskToMatcher(1, 2) /\ UNCHANGED faults)
      [] stage = 24 -> (B!SignalReadersDone(1) /\ UNCHANGED faults)
      [] stage = 25 -> (B!TaskWriterPublish(1) /\ UNCHANGED faults)
      [] stage = 26 -> (B!AppendTaskReceive(2) /\ UNCHANGED faults)
      [] stage = 27 -> (B!AddTaskReply(2) /\ UNCHANGED faults)
      [] stage = 28 -> (B!PollTask(1, 1, 1) /\ UNCHANGED faults)
      [] stage = 29 -> (B!RecordTaskStartedBegin(1, 1) /\ UNCHANGED faults)
      [] stage = 30 -> (B!RecordTaskStarted(1) /\ UNCHANGED faults)
      [] stage = 31 -> (B!RecordTaskStartedReply(1) /\ UNCHANGED faults)
      [] OTHER -> FALSE
ScenarioNext ==
    \/ /\ stage < SeedLength /\ Track(SeedAction) /\ stage' = stage + 1
    \/ /\ stage = SeedLength /\ ContractNext /\ UNCHANGED stage
ScenarioSpec == ScenarioInit /\ [][ScenarioNext]_scenarioVars
ScenarioLiveSpec == ScenarioSpec /\ WF_scenarioVars(stage < SeedLength /\ Track(SeedAction) /\ stage' = stage + 1) /\ RecoveryScheduling
ScenarioView == <<ContractView, stage>>
SeedReached == stage = SeedLength
=============================================================================
