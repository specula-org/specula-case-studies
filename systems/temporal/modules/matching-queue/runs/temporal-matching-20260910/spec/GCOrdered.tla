---------------------------- MODULE GCOrdered ----------------------------
EXTENDS Scenario_gc
ASSUME CrashLimit = 0 /\ LossLimit = 0
\* Receipt changes only a completed poller's availability and worker-observed bit.
\* No enabled queue-safety invariant depends on receipt timing; no crash/loss exists
\* in this scope. Move this independent cleanup before other owner/store steps.
ReceiptReady == \E p \in Pollers : dispatch[p].pc = "worker"
ReceiptStep == Track(\E p \in Pollers : B!PollTaskQueueResponse(p)) /\ UNCHANGED faults
OrderedNext ==
    \/ /\ stage < SeedLength /\ Track(SeedAction) /\ stage' = stage + 1
    \/ /\ stage = SeedLength
       /\ IF ReceiptReady THEN ReceiptStep ELSE ContractNext
       /\ UNCHANGED stage
OrderedSpec == ScenarioInit /\ [][OrderedNext]_scenarioVars
=============================================================================
