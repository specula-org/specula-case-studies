# Severity Classification — etcd-raft V02

## Summary

- Total entries: 8
- Reproduced bugs: 2
- Severity-bearing findings: 0
- Critical: 0
- High: 2
- Medium: 0
- Low: 0
- No-severity dispositions: 6

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | CR-1 | FIXED | — | The persistent restart defect is verified fixed on this revision, so this disposition is not severity-bearing. |
| 2 | CR-2 | NEEDS MORE INFO | — | The current public-interface consequence was not established, so this disposition has no severity. |
| 3 | CR-3 | REPRODUCED | High | Public Node calls can commit a second membership change before the first is applied, exposing externally driven membership serialization failure at the Ready/Advance boundary. |
| 4 | CR-4 | DROPPED | — | The historical duplicate disposition is not severity-bearing. |
| 5 | CR-5 | NEEDS MORE INFO | — | The earlier read consequence was not re-established through the current public APIs, so this disposition has no severity. |
| 6 | CR-6 | FIXED | — | The retained public-interface control verifies that the request appears after quota release, so this fixed disposition is not severity-bearing. |
| 7 | MC-1 | FIXED | — | The current restart path preserves the complete joint configuration and both quorum halves, so this fixed disposition is not severity-bearing. |
| 8 | MC-2 | REPRODUCED | High | A valid public-protocol recovery snapshot is rejected for an outgoing-only joint voter, which can block quorum-backed progress after compaction when that voter is needed by the outgoing majority. |

