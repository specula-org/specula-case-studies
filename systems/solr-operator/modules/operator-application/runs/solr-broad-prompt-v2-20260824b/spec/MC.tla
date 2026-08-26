------------------------------ MODULE MC ------------------------------
(***************************************************************************
 * Counter-bounded model-checking wrapper for base.tla.
 *
 * Bound only client/environment choices and injected failures. Controller
 * handlers, Kubernetes observations, Solr completions, status aggregation,
 * and recovery actions remain unbounded reactive steps.
 *************************************************************************)

EXTENDS base

B == INSTANCE base

CONSTANTS
    MaxManagedUpdateStarts,
    MaxRollingStarts,
    MaxBalanceStarts,
    MaxRollingApiFailures,
    MaxBalanceCheckFailures,
    MaxBalanceSubmitFailures,
    MaxBackupStarts,
    MaxCollectionDeletes,
    MaxCollectionAdds,
    MaxStatusPatchConflicts,
    MaxBasicAuthRequests,
    MaxBootstrapCreateFailures,
    MaxExternalZKChanges,
    MaxManualBootstrapRepairs

ASSUME
    /\ MaxManagedUpdateStarts \in Nat
    /\ MaxRollingStarts \in Nat
    /\ MaxBalanceStarts \in Nat
    /\ MaxRollingApiFailures \in Nat
    /\ MaxBalanceCheckFailures \in Nat
    /\ MaxBalanceSubmitFailures \in Nat
    /\ MaxBackupStarts \in Nat
    /\ MaxCollectionDeletes \in Nat
    /\ MaxCollectionAdds \in Nat
    /\ MaxStatusPatchConflicts \in Nat
    /\ MaxBasicAuthRequests \in Nat
    /\ MaxBootstrapCreateFailures \in Nat
    /\ MaxExternalZKChanges \in Nat
    /\ MaxManualBootstrapRepairs \in Nat

VARIABLE faultCounters

faultVars == <<faultCounters>>
mcVars == <<vars, faultVars>>

(***************************************************************************
 * Counter-bounded client/fault actions
 *************************************************************************)

MCStartManagedUpdate ==
    /\ faultCounters.managedUpdate < MaxManagedUpdateStarts
    /\ B!StartManagedUpdate
    /\ faultCounters' = [faultCounters EXCEPT !.managedUpdate = @ + 1]

MCStartRollingClusterOp ==
    /\ faultCounters.rollingStart < MaxRollingStarts
    /\ B!StartRollingClusterOp
    /\ faultCounters' = [faultCounters EXCEPT !.rollingStart = @ + 1]

MCStartBalanceClusterOp ==
    /\ faultCounters.balanceStart < MaxBalanceStarts
    /\ B!StartBalanceClusterOp
    /\ faultCounters' = [faultCounters EXCEPT !.balanceStart = @ + 1]

MCHandleManagedCloudRollingUpdateClusterStateFailure ==
    /\ faultCounters.rollingApiFailure < MaxRollingApiFailures
    /\ B!HandleManagedCloudRollingUpdateClusterStateFailure
    /\ faultCounters' =
          [faultCounters EXCEPT !.rollingApiFailure = @ + 1]

MCBalanceReplicasForClusterCheckFailure ==
    /\ faultCounters.balanceCheckFailure < MaxBalanceCheckFailures
    /\ B!BalanceReplicasForClusterCheckFailure
    /\ faultCounters' =
          [faultCounters EXCEPT !.balanceCheckFailure = @ + 1]

MCBalanceReplicasForClusterSubmitFailure ==
    /\ faultCounters.balanceSubmitFailure < MaxBalanceSubmitFailures
    /\ B!BalanceReplicasForClusterSubmitFailure
    /\ faultCounters' =
          [faultCounters EXCEPT !.balanceSubmitFailure = @ + 1]

MCStartBackupRun ==
    /\ faultCounters.backupStart < MaxBackupStarts
    /\ B!StartBackupRun
    /\ faultCounters' = [faultCounters EXCEPT !.backupStart = @ + 1]

MCDeleteCollectionDuringBackup(c) ==
    /\ faultCounters.collectionDelete < MaxCollectionDeletes
    /\ B!DeleteCollectionDuringBackup(c)
    /\ faultCounters' =
          [faultCounters EXCEPT !.collectionDelete = @ + 1]

MCAddCollectionDuringBackup(c) ==
    /\ faultCounters.collectionAdd < MaxCollectionAdds
    /\ B!AddCollectionDuringBackup(c)
    /\ faultCounters' =
          [faultCounters EXCEPT !.collectionAdd = @ + 1]

