----------------------------- MODULE base -----------------------------
(***************************************************************************
 * Apache Solr Operator broad interaction semantics.
 *
 * Category A: Kubernetes resources, controller reconciles, Solr async
 * requests, ZooKeeper state, and CR status are independently durable steps.
 * Source revision: ed5c5c7d28a4c1189d19f581259e05385c0d4b20
 *
 * Scenario extensions:
 *   S1 typed replicas and managed-update selection
 *   S2 durable cluster-operation obligations
 *   S3 backup cohort and async evidence durability
 *   S4 BasicAuth bootstrap pipeline
 *************************************************************************)

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    UpdatePod, PullPod,
    NRTReplica, PullReplica,
    TargetShard,
    CollectionA, CollectionB,
    MaxShardReplicasUnavailable

ASSUME MaxShardReplicasUnavailable \in Nat

Pods        == {UpdatePod, PullPod}
Replicas    == {NRTReplica, PullReplica}
Shards      == {TargetShard}
Collections == {CollectionA, CollectionB}
ClusterOps  == {"rolling", "balance"}

ReplicaTypes  == {"NRT", "TLOG", "PULL"}
ReplicaStates == {"active", "down", "recovering", "recovery_failed"}
PodRevisions  == {"old", "new"}
OpStatuses    == {"idle", "nonterminal", "terminal"}
AsyncStates   == {"none", "running", "completed", "failed"}
BackupStates  == {"absent", "submitted", "completed", "failed"}
AuthPhases    == {"idle", "lookup", "createAuth", "createBootstrap",
                   "error", "generateTemplate", "applyTemplate"}
SecurityVersions == {"none", "v1", "external"}
NoReplica == "NO_REPLICA"

EligibleReplicaType(t) == t \in {"NRT", "TLOG"}
TerminalBackupState(s) == s \in {"completed", "failed"}

(***************************************************************************
 * Variables
 *************************************************************************)

VARIABLES
    \* S1: cluster state and managed update
    replicaType, replicaState, replicaNode, leader,
    podRevision, podReady, podExists, scheduledForDeletion,
    clusterSnapshot, snapshotValid, selectedForUpdate, selectionPending,

    \* S2: StatefulSet cluster-operation annotation and future work
    clusterOpLock, opQueue, opStatus, opError, asyncState,
    retryDue, eventDue, dispatchReady, handlerReturned,
    handlerRequestInProgress, balanceReadyToSubmit, opAge,

    \* S3: backup target set, Solr evidence, and CR status
    availableCollections, backupActive, backupCohort, initialBackupCohort,
    workingCRStatus, durableCRStatus, taskState, taskRecord,
    taskEverSubmitted, cleanupPending, backupFinished,
    nextScheduled, backupListNeeded, statusPatchPending,

    \* S4: credential/bootstrap Secrets, generated pod, ZK, and status
    basicAuthRequested, authPhase, authSecret, bootstrapSecret,
    credentialVersion, bootstrapVersion, securityJsonLoaded,
    podTemplateHasBootstrap, podTemplateApplied, podCredentialVersion,
    zkSecurityVersion, authPodReady, cloudReady

s1Vars == <<replicaType, replicaState, replicaNode, leader,
            podRevision, podReady, podExists, scheduledForDeletion,
            clusterSnapshot, snapshotValid, selectedForUpdate,
            selectionPending>>

s2Vars == <<clusterOpLock, opQueue, opStatus, opError, asyncState,
            retryDue, eventDue, dispatchReady, handlerReturned,
            handlerRequestInProgress, balanceReadyToSubmit, opAge>>

s3Vars == <<availableCollections, backupActive, backupCohort,
            initialBackupCohort, workingCRStatus, durableCRStatus,
            taskState, taskRecord, taskEverSubmitted, cleanupPending,
            backupFinished, nextScheduled, backupListNeeded,
            statusPatchPending>>

s4Vars == <<basicAuthRequested, authPhase, authSecret, bootstrapSecret,
            credentialVersion, bootstrapVersion, securityJsonLoaded,
            podTemplateHasBootstrap, podTemplateApplied,
            podCredentialVersion, zkSecurityVersion, authPodReady,
            cloudReady>>

vars == <<s1Vars, s2Vars, s3Vars, s4Vars>>

(***************************************************************************
 * Initial state
 *************************************************************************)

Init ==
    /\ replicaType = [r \in Replicas |->
          IF r = NRTReplica THEN "NRT" ELSE "PULL"]
    /\ replicaState = [r \in Replicas |-> "active"]
    /\ replicaNode = [r \in Replicas |->
          IF r = NRTReplica THEN UpdatePod ELSE PullPod]
    /\ leader = [s \in Shards |-> NRTReplica]
    /\ podRevision = [p \in Pods |->
          IF p = UpdatePod THEN "old" ELSE "new"]
    /\ podReady = [p \in Pods |-> TRUE]
    /\ podExists = [p \in Pods |-> TRUE]
    /\ scheduledForDeletion = {}
    /\ clusterSnapshot = [
         replicaState |-> [r \in Replicas |-> "active"],
         replicaNode  |-> [r \in Replicas |->
                             IF r = NRTReplica THEN UpdatePod ELSE PullPod],
         podReady     |-> [p \in Pods |-> TRUE],
         podExists    |-> [p \in Pods |-> TRUE]]
    /\ snapshotValid = FALSE
    /\ selectedForUpdate = {}
    /\ selectionPending = FALSE

    /\ clusterOpLock = {}
    /\ opQueue = {}
    /\ opStatus = [op \in ClusterOps |-> "idle"]
    /\ opError = [op \in ClusterOps |-> FALSE]
    /\ asyncState = [op \in ClusterOps |-> "none"]
    /\ retryDue = {}
    /\ eventDue = {}
    /\ dispatchReady = {}
    /\ handlerReturned = {}
    /\ handlerRequestInProgress = {}
    /\ balanceReadyToSubmit = {}
    /\ opAge = [op \in ClusterOps |-> 0]

    /\ availableCollections = Collections
    /\ backupActive = FALSE
    /\ backupCohort = {}
    /\ initialBackupCohort = {}
    /\ workingCRStatus = [c \in Collections |-> "absent"]
    /\ durableCRStatus = [c \in Collections |-> "absent"]
    /\ taskState = [c \in Collections |-> "none"]
    /\ taskRecord = [c \in Collections |-> FALSE]
    /\ taskEverSubmitted = [c \in Collections |-> FALSE]
    /\ cleanupPending = {}
    /\ backupFinished = FALSE
    /\ nextScheduled = FALSE
    /\ backupListNeeded = FALSE
    /\ statusPatchPending = FALSE

    /\ basicAuthRequested = FALSE
    /\ authPhase = "idle"
    /\ authSecret = FALSE
    /\ bootstrapSecret = FALSE
    /\ credentialVersion = "none"
    /\ bootstrapVersion = "none"
    /\ securityJsonLoaded = FALSE
    /\ podTemplateHasBootstrap = FALSE
    /\ podTemplateApplied = FALSE
    /\ podCredentialVersion = "none"
    /\ zkSecurityVersion = "none"
    /\ authPodReady = FALSE
    /\ cloudReady = FALSE

