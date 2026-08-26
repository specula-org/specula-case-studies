# Modeling-brief coverage audit

This audit was filled from the final `MC_hunt_*.cfg` files, not from the intended design. The brief is the coverage source. The model is Category A and covers Scenarios 1–4; Scenario 5 is explicitly retained as the brief's test-verifiable `TV-1` rather than represented by an artificial TLA+ dependency-watch extension.

## Required source breadth audit

| Required surface | Production paths inspected | Handoff disposition |
|---|---|---|
| SolrCloud scale up/down, managed updates, addressability transitions, and cluster-operation locks | `controllers/solrcloud_controller.go:470-649,706-774`; `controllers/solr_cluster_ops_util.go`; `controllers/solr_pod_lifecycle_util.go`; `controllers/util/solr_scale_util.go`; `controllers/util/solr_update_util.go`; `api/v1beta1/solrcloud_types.go:1330-1487` | Typed-replica update safety is S1; lost future-work ownership is S2. Addressability transitions were inspected through staged service cleanup and advertised-node derivation and retained outside the primary four bounded Scenarios where no independent trace extension was justified. |
| SolrBackup target selection, repository preparation, sync/async lifecycle, recurrence, and cleanup | `controllers/solrbackup_controller.go`; `controllers/util/backup_util.go`; `controllers/util/solr_backup_repo_util.go`; `api/v1beta1/solrbackup_types.go` | Dynamic target cohort and terminal-evidence ordering are S3. Stable scale-to-zero repository preparation and local rendering concerns remain test-verifiable rather than folded into S3. |
| Solr Admin APIs, preconditions, terminal responses, retries, timeouts, and version gates | `controllers/util/solr_api/api.go`, `errors.go`, `v2.go`, `cluster_status.go`; callers in scale/update/backup utilities | S2/S3 preserve distinct REQUESTSTATUS, submit, completion, DELETESTATUS, retry, and unsupported-version outcomes. V1 context/timeout behavior remains a dedicated test-verifiable hypothesis. |
| Generated `solr.xml`, `security.json`, JVM/environment options, shell/exec arguments, and exact-value rendering | `controllers/util/solr_util.go:89-461,725-929,1271-1388`; `controllers/util/solr_backup_repo_util.go:123-208`; `controllers/util/solr_security_util.go:248-455`; `controllers/util/solr_tls_util.go:340-724` | BasicAuth generation/application is S4. XML, PKCS12, mounted-TLS, JVM/env, and shell rendering hypotheses remain explicit test/code-review items because a local consumer test is more faithful than an artificial message-passing extension. |
| BasicAuth, TLS/mTLS, ZooKeeper identity/ACLs, referenced Secrets/ConfigMaps, and multi-cloud isolation | `controllers/util/solr_security_util.go`; `controllers/util/solr_tls_util.go`; `controllers/util/zk_util.go`; SolrCloud/exporter reference and watch setup; `api/v1beta1/common_types.go:289-343` | Two-Secret/ZK BasicAuth staging is S4. Cross-namespace exporter observation is retained as TV-1; other Secret/TLS watch and exact-path questions remain explicit test/code-review hypotheses. |
| Status truthfulness and convergence for SolrCloud | `controllers/solrcloud_controller.go:477-488,841-968` | Ready-vs-installed BasicAuth is S4; pod/StatefulSet snapshot disagreement remains code-review/test coverage. |
| Status truthfulness and convergence for SolrBackup and SolrPrometheusExporter | `controllers/solrbackup_controller.go:94-184`; `controllers/solrprometheusexporter_controller.go:215-276` | Backup working/durable status is S3. Exporter `ReadyReplicas > 0` and missed dependency events remain TV-1/code-review coverage, not an invented TLA+ state machine. |

## Brief §2 scenarios

