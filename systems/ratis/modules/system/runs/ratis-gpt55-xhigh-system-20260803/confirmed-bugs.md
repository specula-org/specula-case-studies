# Confirmation Report — ratis-system

## Final Result

Reproduced bugs: 4 = 4 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 2
Dropped: 2
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 8
Dispositions: 8 total = 4 reproduced + 0 env-limited + 0 masked + 2 false-positive + 0 needs-more-info + 2 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | MC-4 | REPRODUCED | yes |
| 5 | CR-3 | FALSE POSITIVE | no |
| 6 | CR-4 | DROPPED | no |
| 7 | CR-5 | DROPPED | no |
| 8 | CR-6 | FALSE POSITIVE | no |

## Entry 1: Stale AppendEntries SUCCESS after higher-term vote can let an old leader commit an entry absent from the new leader

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1754

Checklist before `REPRODUCED`:

1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 3 hooks were used only to expose admissible counterexample steps: CE State 9 `appendEntriesAsync_RegisterInFlight(s3)` and CE State 10 `requestVote_Grant(s3,s1)`. The runtime sequence was: real client write to old leader -> real gRPC `AppendEntries` reaches target follower before RaftLog append -> real `RequestVote` grants/persists higher term -> old append completes and returns stale `SUCCESS`.
3. Real consumer/caller observing the wrong outcome: the old-leader client receives a successful `RaftClientReply` through pending request completion (`ratis-server/src/main/java/org/apache/ratis/server/impl/PendingRequest.java:90`; called from `LeaderStateImpl.replyPendingRequest`).
4. The bad state is not masked before observation. Later new-leader sync can remove the stale entry from the target follower, but the old leader has already returned success for log index 1; that is a permanent client-visible safety violation, not a repair.

## Description

Confirmed. A follower can grant and persist a higher-term vote after accepting an old leader’s append but before the async RaftLog append completes. The old append completion still builds `AppendResult.SUCCESS` using the stale captured term. The gRPC leader-side handler then treats that `SUCCESS` as valid follower progress and advances match/commit, allowing the old leader to reply success for an entry absent from the new leader.

Prior-report search covered upstream issues, PRs, Jira text search, and git history. Adjacent fixes such as RATIS-2605/#1519 and RATIS-2154/#1148 do not cover this in-flight append completion after higher-term vote mechanism.

## Trigger scenario

A 3-node gRPC cluster is partitioned by timing only:

- old leader appends client entry `(t:2, i:1)`;
- target follower accepts old leader’s `AppendEntries` but is held before `state.getLog().append(entries)`;
- target grants and persists higher-term vote for candidate `s1`;
- target then completes the old append and returns stale `SUCCESS`;
- old leader commits/replies success;
- candidate becomes leader in term 3 without the entry.

## Developer intent

Raft Leader Completeness requires any entry committed in a term to be present in all later leaders. A follower that has moved to a higher election term should not emit a stale old-term append success that an old leader can count toward commit.

## Reproduction result

Executed:

```text
/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/repro/test_bugMC-1_stale_append_success.sh
```

Real output excerpts:

```text
MC-1 trigger reached
oldLeader=s0 oldTerm=2
candidateNewLeader=s1 term=3
targetVotedFor=s1 targetTerm=3
blockedEntry=(t:2, i:1)
oldLeaderReplySuccess=true replyLogIndex=1 replier=s0
oldLeaderCommittedIndex=1
newLeaderContainsEntry=false
targetContainsEntryBeforeNewLeader=true
targetContainsEntryAfterNewLeaderSync=false
[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
MC-1 reproduction exit_status=0
```

Artifacts written:
`repro/test_bugMC-1_stale_append_success.sh`, `confirmation/MC-1/investigation.md`, `confirmation/MC-1/repro-MC-1.log`.

## Recommendation

Recheck follower term/leader recognition after async append completion and before returning `SUCCESS`; if current term advanced, return the current term and do not report old-leader success. Also harden `GrpcLogAppender` so `SUCCESS` replies are ignored unless they match the leader’s current term/epoch.

---

## Entry 2: Append compose can return SUCCESS for a mismatched future at the same start index

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: ratis-server/src/main/java/org/apache/ratis/server/impl/ServerImplUtils.java:150

## Description

`NavigableIndices.append` composes in-flight append work by `startIndex` only. If an older append for `index=1, term=1, value=v1` is still tracked, a later append for `index=1, term=2, value=v2` takes the existing future and completes successfully without calling `appendLog` for the later entry.

