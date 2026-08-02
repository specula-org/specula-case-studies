# Independent review

The original pipeline produced six candidate dispositions. All six are retained in the case-study ledger, with novelty and masking kept separate.

| ID | Ledger | Finding | Evidence |
| --- | --- | --- | --- |
| MC-1 | New | Teardown overlaps an admitted evaluation, and the published result loses its grade. | Reproduced; `/status` exposes mitigation after application cleanup. |
| MC-2 | New | A delayed diagnosis duplicate is accepted and graded as mitigation. | Reproduced; the legitimate mitigation is subsequently rejected. |
| MC-3 | Known, unfixed | A stale cluster-A baseline is accepted after cluster replacement and destructively reconciled onto cluster B. | Reproduced; matches PR #767. |
| MC-4 | Known, masked | Diagnosis remains available after a pod restart while the replacement PID has no injected fault. | Reproduced; the normal polling monitor later reattaches the fault. Matches issue #568. |
| CR-3 | New | A transient Kubernetes list failure is persisted as an authoritative empty baseline. | Reproduced; cleanup deletes a legitimate ClusterRole. |
| CR-4 | New | `NoiseManager.stop()` can finish before an accepted Chaos apply. | Reproduced; the late apply reaches readiness evaluation and leaves a false stored result. |

The original [confirmed-bugs.md](../confirmed-bugs.md) and [bug-severity.md](../bug-severity.md) remain unchanged as run evidence. `MASKED` describes MC-4's downstream repair; it does not erase the observed invalid diagnosis interval.
