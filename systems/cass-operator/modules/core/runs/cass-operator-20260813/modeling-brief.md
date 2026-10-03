# Modeling brief

## Scope

The model covers cass-operator's reconciliation of CassandraDatacenter deletion, scale-down, node startup, PodDisruptionBudget updates, maintenance tasks, and finalizer cleanup. Kubernetes resources and Cassandra management-API responses are modeled as asynchronous observations, with operator restart and transient API failure as admissible faults.

## Reviewed scenarios

| Scenario | Property checked |
| --- | --- |
| Same-name datacenter recreation during stale deletion | Storage mutations remain scoped to the correct object generation. |
| Decommission under missing or failed ring metadata | Storage is removed only after authoritative node departure. |
| Decommission with missing load information | Capacity approval requires known load for the leaving node. |
| Maintenance submission across checkpoint failure | One logical task does not create multiple untracked remote jobs. |
| Node startup across operator restart | A lost request cannot leave a pod permanently stuck in `Starting`. |
| Scale-up before disruption-budget refresh | Voluntary disruption does not reduce availability below the intended floor. |
| Datacenter deletion after dependency removal | Missing dependencies cannot permanently block finalizer removal. |

The trace harness maps reconcile actions, Kubernetes resource mutations, management-API observations, and durable status updates into these scenario states. Model-checking outputs under `spec/output/` contain the corresponding invariant counterexamples.