`RaftServerImpl.appendEntriesAsync` then turns that completed future into `AppendResult.SUCCESS`, and leader-side consumers can advance follower progress from that success.

## Trigger scenario

Counterexample sequence matched in Level 2:

1. State 22: follower `s1` has in-flight append from old leader `s2`, `start=1, term=1`.
2. State 24: new leader `s3` sends `start=1, term=2`; `NavigableIndices` takes `ComposeExisting`.
3. State 27: follower replies `SUCCESS` for term-2/index-1 while `logTerm(s1)` is still term 1 at index 1.

## Developer intent

`RaftLogSequentialOps.append(List)` documents that same-index/different-term conflicts should delete the existing entry and following entries. The compose branch bypasses that conflict path by not calling `appendLog`.

Known-status search covered GitHub issue/PR API, local `git log`, `git blame`, and docs/tests. Closest precedent is RATIS-2278 / PR #1248, which handled same-startIndex duplicate retry/validation, not mismatched term/value success:
https://issues.apache.org/jira/browse/RATIS-2278
https://github.com/apache/ratis/pull/1248

## Reproduction result

Test written and executed:

`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/repro/test_bugMC-2_append_compose_mismatch.sh`

Command:

```bash
timeout 25m /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/repro/test_bugMC-2_append_compose_mismatch.sh > /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/MC-2/repro-MC-2.log 2>&1
```

Captured output:

```text
MC-2 repro: Level 0 pure black-box was not encoded in this component repro script.
MC-2 repro: Level 1 timing-assisted cluster run needs a pre-append visibility hook not present in the stock harness.
MC-2 repro: executing Level 2 admissible-state test from counterexample step 24.
[INFO] Running org.apache.ratis.server.impl.TestBugMC2AppendComposeMismatch
[INFO] Running org.apache.ratis.server.leader.TestBugMC2AppendReplyConsumer
[INFO] Tests run: 2, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
MC-2_LEVEL2_REPRO: second request startIndex=1 term=2 value=v2 completed via reused future
MC-2_LEVEL2_REPRO: appendLog calls=1, physical entry term=1, physical entry value=v1
MC-2_CONSUMER_REPRO: LogAppenderDefault.handleReply advanced matchIndex=1 nextIndex=2 from SUCCESS
```

Checklist before `REPRODUCED`:

1. Did Level 0 or Level 1 alone trigger it? no.
2. Level 2 injected precondition: counterexample State 24, where `ComposeExisting(s1)` sees old in-flight `start=1, term=1` and later request `start=1, term=2`.
3. Real consumer/caller: `LogAppenderDefault.handleReply` at `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java:192`; gRPC equivalent is `GrpcLogAppender.java:515`.
4. Bad follower log divergence may later be repaired by resend/inconsistency, but the false SUCCESS and leader progress update happen before that repair, so the observed wrong outcome is not masked.

## Recommendation

Make compose identity include the exact covered entries, at least `(startIndex, count, term ranges)` and preferably validate the entries against the in-flight record before reusing a future. If the start index matches but term/value differs, do not compose; route the request through normal raft-log append/truncate conflict handling or return inconsistency.

---

## Entry 3: Metadata persist failure can leave an accepted leader term non-durable

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:642

## Description
Confirmed. `changeToFollowerAndPersistMetadata` can advance the in-memory term before `persistMetadata()` succeeds. A later same-term `AppendEntries` can be accepted without retrying term persistence, leaving `currentTerm=1` while durable `raft-meta` still records term `0`. After restart, the server reloads term `0` and can grant a same-term vote to another candidate.

I searched upstream Apache Ratis issues/PRs and recent git history for this mechanism (`raft-meta`, `persistMetadata`, `changeToFollowerAndPersistMetadata`, same-term leader recognition) and found no prior report or recently landed fix.

## Trigger scenario
1. Follower `s2` starts with volatile and persisted term `0`.
2. `s1` sends higher-term `AppendEntries(term=1)`.
3. Metadata persistence fails after the volatile term is raised, matching counterexample State 2: `MCRaftServerImpl_changeToFollowerAndPersistMetadata_PersistFailure(s2,s1,1)`.
4. Storage becomes writable again; `s1` sends same-term `AppendEntries(term=1)`.
5. Ratis accepts the same-term leader and returns `SUCCESS`, but persisted term remains `0`.
6. After restart, `s2` reloads term `0` and grants `RequestVote(term=1)` to `s3`.

