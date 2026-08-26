# Modeling Brief: apache/solr-operator broad interaction semantics

## 1. System Overview

- **System**: Apache Solr Operator, Go, source `ed5c5c7d28a4c1189d19f581259e05385c0d4b20`; about 12.6 KLOC of production controller/API logic in `controllers/` and `api/v1beta1/`.
- **Category**: **Category A (Distributed / Message-Passing)**. Kubernetes reconciliation, StatefulSet status, Solr Admin API tasks, ZooKeeper state, Secrets, and ConfigMaps advance independently and are joined by persisted CR/status/annotation state.
- **Reference algorithm**: desired CR state -> generated Kubernetes resources -> asynchronous application operations -> observed Solr/Kubernetes state -> CR status.
- **Atomicity boundaries**: each Kubernetes create/patch/status patch, each Solr API submission/status/delete call, each pod deletion, and each controller requeue are separate steps.
- **Concurrency model**: controller-runtime work queues plus independently progressing Kubernetes controllers, Solr overseer tasks, ZooKeeper, probes, Secret/ConfigMap watches, and HTTP requests.
- **Key deviations**: application operations are serialized by annotations on a StatefulSet; backup progress is stored per collection in CR status; availability selection reconstructs Solr cluster state in Go; some dependency changes are converted to reconcile events, while others are not.

## 2. Scenarios

### Scenario 1: Managed updates preserve replica counts but not leader eligibility

**Mechanism**: update selection treats all active replicas as interchangeable even though PULL replicas cannot become leaders.

**Evidence**:
- Code analysis: the API type parses `replica.type` (`controllers/util/solr_api/cluster_status.go:119-149`), and fixtures contain PULL/TLOG/NRT combinations (`controllers/util/solr_update_util_test.go:601-1041`), but aggregation records only active/down counts (`controllers/util/solr_update_util.go:426-466`).
- Code analysis: selection checks only `ShardReplicasNotActive + activeReplicasPerShard` against the budget (`controllers/util/solr_update_util.go:263-281`); it never requires an active NRT/TLOG replica.
- Contract: `maxShardReplicasUnavailable` is the maximum unavailable count (`api/v1beta1/solrcloud_types.go:684-701`; `docs/modules/solr-cloud/pages/managed-updates.adoc:60-75`). Solr documents PULL replicas as ineligible for leadership.
- Historical depth check: issue #66 acknowledged unavoidable downtime for RF=1/one-pod cases; this finding instead targets a supported mixed TLOG/PULL shard with more than one active replica.

**Affected code paths**: `GetNodeReplicaState`, `findSolrNodeContents`, `DeterminePodsSafeToUpdate`, `pickPodsToUpdate`, `DeletePodForUpdate`.

**Suggested modeling approach**:
- Variables: `replicaType`, `replicaState`, `replicaNode`, `leader`, `podRevision`, `podReady`, `scheduledForDeletion`.
- Actions: fetch cluster snapshot; select a batch; mark readiness false; delete/recreate pod; elect leader/recover replicas.
- Granularity: split selection from readiness removal and pod deletion so stale state and concurrent recovery can interleave.

**Priority**: High
**Rationale**: ordinary mixed-replica topology; direct write-availability harm; excellent finite-state fit.

### Scenario 2: A nonterminal cluster operation can lose every reason to run again

**Mechanism**: handler errors and retry metadata are returned separately, but the dispatcher clears `err`; several error paths return neither a pending request nor a positive requeue duration.

**Evidence**:
- Historical: open issue #707 reproduces scale-down permanently stopping after one transient CLUSTERSTATUS failure and explicitly identifies the `err = nil` added by #689.
- Historical: PR #596 establishes the contract that erroring operations are paused/retried and that BalanceReplicas must remain durable because desired pod count cannot reveal imbalance.
- Code analysis: handler errors are assigned at `controllers/solrcloud_controller.go:499-511` then unconditionally cleared at line 524; timeout logic still tests `err != nil` at lines 538-569.
- Code analysis: rolling-update cluster-state failure returns `requestInProgress=true`, `retryLaterDuration=0`, and the API error (`controllers/solr_cluster_ops_util.go:483-506`), so both error propagation and timeout/queue logic are bypassed.
- Code analysis: BalanceReplicas status/submission errors leave `requestInProgress=false` and no requeue (`controllers/util/solr_scale_util.go:43-75,100-103`), after which the dispatcher clears the error.

