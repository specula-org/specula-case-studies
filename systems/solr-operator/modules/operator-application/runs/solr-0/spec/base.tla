--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for the Apache Solr-Operator <-> Apache Solr
 * admin-API interaction boundary.
 *
 * Derived from:
 *   solr-operator (Go, commit ed5c5c7):
 *     controllers/solrcloud_controller.go          (clusterOp dispatch, lock)
 *     controllers/solr_cluster_ops_util.go         (lock/queue, scale-down, getReplicasForPod)
 *     controllers/util/solr_scale_util.go          (BALANCE_REPLICAS)
 *     controllers/util/solr_update_util.go         (EvictReplicasForPodIfNecessary / REPLACENODE / DELETENODE)
 *     controllers/util/backup_util.go              (StartBackup / CheckBackup)
 *     controllers/solrbackup_controller.go         (backup state machine)
 *     controllers/util/solr_api/{api.go,v2.go,errors.go}  (HTTP client, async status)
 *   Apache Solr (Java, main):
 *     cloud/api/collections/{ReplaceNodeCmd,DeleteNodeCmd,BalanceReplicasCmd}.java  (preconditions)
 *     cloud/DistributedApiAsyncTracker.java, SizeLimitedDistributedMap.java         (10k FIFO async map)
 *     solrj/.../response/RequestStatusState.java   (async state strings; notfound terminal)
 *     handler/admin/ClusterStatus.java             (live_nodes from ZK ephemerals)
 *
 * Category: A (Distributed / Message-Passing), crash-fault, no BFT.
 *
 * Scenarios (modeling-brief.md §2):
 *   S1 async request-tracking (notfound + FIFO eviction; per-consumer divergence)
 *   S2 reporting success / clearing lock for an op Solr did not perform (version skew, v1 no-decode)
 *   S3 deciding from stale/coarse observability instead of Solr's real replica state
 *   S4 admin call issued before its Solr-side precondition holds
 *   S5 application error dropped => level-triggered self-heal stalls (liveness)
 *
 * This spec models the implementation's actual control flow, not an idealized
 * protocol. Deviations from "correct" are where the bugs live; every logic
 * block is annotated with source file:line.
 *)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Nodes            \* Set of Solr pod/node ids, e.g. {n0,n1,n2}
CONSTANT TargetNode       \* The pod being scaled down / evicted (subset of Nodes)

\* --- Version skew (S2, modeling-brief §2 Scenario 2 / §4) ---
CONSTANT SolrVersion      \* running Solr version, integer (e.g. 90 = 9.0, 93 = 9.3)
CONSTANT BalanceMinVersion \* BALANCE_REPLICAS v2 endpoint introduced in 9.3+ (=93)

\* --- Async request ids (deterministic, per solr-operator) ---
\* "balance"           = "balance-replicas-<id>"  (solr_scale_util.go:41)
\* "move"              = "move-replicas-<pod>"     (solr_update_util.go:563)
\* "backup"            = AsyncIdForCollectionBackup (backup_util.go:83,116)
CONSTANTS ReqBalance, ReqMove, ReqBackup

\* --- Async state strings (RequestStatusState.java:26-41) ---
\* getKey() values returned by Solr REQUESTSTATUS (CollectionsHandler.java:800-818)
CONSTANTS AStateNone,        \* internal sentinel: no stored entry -> REQUESTSTATUS = "notfound"
          AStateSubmitted,   \* "submitted"
          AStateRunning,     \* "running"
          AStateCompleted,   \* "completed"  (terminal, stored in 10k map)
          AStateFailed       \* "failed"     (terminal, stored in 10k map)
\* Note: "notfound" is not a stored state; it is what a query returns for an
\* AStateNone entry (never-submitted OR FIFO-evicted). RequestStatusState.java:41
\* NOT_FOUND("notfound", true) -- terminal.

\* --- ClusterOp lock types (solr_cluster_ops_util.go; controller switch) ---
CONSTANTS OpNone, OpScaleDown, OpBalance

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Solr ground truth (the real cluster state) ---
VARIABLE liveNodes        \* subset of Nodes currently live (ZK ephemerals)
VARIABLE solrReplicas     \* [Nodes -> Nat] ground-truth replica count per node
VARIABLE clusterBalanced  \* BOOLEAN: replicas actually balanced across live nodes

\* --- Solr async substrate (S1) ---
VARIABLE asyncState       \* [ReqId -> AState*]  Solr's async request tracker

\* --- Operator cached / observed view (S3) ---
VARIABLE observedReplicas \* [Nodes -> Nat]  last CLUSTERSTATUS snapshot (getReplicasForPod)
VARIABLE observedFresh    \* BOOLEAN: operator has a CLUSTERSTATUS snapshot this cycle