## Developer intent
`raft-meta` is the durable source for `currentTerm` and `votedFor` across restart. `changeToFollowerAndPersistMetadata` is the intended persistence point when a higher term is observed. Same-term leader recognition should not allow successful Raft traffic after a failed term durability update without forcing a retry or preventing acceptance.

## Reproduction result
Reproduction test written and executed:

`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/repro/test_bugMC-3_metadata_persist_failure.sh`

Checklist before `REPRODUCED`:

1. Did Level 0 or Level 1 alone trigger it? **no**. Level 0 control did not trigger it; the reproducer injects a real filesystem metadata-write failure.
2. No source patch or unreachable state was used. The injected precondition is the admissible counterexample step `MCRaftServerImpl_changeToFollowerAndPersistMetadata_PersistFailure(s2,s1,1)`, implemented by making the real storage `current/` directory non-writable during the higher-term append.
3. Real consumers observe the wrong outcome: `RaftServerImpl.appendEntries` returns `SUCCESS`; production gRPC leader code consumes that in `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:493` and forwards the reply at `GrpcLogAppender.java:547`. After restart, `RaftServerImpl.requestVote` returns `voteGranted=true` to the election caller at `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderElection.java:155`.
4. The bad state is not masked before crash. Same-term append skips the failed persistence retry; restart reloads the older durable term and allows a same-term vote to another candidate. No downstream sync/loopback/resend guard resolved it in the reproduced path.

Actual output:

```text
MC3_REPRO_COMMAND timeout 12m ./mvnw -pl ratis-server -am -Dtest=TestBugMC3MetadataPersistFailure#metadataPersistFailureAllowsSameTermAppendToRemainNonDurable test
[INFO] Running org.apache.ratis.server.impl.TestBugMC3MetadataPersistFailure
[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 2.906 s -- in org.apache.ratis.server.impl.TestBugMC3MetadataPersistFailure
[INFO] BUILD SUCCESS
MC3_MAVEN_EXIT 0
MC3_SUREFIRE_MARKERS
ratis-server/target/surefire-reports/org.apache.ratis.server.impl.TestBugMC3MetadataPersistFailure-output.txt:4:MC3_LEVEL0_CONTROL result=SUCCESS volatileTerm=0 persistedTerm=0
ratis-server/target/surefire-reports/org.apache.ratis.server.impl.TestBugMC3MetadataPersistFailure-output.txt:5:MC3_FAULT_STEP firstHigherTermAppendFailed=AccessDeniedException volatileTerm=1 persistedTerm=0
ratis-server/target/surefire-reports/org.apache.ratis.server.impl.TestBugMC3MetadataPersistFailure-output.txt:6:MC3_BUG_ACCEPTED_SAME_TERM_APPEND result=SUCCESS replySuccess=true leaderId=s1 volatileTerm=1 persistedTerm=0
ratis-server/target/surefire-reports/org.apache.ratis.server.impl.TestBugMC3MetadataPersistFailure-output.txt:7:MC3_AFTER_RESTART volatileTerm=0 persistedTerm=0
ratis-server/target/surefire-reports/org.apache.ratis.server.impl.TestBugMC3MetadataPersistFailure-output.txt:8:MC3_BUG_SAME_TERM_VOTE_AFTER_ACCEPTED_LEADER voteGranted=true candidate=s3 volatileTerm=1 votedFor=s3
```

## Recommendation
Do not leave a raised volatile term as accepted state when metadata persistence fails. Either persist the new term before exposing same-term leader acceptance, roll back/mark the term as dirty on persistence failure, or force a metadata retry before returning success for same-term `AppendEntries`.

---

## Entry 4: Higher-term step-down event can be dropped by type-only queue deduplication

- **Finding ID**: MC-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/MC-4/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:129`

## Description
`LeaderStateImpl.StateUpdateEvent.equals` compares only `StateUpdateEvent.Type`. `EventQueue.submit` then uses `queue.contains(event)` to avoid duplicates, so an already queued low-term `STEP_DOWN` causes a later higher-term `STEP_DOWN` to be dropped before its captured term can execute.

## Trigger scenario
A leader has a caught-up follower and receives two higher-term `NOT_LEADER` reports before the event processor drains the first `STEP_DOWN`. The first report enqueues `STEP_DOWN(term=2)`. The second report reaches `LeaderStateImpl.onFollowerTerm(..., term=3)`, matching the counterexample’s later higher-term step-down step, but the queue discards it because another `STEP_DOWN` type is already present.

## Developer intent
`onFollowerTerm` is intended to step down and persist metadata when a caught-up follower reports a higher term. `VoteContext.checkTerm` relies on the server’s current term to reject stale vote requests; losing the highest observed step-down term breaks that assumption.

## Reproduction result
Executed: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/repro/test_bugMC-4_stepdown_event_dedup.sh`