(***************************************************************************
 * Scenario 1: managed update and typed replicas
 *************************************************************************)

ActiveEligibleReplicas(s) ==
    {r \in Replicas :
        /\ EligibleReplicaType(replicaType[r])
        /\ replicaState[r] = "active"
        /\ podExists[replicaNode[r]]
        /\ podReady[replicaNode[r]]}

InitiallyWritable(s) ==
    \E r \in Replicas :
        /\ r = NRTReplica
        /\ EligibleReplicaType(replicaType[r])

SnapshotNotActiveCount(s) ==
    Cardinality({r \in Replicas :
        /\ r \in {NRTReplica, PullReplica}
        /\ \/ clusterSnapshot.replicaState[r] /= "active"
           \/ ~clusterSnapshot.podExists[clusterSnapshot.replicaNode[r]]
           \/ ~clusterSnapshot.podReady[clusterSnapshot.replicaNode[r]]})

SnapshotActiveOnPodCount(s, p) ==
    Cardinality({r \in Replicas :
        /\ r \in {NRTReplica, PullReplica}
        /\ clusterSnapshot.replicaNode[r] = p
        /\ clusterSnapshot.replicaState[r] = "active"})

\* A supported CR change starts a managed rolling update.
\* controllers/solr_cluster_ops_util.go:429-445
StartManagedUpdate ==
    /\ ~selectionPending
    /\ podRevision[UpdatePod] = "old"
    /\ selectionPending' = TRUE
    /\ snapshotValid' = FALSE
    /\ selectedForUpdate' = {}
    /\ UNCHANGED <<replicaType, replicaState, replicaNode, leader,
                    podRevision, podReady, podExists,
                    scheduledForDeletion, clusterSnapshot, s2Vars,
                    s3Vars, s4Vars>>

\* Fetch CLUSTERSTATUS and OVERSEERSTATUS, then aggregate the snapshot.
\* controllers/util/solr_update_util.go:124-151
GetNodeReplicaState ==
    /\ selectionPending
    /\ ~snapshotValid
    \* Successful API calls lead to findSolrNodeContents.
    \* controllers/util/solr_update_util.go:128-146
    /\ clusterSnapshot' = [replicaState |-> replicaState,
                            replicaNode  |-> replicaNode,
                            podReady     |-> podReady,
                            podExists    |-> podExists]
    \* Aggregation records active/down counts but drops parsed replica type.
    \* controllers/util/solr_update_util.go:426-466
    /\ snapshotValid' = TRUE
    /\ UNCHANGED <<replicaType, replicaState, replicaNode, leader,
                    podRevision, podReady, podExists,
                    scheduledForDeletion, selectedForUpdate,
                    selectionPending, s2Vars, s3Vars, s4Vars>>

\* Apply pickPodsToUpdate's actual count-only safety test to one candidate.
\* controllers/util/solr_update_util.go:209-311
DeterminePodsSafeToUpdate(p) ==
    /\ p = UpdatePod
    /\ selectionPending
    /\ snapshotValid
    /\ p \notin selectedForUpdate
    /\ podRevision[p] = "old"
    \* Lines 263-281 reject only when an existing unavailable count is
    \* positive and adding active replicas exceeds the configured maximum.
    /\ LET notActive == SnapshotNotActiveCount(TargetShard)
           additional == SnapshotActiveOnPodCount(TargetShard, p)
           safe == ~(notActive > 0 /\
                     notActive + additional > MaxShardReplicasUnavailable)
       IN selectedForUpdate' = IF safe
                               THEN selectedForUpdate \cup {p}
                               ELSE selectedForUpdate
    \* This bounded model has one out-of-date candidate, ending the loop.
    \* controllers/util/solr_update_util.go:291-305
    /\ selectionPending' = FALSE
    /\ UNCHANGED <<replicaType, replicaState, replicaNode, leader,
                    podRevision, podReady, podExists,
                    scheduledForDeletion, clusterSnapshot, snapshotValid,
                    s2Vars, s3Vars, s4Vars>>

\* Remove the pod from service before eviction/deletion.
\* controllers/solr_pod_lifecycle_util.go:50-73
EnsurePodReadinessConditions(p) ==
    /\ p \in selectedForUpdate
    /\ podExists[p]
    /\ p \notin scheduledForDeletion
    \* Both custom readiness conditions become false.
    \* controllers/solr_pod_lifecycle_util.go:51-67,130-159
    /\ podReady' = [podReady EXCEPT ![p] = FALSE]
    /\ scheduledForDeletion' = scheduledForDeletion \cup {p}
    /\ UNCHANGED <<replicaType, replicaState, replicaNode, leader,
                    podRevision, podExists, clusterSnapshot, snapshotValid,
                    selectedForUpdate, selectionPending,
                    s2Vars, s3Vars, s4Vars>>

\* Delete after readiness removal; this is a separate Kubernetes API step.
\* controllers/solr_pod_lifecycle_util.go:75-127
DeletePodForUpdate(p) ==
    /\ p \in scheduledForDeletion
    /\ podExists[p]
    \* The delete call removes the pod; replicas on that node become down.
    \* controllers/solr_pod_lifecycle_util.go:103-124
    /\ podExists' = [podExists EXCEPT ![p] = FALSE]
    /\ replicaState' = [r \in Replicas |->
          IF replicaNode[r] = p THEN "down" ELSE replicaState[r]]
    \* Solr cannot retain a leader on the deleted node.
    \* controllers/util/solr_update_util.go:451-463
    /\ leader' = [s \in Shards |->
          IF leader[s] \in Replicas /\ replicaNode[leader[s]] = p
          THEN NoReplica ELSE leader[s]]
    /\ UNCHANGED <<replicaType, replicaNode, podRevision, podReady,
                    scheduledForDeletion, clusterSnapshot, snapshotValid,
                    selectedForUpdate, selectionPending,
                    s2Vars, s3Vars, s4Vars>>

\* StatefulSet recreates the selected pod at the new revision.
\* controllers/solr_cluster_ops_util.go:472-475
StatefulSetRecreatePod(p) ==
    /\ p \in selectedForUpdate
    /\ ~podExists[p]
    /\ podExists' = [podExists EXCEPT ![p] = TRUE]
    /\ podRevision' = [podRevision EXCEPT ![p] = "new"]
    /\ podReady' = [podReady EXCEPT ![p] = FALSE]
    /\ scheduledForDeletion' = scheduledForDeletion \ {p}
    /\ replicaState' = [r \in Replicas |->
          IF replicaNode[r] = p THEN "recovering" ELSE replicaState[r]]
    /\ UNCHANGED <<replicaType, replicaNode, leader,
                    clusterSnapshot, snapshotValid, selectedForUpdate,
                    selectionPending, s2Vars, s3Vars, s4Vars>>

