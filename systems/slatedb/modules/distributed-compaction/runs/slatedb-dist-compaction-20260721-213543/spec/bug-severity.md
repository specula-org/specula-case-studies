# Severity Classification — slatedb-dist-compaction

## Summary

- Total entries: 5
- Reproduced bugs: 1
- Findings: 1
- Critical: 1
- High: 1
- Medium: 0
- Low: 0
- No-severity dispositions: 3

## Per-entry classification

| Bug | Title | Status | Severity | Reasoning |
|-----|-------|--------|----------|-----------|
| 1 | Submitted backlog can exceed the configured running-compaction bound | REPRODUCED | High | Real admin-submitted external compactions can push two workers past a global `max_concurrent_compactions = 1`, and the next coordinator poll panics from unsigned underflow. The impact is an externally observable compactor crash/liveness failure on a reachable standalone coordinator/worker deployment, but it is bounded to the compaction service rather than irreversible data loss. |
| 2 | External `Submitted` compactions may bypass coordinator admission checks | MASKED | Critical | Without the commit-time destination-overwrite validation that currently marks the loser `Failed`, externally submitted cross-segment compactions can reserve and publish the same destination SR for unrelated inputs through the admin submission path. That consequence is persistent client-visible corruption of compaction output, even though the current mask prevents it from escaping. |
| 3 | Crash windows between manifest and `.compactions` writes may break recovery safety | FALSE POSITIVE | — | Phase 4 marked this a false positive: the reproduced crash window preserved manifest correctness and GC safety on restart, so it is not severity-bearing. |
| 4 | Reclaim and heartbeat races may let stale executions act after ownership moves | FALSE POSITIVE | — | Phase 4 marked this a false positive: the real executor suppresses stale post-stop completion, so there is no live impact-bearing bug to classify. |
| 5 | Independent refresh and merge of manifest and `.compactions` may admit stale state | DROPPED | — | Phase 4 dropped this as a known upstream-fixed duplicate of PR `#1840`, so it carries no Phase 4b severity. |
