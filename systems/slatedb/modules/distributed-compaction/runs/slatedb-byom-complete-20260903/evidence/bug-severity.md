# Severity Classification — slatedb-byom-complete

## Summary

- Total entries: 7
- Reproduced bugs: 4
- Severity-bearing findings: 0
- Critical: 0
- High: 4
- Medium: 0
- Low: 0
- No-severity dispositions: 3

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | High | Duplicate requests through the public compaction-submission API can schedule conflicting work and panic the normal worker, which surfaces a bounded `Closed(Panic)` failure to its caller. |
| 2 | MC-2 | REPRODUCED | High | Public submission plus supported standalone workers can run two compactions despite a coordinator limit of one, externally violating the configured global resource bound; the demonstrated harm is bounded to concurrent over-admission rather than persistent corruption. |
| 3 | MC-3 | REPRODUCED | High | Repeated public submissions and independent worker claims can place two jobs in `Running` while the coordinator limit is one, exposing the configured concurrency violation through the public administration API and live execution. |
| 4 | CR-2 | FALSE POSITIVE | — | This Phase 4 disposition is not severity-bearing; the exact crash-window state recovered safely in the reported test. |
| 5 | CR-3 | DROPPED | — | This Phase 4 disposition is not severity-bearing because the candidate duplicates a known bug whose fix is already present in the target commit. |
| 6 | CR-4 | DROPPED | — | This Phase 4 disposition is not severity-bearing because the candidate duplicates an upstream fix already present in the target commit. |
| 7 | CR-6 | REPRODUCED | High | A supported custom scheduler can leave a compacted L0 consuming capacity until later recompaction, causing a normal public memtable flush to time out; this is an externally visible but bounded liveness failure. |
