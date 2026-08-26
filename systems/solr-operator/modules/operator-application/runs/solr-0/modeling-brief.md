# Modeling Brief: Solr Operator ⇄ Apache Solr Admin-API Interaction Boundary

## 1. System Overview

- **System**: `apache/solr-operator` (Go, k8s controller-runtime, commit `ed5c5c7`) in
  conversation with **Apache Solr / SolrCloud** (Java, `apache/solr` main). Core
  interaction logic ≈ 2,000 LOC across `solrcloud_controller.go`, `solr_cluster_ops_util.go`,
  `solr_pod_lifecycle_util.go`, `util/{solr_scale_util,solr_update_util,backup_util}.go`,
  `util/solr_api/*`, `solrbackup_controller.go`.
- **Category**: **A (Distributed / Message-Passing).** The correctness frontier is a
  client↔server admin protocol over HTTP plus Solr's async request state machine
  (submitted/running/completed/failed/**notfound**) backed by bounded ZooKeeper maps, composed
  with **operator crash/restart** and **level-triggered reconciliation**. Crash-fault only (not
  BFT). Carry this forward: model with distributed-style actions + explicit crash/recovery, not
  lock-free primitives.
- **What is modeled**: the *conversation* — the operator issues admin calls
  (BALANCE_REPLICAS, REPLACENODE, CLUSTERSTATUS, REQUESTSTATUS/DELETESTATUS, BACKUP, …), observes
  Solr + Kubernetes state, and drives cluster operations (scale up/down, rolling restart, PVC
  expansion, backup) under a single StatefulSet-annotation cluster-op lock.
- **Key architectural facts (deviations that create bugs)**:
  1. **No semantic version comparison** — the operator never compares the running Solr version
     before calling a version-gated endpoint; its only defense is post-hoc HTTP-404 string
     matching, wired **only** for the one v2 call (BALANCE_REPLICAS). CRD allows any `solrImage.tag`.
  2. **v1 client never decodes 4xx/5xx bodies** (api.go:173-182) → on the v1 path, "endpoint
     absent", "precondition 400", and "transient 503" are indistinguishable.
  3. **Async state is consumed inconsistently** across the 3 consumers (eviction/balance re-submit
     on `notfound`; backup hangs on it).
  4. **CLUSTERSTATUS `live_nodes` is ZK-eventually-consistent**; the operator often decides from it
     or from Kubernetes pod-readiness rather than Solr's real replica/leader state.

---

## 2. Scenarios

### Scenario 1: Async request-tracking mishandled — `notfound` and terminal-state consumption (HIGH)

**Mechanism**: The operator consumes Solr's async request state machine
(`submitted/running/completed/failed/notfound`) **inconsistently and non-terminally**; a
`notfound` (returned by Solr both for a never-submitted id *and* for a completed/failed id that was
FIFO-evicted from the 10k-capacity ZK maps) is treated by the backup consumer as "keep waiting",
wedging it forever, while the eviction/balance consumers treat it as "restart".

**Evidence**:
- Code: `CheckBackupForCollection` sets `finished` only for `completed`/`failed`
  (backup_util.go:112-132); `reconcileSolrCollectionBackup` has no re-submit once `InProgress`
  (solrbackup_controller.go:300-323) ⇒ stuck; recurrence also wedged
  (solrbackup_controller.go:100-127,160-176).
- Code (contrast): `notfound`→restart in eviction (solr_update_util.go:569-593) and balance
  (solr_scale_util.go:47-76).
- Solr: `RequestStatusState.NOT_FOUND("notfound", true)` is **terminal**; completed/failed live in
  `SizeLimitedDistributedMap` capacity `NUM_RESPONSES_TO_STORE=10000` (`Overseer.java`,
  `DistributedApiAsyncTracker.java`) ⇒ a *completed* backup reads as `notfound` after 10k async ops
  even with no operator restart.
- Historical: SolrBackup-stuck-on-`notfound` (known-good grounding; archaeology #824/#8).

**Affected code paths**: `CheckBackupForCollection`, `CheckAsyncRequest` (api.go:109-125),
`reconcileSolrCollectionBackup`, `EvictReplicasForPodIfNecessary`, `BalanceReplicasForCluster`.

**Suggested modeling approach**:
- Variables: `solrAsync[reqId] ∈ {none,submitted,running,completed,failed,evicted}`;
  `asyncMapSize` (or an abstract `evict` action) to model the 10k FIFO cap; per-op operator view
  `opStage ∈ {idle,submitted,checking,done}`; `backupInProgress`, `backupFinished`.
- Actions: `SubmitAsync`, `SolrCompleteAsync`, `SolrFailAsync`, `EvictAsyncEntry` (completed/failed
  → `notfound`), `OperatorCheckStatus` (one variant per consumer, faithfully reproducing the
  operator's branch table), `OperatorDeleteStatus`, `OperatorRestart`.
- Granularity: keep submit and observe as **separate** actions so a crash/eviction can interleave
  between them.

**Priority**: High — **Rationale**: two of the four target bug classes (State 16.5%,
Mishandled-error 7.7%) converge here; a confirmed production hang; generalizes the known bug from
"lost across outage" to "lost across 10k ops"; classic distributed crash-window that TLA+ excels at.

---

### Scenario 2: Reporting success / clearing the lock for an operation Solr did not perform (HIGH)

**Mechanism**: A Solr response that means "I did not do this" (404 endpoint-absent, or an
un-decoded v1 error) is converted into operator "operation complete", clearing the cluster-op lock
and advancing the state machine though the cluster was never changed.

**Evidence**:
- Code: BALANCE_REPLICAS 404 → `isUnsupportedApi` tested before `err`, `err=nil`,
  `balanceComplete=true` (solr_scale_util.go:59-65) ⇒ lock cleared as "complete"
  (solrcloud_controller.go:525-528). Known-good grounding.
- Code (root enabler, **NEW**): v1 client discards the JSON error body on `StatusCode>=400`
  (api.go:173-182) ⇒ on the v1 path `IsNotSupportedApiError`/`errorBody` are unreachable; 404/400/503
  collapse to one opaque `ServiceUnavailable`. Only the v2 BALANCE path can classify errors
  (v2.go:86-91) — which is exactly why only it has a version guard.
- Fact: no semantic version check anywhere (`ImageVersion` only splits the tag,
  common_types.go:280); CRD default Solr `9.10.0` but `solrImage.tag` is free
  (solrcloud_types.go:40); BALANCE_REPLICAS is 9.3+-only; `maxNumBackupPoints`/incremental gated by
  Solr version yet sent unconditionally (backup_util.go:88).

**Affected code paths**: `BalanceReplicasForCluster`, `CallCollectionsApi`/`CallCollectionsApiV2`,
`CheckForCollectionsApiError`/`IsNotSupportedApiError`, clusterOp completion
(solrcloud_controller.go:523-537).

**Suggested modeling approach**:
- Variables: `solrVersion` (spec constant, ranges over CRD-permitted versions);
  `endpointSupported[op] = (solrVersion ≥ introVersion[op])`; `apiFamily[op] ∈ {v1,v2}`;
  `clusterBalanced` (ground truth); `lockState`.
- Actions: `CallAdmin(op)` whose Solr reply branches on `endpointSupported` and `apiFamily`
  (v2-absent → classifiable 404; v1-absent → opaque error); `OperatorConsumeReply` reproducing the
  `isUnsupportedApi`-before-`err` ordering and the lock-clear on `complete`.
- Granularity: model the version constant as a first-class adversary dimension (spec CONSTANT set).

**Priority**: High — **Rationale**: Version-incompat (12.1%) + Mishandled-error (7.7%); directly
targets the strongest safety property ("never report success Solr didn't perform"); the v1
no-decode enabler is a new, un-audited generalization beyond the known BALANCE case.

---

### Scenario 3: Deciding from stale / coarse observability instead of Solr's real replica state (HIGH)

**Mechanism**: The operator takes destructive actions (delete/evict a pod) based on a
CLUSTERSTATUS snapshot (ZK-eventually-consistent `live_nodes`/replica states) or on Kubernetes pod
readiness, rather than on Solr's *current* replica/leader placement — so a stale view authorizes
deleting a pod that still holds data or a shard's only active replica.

**Evidence**:
- Code: scale-down `getReplicasForPod` uses **unfiltered** CLUSTERSTATUS
  (solr_cluster_ops_util.go:701-724); stale-empty ⇒ `canDeletePod=true`
  (solr_update_util.go:591-593) ⇒ non-empty ephemeral pod deleted (known-good grounding).
- Code: rolling-update pod selection from the same snapshot
  (`GetNodeReplicaState` solr_update_util.go:124-152; `DeterminePodsSafeToUpdate` :163+;
  `findSolrNodeContents` :402-489).
- Code: BALANCE start gated on Kubernetes readiness `Spec.Replicas != Status.ReadyReplicas`
  (solr_scale_util.go:49) — "pod Ready" ≠ "Solr node live / drained".
- Solr: `ClusterStatus.java` reads `live_nodes` from ZK ephemeral children (eventually consistent).

**Affected code paths**: `getReplicasForPod`, `GetNodeReplicaState`, `findSolrNodeContents`,
`DeterminePodsSafeToUpdate`, `evictSinglePod`, `handleManagedCloudRollingUpdate`.

**Suggested modeling approach**:
- Variables: `solrReplicas[node]` (ground truth) vs `observedReplicas[node]` (last CLUSTERSTATUS);
  `zkLagged` boolean / `staleView`; `podReady[pod]` decoupled from `nodeLive[node]`.
- Actions: `FetchClusterStatus` copies a possibly-lagged ground truth into `observedReplicas`;
  `SolrPlaceReplica`/`SolrRecover` change ground truth without an immediate refresh;
  `OperatorDeletePod` guarded by `observedReplicas` (the bug: guard reads stale, not truth).
- Invariant target: never delete a pod whose *ground-truth* replicas>0 without a completed
  migration.

**Priority**: High — **Rationale**: State class (16.5%); a data-loss safety property; the
observed↔truth split is the canonical distributed-modeling pattern and directly encodes the
known-good grounding bug plus its rolling-update generalization.

---

### Scenario 4: Admin call issued before its Solr-side precondition holds (HIGH)

**Mechanism**: The operator issues an admin command in a cluster state where Solr's handler
precondition does not hold (Solr replies `400`), and — because the v1 path can't classify that
`400` (Scenario 2) — retries it forever instead of recognizing an impossible/illegal request.

**Evidence**:
- Solr: REPLACENODE requires **≥2 live nodes** ("No nodes other than the source node … are live" →
  `400`, `ReplaceNodeCmd.java`); MOVEREPLICA target must be in `live_nodes`; DELETENODE refuses the
  last non-PULL replica (failure in body).
- Code: operator issues REPLACENODE with `sourceNode`+`async` during scale-down
  (solr_update_util.go:574-582) with no check that another live target exists; on the v1 path the
  `400` is swallowed as opaque transient (api.go:173-182) ⇒ eviction retries indefinitely.
- Historical (mechanism evidence, fixed): PVC deleted before pod violated the "storage alive to
  migrate from" precondition and spun BalanceReplicas (#688→PR#689, `544da61`); BalanceReplicas ran
  concurrently with a pending scale-down (lock ordering, #689); BALANCE attempted on a 1-node cloud
  (`<1` vs `<=1`, #822→PR#825, `9ae20a5`).

**Affected code paths**: `EvictReplicasForPodIfNecessary`, `handleManagedCloudScaleDown`,
`determineScaleClusterOpLockIfNecessary`, clusterOp lock/retry-queue
(solr_cluster_ops_util.go:67-154).

**Suggested modeling approach**:
- Variables: `liveNodes ⊆ nodes`; `shardReplicas[shard]` (for the last-replica guard); `lockState`,
  `retryQueue`.
- Actions: `Evict/Replace(node)` **guarded on the operator side by what it actually checks** (only
  `podHasReplicas`), with a separate `SolrEvaluatePrecondition` action that returns `400` when
  `|liveNodes \ {source}| = 0`; the operator's consume step (v1, opaque) loops.
- Invariant: the operator never remains in a state where it repeatedly issues an admin call whose
  Solr precondition is unsatisfiable, without surfacing failure or converging.

**Priority**: High — **Rationale**: Semantic-precondition is the **dominant** target class
(63.7%); this scenario makes Solr's real handler preconditions first-class guards, per the target's
core modeling guidance, and composes with Scenario 2's opaque-v1-error to produce a livelock.

---

### Scenario 5: Application error dropped ⇒ level-triggered self-heal stalls (MEDIUM)

**Mechanism**: The reconcile loop discards a non-nil error returned by a cluster-op handler, so a
transient Solr/HTTP failure neither surfaces nor schedules a prompt requeue; convergence then
depends only on the next watch/resync rather than on retrying the failed conversation.

**Evidence**:
- Code: `if operationFound { err = nil; … }` in the in-progress clusterOp branch
  (solrcloud_controller.go:523-524); on a transient CLUSTERSTATUS failure the scale-down handler
  returns `retryLaterDuration=0`, nothing is queued under 1 min (solrcloud_controller.go:538-569),
  and `retryLaterDuration` stays 0 so no fast requeue is set (solrcloud_controller.go:644-648).
- Historical: maintainer-acknowledged scale-down stall introduced by PR #689 (archaeology #707/#22).

**Affected code paths**: main reconcile clusterOp dispatch (solrcloud_controller.go:494-570,644-652),
`handleManagedCloudScaleDown`, `evictSinglePod`.

**Suggested modeling approach**: model `reconcileTrigger ∈ {watch, resync, requeue}` and an
`errorSwallowed` flag; a `Crash`/`NoRequeue` path that only re-enters via `resync`. Liveness:
`◇ operationComplete` must hold even when individual admin calls transiently fail. Note the lock is
*not* cleared on failure (level-triggering is preserved) — the defect is lost requeue/visibility,
so this is a **liveness/observability** target, not a safety one.

**Priority**: Medium — **Rationale**: Mishandled-error class; real, acknowledged; but it is a
liveness/requeue-timing issue partly mitigated by periodic resync, so lower safety impact than 1–4.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why (Scenario) | How |
|---|---|---|
| Solr async state machine incl. `notfound` + FIFO eviction | S1: root of backup hang, generalizes known bug | `solrAsync[reqId]` + `EvictAsyncEntry`; separate submit/observe actions |
| Per-consumer status-consumption branch tables | S1: the *inconsistency* is the bug | 3 distinct `OperatorCheckStatus_{backup,evict,balance}` actions |
| `solrVersion` as spec CONSTANT + per-op `endpointSupported`/`apiFamily` | S2: version skew is a CRD-permitted adversary | version constant gates Solr replies; v1 vs v2 error classifiability differs |
| Lock-clear / op-complete semantics tied to Solr ground truth | S2: "success Solr didn't perform" | `clusterBalanced`/`opPerformed` ground truth vs operator `complete` |
| observed-vs-truth cluster state (CLUSTERSTATUS lag) + pod-ready ≠ node-live | S3: destructive action on stale view | `observedReplicas` copied (lagged) from `solrReplicas`; decoupled `podReady`/`nodeLive` |
| Solr handler preconditions as explicit guards (REPLACENODE ≥2 live, MOVEREPLICA target-live, DELETENODE last-replica) | S4: dominant semantic class | `SolrEvaluatePrecondition` returning 400 when unmet |
| Operator crash/restart + annotation lock & retry-queue replay | S1,S4,S5: async lost across outage; replay under changed state | `OperatorRestart` clears in-memory op view, keeps annotation lock/queue |

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| Helm/packaging, TLS, ingress/DNS, Prometheus exporter, CRD schema plumbing | Out of the interaction boundary; no protocol content |
| Pod-delete-404-as-success (#840), inverted annotation nil-check (#825 bug A) | Already-fixed; §1.4 reference-only; re-deriving = `git revert` |
| Dead `if err != nil` in `retryNextQueuedClusterOpWithQueue`; misleading pod-missing error text | Pure code-review nits, no protocol effect |
| Exact cron/recurrence scheduling arithmetic | Timer arithmetic, not interaction semantics (model only the "recurrence wedged" *consequence* via S1) |
| Byzantine/equivocating Solr | Crash-fault target; no adversarial Solr |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Async state machine | `solrAsync[reqId]`, `asyncMapAtCap`/`EvictAsyncEntry` | Model submitted→running→completed/failed→`notfound` incl. eviction | 1 |
| Split async consumers | `opStage`, `backupInProgress`, `backupFinished` | Capture per-consumer `notfound` handling divergence | 1 |
| Version skew | `solrVersion` (CONSTANT), `endpointSupported[op]`, `apiFamily[op]` | CRD-permitted version as adversary; v1 vs v2 error classifiability | 2 |
| Ground-truth vs report | `clusterBalanced`/`opPerformed`, `lockState` | Detect success reported for un-performed op | 2 |
| Observed vs truth state | `solrReplicas[node]`, `observedReplicas[node]`, `zkLagged`, `podReady`, `nodeLive` | Stale-view destructive actions | 3 |
| Solr preconditions | `liveNodes`, `shardReplicas[shard]` | REPLACENODE/MOVEREPLICA/DELETENODE guards | 4 |
| Crash/recovery + lock replay | `annotationLock`, `retryQueue`, `OperatorRestart` | Async lost across outage; replay under changed state | 1,4,5 |
| Requeue timing | `errorSwallowed`, `reconcileTrigger` | Lost fast-requeue after swallowed error | 5 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| NoSuccessWithoutAction | Safety | Operator marks a clusterOp "complete" / clears the lock only if Solr actually performed it (balance ran, replicas moved) | S2 (§3.2, §3.3) |
| NoDeleteNonEmptyPod | Safety | Never delete/scale-away a pod whose **ground-truth** replicas>0 without a completed migration | S3 (§3.4) |
| PreconditionBeforeCall | Safety | Every issued admin call has its Solr-side precondition satisfied in the reachable state (≥2 live for REPLACENODE, target-live for MOVEREPLICA, not-last-replica for DELETENODE) | S4 (§2, §3.5) |
| AsyncTerminalConsumed | Safety | A terminal Solr async result (`completed`/`failed`/`notfound`) always drives the operator to a terminal decision (never a permanent wait) | S1 (§3.1) |
| EventuallyConverges | Liveness | Under fair scheduling + finite transient Solr failures, every clusterOp eventually completes or is surfaced as failed (no wedge on `notfound`; no stall on swallowed error) | S1, S5 |
| VersionGuardSound | Safety | On any CRD-permitted `solrVersion`, the operator never both (a) fails to classify an endpoint-absent reply and (b) advances as if it succeeded | S2 |
| NoStaleAuthorizedDestroy | Safety | A destructive action's guard must not be authorized solely by an `observedReplicas` snapshot older than the last ground-truth change | S3 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC1 | Solr evicts a *completed* backup's async entry (10k FIFO) before the operator polls; does the operator ever converge, or wedge on `notfound`? | AsyncTerminalConsumed, EventuallyConverges | 1 |
| MC2 | On a CRD-permitted `solrVersion` lacking an endpoint, can the operator reach a state where it reports the op complete / clears the lock though Solr performed nothing? (BALANCE 404; and any v1 op whose 404/400 is opaque) | NoSuccessWithoutAction, VersionGuardSound | 2 |
| MC3 | With CLUSTERSTATUS lagging Solr ground truth (or `podReady` ahead of `nodeLive`), can scale-down/rolling-update delete a pod that still holds ground-truth replicas / a shard's only active replica? | NoDeleteNonEmptyPod, NoStaleAuthorizedDestroy | 3 |
| MC4 | During scale-down of a small/degraded cloud, can the operator issue REPLACENODE when `|liveNodes\{source}|=0` and then livelock on the opaque v1 `400`? | PreconditionBeforeCall, EventuallyConverges | 4 |
| MC5 | Async requestId reuse: after an interrupted op leaves a stale `completed` under a deterministic requestId, does the next op skip real work by reading the prior `completed`? | NoSuccessWithoutAction | 1,2 |
| MC6 | Operator restart between submit and observe of an async op (backup/evict/balance): which consumers self-heal and which wedge? | AsyncTerminalConsumed, EventuallyConverges | 1 |

All MC items are forward-looking mechanism questions (unaudited generalizations), not
reproductions of a closed PR; the known-good grounding bugs (backup-`notfound`, stale-CLUSTERSTATUS
scale-down, BALANCE-404→complete) serve as depth calibration, not as the targets themselves.

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| T1 | v1 `CallCollectionsApi` never decodes 4xx/5xx body (api.go:173-182) | Unit test: mock Solr returning 404/400 JSON body; assert `response.Error` populated (currently nil) |
| T2 | DELETENODE built but never sent (solr_update_util.go:556-561) | Unit test with fake API asserting a DELETENODE call is issued for the `<2`-replica `-0` pod |
| T3 | `maxNumBackupPoints`/incremental sent to a pre-9.x Solr image | Integration test with older `solrImage.tag`; assert graceful handling |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR1 | `err = nil` swallow in reconcile clusterOp branch (solrcloud_controller.go:523-524) impairs fast requeue | Review whether to preserve error/requeue while keeping the lock |
| CR2 | Backup path should treat `notfound` as terminal (fail or verify-by-listing) and/or re-submit like the other consumers | Align consumers; consult maintainers |
| CR3 | Add a semantic `solrVersion` comparison gate rather than 404 string-matching; harden `IsNotSupportedApiError` for Solr 10 message changes | Design discussion (ties to issue about Solr 10 support) |
| CR4 | Dead `if err != nil` (solr_cluster_ops_util.go:140-143); misleading pod-missing error text (:675-678) | Trivial cleanup |

---

## 7. Reference Pointers

- **Full analysis report**: `../.specula-output/analysis-report.md`
- **Operator source (commit `ed5c5c7`)**:
  - `controllers/solrcloud_controller.go:494-652` (clusterOp dispatch, lock clear, requeue, `err=nil`)
  - `controllers/solr_cluster_ops_util.go:67-154` (lock/retry-queue), `:245-361` (scale), `:658-724` (evict/getReplicas→CLUSTERSTATUS)
  - `controllers/util/solr_scale_util.go:35-104` (BALANCE_REPLICAS, 404→complete, notfound→restart)
  - `controllers/util/solr_update_util.go:124-152` (GetNodeReplicaState), `:402-489` (findSolrNodeContents), `:552-623` (EvictReplicasForPodIfNecessary / REPLACENODE / DELETENODE)
  - `controllers/util/backup_util.go:94-143` (Start/Check/DeleteAsync backup)
  - `controllers/solrbackup_controller.go:100-176,272-323` (backup state machine)
  - `controllers/util/solr_api/api.go:109-183` (v1 client + async status; **no error-body decode**), `v2.go:41-103` (v2 client + `IsNotSupportedApiError`), `errors.go:22-33` (`CheckForCollectionsApiError`), `cluster_status.go` (types)
  - `api/v1beta1/common_types.go:280` (`ImageVersion`), `solrcloud_types.go:40,741` (defaults / 9.3 note)
- **Solr source (`apache/solr`)**: `.../handler/admin/api/{BalanceReplicas,ReplaceNode,DeleteNode,MoveReplicaAPI,ListCollections}.java`,
  `.../cloud/api/collections/{BalanceReplicasCmd,ReplaceNodeCmd,DeleteNodeCmd,MoveReplicaCmd,BackupCmd}.java`,
  `.../handler/admin/{ClusterStatus,CollectionsHandler}.java` (REQUESTSTATUS/DELETESTATUS),
  `.../cloud/{Overseer,DistributedApiAsyncTracker}.java` (10k `SizeLimitedDistributedMap`),
  `solrj/.../response/RequestStatusState.java` (async state strings; `notfound` terminal).
- **Confirmed fix PRs (local git)**: #689 `544da61`, #825 `9ae20a5`, #836, #840 `ed5c5c7` — reference/calibration only.
- **Category**: A (Distributed / Message-Passing), crash-fault, no BFT overlay.
