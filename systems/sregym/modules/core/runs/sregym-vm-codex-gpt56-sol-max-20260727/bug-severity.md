# Severity Classification — sregym

## Summary

- Total entries: 6
- Reproduced bugs: 5
- Severity-bearing findings: 1
- Critical: 5
- High: 1
- Medium: 0
- Low: 0
- No-severity dispositions: 0

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | Critical | A queued `POST /submit` can be admitted after the exit snapshot, so cleanup races the evaluation and permanently publishes a grade-less result while `/status` reopens `mitigation` for an undeployed app. This is externally visible state and result corruption with no automatic repair. |
| 2 | MC-2 | REPRODUCED | Critical | A delayed duplicate `POST /submit` from diagnosis can cross the mutable stage boundary and be graded as mitigation, finalizing the run with a false mitigation result and rejecting the legitimate later submission. The stored benchmark outcome is permanently corrupted with no recovery path. |
| 3 | MC-3 | REPRODUCED | Critical | After process restart against a replacement cluster, normal baseline reconciliation accepts the prior cluster's cache and permanently deletes legitimate namespaces and RBAC while overwriting CoreDNS. These destructive cluster-state changes are externally visible and are not automatically restored. |
| 4 | MC-4 | MASKED | High | After a target container restarts, `/status` and `/submit` expose diagnosis while the replacement PID is fault-free, allowing an accepted diagnosis against an invalid benchmark state. The `_FaultReinjectionMonitor` is the named mask that reattaches the probe after the polling interval; absent that mask, the fault-free diagnosis state would persist. |
| 5 | CR-3 | REPRODUCED | Critical | A transient Kubernetes list failure during public baseline capture is persisted as an authoritative empty set, so subsequent cleanup permanently deletes a legitimate ClusterRole. Normal reconciliation neither recreates the role nor otherwise repairs the externally visible configuration loss. |
| 6 | CR-4 | REPRODUCED | Critical | `NoiseManager.stop()` can return while an accepted Chaos apply is still running, allowing late noise to make a target unready during `SustainedReadinessOracle.evaluate()`. Although later cleanup removes the Chaos resources, the false evaluation result remains stored for the stage, creating permanent externally visible result corruption. |
