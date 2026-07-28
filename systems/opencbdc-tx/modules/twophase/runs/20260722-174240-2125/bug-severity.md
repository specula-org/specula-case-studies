# Severity Classification — opencbdc-tx

## Summary

- Total entries: 7
- Reproduced bugs: 1
- Severity-bearing findings: 3
- Critical: 1
- High: 2
- Medium: 1
- Low: 0
- No-severity dispositions: 3

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | MASKED | High | Without the sentinel infinite retry loop (the mask), the activation gap between `isLeader=true` and `handlerActive=true` causes `execute_transaction` to reject transactions during every leader election, dropping transactions that arrive in the window. The gap is transient and the consequence is argued (not live), but the invariant violation (`InvLeaderHasHandler`) creates a real safety window that is Critical if unmasked. |
| 2 | MC-2 | ENV_LIMITED | High | A coordinator accepts a transaction through `is_leader()` check but loses leadership before batch execution completes, leaving the request in-flight on a non-leader. The client receives a `nullopt` failure callback for a legitimately accepted transaction — a genuine transient failure that a retry recovers from. Matches "single failed response a client can retry" rubric. The full race requires a multi-node cluster with precisely timed leadership change (environment-limited). |
| 3 | CR-1 | REPRODUCED | Critical | The locking shard's `apply_outputs` calls `fatal()` (process termination via `exit(EXIT_FAILURE)`) when called for a dtx_id already consumed by `discard_dtx`. A crash-recovery sequence across Raft terms triggers this: the new leader re-issues `apply_outputs` after the shard has already processed the discard. This is a permanent crash with no automatic recovery, reachable through the public API under the stated fault model (leader crash during 2PC). |
| 4 | CR-2 | ENV_LIMITED | Medium | Both coordinator and locking shard set `snapshot_distance_=0`, disabling Raft snapshots and preventing log compaction. Log entries accumulate unboundedly in LevelDB, causing monotonic disk growth and linearly increasing recovery time. No single consumer observes a functional failure; the harm is latent operational exhaustion requiring sustained deployment to manifest. |
| 5 | CR-3 | FALSE POSITIVE | — | Phase 4a determined this is a false positive. The claimed race windows (batch_set_cbs outside lock) are factually incorrect — both `batch_set_cbs` and `add_tx` operate under `m_batch_mut`. No severity-bearing defect exists. |
| 6 | CR-4 | DROPPED | — | Phase 4a dropped this entry (code-review × known, see upstream Issue #56). The locking shard's in-memory state is correctly rebuilt from the Raft log on restart; the defect only manifests when the Raft log itself is destroyed. |
| 7 | CR-5 | FALSE POSITIVE | — | Phase 4a determined this is a false positive. The four claimed error-handling gaps are either intentional defensive design (coordinator `fatal()` on duplicate prepare), already-fixed code (sentinel `init(false)`), or theoretical edges guarded by NuRaft checksums. |