**Affected code paths**: `SolrCloudReconciler.Reconcile`, `handleManagedCloudRollingUpdate`, `handleManagedCloudScaleDown`, `BalanceReplicasForCluster`, retry-queue helpers.

**Suggested modeling approach**:
- Variables: `clusterOp`, `opQueue`, `opError`, `asyncState`, `requestPending`, `requeueScheduled`, `watchedEventPending`, `lastStart`.
- Actions: dispatch operation; fail API call; submit/poll/delete async task; schedule retry; enqueue/restore operation.
- Granularity: keep handler return, dispatcher decision, annotation patch, and future dequeue as separate actions.

**Priority**: High
**Rationale**: confirmed production mechanism plus unaudited sibling paths; liveness and lock ownership are naturally model-checkable.

### Scenario 3: Backup cohort and async evidence are not durable as one operation

**Mechanism**: the collections being backed up, Solr async evidence, and CR status are updated at different times without a frozen cohort or recoverable completion record.

**Evidence**:
- Historical: open #824 has v0.9.1 production reproductions where `REQUESTSTATUS=notfound` freezes all recurrence; #506/#547 report completed remote data with CR status still in progress.
- Code analysis: when `spec.collections` is omitted, LIST is repeated every reconcile (`controllers/solrbackup_controller.go:246-264`), while old per-collection status entries remain in the aggregate (`controllers/util/backup_util.go:60-75`). A collection deleted between polls can therefore disappear from the loop while its old status prevents completion forever.
- Code analysis: completion is written in memory before DELETESTATUS (`controllers/solrbackup_controller.go:303-320`); status is patched only later (`controllers/solrbackup_controller.go:178-181`). A cleanup failure or status conflict splits terminal evidence from durable CR state.
- Contract: omission means every available collection is backed up (`docs/modules/solr-backup/pages/index.adoc:101-102`); recurrence must advance and preserve history (`docs/modules/solr-backup/pages/index.adoc:112-160`).

**Affected code paths**: `reconcileSolrCloudBackup`, `reconcileSolrCollectionBackup`, `ListAllSolrCollections`, `CheckAsyncRequest`, `DeleteAsyncRequest`, `UpdateStatusOfCollectionBackups`.

**Suggested modeling approach**:
- Variables: `backupCohort`, `collectionStatus`, `solrTaskState`, `solrTaskRecord`, `durableCRStatus`, `nextScheduledTime`.
- Actions: freeze cohort; submit; poll; task-record loss; collection deletion; persist terminal state; delete async record; recover/retry.
- Granularity: terminal CR status must be durable before destructive cleanup, or cleanup must be retryable from durable state.

**Priority**: High
**Rationale**: recurring-backup freeze is production-confirmed; a frozen target cohort exposes an independent, forward-looking question.

### Scenario 4: BasicAuth intent spans two non-atomic Secrets and ZooKeeper

**Mechanism**: credential Secret creation, bootstrap Secret creation, StatefulSet generation, and security.json installation are separate steps, but readiness does not record which steps completed.

**Evidence**:
- Historical: #659 shows a ZooKeeper read failure could overwrite live security state; #720/#755 show version-dependent bootstrap omission while pods still became Ready.
- Code analysis: the operator creates the BasicAuth Secret first and bootstrap Secret second (`controllers/util/solr_security_util.go:95-124`). If the second create fails, the next reconcile sees the first Secret, tolerates a missing bootstrap Secret (`:131-146`), and generates no security.json installation command.
- Code analysis: SolrCloud status is derived from pod/StatefulSet readiness, not authentication intent or ZooKeeper security state (`controllers/solrcloud_controller.go:842-968`).
- Contract: requesting Basic without a supplied Secret must create both credentials and a default security.json (`api/v1beta1/solrcloud_types.go:1630-1655`; auth guide lines 28-75).

**Affected code paths**: `reconcileForBasicAuthWithBootstrappedSecurityJson`, `generateZKInteractionInitContainer`, `cmdToPutSecurityJsonInZk`, `createCloudStatus`.

