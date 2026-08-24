# cass-operator

## Scope

Specula analyzed cass-operator's CassandraDatacenter reconciliation and CassandraTask execution, including datacenter deletion, scale-down and decommissioning, node startup, disruption-budget updates, maintenance jobs, and finalizer recovery.

## Bugs

The independent review of the [2026-08-13 run](modules/core/runs/cass-operator-20260813/review/independent-review.md) records **4 new bugs and 3 previously known, unfixed bugs**:

- A transient management-API failure can make an active node appear fully decommissioned, leading the operator to remove its storage.
- Missing load data is treated as zero, allowing an unsafe scale-down to bypass the capacity check.
- A failed status checkpoint can submit the same asynchronous maintenance job twice and orphan the first job.
- An operator restart can leave a pod permanently stuck in `Starting` after its start request is lost.
- **Known:** a stale deletion view can delete storage belonging to a newly recreated datacenter ([issue #118](https://github.com/k8ssandra/cass-operator/issues/118)).
- **Known:** the PodDisruptionBudget remains stale during scale-up, weakening voluntary-disruption protection ([issue #741](https://github.com/k8ssandra/cass-operator/issues/741)).
- **Known:** deleting a required secret first can prevent finalizer removal and leave a datacenter stuck terminating ([issues #812](https://github.com/k8ssandra/cass-operator/issues/812) and [#952](https://github.com/k8ssandra/cass-operator/issues/952)).

The reproductions exercise the operator implementation with fake Kubernetes and management-API clients. They confirm the affected control paths but are not live-cluster end-to-end tests.
