# Confirmation Report — ratis-server

## Final Result

Reproduced bugs: 1 = 1 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 0
False positives: 1
Dropped: 2
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 5
Dispositions: 5 total = 1 reproduced + 0 env-limited + 1 masked + 1 false-positive + 0 needs-more-info + 2 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | MASKED | no |
| 3 | CR-2 | DROPPED | no |
| 4 | CR-3 | DROPPED | no |
| 5 | CR-5 | FALSE POSITIVE | no |

## Entry 1: Async flush failure can advance commit ahead of durable log

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/SegmentedRaftLogWorker.java:415

## Description
`SegmentedRaftLogWorker.asyncFlushOutStream` advances `flushIndex` with `updateFlushedIndexIncreasingly(lastWrittenIndex)` even when the async flush future completes with an exception. `RaftLogBase.updateCommitIndex` then bounds commit by this incorrect `flushIndex`, so the leader can commit and reply success for an entry whose local `FileChannel.force(false)` failed.

## Trigger scenario
Checklist:

1. Did Level 0 or Level 1 alone trigger it: **no**. Level 0 normal public client write succeeded without an async force exception; Level 1 timing-only waiting did not create a `FileChannel.force(false)` failure, and no built-in Ratis failpoint exists at `BufferedWriteChannel.fileChannelForce`.
2. Level 2 was used only to inject the admissible MC fault: one `IOException` from the leader’s already-opened `FileChannel.force(false)`, corresponding to the counterexample step “async flush completed with exception.” Real API sequence: start simulated Ratis cluster, perform normal client write, then call normal admin `setConfiguration ADD listener`.
3. Real consumer/caller observing the wrong outcome: the admin client receives success through `RaftServerImpl.replyPendingRequest` at `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1885` / `:1913`, after state-machine apply at `RaftServerImpl.java:1974`; commit is consumed by `StateMachineUpdater.applyLog`.
4. The bad state was not masked in the observed run. After the failed async force, `flushIndex` and `commitIndex` advanced and the admin client completed successfully. No downstream sync, retry, resend, loopback, or caller guard resolved it before success was exposed.

## Developer intent
Prior-report search covered upstream GitHub issues, merged/closed PRs, and Apache Jira for this mechanism. I found adjacent async-flush work, but not this failure-path report.

Relevant adjacent history:
- RATIS-1644 / PR #699 introduced safe async flush and states commit should be updated after flush completion: https://issues.apache.org/jira/browse/RATIS-1644 and https://github.com/apache/ratis/pull/699
- PR #616 added async flush support: https://github.com/apache/ratis/pull/616

Those do not report the current mechanism where an exceptional async force still advances `flushIndex`. Novelty is therefore `NEW`.

## Reproduction result
Reproduction test written and executed:

`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/repro/test_bugMC-1_async_flush_failure.sh`

Real output:

```text
[INFO] Running org.apache.ratis.SpeculaAsyncFlushFailureTest
[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 2.085 s -- in org.apache.ratis.SpeculaAsyncFlushFailureTest
[INFO] BUILD SUCCESS
SUREFIRE_OUTPUT: ratis-server/target/surefire-reports/org.apache.ratis.SpeculaAsyncFlushFailureTest-output.txt
LEVEL0_RESULT=normal public client write before fault injection succeeded; no async force exception/no bug trigger
LEVEL1_RESULT=timing-only wait around normal operations did not create FileChannel.force IOException; no Ratis failpoint exists at BufferedWriteChannel.fileChannelForce
LEVEL=2 state injection: injected one IOException from the leader FileChannel.force(false)
ADMISSIBLE_FAULT=MC counterexample step: async flush completed with exception
PUBLIC_SEQUENCE=start simulated Ratis cluster; normal client write; normal admin setConfiguration ADD listener
FORCE_ATTEMPTS=4
FORCE_FAILURES=1
TARGET_INDEX=3
BEFORE_COMMIT=2
BEFORE_FLUSH=2
ADMIN_REPLY_SUCCESS=true
AFTER_COMMIT=6
AFTER_FLUSH=6
BUG_TRIGGERED: async force failed, but flushIndex/commitIndex advanced and admin client got success
```

## Recommendation
Move `updateFlushedIndexIncreasingly(...)` and write-task completion in `asyncFlushOutStream` behind the successful flush path only. On async flush failure, propagate the failure to waiting write tasks and avoid marking entries durable or commit-eligible. Add a regression test where `FileChannel.force(false)` fails during async flush and assert that `flushIndex`, commit, and client/admin success do not advance for the failed flush coverage.

---

## Entry 2: Old leader lease read can race with NOT_LEADER reply handling

- **Finding ID**: MC-2
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java:106

## Description

