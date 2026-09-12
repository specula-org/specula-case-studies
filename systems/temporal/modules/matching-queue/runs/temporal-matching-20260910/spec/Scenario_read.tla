---------------- MODULE Scenario_read ----------------
EXTENDS RecoveryFairness
CONSTANTS w1, w2
VARIABLE stage
scenarioVars == <<mcvars, stage>>
ScenarioInit == MCInit /\ stage = 0
SeedLength == 11
SeedAction ==
    CASE stage = 0 -> (B!GetTasksPump(1) /\ UNCHANGED faults)
      [] stage = 1 -> MCAddTask(1, w1, 1)
      [] stage = 2 -> (B!TrySyncMatchFallback(1) /\ UNCHANGED faults)
      [] stage = 3 -> (B!SpoolTask(1) /\ UNCHANGED faults)
      [] stage = 4 -> (B!TaskWriterDequeue(1) /\ UNCHANGED faults)
      [] stage = 5 -> (B!AssignTaskIDs(1) /\ UNCHANGED faults)
      [] stage = 6 -> (B!CreateTasksBegin(1) /\ UNCHANGED faults)
      [] stage = 7 -> (B!CreateTasksCommit(1) /\ UNCHANGED faults)
      [] stage = 8 -> (B!CreateTasksReturn(1, "ok") /\ UNCHANGED faults)
      [] stage = 9 -> (B!GetTaskBatchMax(1) /\ UNCHANGED faults)
      [] stage = 10 -> (B!GetTasksIssue(1) /\ UNCHANGED faults)
      [] OTHER -> FALSE
ScenarioNext ==
    \/ /\ stage < SeedLength /\ Track(SeedAction) /\ stage' = stage + 1
    \/ /\ stage = SeedLength /\ ContractNext /\ UNCHANGED stage
ScenarioSpec == ScenarioInit /\ [][ScenarioNext]_scenarioVars
ScenarioLiveSpec == ScenarioSpec /\ WF_scenarioVars(stage < SeedLength /\ Track(SeedAction) /\ stage' = stage + 1) /\ RecoveryScheduling
ScenarioView == <<ContractView, stage>>
SeedReached == stage = SeedLength
=============================================================================
