# Apache Solr Operator

## Scope

Specula analyzed the Apache Solr Operator's reconciliation boundary with
Kubernetes and managed SolrCloud instances. The reviewed runs cover managed
updates and scale operations, SolrBackup asynchronous lifecycle and cleanup,
generated BasicAuth initialization, cross-namespace exporter references, and
the truthfulness and convergence of public status.

All reviewed results target
[`apache/solr-operator@ed5c5c7d28a4c1189d19f581259e05385c0d4b20`](https://github.com/apache/solr-operator/tree/ed5c5c7d28a4c1189d19f581259e05385c0d4b20).

## Reviewed findings

The [independent review](modules/operator-application/runs/solr-broad-prompt-v2-20260824b/review/independent-review.md)
retains six reportable bug mechanisms: five reproduced bugs and one
environment-limited finding.

| Finding | Status | Reviewed impact |
| --- | --- | --- |
| Scale-down submits `REPLACENODE` when fewer than two Solr nodes are live and repeatedly receives an opaque 400. | `REPRODUCED` | The scale-down operation and its lock can livelock until another destination node becomes live. |
| Managed update can remove the only active NRT/TLOG replica while a PULL replica remains active. | `ENV_LIMITED` | The supported topology can lose shard write availability because PULL replicas cannot become leaders. |
| Relisting collections can drop an already-submitted collection from SolrBackup polling. | `REPRODUCED` | The backup and its recurrence remain nonterminal after the collection is deleted normally. |
| `DELETESTATUS` can destroy the only terminal async record before SolrBackup status is durable. | `REPRODUCED` | Controller loss in the ordering window leaves the backup polling `notfound` indefinitely. |
| A partial generated-BasicAuth Secret creation can be treated as complete on the next reconcile. | `REPRODUCED` | Solr can become Ready without the requested BasicAuth configuration in ZooKeeper. |
| A referenced SolrCloud change does not enqueue a cross-namespace exporter. | `REPRODUCED` | The live exporter Deployment retains an old image and ZooKeeper target while its public status remains Ready. |

Five mechanisms were not described by a matching upstream issue in the reviewed
snapshot. The backup `notfound` consumer is already reported in
[#824](https://github.com/apache/solr-operator/issues/824); this study adds a
distinct controller-loss trigger that reaches that unresolved terminal state.

## Runs and evidence boundary

- [`solr-0`](modules/operator-application/runs/solr-0/README.md) is the earlier
  Copilot/Claude Opus 4.8 run and contributes the scale-down `REPLACENODE`
  finding.
- [`solr-broad-prompt-v2-20260824b`](modules/operator-application/runs/solr-broad-prompt-v2-20260824b/README.md)
  is the broader Codex `gpt-5.6-sol` run and contains the shared model, traces,
  reviews, and consolidated public reproduction runner.
- [`solr-broad-prompt-v2-repro55-20260825`](modules/operator-application/runs/solr-broad-prompt-v2-repro55-20260825/README.md)
  is a scoped `gpt-5.5` confirmation supplement for two findings interrupted in
  the main run. It is not a separate full pipeline execution.

The reproductions exercise real operator control paths with deterministic Solr
transports, fake Kubernetes clients, or envtest. They are implementation-level
evidence, not six live-cluster end-to-end demonstrations. The managed-update
leader-eligibility result remains explicitly `ENV_LIMITED` because this local
confirmation did not execute a real client write against a live SolrCloud.

The public count excludes one masked retry-delay finding and three earlier
calibration cases that were supplied to `solr-0` as known-good grounding rather
than generated blindly.