\* Solr recovery is asynchronous relative to Kubernetes recreation.
\* controllers/util/solr_update_util.go:451-463
SolrRecoverReplica(r) ==
    /\ r \in Replicas
    /\ podExists[replicaNode[r]]
    /\ replicaState[r] \in {"down", "recovering"}
    /\ replicaState' = [replicaState EXCEPT ![r] = "active"]
    /\ podReady' = [podReady EXCEPT ![replicaNode[r]] = TRUE]
    /\ UNCHANGED <<replicaType, replicaNode, leader, podRevision,
                    podExists, scheduledForDeletion, clusterSnapshot,
                    snapshotValid, selectedForUpdate, selectionPending,
                    s2Vars, s3Vars, s4Vars>>

\* Solr may elect only NRT/TLOG active replicas as shard leader.
\* Parsed type: controllers/util/solr_api/cluster_status.go:119-149
SolrElectLeader(s, r) ==
    /\ s \in Shards
    /\ r \in Replicas
    /\ EligibleReplicaType(replicaType[r])
    /\ replicaState[r] = "active"
    /\ podExists[replicaNode[r]]
    /\ leader' = [leader EXCEPT ![s] = r]
    /\ UNCHANGED <<replicaType, replicaState, replicaNode, podRevision,
                    podReady, podExists, scheduledForDeletion,
                    clusterSnapshot, snapshotValid, selectedForUpdate,
                    selectionPending, s2Vars, s3Vars, s4Vars>>

(***************************************************************************
 * Scenario 2: cluster-operation durability
 *************************************************************************)

\* StatefulSet annotation acquires one cluster-operation lock and its patch
\* causes a watched reconciliation event.
\* controllers/solr_cluster_ops_util.go:71-78
\* controllers/solrcloud_controller.go:618-637
StartClusterOp(op) ==
    /\ op \in ClusterOps
    /\ clusterOpLock = {}
    /\ opStatus[op] = "idle"
    /\ clusterOpLock' = {op}
    /\ opStatus' = [opStatus EXCEPT ![op] = "nonterminal"]
    /\ eventDue' = eventDue \cup {op}
    /\ opAge' = [opAge EXCEPT ![op] = 0]
    /\ UNCHANGED <<opQueue, opError, asyncState, retryDue,
                    dispatchReady, handlerReturned,
                    handlerRequestInProgress, balanceReadyToSubmit,
                    s1Vars, s3Vars, s4Vars>>

StartRollingClusterOp == StartClusterOp("rolling")
StartBalanceClusterOp == StartClusterOp("balance")

\* A watched StatefulSet/timer event makes the operation dispatchable.
\* controllers/solrcloud_controller.go:490-515,637
ControllerRuntimeDeliverClusterOpEvent(op) ==
    /\ op \in eventDue
    /\ op \in clusterOpLock
    /\ eventDue' = eventDue \ {op}
    /\ dispatchReady' = dispatchReady \cup {op}
    /\ UNCHANGED <<clusterOpLock, opQueue, opStatus, opError,
                    asyncState, retryDue, handlerReturned,
                    handlerRequestInProgress, balanceReadyToSubmit, opAge,
                    s1Vars, s3Vars, s4Vars>>

\* CLUSTERSTATUS/OVERSEERSTATUS failure returns requestInProgress=true,
\* retryLaterDuration=0, and the API error.
\* controllers/solr_cluster_ops_util.go:483-506
HandleManagedCloudRollingUpdateClusterStateFailure ==
    /\ "rolling" \in dispatchReady
    /\ opStatus["rolling"] = "nonterminal"
    /\ dispatchReady' = dispatchReady \ {"rolling"}
    /\ handlerReturned' = handlerReturned \cup {"rolling"}
    /\ handlerRequestInProgress' =
          handlerRequestInProgress \cup {"rolling"}
    /\ opError' = [opError EXCEPT !["rolling"] = TRUE]
    /\ UNCHANGED <<clusterOpLock, opQueue, opStatus, asyncState,
                    retryDue, eventDue, balanceReadyToSubmit, opAge,
                    s1Vars, s3Vars, s4Vars>>

\* A successful rolling-update handler can complete normally.
\* controllers/solr_cluster_ops_util.go:453-471
HandleManagedCloudRollingUpdateComplete ==
    /\ "rolling" \in dispatchReady
    /\ opStatus["rolling"] = "nonterminal"
    /\ dispatchReady' = dispatchReady \ {"rolling"}
    /\ handlerReturned' = handlerReturned \cup {"rolling"}
    /\ opStatus' = [opStatus EXCEPT !["rolling"] = "terminal"]
    /\ opError' = [opError EXCEPT !["rolling"] = FALSE]
    /\ UNCHANGED <<clusterOpLock, opQueue, asyncState, retryDue,
                    eventDue, handlerRequestInProgress,
                    balanceReadyToSubmit, opAge,
                    s1Vars, s3Vars, s4Vars>>

\* REQUESTSTATUS error returns an error but no in-progress flag or retry.
\* controllers/util/solr_scale_util.go:43-47,100-103
BalanceReplicasForClusterCheckFailure ==
    /\ "balance" \in dispatchReady
    /\ opStatus["balance"] = "nonterminal"
    /\ dispatchReady' = dispatchReady \ {"balance"}
    /\ handlerReturned' = handlerReturned \cup {"balance"}
    /\ handlerRequestInProgress' =
          handlerRequestInProgress \ {"balance"}
    /\ opError' = [opError EXCEPT !["balance"] = TRUE]
    /\ UNCHANGED <<clusterOpLock, opQueue, opStatus, asyncState,
                    retryDue, eventDue, balanceReadyToSubmit, opAge,
                    s1Vars, s3Vars, s4Vars>>

\* REQUESTSTATUS=notfound proceeds to a separate submission call.
\* controllers/util/solr_scale_util.go:47-58
BalanceReplicasForClusterNotFound ==
    /\ "balance" \in dispatchReady
    /\ opStatus["balance"] = "nonterminal"
    /\ dispatchReady' = dispatchReady \ {"balance"}
    /\ balanceReadyToSubmit' = balanceReadyToSubmit \cup {"balance"}
    /\ UNCHANGED <<clusterOpLock, opQueue, opStatus, opError,
                    asyncState, retryDue, eventDue, handlerReturned,
                    handlerRequestInProgress, opAge,
                    s1Vars, s3Vars, s4Vars>>