```text
repro: MC-4 higher-term STEP_DOWN dropped by type-only EventQueue dedup
command: timeout 20m ./mvnw -pl ratis-test -am -DskipShade -Drat.skip=true -Dcheckstyle.skip=true -Dspotbugs.skip=true -Djacoco.skip=true -DfailIfNoTests=false -Dtest=TestLeaderStepDownEventQueueDedup#testHigherTermStepDownDroppedByTypeOnlyDedup test
[INFO] Running org.apache.ratis.server.impl.TestLeaderStepDownEventQueueDedup
[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 1.763 s -- in org.apache.ratis.server.impl.TestLeaderStepDownEventQueueDedup
[INFO] BUILD SUCCESS
```

Surefire captured output:

```text
LEVEL 0: normal cluster start and leader election reached term 1; pure black-box run does not deterministically overlap two queued STEP_DOWN events.
LEVEL 1: using the Ratis CodeInjectionForTesting hook to block one EventQueue.poll.
LEVEL 3: the only source change is the test hook before EventQueue.poll; core logic is unchanged.
LEVEL 2: submitted caught-up follower terms 2 then 3 through LeaderStateImpl.onFollowerTerm; this instantiates CE State 5 and State 11.
OBSERVED: after draining STEP_DOWN queue currentTerm=2, expected=3 if the higher-term STEP_DOWN had not been dropped.
OBSERVED: requestVote(term=2) success=true, replyTerm=2; correct high-term state would reject this stale candidate with term 3.
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2/3 was used. The injected sequence is admissible: CE State 5 queues the first step-down; CE State 11 observes a later higher-term step-down while the first remains queued. The concrete test sequence is real `LeaderStateImpl.onFollowerTerm(caughtUpFollower, 2)` then `LeaderStateImpl.onFollowerTerm(caughtUpFollower, 3)`, with only a timing hook before `EventQueue.poll`.
3. Real consumer/caller: `RaftServerImpl.requestVote` at `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1500`, via `VoteContext.checkTerm` at `ratis-server/src/main/java/org/apache/ratis/server/impl/VoteContext.java:75`, observes the wrong stale term and grants `requestVote(term=2)`.
4. The bad state is not masked by an internal resend/merge/loopback. It persists the lower term until an unrelated future higher-term RPC happens to repair it; the repro shows a real vote request consuming the stale term first.

## Recommendation
Make step-down queue coalescing term-aware. For duplicate `STEP_DOWN` events, retain or replace with the maximum observed term and corresponding reason instead of dropping later same-type events solely by `Type`.

---

## Entry 5: Snapshot, purge, restart, and configuration frontier interleavings can leave stale or discontinuous follower state

- **Finding ID**: CR-3
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderBase.java:225

## Description
CR-3 did not reproduce as a current Ratis bug. The audited code has explicit guards for the suspected frontier: when the leader cannot find the previous log entry, append composition is skipped and the appender routes the follower through snapshot install/notification; follower snapshot installation then reloads log/state-machine state before reporting `SNAPSHOT_INSTALLED`.

## Trigger scenario
Exercised snapshot bootstrap, snapshot notification with asynchronous state-machine delay, leader log purge frontier with follower `nextIndex` at the leader start index, restart, and configuration change after adding a peer.

## Developer intent
Upstream has fixed adjacent historical issues, including PR #1420 / RATIS-2487, PR #573 / RATIS-1481, PR #1053 / RATIS-2045, and PR #1257 / RATIS-2291. These are not a current exact duplicate of CR-3, but they explain the current safeguards and tests.

## Reproduction result
Wrote and executed:
`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/repro/test_bugCR-3_snapshot_frontier.sh`

Command:
`timeout 120m .../repro/test_bugCR-3_snapshot_frontier.sh`

Output:
```text
===== LEVEL 0 normal chunked snapshot bootstrap =====
EXIT_CODE: 0
===== LEVEL 1 notification snapshot bootstrap with state-machine delay =====
EXIT_CODE: 0
===== LEVEL 2 reachable purge frontier injection for follower nextIndex =====
EXIT_CODE: 0
===== LEVEL 3 source-delay widened notification reload window plus purge restart config =====
EXIT_CODE: 0
CR3_RESULT: all targeted snapshot-frontier tests passed
CR3_OBSERVED_BUG: no
```

Surefire summaries showed all targeted tests passed with 0 failures/errors.

## Recommendation
No repair is needed for CR-3 as stated. Keep the existing snapshot-frontier regression tests, especially the purged-previous-entry and install-snapshot-notification restart/configuration tests.

---

## Entry 6: Joint membership, staged catch-up, and listener promotion can disagree about when a peer is safely caught up

- **Finding ID**: CR-4
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/apache/ratis/pull/1246 and https://github.com/apache/ratis/pull/1331; fix-status: fixed)
- **Location**: ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:832

## Description
CR-4 duplicates upstream-reported Ratis defects. PR #1246 reports the same staged catch-up mechanism: a newly added peer can be treated as caught up while still missing timely configuration-change logs due to `stagingCatchupGap`. PR #1331 covers the listener role-transition and snapshot-carried configuration sites also named by CR-4.

## Trigger scenario
Normal `setConfiguration` can stage a new peer/listener, catch it up by log replication or snapshot, then enter joint consensus and final configuration commit. The already-reported unsafe case is a log-based catch-up path where the new peer is close enough to the commit index but has not received the latest configuration log entry.

## Developer intent
Upstream PR #1246 states the fix intent directly: `CAUGHTUP` should only complete after the follower receives the latest configuration logs. The current checkout contains that guard at `LeaderStateImpl.java:841`. PR #1331 fixes listener promotion by changing role only when a real configuration entry is applied, including snapshot-carried configuration.

## Reproduction result
Command executed:
```text
timeout 2m /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/repro/test_bugCR-4_known_prefilter.sh
```

Output:
```text
CR-4 known-status prefilter evidence
worktree=7eedc1deed07fc883bfe448b2d33438b7a0e994e
upstream PR #1246 commit:
c1301b082c3f9359dc510e6f5c26ff0d7a8a7e21 RATIS-2274. Newly added peer may retain outdated configuration after membership change, causing election failure. (#1246)
upstream PR #1331 commit:
d7370f897f43aa31d44beb3bf61933430bfb8355 RATIS-2378. fix listener role transition (#1331)
current checkProgress latest-config guard:
841:        && follower.getMatchIndex() >= server.getRaftConf().getLogEntryIndex()
current listener promotion on configuration application:
418:      server.changeToFollowerAndPersistMetadata(getCurrentTerm(), true, "setRaftConf").join();
current snapshot-carried configuration uses updateConfiguration:
156:          state.updateConfiguration(Collections.singletonList(proto));
RESULT: KNOWN fixed upstream; code-review prefilter applies; no live reproduction attempted.
```

## Recommendation
No new bug report for CR-4. For any older branch missing the fixes, backport PR #1246 and PR #1331 together so staged catch-up, listener promotion, and snapshot-carried configuration all share the fixed configuration-safety behavior.

---

## Entry 7: Client-visible read-index completion can race with delayed append replies, commit, apply, and replied-index flushing

- **Finding ID**: CR-5
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/apache/ratis/pull/1474; fix-status: fixed)
- **Location**: `ratis-server/src/main/java/org/apache/ratis/server/impl/ReplyFlusher.java:97`

## Description

CR-5 is code-review sourced and duplicates already reported/fixed upstream mechanisms. The `REPLIED_INDEX` ordering race at `ReplyFlusher` was reported and fixed by apache/ratis#1474; the read-index heartbeat `minCallId` mechanism was previously reported/fixed by apache/ratis#905. Current `HEAD` contains the relevant fixes: `f19aecdb8` for #1474 and `c1fd4e5dc` for the #905-equivalent patch.

## Trigger scenario

The hypothesized trigger is: delayed AppendEntries/read-index heartbeat replies satisfy read-index leadership/visibility checks while commit, apply, or `repliedIndex` flushing has not caught up. The exact same-site submechanisms are already public: `ReplyFlusher` could release write replies before `repliedIndex` covered them (#1474), and `HeartbeatAck` previously used an incorrect call-id boundary (#905).

## Developer intent

Developer history shows these were treated as bugs/fixes, not intended behavior. #1474 explicitly advances `repliedIndex` before completing write replies. #905 fixed the heartbeat acknowledgement call-id boundary used by `ReadIndexHeartbeats`.

## Reproduction result

Not executed. Per the installed `bug-confirmation` guide, the Phase-1 code-review x already-reported pre-filter applies and says to drop before Phase 2, writing no repro test.

Recorded evidence in:
`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/CR-5/investigation.md`

## Recommendation

No new bug report for CR-5. Treat it as a duplicate of known fixed upstream work, primarily apache/ratis#1474 with related apache/ratis#905 evidence.

---

## Entry 8: gRPC appender reconnect, timeout, and old replies can regress or overstate follower progress

- **Finding ID**: CR-6
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/CR-6/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:207`

## Description
CR-6 在当前代码上是 false positive。`resetClient`、timeout、delayed old reply 都可达，但当前实现没有把 `nextIndex` 回退到 `matchIndex` 以下，也没有让 delayed success reply 造成错误的 follower progress 或错误 linearizable read。旧 success reply 在 follower 完成 append 后返回时，推进 `matchIndex` 是有日志依据的；heartbeat reply 的 `matchIndex` 为 invalid，不能推进。

## Trigger scenario
Level 0 用公开 `RaftClient` 写入、停/重启 follower、gRPC reconnect/catch-up。Level 1 用现有 test hook 阻塞一个 follower 的真实 `AppendEntries` handler 超过 appender timeout，再解除阻塞，让 timed-out request 的 success reply 迟到返回。

## Developer intent
相关历史问题已被报告并修复，但不是当前 delayed-old-reply overstatement 机制：[#875](https://github.com/apache/ratis/pull/875) 处理 heartbeat failure 不应把 restarting follower 的 `nextIndex` 置 0，[#914](https://github.com/apache/ratis/pull/914) 处理 `nextIndex > matchIndex`，[#939](https://github.com/apache/ratis/pull/939) 处理 `GrpcLogAppender.resetClient` 降低 `nextIndex` 时遵守 `matchIndex + 1`。当前代码也体现了这个意图：error path clamp 到 `matchIndex + 1`，`matchIndex`/`nextIndex` 更新是 max-only，read-index ack 有 commit/callId 过滤。

## Reproduction result
Test written and executed: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/repro/test_bugCR-6_grpc_progress.sh`

Command:
```bash
timeout 12m /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/repro/test_bugCR-6_grpc_progress.sh
```

Real output excerpt:
```text
Tests run: 2, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 9.298 s -- in org.apache.ratis.grpc.TestSpeculaCR6GrpcProgress
CR6_PROGRESS level0 follower=s0 matchIndex=10 nextIndex=11
CR6_PROGRESS level0 follower=s1 matchIndex=10 nextIndex=11
CR6_LEVEL0_PASS_NO_BUG follower_restart_reconnect count=5 leader=s2 restartedFollower=s0
Timed out appendEntries, errorCount=1, request=AppendEntriesRequest:cid=10:entry=(t:1, i:3)
Timed out appendEntries, errorCount=2, request=AppendEntriesRequest:cid=12:entry=(t:1, i:4)
Timed out HEARTBEAT appendEntries, errorCount=3, request=AppendEntriesRequest:cid=15:HEARTBEAT
Timed out HEARTBEAT appendEntries, errorCount=4, request=AppendEntriesRequest:cid=17:HEARTBEAT
CR6_PROGRESS level1 follower=s1 matchIndex=4 nextIndex=5
CR6_PROGRESS level1 follower=s2 matchIndex=4 nextIndex=5
CR6_LEVEL1_PASS_NO_BUG timed_out_old_reply beforeTimeouts=0 afterTimeouts=4 slowFollower=s1 leader=s0
BUILD SUCCESS
CR6_LEVEL2_NOT_USED Level 1 already creates the reachable delayed old-reply precondition via a real gRPC cluster; direct state injection would call private handler state.
CR6_LEVEL3_NOT_USED No source patch was needed; patching GrpcLogAppender would create the symptom rather than exercise production logic.
CR6_REPRO_DONE status=PASS_NO_BUG
```

## Recommendation
No production fix for CR-6 as stated. Keep or add a regression test around delayed old reply after appender timeout, because it documents the intended safeguards: `nextIndex >= matchIndex + 1`, exact read-only result after delayed reply, and no progress overstatement.

---
