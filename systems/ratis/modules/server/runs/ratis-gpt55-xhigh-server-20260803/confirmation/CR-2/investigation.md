# CR-2 Investigation

## Code Audit

Source classification: Code Review. The finding has no model-checking
counterexample and the prompt states model checking found no violation for this
area.

Relevant current source SHA before local instrumentation: `7eedc1deed07fc883bfe448b2d33438b7a0e994e`.
After a read-only fetch, `origin/master` advanced to `64e5b3442` via
`RATIS-2625. Streaming: support sending commands in Data Stream (#1534)`;
that commit did not touch `LeaderElection.java`, `VoteContext.java`,
`RaftServerImpl.java`, `RaftStorageImpl.java`, or `TermIndex.java`.

The checkout is dirty with existing Specula trace instrumentation in the core
server files. The relevant semantic changes inspected here are in committed
upstream code; the dirty diff only adds `SpeculaTrace.emit(...)` calls around
the affected election paths.

Cited code:

- `ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java:129`
  initializes storage, reads persisted configuration, initializes the state
  machine, opens the log, then loads persisted metadata into `currentTerm` and
  `votedFor`.
- `ratis-server/src/main/java/org/apache/ratis/server/storage/RaftStorageImpl.java:95`
  formats storage by clearing the directory and persisting default metadata.
- `ratis-server/src/main/java/org/apache/ratis/server/storage/StorageImplUtils.java:125`
  chooses between FORMAT and RECOVER. Current `RECOVER` with no existing
  storage and exactly one configured directory falls back to `format()`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1489`
  exposes the real `requestVote(RequestVoteRequestProto)` server RPC.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1499`
  takes the synchronized vote path, constructs `VoteContext`, persists a
  granted vote/term for election requests, and replies with
  `state.getLastEntry()`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/VoteContext.java:54`
  rejects candidates outside the current configuration.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/VoteContext.java:136`
  applies the Raft last-log election restriction using
  `ServerState.compareLog(state.getLastEntry(), candidateLastEntry)`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ServerProtoUtils.java:46`
  serializes `lastEntry == null` as `TermIndex.INITIAL_VALUE`, not as a missing
  proto field.
- `ratis-server-api/src/main/java/org/apache/ratis/server/protocol/TermIndex.java:41`
  defines `INITIAL_VALUE` as `(term=0,index=-1)` and `PROTO_DEFAULT` as the
  protobuf default `(term=0,index=0)`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderElection.java:513`
  waits for vote replies.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderElection.java:524`
  records whether the candidate has an empty commit history.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderElection.java:576`
  accepts a successful vote only when the candidate has no committed entries or
  `nonEmptyLog(reply)` returns true.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderElection.java:613`
  treats missing `lastEntry` / proto default `(0,0)` as old-version compatible
  evidence, treats any positive term as non-empty, and rejects explicit empty
  log `(term=0,index=-1)`.

Reachable call chain:

1. A peer starts or restarts through normal server startup with
   `RaftStorage.StartupOption.RECOVER`.
2. `ServerState.initialize` calls `StorageImplUtils.initRaftStorage`, then opens
   the raft log and loads metadata.
3. A candidate sends the normal internal `RequestVoteRequestProto`.
4. The voter reaches `RaftServerImpl.requestVote`, `VoteContext.recognizeCandidate`,
   and `VoteContext.decideVote`.
5. If the vote is granted, the reply carries the voter's `state.getLastEntry()`.
6. The candidate reaches `LeaderElection.waitForResults`, which is the real
   consumer of vote-reply last-entry evidence.

Concrete trigger scenario considered:

1. A three-server group has committed entries through index 100 on servers A
   and B. Server C only has entries through index 90.
2. Server A's storage is accidentally reformatted or recovered as empty, so its
   durable log evidence is empty/default.
3. Server C starts an election.
4. Server A receives C's request vote and grants it if C is in the current
   configuration, has a term high enough, has no valid different leader, and
   has a last log at least as up-to-date as A's now-empty local log.
5. In current code, A's new-version vote reply includes
   `lastEntry=(term=0,index=-1)`.
6. In current code, C rejects A's successful vote for the purpose of majority if
   C has committed entries, because `LeaderElection.nonEmptyLog` returns false
   for explicit empty-log evidence.

Safeguards encountered:

- The voter-side Raft 5.4.1 check in `VoteContext.decideVote` can reject a
  stale candidate when the voter has a non-empty up-to-date log. It cannot help
  when the voter's own storage/log evidence has already become empty.
- The candidate-side guard in `LeaderElection.waitForResults` masks the
  reformatted-voter vote for current new-version peers by requiring
  non-empty-log evidence when the candidate has committed entries.
- `LeaderElection.nonEmptyLog` intentionally accepts `TermIndex.PROTO_DEFAULT`
  `(0,0)` as old-version compatibility, because older voters did not include
  `lastEntry`.

## Developer Knowledge Search

Issue tracker and PR search:

- Apache JIRA `RATIS-1995` is titled "Prevent data loss when a storage is
  accidentally re-formatted". Its description gives the same mechanism: A and B
  at commit index 100, C at 90, A accidentally reformatted and restarted with
  commit index -1, C starts election, A votes for it, and commits 91-100 are
  lost. The issue is `Resolved` with resolution `Fixed`, created
  `2024-01-10`, updated `2025-05-16`.
- GitHub PR `apache/ratis#1261` is titled
  "RATIS-1995. Prevent data loss when a storage is accidentally re-formatted",
  was merged `2025-05-16T11:43:24Z`, and states it also refactors server calls
  to `ServerInterface` to add new tests.
- The PR changed `LeaderElection.waitForResults` to exclude votes from explicit
  empty-log voters when the candidate has non-empty commits, changed
  `ServerProtoUtils.toRequestVoteReplyProto` to include `lastEntry`, added
  `TermIndex.PROTO_DEFAULT`, and added
  `ratis-test/src/test/java/org/apache/ratis/server/impl/TestLeaderElectionServerInterface.java`.
- GitHub search for closed PRs with `RATIS-1995`, `re-formatted`, or
  `empty log voters` returned `#1261` as the same mechanism. A search for
  `RequestVote` and `lastEntry` returned older PR `#500` for a different
  rejected-request state-change issue, not this mechanism.
- Read-only `git fetch --all --prune` confirmed the latest fetched
  `origin/master` is `64e5b3442`; the only new commit after this checkout is
  streaming/data-stream related and does not touch the affected election or
  storage recovery files.
- Target-specific historical issues `RATIS-2234` and `RATIS-1305` exist but
  concern heartbeat/append locking and snapshot-install loops, not this
  vote-evidence/reformatted-storage mechanism.

Comments/docs/tests:

- `LeaderElection.nonEmptyLog` documents that old versions may not include
  `lastEntry` in vote replies and returns true for that compatibility case.
- `TestLeaderElectionServerInterface.testVoterWithEmptyLog` asserts the current
  intended behavior: a candidate with non-empty commits fails election with two
  explicit empty-log voters, passes with one non-empty-log voter, and passes
  with one old-version `PROTO_DEFAULT` voter.

## Known Status / Precedent

This code-review finding duplicates the already-filed and already-fixed
RATIS-1995 / GitHub PR #1261 mechanism at the same site:
reformatted storage produces empty durable log evidence, the reformatted server
can still grant a RequestVote, and the election result depends on whether the
candidate counts that voter's evidence. Current code contains the RATIS-1995
candidate-side filter and regression test.

Known citation:

- https://issues.apache.org/jira/browse/RATIS-1995
- https://github.com/apache/ratis/pull/1261

Known fix status: fixed.
