---- MODULE base ----
EXTENDS Naturals, Sequences, FiniteSets, TLC

\*---------------------------------------------------------------------
\* Constants
\*---------------------------------------------------------------------
CONSTANTS
    Range,      \* Set of chunk range identifiers
    Migration,  \* Set of migration identifiers
    Task,       \* Set of task identifiers (natural numbers for overlap ordering)
    Query,      \* Set of query identifiers
    Nil,        \* Null value
    Overlap     \* Symmetric set of overlapping range pairs <<r1, r2>>

\* Two ranges overlap if they are the same or explicitly in the Overlap set
RangeOverlaps(r1, r2) == r1 = r2 \/ <<r1, r2>> \in Overlap

\*---------------------------------------------------------------------
\* Variables
\*---------------------------------------------------------------------

\* --- Service lifecycle (Bug Family 1: Step-Up/Step-Down Races) ---
\* range_deleter_service.h:90-92 — state machine
VARIABLE serviceState       \* "kDown" | "kReadyForInit" | "kInitializing" | "kUp"
\* range_deleter_service.cpp:186-262 — async recovery task
VARIABLE recoveryRunning    \* BOOLEAN
\* ready_range_deletions_processor.h:64 — processor state
VARIABLE processorState     \* "kInit" | "kRunning" | "kStopped"

serviceVars == <<serviceState, recoveryRunning, processorState>>

\* --- Task lifecycle (Bug Families 1, 2, 3, 4) ---
\* range_deletion_task_tracker.cpp — in-memory registry
VARIABLE taskState          \* [Task -> TaskStates]
\* Persistent doc fields in config.rangeDeletions
VARIABLE taskRange          \* [Task -> Range \cup {Nil}]
\* Family 4: identity for cross-shard operations
\* range_deletion_util.cpp:677-708 — asymmetric migrationId filtering
VARIABLE taskMigration      \* [Task -> Migration \cup {Nil}]
\* Family 1+2: overlap ordering
\* range_deleter_service.cpp:404-406 — timestamp tiebreaker
VARIABLE taskRegTime        \* [Task -> Nat]
\* Persistent doc existence
VARIABLE taskDocExists      \* [Task -> BOOLEAN]
\* "pending" flag on persistent doc
VARIABLE taskDocPending     \* [Task -> BOOLEAN]
\* "processing" flag on persistent doc
\* range_deletion_util.cpp:273-294 — markRangeDeletionTaskAsProcessing
VARIABLE taskDocProcessing  \* [Task -> BOOLEAN]
\* Family 3: whether ongoing queries were captured with valid metadata
\* migration_coordinator.cpp:297-302 — getOngoingQueriesCompletionFuture
VARIABLE queriesCapturedOK  \* [Task -> BOOLEAN]
\* Family 2 (MC-4): whether task was recovered with processing flag
VARIABLE taskRecoveredProcessing \* [Task -> BOOLEAN]

taskVars == <<taskState, taskRange, taskMigration, taskRegTime,
              taskDocExists, taskDocPending, taskDocProcessing,
              queriesCapturedOK, taskRecoveredProcessing>>

\* --- Migration lifecycle (Bug Family 2: Ordering Races) ---
\* migration_coordinator.cpp
VARIABLE migrationState     \* [Migration -> MigrationStates]
VARIABLE migrationRange     \* [Migration -> Range \cup {Nil}]

migrationVars == <<migrationState, migrationRange>>

\* --- Query & Metadata (Bug Family 3: Query Safety) ---
\* collection_sharding_runtime — metadata lifecycle
VARIABLE activeQueries      \* SUBSET Query
VARIABLE queryRange         \* [Query -> Range \cup {Nil}]
VARIABLE metadataKnown      \* BOOLEAN — filtering metadata exists

queryMetaVars == <<activeQueries, queryRange, metadataKnown>>

