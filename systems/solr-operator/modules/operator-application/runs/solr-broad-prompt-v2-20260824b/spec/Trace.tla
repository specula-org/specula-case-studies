---------------------------- MODULE Trace -----------------------------
(***************************************************************************
 * Category A linear trace replay for the Solr Operator interaction model.
 * Every event calls the corresponding complete base action and validates the
 * complete post-state projection for that Scenario.
 *************************************************************************)

EXTENDS base, Json, IOUtils, Sequences, TLC

B == INSTANCE base

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x
        /\ "after" \in DOMAIN x))

ASSUME Len(TraceLog) > 0

VARIABLE l

traceVars == <<vars, l>>

SeqAsSet(s) == {s[i] : i \in 1..Len(s)}

(***************************************************************************
 * Strong post-state validators. instrumentation-spec.md requires every event
 * in a Scenario family to emit the complete matching `after` object below.
 *************************************************************************)

ValidateManagedUpdatePost(a) ==
    /\ replicaType' = a.replicaType
    /\ replicaState' = a.replicaState
    /\ replicaNode' = a.replicaNode
    /\ leader' = a.leader
    /\ podRevision' = a.podRevision
    /\ podReady' = a.podReady
    /\ podExists' = a.podExists
    /\ scheduledForDeletion' = SeqAsSet(a.scheduledForDeletion)
    /\ clusterSnapshot' = a.clusterSnapshot
    /\ snapshotValid' = a.snapshotValid
    /\ selectedForUpdate' = SeqAsSet(a.selectedForUpdate)
    /\ selectionPending' = a.selectionPending

ValidateClusterOpPost(a) ==
    /\ clusterOpLock' = SeqAsSet(a.clusterOpLock)
    /\ opQueue' = SeqAsSet(a.opQueue)
    /\ opStatus' = a.opStatus
    /\ opError' = a.opError
    /\ asyncState' = a.asyncState
    /\ retryDue' = SeqAsSet(a.retryDue)
    /\ eventDue' = SeqAsSet(a.eventDue)
    /\ dispatchReady' = SeqAsSet(a.dispatchReady)
    /\ handlerReturned' = SeqAsSet(a.handlerReturned)
    /\ handlerRequestInProgress' = SeqAsSet(a.handlerRequestInProgress)
    /\ balanceReadyToSubmit' = SeqAsSet(a.balanceReadyToSubmit)
    /\ opAge' = a.opAge

ValidateBackupPost(a) ==
    /\ availableCollections' = SeqAsSet(a.availableCollections)
    /\ backupActive' = a.backupActive
    /\ backupCohort' = SeqAsSet(a.backupCohort)
    /\ initialBackupCohort' = SeqAsSet(a.initialBackupCohort)
    /\ workingCRStatus' = a.workingCRStatus
    /\ durableCRStatus' = a.durableCRStatus
    /\ taskState' = a.taskState
    /\ taskRecord' = a.taskRecord
    /\ taskEverSubmitted' = a.taskEverSubmitted
    /\ cleanupPending' = SeqAsSet(a.cleanupPending)
    /\ backupFinished' = a.backupFinished
    /\ nextScheduled' = a.nextScheduled
    /\ backupListNeeded' = a.backupListNeeded
    /\ statusPatchPending' = a.statusPatchPending

ValidateBasicAuthPost(a) ==
    /\ basicAuthRequested' = a.basicAuthRequested
    /\ authPhase' = a.authPhase
    /\ authSecret' = a.authSecret
    /\ bootstrapSecret' = a.bootstrapSecret
    /\ credentialVersion' = a.credentialVersion
    /\ bootstrapVersion' = a.bootstrapVersion
    /\ securityJsonLoaded' = a.securityJsonLoaded
    /\ podTemplateHasBootstrap' = a.podTemplateHasBootstrap
    /\ podTemplateApplied' = a.podTemplateApplied
    /\ podCredentialVersion' = a.podCredentialVersion
    /\ zkSecurityVersion' = a.zkSecurityVersion
    /\ authPodReady' = a.authPodReady
    /\ cloudReady' = a.cloudReady