\* --- Operator / Kubernetes cluster-op lock + pods ---
VARIABLE lockOp           \* OpNone/OpScaleDown/OpBalance -- the SS annotation lock
VARIABLE retryQueue       \* Seq of op types (ClusterOpsRetryQueueAnnotation)
VARIABLE podReady         \* [Nodes -> BOOLEAN]  k8s pod readiness (decoupled from liveNodes)
VARIABLE podDeleted       \* [Nodes -> BOOLEAN]  pod removed by scale-down

\* --- Operator op-progress declarations / defect flags ---
VARIABLE declaredComplete \* [OpType -> BOOLEAN] operator marked op complete & cleared lock
VARIABLE badPreconditionCall \* BOOLEAN: operator issued an admin call whose Solr precondition was unmet (S4)
VARIABLE errorSwallowed   \* BOOLEAN: reconcile discarded a non-nil clusterOp error (S5)
VARIABLE staleDestroyAuthorized \* BOOLEAN: a pod deletion was authorized by a CLUSTERSTATUS snapshot
                                \* older than the last ground-truth change (S3)

\* --- Backup CR status (solrbackup_controller.go IndividualSolrBackupStatus) ---
VARIABLE backupRequested  \* BOOLEAN: a backup should be taken
VARIABLE backupInProgress \* BOOLEAN: collectionBackupStatus.InProgress
VARIABLE backupFinished   \* BOOLEAN: collectionBackupStatus.Finished
VARIABLE backupSuccessful \* BOOLEAN
VARIABLE backupObserved   \* last async status string the backup consumer saw

\* --- CRD intent ---
VARIABLE scaleDownRequested \* BOOLEAN: spec wants to remove TargetNode

\* ============================================================================
\* VARIABLE GROUPS (for UNCHANGED clauses)
\* ============================================================================

solrVars     == <<liveNodes, solrReplicas, clusterBalanced>>
asyncVars    == <<asyncState>>
observedVars == <<observedReplicas, observedFresh>>
lockVars     == <<lockOp, retryQueue, podReady, podDeleted>>
opVars       == <<declaredComplete, badPreconditionCall, errorSwallowed, staleDestroyAuthorized>>
backupVars   == <<backupRequested, backupInProgress, backupFinished,
                  backupSuccessful, backupObserved>>
crdVars      == <<scaleDownRequested>>

vars == <<solrVars, asyncVars, observedVars, lockVars, opVars, backupVars, crdVars>>

\* ============================================================================
\* HELPERS
\* ============================================================================

OpTypes == {OpNone, OpScaleDown, OpBalance}

ReqIds  == {ReqBalance, ReqMove, ReqBackup}

\* Endpoint gating (S2): BALANCE_REPLICAS is v2-only and 9.3+ only.
\* solr_scale_util.go:60 "Remove this if-statement when Solr 9.3 is the lowest supported version"
BalanceSupported == SolrVersion >= BalanceMinVersion

\* REQUESTSTATUS reply for a request id.
\* api.go:120 asyncState = asyncStatus.Status.AsyncState; a stored AStateNone reads as "notfound".
\* (RequestStatusState.java:41 NOT_FOUND("notfound", true))
QueryAsync(r) == IF asyncState[r] = AStateNone THEN "notfound" ELSE asyncState[r]

\* Whether the operator's *cached* view says the target pod holds replicas.
\* getReplicasForPod reads CLUSTERSTATUS (solr_cluster_ops_util.go:701-724);
\* evictSinglePod computes podHasReplicas = len(replicas) > 0 (:669-672).
ObservedPodHasReplicas(n) == observedReplicas[n] > 0

\* Solr-side precondition for REPLACENODE (ReplaceNodeCmd.java:62-67):
\* requires at least one live node other than the source, else 400.
ReplaceNodePreconditionHolds(source) ==
    Cardinality(liveNodes \ {source}) >= 1

\* All pods ready (solr_scale_util.go:49  *Spec.Replicas != Status.ReadyReplicas).
AllPodsReady == \A n \in Nodes : podDeleted[n] \/ podReady[n]

\* Number of live pods currently expected (for the single-node balance shortcut).
LivePodCount == Cardinality({n \in Nodes : ~podDeleted[n]})

\* Some live node other than source to receive migrated replicas.
OtherLiveNode(source) == CHOOSE n \in (liveNodes \ {source}) : TRUE

\* ============================================================================
\* SOLR-SIDE ACTIONS (ground truth + async substrate)
\* ============================================================================

