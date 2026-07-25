------------------------------ MODULE Trace --------------------------------
(* Trace validation spec for MongoDB chunk migration.
   Replays NDJSON execution traces from the instrumented implementation
   against the base spec to verify state consistency at each step.

   Category A (Distributed / Message-Passing): single linear trace cursor `l`.
*)

EXTENDS base, Sequences, Naturals, TLC, IOUtils, Json

-----------------------------------------------------------------------------
(* TRACE LOADING *)

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

-----------------------------------------------------------------------------
(* CURSOR *)

VARIABLE l   \* cursor into TraceLog; l=1 is the first event

-----------------------------------------------------------------------------
(* HELPERS *)

logline == TraceLog[l]

IsEvent(name)           == logline.event = name
IsNodeEvent(name, node) == logline.event = name /\ logline.node = node

\* Map trace string values to spec constants
MapDecision(s) ==
    IF s = "committed" THEN COMMITTED
    ELSE IF s = "aborted" THEN ABORTED
    ELSE NONE

MapRecipientState(s) ==
    IF s = "kInit"          THEN kInit
    ELSE IF s = "kCloning"  THEN kCloning
    ELSE IF s = "kEnteredCritSec" THEN kEnteredCritSec
    ELSE IF s = "kDone"     THEN kDone
    ELSE IF s = "kFail"     THEN kFail
    ELSE IF s = "kAbort"    THEN kAbort
    ELSE kInit

MapRDTask(s) ==
    IF s = "absent"  THEN RD_ABSENT
    ELSE IF s = "pending" THEN RD_PENDING
    ELSE IF s = "ready"  THEN RD_READY
    ELSE RD_ABSENT

MapDonorPhase(s) ==
    IF s = "d_init"      THEN D_INIT
    ELSE IF s = "d_cloning"  THEN D_CLONING
    ELSE IF s = "d_critsec"  THEN D_CRITSEC
    ELSE IF s = "d_committed" THEN D_COMMITTED
    ELSE IF s = "d_aborted"  THEN D_ABORTED
    ELSE D_INIT

-----------------------------------------------------------------------------
(* POST-STATE VALIDATION *)

\* Called after each action wrapper to verify spec state matches trace post-state.
\* logline.after contains the state snapshot captured AFTER the action in the impl.

ValidatePostState ==
    /\ (IF "donorPhase" \in DOMAIN logline.after
        THEN donorPhase' = MapDonorPhase(logline.after.donorPhase)
        ELSE TRUE)
    /\ (IF "recipientState" \in DOMAIN logline.after
        THEN recipientState' = MapRecipientState(logline.after.recipientState)
        ELSE TRUE)
    /\ (IF "configCommitted" \in DOMAIN logline.after
        THEN configCommitted' = logline.after.configCommitted
        ELSE TRUE)
    /\ (IF "coordinatorDocPresent" \in DOMAIN logline.after
        THEN coordinatorDocPresent' = logline.after.coordinatorDocPresent
        ELSE TRUE)
    /\ (IF "coordinatorDocDecision" \in DOMAIN logline.after
        THEN coordinatorDocDecision' = MapDecision(logline.after.coordinatorDocDecision)
        ELSE TRUE)
    /\ (IF "critSecReleaseRPCSent" \in DOMAIN logline.after
        THEN critSecReleaseRPCSent' = logline.after.critSecReleaseRPCSent
        ELSE TRUE)
    /\ (IF "recipientCritSecReleased" \in DOMAIN logline.after
        THEN recipientCritSecReleased' = logline.after.recipientCritSecReleased
        ELSE TRUE)
    /\ (IF "donorRDTask" \in DOMAIN logline.after
        THEN donorRDTask' = MapRDTask(logline.after.donorRDTask)
        ELSE TRUE)
    /\ (IF "recipientRDTask" \in DOMAIN logline.after
        THEN recipientRDTask' = MapRDTask(logline.after.recipientRDTask)
        ELSE TRUE)

