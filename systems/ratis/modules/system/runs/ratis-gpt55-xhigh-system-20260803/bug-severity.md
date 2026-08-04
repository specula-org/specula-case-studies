# Severity Classification — ratis-system

## Summary

- Total entries: 8
- Reproduced bugs: 4
- Severity-bearing findings: 0
- Critical: 1
- High: 3
- Medium: 0
- Low: 0
- No-severity dispositions: 4

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | Critical | The old leader can return a successful client reply for a log entry that is absent from the next leader, creating a persistent Raft safety violation on the normal client write and gRPC AppendEntries path. Later follower sync can remove the stale follower entry, but it cannot undo the already observed client-visible commit success. |
| 2 | MC-2 | REPRODUCED | High | A follower can return SUCCESS for a different in-flight entry at the same start index, and leader append-reply handling can advance follower progress from that false success. The directly observed consequence is incorrect leader progress for a replicated log slot; later repair may correct the follower log, so the reproduced impact is serious but bounded. |
| 3 | MC-3 | REPRODUCED | High | A metadata persistence failure can leave an accepted higher term non-durable, then restart reloads the older term and permits a same-term vote for another candidate. This is a crash-restart term-durability violation on the AppendEntries and RequestVote surfaces. |
| 4 | MC-4 | REPRODUCED | High | Type-only STEP_DOWN deduplication can drop the highest observed follower term, leaving the server at a stale lower term. A real RequestVote call then consumes that stale term and grants a vote that the higher-term state should reject. |
| 5 | CR-3 | FALSE POSITIVE | — | Phase 4a determined the current code has guards for the suspected snapshot frontier, so this disposition is not severity-bearing. |
| 6 | CR-4 | DROPPED | — | Phase 4a dropped this as a known fixed upstream duplicate, so it is recorded without a new severity. |
| 7 | CR-5 | DROPPED | — | Phase 4a dropped this as already reported and fixed upstream before reproduction, so it is not severity-bearing. |
| 8 | CR-6 | FALSE POSITIVE | — | Phase 4a found no progress regression or read-index error in the current implementation, so this disposition has no severity. |
