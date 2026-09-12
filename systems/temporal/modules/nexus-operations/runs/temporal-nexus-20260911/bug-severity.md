# Severity Classification — temporal-nexus

## Summary

- Total entries: 5
- Reproduced bugs: 3
- Severity-bearing findings: 0
- Critical: 3
- High: 0
- Medium: 0
- Low: 0
- No-severity dispositions: 2

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | CR-1 | REPRODUCED | Critical | After a workflow's Nexus start response is lost and a retry persists a different operation token, the completion handler accepts the earlier token's callback when the request ID matches, permanently recording its stale result for the workflow consumer. No downstream mechanism rewrites this terminal result; reaching the conflicting-token condition depends on the endpoint accepting distinct operations for the retried request. |
| 2 | CR-2 | REPRODUCED | Critical | A public workflow that requests cancellation while the Nexus start response is delayed can lose its start-to-close timer, leaving the workflow waiting indefinitely if the operation never completes after cancellation acknowledgment. The report observed the workflow running past its deadline with no persisted timer; explicit administrator task refresh restored the timeout, but is not an automatic safeguard. |
| 3 | CR-3 | DROPPED | — | Phase 4 assigned DROPPED to this previously reported terminal-node cleanup defect; that disposition is not severity-bearing. |
| 4 | CR-4 | REPRODUCED | Critical | A workflow scheduling a Nexus operation without either a schedule-to-close timeout or a workflow run timeout bypasses the configured maximum and generates no operation timeout task, permitting an operation that never completes to leave its caller waiting indefinitely. The report establishes no downstream enforcement of that maximum in this configuration; a configured workflow run timeout can mask the missing bound. |
| 5 | CR-5 | FALSE POSITIVE | — | Phase 4 assigned FALSE POSITIVE because buffered completion and cancellation remain coherent after uncertain commit and reload; that disposition is not severity-bearing. |