\* --------------------------------------------------------------------------
\* SolrPickupAsync: Solr moves a submitted request to running.
\* Models the Overseer picking up a queued async command.
\* Reactive (unbounded).
\* --------------------------------------------------------------------------
SolrPickupAsync(r) ==
    /\ asyncState[r] = AStateSubmitted
    /\ asyncState' = [asyncState EXCEPT ![r] = AStateRunning]
    /\ UNCHANGED <<solrVars, observedVars, lockVars, opVars, backupVars, crdVars>>

\* --------------------------------------------------------------------------
\* SolrCompleteAsync: Solr finishes a request successfully and stores the
\* terminal "completed" response in the 10k SizeLimitedDistributedMap.
\* The *real* cluster effect happens here (this is the ground-truth mutation).
\* Reference: BalanceReplicasCmd.java / ReplaceNodeCmd.java command bodies;
\* DistributedApiAsyncTracker.java (stores completed response).
\* --------------------------------------------------------------------------
SolrCompleteAsync(r) ==
    /\ asyncState[r] \in {AStateSubmitted, AStateRunning}
    /\ asyncState' = [asyncState EXCEPT ![r] = AStateCompleted]
    \* Ground-truth effect of the command:
    /\ \/ /\ r = ReqBalance
          \* BALANCE_REPLICAS actually balances the cluster.
          /\ clusterBalanced' = TRUE
          /\ UNCHANGED <<liveNodes, solrReplicas>>
       \/ /\ r = ReqMove
          \* REPLACENODE migrates all replicas off TargetNode to another live node.
          /\ Cardinality(liveNodes \ {TargetNode}) >= 1
          /\ solrReplicas' = [solrReplicas EXCEPT
                                 ![TargetNode] = 0,
                                 ![OtherLiveNode(TargetNode)] = @ + solrReplicas[TargetNode]]
          /\ UNCHANGED <<liveNodes, clusterBalanced>>
       \/ /\ r = ReqBackup
          \* BACKUP does not change cluster placement.
          /\ UNCHANGED <<liveNodes, solrReplicas, clusterBalanced>>
    /\ UNCHANGED <<observedVars, lockVars, opVars, backupVars, crdVars>>

\* --------------------------------------------------------------------------
\* SolrFailAsync: Solr finishes a request with a "failed" terminal response.
\* No ground-truth cluster effect. Stored in the 10k map.
\* --------------------------------------------------------------------------
SolrFailAsync(r) ==
    /\ asyncState[r] \in {AStateSubmitted, AStateRunning}
    /\ asyncState' = [asyncState EXCEPT ![r] = AStateFailed]
    /\ UNCHANGED <<solrVars, observedVars, lockVars, opVars, backupVars, crdVars>>

\* --------------------------------------------------------------------------
\* EvictAsyncEntry: the 10k-capacity SizeLimitedDistributedMap FIFO-evicts a
\* *terminal* async response, so a later REQUESTSTATUS returns "notfound"
\* even though the op actually completed/failed.
\* Reference: SizeLimitedDistributedMap.java:65-102 (evict oldest when >= maxSize);
\* DistributedApiAsyncTracker.java:73 MAX_TRACKED_ASYNC_TASKS = 10000.
\* This is the S1 mechanism: "completed reads as notfound after 10k ops".
\* Fault action (bounded in MC).
\* --------------------------------------------------------------------------
EvictAsyncEntry(r) ==
    /\ asyncState[r] \in {AStateCompleted, AStateFailed}
    /\ asyncState' = [asyncState EXCEPT ![r] = AStateNone]
    /\ UNCHANGED <<solrVars, observedVars, lockVars, opVars, backupVars, crdVars>>

\* --------------------------------------------------------------------------
\* SolrNodeDown / SolrNodeUp: live_nodes membership changes (ZK ephemerals).
\* Affects REPLACENODE preconditions (S4) and makes CLUSTERSTATUS stale (S3).
\* Fault actions (bounded in MC).
\* --------------------------------------------------------------------------
SolrNodeDown(n) ==
    /\ n \in liveNodes
    /\ Cardinality(liveNodes) >= 1
    /\ liveNodes' = liveNodes \ {n}
    /\ UNCHANGED <<solrReplicas, clusterBalanced>>
    /\ UNCHANGED <<asyncVars, observedVars, lockVars, opVars, backupVars, crdVars>>

SolrNodeUp(n) ==
    /\ n \notin liveNodes
    /\ ~podDeleted[n]
    /\ liveNodes' = liveNodes \cup {n}
    /\ UNCHANGED <<solrReplicas, clusterBalanced>>
    /\ UNCHANGED <<asyncVars, observedVars, lockVars, opVars, backupVars, crdVars>>

\* ============================================================================
\* OPERATOR-SIDE ACTIONS
\* ============================================================================