\* A submission error also returns no in-progress flag and no retry duration.
\* controllers/util/solr_scale_util.go:52-75,100-103
BalanceReplicasForClusterSubmitFailure ==
    /\ "balance" \in balanceReadyToSubmit
    /\ balanceReadyToSubmit' = balanceReadyToSubmit \ {"balance"}
    /\ handlerReturned' = handlerReturned \cup {"balance"}
    /\ handlerRequestInProgress' =
          handlerRequestInProgress \ {"balance"}
    /\ opError' = [opError EXCEPT !["balance"] = TRUE]
    /\ UNCHANGED <<clusterOpLock, opQueue, opStatus, asyncState,
                    retryDue, eventDue, dispatchReady, opAge,
                    s1Vars, s3Vars, s4Vars>>

\* Successful submission creates real async work and a five-second poll.
\* controllers/util/solr_scale_util.go:52-72,100-102
BalanceReplicasForClusterSubmitSuccess ==
    /\ "balance" \in balanceReadyToSubmit
    /\ balanceReadyToSubmit' = balanceReadyToSubmit \ {"balance"}
    /\ asyncState' = [asyncState EXCEPT !["balance"] = "running"]
    /\ retryDue' = retryDue \cup {"balance"}
    /\ handlerReturned' = handlerReturned \cup {"balance"}
    /\ handlerRequestInProgress' =
          handlerRequestInProgress \cup {"balance"}
    /\ opError' = [opError EXCEPT !["balance"] = FALSE]
    /\ UNCHANGED <<clusterOpLock, opQueue, opStatus, eventDue,
                    dispatchReady, opAge, s1Vars, s3Vars, s4Vars>>

\* The Solr overseer completes independently of controller reconciliation.
\* controllers/util/solr_scale_util.go:77-87
SolrBalanceReplicasTaskCompletes ==
    /\ asyncState["balance"] = "running"
    /\ asyncState' = [asyncState EXCEPT !["balance"] = "completed"]
    /\ UNCHANGED <<clusterOpLock, opQueue, opStatus, opError,
                    retryDue, eventDue, dispatchReady, handlerReturned,
                    handlerRequestInProgress, balanceReadyToSubmit, opAge,
                    s1Vars, s3Vars, s4Vars>>

\* A scheduled retry becomes a controller event.
\* controllers/solrcloud_controller.go:644-649
ControllerTimerFires(op) ==
    /\ op \in retryDue
    /\ retryDue' = retryDue \ {op}
    /\ eventDue' = eventDue \cup {op}
    /\ UNCHANGED <<clusterOpLock, opQueue, opStatus, opError,
                    asyncState, dispatchReady, handlerReturned,
                    handlerRequestInProgress, balanceReadyToSubmit, opAge,
                    s1Vars, s3Vars, s4Vars>>

\* Poll observes completed async work and reports operationComplete=true.
\* controllers/util/solr_scale_util.go:77-97
BalanceReplicasForClusterCompleted ==
    /\ "balance" \in dispatchReady
    /\ asyncState["balance"] = "completed"
    /\ dispatchReady' = dispatchReady \ {"balance"}
    /\ handlerReturned' = handlerReturned \cup {"balance"}
    /\ handlerRequestInProgress' =
          handlerRequestInProgress \ {"balance"}
    /\ opStatus' = [opStatus EXCEPT !["balance"] = "terminal"]
    /\ asyncState' = [asyncState EXCEPT !["balance"] = "none"]
    /\ opError' = [opError EXCEPT !["balance"] = FALSE]
    /\ UNCHANGED <<clusterOpLock, opQueue, retryDue, eventDue,
                    balanceReadyToSubmit, opAge,
                    s1Vars, s3Vars, s4Vars>>

\* Dispatcher consumes the handler tuple. It first clears err unconditionally,
\* then only queues a non-in-progress operation after a timeout.
\* controllers/solrcloud_controller.go:523-570
SolrCloudReconcileClusterOpDispatcher(op) ==
    /\ op \in handlerReturned
    /\ op \in clusterOpLock
    \* Line 524 erases the handler error before lines 538-569 test it.
    /\ opError' = [opError EXCEPT ![op] = FALSE]
    /\ handlerReturned' = handlerReturned \ {op}
    /\ handlerRequestInProgress' = handlerRequestInProgress \ {op}
    /\ IF opStatus[op] = "terminal"
          \* Completion clears the StatefulSet annotation.
          \* controllers/solrcloud_controller.go:525-537
          THEN /\ clusterOpLock' = clusterOpLock \ {op}
               /\ opQueue' = opQueue
               /\ eventDue' = eventDue
          \* The short-timeout queue is unreachable at age zero; an erased
          \* error therefore leaves neither a queue entry nor a new event.
          \* controllers/solrcloud_controller.go:538-569
          ELSE IF opAge[op] > 1 /\ op \notin handlerRequestInProgress
               THEN /\ clusterOpLock' = clusterOpLock \ {op}
                    /\ opQueue' = opQueue \cup {op}
                    /\ eventDue' = eventDue \cup {op}
               ELSE /\ clusterOpLock' = clusterOpLock
                    /\ opQueue' = opQueue
                    /\ eventDue' = eventDue
    /\ UNCHANGED <<opStatus, asyncState, retryDue, dispatchReady,
                    balanceReadyToSubmit, opAge,
                    s1Vars, s3Vars, s4Vars>>

\* Retry queue patch restores the next operation as the current lock.
\* controllers/solr_cluster_ops_util.go:123-153,603-616
RetryNextQueuedClusterOp(op) ==
    /\ op \in opQueue
    /\ clusterOpLock = {}
    /\ opQueue' = opQueue \ {op}
    /\ clusterOpLock' = {op}
    /\ eventDue' = eventDue \cup {op}
    /\ UNCHANGED <<opStatus, opError, asyncState, retryDue,
                    dispatchReady, handlerReturned,
                    handlerRequestInProgress, balanceReadyToSubmit, opAge,
                    s1Vars, s3Vars, s4Vars>>

(***************************************************************************
 * Scenario 3: backup cohort and async evidence
 *************************************************************************)

AllWorkingTerminal ==
    /\ \E c \in Collections : workingCRStatus[c] /= "absent"
    /\ \A c \in Collections :
          workingCRStatus[c] = "absent" \/
          TerminalBackupState(workingCRStatus[c])

\* Starting a run records only time/version; omitted collections are listed.
\* controllers/solrbackup_controller.go:223-264
StartBackupRun ==
    /\ ~backupActive
    /\ backupActive' = TRUE
    /\ backupCohort' = availableCollections
    /\ initialBackupCohort' = availableCollections
    /\ workingCRStatus' = [c \in Collections |-> "absent"]
    /\ durableCRStatus' = [c \in Collections |-> "absent"]
    /\ taskState' = [c \in Collections |-> "none"]
    /\ taskRecord' = [c \in Collections |-> FALSE]
    /\ taskEverSubmitted' = [c \in Collections |-> FALSE]
    /\ cleanupPending' = {}
    /\ backupFinished' = FALSE
    /\ nextScheduled' = FALSE
    /\ backupListNeeded' = FALSE
    /\ statusPatchPending' = TRUE
    /\ UNCHANGED <<availableCollections, s1Vars, s2Vars, s4Vars>>

