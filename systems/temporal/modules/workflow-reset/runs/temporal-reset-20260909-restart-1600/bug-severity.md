# Severity Classification — temporal-reset

## Summary

- Total entries: 6
- Reproduced bugs: 3
- Severity-bearing findings: 0
- Critical: 2
- High: 1
- Medium: 0
- Low: 0
- No-severity dispositions: 3

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | Critical | Public Start or Reset can acknowledge a run with permanently missing or incomplete history when the scanner minimum age is shorter than the SQL history-to-metadata publication window. Retries do not restore the acknowledged run's history; the default 60-day minimum age prevents the demonstrated deletion. |
| 2 | MC-2 | REPRODUCED | Critical | Repeating an identical public Reset request, including after response loss, creates a second run and durably terminates the first instead of returning its identity. Although the demonstrated damage is confined to the reset operation, the acknowledged result is permanently replaced and no downstream recovery restores it. |
| 3 | CR-2 | FALSE POSITIVE | — | The Phase 4 FALSE POSITIVE disposition is not severity-bearing; the recorded retry after shard reload repaired the split state and completed the reset run. |
| 4 | CR-3 | FALSE POSITIVE | — | The Phase 4 FALSE POSITIVE disposition is not severity-bearing; persistence rejected the stale create and normal retry completed the overlapping Reset without the claimed corrupt outcome. |
| 5 | CR-4 | REPRODUCED | High | Public Reset returns Internal when reapplication merges Continue-As-New source runs that legitimately reused an Update ID, preventing that reset from succeeding. The demonstrated external harm is the failed Reset operation, with no downstream mechanism resolving the collision. |
| 6 | CR-5 | FALSE POSITIVE | — | The Phase 4 FALSE POSITIVE disposition is not severity-bearing; the tested child-completion and deletion consumers observed no wrong outcome, and reset history survived base deletion. |