\* --------------------------------------------------------------------------
\* FetchClusterStatus: getReplicasForPod issues CLUSTERSTATUS and caches the
\* per-node replica list. Reference: solr_cluster_ops_util.go:701-724.
\* The snapshot may go stale as ground truth evolves afterward (S3).
\* --------------------------------------------------------------------------
FetchClusterStatus ==
    /\ observedReplicas' = solrReplicas
    /\ observedFresh'    = TRUE
    /\ UNCHANGED <<solrVars, asyncVars, lockVars, opVars, backupVars, crdVars>>

\* --------------------------------------------------------------------------
\* FetchClusterStatusStale: CLUSTERSTATUS reads live_nodes / replica states from
\* ZK ephemeral children, which are eventually consistent (ClusterStatus.java:120).
\* A lagged snapshot can UNDER-REPORT the replicas actually on TargetNode, so the
\* operator's cached view shows the pod as empty though ground truth says otherwise.
\* This is the S3 mechanism ("stale CLUSTERSTATUS => delete a non-empty pod").
\* Fault action (bounded in MC).
\* --------------------------------------------------------------------------
FetchClusterStatusStale ==
    /\ solrReplicas[TargetNode] > 0
    /\ observedReplicas' = [solrReplicas EXCEPT ![TargetNode] = 0]
    /\ observedFresh'    = TRUE
    /\ UNCHANGED <<solrVars, asyncVars, lockVars, opVars, backupVars, crdVars>>

\* --------------------------------------------------------------------------
\* AcquireScaleDownLock: the reconcile loop acquires the ScaleDown clusterOp
\* lock when a scale-down is requested and no op is running.
\* Reference: determineScaleClusterOpLockIfNecessary (solr_cluster_ops_util.go:245),
\* setClusterOpLock (:71), controller (:618-624).
\* --------------------------------------------------------------------------
AcquireScaleDownLock ==
    /\ lockOp = OpNone
    /\ scaleDownRequested
    /\ ~podDeleted[TargetNode]
    /\ lockOp' = OpScaleDown
    /\ UNCHANGED <<retryQueue, podReady, podDeleted>>
    /\ UNCHANGED <<solrVars, asyncVars, observedVars, opVars, backupVars, crdVars>>

\* --------------------------------------------------------------------------
\* AcquireBalanceLock: the reconcile loop acquires the BalanceReplicas lock.
\* Reference: BalanceReplicasLock dispatch (solrcloud_controller.go:508).
\* --------------------------------------------------------------------------
AcquireBalanceLock ==
    /\ lockOp = OpNone
    /\ ~clusterBalanced
    /\ ~declaredComplete[OpBalance]
    /\ lockOp' = OpBalance
    /\ UNCHANGED <<retryQueue, podReady, podDeleted>>
    /\ UNCHANGED <<solrVars, asyncVars, observedVars, opVars, backupVars, crdVars>>

\* --------------------------------------------------------------------------
\* --- SCALE-DOWN / EVICTION CONSUMER (S1 restart-on-notfound, S3 stale, S4) ---
\* Each reconcile calls evictSinglePod -> EvictReplicasForPodIfNecessary.
\* We split it into faithful per-branch actions guarded by the observed
\* CLUSTERSTATUS view and the Solr async state (level-triggered: re-derived
\* from Solr each reconcile, no persistent operator progress flag).
\* Reference: solr_update_util.go:552-623, solr_cluster_ops_util.go:658-699.
\* --------------------------------------------------------------------------

\* Branch A (single-pod "-0" DELETENODE path): if <2 replicas requested and
\* the pod is "-0", delete the data. Not our TargetNode scenario; omitted for
\* TargetNode (TargetNode is not the "-0" pod). We model the multi-pod branch.

\* CompleteScaleDownDelete: replicaManagementComplete => patch SS replicas down,
\* the TargetNode pod is removed, clear the ScaleDown lock.
\* Reference: handleManagedCloudScaleDown (:347-352), clearClusterOpLockWithPatch
\* via controller (:525-528). NOTE: pod deletion uses ground truth solrReplicas at
\* this instant -- if it was authorized by a stale empty observed view while
\* solrReplicas>0, data is lost (S3). Leaves asyncState and staleDestroyAuthorized
\* to the caller.
CompleteScaleDownDelete ==
    /\ podDeleted' = [podDeleted EXCEPT ![TargetNode] = TRUE]
    /\ lockOp' = OpNone
    /\ declaredComplete' = [declaredComplete EXCEPT ![OpScaleDown] = TRUE]
    /\ liveNodes' = liveNodes \ {TargetNode}
    /\ UNCHANGED <<solrReplicas, clusterBalanced,
                   observedReplicas, observedFresh,
                   retryQueue, podReady, badPreconditionCall, errorSwallowed,
                   backupVars, crdVars>>

