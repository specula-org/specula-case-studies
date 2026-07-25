------------------------------- MODULE Trace --------------------------------
\* Trace validation spec for MongoDB Range Deletion Protocol
\*
\* Category A (Distributed/Message-Passing): single-file linear trace.
\* Each trace event corresponds to one spec action.
\* Cursor `l` walks through TraceLog; TraceMatched verifies the full trace is consumed.

EXTENDS base, Naturals, Sequences, TLC, Json, IOUtils

-----------------------------------------------------------------------------
\* TRACE FILE LOCATION

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

Len_TraceLog == Len(TraceLog)

-----------------------------------------------------------------------------
\* CURSOR VARIABLE

VARIABLES l   \* current position in TraceLog (1-indexed)

tracevars == <<vars, l>>

-----------------------------------------------------------------------------
\* HELPERS

\* Current trace event
logline == TraceLog[l]

\* Check if current event has the given name
IsEvent(name) == logline.event = name

\* Check if current event is for a specific migration ID
IsMigrationEvent(name, m) == IsEvent(name) /\ logline.migrationId = m

-----------------------------------------------------------------------------
\* STATE FIELD MAPPING
\*
\* Trace events capture these fields (see instrumentation-spec.md):
\*   migrationId     — migration identifier
\*   coordDocState   — state of coordinator document: "absent"|"present"|"committed"|"aborted"
\*   donorTaskState  — state of donor range deletion task: "absent"|"pending"|"ready"|"processing"
\*   recipientTaskState — state of recipient range deletion task
\*   recipientAlive  — boolean: whether recipient shard is reachable
\*
\* Field names match base spec variable names exactly.

-----------------------------------------------------------------------------
\* POST-STATE VALIDATION

\* Validate that spec state matches trace-captured state after each action.
\* Called inside every action wrapper.

ValidateCoordDoc(m) ==
    coordDoc'[m] = logline.coordDocState

ValidateDonorTask(m) ==
    donorTask'[m] = logline.donorTaskState

ValidateRecipientTask(m) ==
    recipientTask'[m] = logline.recipientTaskState

ValidateRecipientAlive ==
    recipientShardAlive' = logline.recipientAlive

\* Full post-state check for events that capture all fields
ValidateFullState(m) ==
    /\ ValidateCoordDoc(m)
    /\ ValidateDonorTask(m)
    /\ ValidateRecipientTask(m)
    /\ ValidateRecipientAlive

\* Partial post-state check for events that only capture task state
ValidateTaskState(m) ==
    /\ ValidateDonorTask(m)
    /\ ValidateRecipientTask(m)

-----------------------------------------------------------------------------
\* TRACE INIT
\*
\* The implementation starts with all documents absent, term=1.
\* This matches base spec Init exactly.

TraceInit ==
    /\ Init
    /\ l = 1

-----------------------------------------------------------------------------
\* ACTION WRAPPERS

\* WriteCoordDoc — insertMigrationCoordinatorDoc
\* migration_coordinator.cpp:150
TraceWriteCoordDoc ==
    /\ l <= Len_TraceLog
    /\ IsEvent("WriteCoordDoc")
    /\ LET m == logline.migrationId IN
        /\ WriteCoordDoc(m)
        /\ ValidateCoordDoc(m)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

\* WriteRangeDeletionTask — createAndPersistRangeDeletionTask
\* migration_coordinator.cpp:158-169, range_deletion_util.cpp:147-170
TraceWriteRangeDeletionTask ==
    /\ l <= Len_TraceLog
    /\ IsEvent("WriteRangeDeletionTask")
    /\ LET m == logline.migrationId IN
        /\ WriteRangeDeletionTask(m)
        /\ ValidateTaskState(m)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

\* PersistCommitDecision — persistCommitDecision
\* migration_coordinator.cpp:240
TracePersistCommitDecision ==
    /\ l <= Len_TraceLog
    /\ IsEvent("PersistCommitDecision")
    /\ LET m == logline.migrationId IN
        /\ PersistCommitDecision(m)
        /\ ValidateCoordDoc(m)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

\* DeleteRecipientTaskOnCommit — deleteRangeDeletionTaskOnRecipient
\* migration_coordinator.cpp:278-282
TraceDeleteRecipientTaskOnCommit ==
    /\ l <= Len_TraceLog
    /\ IsEvent("DeleteRecipientTaskOnCommit")
    /\ LET m == logline.migrationId IN
        /\ DeleteRecipientTaskOnCommit(m)
        /\ ValidateRecipientTask(m)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

\* ActivateDonorTaskOnCommit — registerTask + markAsReadyRangeDeletionTaskLocally
\* migration_coordinator.cpp:309-321
TraceActivateDonorTaskOnCommit ==
    /\ l <= Len_TraceLog
    /\ IsEvent("ActivateDonorTaskOnCommit")
    /\ LET m == logline.migrationId IN
        /\ ActivateDonorTaskOnCommit(m)
        /\ ValidateDonorTask(m)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

\* PersistAbortDecision — persistAbortDecision
\* migration_coordinator.cpp:334
TracePersistAbortDecision ==
    /\ l <= Len_TraceLog
    /\ IsEvent("PersistAbortDecision")
    /\ LET m == logline.migrationId IN
        /\ PersistAbortDecision(m)
        /\ ValidateCoordDoc(m)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

