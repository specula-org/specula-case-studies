---------------- MODULE Scenario_acceptance ----------------
EXTENDS RecoveryFairness
CONSTANTS w1, w2
VARIABLE stage
scenarioVars == <<mcvars, stage>>
ScenarioInit == MCInit /\ stage = 0
SeedLength == 6
SeedAction ==
    CASE stage = 0 -> MCAddTask(1, w1, 1)
      [] stage = 1 -> (B!TrySyncMatchFallback(1) /\ UNCHANGED faults)
      [] stage = 2 -> (B!SpoolTask(1) /\ UNCHANGED faults)
      [] stage = 3 -> (B!TaskWriterDequeue(1) /\ UNCHANGED faults)
      [] stage = 4 -> (B!AssignTaskIDs(1) /\ UNCHANGED faults)
      [] stage = 5 -> (B!CreateTasksBegin(1) /\ UNCHANGED faults)
      [] OTHER -> FALSE
ScenarioNext ==
    \/ /\ stage < SeedLength /\ Track(SeedAction) /\ stage' = stage + 1
    \/ /\ stage = SeedLength /\ ContractNext /\ UNCHANGED stage
ScenarioSpec == ScenarioInit /\ [][ScenarioNext]_scenarioVars
ScenarioLiveSpec == ScenarioSpec /\ WF_scenarioVars(stage < SeedLength /\ Track(SeedAction) /\ stage' = stage + 1) /\ RecoveryScheduling
ScenarioView == <<ContractView, stage>>
SeedReached == stage = SeedLength
=============================================================================