\* --- Clock (Bug Families 1, 2) ---
\* Can return same value for consecutive reads → equal timestamps
VARIABLE clock              \* Nat

vars == <<serviceVars, taskVars, migrationVars, queryMetaVars, clock>>

\*---------------------------------------------------------------------
\* State constants
\*---------------------------------------------------------------------
ServiceStates == {"kDown", "kReadyForInit", "kInitializing", "kUp"}
ProcessorStates == {"kInit", "kRunning", "kStopped"}
TaskStates == {"unused", "pending", "registered", "waitOverlap",
               "waitQueries", "ready", "executing", "completed"}
MigrationStates == {"idle", "cloning", "committed", "aborted"}

\*---------------------------------------------------------------------
\* Helpers
\*---------------------------------------------------------------------

TasksInState(s) == {t \in Task : taskState[t] = s}

\* Overlapping active tasks for task t
\* range_deleter_service.cpp:392-393 — getOverlappingTasks
OverlappingActiveTasks(t) ==
    {t2 \in Task : t2 /= t
                    /\ taskState[t2] \notin {"unused", "completed"}
                    /\ taskRange[t2] /= Nil
                    /\ taskRange[t] /= Nil
                    /\ RangeOverlaps(taskRange[t], taskRange[t2])}

\* Overlap ordering: t should wait for t2
\* range_deleter_service.cpp:404-406
\* t waits for t2 when: t2 registered earlier, OR same time AND t's ID < t2's ID
ShouldWaitFor(t, t2) ==
    \/ taskRegTime[t2] < taskRegTime[t]
    \/ (taskRegTime[t2] = taskRegTime[t] /\ t < t2)

\* Tasks blocking t from proceeding past overlap wait
BlockingTasks(t) ==
    {t2 \in OverlappingActiveTasks(t) : ShouldWaitFor(t, t2)}

\* Active queries on a range
QueriesOnRange(r) ==
    {q \in activeQueries : queryRange[q] /= Nil /\ RangeOverlaps(queryRange[q], r)}

\* Is any deletion executing on a range?
DeletionExecutingOnRange(r) ==
    \E t \in Task : taskState[t] = "executing"
                    /\ taskRange[t] /= Nil
                    /\ RangeOverlaps(taskRange[t], r)

\*---------------------------------------------------------------------
\* Init
\*---------------------------------------------------------------------
Init ==
    /\ serviceState = "kDown"
    /\ recoveryRunning = FALSE
    /\ processorState = "kStopped"
    /\ taskState = [t \in Task |-> "unused"]
    /\ taskRange = [t \in Task |-> Nil]
    /\ taskMigration = [t \in Task |-> Nil]
    /\ taskRegTime = [t \in Task |-> 0]
    /\ taskDocExists = [t \in Task |-> FALSE]
    /\ taskDocPending = [t \in Task |-> FALSE]
    /\ taskDocProcessing = [t \in Task |-> FALSE]
    /\ queriesCapturedOK = [t \in Task |-> FALSE]
    /\ taskRecoveredProcessing = [t \in Task |-> FALSE]
    /\ migrationState = [m \in Migration |-> "idle"]
    /\ migrationRange = [m \in Migration |-> Nil]
    /\ activeQueries = {}
    /\ queryRange = [q \in Query |-> Nil]
    /\ metadataKnown = TRUE
    /\ clock = 1

\*=====================================================================
\* SERVICE LIFECYCLE ACTIONS (Bug Family 1)
\*=====================================================================

\* range_deleter_service.cpp:135-154 — onStepUpComplete()
\* Transitions from kDown, creates executor + processor, launches recovery
StepUp ==
    /\ serviceState = "kDown"
    \* range_deleter_service.cpp:143
    /\ serviceState' = "kReadyForInit"
    /\ recoveryRunning' = TRUE
    \* range_deleter_service.cpp:153-154 — create processor
    /\ processorState' = "kInit"
    /\ UNCHANGED <<taskVars, migrationVars, queryMetaVars, clock>>

