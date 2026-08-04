# CR-6 Investigation

## Scope

Finding: `CR-6`, code-review source.

Worktree SHA: `7eedc1deed07fc883bfe448b2d33438b7a0e994e`.

The checkout already contained local `SpeculaTrace` instrumentation in several files. I did not revert or rely on it for the progress assertions.

## Step 1: Code Audit

Relevant sites:

- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:207-235`: `resetClient` clears pending requests. For non-heartbeat request errors it calls `getNextIndexForError`; for `request == null` errors it keeps `nextIndex` unchanged; for heartbeat request errors it returns without changing `nextIndex`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:453-462`: timeout removes only the pending request and records timeout; it does not directly decrease `nextIndex` or advance `matchIndex`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:493-548`: delayed replies are still processed after `pendingRequests.remove(reply)` returns `null`; success replies call `updateMatchIndex(reply.getMatchIndex())`, then `updateNextIndex(reply.getMatchIndex() + 1)` only if match increased.
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderBase.java:177-208`: inconsistency/error next-index helpers clamp error next-index to at least `matchIndex + 1`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/FollowerInfoImpl.java:93-150`: `matchIndex`, `commitIndex`, and `updateNextIndex` are max-only except explicit `setNextIndex`/`computeNextIndex`; snapshot install sets match/next together.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1656-1756`: follower success reply is created after append future completion; data append replies carry `matchIndex = last entry index`, heartbeat replies carry invalid match index.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ReadIndexHeartbeats.java:43-82,139-185`: read-index heartbeat ack filters success replies by follower commit and `callId >= minCallId`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:1182-1235`: linearizable read is the real caller that waits for append/heartbeat replies.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java:57-60,500-504`: server state owns protected raft-log state and computes local next index from log/snapshot.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java:64-95,319-324`: snapshot installation can make appendEntries reply inconsistency while state machine installs a snapshot.

Reachable path:

1. A public `RaftClient` write creates a leader log entry.
2. `LeaderStateImpl.newAppendEntriesRequestProto` builds append requests.
3. `GrpcLogAppender.appendLog/sendRequest` sends the request through gRPC and schedules timeout.
4. Follower `RaftServerImpl.appendEntriesAsync` validates the request, appends, commits, and replies.
5. Leader `GrpcLogAppender.AppendLogResponseHandler.onNext` updates follower progress and notifies `LeaderStateImpl`.
6. Linearizable read uses `LeaderStateImpl.getReadIndex` and `ReadIndexHeartbeats` as a real consumer of append replies.

Trigger scenario constructed:

- Level 0: public writes, follower stop/restart, leader reconnect and catch-up.
- Level 1: use the existing test hook `BlockRequestHandlingInjection` to block one follower's real `AppendEntries` handler past the leader appender timeout, then unblock it so the original success reply arrives after its pending request has timed out.

Safeguards recorded:

- `resetClient(request == null, error)` keeps `nextIndex` unchanged.
- Heartbeat reset returns without changing `nextIndex`.
- `getNextIndexForError` clamps to `matchIndex + 1`.
- `updateMatchIndex` is max-only.
- `updateNextIndex` is max-only.
- Heartbeat success replies cannot advance match because follower replies use invalid match index for heartbeats.
- Read-index requires success, sufficient follower commit, and call-id lower bound.

## Step 2: Developer Knowledge

Local git history and GitHub PR search found related historical fixes at the same code area:

- `RATIS-1835` / GitHub PR `#875`: "Keep nextIndex unchanged when leader sending heartbeat to restarting followers"; merged Apr 17, 2023. This covers heartbeat failure resetting nextIndex for restarting followers.
- `RATIS-1883` / GitHub PR `#914`: "Next Index should be always larger than Match Index in GrpcLogAppender"; merged Sep 7, 2023. This covers next-index lower bound relative to match-index.
- `RATIS-1909` / GitHub PR `#939`: "Fix Decreasing Next Index When GrpcLogAppender Reset Client"; merged Oct 18, 2023. The PR text says the change decreases next index while obeying `matchIndex + 1`, and its discussion gives a concrete next-index-regression scenario.
- `RATIS-1872` / GitHub PR `#905`: "HeartbeatAck use in-correct callId as minCallId"; merged Aug 2023. This covers a read-index heartbeat ack call-id bug, but not delayed old appender reply after current timeout/reconnect.

Developer comments near the current code also document intended safeguards:

- `LogAppenderBase.getNextIndexForInconsistency`: comment says next index should ideally be greater than match index, but avoids resending the same first entry in special cases.
- `LeaderStateImpl.getReadIndex`: comment says linearizable read records a read index, broadcasts heartbeats, and waits for majority acknowledgements.
- `RaftServerImpl.readIndexAsync`: comment says after leader replies to follower read-index request it triggers heartbeat so follower commit can be updated.

## Step 3: Known Status / Precedent

Prior search covered local git history and GitHub merged/closed PRs for `GrpcLogAppender`, `resetClient`, `nextIndex`, `matchIndex`, timeout, delayed/old/stale replies, and `ReadIndexHeartbeats`.

The historical next-index regression portions are already reported and fixed by `RATIS-1835`, `RATIS-1883`, and `RATIS-1909`. I did not find an existing report for this current-code mechanism: a delayed success reply after appender timeout/reconnect falsely advancing `matchIndex` or causing a real linearizable-read caller to observe a wrong result.

Known-status for the current mechanism: no exact existing report found; proceed to Phase 2.
