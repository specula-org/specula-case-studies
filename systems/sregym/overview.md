# SREGym

## Scope

Specula analyzed SREGym's benchmark run lifecycle and submission evaluation, including stage transitions, result publication, cluster baseline capture and reconciliation, fault reinjection, noise application, readiness evaluation, and teardown cleanup.

## Bugs

The reviewed [2026-07-27 run](modules/core/runs/sregym-vm-codex-gpt56-sol-max-20260727/review/independent-review.md) records **4 new bugs and 2 previously known bugs**:

- Cleanup can start while submission evaluation is in flight, losing the grade from the published result and reopening mitigation after the application is removed.
- A delayed diagnosis duplicate can cross the mutable stage boundary and be graded as mitigation, finalizing a false result before the legitimate mitigation is submitted.
- A transient Kubernetes list failure during baseline capture can be persisted as an authoritative empty set, causing cleanup to delete legitimate cluster state.
- An accepted Chaos apply can complete after noise cleanup and affect readiness evaluation, leaving a false stored result.
- **Known:** a persisted baseline can be reused after cluster replacement and destructively reconcile the replacement cluster (PR #767).
- **Known, masked:** after a pod restart, diagnosis remains available while the replacement PID is temporarily fault-free; the normal reinjection monitor later restores the fault (issue #568).