Advance == l' = l + 1

(***************************************************************************
 * Scenario 1 wrappers
 *************************************************************************)

TraceStartManagedUpdate(e) ==
    /\ e.event = "StartManagedUpdate"
    /\ B!StartManagedUpdate
    /\ ValidateManagedUpdatePost(e.after)
    /\ Advance

TraceGetNodeReplicaState(e) ==
    /\ e.event = "GetNodeReplicaState"
    /\ B!GetNodeReplicaState
    /\ ValidateManagedUpdatePost(e.after)
    /\ Advance

TraceDeterminePodsSafeToUpdate(e) ==
    /\ e.event = "DeterminePodsSafeToUpdate"
    /\ "pod" \in DOMAIN e
    /\ B!DeterminePodsSafeToUpdate(e.pod)
    /\ ValidateManagedUpdatePost(e.after)
    /\ Advance

TraceEnsurePodReadinessConditions(e) ==
    /\ e.event = "EnsurePodReadinessConditions"
    /\ "pod" \in DOMAIN e
    /\ B!EnsurePodReadinessConditions(e.pod)
    /\ ValidateManagedUpdatePost(e.after)
    /\ Advance

TraceDeletePodForUpdate(e) ==
    /\ e.event = "DeletePodForUpdate"
    /\ "pod" \in DOMAIN e
    /\ B!DeletePodForUpdate(e.pod)
    /\ ValidateManagedUpdatePost(e.after)
    /\ Advance

TraceStatefulSetRecreatePod(e) ==
    /\ e.event = "StatefulSetRecreatePod"
    /\ "pod" \in DOMAIN e
    /\ B!StatefulSetRecreatePod(e.pod)
    /\ ValidateManagedUpdatePost(e.after)
    /\ Advance

TraceSolrRecoverReplica(e) ==
    /\ e.event = "SolrRecoverReplica"
    /\ "replica" \in DOMAIN e
    /\ B!SolrRecoverReplica(e.replica)
    /\ ValidateManagedUpdatePost(e.after)
    /\ Advance

TraceSolrElectLeader(e) ==
    /\ e.event = "SolrElectLeader"
    /\ "shard" \in DOMAIN e
    /\ "replica" \in DOMAIN e
    /\ B!SolrElectLeader(e.shard, e.replica)
    /\ ValidateManagedUpdatePost(e.after)
    /\ Advance

(***************************************************************************
 * Scenario 2 wrappers
 *************************************************************************)

TraceStartRollingClusterOp(e) ==
    /\ e.event = "StartRollingClusterOp"
    /\ B!StartRollingClusterOp
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

TraceStartBalanceClusterOp(e) ==
    /\ e.event = "StartBalanceClusterOp"
    /\ B!StartBalanceClusterOp
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

TraceControllerRuntimeDeliverClusterOpEvent(e) ==
    /\ e.event = "ControllerRuntimeDeliverClusterOpEvent"
    /\ "op" \in DOMAIN e
    /\ B!ControllerRuntimeDeliverClusterOpEvent(e.op)
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

TraceHandleManagedCloudRollingUpdateClusterStateFailure(e) ==
    /\ e.event = "HandleManagedCloudRollingUpdateClusterStateFailure"
    /\ B!HandleManagedCloudRollingUpdateClusterStateFailure
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

TraceHandleManagedCloudRollingUpdateComplete(e) ==
    /\ e.event = "HandleManagedCloudRollingUpdateComplete"
    /\ B!HandleManagedCloudRollingUpdateComplete
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

TraceBalanceReplicasForClusterCheckFailure(e) ==
    /\ e.event = "BalanceReplicasForClusterCheckFailure"
    /\ B!BalanceReplicasForClusterCheckFailure
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