**Suggested modeling approach**:
- Variables: `authSecret`, `bootstrapSecret`, `zkSecurityState`, `podTemplateHasBootstrap`, `podReady`, `cloudReady`.
- Actions: create each Secret independently; fail/crash between creates; generate/apply pod template; initialize ZK; report readiness; manual recovery.
- Granularity: separate both creates and ZK read/write; distinguish requested, staged, installed, and externally modified security state.

**Priority**: High
**Rationale**: one transient Kubernetes failure can silently change application identity/security while status remains healthy.

### Scenario 5: Reference changes are not uniformly converted into reconcile events

**Mechanism**: the controller accepts explicit cross-namespace references but indexes/watches by name in the referenced object's namespace.

**Evidence**:
- Code analysis: exporter lookup honors `cloud.namespace` (`controllers/solrprometheusexporter_controller.go:285-299`), but the SolrCloud watch lists exporters only in `obj.GetNamespace()` (`:393-436`).
- Contract: `SolrCloudReference.Namespace` is public (`api/v1beta1/solrprometheusexporter_types.go:134-149`), and the exporter guide supports a cloud name and namespace (`docs/modules/solr-prometheus-exporter/pages/index.adoc:19-44`).
- Code analysis: exporter status is only `Deployment.ReadyReplicas > 0` (`controllers/solrprometheusexporter_controller.go:217-274`), so stale ZK/image identity remains reported Ready.

**Affected code paths**: `getSolrConnectionInfo`, `indexAndWatchForSolrClouds`, exporter Deployment generation/status.

**Suggested modeling approach**: retain as a small reference/event-delivery extension only if Scenario 4 already models dependency observation; otherwise verify by controller test.

**Priority**: Medium
**Rationale**: deterministic missed-event path with multi-cloud impact, but cheaper to confirm by test than full TLA+.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|---|---|---|
| Replica type and leader eligibility | Scenario 1 | Add NRT/TLOG/PULL and require an active eligible replica for write availability. |
| Cluster-op retry obligation | Scenario 2 | Every nonterminal op must own a pending task, scheduled retry, or guaranteed watched event. |
| Frozen backup cohort and async evidence | Scenario 3 | Snapshot collection membership at start; separate task state, task record, and CR status. |
| Auth bootstrap stages | Scenario 4 | Split two Secret creates, pod-template staging, and ZK installation. |

### 3.2 Do Not Model

