# Analysis Report — Solr Operator ⇄ Apache Solr Admin-API Interaction Boundary

**Target**: `apache/solr-operator` (Go, k8s controller-runtime) at commit `ed5c5c7`, in
conversation with **Apache Solr / SolrCloud** (Java, `apache/solr` main).
**System under specification**: the *conversation* between the two — the operator issues
Collections/Cluster admin API calls, observes Solr + Kubernetes state, and drives cluster
operations (scale up/down, rolling restart, PVC expansion, backup).

**Category**: **A (Distributed / Message-Passing).** The correctness frontier is a
client↔server protocol over HTTP + an async request state machine backed by ZooKeeper,
composed with operator crash/restart and level-triggered reconciliation. Not a lock-free
concurrency problem. (Not BFT — crash-fault only.)

---

## 0. Coverage Statistics

- **Operator core files read in full**: `solrcloud_controller.go` (reconcile + clusterOp
  dispatch), `solr_cluster_ops_util.go`, `solr_pod_lifecycle_util.go`,
  `util/solr_scale_util.go`, `util/solr_update_util.go`, `util/backup_util.go`,
  `solrbackup_controller.go`, `util/solr_api/{api,v2,errors,cluster_status,node_command,backup}.go`.
- **Solr-side handlers read** (via subagent, file:line cited below): BalanceReplicas,
  ReplaceNode, DeleteNode, MoveReplica, ClusterStatus, OverseerStatus, RequestStatus /
  DeleteStatus + `DistributedApiAsyncTracker` / `Overseer` async maps, Backup/Restore.
