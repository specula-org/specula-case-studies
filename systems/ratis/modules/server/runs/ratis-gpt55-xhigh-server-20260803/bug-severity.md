# Severity Classification — ratis-server

## Summary

- Total entries: 5
- Reproduced bugs: 1
- Severity-bearing findings: 1
- Critical: 1
- High: 1
- Medium: 0
- Low: 0
- No-severity dispositions: 3

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | Critical | A public client/admin operation can receive success after the leader's async `FileChannel.force(false)` failed, because `flushIndex` and `commitIndex` advance and state-machine apply proceeds. Under that storage-force failure surface, an acknowledged configuration/log entry can become non-durable, enabling externally visible committed-entry loss or consistency failure after leader loss. |
| 2 | MC-2 | MASKED | High | If unmasked, a public linearizable `ReadIndex` read sent to an old partitioned leader could use lease evidence updated before `NOT_LEADER` handling and return stale state after a replacement leader committed newer data. The named mask is that the real run demoted the old server to follower and returned `ReadIndexException: Leader is unknown` instead of serving the lease read. |
| 3 | CR-2 | DROPPED | — | Phase 4 dropped this as a duplicate of already reported and fixed RATIS-1995, so the disposition is not severity-bearing. |
| 4 | CR-3 | DROPPED | — | Phase 4 dropped this as already reported and fixed by upstream snapshot and ReadIndex fixes, so the disposition is not severity-bearing. |
| 5 | CR-5 | FALSE POSITIVE | — | Phase 4 concluded the membership-guard behavior is intentional joint-consensus behavior, so this false-positive disposition has no severity. |
