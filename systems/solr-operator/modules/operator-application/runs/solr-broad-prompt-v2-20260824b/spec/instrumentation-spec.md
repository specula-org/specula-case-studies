# Instrumentation specification

## 1. Trace event schema

Write one NDJSON object after each modeled action:

```json
{
  "tag": "trace",
  "event": "ExactSpecActionName",
  "pod": "optional-pod-id",
  "replica": "optional-replica-id",
  "shard": "optional-shard-id",
  "op": "optional-cluster-op-id",
  "collection": "optional-collection-id",
  "after": {}
}
```

The event name is exactly the base action name. Emit only the applicable optional identity fields. Every event must include the complete post-state bundle for its family; `Trace.tla` validates every listed field, so omitted fields are not accepted.

### Managed-update bundle (`MU`)

| Trace field under `after` | TLA+ variable | Implementation source |
|---|---|---|
| `replicaType` | `replicaType` | `SolrReplicaStatus.Type` from CLUSTERSTATUS (`controllers/util/solr_api/cluster_status.go:119-149`) |
| `replicaState` | `replicaState` | `SolrReplicaStatus.State` |
| `replicaNode` | `replicaNode` | `SolrReplicaStatus.NodeName` |
| `leader` | `leader` | shard replica with `Leader=true`; use `NO_REPLICA` if none |
| `podRevision` | `podRevision` | pod `controller-revision-hash` compared with StatefulSet `UpdateRevision` (`controllers/solrcloud_controller.go:897-929`) |
| `podReady` | `podReady` | PodReady plus the operator's stop-traffic readiness gate (`controllers/solrcloud_controller.go:875-889`) |
| `podExists` | `podExists` | Kubernetes GET/watch result |
| `scheduledForDeletion` | set variable | JSON array of pods whose stop readiness condition is false for `PodUpdate` |
| `clusterSnapshot` | `clusterSnapshot` | object with `replicaState`, `replicaNode`, `podReady`, `podExists` from the just-consumed observations |
| `snapshotValid` | `snapshotValid` | true only after both cluster/overseer calls succeeded |
| `selectedForUpdate` | set variable | JSON array shadowed from the return of `DeterminePodsSafeToUpdate` |
| `selectionPending` | `selectionPending` | harness shadow: true between update start and selection completion |

### Cluster-operation bundle (`OP`)

| Trace field under `after` | TLA+ variable | Implementation source |
|---|---|---|
| `clusterOpLock` | set variable | JSON array containing the operation in `solr.apache.org/clusterOpsLock`, or empty (`controllers/solr_cluster_ops_util.go:67-99`) |
| `opQueue` | set variable | operation kinds in retry-queue annotation (`controllers/solr_cluster_ops_util.go:81-106`) |
| `opStatus` | `opStatus` | harness shadow (`idle`, `nonterminal`, `terminal`) keyed by `rolling`/`balance` |
| `opError` | `opError` | handler/dispatcher local error shadow |
| `asyncState` | `asyncState` | real Solr REQUESTSTATUS state; `none` means no task record |
| `retryDue` | set variable | operations with positive `retryLaterDuration` applied to `ctrl.Result` |
| `eventDue` | set variable | guaranteed watched/timer events not yet delivered |
| `dispatchReady` | set variable | reconcile has read the current lock and is about to invoke its handler |
| `handlerReturned` | set variable | handler tuple exists but dispatcher lines 523–570 have not run |
| `handlerRequestInProgress` | set variable | raw handler `requestInProgress` return bit; do not infer a real task from it |
| `balanceReadyToSubmit` | set variable | REQUESTSTATUS returned `notfound`, before POST submission |
| `opAge` | `opAge` | discretized age: `0` under one minute, `1` one–ten minutes, `2` over ten minutes |

### Backup bundle (`BK`)

| Trace field under `after` | TLA+ variable | Implementation source |
|---|---|---|
| `availableCollections` | set variable | JSON array from LIST |
| `backupActive` | `backupActive` | current `IndividualSolrBackupStatus.Finished == false` |
| `backupCohort` | set variable | collections iterated by the current reconcile |
| `initialBackupCohort` | ghost set | first successful LIST for this run; harness shadow only |
| `workingCRStatus` | `workingCRStatus` | current in-memory `CollectionBackupStatuses`, normalized to `absent/submitted/completed/failed` |
| `durableCRStatus` | `durableCRStatus` | last SolrBackup status read back from Kubernetes |
| `taskState` | `taskState` | fake/real Solr task execution state |
| `taskRecord` | `taskRecord` | REQUESTSTATUS record exists |
| `taskEverSubmitted` | `taskEverSubmitted` | harness shadow set on successful BACKUP submission |
| `cleanupPending` | set variable | terminal collections between status observation and DELETESTATUS return |
| `backupFinished` | `backupFinished` | aggregate `IndividualSolrBackupStatus.Finished` |
| `nextScheduled` | `nextScheduled` | `NextScheduledTime != nil` |
| `backupListNeeded` | `backupListNeeded` | collection membership changed and the next LIST has not been consumed |
| `statusPatchPending` | `statusPatchPending` | in-memory status differs from last durable status |