\* range_deleter_service.cpp:186-261 — _launchRangeDeletionRecoveryTask body
\* Transitions kReadyForInit → kInitializing, re-registers persisted tasks
\* Two-phase: processing tasks first (line 220-231), then others (line 240-254)
RecoveryBegin ==
    /\ recoveryRunning = TRUE
    \* range_deleter_service.cpp:194 — check state
    /\ serviceState = "kReadyForInit"
    \* range_deleter_service.cpp:197
    /\ serviceState' = "kInitializing"
    \* Re-register persisted non-pending tasks with makeReady() future
    \* range_deleter_service.cpp:226-229, 249-252
    /\ taskState' = [t \in Task |->
        IF taskDocExists[t] /\ ~taskDocPending[t]
        THEN "registered"
        ELSE taskState[t]]
    \* Recovery uses SemiFuture::makeReady() — skips query wait
    /\ queriesCapturedOK' = [t \in Task |->
        IF taskDocExists[t] /\ ~taskDocPending[t]
        THEN TRUE
        ELSE queriesCapturedOK[t]]
    \* Track which tasks were recovered with processing flag (MC-4)
    /\ taskRecoveredProcessing' = [t \in Task |->
        IF taskDocExists[t] /\ ~taskDocPending[t] /\ taskDocProcessing[t]
        THEN TRUE
        ELSE FALSE]
    /\ UNCHANGED <<recoveryRunning, processorState,
                   taskRange, taskMigration, taskRegTime, taskDocExists,
                   taskDocPending, taskDocProcessing,
                   migrationVars, queryMetaVars, clock>>

\* range_deleter_service.cpp:156-175 — recovery future completion callback
\* Transitions kInitializing → kUp, starts processor
RecoveryComplete ==
    /\ recoveryRunning = TRUE
    \* range_deleter_service.cpp:166 — if (_state != kDown)
    /\ serviceState = "kInitializing"
    \* range_deleter_service.cpp:167
    /\ serviceState' = "kUp"
    /\ recoveryRunning' = FALSE
    \* range_deleter_service.cpp:169 — beginProcessing()
    /\ processorState' = "kRunning"
    /\ UNCHANGED <<taskVars, migrationVars, queryMetaVars, clock>>

\* range_deleter_service.cpp:315-322 — onStepDown() / onShutdown()
\* Clears all in-memory state, stops processor
StepDown ==
    /\ serviceState /= "kDown"
    /\ serviceState' = "kDown"
    /\ recoveryRunning' = FALSE
    /\ processorState' = "kStopped"
    \* Clear in-memory task state — range_deleter_service.cpp:315 _stopService
    /\ taskState' = [t \in Task |-> "unused"]
    /\ queriesCapturedOK' = [t \in Task |-> FALSE]
    /\ taskRecoveredProcessing' = [t \in Task |-> FALSE]
    \* Persistent state preserved across step-down
    /\ UNCHANGED <<taskRange, taskMigration, taskRegTime, taskDocExists,
                   taskDocPending, taskDocProcessing,
                   migrationVars, queryMetaVars, clock>>

\*=====================================================================
\* MIGRATION LIFECYCLE ACTIONS (Bug Family 2)
\*=====================================================================