\* EvictSubmit: asyncState[move] = notfound AND observed says pod has replicas
\* -> issue REPLACENODE (v1 CallCollectionsApi). solr_update_util.go:569-582.
\* Solr evaluates the REPLACENODE precondition synchronously (v1 body opaque):
\*   - precondition holds  -> async submitted (running eventually)
\*   - precondition unmet   -> Solr returns 400; v1 client cannot decode body
\*     (api.go:173-182) => opaque ServiceUnavailable; err set, no async; loops.
EvictSubmitReplaceNode ==
    /\ lockOp = OpScaleDown
    /\ observedFresh
    /\ QueryAsync(ReqMove) = "notfound"
    /\ ObservedPodHasReplicas(TargetNode)          \* podHasReplicas (:570)
    /\ \/ \* Solr precondition holds: async accepted (ReplaceNodeCmd.java:62-67 passes)
          /\ ReplaceNodePreconditionHolds(TargetNode)
          /\ asyncState' = [asyncState EXCEPT ![ReqMove] = AStateSubmitted]
          /\ UNCHANGED opVars
       \/ \* Solr precondition unmet: 400, opaque on v1 (api.go:173-182), error
          \* swallowed as transient, eviction retries indefinitely. Records S4.
          /\ ~ReplaceNodePreconditionHolds(TargetNode)
          /\ badPreconditionCall' = TRUE
          /\ UNCHANGED <<asyncState, declaredComplete, errorSwallowed, staleDestroyAuthorized>>
    /\ UNCHANGED <<solrVars, observedVars, lockVars, backupVars, crdVars>>

\* EvictNoReplicasCanDelete: asyncState[move]=notfound AND observed says pod is
\* EMPTY -> canDeletePod = true (solr_update_util.go:591-593). This is the S3
\* stale-view destructive path: the guard is the *cached* observedReplicas, which
\* may be older than the last ground-truth change (observed differs from truth).
EvictNoReplicasCanDelete ==
    /\ lockOp = OpScaleDown
    /\ observedFresh
    /\ QueryAsync(ReqMove) = "notfound"
    /\ ~ObservedPodHasReplicas(TargetNode)
    \* Record whether this destroy is authorized by a stale snapshot (S3).
    /\ staleDestroyAuthorized' = (staleDestroyAuthorized \/ (observedReplicas[TargetNode] /= solrReplicas[TargetNode]))
    /\ CompleteScaleDownDelete
    /\ UNCHANGED asyncState

\* EvictCheckCompleted: async completed -> canDeletePod, delete async id.
\* solr_update_util.go:598-600, 613-619.
EvictCheckCompleted ==
    /\ lockOp = OpScaleDown
    /\ QueryAsync(ReqMove) = "completed"
    /\ asyncState' = [asyncState EXCEPT ![ReqMove] = AStateNone]  \* DeleteAsyncRequest
    /\ UNCHANGED staleDestroyAuthorized
    /\ CompleteScaleDownDelete

\* EvictCheckFailed: async failed -> retry (delete async id, no delete of pod).
\* solr_update_util.go:603-606, 613-619 (notfound next reconcile => resubmit).
EvictCheckFailed ==
    /\ lockOp = OpScaleDown
    /\ QueryAsync(ReqMove) = "failed"
    /\ asyncState' = [asyncState EXCEPT ![ReqMove] = AStateNone]  \* DeleteAsyncRequest -> resubmit next time
    /\ UNCHANGED <<solrVars, observedVars, lockVars, opVars, backupVars, crdVars>>

\* EvictCheckRunning: async running/submitted -> requestInProgress, wait.
\* solr_update_util.go:607-608.
EvictCheckRunning ==
    /\ lockOp = OpScaleDown
    /\ QueryAsync(ReqMove) \in {"running", "submitted"}
    /\ UNCHANGED vars

\* --------------------------------------------------------------------------
\* --- BALANCE CONSUMER (S2 version skew / success-without-action) ---
\* BalanceReplicasForCluster (solr_scale_util.go:35-104).
\* --------------------------------------------------------------------------

\* BalanceSingleNodeShortcut: <=1 pods => nothing to balance, balanceComplete.
\* solr_scale_util.go:38-39. Legitimate completion (clusterBalanced trivially).
BalanceSingleNodeShortcut ==
    /\ lockOp = OpBalance
    /\ LivePodCount <= 1
    /\ clusterBalanced' = TRUE
    /\ lockOp' = OpNone
    /\ declaredComplete' = [declaredComplete EXCEPT ![OpBalance] = TRUE]
    /\ UNCHANGED <<liveNodes, solrReplicas, asyncVars, observedVars,
                   retryQueue, podReady, podDeleted,
                   badPreconditionCall, errorSwallowed, staleDestroyAuthorized,
                   backupVars, crdVars>>