\* Kubernetes/Solr collection membership can change between polls.
\* controllers/solrbackup_controller.go:246-264
DeleteCollectionDuringBackup(c) ==
    /\ backupActive
    /\ c \in availableCollections
    /\ availableCollections' = availableCollections \ {c}
    /\ backupListNeeded' = TRUE
    /\ UNCHANGED <<backupActive, backupCohort, initialBackupCohort,
                    workingCRStatus, durableCRStatus, taskState, taskRecord,
                    taskEverSubmitted, cleanupPending, backupFinished,
                    nextScheduled, statusPatchPending,
                    s1Vars, s2Vars, s4Vars>>

AddCollectionDuringBackup(c) ==
    /\ backupActive
    /\ c \notin availableCollections
    /\ availableCollections' = availableCollections \cup {c}
    /\ backupListNeeded' = TRUE
    /\ UNCHANGED <<backupActive, backupCohort, initialBackupCohort,
                    workingCRStatus, durableCRStatus, taskState, taskRecord,
                    taskEverSubmitted, cleanupPending, backupFinished,
                    nextScheduled, statusPatchPending,
                    s1Vars, s2Vars, s4Vars>>

\* With spec.collections omitted, LIST is called on every reconcile rather
\* than reading a frozen target set from status.
\* controllers/solrbackup_controller.go:246-256
ListAllSolrCollections ==
    /\ backupActive
    /\ backupListNeeded
    /\ backupCohort' = availableCollections
    /\ backupListNeeded' = FALSE
    /\ UNCHANGED <<availableCollections, backupActive, initialBackupCohort,
                    workingCRStatus, durableCRStatus, taskState, taskRecord,
                    taskEverSubmitted, cleanupPending, backupFinished,
                    nextScheduled, statusPatchPending,
                    s1Vars, s2Vars, s4Vars>>

\* BACKUP submission updates the in-memory per-collection status.
\* controllers/solrbackup_controller.go:285-300
ReconcileSolrCollectionBackupSubmit(c) ==
    /\ backupActive
    /\ ~backupListNeeded
    /\ c \in backupCohort
    /\ workingCRStatus[c] = "absent"
    /\ workingCRStatus' = [workingCRStatus EXCEPT ![c] = "submitted"]
    /\ taskState' = [taskState EXCEPT ![c] = "running"]
    /\ taskRecord' = [taskRecord EXCEPT ![c] = TRUE]
    /\ taskEverSubmitted' = [taskEverSubmitted EXCEPT ![c] = TRUE]
    /\ statusPatchPending' = TRUE
    /\ UNCHANGED <<availableCollections, backupActive, backupCohort,
                    initialBackupCohort, durableCRStatus, cleanupPending,
                    backupFinished, nextScheduled, backupListNeeded,
                    s1Vars, s2Vars, s4Vars>>

\* Solr executes the asynchronous backup independently.
\* controllers/util/backup_util.go:112-131
SolrBackupTaskCompletes(c) ==
    /\ taskState[c] = "running"
    /\ taskRecord[c]
    /\ taskState' = [taskState EXCEPT ![c] = "completed"]
    /\ UNCHANGED <<availableCollections, backupActive, backupCohort,
                    initialBackupCohort, workingCRStatus, durableCRStatus,
                    taskRecord, taskEverSubmitted, cleanupPending,
                    backupFinished, nextScheduled, backupListNeeded,
                    statusPatchPending, s1Vars, s2Vars, s4Vars>>

\* REQUESTSTATUS=completed mutates the local CR object before cleanup.
\* controllers/solrbackup_controller.go:300-318
CheckAsyncRequestCompleted(c) ==
    /\ c \in backupCohort
    /\ workingCRStatus[c] = "submitted"
    /\ taskRecord[c]
    /\ taskState[c] = "completed"
    /\ workingCRStatus' = [workingCRStatus EXCEPT ![c] = "completed"]
    /\ cleanupPending' = cleanupPending \cup {c}
    /\ statusPatchPending' = TRUE
    /\ UNCHANGED <<availableCollections, backupActive, backupCohort,
                    initialBackupCohort, durableCRStatus, taskState,
                    taskRecord, taskEverSubmitted, backupFinished,
                    nextScheduled, backupListNeeded,
                    s1Vars, s2Vars, s4Vars>>

\* DELETESTATUS is invoked before the later CR status patch.
\* controllers/solrbackup_controller.go:303-320
\* controllers/util/backup_util.go:134-142
DeleteAsyncRequestForBackup(c) ==
    /\ c \in cleanupPending
    /\ taskRecord[c]
    /\ taskRecord' = [taskRecord EXCEPT ![c] = FALSE]
    /\ taskState' = [taskState EXCEPT ![c] = "none"]
    /\ cleanupPending' = cleanupPending \ {c}
    /\ UNCHANGED <<availableCollections, backupActive, backupCohort,
                    initialBackupCohort, workingCRStatus, durableCRStatus,
                    taskEverSubmitted, backupFinished, nextScheduled,
                    backupListNeeded, statusPatchPending,
                    s1Vars, s2Vars, s4Vars>>

\* Status is persisted only after reconcileSolrCloudBackup returns.
\* controllers/solrbackup_controller.go:178-181
PatchSolrBackupStatus ==
    /\ statusPatchPending
    /\ cleanupPending = {}
    /\ durableCRStatus' = workingCRStatus
    /\ statusPatchPending' = FALSE
    /\ UNCHANGED <<availableCollections, backupActive, backupCohort,
                    initialBackupCohort, workingCRStatus, taskState,
                    taskRecord, taskEverSubmitted, cleanupPending,
                    backupFinished, nextScheduled, backupListNeeded,
                    s1Vars, s2Vars, s4Vars>>

\* A status conflict/error discards the in-memory terminal evidence; the next
\* reconcile reloads durable status after DELETESTATUS already succeeded.
\* controllers/solrbackup_controller.go:178-183
PatchSolrBackupStatusConflict ==
    /\ statusPatchPending
    /\ cleanupPending = {}
    /\ \E c \in Collections :
          /\ taskEverSubmitted[c]
          /\ ~taskRecord[c]
          /\ ~TerminalBackupState(durableCRStatus[c])
    /\ workingCRStatus' = durableCRStatus
    /\ statusPatchPending' = FALSE
    /\ UNCHANGED <<availableCollections, backupActive, backupCohort,
                    initialBackupCohort, durableCRStatus, taskState,
                    taskRecord, taskEverSubmitted, cleanupPending,
                    backupFinished, nextScheduled, backupListNeeded,
                    s1Vars, s2Vars, s4Vars>>