TraceBalanceReplicasForClusterNotFound(e) ==
    /\ e.event = "BalanceReplicasForClusterNotFound"
    /\ B!BalanceReplicasForClusterNotFound
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

TraceBalanceReplicasForClusterSubmitFailure(e) ==
    /\ e.event = "BalanceReplicasForClusterSubmitFailure"
    /\ B!BalanceReplicasForClusterSubmitFailure
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

TraceBalanceReplicasForClusterSubmitSuccess(e) ==
    /\ e.event = "BalanceReplicasForClusterSubmitSuccess"
    /\ B!BalanceReplicasForClusterSubmitSuccess
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

TraceSolrBalanceReplicasTaskCompletes(e) ==
    /\ e.event = "SolrBalanceReplicasTaskCompletes"
    /\ B!SolrBalanceReplicasTaskCompletes
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

TraceControllerTimerFires(e) ==
    /\ e.event = "ControllerTimerFires"
    /\ "op" \in DOMAIN e
    /\ B!ControllerTimerFires(e.op)
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

TraceBalanceReplicasForClusterCompleted(e) ==
    /\ e.event = "BalanceReplicasForClusterCompleted"
    /\ B!BalanceReplicasForClusterCompleted
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

TraceSolrCloudReconcileClusterOpDispatcher(e) ==
    /\ e.event = "SolrCloudReconcileClusterOpDispatcher"
    /\ "op" \in DOMAIN e
    /\ B!SolrCloudReconcileClusterOpDispatcher(e.op)
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

TraceRetryNextQueuedClusterOp(e) ==
    /\ e.event = "RetryNextQueuedClusterOp"
    /\ "op" \in DOMAIN e
    /\ B!RetryNextQueuedClusterOp(e.op)
    /\ ValidateClusterOpPost(e.after)
    /\ Advance

(***************************************************************************
 * Scenario 3 wrappers
 *************************************************************************)

TraceStartBackupRun(e) ==
    /\ e.event = "StartBackupRun"
    /\ B!StartBackupRun
    /\ ValidateBackupPost(e.after)
    /\ Advance

TraceDeleteCollectionDuringBackup(e) ==
    /\ e.event = "DeleteCollectionDuringBackup"
    /\ "collection" \in DOMAIN e
    /\ B!DeleteCollectionDuringBackup(e.collection)
    /\ ValidateBackupPost(e.after)
    /\ Advance

TraceAddCollectionDuringBackup(e) ==
    /\ e.event = "AddCollectionDuringBackup"
    /\ "collection" \in DOMAIN e
    /\ B!AddCollectionDuringBackup(e.collection)
    /\ ValidateBackupPost(e.after)
    /\ Advance

TraceListAllSolrCollections(e) ==
    /\ e.event = "ListAllSolrCollections"
    /\ B!ListAllSolrCollections
    /\ ValidateBackupPost(e.after)
    /\ Advance

TraceReconcileSolrCollectionBackupSubmit(e) ==
    /\ e.event = "ReconcileSolrCollectionBackupSubmit"
    /\ "collection" \in DOMAIN e
    /\ B!ReconcileSolrCollectionBackupSubmit(e.collection)
    /\ ValidateBackupPost(e.after)
    /\ Advance

TraceSolrBackupTaskCompletes(e) ==
    /\ e.event = "SolrBackupTaskCompletes"
    /\ "collection" \in DOMAIN e
    /\ B!SolrBackupTaskCompletes(e.collection)
    /\ ValidateBackupPost(e.after)
    /\ Advance

TraceCheckAsyncRequestCompleted(e) ==
    /\ e.event = "CheckAsyncRequestCompleted"
    /\ "collection" \in DOMAIN e
    /\ B!CheckAsyncRequestCompleted(e.collection)
    /\ ValidateBackupPost(e.after)
    /\ Advance

