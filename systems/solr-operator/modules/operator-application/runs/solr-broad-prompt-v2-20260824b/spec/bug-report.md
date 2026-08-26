# Bug Report — Apache Solr Operator broad interaction semantics

## Summary

- Source revision: `ed5c5c7d28a4c1189d19f581259e05385c0d4b20`
- Modeled Scenarios tested: 4; Scenario 5 remains test-verifiable by design
- Hunting configs run: 8 BFS runs, each with a 30-minute cap
- Independent model-checking candidates promoted: 5
- Known upstream depth checks: 1 (`REQUESTSTATUS=notfound`, issue #824)
- Trace validation: 13/13 implementation traces pass complete post-state replay
- Convergence: bounded 30-minute `MC.cfg` run, depth 37, 3,785,163,196 generated states and 430,887,998 distinct states; frontier nonempty, so not exhaustive
- Reproduction scope: these are source-confirmed model-checking candidates with real controller/helper-path traces, not live-cluster Phase-4 reproductions

Every hunting BFS found its enabled oracle within one second, so the workflow did not require simulation follow-ups.

## Bug 1: Managed update can remove the only leader-eligible replica while PULL remains active

- **Scenario**: S1 — managed update and typed replicas
- **Severity**: High
- **Invariant violated**: `WriteAvailabilityBudget`
- **Config**: `MC_hunt_s1_managed_update.cfg`
- **Counterexample**: 5 states, `spec/output/MC_hunt_s1_managed_update_bfs.out`
- **Novelty**: targeted upstream search found no direct report; issue #66 concerns general readiness/service mechanics, not mixed replica leadership

### Trace Summary

1. A shard starts writable with one active NRT leader on `update-pod` and one active PULL replica on `pull-pod`.
2. A supported CR change starts a managed update and the operator fetches a successful cluster snapshot.
3. Count-only selection chooses `update-pod` because no replica is currently unavailable.
4. The operator marks that pod unready before deletion. The PULL replica remains active, but no NRT/TLOG replica remains available to lead writes.

### Root Cause

Solr's response parser retains replica type, but `findSolrNodeContents` aggregates only active/down counts. `pickPodsToUpdate` compares those counts to `maxShardReplicasUnavailable` and never checks whether the remaining active set contains an NRT or TLOG replica. Solr documents that PULL replicas cannot become shard leaders, while indexing is routed through the leader: <https://solr.apache.org/guide/solr/latest/deployment-guide/solrcloud-shards-indexing.html>.

### Affected Code

- `controllers/util/solr_api/cluster_status.go:119-149`: parses NRT/TLOG/PULL type
- `controllers/util/solr_update_util.go:214-316`: count-only pod selection
- `controllers/util/solr_update_util.go:407-470`: aggregation drops replica type
- `controllers/solr_pod_lifecycle_util.go:51-131`: removes readiness before deletion

### Recommendation

Carry replica type and leader eligibility into `NodeReplicaState`. Reject a batch that would leave any previously writable shard without an active NRT/TLOG replica, and add mixed TLOG/PULL and NRT/PULL tests.

---

## Bug 2: Dispatcher erases rolling-update and balance errors, abandoning the cluster-operation lock

- **Scenario**: S2 — durable cluster-operation obligations
- **Severity**: Medium
- **Invariant violated**: `NonterminalOpHasFuture`
- **Configs**: `MC_hunt_s2_rolling_error.cfg`, `MC_hunt_s2_balance_check_error.cfg`, `MC_hunt_s2_balance_submit_error.cfg`
- **Counterexamples**: 5/5/6 states; primary file `spec/output/MC_hunt_s2_rolling_error_bfs.out`; corroborating balance files under `spec/output/`
- **Novelty**: open issue #707 tracks the scale-down manifestation; these counterexamples expand the same root area to rolling CLUSTERSTATUS failure and both balance status/submission failures

### Trace Summary

1. The controller persists a rolling or balance lock and consumes the StatefulSet watch event.
2. The selected handler returns an API error. Rolling also returns `requestInProgress=true` without a real task; balance returns no in-progress task and no retry duration.
3. The dispatcher unconditionally clears `err`, consumes the handler tuple, and is still below its age-based queue timeout.
4. The operation remains nonterminal and locked, but owns no async task, retry timer, queued operation, dispatchable event, or pending handler state.

### Root Cause

`SolrCloudReconciler.Reconcile` assigns the handler error and then sets `err = nil` before the later error/timeout logic tests it. None of the three error paths changes a watched resource or supplies a positive requeue. The already-consumed lock event therefore supplies no future execution obligation. The related scale-down symptom is publicly tracked in [issue #707](https://github.com/apache/solr-operator/issues/707), but that report does not cover rolling or BalanceReplicas.

### Affected Code

- `controllers/solrcloud_controller.go:499-570`: handler dispatch, unconditional error clearing, and queue decision
- `controllers/solr_cluster_ops_util.go:483-506`: rolling cluster-state error tuple
- `controllers/util/solr_scale_util.go:43-80`: balance status and submission errors

### Recommendation

Do not discard handler errors before retry/queue policy consumes them. Require every nonterminal return to own a concrete future: a real async request, positive `RequeueAfter`, queued lock, or guaranteed watched mutation. Add regression tests for all three handler sites.

---

## Bug 3: Relisting can drop an already-submitted collection from backup polling

- **Scenario**: S3 — backup cohort and async evidence
- **Severity**: Medium
- **Invariant violated**: `SubmittedBackupRemainsInCohort`
- **Config**: `MC_hunt_s3_backup_cohort.cfg`
- **Counterexample**: 5 states, `spec/output/MC_hunt_s3_backup_cohort_bfs.out`
- **Novelty**: targeted upstream search found no direct issue matching the submitted-then-dropped cohort mechanism

### Trace Summary

1. An omitted `spec.collections` starts a run over collections A and B.
2. BACKUP submission for A succeeds, leaving its working status `submitted` and its async task running.
3. A normal Collections API operation deletes A.
4. The next reconcile calls LIST again and replaces the working cohort with only B. A's old submitted status remains in the CR aggregate but A is no longer iterated or polled.

### Root Cause

When `spec.collections` is empty, every reconcile rebuilds `collectionsToBackup` from the current LIST response. Per-collection status is retained independently and `UpdateStatusOfCollectionBackups` still includes every old entry. A submitted collection that disappears from LIST therefore stops receiving REQUESTSTATUS calls while its nonterminal status can block completion and recurrence. The operator guide promises that omitting the field backs up every available collection and that status/history drive recurring runs: `docs/modules/solr-backup/pages/index.adoc:101-160`.

### Affected Code

- `controllers/solrbackup_controller.go:247-268`: relists and iterates the current collection set every reconcile
- `controllers/solrbackup_controller.go:273-336`: polls only collections in that current set
- `controllers/util/backup_util.go:61-76`: aggregates retained status entries, including dropped collections

### Recommendation

Persist a run cohort when the backup starts and poll that cohort to terminal disposition. If a collection disappears, explicitly mark that target failed/cancelled rather than silently dropping it from iteration.

---

## Bug 4: DELETESTATUS destroys terminal evidence before SolrBackup status is durable

- **Scenario**: S3 — backup cohort and async evidence
- **Severity**: Medium
- **Invariant violated**: `CleanupAfterDurableTerminal`
- **Config**: `MC_hunt_s3_backup_cleanup.cfg`
- **Counterexample**: 6 states, `spec/output/MC_hunt_s3_backup_cleanup_bfs.out`
- **Novelty**: older issues #506/#547 report stuck remote backups, but targeted review found no report establishing this cleanup-before-status-patch root cause

### Trace Summary

1. The operator starts a run and successfully submits collection A.
2. Solr completes the task; REQUESTSTATUS supplies terminal success.
3. The controller changes only its in-memory collection status to `completed` and marks cleanup pending.
4. DELETESTATUS succeeds, erasing Solr's stored response while durable CR status is still `absent`.
5. A later status-patch conflict or controller failure can now discard the sole terminal result; the next reconcile sees `notfound`.

### Root Cause

`reconcileSolrCollectionBackup` observes completion and immediately calls DELETESTATUS. The controller patches `SolrBackup.status` only after the whole reconcile helper returns. Solr documents that completed/failed async responses remain stored until DELETESTATUS explicitly removes them: <https://solr.apache.org/guide/solr/latest/configuration-guide/collections-api.html>.

### Affected Code

- `controllers/solrbackup_controller.go:308-324`: terminal in-memory update followed immediately by DELETESTATUS
- `controllers/solrbackup_controller.go:179-182`: later status patch boundary
- `controllers/util/backup_util.go:139-150`: destructive DELETESTATUS helper

### Recommendation

Persist terminal per-collection status before DELETESTATUS. Perform cleanup from durable state in a later reconcile and treat it as idempotent best-effort work.

---

## Bug 5: Failed second Secret create can produce Ready Solr without requested BasicAuth

- **Scenario**: S4 — BasicAuth bootstrap pipeline
- **Severity**: High
- **Invariant violated**: `ReadyBasicAuthIsInstalled`
- **Config**: `MC_hunt_s4_basic_auth.cfg`
- **Counterexample**: 11 states, `spec/output/MC_hunt_s4_basic_auth_bfs.out`
- **Novelty**: closed issues #659/#720 concern setup-zk read/write behavior; this is a distinct non-atomic Secret creation and recovery path

### Trace Summary

1. A SolrCloud requests operator-generated BasicAuth.
2. The generated credentials Secret is created successfully, but creation of the bootstrap `security.json` Secret fails transiently.
3. controller-runtime retries. The credentials Secret now exists, and the missing bootstrap Secret is explicitly tolerated.
4. StatefulSet generation sees no `SecurityJson`, so setup-zk contains no security installation command.
5. The template is applied, the pod becomes Kubernetes Ready, and SolrCloud status reports Ready while ZooKeeper has no matching security configuration.

### Root Cause

The two Secrets are separate Kubernetes creates. On retry, the existing-credentials branch treats bootstrap NotFound as acceptable and continues with empty `SecurityJson`. Pod generation conditionally omits security installation, while readiness/status are derived from pod and StatefulSet counts rather than installed application identity. The operator's auth guide states that generated BasicAuth bootstraps `security.json`: `docs/modules/solr-cloud/pages/authentication-and-authorization.adoc:28-75`.

### Affected Code

- `controllers/util/solr_security_util.go:99-151`: non-atomic Secret creates and tolerated missing bootstrap Secret
- `controllers/util/solr_util.go:1305-1343`: omits setup-zk security command when `SecurityJson` is empty
- `controllers/solrcloud_controller.go:842-968`: readiness/status do not verify auth installation

### Recommendation

Represent generated credentials and bootstrap data as one recoverable transaction or durable phase. Never proceed to a Ready-capable pod template while the generated pair is incomplete; surface a condition until matching security is confirmed in ZooKeeper.

---

## Known Depth Check

| Scenario | Config | Counterexample | Disposition |
|---|---|---|---|
| S3 async record loss | `MC_hunt_s3_backup_progress.cfg` | 7 states; `spec/output/MC_hunt_s3_backup_progress_bfs.out` | Real stall, but already tracked as open [issue #824](https://github.com/apache/solr-operator/issues/824); not promoted as a new finding |

## Hunting Coverage

| Scenario | Config | Generated / distinct states | Diameter | Result |
|---|---|---:|---:|---|
| S1 | `MC_hunt_s1_managed_update.cfg` | 8 / 5 | 5 | `WriteAvailabilityBudget` violated |
| S2 rolling | `MC_hunt_s2_rolling_error.cfg` | 13 / 7 | 5 | `NonterminalOpHasFuture` violated |
| S2 balance status | `MC_hunt_s2_balance_check_error.cfg` | 76 / 28 | 10 | `NonterminalOpHasFuture` violated |
| S2 balance submit | `MC_hunt_s2_balance_submit_error.cfg` | 76 / 28 | 11 | `NonterminalOpHasFuture` violated |
| S3 cohort | `MC_hunt_s3_backup_cohort.cfg` | 722 / 273 | 10 | `SubmittedBackupRemainsInCohort` violated |
| S3 progress | `MC_hunt_s3_backup_progress.cfg` | 2,314 / 701 | 12 | known #824 depth check |
| S3 cleanup | `MC_hunt_s3_backup_cleanup.cfg` | 894 / 294 | 13 | `CleanupAfterDurableTerminal` violated |
| S4 | `MC_hunt_s4_basic_auth.cfg` | 46 / 17 | 11 | `ReadyBasicAuthIsInstalled` violated |

## Not Reproduced

| Scenario | Config | States Explored | Result |
|---|---|---:|---|
| S5 cross-namespace exporter dependency delivery | None | N/A | Not modeled by design; requires controller/envtest with exporter in namespace A and SolrCloud in B |
| XML/TLS/JVM/shell exact rendering hypotheses | None | N/A | Not model-checkable at this abstraction; retained for consumer-level tests |
| V1 HTTP context/timeout and zero-node backup boundary | None | N/A | Not model-checkable here; retained for unit/envtest or Phase-4 reproduction |

## Spec Adjustments During Hunting

- `CleanupAfterDurableTerminal` was narrowed to terminal working status so independent async-record loss is not mislabeled as destructive cleanup; the revised oracle remains falsifiable at DELETESTATUS.
- The cohort hunt replaced broad set equality with `SubmittedBackupRemainsInCohort` so a violation requires concrete abandoned work, not harmless pre-submission membership drift.