\* REQUESTSTATUS=notfound is neither completed nor failed and leaves the
\* collection in progress.
\* controllers/util/backup_util.go:112-131
CheckAsyncRequestNotFound(c) ==
    /\ c \in backupCohort
    /\ workingCRStatus[c] = "submitted"
    /\ taskRecord[c]
    /\ taskState[c] = "running"
    /\ taskRecord' = [taskRecord EXCEPT ![c] = FALSE]
    /\ taskState' = [taskState EXCEPT ![c] = "none"]
    /\ UNCHANGED <<availableCollections, backupActive, backupCohort,
                    initialBackupCohort, workingCRStatus, durableCRStatus,
                    taskEverSubmitted, cleanupPending, backupFinished,
                    nextScheduled, backupListNeeded, statusPatchPending,
                    s1Vars, s2Vars, s4Vars>>

\* Aggregate every old status entry, including collections no longer listed.
\* controllers/util/backup_util.go:60-75
UpdateStatusOfCollectionBackups ==
    /\ backupActive
    /\ backupFinished' = AllWorkingTerminal
    /\ statusPatchPending' = (statusPatchPending \/ AllWorkingTerminal)
    /\ UNCHANGED <<availableCollections, backupActive, backupCohort,
                    initialBackupCohort, workingCRStatus, durableCRStatus,
                    taskState, taskRecord, taskEverSubmitted,
                    cleanupPending, nextScheduled, backupListNeeded,
                    s1Vars, s2Vars, s4Vars>>

\* A recurring backup is scheduled only after aggregate completion.
\* controllers/solrbackup_controller.go:159-175
ScheduleNextBackup ==
    /\ backupActive
    /\ backupFinished
    /\ nextScheduled' = TRUE
    /\ backupActive' = FALSE
    /\ UNCHANGED <<availableCollections, backupCohort,
                    initialBackupCohort, workingCRStatus, durableCRStatus,
                    taskState, taskRecord, taskEverSubmitted,
                    cleanupPending, backupFinished, backupListNeeded,
                    statusPatchPending, s1Vars, s2Vars, s4Vars>>

(***************************************************************************
 * Scenario 4: BasicAuth bootstrap pipeline
 *************************************************************************)

\* A CR requests generated BasicAuth credentials and security.json.
\* api/v1beta1/solrcloud_types.go:1625-1655
RequestBasicAuth ==
    /\ ~basicAuthRequested
    /\ basicAuthRequested' = TRUE
    /\ authPhase' = "lookup"
    /\ UNCHANGED <<authSecret, bootstrapSecret, credentialVersion,
                    bootstrapVersion, securityJsonLoaded,
                    podTemplateHasBootstrap, podTemplateApplied,
                    podCredentialVersion, zkSecurityVersion,
                    authPodReady, cloudReady, s1Vars, s2Vars, s3Vars>>

\* Missing credentials enter the two-Secret creation branch.
\* controllers/util/solr_security_util.go:95-100
ReconcileForBasicAuthLookupMissingSecret ==
    /\ basicAuthRequested
    /\ authPhase = "lookup"
    /\ ~authSecret
    /\ authPhase' = "createAuth"
    /\ UNCHANGED <<authSecret, bootstrapSecret, credentialVersion,
                    bootstrapVersion, securityJsonLoaded,
                    podTemplateHasBootstrap, podTemplateApplied,
                    podCredentialVersion, zkSecurityVersion,
                    authPodReady, cloudReady, basicAuthRequested,
                    s1Vars, s2Vars, s3Vars>>

\* The credentials Secret is created in its own Kubernetes API call.
\* controllers/util/solr_security_util.go:100-112
CreateBasicAuthSecret ==
    /\ authPhase = "createAuth"
    /\ ~authSecret
    /\ authSecret' = TRUE
    /\ credentialVersion' = "v1"
    /\ authPhase' = "createBootstrap"
    /\ UNCHANGED <<bootstrapSecret, bootstrapVersion,
                    securityJsonLoaded, podTemplateHasBootstrap,
                    podTemplateApplied, podCredentialVersion,
                    zkSecurityVersion, authPodReady, cloudReady,
                    basicAuthRequested, s1Vars, s2Vars, s3Vars>>

\* The bootstrap Secret is a second, non-atomic create.
\* controllers/util/solr_security_util.go:113-124
CreateBootstrapSecret ==
    /\ authPhase = "createBootstrap"
    /\ ~bootstrapSecret
    /\ bootstrapSecret' = TRUE
    /\ bootstrapVersion' = credentialVersion
    /\ securityJsonLoaded' = TRUE
    /\ authPhase' = "generateTemplate"
    /\ UNCHANGED <<authSecret, credentialVersion,
                    podTemplateHasBootstrap, podTemplateApplied,
                    podCredentialVersion, zkSecurityVersion,
                    authPodReady, cloudReady, basicAuthRequested,
                    s1Vars, s2Vars, s3Vars>>

\* Transient failure occurs after the first Secret is already durable.
\* controllers/util/solr_security_util.go:109-116
FailBootstrapSecretCreate ==
    /\ authPhase = "createBootstrap"
    /\ authSecret
    /\ ~bootstrapSecret
    /\ authPhase' = "error"
    /\ UNCHANGED <<authSecret, bootstrapSecret, credentialVersion,
                    bootstrapVersion, securityJsonLoaded,
                    podTemplateHasBootstrap, podTemplateApplied,
                    podCredentialVersion, zkSecurityVersion,
                    authPodReady, cloudReady, basicAuthRequested,
                    s1Vars, s2Vars, s3Vars>>

\* controller-runtime retries a reconcile that returned an error.
\* controllers/solrcloud_controller.go:302-315
ControllerRuntimeRetryBasicAuth ==
    /\ authPhase = "error"
    /\ authPhase' = "lookup"
    /\ UNCHANGED <<authSecret, bootstrapSecret, credentialVersion,
                    bootstrapVersion, securityJsonLoaded,
                    podTemplateHasBootstrap, podTemplateApplied,
                    podCredentialVersion, zkSecurityVersion,
                    authPodReady, cloudReady, basicAuthRequested,
                    s1Vars, s2Vars, s3Vars>>

\* Existing credentials plus missing bootstrap Secret is explicitly tolerated;
\* SecurityJson remains empty and reconciliation continues.
\* controllers/util/solr_security_util.go:126-148
ReconcileForBasicAuthLookupExistingSecret ==
    /\ basicAuthRequested
    /\ authPhase = "lookup"
    /\ authSecret
    /\ securityJsonLoaded' = bootstrapSecret
    /\ bootstrapVersion' = IF bootstrapSecret
                              THEN credentialVersion ELSE "none"
    /\ authPhase' = "generateTemplate"
    /\ UNCHANGED <<authSecret, bootstrapSecret, credentialVersion,
                    podTemplateHasBootstrap, podTemplateApplied,
                    podCredentialVersion, zkSecurityVersion,
                    authPodReady, cloudReady, basicAuthRequested,
                    s1Vars, s2Vars, s3Vars>>