The source ordering matches the model concern: `LogAppenderDefault` records `lastRespondedAppendEntriesSendTime(sendTime)` before `handleReply` processes `NOT_LEADER` and calls `onFollowerTerm`. That timestamp can feed `LeaderStateImpl.hasLease()` and the lease fast path in `getReadIndex()`.

I did not reproduce a stale read. In the executable reproduction, the old server was demoted to `FOLLOWER`, and the real linearizable read path returned `ReadIndexException: Leader is unknown` instead of returning the old state.

## Trigger scenario

The repro creates a 3-node simulated-RPC Ratis cluster, enables linearizable read with leader lease, commits value `1` on the old leader, partitions the old leader, waits for a replacement leader, commits value `2` on the new leader, then tries old-leader reads. Level 3 also temporarily delays `LogAppenderDefault` after the suspected timestamp update point, but the marker for the exact NOT_LEADER-after-timestamp window did not fire.

## Developer intent

Linearizable reads should not be served by an old leader after another leader has committed newer state. If a server is no longer leader or does not know a valid leader for ReadIndex forwarding, it should reject instead of serving a local stale state-machine query.

## Reproduction result

Executed:

```text
/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/repro/test_bugMC-2_old_leader_lease_read.sh
```

Key output:

```text
MC2_REPRO_START 2026-08-04T11:34:26Z
HEAD=7eedc1deed07fc883bfe448b2d33438b7a0e994e
LEVEL0_COMMAND_STATUS=0
LEVEL1_COMMAND_STATUS=0
LEVEL3_PATCH=delay_after_updateLastRespondedAppendEntriesSendTime_for_NOT_LEADER
LEVEL3_COMMAND_STATUS=0
MC2_REPRO_END 2026-08-04T11:37:26Z
```

Surefire result excerpt:

```text
MC2_RESULT level=LEVEL3 attempt=6 staleReadObserved=false replacementLeaderObserved=true oldLeaseExpiredBeforeReplacement=true oldLeaderFinalRole=FOLLOWER newLeaderId=s2 notLeaderTimestampObserved=false readAttempts=218 staleValue=-1 detail="first=FAILED_REPLY exception=org.apache.ratis.protocol.exceptions.ReadIndexException: s1@group-FD3ADB2F0A87: Leader is unknown.; last=FAILED_REPLY exception=org.apache.ratis.protocol.exceptions.ReadIndexException: s1@group-FD3ADB2F0A87: Leader is unknown."
```

## Recommendation

Keep a regression test around this leadership-change read path. For extra hardening, consider moving `NOT_LEADER` handling before lease timestamp updates, or updating `lastRespondedAppendEntriesSendTime` only for replies that can legitimately renew leadership evidence.

---

## Entry 3: Recovered or reformatted voter election evidence may be inconsistent

- **Finding ID**: CR-2
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://issues.apache.org/jira/browse/RATIS-1995; fix-status: fixed)
- **Location**: `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderElection.java:576`

## Description

CR-2 matches already-filed RATIS-1995: an accidentally reformatted voter can grant a RequestVote with empty local log evidence, which previously could let a stale candidate win and lose committed entries. Current Ratis contains the RATIS-1995 fix from PR https://github.com/apache/ratis/pull/1261: candidates with non-empty commits discount successful votes from explicit empty-log voters.

## Trigger scenario

Three voters: A and B have committed through index 100, C is behind at 90. A is accidentally reformatted/restarted with empty storage, C starts an election, and A grants C a vote. This is the same mechanism described in RATIS-1995.

## Developer intent

JIRA RATIS-1995 is resolved Fixed. PR #1261 added `lastEntry` to vote replies, `LeaderElection.nonEmptyLog`, and `TestLeaderElectionServerInterface#testVoterWithEmptyLog`, which asserts the intended behavior: reject explicit empty-log voters for non-empty-commit candidates, while preserving old-version compatibility for missing `lastEntry`.

## Reproduction result

Repro script written and executed:

`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/repro/test_bugCR-2_known_ratis1995.sh`

Command:

```bash
timeout 15m ./mvnw -pl ratis-test -am -DargLine=-XX:+PerfDisableSharedMem -Dtest=org.apache.ratis.server.impl.TestLeaderElectionServerInterface#testVoterWithEmptyLog -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false test
```

Output excerpt:

```text
[INFO] Running org.apache.ratis.server.impl.TestLeaderElectionServerInterface
[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
[INFO] Finished at: 2026-08-04T11:47:58Z
```

Full output saved to:

`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/repro/test_bugCR-2_known_ratis1995.out`

## Recommendation

Do not file as a new Specula bug. This is a code-review duplicate of already-reported and fixed RATIS-1995 / apache/ratis#1261; keep the existing regression coverage.

---

## Entry 4: Snapshot installation can interleave with append and ReadIndex state

- **Finding ID**: CR-3
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/apache/ratis/pull/1444, https://github.com/apache/ratis/pull/1372, https://issues.apache.org/jira/browse/RATIS-1481; fix-status: fixed)
- **Location**: ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java:276