| What | Why |
|---|---|
| Open PR #844 shell-form backup location | Already-known current fix; test/code-review reference only. |
| XML/JSON escaping and PKCS12 filename rendering | Local serialization behavior; unit tests are more direct. |
| Go HTTP/TLS client construction | Transport implementation detail; use deterministic HTTP/TLS tests. |
| Metrics labels, logging, obsolete CLI spelling | Local bugs or already-fixed history. |
| Recreating #707/#824/#659/#720 | Existing answer keys; use only as mechanism evidence. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Typed replicas | `replicaType`, `leaderEligible`, `replicaState` | Distinguish count availability from write leadership | 1 |
| Durable operation obligation | `clusterOp`, `asyncState`, `retryDue`, `eventDue`, `opQueue` | Detect abandoned locks/operations | 2 |
| Backup snapshot and evidence | `backupCohort`, `taskState`, `taskRecord`, `crBackupStatus` | Model loss/reorder of terminal evidence | 3 |
| Auth bootstrap pipeline | `authSecret`, `bootstrapSecret`, `zkSecurity`, `cloudReady` | Detect partial identity application | 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| WriteAvailabilityBudget | Safety | An update honoring availability limits never removes every active NRT/TLOG replica of a previously writable shard | S1, MC-1 |
| NonterminalOpHasFuture | Liveness | Every nonterminal cluster op has a pending task, positive retry, or guaranteed event | S2, MC-2/3 |
| OneActiveClusterOp | Safety | At most one operation owns the StatefulSet lock | S2 |
| BackupCohortStable | Safety | A run's collection set is fixed after start | S3, MC-4 |
| BackupEventuallyTerminal | Liveness | Each submitted collection reaches success/failure within bounded evidence loss | S3 |
| CleanupAfterDurableTerminal | Safety | Async evidence is not irreversibly deleted before terminal CR state is durable | S3 |
| ReadyBasicAuthIsInstalled | Safety | Ready + requested bootstrap BasicAuth implies matching credentials and nonblank security.json in ZK | S4, MC-5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC-1 | Can restarting the sole active NRT/TLOG replica while active PULL replicas remain make a shard unwritable? | WriteAvailabilityBudget | 1 |
| MC-2 | Can rolling-update cluster-state failure return `requestInProgress=true` but leave no task/retry/event? | NonterminalOpHasFuture | 2 |
| MC-3 | Can BalanceReplicas status/submission failure be erased by the dispatcher with no requeue? | NonterminalOpHasFuture | 2 |
| MC-4 | If an omitted collection list changes between polls, can an old status strand recurrence or a new collection join mid-run? | BackupCohortStable, BackupEventuallyTerminal | 3 |
| MC-5 | Can failure/crash between the two Secret creates produce Ready pods without installed BasicAuth? | ReadyBasicAuthIsInstalled | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV-1 | Cross-namespace referenced SolrCloud changes do not enqueue its exporter | envtest: exporter in A references cloud in B; update B status; assert Deployment env changes |
| TV-2 | `--tls-ca-cert-path` populates `ClientCAs`, not `RootCAs` (`main.go:328-345`) | TLS server signed only by supplied CA; `skipVerify=false`; expect current client to fail and RootCAs variant to pass |
| TV-3 | Volume backup at stable scale-to-zero indexes an empty pod-name slice (`backup_util.go:145-154`) | unit/envtest with spec/status replicas 0; assert error/status, never panic |
| TV-4 | S3 endpoint/proxy values are inserted into solr.xml without XML escaping (`solr_backup_repo_util.go:123-154`) | use a valid URL containing `&`; parse generated XML and start a Solr consumer |
| TV-5 | V1 Collections API ignores context and has zero client timeout (`solr_api/api.go:144-190`) | server accepts request but never returns headers; assert bounded cancellation and another cloud still reconciles |
| TV-6 | DELETESTATUS failure after backup completion is not retried (`solrbackup_controller.go:303-331`) | fake terminal task + failing delete; reconcile twice; assert cleanup obligation persists |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | PKCS12 selector accepts an arbitrary key but runtime path is always `keystore.p12` (`solr_tls_util.go:225-228,489-496`) | Decide whether to honor selector key or validate the fixed filename |
| CR-2 | mounted-TLS fallback assigns both server password scripts to `exportClientKeystorePassword`, never `exportClientTruststorePassword` (`solr_tls_util.go:634-637`) | Confirm required Solr env contract; add exact script test |
| CR-3 | Cloud status is skipped whenever pod-derived and StatefulSet counts disagree (`solrcloud_controller.go:477-488`) | Add conditions/observedGeneration; distinguish stale snapshot from desired-state readiness |
| CR-4 | SolrCloud watches keystore Secrets but not referenced truststore/password Secrets (`solrcloud_controller.go:1361-1456`) | Define which rotations require restart and index every load-bearing Secret |

## 7. Reference Pointers

- Full report: `.specula-output/analysis-report.md`
- Core source: `controllers/solrcloud_controller.go`, `controllers/solr_cluster_ops_util.go`, `controllers/util/solr_update_util.go`, `controllers/solrbackup_controller.go`, `controllers/util/backup_util.go`, `controllers/util/solr_security_util.go`, `controllers/solrprometheusexporter_controller.go`.
- Historical mechanisms: [#707](https://github.com/apache/solr-operator/issues/707), [#824](https://github.com/apache/solr-operator/issues/824), [#506](https://github.com/apache/solr-operator/issues/506), [#659](https://github.com/apache/solr-operator/issues/659), [#682](https://github.com/apache/solr-operator/issues/682), [PR #596](https://github.com/apache/solr-operator/pull/596).
- Known/current non-targets: [PR #844](https://github.com/apache/solr-operator/pull/844), [PR #569](https://github.com/apache/solr-operator/pull/569), [PR #722](https://github.com/apache/solr-operator/pull/722), [PR #744](https://github.com/apache/solr-operator/pull/744).
- Product contracts: [Solr replica types](https://solr.apache.org/guide/solr/latest/deployment-guide/solrcloud-shards-indexing.html), [Collections async API](https://solr.apache.org/guide/solr/latest/configuration-guide/collections-api.html), [Go TLS Config](https://pkg.go.dev/crypto/tls), [Go HTTP Client](https://pkg.go.dev/net/http).