\* The setup-zk init container includes security installation only if a
\* non-empty SecurityJson was loaded.
\* controllers/util/solr_util.go:1270-1307
GenerateZKInteractionInitContainer ==
    /\ authPhase = "generateTemplate"
    /\ podTemplateHasBootstrap' = securityJsonLoaded
    /\ podCredentialVersion' = credentialVersion
    /\ podTemplateApplied' = FALSE
    /\ authPodReady' = FALSE
    /\ cloudReady' = FALSE
    /\ authPhase' = "applyTemplate"
    /\ UNCHANGED <<authSecret, bootstrapSecret, credentialVersion,
                    bootstrapVersion, securityJsonLoaded,
                    zkSecurityVersion, basicAuthRequested,
                    s1Vars, s2Vars, s3Vars>>

\* StatefulSet generation/application is a separate Kubernetes patch.
\* controllers/solrcloud_controller.go:318-340
ApplySecurityStatefulSet ==
    /\ authPhase = "applyTemplate"
    /\ podTemplateApplied' = TRUE
    /\ authPhase' = "idle"
    /\ UNCHANGED <<authSecret, bootstrapSecret, credentialVersion,
                    bootstrapVersion, securityJsonLoaded,
                    podTemplateHasBootstrap, podCredentialVersion,
                    zkSecurityVersion, authPodReady, cloudReady,
                    basicAuthRequested, s1Vars, s2Vars, s3Vars>>

\* setup-zk writes generated JSON only when the generated command is present.
\* controllers/util/solr_security_util.go:242-256
\* controllers/util/solr_util.go:1304-1339
RunSetupZKSecurityJson ==
    /\ podTemplateApplied
    /\ podTemplateHasBootstrap
    /\ zkSecurityVersion = "none"
    /\ zkSecurityVersion' = podCredentialVersion
    /\ UNCHANGED <<authSecret, bootstrapSecret, credentialVersion,
                    bootstrapVersion, securityJsonLoaded,
                    podTemplateHasBootstrap, podTemplateApplied,
                    podCredentialVersion, authPodReady, cloudReady,
                    basicAuthRequested, authPhase,
                    s1Vars, s2Vars, s3Vars>>

\* Pods without a bootstrap command can become Kubernetes Ready; pods with
\* one wait for its init-container effect.
\* controllers/util/solr_util.go:1304-1339
KubernetesAuthPodBecomesReady ==
    /\ podTemplateApplied
    /\ ~authPodReady
    /\ (~podTemplateHasBootstrap \/
        zkSecurityVersion = podCredentialVersion)
    /\ authPodReady' = TRUE
    /\ UNCHANGED <<authSecret, bootstrapSecret, credentialVersion,
                    bootstrapVersion, securityJsonLoaded,
                    podTemplateHasBootstrap, podTemplateApplied,
                    podCredentialVersion, zkSecurityVersion, cloudReady,
                    basicAuthRequested, authPhase,
                    s1Vars, s2Vars, s3Vars>>

\* SolrCloud readiness is derived from Pod/StatefulSet counts, not auth/ZK.
\* controllers/solrcloud_controller.go:842-968
CreateCloudStatus ==
    /\ basicAuthRequested
    /\ cloudReady' = authPodReady
    /\ UNCHANGED <<authSecret, bootstrapSecret, credentialVersion,
                    bootstrapVersion, securityJsonLoaded,
                    podTemplateHasBootstrap, podTemplateApplied,
                    podCredentialVersion, zkSecurityVersion,
                    authPodReady, basicAuthRequested, authPhase,
                    s1Vars, s2Vars, s3Vars>>

\* ZooKeeper security can be changed independently after bootstrap.
\* api/v1beta1/solrcloud_types.go:1636-1641
ExternalModifyZKSecurity ==
    /\ zkSecurityVersion /= "external"
    /\ zkSecurityVersion' = "external"
    /\ UNCHANGED <<authSecret, bootstrapSecret, credentialVersion,
                    bootstrapVersion, securityJsonLoaded,
                    podTemplateHasBootstrap, podTemplateApplied,
                    podCredentialVersion, authPodReady, cloudReady,
                    basicAuthRequested, authPhase,
                    s1Vars, s2Vars, s3Vars>>

\* Manual repair may create the expected missing Secret; the next reconcile
\* can then stage it into a new pod template.
\* controllers/util/solr_security_util.go:131-145
ManualCreateBootstrapSecret ==
    /\ basicAuthRequested
    /\ authSecret
    /\ ~bootstrapSecret
    /\ bootstrapSecret' = TRUE
    /\ bootstrapVersion' = credentialVersion
    /\ authPhase' = "lookup"
    /\ UNCHANGED <<authSecret, credentialVersion, securityJsonLoaded,
                    podTemplateHasBootstrap, podTemplateApplied,
                    podCredentialVersion, zkSecurityVersion,
                    authPodReady, cloudReady, basicAuthRequested,
                    s1Vars, s2Vars, s3Vars>>

(***************************************************************************
 * Next-state relation
 *************************************************************************)

Next ==
    \/ StartManagedUpdate
    \/ GetNodeReplicaState
    \/ \E p \in Pods : DeterminePodsSafeToUpdate(p)
    \/ \E p \in Pods : EnsurePodReadinessConditions(p)
    \/ \E p \in Pods : DeletePodForUpdate(p)
    \/ \E p \in Pods : StatefulSetRecreatePod(p)
    \/ \E r \in Replicas : SolrRecoverReplica(r)
    \/ \E s \in Shards, r \in Replicas : SolrElectLeader(s, r)

    \/ StartRollingClusterOp
    \/ StartBalanceClusterOp
    \/ \E op \in ClusterOps : ControllerRuntimeDeliverClusterOpEvent(op)
    \/ HandleManagedCloudRollingUpdateClusterStateFailure
    \/ HandleManagedCloudRollingUpdateComplete
    \/ BalanceReplicasForClusterCheckFailure
    \/ BalanceReplicasForClusterNotFound
    \/ BalanceReplicasForClusterSubmitFailure
    \/ BalanceReplicasForClusterSubmitSuccess
    \/ SolrBalanceReplicasTaskCompletes
    \/ \E op \in ClusterOps : ControllerTimerFires(op)
    \/ BalanceReplicasForClusterCompleted
    \/ \E op \in ClusterOps : SolrCloudReconcileClusterOpDispatcher(op)
    \/ \E op \in ClusterOps : RetryNextQueuedClusterOp(op)

    \/ StartBackupRun
    \/ \E c \in Collections : DeleteCollectionDuringBackup(c)
    \/ \E c \in Collections : AddCollectionDuringBackup(c)
    \/ ListAllSolrCollections
    \/ \E c \in Collections : ReconcileSolrCollectionBackupSubmit(c)
    \/ \E c \in Collections : SolrBackupTaskCompletes(c)
    \/ \E c \in Collections : CheckAsyncRequestCompleted(c)
    \/ \E c \in Collections : DeleteAsyncRequestForBackup(c)
    \/ PatchSolrBackupStatus
    \/ PatchSolrBackupStatusConflict
    \/ \E c \in Collections : CheckAsyncRequestNotFound(c)
    \/ UpdateStatusOfCollectionBackups
    \/ ScheduleNextBackup

    \/ RequestBasicAuth
    \/ ReconcileForBasicAuthLookupMissingSecret
    \/ CreateBasicAuthSecret
    \/ CreateBootstrapSecret
    \/ FailBootstrapSecretCreate
    \/ ControllerRuntimeRetryBasicAuth
    \/ ReconcileForBasicAuthLookupExistingSecret
    \/ GenerateZKInteractionInitContainer
    \/ ApplySecurityStatefulSet
    \/ RunSetupZKSecurityJson
    \/ KubernetesAuthPodBecomesReady
    \/ CreateCloudStatus
    \/ ExternalModifyZKSecurity
    \/ ManualCreateBootstrapSecret