| Scenario | Spec mechanism | Targeting hunt cfg(s) | Disposition |
|---|---|---|---|
| S1 managed update / leader eligibility | `GetNodeReplicaState`, `DeterminePodsSafeToUpdate`, readiness removal, deletion, recovery/election; replica types remain visible although selection ignores them | `MC_hunt_s1_managed_update.cfg` | Covered |
| S2 lost cluster-operation future | Handler return values, real async state, dispatcher error clearing, retry/event/queue ownership | `MC_hunt_s2_rolling_error.cfg`; `MC_hunt_s2_balance_check_error.cfg`; `MC_hunt_s2_balance_submit_error.cfg` | Covered; distinct handler sites remain separate |
| S3 backup cohort/evidence durability | Dynamic LIST cohort, per-collection working/durable status, task record, DELETESTATUS, status patch/conflict, recurrence | `MC_hunt_s3_backup_cohort.cfg`; `MC_hunt_s3_backup_progress.cfg`; `MC_hunt_s3_backup_cleanup.cfg` | Covered; cohort, progress, and cleanup hypotheses remain separate |
| S4 BasicAuth two-Secret bootstrap | Separate Secret creates, failed second create, controller retry, missing-bootstrap lookup, pod template, ZK install, readiness status | `MC_hunt_s4_basic_auth.cfg` | Covered |
| S5 cross-namespace exporter watch | No TLA+ extension | None | Intentionally test-only: brief §2 says controller test is cheaper, §3.1 excludes it from “Model”, and §6.2 records it as `TV-1` |

## Brief §5 proposed invariants

`NonterminalOpHasFuture` and `BackupEventuallyTerminal` are liveness requirements encoded as finite-state progress-obligation predicates for the hunt configs. Temporal companions (`NonterminalOpEventuallyTerminal`, `BackupTerminationLiveness`) are also defined in `base.tla` but left disabled until a later phase supplies fairness assumptions.

| Brief invariant | Kind | Defined | Wired through MC | Enabled in actual cfg |
|---|---|---|---|---|
| `WriteAvailabilityBudget` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_s1_managed_update.cfg` |
| `NonterminalOpHasFuture` | Bounded liveness obligation | `base.tla` | inherited by `MC.tla` | all three `MC_hunt_s2_*.cfg` files |
| `OneActiveClusterOp` | Safety/core | `base.tla` | inherited by `MC.tla` | every hunt cfg and `MC.cfg` |
| `BackupCohortStable` | Safety design oracle | `base.tla` | inherited by `MC.tla` | Refined during hunting: broad membership drift lacked concrete harm and is not counted as independent coverage |
| `SubmittedBackupRemainsInCohort` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_s3_backup_cohort.cfg`; requires an already-submitted collection to be dropped before violation |
| `BackupEventuallyTerminal` | Bounded liveness obligation | `base.tla` | inherited by `MC.tla` | `MC_hunt_s3_backup_progress.cfg` |
| `CleanupAfterDurableTerminal` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_s3_backup_cleanup.cfg` |
| `ReadyBasicAuthIsInstalled` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_s4_basic_auth.cfg` |

No §5 invariant is only defined/commented without an enabling hunt cfg.

## Brief §6.1 model-checkable findings

| Finding | Reachable trigger in cfg | Expected violation | Targeting hunt cfg(s) | Bounded check result |
|---|---|---|---|---|
| MC-1 | one managed-update start; other scenarios disabled | `WriteAvailabilityBudget` | `MC_hunt_s1_managed_update.cfg` | Violated after selection and readiness removal of the NRT pod |
| MC-2 | one rolling lock plus one CLUSTERSTATUS failure | `NonterminalOpHasFuture` | `MC_hunt_s2_rolling_error.cfg` | Violated after dispatcher clears the handler error |
| MC-3 status failure | one balance lock plus one REQUESTSTATUS failure | `NonterminalOpHasFuture` | `MC_hunt_s2_balance_check_error.cfg` | Violated after dispatcher clears the handler error |
| MC-3 submission failure | one balance lock, notfound response, one submission failure | `NonterminalOpHasFuture` | `MC_hunt_s2_balance_submit_error.cfg` | Violated after dispatcher clears the handler error |
| MC-4 cohort change | one run, one successful submission, then one delete/relist transition | `SubmittedBackupRemainsInCohort` | `MC_hunt_s3_backup_cohort.cfg` | Violated only when relisting drops an already-submitted collection from future polling |
| MC-4 stranded recurrence | one run plus one collection deletion; normal remaining work enabled | `BackupEventuallyTerminal` | `MC_hunt_s3_backup_progress.cfg` | Violated when an old submitted status is outside the relisted cohort and no semantic progress remains |
| MC-5 | one BasicAuth request plus one second-Secret create failure; no manual repair/external ZK change | `ReadyBasicAuthIsInstalled` | `MC_hunt_s4_basic_auth.cfg` | Violated after retry generates a pod without setup-zk security and readiness is reported |

The additional `MC_hunt_s3_backup_cleanup.cfg` targets the independent S3 §5 safety invariant. It reaches DELETESTATUS before the CR status patch and violates `CleanupAfterDurableTerminal`; it is not counted as a separate §6.1 finding.
