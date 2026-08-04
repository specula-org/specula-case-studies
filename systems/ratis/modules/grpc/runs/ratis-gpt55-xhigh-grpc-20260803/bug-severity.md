# Severity Classification — ratis-grpc

## Summary

- Total entries: 4
- Reproduced bugs: 0
- Severity-bearing findings: 1
- Critical: 0
- High: 1
- Medium: 0
- Low: 0
- No-severity dispositions: 3

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | MASKED | High | A stale gRPC `INCONSISTENCY` reply can move leader-side follower progress below the recorded snapshot boundary, suppressing append construction and losing proven catch-up progress for that follower. This is bounded replication/liveness harm, currently masked by `shouldInstallSnapshot()` / `GrpcLogAppender.run` retrying snapshot work and restoring `nextIndex`. |
| 2 | MC-2 | FALSE POSITIVE | — | Phase 4 marked the modeled staging restart reset as unreachable in current implementation because restart does not recreate staging-only follower state; this disposition is not severity-bearing. |
| 3 | CR-1 | FALSE POSITIVE | — | Phase 4 found the late gRPC `SUCCESS` reply path remained monotonic and the client workload continued to commit later writes; this disposition is not severity-bearing. |
| 4 | CR-4 | DROPPED | — | Phase 4 dropped this as an already reported upstream snapshot backpressure/cancellation issue; dropped entries are recorded without severity. |