TraceDeleteAsyncRequestForBackup(e) ==
    /\ e.event = "DeleteAsyncRequestForBackup"
    /\ "collection" \in DOMAIN e
    /\ B!DeleteAsyncRequestForBackup(e.collection)
    /\ ValidateBackupPost(e.after)
    /\ Advance

TracePatchSolrBackupStatus(e) ==
    /\ e.event = "PatchSolrBackupStatus"
    /\ B!PatchSolrBackupStatus
    /\ ValidateBackupPost(e.after)
    /\ Advance

TracePatchSolrBackupStatusConflict(e) ==
    /\ e.event = "PatchSolrBackupStatusConflict"
    /\ B!PatchSolrBackupStatusConflict
    /\ ValidateBackupPost(e.after)
    /\ Advance

TraceCheckAsyncRequestNotFound(e) ==
    /\ e.event = "CheckAsyncRequestNotFound"
    /\ "collection" \in DOMAIN e
    /\ B!CheckAsyncRequestNotFound(e.collection)
    /\ ValidateBackupPost(e.after)
    /\ Advance

TraceUpdateStatusOfCollectionBackups(e) ==
    /\ e.event = "UpdateStatusOfCollectionBackups"
    /\ B!UpdateStatusOfCollectionBackups
    /\ ValidateBackupPost(e.after)
    /\ Advance

TraceScheduleNextBackup(e) ==
    /\ e.event = "ScheduleNextBackup"
    /\ B!ScheduleNextBackup
    /\ ValidateBackupPost(e.after)
    /\ Advance

(***************************************************************************
 * Scenario 4 wrappers
 *************************************************************************)

TraceRequestBasicAuth(e) ==
    /\ e.event = "RequestBasicAuth"
    /\ B!RequestBasicAuth
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

TraceReconcileForBasicAuthLookupMissingSecret(e) ==
    /\ e.event = "ReconcileForBasicAuthLookupMissingSecret"
    /\ B!ReconcileForBasicAuthLookupMissingSecret
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

TraceCreateBasicAuthSecret(e) ==
    /\ e.event = "CreateBasicAuthSecret"
    /\ B!CreateBasicAuthSecret
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

TraceCreateBootstrapSecret(e) ==
    /\ e.event = "CreateBootstrapSecret"
    /\ B!CreateBootstrapSecret
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

TraceFailBootstrapSecretCreate(e) ==
    /\ e.event = "FailBootstrapSecretCreate"
    /\ B!FailBootstrapSecretCreate
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

TraceControllerRuntimeRetryBasicAuth(e) ==
    /\ e.event = "ControllerRuntimeRetryBasicAuth"
    /\ B!ControllerRuntimeRetryBasicAuth
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

TraceReconcileForBasicAuthLookupExistingSecret(e) ==
    /\ e.event = "ReconcileForBasicAuthLookupExistingSecret"
    /\ B!ReconcileForBasicAuthLookupExistingSecret
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

TraceGenerateZKInteractionInitContainer(e) ==
    /\ e.event = "GenerateZKInteractionInitContainer"
    /\ B!GenerateZKInteractionInitContainer
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

TraceApplySecurityStatefulSet(e) ==
    /\ e.event = "ApplySecurityStatefulSet"
    /\ B!ApplySecurityStatefulSet
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

TraceRunSetupZKSecurityJson(e) ==
    /\ e.event = "RunSetupZKSecurityJson"
    /\ B!RunSetupZKSecurityJson
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

TraceKubernetesAuthPodBecomesReady(e) ==
    /\ e.event = "KubernetesAuthPodBecomesReady"
    /\ B!KubernetesAuthPodBecomesReady
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

TraceCreateCloudStatus(e) ==
    /\ e.event = "CreateCloudStatus"
    /\ B!CreateCloudStatus
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

TraceExternalModifyZKSecurity(e) ==
    /\ e.event = "ExternalModifyZKSecurity"
    /\ B!ExternalModifyZKSecurity
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

