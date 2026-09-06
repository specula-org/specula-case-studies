# Severity Classification — vsr-rs

## Summary

- Total entries: 6
- Reproduced bugs: 3
- Severity-bearing findings: 2
- Critical: 4
- High: 0
- Medium: 1
- Low: 0
- No-severity dispositions: 1

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | CR-1 | REPRODUCED | Critical | Restarting a kvstore replica with an existing invalid view file reuses its identity as a fresh view-0 participant, allowing an old primary to commit an operation that conflicts with an already committed newer-view operation. The public reply path releases conflicting client results for the same log slot, and the reproduced committed inconsistency is permanent. |
| 2 | CR-2 | REPRODUCED | Critical | A client request to a singleton configuration accepted by the public API records its self-ack but never commits or produces a reply because quorum evaluation waits for a peer response that cannot arrive. Normal owner-loop steps and client retries cannot resolve the request, leaving persistent client-visible unavailability without automatic recovery. |
| 3 | CR-3 | REPRODUCED | Critical | A normal large kvstore SET to a primary with an established, non-draining backup connection can block the shared sender without a write timeout, indefinitely withholding replication traffic from healthy peers and leaving the client waiting while that connection remains stalled. The experiment observed a finite delay and a reply only after the peer was explicitly resumed; Critical follows the worst persistent consequence of the unbounded write, with duration beyond the observation window remaining inferred. |
| 4 | CR-4 | ENV_LIMITED | Critical | The report's production-impact argument is that a host/filesystem crash after kvstore releases newer-view outputs but before the renamed view file's directory entry is durable can lose the persisted view; a missing-file restart then composes with the fresh-identity mechanism in CR-1 to enable conflicting committed client results without automatic repair. This assumes loss of the unsynced directory entry and remains environment-limited because crash-capable filesystem/block-device injection or real power loss was unavailable, so no stale or missing restart was observed. |
| 5 | CR-5 | MASKED | Medium | Reusing a wall-clock-derived recovery nonce across kvstore restarts lets delayed prior RecoveryResponse messages complete recovery with stale committed state, violating recovery freshness and risking downstream use of stale state without a directly demonstrated external effect. The named mask is the next current primary Commit triggering GetState/NewState transfer, which restores the replica to the current committed state. |
| 6 | CR-6 | FALSE POSITIVE | — | Phase 4a records an observer-coverage boundary without a current reachable wrong outcome; the FALSE POSITIVE disposition is not severity-bearing. |