Spec == Init /\ [][Next]_vars

(***************************************************************************
 * Invariants
 *************************************************************************)

TypeOK ==
    /\ replicaType \in [Replicas -> ReplicaTypes]
    /\ replicaState \in [Replicas -> ReplicaStates]
    /\ replicaNode \in [Replicas -> Pods]
    /\ leader \in [Shards -> Replicas \cup {NoReplica}]
    /\ podRevision \in [Pods -> PodRevisions]
    /\ podReady \in [Pods -> BOOLEAN]
    /\ podExists \in [Pods -> BOOLEAN]
    /\ scheduledForDeletion \subseteq Pods
    /\ snapshotValid \in BOOLEAN
    /\ selectedForUpdate \subseteq Pods
    /\ selectionPending \in BOOLEAN
    /\ clusterOpLock \subseteq ClusterOps
    /\ opQueue \subseteq ClusterOps
    /\ opStatus \in [ClusterOps -> OpStatuses]
    /\ opError \in [ClusterOps -> BOOLEAN]
    /\ asyncState \in [ClusterOps -> AsyncStates]
    /\ retryDue \subseteq ClusterOps
    /\ eventDue \subseteq ClusterOps
    /\ dispatchReady \subseteq ClusterOps
    /\ handlerReturned \subseteq ClusterOps
    /\ handlerRequestInProgress \subseteq ClusterOps
    /\ balanceReadyToSubmit \subseteq ClusterOps
    /\ opAge \in [ClusterOps -> Nat]
    /\ availableCollections \subseteq Collections
    /\ backupActive \in BOOLEAN
    /\ backupCohort \subseteq Collections
    /\ initialBackupCohort \subseteq Collections
    /\ workingCRStatus \in [Collections -> BackupStates]
    /\ durableCRStatus \in [Collections -> BackupStates]
    /\ taskState \in [Collections -> AsyncStates]
    /\ taskRecord \in [Collections -> BOOLEAN]
    /\ taskEverSubmitted \in [Collections -> BOOLEAN]
    /\ cleanupPending \subseteq Collections
    /\ backupFinished \in BOOLEAN
    /\ nextScheduled \in BOOLEAN
    /\ backupListNeeded \in BOOLEAN
    /\ statusPatchPending \in BOOLEAN
    /\ basicAuthRequested \in BOOLEAN
    /\ authPhase \in AuthPhases
    /\ authSecret \in BOOLEAN
    /\ bootstrapSecret \in BOOLEAN
    /\ credentialVersion \in SecurityVersions
    /\ bootstrapVersion \in SecurityVersions
    /\ securityJsonLoaded \in BOOLEAN
    /\ podTemplateHasBootstrap \in BOOLEAN
    /\ podTemplateApplied \in BOOLEAN
    /\ podCredentialVersion \in SecurityVersions
    /\ zkSecurityVersion \in SecurityVersions
    /\ authPodReady \in BOOLEAN
    /\ cloudReady \in BOOLEAN

\* S1 / MC-1: count-safe selection must preserve a writable eligible replica.
WriteAvailabilityBudget ==
    \A s \in Shards :
        (InitiallyWritable(s) /\ selectedForUpdate /= {}) =>
            ActiveEligibleReplicas(s) /= {}

\* S2: a nonterminal operation must own concrete future execution, not just
\* the handler's requestInProgress return bit.
NonterminalOpHasFuture ==
    \A op \in ClusterOps :
        opStatus[op] = "nonterminal" =>
            \/ op \in opQueue
            \/ op \in eventDue
            \/ op \in dispatchReady
            \/ op \in handlerReturned
            \/ op \in balanceReadyToSubmit
            \/ op \in retryDue
            \/ asyncState[op] = "running"

\* S2: one annotation can contain at most one current operation.
OneActiveClusterOp == Cardinality(clusterOpLock) <= 1

\* S3: omitted collection selection must not change within one run.
BackupCohortStable ==
    ~backupActive \/ backupCohort = initialBackupCohort

\* Harm-bearing cohort obligation: once a collection has in-progress work,
\* relisting must not silently remove it from the set the controller polls.
SubmittedBackupRemainsInCohort ==
    \A c \in Collections :
        (backupActive /\ workingCRStatus[c] = "submitted") =>
            c \in backupCohort

\* S3 bounded liveness obligation: an unfinished run must have a concrete
\* transition capable of changing durable/working progress.
BackupEventuallyTerminal ==
    \/ ~backupActive
    \/ backupFinished
    \/ backupListNeeded
    \/ statusPatchPending
    \/ cleanupPending /= {}
    \/ AllWorkingTerminal
    \/ \E c \in backupCohort :
          \/ workingCRStatus[c] = "absent"
          \/ /\ workingCRStatus[c] = "submitted"
             /\ taskRecord[c]
             /\ taskState[c] \in {"running", "completed", "failed"}

\* S3: successful destructive cleanup requires durable terminal evidence.
CleanupAfterDurableTerminal ==
    \A c \in Collections :
        ( /\ taskEverSubmitted[c]
          /\ ~taskRecord[c]
          /\ TerminalBackupState(workingCRStatus[c])) =>
            TerminalBackupState(durableCRStatus[c])

\* S4 / MC-5: Ready must reflect the requested application identity.
ReadyBasicAuthIsInstalled ==
    (cloudReady /\ basicAuthRequested) =>
        /\ authSecret
        /\ credentialVersion /= "none"
        /\ zkSecurityVersion = credentialVersion

\* Temporal companions for later fairness-tuned validation runs.
NonterminalOpEventuallyTerminal ==
    \A op \in ClusterOps :
        (opStatus[op] = "nonterminal") ~> (opStatus[op] = "terminal")

BackupTerminationLiveness == backupActive ~> backupFinished

=============================================================================