\* BalanceSubmit: asyncState[balance]=notfound AND all pods ready -> issue
\* BALANCE via v2 (CallCollectionsApiV2). solr_scale_util.go:47-68.
\* Two Solr outcomes, gated by version:
\*   - endpoint supported -> async submitted.
\*   - endpoint absent (v2 classifiable 404) -> isUnsupportedApi=true =>
\*       err=nil; balanceComplete=true (solr_scale_util.go:59-65).  <-- BUG (S2):
\*       lock cleared as "complete" though Solr balanced nothing.
BalanceSubmit ==
    /\ lockOp = OpBalance
    /\ LivePodCount > 1
    /\ QueryAsync(ReqBalance) = "notfound"
    /\ AllPodsReady                                  \* solr_scale_util.go:49
    /\ \/ \* Supported version: real async balance begins.
          /\ BalanceSupported
          /\ asyncState' = [asyncState EXCEPT ![ReqBalance] = AStateSubmitted]
          /\ UNCHANGED <<solrVars, lockVars, opVars>>
       \/ \* Unsupported version: 404 -> isUnsupportedApi -> balanceComplete=true,
          \* clear lock as complete WITHOUT Solr performing the balance. (S2)
          /\ ~BalanceSupported
          /\ lockOp' = OpNone
          /\ declaredComplete' = [declaredComplete EXCEPT ![OpBalance] = TRUE]
          /\ UNCHANGED <<solrVars, asyncState, retryQueue, podReady, podDeleted,
                         badPreconditionCall, errorSwallowed, staleDestroyAuthorized>>
    /\ UNCHANGED <<observedVars, backupVars, crdVars>>

\* BalanceCheckCompleted: async completed -> balanceComplete, delete async, clear lock.
\* solr_scale_util.go:80-82, 91-97 + controller clear (:525-528).
BalanceCheckCompleted ==
    /\ lockOp = OpBalance
    /\ QueryAsync(ReqBalance) = "completed"
    /\ asyncState' = [asyncState EXCEPT ![ReqBalance] = AStateNone]
    /\ lockOp' = OpNone
    /\ declaredComplete' = [declaredComplete EXCEPT ![OpBalance] = TRUE]
    /\ UNCHANGED <<solrVars, observedVars, retryQueue, podReady, podDeleted,
                   badPreconditionCall, errorSwallowed, staleDestroyAuthorized,
                   backupVars, crdVars>>

\* BalanceCheckFailed: async failed -> retry (delete async id -> resubmit next).
\* solr_scale_util.go:83-84, 91-97.
BalanceCheckFailed ==
    /\ lockOp = OpBalance
    /\ QueryAsync(ReqBalance) = "failed"
    /\ asyncState' = [asyncState EXCEPT ![ReqBalance] = AStateNone]
    /\ UNCHANGED <<solrVars, observedVars, lockVars, opVars, backupVars, crdVars>>

\* BalanceCheckRunning: async running/submitted -> requestInProgress, wait.
\* solr_scale_util.go:85-87.
BalanceCheckRunning ==
    /\ lockOp = OpBalance
    /\ QueryAsync(ReqBalance) \in {"running", "submitted"}
    /\ UNCHANGED vars

\* --------------------------------------------------------------------------
\* --- BACKUP CONSUMER (S1 hang-on-notfound) ---
\* reconcileSolrCollectionBackup (solrbackup_controller.go:285-323) +
\* StartBackupForCollection / CheckBackupForCollection (backup_util.go:94-132).
\* --------------------------------------------------------------------------

\* BackupStart: not finished, not in progress -> StartBackup submits async.
\* solrbackup_controller.go:288-299; backup_util.go:94-110.
BackupStart ==
    /\ backupRequested
    /\ ~backupFinished
    /\ ~backupInProgress
    /\ QueryAsync(ReqBackup) = "notfound"
    /\ asyncState' = [asyncState EXCEPT ![ReqBackup] = AStateSubmitted]
    /\ backupInProgress' = TRUE
    /\ backupObserved' = AStateSubmitted
    /\ UNCHANGED <<solrVars, observedVars, lockVars, opVars,
                   backupRequested, backupFinished, backupSuccessful, crdVars>>

