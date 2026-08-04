# MC-2 Investigation

## Code audit

Finding: append compose can return success for a later AppendEntries request whose
first entry has the same start index as an in-flight append but a different term
or value.

Relevant code:

- `ratis-server/src/main/java/org/apache/ratis/server/impl/ServerImplUtils.java:150-160`
  converts the request entries to `ConsecutiveIndices`, calls
  `alreadyExists(...)`, and when that reports an existing start index, returns
  the existing `future.get()` without invoking `appendLog.apply(entries)` for
  the later request.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ServerImplUtils.java:163-176`
  treats a collision only by `indices.startIndex`. It does not compare the
  colliding `term`, `count`, or entry contents.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1713-1715`
  routes normal follower AppendEntries through `appendLogTermIndices.append`
  when `raft.server.log.append-entries.compose.enabled` is true.
- `ratis-server-api/src/main/java/org/apache/ratis/server/RaftServerConfigKeys.java:475-482`
  defines that compose setting, defaulting to enabled.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1730-1749`
  converts a completed `appendFuture` into `AppendResult.SUCCESS` with
  `matchIndex = entries.get(entries.size() - 1).getIndex()`, so a composed
  request can receive success for entries that were not passed to the raft log.

Call chain:

- gRPC server entry:
  `GrpcServerProtocolService.appendEntries` -> `GrpcServicesImpl.appendEntriesAsync`
  -> `RaftServerProxy.appendEntriesAsync` -> `RaftServerImpl.appendEntriesAsync`
  -> `ServerImplUtils.NavigableIndices.append`.
- non-gRPC/server protocol entry:
  `LogAppenderDefault.sendAppendEntriesWithRetries` calls
  `RaftServerRpc.appendEntries`, and the follower side reaches the same
  `RaftServerImpl.appendEntriesAsync` path.
- Leader-side consumers of a SUCCESS reply:
  `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:515-528`
  updates follower commit/match/next index on `AppendResult.SUCCESS`; it does
  this even when `pendingRequests.remove(reply)` returned null.
  `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java:192-211`
  updates match and next index from the success reply in the non-gRPC appender.
  `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:851-858`
  submits commit/staging work after a follower success.
  `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:953-1029`
  computes the majority from follower match indices and can advance commit.

Reachability:

- The follower accepts an AppendEntries request under `synchronized (this)`,
  checks term/leader/group and the previous log entry, then leaves the lock
  before the asynchronous log append completes
  (`RaftServerImpl.java:1668-1715`).
- The implementation has a real in-flight state distinct from durable log state:
  `NavigableIndices` is specifically used by `checkInconsistentAppendEntries`
  to recognize a previous term/index that has been accepted but not yet visible
  in the raft log (`RaftServerImpl.java:1787-1790`).
- A later request with the same first index can arrive while the first request's
  term-index remains in `NavigableIndices.map`. The compose branch only keys by
  start index, so it will compose even if the later request's first entry has a
  different term/value.

Counterexample alignment:

- `spec/output/hunt/MC_hunt_scenario1_sim3.log` reports
  `Error: Invariant AppendSuccessReflectsLog is violated`.
- State 22 has pending request `s1` from leader `s3`, `term |-> 2`,
  `first |-> 1`, `last |-> 1`, while `inFlightAppend(s1)` still records the
  older leader `s2`, `term |-> 1`, `start |-> 1`.
- State 24 is
  `MCServerImplUtils_NavigableIndices_append_ComposeExisting(s1)` and records
  `composedAppend(s1)` with `leader |-> s3`, `term |-> 2`, `start |-> 1`.
- State 27 is
  `MCRaftServerImpl_appendEntriesAsync_ReplyComposed(s1)` and records
  `appendReply(s1)` as `result |-> "SUCCESS"`, `term |-> 2`,
  `match |-> 1`, `next |-> 2`; at the same state, `logTerm(s1)` remains
  `<<1, 0, 0, 0>>`, so the follower is acknowledging term-2/index-1 while its
  log has term-1/index-1.

Safeguards encountered:

- `checkInconsistentAppendEntries` rejects missing previous entries, snapshot
  overlap, or gaps (`RaftServerImpl.java:1692-1707`, `1764-1796`), but it does
  not compare the entries being appended against in-flight entries with the
  same first index.
- `RaftLogSequentialOps.append(List)` documents the intended follower behavior:
  "If an existing entry conflicts with a new one (same index but different
  terms), delete the existing entry and all entries that follow it (§5.3)"
  (`ratis-server-api/src/main/java/org/apache/ratis/server/raftlog/RaftLogSequentialOps.java:144-151`).
  The compose branch bypasses this raft-log conflict handling because it never
  calls `appendLog` for the later request.
- A later AppendEntries with `previous=(term=2,index=1)` may force an
  `INCONSISTENCY` reply from a follower that still has term 1 at index 1, but
  that happens after the earlier incorrect SUCCESS can already be returned and
  consumed by leader-side match/commit logic.

## Developer-knowledge search

Public tracker/history searched:

- GitHub issues/PR API queries:
  - `repo:apache/ratis NavigableIndices same startIndex term value` -> 0
  - `repo:apache/ratis append-entries.compose.enabled same start index` -> 0
  - `repo:apache/ratis "ServerImplUtils.NavigableIndices" "term"` -> 0
  - `repo:apache/ratis "ReplyComposed" "AppendSuccessReflectsLog"` -> 0
- `git log --all --grep='same start|startIndex|appendEntries|NavigableIndices|compose|future|term' --regexp-ignore-case`
  found related append/NavigableIndices changes, especially RATIS-2278/#1247
  and #1248, but no commit message describing this same term/value mismatch.
- `rg` over main/test/docs for the same keywords found no existing test or
  comment covering mismatched term/value compose.

Closest known related issue:

- Apache JIRA RATIS-2278:
  https://issues.apache.org/jira/browse/RATIS-2278
  describes a `NavigableIndices` inter-method concurrency problem where
  start-index validation rejects valid concurrent append work.
- GitHub PR #1247:
  https://github.com/apache/ratis/pull/1247
  proposed changing the startIndex precondition for multiple appendEntries
  requests and was later reverted.
- GitHub PR #1248:
  https://github.com/apache/ratis/pull/1248
  discusses two AppendEntries requests with the same startIndex during
  INCONSISTENCY/retry; reviewer discussion says the implementation should
  "simply ignore the second request" for same-entry retry. The public discussion
  does not mention accepting a different term or value under the same start
  index, and the GitHub/JIRA searches above did not find this exact mechanism.

Developer intent:

- PR #1248 intent was to ignore a duplicate request with the same first index
  in the retry race, not to acknowledge a conflicting term/value as appended.
- The raft-log API comment at `RaftLogSequentialOps.java:148-149` states that
  same-index different-term conflicts are supposed to truncate/replace, which
  supports treating term/value-oblivious compose as contrary to intended
  follower append semantics.

Known-status:

- Novelty result: NEW. I found a related filed issue/PR for same-startIndex
  retry/validation (`RATIS-2278`, #1247/#1248), but no public issue, PR, CVE,
  advisory, or visible repository history entry reporting the same mechanism:
  compose reuses an in-flight future for a later same-startIndex append with a
  different term/value and returns SUCCESS without appending that exact entry.

## Reproduction artifact

- Test file written and executed:
  `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/repro/test_bugMC-2_append_compose_mismatch.sh`
- Output captured at:
  `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/MC-2/repro-MC-2.log`
- Command:
  `timeout 25m /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/repro/test_bugMC-2_append_compose_mismatch.sh > /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/MC-2/repro-MC-2.log 2>&1`
- The script executes a Level 2 admissible-state reproduction corresponding to
  counterexample State 24: an in-flight old leader entry term=1/index=1 exists
  in `NavigableIndices`, then a later entry term=2/index=1 is appended through
  the production `NavigableIndices.append` method.
- The script also executes the real non-gRPC leader reply consumer
  `LogAppenderDefault.handleReply`, showing that a SUCCESS reply for
  `nextIndex=2` advances follower `matchIndex` to 1 and `nextIndex` to 2. The
  gRPC consumer has the same observable progress update at
  `GrpcLogAppender.java:515-528`.
- Observed result in Surefire output:
  `MC-2_LEVEL2_REPRO: second request startIndex=1 term=2 value=v2 completed via reused future`
  and
  `MC-2_LEVEL2_REPRO: appendLog calls=1, physical entry term=1, physical entry value=v1`,
  plus
  `MC-2_CONSUMER_REPRO: LogAppenderDefault.handleReply advanced matchIndex=1 nextIndex=2 from SUCCESS`.