-----------------------------------------------------------------------------
(* BOOTSTRAP: initial trace state *)

\* The trace may start mid-migration (e.g., after crash recovery).
\* TraceInit reads the first event's 'before' snapshot to seed the spec state.
TraceInit ==
    /\ l = 1
    /\ LET first == TraceLog[1].before IN
       /\ donorPhase              = MapDonorPhase(first.donorPhase)
       /\ recipientState          = MapRecipientState(first.recipientState)
       /\ configCommitted         = first.configCommitted
       /\ coordinatorDocPresent   = first.coordinatorDocPresent
       /\ coordinatorDocDecision  = MapDecision(first.coordinatorDocDecision)
       /\ critSecReleaseRPCSent   = first.critSecReleaseRPCSent
       /\ recipientCritSecReleased = first.recipientCritSecReleased
       /\ donorCrashed            = first.donorCrashed
       /\ recipientAbortSignaled  = first.recipientAbortSignaled
       /\ recipientRecoveryDocPresent = first.recipientRecoveryDocPresent
       /\ recipientInRecovery     = first.recipientInRecovery
       /\ donorRDTask             = MapRDTask(first.donorRDTask)
       /\ recipientRDTask         = MapRDTask(first.recipientRDTask)

-----------------------------------------------------------------------------
(* ACTION WRAPPERS *)

\* Each wrapper: match event → call base spec action → validate post-state → advance cursor.

TraceStartClone ==
    /\ IsEvent("StartClone")
    /\ StartClone
    /\ ValidatePostState
    /\ l' = l + 1

TraceRecipientBeginClone ==
    /\ IsEvent("RecipientBeginClone")
    /\ RecipientBeginClone
    /\ ValidatePostState
    /\ l' = l + 1

TraceDonorEnterCriticalSection ==
    /\ IsEvent("DonorEnterCriticalSection")
    /\ DonorEnterCriticalSection
    /\ ValidatePostState
    /\ l' = l + 1

TraceRecipientEnterCriticalSection ==
    /\ IsEvent("RecipientEnterCriticalSection")
    /\ RecipientEnterCriticalSection
    /\ ValidatePostState
    /\ l' = l + 1

TraceCommitChunkMigrationOnConfigServer ==
    /\ IsEvent("CommitChunkMigrationOnConfigServer")
    /\ CommitChunkMigrationOnConfigServer
    /\ ValidatePostState
    /\ l' = l + 1

TraceLaunchReleaseRecipientCritSec ==
    /\ IsEvent("LaunchReleaseRecipientCritSec")
    /\ LaunchReleaseRecipientCritSec
    /\ ValidatePostState
    /\ l' = l + 1

TraceRecipientReleaseCritSec ==
    /\ IsEvent("RecipientReleaseCritSec")
    /\ RecipientReleaseCritSec
    /\ ValidatePostState
    /\ l' = l + 1

TracePersistCommitDecision ==
    /\ IsEvent("PersistCommitDecision")
    /\ PersistCommitDecision
    /\ ValidatePostState
    /\ l' = l + 1

TraceDeleteRecipientRangeDeletionTask ==
    /\ IsEvent("DeleteRecipientRangeDeletionTask")
    /\ DeleteRecipientRangeDeletionTask
    /\ ValidatePostState
    /\ l' = l + 1

TraceMarkDonorRangeDeletionTaskReady ==
    /\ IsEvent("MarkDonorRangeDeletionTaskReady")
    /\ MarkDonorRangeDeletionTaskReady
    /\ ValidatePostState
    /\ l' = l + 1

TraceForgetMigration ==
    /\ IsEvent("ForgetMigration")
    /\ ForgetMigration
    /\ ValidatePostState
    /\ l' = l + 1

TracePersistAbortDecision ==
    /\ IsEvent("PersistAbortDecision")
    /\ PersistAbortDecision
    /\ ValidatePostState
    /\ l' = l + 1