### BasicAuth bundle (`AU`)

| Trace field under `after` | TLA+ variable | Implementation source |
|---|---|---|
| `basicAuthRequested` | `basicAuthRequested` | CR has generated BasicAuth intent (`BasicAuthSecret == ""`) |
| `authPhase` | `authPhase` | harness shadow of lookup/create/generate/apply call boundary |
| `authSecret` | `authSecret` | generated BasicAuth Secret exists |
| `bootstrapSecret` | `bootstrapSecret` | generated bootstrap security.json Secret exists |
| `credentialVersion` | `credentialVersion` | stable digest mapped to `v1`; `none` if absent |
| `bootstrapVersion` | `bootstrapVersion` | digest-equivalence to credential version; `none` if absent |
| `securityJsonLoaded` | `securityJsonLoaded` | returned `SecurityConfig.SecurityJson != ""` |
| `podTemplateHasBootstrap` | `podTemplateHasBootstrap` | setup-zk has `SECURITY_JSON` and `cmdToPutSecurityJsonInZk` |
| `podTemplateApplied` | `podTemplateApplied` | generated StatefulSet template observed from Kubernetes |
| `podCredentialVersion` | `podCredentialVersion` | credential Secret version referenced by the applied pod template |
| `zkSecurityVersion` | `zkSecurityVersion` | ZooKeeper `/security.json`: `none`, matching `v1`, or `external` |
| `authPodReady` | `authPodReady` | PodReady count is positive for the applied template |
| `cloudReady` | `cloudReady` | SolrCloud status reports positive ready replicas |

## 2. Action-to-code mapping

Each row is one spec action and one trace event type. `Bundle` means the complete `after` object defined above.

### Scenario 1 — managed updates

| Spec action / event | Code location | Trigger point | Args | Bundle / notes |
|---|---|---|---|---|
| `StartManagedUpdate` | `controllers/solr_cluster_ops_util.go:429-445`; `controllers/solrcloud_controller.go:618-630` | After the rolling-update lock patch succeeds | — | MU; initialize selection shadow |
| `GetNodeReplicaState` | `controllers/util/solr_update_util.go:124-151` | After successful CLUSTERSTATUS and OVERSEERSTATUS aggregation | — | MU; preserve parsed replica type even though aggregation drops it |
| `DeterminePodsSafeToUpdate` | `controllers/util/solr_update_util.go:163-193,209-311` | Immediately after the function returns its selected slice | `pod` for each modeled candidate decision | MU; emit the one selected candidate in this bounded topology |
| `EnsurePodReadinessConditions` | `controllers/solr_pod_lifecycle_util.go:50-73,130-159` | After the Pod status patch succeeds | `pod` | MU |
| `DeletePodForUpdate` | `controllers/solr_pod_lifecycle_util.go:75-127` | After Delete returns success or NotFound | `pod` | MU; refresh Kubernetes existence and Solr state |
| `StatefulSetRecreatePod` | observed at `controllers/solrcloud_controller.go:470-488,897-929` | Harness Pod watch observes a replacement UID/revision | `pod` | MU; external StatefulSet-controller step |
| `SolrRecoverReplica` | observed via `controllers/util/solr_update_util.go:124-151,402-466` | A later CLUSTERSTATUS changes one replica from down/recovering to active | `replica` | MU; emit before the snapshot-consumption event that depends on it |
| `SolrElectLeader` | observed via `controllers/util/solr_api/cluster_status.go:119-149` | CLUSTERSTATUS changes the shard's leader | `shard`, `replica` | MU; accept only NRT/TLOG in harness assertions |

### Scenario 2 — cluster-operation durability