TraceManualCreateBootstrapSecret(e) ==
    /\ e.event = "ManualCreateBootstrapSecret"
    /\ B!ManualCreateBootstrapSecret
    /\ ValidateBasicAuthPost(e.after)
    /\ Advance

(***************************************************************************
 * Dispatch and completion
 *************************************************************************)

MatchEvent(e) ==
    \/ TraceStartManagedUpdate(e)
    \/ TraceGetNodeReplicaState(e)
    \/ TraceDeterminePodsSafeToUpdate(e)
    \/ TraceEnsurePodReadinessConditions(e)
    \/ TraceDeletePodForUpdate(e)
    \/ TraceStatefulSetRecreatePod(e)
    \/ TraceSolrRecoverReplica(e)
    \/ TraceSolrElectLeader(e)
    \/ TraceStartRollingClusterOp(e)
    \/ TraceStartBalanceClusterOp(e)
    \/ TraceControllerRuntimeDeliverClusterOpEvent(e)
    \/ TraceHandleManagedCloudRollingUpdateClusterStateFailure(e)
    \/ TraceHandleManagedCloudRollingUpdateComplete(e)
    \/ TraceBalanceReplicasForClusterCheckFailure(e)
    \/ TraceBalanceReplicasForClusterNotFound(e)
    \/ TraceBalanceReplicasForClusterSubmitFailure(e)
    \/ TraceBalanceReplicasForClusterSubmitSuccess(e)
    \/ TraceSolrBalanceReplicasTaskCompletes(e)
    \/ TraceControllerTimerFires(e)
    \/ TraceBalanceReplicasForClusterCompleted(e)
    \/ TraceSolrCloudReconcileClusterOpDispatcher(e)
    \/ TraceRetryNextQueuedClusterOp(e)
    \/ TraceStartBackupRun(e)
    \/ TraceDeleteCollectionDuringBackup(e)
    \/ TraceAddCollectionDuringBackup(e)
    \/ TraceListAllSolrCollections(e)
    \/ TraceReconcileSolrCollectionBackupSubmit(e)
    \/ TraceSolrBackupTaskCompletes(e)
    \/ TraceCheckAsyncRequestCompleted(e)
    \/ TraceDeleteAsyncRequestForBackup(e)
    \/ TracePatchSolrBackupStatus(e)
    \/ TracePatchSolrBackupStatusConflict(e)
    \/ TraceCheckAsyncRequestNotFound(e)
    \/ TraceUpdateStatusOfCollectionBackups(e)
    \/ TraceScheduleNextBackup(e)
    \/ TraceRequestBasicAuth(e)
    \/ TraceReconcileForBasicAuthLookupMissingSecret(e)
    \/ TraceCreateBasicAuthSecret(e)
    \/ TraceCreateBootstrapSecret(e)
    \/ TraceFailBootstrapSecretCreate(e)
    \/ TraceControllerRuntimeRetryBasicAuth(e)
    \/ TraceReconcileForBasicAuthLookupExistingSecret(e)
    \/ TraceGenerateZKInteractionInitContainer(e)
    \/ TraceApplySecurityStatefulSet(e)
    \/ TraceRunSetupZKSecurityJson(e)
    \/ TraceKubernetesAuthPodBecomesReady(e)
    \/ TraceCreateCloudStatus(e)
    \/ TraceExternalModifyZKSecurity(e)
    \/ TraceManualCreateBootstrapSecret(e)

TraceInit == Init /\ l = 1

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ LET e == TraceLog[l]
          IN MatchEvent(e)
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED traceVars

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_traceVars
    \* Prevent the stuttering closure from satisfying a replay without ever
    \* consuming an enabled event; completion-state stuttering remains legal.
    /\ WF_traceVars(TraceNext)

TraceMatched == <>(l > Len(TraceLog))

TraceView == <<vars, l>>

=============================================================================
