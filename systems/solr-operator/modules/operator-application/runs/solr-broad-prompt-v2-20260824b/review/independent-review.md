# Independent review

The reviewed public ledger contains six bug mechanisms: five reproduced bugs
and one environment-limited finding. Status is preserved from Phase 4; severity
describes the demonstrated or externally established consequence and does not
change an `ENV_LIMITED` result into a local reproduction.

| Stable finding | Origin | Status | Severity | Evidence and consequence |
| --- | --- | --- | --- | --- |
| Scale-down `REPLACENODE` live-node precondition | `solr-0` MC-1 | `REPRODUCED` | Critical | Level-2 implementation reproduction drives the real eviction helper and v1 client. The impossible operation can retain the scale-down lock and repeat until another destination node is live. |
| Managed-update leader-eligible availability | broad run MC-1, finalized by supplement | `ENV_LIMITED` | High | The operator selects the only NRT/TLOG replica while a PULL replica remains. The selection and readiness-removal paths reproduce; this local run did not execute the final failed client write against a live SolrCloud. |
| SolrBackup collection-cohort drift | broad run MC-3 | `REPRODUCED` | Medium | Level-0 public collection deletion plus the real Reconcile consumer leaves one submitted collection unpolled and permanently blocks completion and recurrence. |
| SolrBackup terminal-evidence cleanup ordering | broad run MC-4 | `REPRODUCED` | Medium | Level-1 controller cancellation after successful `DELETESTATUS` leaves durable status nonterminal and all later polls at `notfound`. |
| Generated-BasicAuth partial initialization | broad run MC-5, finalized by supplement | `REPRODUCED` | High | Level-2 partial-create state reaches the real retry, StatefulSet generation, and Ready calculation; requested authentication can be absent with no automatic repair. |
| Cross-namespace exporter watch mapping | broad run CR-5 | `REPRODUCED` | Medium | Envtest runs the production controller and a normal image update. The same-namespace control converges while the cross-namespace Deployment remains stale and publicly Ready. |

## Selection boundary

The ledger counts results that the two runs generated independently, including
mechanisms also present in an external Argus result set. External overlap does
not remove a Specula discovery from this case study.

The ledger excludes:

- the masked cluster-operation fast-requeue finding, because periodic
  controller-runtime resync eventually repairs the stalled operation;
- three `solr-0` calibration cases because the old prompt explicitly supplied
  their exact mechanisms as known-good grounding before candidate generation.

Those exclusions have different meanings. The masked item is a real but
secondary operational defect. Two seeded calibration mechanisms—backup
`notfound` nontermination and stale-`CLUSTERSTATUS` destructive scale-down—have
serious potential impact, but they are not independent blind discoveries from
that run. The seeded BALANCE_REPLICAS 404 fallback is additionally weakened by
explicit compatibility intent and lacks a comparably strong external
consequence.

## Validation limits

- `solr-0` MC-1 and generated-BasicAuth MC-5 use Level-2 implementation tests.
- The leader-eligibility finding remains `ENV_LIMITED` in the Specula report.
- The exporter envtest writes reachable controller-owned status preconditions;
  its decisive image update is a normal public CR update.
- Deterministic transports and fake clients preserve the operator control paths
  but do not substitute for six live Solr/Kubernetes deployments.
- The broad run's standard MC execution was time-bounded, and its spec review
  identified modeling defects. Every retained result therefore depends on its
  finding-local code confirmation rather than an exhaustive-model claim.