| Spec action / event | Code location | Trigger point | Args | Bundle / notes |
|---|---|---|---|---|
| `StartRollingClusterOp` | `controllers/solr_cluster_ops_util.go:429-445`; `controllers/solrcloud_controller.go:618-630` | After lock annotation patch | — | OP |
| `StartBalanceClusterOp` | `controllers/solr_cluster_ops_util.go:463-470`; `controllers/solrcloud_controller.go:618-630` | After lock annotation patch | — | OP |
| `ControllerRuntimeDeliverClusterOpEvent` | `controllers/solrcloud_controller.go:96,490-515` | After Reconcile reads a current supported lock, immediately before handler call | `op` | OP |
| `HandleManagedCloudRollingUpdateClusterStateFailure` | `controllers/solr_cluster_ops_util.go:483-506` | Immediately after the handler returns `(false,true,0,nil,error)` | — | OP; capture before dispatcher line 524 |
| `HandleManagedCloudRollingUpdateComplete` | `controllers/solr_cluster_ops_util.go:453-471` | Immediately after handler reports complete | — | OP |
| `BalanceReplicasForClusterCheckFailure` | `controllers/util/solr_scale_util.go:43-47,100-103` | Immediately after REQUESTSTATUS error return | — | OP; capture before dispatcher |
| `BalanceReplicasForClusterNotFound` | `controllers/util/solr_scale_util.go:47-58` | After `notfound`, before POST `/api/cluster/replicas/balance` | — | OP |
| `BalanceReplicasForClusterSubmitFailure` | `controllers/util/solr_scale_util.go:52-75,100-103` | Immediately after submission error return | — | OP |
| `BalanceReplicasForClusterSubmitSuccess` | `controllers/util/solr_scale_util.go:52-72,100-102` | After successful submission and retry duration assignment | — | OP |
| `SolrBalanceReplicasTaskCompletes` | observed at `controllers/util/solr_scale_util.go:77-87` | Solr stub/real endpoint changes REQUESTSTATUS to completed | — | OP; managed-system event |
| `ControllerTimerFires` | `controllers/solrcloud_controller.go:644-649` plus harness reconcile entry | When the positive RequeueAfter causes the next reconcile | `op` | OP |
| `BalanceReplicasForClusterCompleted` | `controllers/util/solr_scale_util.go:77-97` | After completed status and DELETESTATUS handling return | — | OP |
| `SolrCloudReconcileClusterOpDispatcher` | `controllers/solrcloud_controller.go:523-570` | After error clearing and complete/queue decision, before later reconcile work | `op` | OP; this is the critical handler/dispatcher boundary |
| `RetryNextQueuedClusterOp` | `controllers/solr_cluster_ops_util.go:123-153,603-616` | After queue-to-lock StatefulSet patch | `op` | OP |

### Scenario 3 — backup cohort and evidence

| Spec action / event | Code location | Trigger point | Args | Bundle / notes |
|---|---|---|---|---|
| `StartBackupRun` | `controllers/solrbackup_controller.go:97-131,223-244` | After a new run's start fields are initialized | — | BK |
| `DeleteCollectionDuringBackup` | normal Solr Collections API, observed by `controllers/util/backup_util.go:213-222` | After test/client DELETE completes, before next operator LIST | `collection` | BK; external public-interface event |
| `AddCollectionDuringBackup` | normal Solr Collections API, observed by `controllers/util/backup_util.go:213-222` | After test/client CREATE completes, before next operator LIST | `collection` | BK; external public-interface event |
| `ListAllSolrCollections` | `controllers/solrbackup_controller.go:246-256`; `controllers/util/backup_util.go:213-222` | After LIST response is accepted | — | BK |
| `ReconcileSolrCollectionBackupSubmit` | `controllers/solrbackup_controller.go:285-300`; `controllers/util/backup_util.go:94-109` | After BACKUP submission succeeds and local status is updated | `collection` | BK |
| `SolrBackupTaskCompletes` | observed through `controllers/util/backup_util.go:112-131` | Solr stub/real endpoint moves task to completed | `collection` | BK; managed-system event |
| `CheckAsyncRequestCompleted` | `controllers/solrbackup_controller.go:300-318` | After local terminal fields are set, immediately before DELETESTATUS | `collection` | BK |
| `DeleteAsyncRequestForBackup` | `controllers/solrbackup_controller.go:319`; `controllers/util/backup_util.go:134-142` | After DELETESTATUS succeeds | `collection` | BK |
| `PatchSolrBackupStatus` | `controllers/solrbackup_controller.go:178-181` | After status patch succeeds and readback is durable | — | BK |
| `PatchSolrBackupStatusConflict` | `controllers/solrbackup_controller.go:178-183` | After status patch returns conflict/error; reload durable object before snapshot | — | BK |
| `CheckAsyncRequestNotFound` | `controllers/util/solr_api/api.go:109-124`; `controllers/util/backup_util.go:112-131` | After REQUESTSTATUS returns `notfound` and local status remains in progress | `collection` | BK; record `taskRecord=false` and `taskState=none` while preserving submitted CR status |
| `UpdateStatusOfCollectionBackups` | `controllers/util/backup_util.go:60-75` | After aggregate fields are recalculated | — | BK |
| `ScheduleNextBackup` | `controllers/solrbackup_controller.go:159-175` | After `NextScheduledTime` is set | — | BK |