- **Git archaeology**: 60+ bug-fix commits touching the interaction files enumerated;
  key commits inspected in full (`9ae20a5`/#825, `ed5c5c7`/#840, `0ce9517`/#625,
  `45665b5`/#614, `544da61`/#689, `e5c1271`/#692, `efb82fb`/#561, `848a053`/#596).
- **GitHub issue/PR mining** (subagent): ~430 issues/PRs scanned, ~30 read in full, 27
  interaction-boundary findings, 18 confirmed bugs/gaps. Confirmed fix PRs cross-checked
  against local git (#689, #825, #836, #840 all present in `git log`).

---

## 1. The interaction surface (what the operator says to Solr)

| Operator call site | Solr endpoint | API | Async? | Version note |
|---|---|---|---|---|
| `BalanceReplicasForCluster` (solr_scale_util.go:58) | `POST /api/cluster/replicas/balance` | **v2** | yes | **9.3+ only** (`BalanceReplicas.java`; CHANGELOG "9.3") |
| `EvictReplicasForPodIfNecessary` (solr_update_util.go:574) | `action=REPLACENODE` | **v1** | yes | 8.x+; src-node-liveness optional since 9.x (SOLR-17204) |
| `EvictReplicasForPodIfNecessary` (solr_update_util.go:558) | `action=DELETENODE` (built, **never sent**) | v1 | — | see §3.7 |
| `getReplicasForPod` (solr_cluster_ops_util.go:705); `GetNodeReplicaState` (solr_update_util.go:131) | `action=CLUSTERSTATUS` | v1 | no (ZK read) | live_nodes read from ZK ephemeral children |
| `GetNodeReplicaState` (solr_update_util.go:137) | `action=OVERSEERSTATUS` | v1 | no | empty in distributed-Overseer mode |
| `CheckAsyncRequest` (api.go:115) | `action=REQUESTSTATUS` | v1 | — | states: submitted/running/completed/failed/**notfound** |
| `DeleteAsyncRequest` (api.go:133) | `action=DELETESTATUS` | v1 | — | |
| `StartBackupForCollection` (backup_util.go:99) | `action=BACKUP` (+`maxNumBackupPoints`) | v1 | yes | incremental default 9.x; `maxNumBackupPoints` 9.x |
| `ListAllSolrCollections` (backup_util.go:218) | `action=LIST` | v1 | no | |

**Key architectural facts of the boundary:**
1. **No semantic version comparison exists anywhere.** `ImageVersion` (api/v1beta1/common_types.go:280)
   only splits the tag string. The operator never compares the running Solr version before
   issuing a version-gated endpoint; its *only* defense is post-hoc HTTP-404 string matching,
   and that is wired **only** for the single v2 call (BALANCE_REPLICAS). CRD default is Solr
   `9.10.0` (solrcloud_types.go:40) but `solrImage.tag` is user-settable to any value.
2. **Only BALANCE_REPLICAS uses the v2 client** (`CallCollectionsApiV2`, which decodes the JSON
   error body). Every other admin call uses the v1 client `CallCollectionsApi`, which on
   `StatusCode>=400` builds a generic `ServiceUnavailable` and **does not decode the JSON body**
   (api.go:173-182) — so `IsNotSupportedApiError` and `errorBody`-based classification are
   unreachable on the v1 path.
3. **Cluster operations are serialized by a single StatefulSet annotation lock**
   (`ClusterOpsLockAnnotation`) with a persistent retry queue annotation; both survive operator
   restarts and are *replayed* level-triggered.

---

## 2. Solr-side preconditions & response space (anchors for guards)

- **REQUESTSTATUS `notfound` is TERMINAL** (`RequestStatusState.NOT_FOUND("notfound", true)`,
  solrj `.../response/RequestStatusState.java`). It is returned for **both** (a) a requestId
  never submitted, and (b) a completed/failed requestId **FIFO-evicted** from the
  `SizeLimitedDistributedMap` at `/overseer/collection-map-completed` and
  `/overseer/collection-map-failure`, whose capacity is `NUM_RESPONSES_TO_STORE = 10000`
  (`Overseer.java`; `DistributedApiAsyncTracker.MAX_TRACKED_ASYNC_TASKS = 10000`). **Consequence:
  a backup that actually completed can be observed as `notfound` after 10k subsequent async ops,
  with no operator restart required.**
- **BALANCE_REPLICAS** (`BalanceReplicasCmd.java`): v2-only, 9.3+; `400 BAD_REQUEST` "Cannot
  balance across a single node"; async; partial-inability returns success + warnings.
- **REPLACENODE** (`ReplaceNodeCmd.java`): `sourceNode` required; **requires ≥2 live nodes total**
  ("No nodes other than the source node … are live" → `400`); if `targetNode` given it must be
  live; collection must exist; async accept-then-per-node-failure via
  `SubResponseAccumulatingJerseyResponse`.
- **DELETENODE** (`DeleteNodeCmd.java`): **refuses to delete the only non-PULL replica of a shard**
  — returns a *failure in the response body* (not an HTTP error).
- **MOVEREPLICA** (`MoveReplicaCmd.java`): target node must be in live_nodes (`400` otherwise).
- **CLUSTERSTATUS** (`ClusterStatus.java`): synchronous; `live_nodes` read directly from ZK
  ephemeral children ⇒ **eventually consistent**, can lag real liveness.
- **BACKUP** (`BackupCmd.java`): async; incremental default true (9.x); `400` if location missing;
  `500` (with JSON body) if repository name unknown.

---

## 3. Confirmed findings (verified against source)

### 3.1 Backup wedged forever on async `notfound` — path inconsistency across 3 async consumers  ✔ (known-good, generalized)
`CheckBackupForCollection` (backup_util.go:112-132) sets `finished=true` **only** for
`completed`/`failed`; every other state (incl. `notfound`) → `finished=false, err=nil`.
`reconcileSolrCollectionBackup` (solrbackup_controller.go:300-323) only ever *checks* once
`InProgress==true` — there is **no re-submit path**. So `notfound` ⇒ `InProgress` stuck true
forever; and for recurring backups this also wedges `NextScheduledTime`/pruning
(solrbackup_controller.go:100-127,160-176).
**Contrast**: `EvictReplicasForPodIfNecessary` (solr_update_util.go:569) and
`BalanceReplicasForCluster` (solr_scale_util.go:47) both treat `notfound` as *"(re)start the
request"*. Two of three consumers self-heal; the backup consumer does not. Generalization beyond
the known "lost across operator outage": §2 shows `notfound` also occurs for a **completed**
backup once 10k async ops elapse (no restart needed).

### 3.2 Success reported for an op Solr did not perform — BALANCE_REPLICAS 404→complete  ✔ (known-good)
solr_scale_util.go:59-65: `CheckForCollectionsApiError` is called and `isUnsupportedApi` is tested
**before** `err`; on a 404 (Solr <9.3, or a Solr-10 path/message change) it logs, sets `err=nil`
and `balanceComplete=true`. The reconcile then clears the clusterOp lock as *"complete"*
(solrcloud_controller.go:525-528). The operator reports the balance succeeded though Solr did
nothing; the cluster is left unbalanced with no status signal.

### 3.3 v1 error bodies are never decoded ⇒ endpoint-absent / precondition errors are indistinguishable on v1  ✔ NEW
api.go:173-182: on `StatusCode>=400` the v1 client returns `ServiceUnavailable(...)` and **skips**
`json.Decode(&response)` (guarded by `if err == nil`). Therefore for every v1 admin call
(REPLACENODE, DELETENODE, CLUSTERSTATUS, OVERSEERSTATUS, BACKUP, LIST, REQUESTSTATUS/DELETESTATUS),
`response.Error`/`response.ResponseHeader` stay zero, so `CheckForCollectionsApiError` →
`IsNotSupportedApiError` can **never** fire and a `404 unsupported`, `400 precondition`, and
`503 transient` all collapse to the same opaque transient error. v2 does it correctly
(v2.go:86-91). This is why the version guard exists *only* for BALANCE_REPLICAS: it is the only
call whose error body is parseable.

### 3.4 Deciding from stale/coarse observability, not Solr's real replica/leader state  ✔ (known-good, extended)
- Scale-down: `getReplicasForPod` (solr_cluster_ops_util.go:701-724) issues an **unfiltered**
  CLUSTERSTATUS and derives `podHasReplicas`; a stale-empty view ⇒ `EvictReplicasForPodIfNecessary`
  returns `canDeletePod=true` (solr_update_util.go:591-593) ⇒ non-empty ephemeral pod deleted ⇒
  data loss. No freshness/liveness cross-check (does not consult `live_nodes`).
- Rolling update: `GetNodeReplicaState`/`DeterminePodsSafeToUpdate` (solr_update_util.go:124-152,
  163+) pick pods to delete from the same CLUSTERSTATUS; stale-active ⇒ delete the pod holding a
  shard's only active replica.
- BALANCE gate uses Kubernetes readiness as a proxy for Solr liveness:
  `*statefulSet.Spec.Replicas != statefulSet.Status.ReadyReplicas` (solr_scale_util.go:49) —
  "pod Ready" ≠ "Solr node registered / replicas balanced".

### 3.5 Precondition not established before the admin call (dominant semantic class)  ✔
- **REPLACENODE ≥2-live-nodes precondition** (§2): during scale-down of a small/degraded cloud the
  operator can issue REPLACENODE when Solr's precondition (another live node) does not hold ⇒ Solr
  `400`; on the v1 path (§3.3) this is swallowed as an opaque transient error ⇒ the eviction
  retries indefinitely instead of surfacing "impossible".
- **PVC deleted before pod** during scale-down (#688 → PR #689, `544da61`) violated the
  "storage alive to migrate from" precondition of BALANCE/REPLACENODE and made BalanceReplicas
  spin — fixed, but evidences the mechanism.
- **BalanceReplicas ran while a scale-down was pending** (lock-ordering) — fixed by #689.
- **Single-pod BALANCE precondition** (`replicas<=1`) was `<1` (attempted balance on a 1-node
  cloud) — fixed in PR #825 (`9ae20a5`).

### 3.6 Application error dropped ⇒ level-triggered self-heal impaired  ✔ NEW/confirmed (#707)
solrcloud_controller.go:523-524: inside the in-progress clusterOp branch, `if operationFound { err = nil; … }`
unconditionally discards the handler's error. For a transient CLUSTERSTATUS failure during
scale-down, the handler returns `retryLaterDuration=0`; with `err` nil and runtime <1 min, nothing
is queued (solrcloud_controller.go:538-569) and `retryLaterDuration` stays 0, so **no fast requeue
is scheduled** (solrcloud_controller.go:644-648) — the op resumes only on the next watch/resync.
Maintainer-acknowledged (introduced by PR #689). The clusterOp lock is *not* cleared on failure
(good: level-triggering preserved), but error visibility/requeue is lost.

### 3.7 DELETENODE built but never sent  ✔ NEW (low)
solr_update_util.go:556-561: for a `<2`-replica `-0` pod the code builds a `DELETENODE`
`url.Values` then immediately sets `canDeletePod=true` **without calling** `CallCollectionsApi`.
The pod (ephemeral) is deleted; ZK replica/collection state is never cleaned via DELETENODE. TODO
acknowledges the "last replica of every type" limitation. Mostly benign for ephemeral data but is
a semantic gap (Solr state not reconciled).

### 3.8 Async requestId reuse across successive cluster ops  ✔ NEW
Balance requestId is `"balance-replicas-"+clusterOp.Metadata` (solr_scale_util.go:41), and
Metadata is a **constant** per trigger (`"ScaleUp"`, `"RollingUpdateComplete"`,
`"UndoFailedScaleDown"`; solr_cluster_ops_util.go:299,410,468). Two successive rolling updates
reuse `balance-replicas-RollingUpdateComplete`. If a prior run's `completed` status was not
DELETESTATUS'd (DELETESTATUS failed, or the op was interrupted after `completed` but before delete),
the next op's first `CheckAsyncRequest` returns `completed` immediately (solr_scale_util.go:80) ⇒
`balanceComplete=true` ⇒ the **new** balance is skipped though Solr never ran it for the new state.
Same shape applies to REPLACENODE (`move-replicas-<pod>`) and backups (`<backup>-<collection>`).

---

## 4. Reference / already-fixed (calibration, not modeling targets)

| Ref | What | Fix | Class |
|---|---|---|---|
| #839 → PR #840 (`ed5c5c7`) | pod-delete 404 in rolling update logged as error | treat NotFound as success | Mishandled-error |
| #822 → PR #825 (`9ae20a5`) | inverted annotation nil-check; BALANCE `<1` vs `<=1` | fixed | Semantic |
| #688 → PR #689 (`544da61`) | PVC deleted before pod; BalanceReplicas spins vs pending scale-down | fixed (but added §3.6 `err=nil`) | Semantic |
| #625 (`0ce9517`) | rebalance only after all pods updated; BalanceReplicas as its own clusterOp | design | Semantic |
| #614 (`45665b5`) | rolling restart of ephemeral clouds broke on replica-migration retry | fixed | Observability |
| #120 → PR #836 | events silently dropped (RBAC) — boundary errors invisible | fixed | Observability |

These establish the **bug-prone mechanisms**; per skill §1.4 they are reference context, not
§6.1 model-checkable targets.

---

## 5. Verification notes / exclusions

- The GitHub issue **numbers/dates** come from the archaeology subagent and could not all be
  independently re-fetched; every *code-level* claim above was re-read directly at the cited
  file:line, and every "fixed" PR was cross-checked against local `git log` (#689, #825, #836,
  #840 confirmed present). Findings rest on code, not issue metadata.
- **Excluded** as out-of-boundary: helm/packaging, TLS/security wiring, ingress/DNS, Prometheus
  exporter, CRD schema plumbing.
- **Excluded** as pure code-review nits: dead `if err != nil` in `retryNextQueuedClusterOpWithQueue`
  (solr_cluster_ops_util.go:140-143); misleading error text in `evictSinglePod` pod-missing branch.