\* BackupCheck: in progress -> CheckBackupForCollection.
\* backup_util.go:112-132: finished ONLY on completed/failed; anything else
\* (running/submitted/notfound) leaves InProgress set with no re-submit.
\* solrbackup_controller.go:300-322. THE BUG (S1): "notfound" (evicted-after-
\* completion, or lost) is NOT terminal here => backup wedges forever.
BackupCheck ==
    /\ backupInProgress
    /\ ~backupFinished
    /\ LET st == QueryAsync(ReqBackup) IN
       \/ \* completed -> finished, success, delete async id (backup_util.go:119-122)
          /\ st = "completed"
          /\ backupFinished' = TRUE
          /\ backupSuccessful' = TRUE
          /\ backupInProgress' = FALSE
          /\ backupObserved' = AStateCompleted
          /\ asyncState' = [asyncState EXCEPT ![ReqBackup] = AStateNone]
       \/ \* failed -> finished, not successful, delete async id (backup_util.go:123-126)
          /\ st = "failed"
          /\ backupFinished' = TRUE
          /\ backupSuccessful' = FALSE
          /\ backupInProgress' = FALSE
          /\ backupObserved' = AStateFailed
          /\ asyncState' = [asyncState EXCEPT ![ReqBackup] = AStateNone]
       \/ \* running/submitted/notfound -> stay InProgress, record status, NO progress.
          \* For "notfound" this is the permanent wedge.
          /\ st \notin {"completed", "failed"}
          /\ backupObserved' = (CASE st = "running"   -> AStateRunning
                                  [] st = "submitted" -> AStateSubmitted
                                  [] OTHER            -> AStateNone)
          /\ UNCHANGED <<asyncState, backupFinished, backupSuccessful, backupInProgress>>
    /\ UNCHANGED <<solrVars, observedVars, lockVars, opVars,
                   backupRequested, crdVars>>

\* ============================================================================
\* FAULT / ENVIRONMENT ACTIONS
\* ============================================================================

\* PodReadyChange: k8s pod readiness flips independently of Solr node liveness.
\* Models "pod Ready" != "Solr node live / drained" (solr_scale_util.go:49). (S3)
PodReadyChange(n) ==
    /\ ~podDeleted[n]
    /\ podReady' = [podReady EXCEPT ![n] = ~@]
    /\ UNCHANGED <<solrVars, asyncVars, observedVars,
                   lockOp, retryQueue, podDeleted, opVars, backupVars, crdVars>>

\* OperatorRestart: the operator crashes; its in-memory CLUSTERSTATUS snapshot is
\* lost (must re-fetch), but the persisted SS annotation lock, retry queue and
\* backup CR status survive. Async ids are deterministic, so the next reconcile
\* re-queries Solr -- if Solr evicted the entry meanwhile, it reads "notfound". (S1,S4,S5)
OperatorRestart ==
    /\ observedFresh' = FALSE
    /\ errorSwallowed' = FALSE
    /\ UNCHANGED <<observedReplicas>>
    /\ UNCHANGED <<solrVars, asyncVars, lockVars,
                   declaredComplete, badPreconditionCall, staleDestroyAuthorized,
                   backupVars, crdVars>>

\* ============================================================================
\* INIT
\* ============================================================================

Init ==
    /\ liveNodes        = Nodes
    /\ solrReplicas     = [n \in Nodes |-> IF n = TargetNode THEN 1 ELSE 1]
    /\ clusterBalanced  = FALSE          \* cluster starts unbalanced (needs a balance)
    /\ asyncState       = [r \in ReqIds |-> AStateNone]
    /\ observedReplicas = [n \in Nodes |-> 0]
    /\ observedFresh    = FALSE
    /\ lockOp           = OpNone
    /\ retryQueue       = <<>>
    /\ podReady         = [n \in Nodes |-> TRUE]
    /\ podDeleted       = [n \in Nodes |-> FALSE]
    /\ declaredComplete = [o \in OpTypes |-> FALSE]
    /\ badPreconditionCall = FALSE
    /\ errorSwallowed   = FALSE
    /\ staleDestroyAuthorized = FALSE
    /\ backupRequested  = TRUE
    /\ backupInProgress = FALSE
    /\ backupFinished   = FALSE
    /\ backupSuccessful = FALSE
    /\ backupObserved   = AStateNone
    /\ scaleDownRequested = TRUE

\* ============================================================================
\* NEXT
\* ============================================================================