MCPatchSolrBackupStatusConflict ==
    /\ faultCounters.statusPatchConflict < MaxStatusPatchConflicts
    /\ B!PatchSolrBackupStatusConflict
    /\ faultCounters' =
          [faultCounters EXCEPT !.statusPatchConflict = @ + 1]

MCRequestBasicAuth ==
    /\ faultCounters.basicAuthRequest < MaxBasicAuthRequests
    /\ B!RequestBasicAuth
    /\ faultCounters' =
          [faultCounters EXCEPT !.basicAuthRequest = @ + 1]

MCFailBootstrapSecretCreate ==
    /\ faultCounters.bootstrapCreateFailure < MaxBootstrapCreateFailures
    /\ B!FailBootstrapSecretCreate
    /\ faultCounters' =
          [faultCounters EXCEPT !.bootstrapCreateFailure = @ + 1]

MCExternalModifyZKSecurity ==
    /\ faultCounters.externalZKChange < MaxExternalZKChanges
    /\ B!ExternalModifyZKSecurity
    /\ faultCounters' =
          [faultCounters EXCEPT !.externalZKChange = @ + 1]

MCManualCreateBootstrapSecret ==
    /\ faultCounters.manualBootstrapRepair < MaxManualBootstrapRepairs
    /\ B!ManualCreateBootstrapSecret
    /\ faultCounters' =
          [faultCounters EXCEPT !.manualBootstrapRepair = @ + 1]

(***************************************************************************
 * Initialization and next-state relation
 *************************************************************************)

MCInit ==
    /\ Init
    /\ faultCounters = [
         managedUpdate         |-> 0,
         rollingStart          |-> 0,
         balanceStart          |-> 0,
         rollingApiFailure     |-> 0,
         balanceCheckFailure   |-> 0,
         balanceSubmitFailure  |-> 0,
         backupStart           |-> 0,
         collectionDelete      |-> 0,
         collectionAdd         |-> 0,
         statusPatchConflict   |-> 0,
         basicAuthRequest      |-> 0,
         bootstrapCreateFailure|-> 0,
         externalZKChange      |-> 0,
         manualBootstrapRepair |-> 0]