\* Migration begins on a range. Creates persistent task doc with pending=true.
\* migration_source_manager.cpp:337-369 — drain check before donating
StartMigration(m, r, t) ==
    /\ migrationState[m] = "idle"
    /\ r /= Nil
    /\ taskState[t] = "unused"
    /\ ~taskDocExists[t]
    \* Drain check: no executing deletion on this range
    \* migration_source_manager.cpp:337-369
    /\ ~DeletionExecutingOnRange(r)
    \* At most one cloning migration per range
    /\ ~\E m2 \in Migration : migrationState[m2] = "cloning" /\ migrationRange[m2] = r
    \* No existing task doc for this range (previous task must be cleaned up)
    /\ ~\E t2 \in Task : taskDocExists[t2] /\ taskRange[t2] = r
    \* Create persistent task doc with pending=true
    /\ taskDocExists' = [taskDocExists EXCEPT ![t] = TRUE]
    /\ taskDocPending' = [taskDocPending EXCEPT ![t] = TRUE]
    /\ taskDocProcessing' = [taskDocProcessing EXCEPT ![t] = FALSE]
    /\ taskRange' = [taskRange EXCEPT ![t] = r]
    /\ taskMigration' = [taskMigration EXCEPT ![t] = m]
    /\ taskRegTime' = [taskRegTime EXCEPT ![t] = clock]
    /\ migrationState' = [migrationState EXCEPT ![m] = "cloning"]
    /\ migrationRange' = [migrationRange EXCEPT ![m] = r]
    /\ UNCHANGED <<serviceVars, taskState, queriesCapturedOK, taskRecoveredProcessing,
                   activeQueries, queryRange, metadataKnown, clock>>

\* migration_coordinator.cpp:231-324 — _commitMigrationOnDonorAndRecipient()
\* Registers task in memory as pending, captures ongoing queries future
CommitMigration(m) ==
    /\ migrationState[m] = "cloning"
    /\ serviceState = "kUp"
    /\ \E t \in Task :
        /\ taskMigration[t] = m
        /\ taskDocExists[t]
        /\ taskDocPending[t]
        \* Register in memory as pending — line 308-311
        /\ taskState' = [taskState EXCEPT ![t] = "pending"]
        \* Capture ongoing queries future — line 297-302
        \* Timing: BEFORE oplog commit, uses current metadata state
        /\ queriesCapturedOK' = [queriesCapturedOK EXCEPT ![t] = metadataKnown]
    /\ migrationState' = [migrationState EXCEPT ![m] = "committed"]
    /\ UNCHANGED <<serviceVars, taskRange, taskMigration, taskRegTime, taskDocExists,
                   taskDocPending, taskDocProcessing, taskRecoveredProcessing,
                   migrationRange, activeQueries, queryRange, metadataKnown, clock>>