TraceDeleteDonorRangeDeletionTaskOnAbort ==
    /\ IsEvent("DeleteDonorRangeDeletionTaskOnAbort")
    /\ DeleteDonorRangeDeletionTaskOnAbort
    /\ ValidatePostState
    /\ l' = l + 1

TraceMarkRecipientRangeDeletionTaskReadyOnAbort ==
    /\ IsEvent("MarkRecipientRangeDeletionTaskReadyOnAbort")
    /\ MarkRecipientRangeDeletionTaskReadyOnAbort
    /\ ValidatePostState
    /\ l' = l + 1

TraceCrashDonor ==
    /\ IsEvent("CrashDonor")
    /\ CrashDonor
    /\ ValidatePostState
    /\ l' = l + 1

TraceRecoverDonor ==
    /\ IsEvent("RecoverDonor")
    /\ RecoverDonor
    /\ ValidatePostState
    /\ l' = l + 1

TraceRecoverDonorNoDecision ==
    /\ IsEvent("RecoverDonorNoDecision")
    /\ RecoverDonorNoDecision
    /\ ValidatePostState
    /\ l' = l + 1

TraceStartRecipientRecovery ==
    /\ IsEvent("StartRecipientRecovery")
    /\ StartRecipientRecovery
    /\ ValidatePostState
    /\ l' = l + 1

TraceConcurrentAbortSignalDuringRecovery ==
    /\ IsEvent("ConcurrentAbortSignalDuringRecovery")
    /\ ConcurrentAbortSignalDuringRecovery
    /\ ValidatePostState
    /\ l' = l + 1

TraceRecoverySetsCritSecState ==
    /\ IsEvent("RecoverySetsCritSecState")
    /\ RecoverySetsCritSecState
    /\ ValidatePostState
    /\ l' = l + 1

-----------------------------------------------------------------------------
(* SILENT ACTIONS *)
\* Fire base actions without consuming a trace event.
\* Tightly constrained to avoid state space explosion.

\* RecipientReleaseCritSec may occur without a separate trace event
\* if the async RPC is processed before the next donor event is logged.
SilentRecipientReleaseCritSec ==
    /\ l <= Len(TraceLog)
    /\ critSecReleaseRPCSent = TRUE        \* RPC must have been sent
    /\ ~recipientCritSecReleased
    \* Only fire if next event requires crit sec to be released
    /\ TraceLog[l].event \in {"PersistCommitDecision",
                               "DeleteRecipientRangeDeletionTask",
                               "ForgetMigration"}
    /\ RecipientReleaseCritSec
    /\ UNCHANGED l

-----------------------------------------------------------------------------
(* TRACE NEXT *)

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ \/ TraceStartClone
          \/ TraceRecipientBeginClone
          \/ TraceDonorEnterCriticalSection
          \/ TraceRecipientEnterCriticalSection
          \/ TraceCommitChunkMigrationOnConfigServer
          \/ TraceLaunchReleaseRecipientCritSec
          \/ TraceRecipientReleaseCritSec
          \/ TracePersistCommitDecision
          \/ TraceDeleteRecipientRangeDeletionTask
          \/ TraceMarkDonorRangeDeletionTaskReady
          \/ TraceForgetMigration
          \/ TracePersistAbortDecision
          \/ TraceDeleteDonorRangeDeletionTaskOnAbort
          \/ TraceMarkRecipientRangeDeletionTaskReadyOnAbort
          \/ TraceCrashDonor
          \/ TraceRecoverDonor
          \/ TraceRecoverDonorNoDecision
          \/ TraceStartRecipientRecovery
          \/ TraceConcurrentAbortSignalDuringRecovery
          \/ TraceRecoverySetsCritSecState
          \/ (SilentRecipientReleaseCritSec /\ UNCHANGED l)
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED <<vars, l>>

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>> /\ WF_<<vars,l>>(TraceNext)

\* Temporal property: full trace must be consumed
TraceMatched == <>(l > Len(TraceLog))

=============================================================================