MCNext ==
    \* Bounded external/fault actions. Config operator replacement maps each
    \* inherited base name to the corresponding MC wrapper above.
    \/ StartManagedUpdate
    \/ StartRollingClusterOp
    \/ StartBalanceClusterOp
    \/ HandleManagedCloudRollingUpdateClusterStateFailure
    \/ BalanceReplicasForClusterCheckFailure
    \/ BalanceReplicasForClusterSubmitFailure
    \/ StartBackupRun
    \/ \E c \in Collections : DeleteCollectionDuringBackup(c)
    \/ \E c \in Collections : AddCollectionDuringBackup(c)
    \/ PatchSolrBackupStatusConflict
    \/ RequestBasicAuth
    \/ FailBootstrapSecretCreate
    \/ ExternalModifyZKSecurity
    \/ ManualCreateBootstrapSecret

    \* Unbounded deterministic/reactive managed-update actions.
    \/ /\ B!GetNodeReplicaState
       /\ UNCHANGED faultVars
    \/ /\ \E p \in Pods : B!DeterminePodsSafeToUpdate(p)
       /\ UNCHANGED faultVars
    \/ /\ \E p \in Pods : B!EnsurePodReadinessConditions(p)
       /\ UNCHANGED faultVars
    \/ /\ \E p \in Pods : B!DeletePodForUpdate(p)
       /\ UNCHANGED faultVars
    \/ /\ \E p \in Pods : B!StatefulSetRecreatePod(p)
       /\ UNCHANGED faultVars
    \/ /\ \E r \in Replicas : B!SolrRecoverReplica(r)
       /\ UNCHANGED faultVars
    \/ /\ \E s \in Shards, r \in Replicas : B!SolrElectLeader(s, r)
       /\ UNCHANGED faultVars

    \* Unbounded cluster-operation delivery, handlers, and completion.
    \/ /\ \E op \in ClusterOps :
              B!ControllerRuntimeDeliverClusterOpEvent(op)
       /\ UNCHANGED faultVars
    \/ /\ B!HandleManagedCloudRollingUpdateComplete
       /\ UNCHANGED faultVars
    \/ /\ B!BalanceReplicasForClusterNotFound
       /\ UNCHANGED faultVars
    \/ /\ B!BalanceReplicasForClusterSubmitSuccess
       /\ UNCHANGED faultVars
    \/ /\ B!SolrBalanceReplicasTaskCompletes
       /\ UNCHANGED faultVars
    \/ /\ \E op \in ClusterOps : B!ControllerTimerFires(op)
       /\ UNCHANGED faultVars
    \/ /\ B!BalanceReplicasForClusterCompleted
       /\ UNCHANGED faultVars
    \/ /\ \E op \in ClusterOps :
              B!SolrCloudReconcileClusterOpDispatcher(op)
       /\ UNCHANGED faultVars
    \/ /\ \E op \in ClusterOps : B!RetryNextQueuedClusterOp(op)
       /\ UNCHANGED faultVars

    \* Unbounded backup submission, observation, persistence, and scheduling.
    \/ /\ B!ListAllSolrCollections
       /\ UNCHANGED faultVars
    \/ /\ \E c \in Collections :
              B!ReconcileSolrCollectionBackupSubmit(c)
       /\ UNCHANGED faultVars
    \/ /\ \E c \in Collections : B!SolrBackupTaskCompletes(c)
       /\ UNCHANGED faultVars
    \/ /\ \E c \in Collections : B!CheckAsyncRequestCompleted(c)
       /\ UNCHANGED faultVars
    \/ /\ \E c \in Collections : B!DeleteAsyncRequestForBackup(c)
       /\ UNCHANGED faultVars
    \/ /\ B!PatchSolrBackupStatus
       /\ UNCHANGED faultVars
    \/ /\ \E c \in Collections : B!CheckAsyncRequestNotFound(c)
       /\ UNCHANGED faultVars
    \/ /\ B!UpdateStatusOfCollectionBackups
       /\ UNCHANGED faultVars
    \/ /\ B!ScheduleNextBackup
       /\ UNCHANGED faultVars

    \* Unbounded BasicAuth reconciliation and managed-system observation.
    \/ /\ B!ReconcileForBasicAuthLookupMissingSecret
       /\ UNCHANGED faultVars
    \/ /\ B!CreateBasicAuthSecret
       /\ UNCHANGED faultVars
    \/ /\ B!CreateBootstrapSecret
       /\ UNCHANGED faultVars
    \/ /\ B!ControllerRuntimeRetryBasicAuth
       /\ UNCHANGED faultVars
    \/ /\ B!ReconcileForBasicAuthLookupExistingSecret
       /\ UNCHANGED faultVars
    \/ /\ B!GenerateZKInteractionInitContainer
       /\ UNCHANGED faultVars
    \/ /\ B!ApplySecurityStatefulSet
       /\ UNCHANGED faultVars
    \/ /\ B!RunSetupZKSecurityJson
       /\ UNCHANGED faultVars
    \/ /\ B!KubernetesAuthPodBecomesReady
       /\ UNCHANGED faultVars
    \/ /\ B!CreateCloudStatus
       /\ UNCHANGED faultVars

MCSpec == MCInit /\ [][MCNext]_mcVars

(***************************************************************************
 * View, constraints, and MC structural invariants
 *************************************************************************)

\* Fault counters affect which bounded environment/failure actions remain
\* enabled, so they are semantically part of the model-checking state. Omitting
\* them from VIEW can merge states with different future behaviors.
ModelView == <<vars, faultCounters>>

FaultCounterTypeOK ==
    /\ faultCounters.managedUpdate \in Nat
    /\ faultCounters.rollingStart \in Nat
    /\ faultCounters.balanceStart \in Nat
    /\ faultCounters.rollingApiFailure \in Nat
    /\ faultCounters.balanceCheckFailure \in Nat
    /\ faultCounters.balanceSubmitFailure \in Nat
    /\ faultCounters.backupStart \in Nat
    /\ faultCounters.collectionDelete \in Nat
    /\ faultCounters.collectionAdd \in Nat
    /\ faultCounters.statusPatchConflict \in Nat
    /\ faultCounters.basicAuthRequest \in Nat
    /\ faultCounters.bootstrapCreateFailure \in Nat
    /\ faultCounters.externalZKChange \in Nat
    /\ faultCounters.manualBootstrapRepair \in Nat

ClusterOpOwnershipConsistency ==
    \A op \in ClusterOps :
        op \in clusterOpLock => opStatus[op] \in {"nonterminal", "terminal"}

BackupCohortWithinUniverse ==
    /\ backupCohort \subseteq Collections
    /\ initialBackupCohort \subseteq Collections

=============================================================================
