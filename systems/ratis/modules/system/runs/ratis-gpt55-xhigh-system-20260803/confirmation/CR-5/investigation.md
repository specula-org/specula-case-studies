# CR-5 Investigation

## Finding

- Source: Code Review
- Candidate: CR-5, "Client-visible read-index completion can race with delayed append replies, commit, apply, and replied-index flushing"
- Source tree: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/CR-5/worktree`
- Baseline HEAD: `7eedc1deed07fc883bfe448b2d33438b7a0e994e`

## Step 1: Code Audit

Relevant current code:

- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1109-1161`
  - Follower linearizable reads call `sendReadIndexAsync`, receive the leader-selected read index, then call `getState().getReadRequests().waitToAdvance(readIndex, ...)` before `queryStateMachine`.
  - Leader-local linearizable reads use `getReadIndex(request, leader)`, which includes read-after-write via `writeIndexCache`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ReadRequests.java:58-84,104-120`
  - `ReadIndexQueue.add` returns immediately only when `readIndex <= lastAppliedIndex`.
  - Otherwise it stores a future keyed by read index; `complete(appliedIndex)` completes only entries `<= appliedIndex`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ReadIndexHeartbeats.java:49-81,90-118,139-180`
  - `AppendEntriesListener` triggers heartbeats and records a per-appender `HeartbeatAck`.
  - `HeartbeatAck.isValid` requires a successful AppendEntries reply whose call id is at least the appender call id captured for this listener.
  - `AppendEntriesListeners.onAppendEntriesReply` ignores listeners above `reply.getFollowerCommit()`, so a reply cannot satisfy a read index beyond the follower's committed index.
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/RaftLogBase.java:123-136`
  - Commit advancement uses `Math.min(majorityIndex, getFlushIndex())`; leaders additionally require the committed entry term to equal the current term.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ReplyFlusher.java:97-149`
  - For `REPLIED_INDEX`, held write replies carry their log index separately; `flush` computes max held index, advances `repliedIndex`, then completes client write replies.

Reachable public path:

1. A client submits a write through `RaftClient`.
2. The leader appends locally, replicates via `GrpcLogAppender`/`LogAppenderDefault`, advances commit only after flushed majority progress, and applies through `StateMachineUpdater`.
3. A client submits a linearizable read to the leader or a follower.
4. The leader selects a read index and, when heartbeat checking is enabled, waits for majority AppendEntries acknowledgements through `ReadIndexHeartbeats`.
5. The serving server waits for local state-machine application of that read index before executing `stateMachine.query`.

Safeguards recorded for Phase 2:

- Read serving is gated by local applied index in `ReadRequests`.
- Read-index heartbeat acknowledgement is gated by both `followerCommit >= readIndex` and heartbeat/appender call id.
- Commit index is bounded by flushed log index and current-term leader commit rules.
- `REPLIED_INDEX` batching advances `repliedIndex` before releasing held write replies in this baseline.

## Step 2: Developer Knowledge Search

Local git history and upstream PR search found same-site prior reports:

- `RATIS-1872. HeartbeatAck use in-correct callId as minCallId. (#905)`:
  - Upstream PR: https://github.com/apache/ratis/pull/905
  - Merged: 2023-08-18T14:49:03Z.
  - Local equivalent commit in this checkout: `c1fd4e5dc015fc8b3e4b6b18d41eeab2b9e81284`, which is an ancestor of `HEAD`.
  - Patch moved heartbeat triggering/listener construction so `HeartbeatAck` captures the intended per-appender min call id for read-index heartbeat acknowledgement.
- `RATIS-2547. Advance repliedIndex before completing write replies (#1474)`:
  - Upstream PR: https://github.com/apache/ratis/pull/1474
  - Merged: 2026-05-29T13:55:16Z.
  - Local commit: `f19aecdb85401882a1b730c1a1e0189faa655de4`, ancestor of `HEAD`.
  - PR body states that the old `ReplyFlusher` flow could release a successful write reply before `repliedIndex` covered that write, and that the fix advances `repliedIndex` before completing held replies.
- Related but not the primary read-index/replied-index site: `RATIS-2605. Avoid advancing matchIndex from heartbeat AppendEntries success (#1519)`, merged 2026-07-14T18:16:07Z, local commit `6aafce539ca3c280db6e91fe8a6e02b345001952`, ancestor of `HEAD`.

Developer comments/tests in-tree:

- `LeaderStateImpl.getReadIndex` documents the Raft section 6.4 sequence: commit a current-term entry, record a read index, broadcast heartbeats, and return only after majority success.
- `RaftServerImpl.readIndexAsync` documents the follower-read path: after a leader replies with ReadIndex, it triggers heartbeat so the follower can advance commit/apply instead of waiting for the next AppendEntries.
- Existing tests include `TestLinearizableReadWithGrpc`, `TestLinearizableReadAppliedIndexWithGrpc`, `TestLinearizableReadRepliedIndexWithGrpc`, `TestReplyFlusher`, and `TestLogAppenderDefault`; these cover follower linearizable reads, read-after-write, replied-index batching, and heartbeat success handling.

## Step 3: Known Status / Precedent

This is code-review-sourced; no model-checking counterexample was supplied.

The finding is not novel. The same mechanisms at the same sites have existing upstream PRs:

- `ReadIndexHeartbeats` delayed/incorrect heartbeat call-id acknowledgement: https://github.com/apache/ratis/pull/905, fixed.
- `ReplyFlusher` replied-index completion ordering before client-visible write replies: https://github.com/apache/ratis/pull/1474, fixed.

Phase-1 pre-filter applies: Code Review x already-reported/fixed. No Phase 2 reproduction test is written or executed, per the bug-confirmation guide's DROPPED rule.

Status: DROPPED (code-review x known, cite: https://github.com/apache/ratis/pull/1474; additional same-site cite: https://github.com/apache/ratis/pull/905; fix-status: fixed)
