# MC-1 Investigation

## Scope

- Finding: MC-1, source MC, invariant `CommittedImpliesDurableFlush`.
- Worktree: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/confirmation/MC-1/worktree`
- HEAD: `7eedc1deed07fc883bfe448b2d33438b7a0e994e`
- Current checkout has uncommitted Specula instrumentation in server files; the investigated upstream mechanism is still present at the cited sites.

## Code audit

- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/SegmentedRaftLogWorker.java:407-420`: `asyncFlushOutStream` combines `out.asyncFlush(flushExecutor)` with the state-machine flush future. Its `whenComplete((v, e) -> ...)` records failure when `e != null`, but still calls `updateFlushedIndexIncreasingly(lastWrittenIndex)` at line 415.
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/SegmentedRaftLogWorker.java:433-436`: `updateFlushedIndexIncreasingly(index)` advances `flushIndex`, fires `submitUpdateCommitEvent`, and completes write tasks through `writeTasks.updateIndex(index)`.
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/BufferedWriteChannel.java:144-151`: `asyncFlush` flushes buffered bytes to the `FileChannel`, schedules `fileChannel.force(false)`, sets `forced = true`, and returns a future chained through prior flushes.
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/BufferedWriteChannel.java:154-160`: `fileChannelForce` converts `FileChannel.force(false)` `IOException` into a failed `CompletionException`.
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/RaftLogBase.java:123-136`: commit advancement clamps majority index by `getFlushIndex()`. If `flushIndex` was advanced by a failed async flush, this guard treats the failed local flush as durable.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:956-959`: leader commit calculation uses follower match indexes plus `raftLog::getFlushIndex` for the leader's own index.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:1025-1033`: once the majority is above the old commit index, the leader calls `server.getState().updateCommitIndex(...)`; this reaches `RaftLogBase.updateCommitIndex`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java:414-418`: when the log commit index changes, the state-machine updater is notified.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/StateMachineUpdater.java:243-256`: the updater reads `raftLog.getLastCommittedIndex()` and applies committed entries to the state machine.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1885-1917` and `:1969-1975`: applying a state-machine log entry completes the pending client reply.

Reachable call chain:

1. Public client/admin API sends a normal write or configuration change to the leader.
2. Leader appends the entry through `SegmentedRaftLog.appendEntry(...)` to the `SegmentedRaftLogWorker`.
3. With `raft.server.log.async-flush.enabled=true` and `raft.server.log.force.sync.num=1`, each written entry enters `SegmentedRaftLogWorker.asyncFlushOutStream`.
4. If `FileChannel.force(false)` completes exceptionally, the callback still advances `flushIndex` and completes the write task.
5. Follower replication plus the leader's now-advanced `flushIndex` lets `LeaderStateImpl.updateCommit` advance commit.
6. `StateMachineUpdater`/`RaftServerImpl.replyPendingRequest` can apply the entry and return success to the client.

Trigger scenario:

- Start a normal multi-node Ratis cluster with segmented log async flush enabled and immediate force-on-entry.
- Let the leader reach ready state through a normal write.
- Submit a normal configuration-change request.
- During the leader's async log flush for the configuration entry, the storage layer's `FileChannel.force(false)` fails with `IOException`.
- The async flush future completes exceptionally, but `SegmentedRaftLogWorker.asyncFlushOutStream` still advances `flushIndex`; commit and client success can follow.

Safeguards checked:

- `RaftLogBase.updateCommitIndex` does check `Math.min(majorityIndex, getFlushIndex())`, but this is the exact guard defeated by the failed-flush callback advancing `flushIndex`.
- The async failure is not propagated to the entry write future; `writeTasks.updateIndex(index)` completes the write task after `flushIndex` advances.
- `BufferedWriteChannel.asyncFlush` sets `forced = true` before the asynchronous `force(false)` result is known; after a failed future, there is no observed retry before commit.

## Developer knowledge

- GitHub PR search via GitHub API:
  - `repo:apache/ratis asyncFlushOutStream` found PR #699, "RATIS-1644. Provide a safe async flush."
  - `repo:apache/ratis updateFlushedIndexIncreasingly` found PRs #699, #616, and #611.
  - `repo:apache/ratis flushIndex async flush`, `FileChannel.force asyncFlush`, and `forceSyncNum asyncFlush` found the async-flush introduction/safe-flush work, but no report of failed `force(false)` still advancing `flushIndex`.
- RATIS-1644 JIRA (`https://issues.apache.org/jira/browse/RATIS-1644`) says unsafe flush updated commit before flush returned, and that updating commit after flush return would make async flush safe.
- PR #699 (`https://github.com/apache/ratis/pull/699`) added the current safe async flush mechanism. A reviewer comment states that when async flush is enabled the implementation should wait for both relevant operations before updating the index. That is developer-intent evidence that index advancement is supposed to be gated on successful flush completion, not merely callback execution.
- PR #616 (`https://github.com/apache/ratis/pull/616`) introduced async flush as a performance feature after a prior minimum-flush-interval approach hurt commit progress. It is adjacent history, not a report of the failure-path defect.
- Local `git blame` attributes `updateFlushedIndexIncreasingly(lastWrittenIndex)` inside the async callback to merge commit `fafca0a287...` from RATIS-1644/#699. No nearby comment documents accepting failed force as durable.

## Known-status / precedent

- Same-site async-flush history exists (#616/#699), but I found no public issue, PR, CVE, advisory, or local git commit message that reports the exact mechanism: `FileChannel.force(false)`/async flush completes exceptionally, yet `SegmentedRaftLogWorker.asyncFlushOutStream` still advances `flushIndex` and permits commit/client success.
- Novelty for this mechanism: `NEW`.
