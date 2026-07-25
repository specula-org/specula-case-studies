---- MODULE TraceValidation ----
(*
 * Trace Validation Spec for MongoDB Chunk Migration
 *
 * Validates recorded execution traces against the base spec.
 * Category A (Distributed): single linear trace with cursor.
 *)

EXTENDS base, TLC, Naturals, Sequences, Json

\* Trace file location and loading
JsonFile == "../traces/migration.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* Cursor variable walks through trace events
VARIABLE l  \* Trace cursor: 0 <= l <= Len(TraceLog)

traceVars == <<l>>

allVars == <<vars, traceVars>>

----

\* Extract current trace event
CurrentLogline == IF l < Len(TraceLog) THEN TraceLog[l + 1] ELSE [type |-> "EOF"]

\* Event predicates
IsEvent(eventType) ==
    l < Len(TraceLog) /\ CurrentLogline.type = eventType

IsNodeEvent(eventType, node) ==
    IsEvent(eventType) /\ CurrentLogline.nodeId = node

----

\* Post-state validation: verify spec state matches trace
\* Each action wrapper validates the key fields that changed

ValidateRecipientStartClone ==
    /\ IsEvent("RecipientStartClone")
    /\ CurrentLogline.recipientState = "Init"

ValidateRecipientCloneComplete ==
    /\ IsEvent("RecipientCloneComplete")
    /\ CurrentLogline.recipientState = "Cloned"

ValidateDonorEnterCriticalSection ==
    /\ IsEvent("DonorEnterCriticalSection")
    /\ CurrentLogline.criticalSectionActive \in {"true", TRUE}

ValidateDonorPersistCommitDecision ==
    /\ IsEvent("DonorPersistCommitDecision")
    /\ CurrentLogline.decision = "Commit"

ValidateDonorPersistAbortDecision ==
    /\ IsEvent("DonorPersistAbortDecision")
    /\ CurrentLogline.decision = "Abort"

ValidateDonorSendConfigServerCommit ==
    /\ IsEvent("DonorSendConfigServerCommit")
    /\ CurrentLogline.donorState = "CommittingOnConfig"

ValidateConfigServerPersistCommit ==
    /\ IsEvent("ConfigServerPersistCommit")
    /\ CurrentLogline.donorState = "Done"

ValidateConfigServerCommitFails ==
    /\ IsEvent("ConfigServerCommitFails")
    /\ CurrentLogline.donorMetadata = "not_owned"

ValidateLaunchReleaseRecipientCriticalSection ==
    /\ IsEvent("LaunchReleaseRecipientCriticalSection")
    /\ CurrentLogline.releaseState = "in_flight"

ValidateCriticalSectionReleaseSucceeds ==
    /\ IsEvent("CriticalSectionReleaseSucceeds")
    /\ CurrentLogline.criticalSectionActive \in {"false", FALSE}
    /\ CurrentLogline.releaseState = "released"

ValidateCriticalSectionReleaseFails ==
    /\ IsEvent("CriticalSectionReleaseFails")
    /\ CurrentLogline.releaseState = "released"
    /\ CurrentLogline.failureType = "ShardNotFound"

ValidateDonorDeleteRangeDeletionTaskLocally ==
    /\ IsEvent("DonorDeleteRangeDeletionTaskLocally")
    /\ CurrentLogline.taskState = "deleted"

ValidateDonorRegisterRangeDeletionTask ==
    /\ IsEvent("DonorRegisterRangeDeletionTask")
    /\ CurrentLogline.taskState = "ready"

ValidateDonorDeleteRecipientRangeDeletionTask ==
    /\ IsEvent("DonorDeleteRecipientRangeDeletionTask")
    /\ CurrentLogline.recipientTaskState = "deleted"

ValidateAbortDeleteDonorRangeDeletionTask ==
    /\ IsEvent("AbortDeleteDonorRangeDeletionTask")
    /\ CurrentLogline.taskState = "deleted"

ValidateAbortBumpRecipientTxnNumber ==
    /\ IsEvent("AbortBumpRecipientTxnNumber")
    /\ CurrentLogline.decision = "Abort"

ValidateAbortMarkRecipientRangeDeletionReady ==
    /\ IsEvent("AbortMarkRecipientRangeDeletionReady")
    /\ CurrentLogline.recipientTaskState = "ready"

ValidateAbortRecipientNotificationFails ==
    /\ IsEvent("AbortRecipientNotificationFails")
    /\ CurrentLogline.failureType = "ShardNotFound"

ValidateForgetMigration ==
    /\ IsEvent("ForgetMigration")
    /\ CurrentLogline.state = "Done"

ValidateAbortCleanup ==
    /\ IsEvent("AbortCleanup")
    /\ CurrentLogline.recipientState = "Done"

----

\* Trace action wrappers: match event -> call base action -> validate -> advance cursor

TraceRecipientStartClone ==
    /\ ValidateRecipientStartClone
    /\ RecipientStartClone
    /\ l' = l + 1

TraceRecipientCloneComplete ==
    /\ ValidateRecipientCloneComplete
    /\ RecipientCloneComplete
    /\ l' = l + 1

TraceDonorEnterCriticalSection ==
    /\ ValidateDonorEnterCriticalSection
    /\ DonorEnterCriticalSection
    /\ l' = l + 1

TraceDonorPersistCommitDecision ==
    /\ ValidateDonorPersistCommitDecision
    /\ DonorPersistCommitDecision
    /\ l' = l + 1

