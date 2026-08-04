# MC-1 Investigation

## Finding

MC-1 claims that a follower can accept a non-heartbeat `AppendEntries`, grant a higher-term vote before the asynchronous append completes, and later return a stale `SUCCESS` to the old leader. The old leader can count that reply toward commit even though the newly elected leader does not contain the entry.

## Counterexample Trace Evidence

The provided model-checking counterexample `spec/output/mc/MC_convergence_round3.log` reports `Invariant LeaderCompleteness is violated`.

Relevant actions:

- State 7: `MCRaftServerImpl_appendTransaction(s2,v1)` creates the old-leader entry.
- State 8: `MCGrpcLogAppender_appendLog(s2,s3)` sends the entry from old leader `s2` to follower `s3`.
- State 9: `MCRaftServerImpl_appendEntriesAsync_RegisterInFlight(s3)` reaches the in-flight append window.
- State 10: `MCRaftServerImpl_requestVote_Grant(s3,s1)` lets `s3` grant a higher-term vote to `s1` before physical append completion.
- State 11: `MCSegmentedRaftLog_appendImpl_CompletePhysicalAppend(s3)` completes the append at `s3`.
- State 12: `MCRaftServerImpl_changeToLeader(s1)` elects `s1`, which does not have `v1`.
- State 13: `MCGrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_OldStream(s2,s3,1)` delivers the stale success to old leader `s2`.
- State 14: `MCLeaderStateImpl_updateCommit(s2,1)` advances old leader `s2`'s commit index for `v1`.

At the violating state, `s1` is leader, `s2` also still believes it is leader in the partitioned old term, `s2` and `s3` contain `v1`, and `s1` does not.

## Code Evidence

`ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java` accepts and validates `AppendEntries` under `synchronized (this)`, captures `currentTerm`, recognizes the old leader, and exits the synchronized block before appending entries to the log. The reply path later uses that captured term and returns `AppendResult.SUCCESS` after asynchronous append completion.

`ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java` grants votes in `requestVote` under a separate synchronized section and evaluates candidate freshness via `ServerState.getLastEntry()`. If the old leader's entry has not yet entered the follower's `RaftLog`, the candidate that lacks the entry can still be considered up to date.

`ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java` handles `AppendResult.SUCCESS` by updating the follower match index and calling `LeaderStateImpl.onFollowerSuccessAppendEntries` without checking that the reply term still reflects a current follower term for the old leader's epoch.

`ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java` recomputes majority match indexes and advances the leader commit index via `server.getState().updateCommitIndex(majority, currentTerm, true)`.

`ratis-server/src/main/java/org/apache/ratis/server/raftlog/RaftLogBase.java` only advances a leader commit index for entries in the leader's current term. The disputed entry is created in the old leader's current term, so that guard does not prevent this scenario.

`ratis-server/src/main/java/org/apache/ratis/server/impl/PendingRequest.java` completes the client-visible future when the leader replies to a committed pending request.

## Existing Report Search

I searched upstream GitHub issues, upstream GitHub pull requests, Jira text search, and local git history for this mechanism, including terms around `AppendEntries`, `RequestVote`, stale `SUCCESS`, higher-term vote, `GrpcLogAppender`, and `LeaderCompleteness`.

Adjacent but not matching records:

- apache/ratis#1519 / RATIS-2605 fixes heartbeat success incorrectly advancing match index in `LogAppenderDefault`; it does not cover non-heartbeat gRPC stale success after a follower grants a higher-term vote.
- apache/ratis#1148 / RATIS-2154 changes old-leader append behavior after the old leader observes a term change; it does not cover a follower returning a stale success on an already in-flight append after voting in a higher term.
- apache/ratis#1168 / RATIS-2174 moves `future.join` outside the lock for deadlock avoidance; it does not add a term/leadership guard on stale append completion or gRPC success consumption.

No prior report or merged/closed fix was found for the specific in-flight append completion across higher-term vote mechanism.

## Reproduction Plan

Level 0/1 timing alone did not expose a stable hook at the required point. The existing `LogSegment.APPEND_RECORD` hook runs after the entry is already placed in the log cache under the log write lock, so a concurrent vote either sees the entry or waits behind the log lock. That does not match counterexample State 9.

The reproduction therefore uses two Level 3 test-only timing hooks. The first runs immediately after `RaftServerImpl.appendEntriesAsync` has accepted the old leader's append and released the server lock, but immediately before `state.getLog().append(entries)`; it corresponds to counterexample State 9. The second runs immediately after `requestVote` has granted and persisted a higher-term vote but before returning the vote reply; it corresponds to counterexample State 10. Both injected pre-conditions are reached through real cluster activity: a public client write, real gRPC `AppendEntries`, and real leader-election `RequestVote`.

The test then:

- starts a 3-node gRPC cluster;
- chooses the old leader, the future candidate, and the target follower;
- blocks old-leader appends to the candidate;
- sends a real asynchronous client write to the old leader;
- waits until the target follower is blocked in the accepted-before-append window;
- blocks the target's outbound election attempts and isolates the old leader so the candidate can obtain target's vote;
- waits until the target follower has granted and persisted the higher-term vote to the candidate;
- releases the target follower append so it returns stale `SUCCESS` to the old leader;
- verifies the old-leader client receives success while the new leader still lacks the entry.
