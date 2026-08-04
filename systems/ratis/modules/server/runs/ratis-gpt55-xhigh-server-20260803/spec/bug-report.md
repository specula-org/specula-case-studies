# Bug Report - ratis-server

## Summary

- Scenarios tested: 5
- Bugs found: 2 model-checking/source-backed candidates
- Configs run: `MC_hunt_scenario1.cfg`, `MC_hunt_scenario2.cfg`, `MC_hunt_scenario3.cfg`, `MC_hunt_scenario4.cfg`, `MC_hunt_scenario5.cfg`
- Evidence status: TLC counterexamples mapped to source code; code-level reproduction is still a Phase 4 task.

## Bug 1: Async flush failure can advance commit ahead of durable log

- **Scenario**: Scenario 1 - commit advancement versus durable log state
- **Severity**: Critical
- **Invariant violated**: `CommittedImpliesDurableFlush`
- **Config**: `MC_hunt_scenario1.cfg`
- **Counterexample**: 12 states, `spec/output/MC_hunt_scenario1_bfs_round7.out`

### Trace Summary

A server starts an election, becomes leader, appends a configuration entry at index 0, writes it to the log worker queue, and starts an async flush. The async flush fails, but the follow-up callback still advances the modeled flush index. The leader then observes enough follower/config acknowledgement and advances `commitIndex` to 0 while `diskLog[s1]` is still empty.

### Root Cause

The source-backed concern is that `SegmentedRaftLogWorker.asyncFlushOutStream` emits the failure path when the async flush completes with an exception, but then still calls `updateFlushedIndexIncreasingly(lastWrittenIndex)`. `RaftLogBase.updateCommitIndex` clamps commit advancement to `getFlushIndex()`, and `LeaderStateImpl.updateCommit` feeds leader-local flush state into the majority commit calculation. If a failed flush can increase `flushIndex`, the leader may treat a non-durable local entry as flush-covered.

### Affected Code

- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/SegmentedRaftLogWorker.java:407`: async flush callback handles both success and failure.
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/SegmentedRaftLogWorker.java:415`: `updateFlushedIndexIncreasingly(lastWrittenIndex)` runs even after `e != null`.
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/RaftLogBase.java:123`: commit index advancement is bounded by `getFlushIndex()`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:956`: leader commit advancement uses follower match indices and local `raftLog::getFlushIndex`.

### Recommendation

Do not advance `flushIndex`, notify commit, or complete flush-covered work as successful when async log flush completes exceptionally. Add a fault-injection test around async flush failure that asserts `flushIndex` and `commitIndex` do not advance past durable log contents.

---

## Bug 2: Old leader lease read can race with NOT_LEADER reply handling

- **Scenario**: Scenario 4 - leader lease and ReadIndex state across leadership change
- **Severity**: High
- **Invariant violated**: `NoOldLeaderLeaseRead`
- **Config**: `MC_hunt_scenario4.cfg`
- **Counterexample**: 11 states, `spec/output/MC_hunt_scenario4_bfs_round10.out`

### Trace Summary

A server becomes leader and enables leader leases. A log appender sends AppendEntries to a follower and receives a `NOT_LEADER`/higher-term style result. Before the reply is handled by `handleReply`, the appender records the last responded AppendEntries send timestamp. A concurrent lease check uses that timestamp to extend the lease, and a read enters the lease fast path before the old leader steps down.

### Root Cause

`LogAppenderDefault.sendAppendEntriesWithRetries` updates follower response timing and `lastRespondedAppendEntriesSendTime` immediately after receiving an AppendEntries reply. Handling of `NOT_LEADER` is deferred until the caller later invokes `handleReply`, where `onFollowerTerm(reply.getTerm())` may step the server down. `LeaderLease.extend` trusts recent follower response timestamps for majority lease extension, and `LeaderStateImpl.getReadIndex` can return on the lease fast path once `hasLease()` succeeds. This creates a source-backed race window in which an old leader can serve a lease read before the demotion path has consumed the reply that should invalidate leadership.

### Affected Code

- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java:95`: records AppendEntries send time.
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java:103`: receives AppendEntries reply.
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java:105`: updates follower response time before reply handling.
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java:106`: updates `lastRespondedAppendEntriesSendTime` before reply handling.
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java:186`: `handleReply` is called after send returns.
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java:221`: `NOT_LEADER` handling calls `onFollowerTerm`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderLease.java:68`: lease extension uses recent follower timestamps.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:1214`: ReadIndex can use the lease fast path.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:1249`: `hasLease` can extend and validate the lease.

### Recommendation

Only update lease-eligible follower response timestamps after a reply has been classified as leadership-preserving success, or ensure `NOT_LEADER`/higher-term handling runs before those timestamps can be observed by lease extension. Add a concurrency test with an AppendEntries `NOT_LEADER` reply racing a lease ReadIndex request.

---

## Not Reproduced

| Scenario | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Scenario 2 - election/crash recovery interactions | `MC_hunt_scenario2.cfg` | BFS round7: level 13, 712,195,184 generated / 126,753,952 distinct; simulation round7: 482,489,395 states / 20,459,165 traces | No violation after Case B fixes for leader-only metadata/config paths, durable metadata recovery, empty-storage format guard, and stale vote-reply term matching. |
| Scenario 3 - snapshot installation exclusion | `MC_hunt_scenario3.cfg` | BFS round9: level 9, 873,364,343 generated / 169,601,712 distinct; simulation round9: 444,777,031 states / 24,937,553 traces | No violation after Case B fixes for snapshot bookkeeping and removal of source-unsupported accept-during-snapshot fault path. |
| Scenario 5 - configuration changes across recovery and leader change | `MC_hunt_scenario5.cfg` | BFS round15: level 13, 104,666,351 generated / 26,155,056 distinct; simulation round15: 227,264,462 states / 18,500,526 traces | No violation after Case A/B fixes for listener election eligibility, follower updateConfiguration AppendEntries context, leader-local appends, recovered-role invariant scope, and removal of source-unsupported old-majority bypass. |

## Spec Fixes During Hunting

- Tightened crash recovery so in-flight async flush state does not survive recovery, and durable config/log metadata is restored from disk-covered evidence.
- Added leader-only guards for local log append, metadata append, configuration acknowledgement, caught-up tracking, attempted snapshot tracking, and configuration commit paths.
- Removed source-unsupported synthetic fault transitions for accept-during-snapshot and config commit without old-majority overlap.
- Refined invariants whose first counterexamples were Case A mismatches: `ReadIndexRequiresCurrentLeader` and `DurableConfigMatchesRecoveredRole`.
- Added source-backed guards for listener election eligibility and for `ServerState_updateConfiguration_BeforeAppendDurable` so configuration updates require a recognized AppendEntries leader and no snapshot-in-progress inconsistency.
- Full round-by-round evidence is recorded in `spec/changelog.md`.