\* DeleteDonorTaskOnAbort — deleteRangeDeletionTaskLocally
\* migration_coordinator.cpp:347-350
TraceDeleteDonorTaskOnAbort ==
    /\ l <= Len_TraceLog
    /\ IsEvent("DeleteDonorTaskOnAbort")
    /\ LET m == logline.migrationId IN
        /\ DeleteDonorTaskOnAbort(m)
        /\ ValidateDonorTask(m)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

\* MarkRecipientTaskReady — markAsReadyRangeDeletionTaskOnRecipient (success path)
\* migration_coordinator.cpp:382-386
TraceMarkRecipientTaskReady ==
    /\ l <= Len_TraceLog
    /\ IsEvent("MarkRecipientTaskReady")
    /\ LET m == logline.migrationId IN
        /\ MarkRecipientTaskReady(m)
        /\ ValidateRecipientTask(m)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

\* ForgetMigration — store.remove with w:1
\* migration_coordinator.cpp:396-401
TraceForgetMigration ==
    /\ l <= Len_TraceLog
    /\ IsEvent("ForgetMigration")
    /\ LET m == logline.migrationId IN
        /\ ForgetMigration(m)
        /\ ValidateCoordDoc(m)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

\* ExecuteRangeDeletion — range deletion begins processing
\* ready_range_deletions_processor.cpp:290-400
TraceExecuteRangeDeletion ==
    /\ l <= Len_TraceLog
    /\ IsEvent("ExecuteRangeDeletion")
    /\ LET m == logline.migrationId IN
        /\ ExecuteRangeDeletion(m)
        /\ ValidateDonorTask(m)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

\* CompleteRangeDeletion — range deletion completes
TraceCompleteRangeDeletion ==
    /\ l <= Len_TraceLog
    /\ IsEvent("CompleteRangeDeletion")
    /\ LET m == logline.migrationId IN
        /\ CompleteRangeDeletion(m)
        /\ ValidateDonorTask(m)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

\* Recovery — step-up recovery re-registers tasks
\* range_deleter_service.cpp:200-261
TraceRecovery ==
    /\ l <= Len_TraceLog
    /\ IsEvent("Recovery")
    /\ Recovery
    /\ l' = l + 1
    /\ UNCHANGED faultVars

-----------------------------------------------------------------------------
\* SILENT ACTIONS
\*
\* These fire base spec actions without consuming a trace event.
\* Tightly constrained to prevent state space explosion.
\*
\* Rule: a silent action may fire only if the NEXT trace event requires
\* the intermediate state that the silent action produces.

\* Silent: MarkRecipientTaskReadyFails — shard not found, no trace event emitted
\* Fires only when the next event requires coordDoc[m]=aborted AND recipientTask[m]=pending
TraceSilentMarkRecipientTaskReadyFails ==
    /\ l <= Len_TraceLog
    /\ \E m \in MigrationId :
        /\ coordDoc[m] = "aborted"
        /\ recipientTask[m] = "pending"
        /\ recipientShardAlive = FALSE
        \* Only fire if next event needs this migration and recipient task still pending
        /\ logline.migrationId = m
        /\ MarkRecipientTaskReadyFails(m)
    /\ UNCHANGED l

\* Silent: CommitSilentSkip — no donor task found, makeReady() returned silently
\* Fires only when coordDoc is committed and donorTask is absent
TraceSilentCommitSkip ==
    /\ l <= Len_TraceLog
    /\ \E m \in MigrationId :
        /\ coordDoc[m] = "committed"
        /\ donorTask[m] = "absent"
        /\ logline.migrationId = m
        /\ CommitSilentSkip(m)
    /\ UNCHANGED l

-----------------------------------------------------------------------------
\* TRACE NEXT

TraceNext ==
    \/ TraceWriteCoordDoc
    \/ TraceWriteRangeDeletionTask
    \/ TracePersistCommitDecision
    \/ TraceDeleteRecipientTaskOnCommit
    \/ TraceActivateDonorTaskOnCommit
    \/ TracePersistAbortDecision
    \/ TraceDeleteDonorTaskOnAbort
    \/ TraceMarkRecipientTaskReady
    \/ TraceForgetMigration
    \/ TraceExecuteRangeDeletion
    \/ TraceCompleteRangeDeletion
    \/ TraceRecovery
    \* Silent actions (no l advancement)
    \/ TraceSilentMarkRecipientTaskReadyFails
    \/ TraceSilentCommitSkip
    \* Stuttering when trace fully consumed
    \/ (l > Len_TraceLog /\ UNCHANGED tracevars)

TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(TraceNext)

-----------------------------------------------------------------------------
\* COMPLETENESS CHECK

\* Temporal property: the full trace must be consumed
TraceMatched == <>(l > Len_TraceLog)

-----------------------------------------------------------------------------
\* INVARIANTS (checked during trace validation)

\* Structural invariants should hold on every real execution
TraceTypeOK            == TypeOK
TraceProcessingInMem   == ProcessingImpliesInMemory
TraceRecoveryComplete  == RecoveryCompleteness

\* Safety invariants that hold on correct executions (no fault injection)
TraceNoSimultaneous    == NoSimultaneousDonorProcessing

=============================================================================
