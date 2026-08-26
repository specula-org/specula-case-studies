# Code Analysis Report: solr-operator-broad-interaction

## 0. Scope, provenance, and disposition rules

- Repository: `apache/solr-operator`
- Source root: [`apache/solr-operator@ed5c5c7`](https://github.com/apache/solr-operator/tree/ed5c5c7d28a4c1189d19f581259e05385c0d4b20)
- Audited source: `ed5c5c7d28a4c1189d19f581259e05385c0d4b20` (2026-07-21)
- Language/category: Go; **Category A (Distributed / Message-Passing)**.
- Production controller/API size: 12,555 lines excluding tests and generated deepcopy code.
- Method: `$code-analysis` Step 0 and Phases 1-4, including the Category A distributed-system reference, full core-file reading, bug archaeology, exact-path re-reading, compensating-mechanism checks, and Scenario synthesis.
- Blind-run boundary: candidates were derived from current source, in-repo docs/tests, `SECURITY.md`, and `THREAT_MODEL.md` before git/GitHub history was consulted. `.autors/`, `research/`, `.specula-output` prior reports/logs, and prior Argus/Specula candidates were not used as candidate sources.
- Security scope: findings were checked against the repository's draft threat model. Pass-through pod options, missing admission policy, broad operator RBAC by itself, Solr-server defects, and administrator-only misuse were excluded as directed.
- Candidate gate: retained findings require a supported or ordinary interface transition, concrete observable harm, and a source/doc/test/application contract. Already-fixed or currently-known issues are evidence only unless a distinct unaudited code site generalizes the mechanism.

## 1. Phase 1 — Reconnaissance

### 1.1 Architecture and concurrency map

The operator has three independent controller-runtime controllers:

1. `SolrCloudReconciler` turns a `SolrCloud` into Services, ConfigMaps, Secrets, a StatefulSet, Ingress/PDB/PVC objects, and optionally a ZookeeperCluster. It also sends Solr Admin API operations for cluster state, replica movement, and replica balancing.
2. `SolrBackupReconciler` resolves a SolrCloud/repository, optionally executes directory preparation in a Solr pod, submits one asynchronous Solr backup per collection, polls task state, deletes task records, and persists CR status/history.
3. `SolrPrometheusExporterReconciler` resolves a standalone/cloud reference, TLS/auth/config dependencies, and generates a Deployment/Service/ConfigMap; it exposes only a Boolean `Ready` status.

The manager enables leader election by default (`main.go:114-123,149-171`), but the three controllers and all external controllers/tasks progress independently. No controller transaction spans Kubernetes API writes and Solr/ZooKeeper operations.

### 1.2 Atomicity boundaries

| Logical operation | Actual atomic steps | Interleavings/failure windows |
|---|---|---|
| Default/reconcile a CR | CR update; each dependent-object get/create/update; status patch | later steps can fail after earlier desired state is visible |
| Cluster operation lock | read StatefulSet annotation; handler API calls/pod status patches; annotation patch; future requeue | task can run without durable retry obligation; CR intent can reverse while queued |
| Managed pod update | fetch two Solr snapshots; select pods; patch readiness; optional async REPLACENODE; delete pod | replica state/leader changes after selection; task status and pod deletion are separate |
| Backup run | resolve repo; exec mkdir; set start time in memory; LIST; submit per collection; poll; delete status; patch CR | cohort changes; task record loss; cleanup can precede durable completion |
| BasicAuth bootstrap | create credential Secret; create bootstrap Secret; generate pod; copy security.json to ZK | failure/crash after first Secret; ZK read/write ambiguity |
| Exporter reference update | referenced SolrCloud status change; watch mapping; exporter reconcile; Deployment update; Ready patch | cross-namespace watch can drop the event; Ready can describe stale configuration |
| Operator mTLS setup | load cert; construct global client; filesystem watch; later HTTP calls | one global transport affects all clouds; CA/cert update and calls interleave |

### 1.3 Files read in full

Production entry/core files read completely:

- `main.go`, `SECURITY.md`, `THREAT_MODEL.md`
- `controllers/solrcloud_controller.go`
- `controllers/solrbackup_controller.go`
- `controllers/solrprometheusexporter_controller.go`
- `controllers/solr_cluster_ops_util.go`
- `controllers/solr_pod_lifecycle_util.go`
- `controllers/common.go`, `controllers/event_recorder.go`
- `controllers/util/backup_util.go`
- `controllers/util/common.go`
- `controllers/util/prometheus_exporter_util.go`
- `controllers/util/solr_api/api.go`, `backup.go`, `cluster_status.go`, `errors.go`, `node_command.go`, `v2.go`
- `controllers/util/solr_backup_repo_util.go`
- `controllers/util/solr_pod_disruption.go`
- `controllers/util/solr_scale_util.go`
- `controllers/util/solr_security_util.go`
- `controllers/util/solr_tls_util.go`
- `controllers/util/solr_update_util.go`
- `controllers/util/solr_util.go`
- `controllers/util/zk_util.go`
- `api/v1beta1/common_types.go`, `solrbackup_types.go`, `solrcloud_types.go`, `solrprometheusexporter_types.go`, `groupversion_info.go`

Direct tests and docs were then read around every retained path, especially `solr_update_util_test.go`, controller TLS/auth/backup/ingress tests, backup E2E, and the product pages for scaling, managed updates, cluster locks, addressability, backup/recurrence/repositories, authentication, TLS, ZooKeeper, and exporter references.

### 1.4 Required breadth coverage

| Required surface | Coverage and key code |
|---|---|
| Scale up/down | Lock decision and reversal (`solr_cluster_ops_util.go:245-415`), REPLACENODE (`solr_update_util.go:549-623`), BalanceReplicas (`solr_scale_util.go:29-103`), scale-to-zero docs and boundary behavior |
| Managed updates | status segmentation (`solrcloud_controller.go:842-968`), snapshot aggregation/selection (`solr_update_util.go:124-353,394-529`), readiness/deletion pipeline (`solr_pod_lifecycle_util.go`) |
| Addressability transitions | node/common/headless services, hostAliases, advertised node identity, transition cleanup, ingress E2E (`solrcloud_controller.go:130-213,412-451,706-774`; `solr_util.go:291-315,950-1268`) |
| Cluster-operation locks | annotation serialization, retry queue, timeout/cleanup and reversal (`solr_cluster_ops_util.go:40-153`; `solrcloud_controller.go:490-652`) |
| Backup target selection | repository resolution and availability, explicit collections vs LIST (`solrbackup_controller.go:186-269`) |
| Repository preparation | volume exec and GCS/S3/volume generation (`backup_util.go:145-202`; `solr_backup_repo_util.go`) |
| Sync/async lifecycle | submit/check/delete types and calls (`solr_api/api.go:50-183`; `backup_util.go:94-143`; scale/update helpers) |
| Recurrence/cleanup | history pruning, scheduling, disable/enable, task cleanup (`solrbackup_controller.go:97-181,272-331`) |
| Admin API preconditions/errors | HTTP status, response header/error body, unsupported V2 version path, request IDs, no timeout (`solr_api/`; all callers) |
| Generated `solr.xml` | default template, modules/libs, repositories (`solr_util.go:842-930`; `solr_backup_repo_util.go:123-208`) |
| Generated `security.json` | users/permissions/probe paths and ZK installation (`solr_security_util.go:242-415`) |
| JVM/env/shell arguments | SOLR_OPTS/ZK ACLs, probe commands, TLS wrapper scripts, backup exec (`solr_util.go:314-458,1270-1382`; TLS/security/backup helpers) |
| BasicAuth | generated/user Secret paths, credential context, bootstrap and probes (`solr_security_util.go`) |
| TLS/mTLS | CR verification, mounts/env/scripts, Secret watches, process-global HTTP transport (`solr_tls_util.go`; controller setup; `main.go:244-350`) |
| ZooKeeper identity/ACL | provided/provisioned ZK, chroot parsing/creation, ACL Secret env, status (`zk_util.go`; `common_types.go:289-343`) |
| Secret/ConfigMap references | same-namespace fetches, field indexes/watch mappings, checksums, missing referenced-dependency watches |
| Multi-cloud isolation | namespaced resource generation, global HTTP client, cross-namespace exporter references/watch mapping |
| Status truth/convergence | SolrCloud count/version/repository status, Backup per-collection/history status, Exporter Boolean Ready; observedGeneration gap |

### 1.5 Phase 1 raw candidate ledger

The following were generated before archaeology:

| Raw ID | Mechanism | Initial disposition |
|---|---|---|
| R1 | Replica `Type` parsed but ignored by managed-update availability | retain, model-checkable |
| R2 | cluster-op handler error cleared in dispatcher | retain mechanism; later deduplicate known scale-down site |
| R3 | rolling-update API error marked as request in progress without retry | retain, model-checkable generalized site |
| R4 | BalanceReplicas error has no retry and is cleared | retain, model-checkable generalized site |
| R5 | omitted backup collection list is recomputed, not frozen | retain, model-checkable |
| R6 | backup terminal status and DELETESTATUS are non-atomic | retain as test-verifiable; later found adjacent known issue |
| R7 | scale-to-zero volume backup indexes empty pod slice | retain, test-verifiable |
| R8 | backup location crosses `bash -c` by concatenation | later demote: open PR #844 |
| R9 | repository endpoint/proxy crosses XML without escaping | retain, test-verifiable |
| R10 | two generated BasicAuth Secrets are created non-atomically | retain, model-checkable |
| R11 | custom CA assigned to `ClientCAs` instead of `RootCAs` | retain, test-verifiable |
| R12 | V1 Solr API ignores context and has no HTTP timeout | retain, test-verifiable |
| R13 | cross-namespace SolrCloud reference is not watched cross-namespace | retain, test-verifiable / small model extension |
| R14 | PKCS12 selector key is accepted but runtime path is fixed | retain, code-review-only |
| R15 | mounted TLS client-password fallback copy/paste assignment | retain, code-review-only |
| R16 | truststore/password Secret updates do not all cause restarts | retain, code-review-only |
| R17 | SolrCloud status update is skipped during source-count disagreement | retain, code-review-only |
| R18 | BasicAuth Secret itself is not directly watched | exclude after compensation check: every API-using reconcile reads it fresh; secret change alone need not mutate a dependent resource |
| R19 | external/internal advertised-node identity transition | exclude from concrete handoff: E2E supports transition but does not check application data; no verified harmful consumer outcome yet |

## 2. Phase 2 — Bug archaeology

### 2.1 Git history coverage

- Repository history: 556 commits reachable from all refs.
- Commits touching the selected core paths: 214.
- Keyword hits (`fix|bug|race|panic|deadlock|correctness|crash|corrupt|leak|inconsistent|wrong|error|fail|retry|timeout`): 76 commit objects across all refs.
- Cherry-picks/backports and test/release-only matches were consolidated. **37 significant logical fixes** were examined at patch level; all significant core-path fixes in the 76-hit set were classified.

### 2.2 Significant fix classification

| Commit/PR | Root cause and subsystem | Severity/context |
|---|---|---|
| `ed5c5c7` / #840 | pod delete NotFound treated as warning/error path | Medium update idempotence |
| `9ae20a5` / #825 | inverted annotation condition; one-node balancing boundary | Medium logic/copy mismatch |
| `c5b35fc` / #769 | generated setup-zk shell syntax | High bootstrap failure |
| `10f00c4` / #766 | readiness gates omitted from pod-template copying | High upgrade stall |
| `1cd65d5` / #756 | version-specific Solr ZK CLI stopped honoring env | High security/bootstrap omission |
| `ccf54fd` / #729 | wrong exporter probe parameter | Medium probe cost/failure |
| `e5c1271` / #692 | ingress-addressed scale changed hostAliases and restarted/misrouted pods | High availability |
| `8cbb5b0` / #660 | ZK read failure mistaken for blank security.json | Critical identity overwrite |
| `2358d54` / #694 | exporter liveness performed full metric collection | Medium availability/load |
| `544da61` / #689 | PVCs deleted before scale-down pod deletion; Balance task behavior | High data/availability |
| `0ce9517` / #625 | ephemeral rolling update ended imbalanced | High availability |
| `ea138ed` / #641 | non-TLS Service appProtocol wrong | Medium connectivity |
| `696faff` / #610 | TLS secure probes incompatible across Solr 9 versions | High readiness |
| `45665b5` / #614 | ephemeral rolling restart accounting/eviction defects | High availability |
| `848a053` / #596 | failing operations needed durable retry queue and reversal rules | High liveness |
| `cfaf46c` / #586 | update/scale lacked common serialized cluster-op ownership | High concurrency |
| `852d2a8` / #516 | omitted collections never listed | High backup completeness |
| `c3cda10` / #509 | non-recurring backup completion/scheduling logic | High backup liveness |
| `23ac993` / #481 | custom PVC name broke pod/data mapping and panicked | High crash/availability |
| `9e48f52` / #450 | registry port parsed as image version | Medium status truth |
| `04aefa9` / #439 | custom PVC names not mounted consistently | High startup/data |
| `aa61a52` / #398 | semantically equal resource quantities triggered roll loops | High convergence |
| `173266e` / #374 | volume incremental backup path wrong | High backup correctness |
| `54b4fe3` / #344 | imagePullSecret copy logic for ZK | High dependency startup |
| `c1984dd` / #305 | ZK ephemeral/defaulted fields fought reconcile | High convergence |
| `43f91ea` / #299 | generated security roles/permission ordering wrong | High authorization |
| `6f26747` / #260 | release testing exposed several API/default mismatches | Mixed |
| `497630e` / #226 | termination grace not propagated to shutdown semantics | Medium availability |
| `2ee8a7e` / #225 | wrong Ingress RBAC API group | High reconcile failure |
| `fe62b2d` / #224 | nil pointers and exporter generation errors | High crash |
| `d3e4891` / #210 | TCP custom probes ignored | Medium readiness |
| `507e0c9` / #145 | service port and status URL mismatch | High connectivity/status |
| `8a4e73a` | ordered pod creation and managed-update availability mismatch | High availability |
| `80229f0` | dependent-object equality/default handling caused endless reconcile | High convergence |
| `fb47f93` | defaulted Ingress fields caused endless reconcile | High convergence |
| `0bcff50` / #65 | nil rest config, ZK persistence, backup volume mount | High crash/data |
| `3a5e477` / #64 and `01f2411` / #62 | default loop and chroot creation/validation | High liveness/identity |

Historical density is highest in: (1) independent desired/observed/defaulted Kubernetes fields, (2) cluster operation sequencing and requeue, (3) generated shell/config/application interfaces, and (4) backup async/status lifecycle.

### 2.3 GitHub issue/PR coverage

- Multi-query collection covered bug label plus scale, update, backup, TLS, security, ZooKeeper, exporter, status, panic/crash, retry, and timeout terms.
- 45 unique issue threads had full body/comment payloads retrieved and classified; 9 PR discussions were also read in full.
- Issue classifications: **25 confirmed bugs/design defects**, **12 excluded as user error, unsupported setup, separate Solr/dependency behavior, or explicitly disclaimed design**, and **8 uncertain/enhancement-only**.
- Examples of confirmed: #707, #824, #682, #688, #659, #609, #822, #755, #720, #564, #515, #479, #445, #274, #141, #208, #169, #390, #506, #547.
- Examples excluded/redirected: #475 (Solr AWS SDK dependency), #130 (unsupported backing storage despite RWX declaration), #399 (ephemeral ZooKeeper loss; resolved with persistence), #620 (Solr-version endpoint behavior), broad-RBAC/no-webhook reports covered by `THREAT_MODEL.md` non-findings.

### 2.4 Open PR review

All 17 open PRs were inspected for intent/current state. The two direct open bug-fix PRs were read in full:

- #844 fixes the exact `SolrBackup.spec.location` shell concatenation (mergeable; unit/build green, E2E skipped). It is a known current fix and not a Scenario target.
- #569 attempts to fix backup start/error and InProgress behavior (#506/#547), but is Draft, conflicting, and stale.

Five additional compatibility/status/security PRs were deeply reviewed because they change analyzed contracts:

- #744 security.json overwrite/watch feature: changes requested, conflicting.
- #722 observedGeneration: approved but conflicting; confirms the status-generation gap.
- #461 merged truststore proposal: Draft/conflicting; author rejected its own incomplete mounted-dir approach.
- #826/#827 Solr 10 compatibility: both open; #826 smoke test fails, #827 introduces version-conditioned contracts and explicitly excludes exporter.

Other open PRs are dependency upgrades, Gateway/Ingress features, release tooling, platform options, or unrelated features and have no current fix for retained findings.

### 2.5 Archaeology effect on raw candidates

| Raw candidate | History result | Final use |
|---|---|---|
| R2 scale-down site | #707 open, maintainer-confirmed | reference evidence only; MC targets sibling rolling/balance paths |
| R6 backup status/task record | #506/#547 and stale PR #569 already describe adjacent race | reference + focused cleanup-order test, not answer-key MC |
| R8 shell location | open PR #844 exact fix | demoted entirely from primary Scenarios |
| backup `notfound` | #824 production-confirmed open issue | reference only; do not spend MC on reproducing it |
| security overwrite/CLI bugs | #659/#720/#755 fixed/known | evidence only; MC targets separate two-Secret partial-create window |
| R1, R10-R17 | no matching report/fix found | retain according to verification method |

## 3. Phase 3 — Deep verification

### 3.1 Finding F1: leader-eligible availability is absent from update state

**Path**:

1. `CallCollectionsApi(CLUSTERSTATUS)` decodes each replica's `state`, `leader`, and `type` (`cluster_status.go:119-149`).
2. `findSolrNodeContents` aggregates total/active/down counts but never copies `Type` or counts NRT/TLOG separately (`solr_update_util.go:402-488`).
3. `pickPodsToUpdate` enforces only a replica-count budget (`:263-281`). It may eventually select a current leader's pod after other pods update; being sorted late is not a guard.
4. `DeletePodForUpdate` sets readiness false and deletes the pod once any storage-specific eviction completes.

**Trigger**: a supported collection with one active TLOG/NRT replica and one or more active PULL replicas, followed by an ordinary managed pod-template/image/TLS update.

**Harm**: when the only leader-eligible replica is restarted, PULL replicas cannot elect a leader; updates fail, and newly restarted PULL replicas may also be temporarily unqueryable until leadership returns.

**Contract**: the operator documents `maxShardReplicasUnavailable` availability; Solr's official guide says PULL does not participate in elections. The in-repo test fixtures deliberately include mixed replica types, so the representation is not hypothetical.

**Compensation checked**: leader pods are sorted later, but are still eligible once they are last; the max-unavailable check counts PULL replicas; PDBs are pod-wide and know no shard type. No compensating leader-eligible guard exists.

**Disposition**: MC-1, Scenario 1.

### 3.2 Findings F2/F3: cluster-op errors can be terminal to the reconcile loop but nonterminal in state

**Path F2 (rolling update)**:

1. `GetNodeReplicaState` returns an HTTP/API error.
2. `handleManagedCloudRollingUpdate` returns `operationComplete=false`, `requestInProgress=true`, `retry=0`, plus the error (`solr_cluster_ops_util.go:483-492`). No async request was actually established by this failure path.
3. Dispatcher assigns the tuple then clears `err` (`solrcloud_controller.go:501,523-524`).
4. Because `requestInProgress=true`, timeout/queue logic is skipped; because retry is zero and error is cleared, the reconcile returns success with no requeue and no object mutation.

**Path F3 (BalanceReplicas)**: status/submission error leaves `requestInProgress=false` and retry zero (`solr_scale_util.go:43-75,100-103`); dispatcher clears the error before its error-timeout branch.

**Trigger**: one transient Solr API failure during an ordinary managed update/scale-up rebalance.

**Harm**: lock remains persisted, desired state does not converge, later operations are blocked, and recovery of Solr connectivity alone generates no Kubernetes watch event.

**Contract**: cluster-operations docs require erroring/expired operations to pause and enter retry queue; #596 explains why BalanceReplicas must remain durable; #707 confirms the same dispatcher mechanism at scale-down.

**Compensation checked**: there is no periodic controller resync configured here, default controller worker count is one, and Solr internal state changes do not enqueue Kubernetes reconciles. Unrelated events may rescue the op but are not guaranteed.

**Disposition**: MC-2 and MC-3, Scenario 2. #707 itself is not a modeling target.

### 3.3 Finding F4: omitted backup cohort is live, not snapshotted

**Path**:

1. Empty `spec.collections` executes LIST on every reconcile (`solrbackup_controller.go:246-256`).
2. The controller iterates only the latest LIST response (`:258-264`).
3. Previously created `CollectionBackupStatuses` are never removed; aggregation requires every stored entry to be finished (`backup_util.go:60-75`).

**Trigger**: create/delete a collection while an ordinary "all collections" backup is running, or observe an eventually inconsistent LIST across Solr state changes.

**Harm**: a deleted collection's unfinished status can never be polled again and freezes the run/recurrence; a newly created collection can join a run after its recorded start time, violating a stable backup cohort.

**Contract**: "If you don't specify the collections field, every available SolrCloud collection will be backed up" is naturally tied to initiation; status has one run start time/history entry.

**Compensation checked**: neither start status nor annotations store the initial LIST; `UpdateStatusOfCollectionBackups` cannot terminalize orphaned entries. Recreating the CR is external/manual recovery.

**Disposition**: MC-4, Scenario 3.

### 3.4 Finding F5: async task cleanup and durable backup completion are reordered

The collection status is marked finished in memory and DELETESTATUS is issued before the top-level CR status patch. A DELETESTATUS failure is returned, but the finished collection entry is still copied into status; on the next reconcile aggregate completion returns early and cleanup is not retried. Conversely, DELETESTATUS success followed by status-patch conflict loses the only terminal evidence, the race described in #506.

**Trigger**: one transient DELETESTATUS failure or one status conflict after a completed backup.

**Harm**: task records leak; recurrence reuses stable request IDs (`backupName-collection`) and can be rejected or wedge; up to 10,000 Solr async responses are retained unless deleted.

**Compensation checked**: no cleanup-pending field/finalizer exists. Scale/update helpers do keep operations nonterminal when cleanup fails, confirming path inconsistency.

**Disposition**: TV-6, Scenario 3 evidence; no MC answer-key reproduction of #506/#824.

### 3.5 Finding F6: partial BasicAuth Secret creation silently changes intended identity

**Path**:

1. Missing generated credential Secret causes generation of credential and bootstrap objects.
2. Credential Secret is created first; bootstrap Secret second (`solr_security_util.go:95-124`).
3. A failure between creates returns an error. On retry, credential Secret exists, so creation block is skipped.
4. Missing bootstrap Secret is explicitly tolerated (`:131-146`), producing `SecurityConfig` with credentials but empty SecurityJson.
5. `generateZKInteractionInitContainer` omits the security.json command when empty (`solr_util.go:1304-1307`); pods can start and status can become Ready.

**Trigger**: one transient API error, quota/admission rejection, or process crash after the first create.

**Harm**: CR requests BasicAuth but managed Solr starts without the intended security.json; operator status has no condition exposing the partial bootstrap.

**Contract**: API/docs promise generated credentials plus default security.json when BasicAuth is requested without a supplied Secret.

**Compensation checked**: deleting the credential Secret manually forces regeneration, but no automatic path repairs only the missing bootstrap Secret. Secret ownership watches merely cause the same skip on retry.

**Disposition**: MC-5, Scenario 4.

### 3.6 Finding F7: cross-namespace exporter references miss change events

Lookup honors the explicit referenced namespace (`solrprometheusexporter_controller.go:285-299`), but the field index contains only cloud name and the watch handler lists exporters in the changed cloud's namespace (`:393-436`). An exporter in namespace A referring to a cloud in B is absent from that list.

**Trigger**: supported cross-namespace reference, then change the cloud's ZK connection status or image.

**Harm**: exporter Deployment retains stale ZK/image identity; status remains Ready because it checks only the old Deployment's ready replica count.

**Compensation checked**: no periodic requeue is guaranteed; owned Deployment events do not occur merely because the referenced cloud changed. A manual exporter edit or unrelated Deployment event may eventually repair it.

**Disposition**: TV-1; Scenario 5.

### 3.7 Finding F8: custom CA is installed in the server-side TLS field

`buildTLSTransport` calls the operator's CA input a root CA but writes the pool to `tls.Config.ClientCAs` (`main.go:328-345`). Go's primary API contract states clients verify servers with `RootCAs`; `ClientCAs` is used by servers to verify client certificates. Issue #255 originally suggested the wrong field, explaining the historical origin but not fixing the behavior.

**Trigger**: supported operator flags with `tls-skip-verify-server=false` and a Solr server certificate rooted only in the supplied CA.

**Harm**: all global mTLS Admin API calls reject the server certificate, blocking cluster operations/backups across clouds using that operator.

**Compensation checked**: it works only if the CA is already in host system roots or skip-verify is true, which defeats the purpose of the custom CA flag. No later code copies `ClientCAs` to `RootCAs`.

**Disposition**: TV-2; do not model Go TLS internals.

### 3.8 Finding F9: scale-to-zero volume backup panics before readiness rejection

Scale-to-zero is documented and implemented. At stable zero, `GetAllSolrPodNames` returns an empty slice (`solrcloud_types.go:1226-1243`). Volume backup preparation indexes element zero (`backup_util.go:145-154`) before `reconcileSolrCloudBackup` checks repository readiness (`solrbackup_controller.go:223-237`).

**Trigger**: ordinary `SolrCloud.spec.replicas=0` plus a volume repository and a SolrBackup CR.

**Harm**: reconcile panic/recovery loop instead of a terminal or retryable not-ready status.

**Compensation checked**: remote repositories skip exec and do not panic; status readiness is too late for volume repositories. No length guard exists.

**Disposition**: TV-3.

### 3.9 Finding F10: exact values are not escaped at XML boundaries

S3 `endpoint` and `proxyUrl`, buckets/regions, repository names, modules, and library paths are interpolated into XML with `fmt.Sprintf` (`solr_backup_repo_util.go:123-154`; `solr_util.go:895-930`). A normal URL query containing `&` changes XML parsing semantics. The generated ConfigMap hash correctly causes a rollout, so it propagates the malformed value consistently rather than rejecting it.

**Harm**: new pods fail to parse `solr.xml`, blocking convergence and potentially reducing availability during update.

**Disposition**: TV-4. Probe-path JSON construction was reviewed too, but deliberately quote-bearing probe paths are self-conflicting and were not retained separately.

### 3.10 Finding F11: V1 Solr calls are unbounded and ignore reconcile cancellation

`CallCollectionsApi` uses `http.NewRequest`, not `NewRequestWithContext`, and the shared clients have zero `http.Client.Timeout`; the cloned default transport has no response-header timeout (`solr_api/api.go:144-190`). The V2 path at least attaches context (`v2.go:41-97`).

**Trigger**: a Solr endpoint accepts a connection but never returns headers/body during CLUSTERSTATUS, backup, REQUESTSTATUS, DELETESTATUS, or REPLACENODE.

**Harm**: the controller worker can remain blocked indefinitely; default worker count is one per controller, so one managed cloud can block other resources handled by that controller.

**Compensation checked**: default dial timeout does not bound a server that accepted the connection; reconcile context has no effect because it is not attached. No client/transport timeout is set elsewhere.

**Disposition**: TV-5.

### 3.11 Code-review-only residuals

- **CR-1 PKCS12 key/path mismatch**: CR uses a `SecretKeySelector` and verification checks the selected key, but runtime keystore path is always `keystore.p12`. Existing tests use only the fixed key and contain commented-out key assertions.
- **CR-2 mounted TLS assignment**: `solr_tls_util.go:634-637` assigns both fallback strings to `exportClientKeystorePassword`; whether this is observable depends on Solr's defaulting when no separate client cert exists.
- **CR-3 status snapshot suppression**: `createCloudStatus` output is discarded whenever StatefulSet/pod-derived counts disagree (`solrcloud_controller.go:477-488`); open PR #722 confirms users need generation-aware status.
- **CR-4 incomplete TLS dependency watches**: SolrCloud indexes PKCS12 Secrets but not separate truststore or password Secrets; exporter watches keystore/truststore but not password Secret refs. Runtime reload semantics must determine the required restart set.

## 4. Explicit exclusions and false positives

| Candidate | Exclusion reason |
|---|---|
| `math/rand` bootstrap passwords | repository threat model already classifies as known hardening/non-finding; no new contract evidence |
| default `InsecureSkipVerify=true` | explicitly documented/disclaimed install-time posture; no new implementation bypass |
| broad ClusterRole, pods/exec, missing webhook | designed authority/policy responsibility unless a concrete cross-boundary action exists |
| arbitrary pod volumes/images/security context | pass-through Kubernetes options explicitly out of operator threat scope |
| negative replicas | downstream Kubernetes validation rejects; no silent harmful state verified |
| one-node/RF=1 rolling downtime alone | maintainer discussion #66 acknowledges unavoidable downtime; no new information |
| 1-node ephemeral update data loss | project provides no persistence promise for ephemeral storage; deliberate topology limitation |
| external/internal addressability identity transition | implementation and E2E support transition, but no real Solr consumer harm was confirmed in this phase; defer to integration validation rather than assert |
| provided BasicAuth Secret not directly watched | every later API-using reconcile fetches current Secret; no dependent mutation is necessarily required at change time |
| `otherVersions[0]` status choice | can be nondeterministic in mixed-version status but no material application harm beyond imprecision |
| stale per-node Services after scale-down | documented cleanup omission; empty-selector services do not route traffic, and no concrete harm was found |
| custom probe path JSON quoting | requires deliberately self-conflicting path input; no demonstrated trust-boundary harm distinct from pod customization |
| PR #844 location shell path | real, but already known with an exact open fix; reference only |
| #707 scale-down no-requeue and #824 backup notfound | real/open, but answer keys; retained solely as evidence for generalized mechanisms |
| #659/#720/#755 security bootstrap failures | fixed/known, so excluded from MC targets; evidence for Scenario 4 only |

## 5. Scenario synthesis and handoff decisions

The retained Scenarios are grouped by mechanism, not file:

1. **Replica semantics vs count availability** — MC-1.
2. **Nonterminal operations without a future event/retry** — MC-2/MC-3, generalized beyond #707.
3. **Backup cohort/evidence durability** — MC-4; known notfound/cleanup bugs remain evidence/test targets.
4. **Multi-object identity bootstrap atomicity** — MC-5.
5. **Reference-event delivery** — primarily TV-1, optional small model extension.

Every concrete candidate is preserved in `modeling-brief.md` under Model-Checkable, Test-Verifiable, Code-Review-Only, or an explicit exclusion above.

## 6. Recommended next-phase order

1. Build the smallest spec containing one shard, typed replicas, pod update selection, and leader election; run MC-1 first.
2. Add the annotation lock/retry obligation and check MC-2/MC-3 without backup state.
3. Build backup as a separate module with frozen cohort and task-record loss; check MC-4.
4. Model BasicAuth bootstrap separately; do not combine it with replica/update state until MC-5 is resolved.
5. In parallel, add deterministic Go/envtest cases TV-1 through TV-6. These tests can confirm or remove non-model findings before Phase 4 reproduction.

## 7. Primary references

- In-repo contracts: `THREAT_MODEL.md`; `docs/modules/solr-cloud/pages/{cluster-operations,managed-updates,scaling,addressability,authentication-and-authorization,tls,zookeeper}.adoc`; `docs/modules/solr-backup/pages/{index,backup-repositories}.adoc`; `docs/modules/solr-prometheus-exporter/pages/index.adoc`.
- Official Solr: <https://solr.apache.org/guide/solr/latest/deployment-guide/solrcloud-shards-indexing.html>; <https://solr.apache.org/guide/solr/latest/configuration-guide/collections-api.html>; <https://solr.apache.org/guide/solr/latest/deployment-guide/collection-management.html>.
- Official Go: <https://pkg.go.dev/crypto/tls>; <https://pkg.go.dev/net/http>.
- History: #707, #824, #506, #547, #682, #688, #659, #720, #755, #822; PRs #596, #844, #569, #722, #744, #461, #826, #827.

## 8. Deliverable validation

- Both requested files exist and are non-empty.
- `modeling-brief.md` is 191 lines, within the skill's 100-200 line target, and contains all seven required sections plus explicit Category A classification.
- `analysis-report.md` records all required breadth surfaces, source/history/issue/PR coverage statistics, exact source references, compensating-mechanism checks, retained dispositions, and explicit exclusions.
- `git diff --check` passed for the source worktree; no source file was edited. The pre-existing untracked `.codex/` directory was left untouched.
- A targeted test command was attempted: `go test ./api/v1beta1 ./controllers/util ./controllers .`.
- The test command could not run because this environment has no `go` executable and no local `golang` container image. No dependency/toolchain installation was performed, and the report does not claim tests passed.
