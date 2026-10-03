# Independent review

The reviewed ledger contains seven implementation bugs: four new findings and three previously reported, unfixed bugs.

| ID | Ledger | Finding | Evidence |
| --- | --- | --- | --- |
| MC-1 | Known, unfixed | A stale deletion view can remove storage belonging to a newly recreated datacenter. | Reproduced against the target implementation; matches issue #118. |
| MC-2 | New | A transient metadata failure can be mistaken for completed decommission and trigger storage removal. | Reproduced with a management-API 500 response; healthy metadata retains the storage. |
| MC-3 | New | Missing load data defaults to zero and bypasses the scale-down capacity check. | Reproduced with an incomplete management-API snapshot; the known-load control rejects the same over-capacity operation. |
| MC-5 | New | A failed task-status checkpoint can submit a second maintenance job and orphan the first. | Reproduced through the task reconcile and cleanup submission path. |
| MC-6 | New | A lost start request after the durable `Starting` label can stall the datacenter indefinitely. | Reproduced across repeated recovery reconciles; the request is not retried and existing stuck-node cleanup does not fire. |
| MC-7 | Known, unfixed | Scale-up can proceed while the PodDisruptionBudget still carries the old availability floor. | Reproduced through the scale-up path and Kubernetes admission rule; matches issue #741. |
| MC-8 | Known, unfixed | A missing required secret can prevent deletion from reaching finalizer removal. | Reproduced through the public reconcile entry point; matches issues #812 and #952. |

The tests run against the operator code with fake Kubernetes and management-API clients. They are implementation-level reproductions, not live-cluster end-to-end demonstrations. In particular, MC-3 does not exercise a resulting disk-capacity failure, and MC-7 does not submit an eviction to a live API server.