## Description

CR-3 is a code-review candidate, but this mechanism is already reported and fixed upstream. The same snapshot-install interleavings are covered by RATIS-2511/PR #1444 for ReadIndex during snapshot install, RATIS-2430/PR #1372 for partial chunk snapshot publication, and RATIS-1481/PR #573 for notification-mode AppendEntries/in-progress state ordering.

## Trigger scenario

A leader sends snapshot chunks or snapshot-install notifications to a lagging follower while AppendEntries and follower linearizable reads are in flight. Current code sets `inProgressInstallSnapshotIndex`, fails pending/new ReadIndex waits, rejects AppendEntries as inconsistent while install is in progress, and only publishes chunk snapshots after the final chunk.

## Developer intent

Upstream issue/PR and git-history search found same-site fixes already merged: `0355d33e0` (RATIS-2511/#1444), `d430b4d45` (RATIS-2430/#1372), `7167fafe7` (RATIS-1481/#573), plus related `b735bb520` (RATIS-1402/#504). This is code-review × already-reported/fixed, so it is not a new finding.

## Reproduction result

Executed: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/repro/test_bugCR-3_known_fixed.sh`

Captured output excerpt:

```text
HEAD: 7eedc1deed07fc883bfe448b2d33438b7a0e994e
Known upstream reports/fixes covering this mechanism:
d430b4d45 RATIS-2430. Write snapshot to temporary path until finish (#1372)
0355d33e0 RATIS-2511. Follower should throw ReadException if it is installing snapshot (#1444)
7167fafe7 RATIS-1481. make state upgradate in notifyStateMachineToInstallSnapshot serialized (#573)
b735bb520 RATIS-1402. do not send extra rpc calls to follower when the follower is still installing a snapshot (#504)
[INFO] Running org.apache.ratis.grpc.TestLinearizableReadWithGrpc
[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

## Recommendation

No new fix is needed for CR-3 on this tree. Keep the upstream regression coverage for follower ReadIndex during snapshot install and the existing snapshot publish/in-progress guards.

---

## Entry 5: Reconfiguration catch-up and leader recognition may use inconsistent membership guards

- **Finding ID**: CR-5
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java:330

## Description

CR-5 is not a current Ratis bug. The apparent mismatch is intentional joint-consensus behavior: `RequestVote` only accepts candidates in the current/new configuration, while `AppendEntries`/`InstallSnapshot` may continue recognizing the same-term current leader so an old-conf leader can finish transitional replication before stepping down after the final stable new configuration commits.

The downstream consumers also use the correct guards: transitional commit uses old+new majorities, removed leaders close after final new-conf commit, and stale uncommitted configuration changes are handled by NotLeader/truncation recovery.

## Trigger scenario

I tested the reachable scenarios for this mechanism:

1. Normal client `setConfiguration` removing the current leader.
2. Timing-assisted stale-old-leader path where a config entry is persisted but not committed.
3. Reachable state-injection of a transitional single-to-HA configuration.

## Developer intent

Relevant intent is already encoded in upstream tests and comments. `RaftConfigurationImpl.hasMajority` requires both old and new majorities during transitional configs; `LeaderStateImpl.checkAndUpdateConfiguration` closes a leader not in the final new conf only after the stable new-conf entry commits. Adjacent prior work was checked and is not the same mechanism: RATIS-2274 / PR #1246, RATIS-2154 / PR #1148, and RATIS-2008 / PR #1024.

## Reproduction result

Repro test written and executed:

`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/repro/test_bugCR-5_membership_guards.sh`

Real output excerpt:

```text
CR-5 reproduction attempt on 7eedc1deed07fc883bfe448b2d33438b7a0e994e

== Level 0 public API: testLeaderStepDown ==
maven-exit: 0
Tests run: 1, Failures: 0, Errors: 0, Skipped: 0

== Level 1 timing assistance: testRevertConfigurationChange ==
maven-exit: 0
Tests run: 1, Failures: 0, Errors: 0, Skipped: 0

== Level 2 reachable state injection: testLeaderElectionWhenChangeFromSingleToHA ==
maven-exit: 0
Tests run: 1, Failures: 0, Errors: 0, Skipped: 0

Level 3 source patch: not applied.
Reason: after Levels 0-2, the only way to force a bad old-only leader outcome would be to fabricate an old-only higher-term leader that RequestVote cannot elect under VoteContext.checkConf; that is an unreachable precondition, not a sound CR-5 reproduction.

CR-5 result: no reproduced live harm from reconfiguration catch-up, leader recognition, or RequestVote membership guards.
```

## Recommendation

No code fix for CR-5. If maintainers want clearer future auditing, add a focused regression/comment explaining that old-conf same-term leader recognition is allowed during joint consensus, while new elections remain current-conf guarded.

---