\* migration_coordinator.cpp:326-387 — _abortMigrationOnDonorAndRecipient()
\* Deletes donor's task doc, cleans up in-memory state
AbortMigration(m) ==
    /\ migrationState[m] = "cloning"
    /\ \E t \in Task :
        /\ taskMigration[t] = m
        /\ taskDocExists[t]
        \* Delete persistent doc — line 347-350
        /\ taskDocExists' = [taskDocExists EXCEPT ![t] = FALSE]
        /\ taskDocPending' = [taskDocPending EXCEPT ![t] = FALSE]
        /\ taskDocProcessing' = [taskDocProcessing EXCEPT ![t] = FALSE]
        \* Clear in-memory state (task was never registered if migration didn't commit)
        /\ taskState' = [taskState EXCEPT ![t] = "unused"]
        /\ taskRange' = [taskRange EXCEPT ![t] = Nil]
        /\ taskMigration' = [taskMigration EXCEPT ![t] = Nil]
        /\ taskRegTime' = [taskRegTime EXCEPT ![t] = 0]
        /\ queriesCapturedOK' = [queriesCapturedOK EXCEPT ![t] = FALSE]
        /\ taskRecoveredProcessing' = [taskRecoveredProcessing EXCEPT ![t] = FALSE]
    /\ migrationState' = [migrationState EXCEPT ![m] = "aborted"]
    /\ UNCHANGED <<serviceVars, migrationRange, activeQueries, queryRange,
                   metadataKnown, clock>>

\*=====================================================================
\* TASK REGISTRATION CHAIN ACTIONS (Bug Families 1, 2, 3)
\*=====================================================================

\* range_deleter_service.cpp:476-478 — clearPending() via OpObserver
\* migration_coordinator.cpp:320-321 — markAsReadyRangeDeletionTaskLocally
\* range_deleter_service_op_observer.cpp:149-172 — onUpdate, pending removed
\* Clears pending flag on doc, unblocks async chain
ClearPending(t) ==
    /\ taskState[t] = "pending"
    /\ serviceState = "kUp"
    \* Update persistent doc: remove pending flag
    /\ taskDocPending' = [taskDocPending EXCEPT ![t] = FALSE]
    \* OpObserver calls registerTask(kNotPending) → clearPending()
    /\ taskState' = [taskState EXCEPT ![t] = "registered"]
    /\ UNCHANGED <<serviceVars, taskRange, taskMigration, taskRegTime, taskDocExists,
                   taskDocProcessing, queriesCapturedOK, taskRecoveredProcessing,
                   migrationVars, queryMetaVars, clock>>

\* range_deleter_service.cpp:385-426 — overlap check in async chain
\* Determines if task must wait for overlapping older tasks
CheckOverlap(t) ==
    /\ taskState[t] = "registered"
    /\ serviceState = "kUp"
    /\ IF BlockingTasks(t) = {}
       THEN taskState' = [taskState EXCEPT ![t] = "waitQueries"]
       ELSE taskState' = [taskState EXCEPT ![t] = "waitOverlap"]
    /\ UNCHANGED <<serviceVars, taskRange, taskMigration, taskRegTime, taskDocExists,
                   taskDocPending, taskDocProcessing, queriesCapturedOK, taskRecoveredProcessing,
                   migrationVars, queryMetaVars, clock>>

\* All blocking overlapping tasks have completed
OverlapResolved(t) ==
    /\ taskState[t] = "waitOverlap"
    /\ serviceState = "kUp"
    /\ BlockingTasks(t) = {}
    /\ taskState' = [taskState EXCEPT ![t] = "waitQueries"]
    /\ UNCHANGED <<serviceVars, taskRange, taskMigration, taskRegTime, taskDocExists,
                   taskDocPending, taskDocProcessing, queriesCapturedOK, taskRecoveredProcessing,
                   migrationVars, queryMetaVars, clock>>

\* range_deleter_service.cpp:428-432 — wait for active queries to drain
\* Family 3: if queriesCapturedOK=FALSE, proceeds without proper waiting
QueriesDrained(t) ==
    /\ taskState[t] = "waitQueries"
    /\ serviceState = "kUp"
    \* Proceed when queries have drained OR capture was invalid (the bug)
    /\ \/ (queriesCapturedOK[t] /\ QueriesOnRange(taskRange[t]) = {})
       \/ ~queriesCapturedOK[t]
    /\ taskState' = [taskState EXCEPT ![t] = "ready"]
    /\ UNCHANGED <<serviceVars, taskRange, taskMigration, taskRegTime, taskDocExists,
                   taskDocPending, taskDocProcessing, queriesCapturedOK, taskRecoveredProcessing,
                   migrationVars, queryMetaVars, clock>>

\*=====================================================================
\* DELETION EXECUTION ACTIONS
\*=====================================================================

\* ready_range_deletions_processor.cpp:210-404 — _runRangeDeletions()
\* Processor dequeues a ready task and begins execution (single-threaded)
ProcessorPickTask(t) ==
    /\ processorState = "kRunning"
    /\ taskState[t] = "ready"
    /\ taskDocExists[t]
    \* Single-threaded: at most one task executing at a time
    \* ready_range_deletions_processor.cpp:210 — main loop
    /\ Cardinality(TasksInState("executing")) = 0
    \* Mark as processing in persistent doc
    \* range_deletion_util.cpp:273-294 — markRangeDeletionTaskAsProcessing
    /\ taskDocProcessing' = [taskDocProcessing EXCEPT ![t] = TRUE]
    /\ taskState' = [taskState EXCEPT ![t] = "executing"]
    /\ UNCHANGED <<serviceVars, taskRange, taskMigration, taskRegTime, taskDocExists,
                   taskDocPending, queriesCapturedOK, taskRecoveredProcessing,
                   migrationVars, queryMetaVars, clock>>

\* ready_range_deletions_processor.cpp:246-365 — deletion + task removal
\* Abstracts batch deletion into single atomic completion
CompleteTask(t) ==
    /\ taskState[t] = "executing"
    /\ serviceState = "kUp"
    \* range_deleter_service.cpp:491-499 — completeTask() removes from tracker
    /\ taskState' = [taskState EXCEPT ![t] = "completed"]
    \* ready_range_deletions_processor.cpp:344-348 — remove persistent doc
    /\ taskDocExists' = [taskDocExists EXCEPT ![t] = FALSE]
    /\ taskDocPending' = [taskDocPending EXCEPT ![t] = FALSE]
    /\ taskDocProcessing' = [taskDocProcessing EXCEPT ![t] = FALSE]
    \* Clean up task slot
    /\ taskRange' = [taskRange EXCEPT ![t] = Nil]
    /\ taskMigration' = [taskMigration EXCEPT ![t] = Nil]
    /\ taskRegTime' = [taskRegTime EXCEPT ![t] = 0]
    /\ queriesCapturedOK' = [queriesCapturedOK EXCEPT ![t] = FALSE]
    /\ taskRecoveredProcessing' = [taskRecoveredProcessing EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<serviceVars, migrationVars, queryMetaVars, clock>>

\*=====================================================================
\* QUERY LIFECYCLE ACTIONS (Bug Family 3)
\*=====================================================================

\* Client starts a query on a range (requires metadata to be known)
StartQuery(q, r) ==
    /\ q \notin activeQueries
    /\ r /= Nil
    /\ metadataKnown
    /\ activeQueries' = activeQueries \cup {q}
    /\ queryRange' = [queryRange EXCEPT ![q] = r]
    /\ UNCHANGED <<serviceVars, taskVars, migrationVars, metadataKnown, clock>>

\* Query completes
EndQuery(q) ==
    /\ q \in activeQueries
    /\ activeQueries' = activeQueries \ {q}
    /\ queryRange' = [queryRange EXCEPT ![q] = Nil]
    /\ UNCHANGED <<serviceVars, taskVars, migrationVars, metadataKnown, clock>>

\*=====================================================================
\* METADATA LIFECYCLE ACTIONS (Bug Family 3)
\*=====================================================================

\* collection_sharding_runtime.cpp — clearFilteringMetadata()
\* SERVER-67385: destroys MetadataManager, loses ongoing query tracking
ClearMetadata ==
    /\ metadataKnown = TRUE
    /\ metadataKnown' = FALSE
    \* Active queries still running but metadata tracking lost
    /\ UNCHANGED <<serviceVars, taskVars, migrationVars, activeQueries, queryRange, clock>>

\* collection_sharding_runtime.cpp — setFilteringMetadata()
\* Re-establishes metadata (new MetadataManager, no knowledge of prior queries)
RefreshMetadata ==
    /\ metadataKnown = FALSE
    /\ metadataKnown' = TRUE
    /\ UNCHANGED <<serviceVars, taskVars, migrationVars, activeQueries, queryRange, clock>>

\*=====================================================================
\* CLOCK ACTION (Bug Families 1, 2)
\*=====================================================================

\* Clock advances. Not calling TickClock between two registrations
\* gives them the same timestamp (models SERVER-119435 mechanism).
TickClock ==
    /\ clock' = clock + 1
    /\ UNCHANGED <<serviceVars, taskVars, migrationVars, queryMetaVars>>

\*=====================================================================
\* FAULT INJECTION: CROSS-SHARD IDENTITY (Bug Family 4)
\*=====================================================================

\* Retry of aborted migration's deleteRangeDeletionTaskLocally
\* range_deletion_util.cpp:702-708 — uses only (collUUID, range), no migrationId
\* range_deletion_util.cpp:677-693 — recipient path DOES include migrationId
\* A retry can delete the WRONG migration's task if range matches
RetryDeleteTaskLocally(m) ==
    /\ migrationState[m] = "aborted"
    /\ migrationRange[m] /= Nil
    /\ \E t \in Task :
        /\ taskDocExists[t]
        /\ taskRange[t] = migrationRange[m]
        \* KEY BUG MECHANISM: finds task by range only, may be different migration
        /\ taskMigration[t] /= m
        \* Delete persistent doc only — in-memory state NOT updated
        \* (deleteRangeDeletionTaskLocally is a direct persistent store write,
        \* does not interact with RangeDeleterService in-memory tracker)
        /\ taskDocExists' = [taskDocExists EXCEPT ![t] = FALSE]
        /\ taskDocPending' = [taskDocPending EXCEPT ![t] = FALSE]
        /\ taskDocProcessing' = [taskDocProcessing EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<serviceVars, taskState, taskRange, taskMigration, taskRegTime,
                   queriesCapturedOK, taskRecoveredProcessing,
                   migrationVars, queryMetaVars, clock>>

\*=====================================================================
\* SPECIFICATION
\*=====================================================================

Next ==
    \* Service lifecycle (Family 1)
    \/ StepUp
    \/ RecoveryBegin
    \/ RecoveryComplete
    \/ StepDown
    \* Migration lifecycle (Family 2)
    \/ \E m \in Migration, r \in Range, t \in Task : StartMigration(m, r, t)
    \/ \E m \in Migration : CommitMigration(m)
    \/ \E m \in Migration : AbortMigration(m)
    \* Task registration chain (Families 1, 2, 3)
    \/ \E t \in Task : ClearPending(t)
    \/ \E t \in Task : CheckOverlap(t)
    \/ \E t \in Task : OverlapResolved(t)
    \/ \E t \in Task : QueriesDrained(t)
    \* Deletion execution
    \/ \E t \in Task : ProcessorPickTask(t)
    \/ \E t \in Task : CompleteTask(t)
    \* Query lifecycle (Family 3)
    \/ \E q \in Query, r \in Range : StartQuery(q, r)
    \/ \E q \in Query : EndQuery(q)
    \* Metadata lifecycle (Family 3)
    \/ ClearMetadata
    \/ RefreshMetadata
    \* Clock (Families 1, 2)
    \/ TickClock
    \* Fault injection (Family 4)
    \/ \E m \in Migration : RetryDeleteTaskLocally(m)

Spec == Init /\ [][Next]_vars

\*=====================================================================
\* INVARIANTS
\*=====================================================================

\* --- Standard Safety Invariants ---

\* Range deletion not scheduled while migration is cloning the SAME range
\* Family 2: SERVER-91970
\* Note: uses exact range match, not overlap — migration drain is per-chunk
NoOrphanedRangeDeletion ==
    \A t \in Task, m \in Migration :
        (taskState[t] \in {"ready", "executing"} /\ taskRange[t] /= Nil
         /\ migrationState[m] = "cloning" /\ migrationRange[m] /= Nil)
        => taskRange[t] /= migrationRange[m]

\* Active queries not affected by executing range deletion
\* Family 3: SERVER-67385
QueryNotAffected ==
    \A t \in Task :
        (taskState[t] = "executing" /\ taskRange[t] /= Nil)
        => QueriesOnRange(taskRange[t]) = {}

\* No new migration while deletion executing on the SAME range
\* Family 2: SERVER-91970
\* Note: uses exact range match — drain check is per-chunk
DrainBeforeDonate ==
    \A m \in Migration :
        (migrationState[m] = "cloning" /\ migrationRange[m] /= Nil)
        => ~\E t \in Task : taskState[t] = "executing"
                            /\ taskRange[t] = migrationRange[m]

\* At most one deletion executing on overlapping ranges
\* Family 2: overlap serialization
OverlapSerializationTotal ==
    \A t1, t2 \in Task :
        (t1 /= t2 /\ taskState[t1] = "executing" /\ taskState[t2] = "executing"
         /\ taskRange[t1] /= Nil /\ taskRange[t2] /= Nil)
        => ~RangeOverlaps(taskRange[t1], taskRange[t2])

\* --- Extension Invariants (Bug-Family Specific) ---

\* No circular wait in overlap ordering
\* Family 1: SERVER-119435 — equal timestamps deadlock
NoTaskDeadlock ==
    ~\E t1, t2 \in Task :
        /\ t1 /= t2
        /\ taskState[t1] = "waitOverlap"
        /\ taskState[t2] = "waitOverlap"
        /\ taskRange[t1] /= Nil /\ taskRange[t2] /= Nil
        /\ RangeOverlaps(taskRange[t1], taskRange[t2])
        /\ ShouldWaitFor(t1, t2)
        /\ ShouldWaitFor(t2, t1)

\* Service state consistency
\* Family 1: SERVER-115921, SERVER-69552
ServiceStateConsistency ==
    (serviceState = "kUp") => (processorState \in {"kRunning", "kInit"})

\* Active in-memory tasks have persistent docs
\* Family 4: SERVER-69586 — retry deletes wrong task's doc
TaskDocConsistency ==
    \A t \in Task :
        taskState[t] \in {"pending", "registered", "waitOverlap",
                          "waitQueries", "ready", "executing"}
        => taskDocExists[t]

\* Recovered-processing tasks execute before non-recovered overlapping tasks
\* Family 2: SERVER-64979 (MC-4)
ResumeInProgressFirst ==
    ~\E t1, t2 \in Task :
        /\ t1 /= t2
        /\ taskRecoveredProcessing[t1]
        /\ ~taskRecoveredProcessing[t2]
        /\ taskState[t1] \in {"registered", "waitOverlap", "waitQueries", "ready"}
        /\ taskState[t2] = "executing"
        /\ taskRange[t1] /= Nil /\ taskRange[t2] /= Nil
        /\ RangeOverlaps(taskRange[t1], taskRange[t2])

\* --- Structural Invariants ---

TypeOK ==
    /\ serviceState \in ServiceStates
    /\ recoveryRunning \in BOOLEAN
    /\ processorState \in ProcessorStates
    /\ taskState \in [Task -> TaskStates]
    /\ taskRange \in [Task -> Range \cup {Nil}]
    /\ taskMigration \in [Task -> Migration \cup {Nil}]
    /\ taskRegTime \in [Task -> Nat]
    /\ taskDocExists \in [Task -> BOOLEAN]
    /\ taskDocPending \in [Task -> BOOLEAN]
    /\ taskDocProcessing \in [Task -> BOOLEAN]
    /\ queriesCapturedOK \in [Task -> BOOLEAN]
    /\ taskRecoveredProcessing \in [Task -> BOOLEAN]
    /\ migrationState \in [Migration -> MigrationStates]
    /\ migrationRange \in [Migration -> Range \cup {Nil}]
    /\ activeQueries \in SUBSET Query
    /\ queryRange \in [Query -> Range \cup {Nil}]
    /\ metadataKnown \in BOOLEAN
    /\ clock \in Nat

\* Processor only runs when service is up
ProcessorServiceConsistency ==
    processorState = "kRunning" => serviceState = "kUp"

\* At most one task executing (single-threaded processor)
SingleExecuting == Cardinality(TasksInState("executing")) <= 1

\* Executing tasks have processing flag set on persistent doc
ExecutingTaskHasProcessingFlag ==
    \A t \in Task :
        taskState[t] = "executing" => taskDocProcessing[t]

====