Next ==
    \* --- Solr async substrate (reactive) ---
    \/ \E r \in ReqIds : SolrPickupAsync(r)
    \/ \E r \in ReqIds : SolrCompleteAsync(r)
    \/ \E r \in ReqIds : SolrFailAsync(r)
    \/ \E r \in ReqIds : EvictAsyncEntry(r)
    \* --- Solr node liveness (fault) ---
    \/ \E n \in Nodes : SolrNodeDown(n)
    \/ \E n \in Nodes : SolrNodeUp(n)
    \* --- Operator: observability + lock acquisition ---
    \/ FetchClusterStatus
    \/ FetchClusterStatusStale
    \/ AcquireScaleDownLock
    \/ AcquireBalanceLock
    \* --- Operator: scale-down / eviction consumer ---
    \/ EvictSubmitReplaceNode
    \/ EvictNoReplicasCanDelete
    \/ EvictCheckCompleted
    \/ EvictCheckFailed
    \/ EvictCheckRunning
    \* --- Operator: balance consumer ---
    \/ BalanceSingleNodeShortcut
    \/ BalanceSubmit
    \/ BalanceCheckCompleted
    \/ BalanceCheckFailed
    \/ BalanceCheckRunning
    \* --- Operator: backup consumer ---
    \/ BackupStart
    \/ BackupCheck
    \* --- Faults ---
    \/ \E n \in Nodes : PodReadyChange(n)
    \/ OperatorRestart

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* --- Structural / type sanity ---
TypeOK ==
    /\ liveNodes \subseteq Nodes
    /\ solrReplicas \in [Nodes -> Nat]
    /\ clusterBalanced \in BOOLEAN
    /\ asyncState \in [ReqIds -> {AStateNone, AStateSubmitted, AStateRunning,
                                   AStateCompleted, AStateFailed}]
    /\ observedReplicas \in [Nodes -> Nat]
    /\ lockOp \in OpTypes
    /\ podReady \in [Nodes -> BOOLEAN]
    /\ podDeleted \in [Nodes -> BOOLEAN]
    /\ declaredComplete \in [OpTypes -> BOOLEAN]
    /\ backupInProgress \in BOOLEAN
    /\ backupFinished \in BOOLEAN

\* --- S2: NoSuccessWithoutAction (Safety) ---
\* Operator declares an op complete only if Solr actually performed it.
\* balance-complete must imply the cluster is truly balanced.
\* (Violated by the version-absent 404 -> balanceComplete path.)
NoSuccessWithoutAction ==
    declaredComplete[OpBalance] => clusterBalanced

\* --- S2: VersionGuardSound (Safety) ---
\* On any CRD-permitted SolrVersion, the operator must not declare BALANCE
\* complete unless either the endpoint is actually supported (and thus could
\* have performed it) or the cluster was already balanced (nothing to do).
VersionGuardSound ==
    declaredComplete[OpBalance] => (BalanceSupported \/ clusterBalanced)

\* --- S3: NoDeleteNonEmptyPod (Safety) ---
\* Never delete/scale-away a pod whose GROUND-TRUTH replicas > 0.
NoDeleteNonEmptyPod ==
    \A n \in Nodes : podDeleted[n] => solrReplicas[n] = 0

\* --- S3: NoStaleAuthorizedDestroy (Safety) ---
\* A destructive deletion must not have been authorized solely by an
\* observedReplicas snapshot older than the last ground-truth change. This is
\* distinct from NoDeleteNonEmptyPod: it flags the *stale decision* even when
\* solrReplicas happens to be 0 by luck.
NoStaleAuthorizedDestroy ==
    ~staleDestroyAuthorized

\* --- S4: PreconditionBeforeCall (Safety) ---
\* The operator never issues an admin call whose Solr-side precondition is
\* unsatisfiable in the reachable state (>=2 live for REPLACENODE, etc.).
PreconditionBeforeCall ==
    ~badPreconditionCall

\* --- S1: AsyncTerminalConsumed (Safety) ---
\* A terminal async result must drive the operator to a terminal decision.
\* If the backup consumer observed a terminal "notfound" while still InProgress,
\* it must have finished. (Violated: notfound leaves InProgress forever.)
AsyncTerminalConsumed ==
    (backupInProgress /\ backupObserved = AStateNone) => backupFinished

\* --- Structural invariants ---
LockConsistency ==
    lockOp \in OpTypes

BackupStatusConsistency ==
    backupFinished => ~backupInProgress

ReplicaNonNegative ==
    \A n \in Nodes : solrReplicas[n] >= 0

\* ============================================================================
\* TEMPORAL PROPERTIES (liveness)
\* ============================================================================

\* --- S1/S5: EventuallyConverges (Liveness) ---
\* Every requested backup eventually finishes (no wedge on notfound; no stall
\* on a swallowed error). Checked with fairness in a liveness hunt cfg.
BackupEventuallyFinishes ==
    backupRequested ~> backupFinished

\* Scale-down eventually removes the target pod OR surfaces the precondition
\* failure (does not livelock silently).
ScaleDownEventuallyResolves ==
    scaleDownRequested ~> (podDeleted[TargetNode] \/ badPreconditionCall)

====