### Scenario 4 — BasicAuth bootstrap

| Spec action / event | Code location | Trigger point | Args | Bundle / notes |
|---|---|---|---|---|
| `RequestBasicAuth` | `api/v1beta1/solrcloud_types.go:1625-1655`; reconcile entry `controllers/solrcloud_controller.go:302-315` | After the public SolrCloud CR patch is observed | — | AU |
| `ReconcileForBasicAuthLookupMissingSecret` | `controllers/util/solr_security_util.go:95-100` | After credentials GET returns NotFound, before generation | — | AU |
| `CreateBasicAuthSecret` | `controllers/util/solr_security_util.go:100-112` | After first Secret create succeeds | — | AU |
| `CreateBootstrapSecret` | `controllers/util/solr_security_util.go:113-124` | After second Secret create succeeds | — | AU |
| `FailBootstrapSecretCreate` | `controllers/util/solr_security_util.go:113-116` | After second Secret create returns the injected/real transient error | — | AU |
| `ControllerRuntimeRetryBasicAuth` | error return `controllers/solrcloud_controller.go:302-315`; next reconcile entry line 96 | At start of the retry reconcile caused by the previous error | — | AU |
| `ReconcileForBasicAuthLookupExistingSecret` | `controllers/util/solr_security_util.go:126-148` | After bootstrap GET; include the tolerated NotFound branch | — | AU |
| `GenerateZKInteractionInitContainer` | `controllers/util/solr_util.go:1270-1339` | After pod template generation decides whether setup-zk contains security installation | — | AU |
| `ApplySecurityStatefulSet` | generated at `controllers/util/solr_util.go:89,724-810`; applied in `controllers/solrcloud_controller.go` StatefulSet reconciliation | After StatefulSet create/patch succeeds | — | AU |
| `RunSetupZKSecurityJson` | `controllers/util/solr_security_util.go:242-256`; command attached at `controllers/util/solr_util.go:1304-1339` | After setup-zk exits and ZK readback confirms the matching content | — | AU |
| `KubernetesAuthPodBecomesReady` | observed at `controllers/solrcloud_controller.go:875-889` | Pod watch/read observes Ready for the applied template | — | AU |
| `CreateCloudStatus` | `controllers/solrcloud_controller.go:842-968` | After `createCloudStatus` calculates ready counts, before/after status patch with the same snapshot | — | AU |
| `ExternalModifyZKSecurity` | normal Solr Security API or ZK admin interface; operator contract at `api/v1beta1/solrcloud_types.go:1636-1641` | After readback confirms independently modified security state | — | AU; external public/admin-interface event |
| `ManualCreateBootstrapSecret` | consumed by `controllers/util/solr_security_util.go:131-145` | After a normal Kubernetes Secret create succeeds | — | AU; recovery event |

## 3. Special considerations

- Emit post-state after the exact boundary in the table. In particular, do not merge handler return with `SolrCloudReconcileClusterOpDispatcher`, or `CheckAsyncRequestCompleted` with `DeleteAsyncRequestForBackup` and the later CR status patch.
- Controller goroutines, Kubernetes controllers, Solr tasks, and ZooKeeper advance independently. Serialize events at completed API/observation boundaries; the target is Category A, so one NDJSON order is sufficient for one observed execution.
- `initialBackupCohort`, `selectionPending`, `eventDue`, `dispatchReady`, `handlerReturned`, `taskEverSubmitted`, and phase fields are harness shadows. Update them only at the mapped boundaries; they must not be inferred retroactively from the expected invariant.
- Use stable string IDs exactly matching `Trace.cfg`: pods `update-pod`/`pull-pod`, replicas `nrt-replica`/`pull-replica`, shard `collection1|shard1`, collections `collection-a`/`collection-b`, operations `rolling`/`balance`. A real-system harness should map actual names to these two-element roles at trace start and keep the mapping fixed.
- Sort every JSON array used as a set for deterministic artifacts. JSON object key order is irrelevant.
- Never log Secret bytes, usernames, or passwords. `credentialVersion` and `bootstrapVersion` are equality-class labels derived from an in-memory digest comparison and must not contain the digest or credential material.
- Read ZooKeeper security state only in an isolated test cloud and reduce it to `none`, matching `v1`, or `external`. Do not copy `security.json` into the trace.
- For failure events, use normal interfaces first (fake API server reactors, HTTP fault server, status-patch conflict, or controlled Kubernetes API failure). The trace records the consumer-observed result, not merely a mock's configured intention.
- Trace files live in `../traces/*.ndjson`; override selection with the `JSON` environment variable. `Trace.cfg` requires `TraceMatched`, so a prefix-only replay cannot pass.