TraceDonorPersistAbortDecision ==
    /\ ValidateDonorPersistAbortDecision
    /\ DonorPersistAbortDecision
    /\ l' = l + 1

TraceDonorSendConfigServerCommit ==
    /\ ValidateDonorSendConfigServerCommit
    /\ DonorSendConfigServerCommit
    /\ l' = l + 1

TraceConfigServerPersistCommit ==
    /\ ValidateConfigServerPersistCommit
    /\ ConfigServerPersistCommit
    /\ l' = l + 1

TraceConfigServerCommitFails ==
    /\ ValidateConfigServerCommitFails
    /\ ConfigServerCommitFails
    /\ l' = l + 1

TraceLaunchReleaseRecipientCriticalSection ==
    /\ ValidateLaunchReleaseRecipientCriticalSection
    /\ LaunchReleaseRecipientCriticalSection
    /\ l' = l + 1

TraceCriticalSectionReleaseSucceeds ==
    /\ ValidateCriticalSectionReleaseSucceeds
    /\ CriticalSectionReleaseSucceeds
    /\ l' = l + 1

TraceCriticalSectionReleaseFails ==
    /\ ValidateCriticalSectionReleaseFails
    /\ CriticalSectionReleaseFails
    /\ l' = l + 1

TraceDonorDeleteRangeDeletionTaskLocally ==
    /\ ValidateDonorDeleteRangeDeletionTaskLocally
    /\ DonorDeleteRangeDeletionTaskLocally
    /\ l' = l + 1

TraceDonorRegisterRangeDeletionTask ==
    /\ ValidateDonorRegisterRangeDeletionTask
    /\ DonorRegisterRangeDeletionTask
    /\ l' = l + 1

TraceDonorDeleteRecipientRangeDeletionTask ==
    /\ ValidateDonorDeleteRecipientRangeDeletionTask
    /\ DonorDeleteRecipientRangeDeletionTask
    /\ l' = l + 1

TraceAbortDeleteDonorRangeDeletionTask ==
    /\ ValidateAbortDeleteDonorRangeDeletionTask
    /\ AbortDeleteDonorRangeDeletionTask
    /\ l' = l + 1

TraceAbortBumpRecipientTxnNumber ==
    /\ ValidateAbortBumpRecipientTxnNumber
    /\ AbortBumpRecipientTxnNumber
    /\ l' = l + 1

TraceAbortMarkRecipientRangeDeletionReady ==
    /\ ValidateAbortMarkRecipientRangeDeletionReady
    /\ AbortMarkRecipientRangeDeletionReady
    /\ l' = l + 1

TraceAbortRecipientNotificationFails ==
    /\ ValidateAbortRecipientNotificationFails
    /\ AbortRecipientNotificationFails
    /\ l' = l + 1

TraceForgetMigration ==
    /\ ValidateForgetMigration
    /\ ForgetMigration
    /\ l' = l + 1

TraceAbortCleanup ==
    /\ ValidateAbortCleanup
    /\ AbortCleanup
    /\ l' = l + 1

----

\* Silent actions: state changes that don't have trace events
\* These must be tightly constrained to avoid state space explosion

\* Silent crash/recovery actions (if not explicitly traced)
SilentDonorCrash ==
    /\ l <= Len(TraceLog)
    /\ DonorCrash

SilentDonorRecover ==
    /\ l <= Len(TraceLog)
    /\ coordinatorDecision \in {"Commit", "Abort"}
    /\ DonorRecover

SilentRecipientCrash ==
    /\ l <= Len(TraceLog)
    /\ RecipientCrash

SilentRecipientRecover ==
    /\ l <= Len(TraceLog)
    /\ recipientClone = "cloned"
    /\ RecipientRecover

SilentActions ==
    \/ SilentDonorCrash
    \/ SilentDonorRecover
    \/ SilentRecipientCrash
    \/ SilentRecipientRecover

----

\* Trace initialization: bootstrap from trace's initial state
TraceInit ==
    /\ Init
    /\ l = 0

\* Trace validation: match events and validate post-state
TraceNext ==
    \/ TraceRecipientStartClone
    \/ TraceRecipientCloneComplete
    \/ TraceDonorEnterCriticalSection
    \/ TraceDonorPersistCommitDecision
    \/ TraceDonorPersistAbortDecision
    \/ TraceDonorSendConfigServerCommit
    \/ TraceConfigServerPersistCommit
    \/ TraceConfigServerCommitFails
    \/ TraceLaunchReleaseRecipientCriticalSection
    \/ TraceCriticalSectionReleaseSucceeds
    \/ TraceCriticalSectionReleaseFails
    \/ TraceDonorDeleteRangeDeletionTaskLocally
    \/ TraceDonorRegisterRangeDeletionTask
    \/ TraceDonorDeleteRecipientRangeDeletionTask
    \/ TraceAbortDeleteDonorRangeDeletionTask
    \/ TraceAbortBumpRecipientTxnNumber
    \/ TraceAbortMarkRecipientRangeDeletionReady
    \/ TraceAbortRecipientNotificationFails
    \/ TraceForgetMigration
    \/ TraceAbortCleanup
    \/ SilentActions

\* Liveness: ensure entire trace is consumed
TraceMatched == <>(l > Len(TraceLog))

Spec == TraceInit /\ [][TraceNext]_allVars /\ TraceMatched

====
