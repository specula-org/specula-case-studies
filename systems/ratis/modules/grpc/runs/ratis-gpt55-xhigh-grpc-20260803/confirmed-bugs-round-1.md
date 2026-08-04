# Confirmation Report — ratis-grpc

## Final Result

Reproduced bugs: 0 = 0 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 0
False positives: 2
Dropped: 1
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 4
Dispositions: 4 total = 0 reproduced + 0 env-limited + 1 masked + 2 false-positive + 0 needs-more-info + 1 dropped + 0 pending-repair + 0 incomplete + 0 deferred

| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | MASKED | no |
| 2 | MC-2 | FALSE POSITIVE | no |
| 3 | CR-1 | FALSE POSITIVE | no |
| 4 | CR-4 | DROPPED | no |

## Entry 1: Snapshot progress can be overwritten by a stale INCONSISTENCY reply

- **Finding ID**: MC-1
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:592`

## Description
A stale gRPC `INCONSISTENCY` append reply can be processed after snapshot progress has already moved the follower state to `snapshotIndex = S`, `matchIndex = S`, `nextIndex = S + 1`. The gRPC handler then calls `setNextIndex(...)` through `GrpcLogAppender.updateNextIndex`, lowering `nextIndex` below the recorded snapshot boundary.

This is a real progress-state defect, but the reproduction shows the next appender loop masks the live consequence by retrying snapshot work and restoring `nextIndex`.

## Trigger scenario
1. Leader reaches a real snapshot/purged-log state through normal client writes.
2. Snapshot handling records follower progress at `snapshotIndex=23`, `matchIndex=23`, `nextIndex=24`.
3. A reachable old append request beginning at `24` receives a stale `INCONSISTENCY` reply with `replyNextIndex=23`.
4. `GrpcLogAppender` applies the stale reply and lowers `nextIndex` to `23`.
5. `LogAppenderBase.newAppendEntriesRequest` observes the bad state, returns `null`, and `shouldInstallSnapshot()` triggers the snapshot retry mask.

## Developer intent
Upstream search covered open/closed issues and recently merged/closed PRs. Adjacent history exists, including RATIS-1883/#914, RATIS-1895/#926, RATIS-1909/#939, and RATIS-2283/#1250, but none reports this exact stale `INCONSISTENCY` after snapshot-progress mechanism. The local comment in `LogAppenderBase.getNextIndexForInconsistency` says `nextIndex` should ideally be greater than `matchIndex`, but the `requestFirstIndex` special case permits this stale-reply regression.

## Reproduction result
Reproduction test written and executed:

`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/repro/test_bugMC-1_snapshot_stale_inconsistency.sh`

Command:

```bash
timeout 12m /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/repro/test_bugMC-1_snapshot_stale_inconsistency.sh
```

Key output:

```text
LEVEL0: reached snapshot/purged-log state via client writes; snapshotIndex=23, leaderStartIndex=24, leaderNextIndex=33
LEVEL1: timing-only hooks cannot force response reordering after a follower computes INCONSISTENCY; escalating to Level2 with the reachable stale-reply order
LEVEL2: injected reachable precondition from InstallSnapshot ALREADY_INSTALLED/SNAPSHOT_INSTALLED handling; follower snapshotIndex=23, matchIndex=23, nextIndex=24
BUG_STATE: stale INCONSISTENCY replyNextIndex=23 overwrote snapshot boundary nextIndex=24; observed nextIndex=23, snapshotIndex=23, matchIndex=23
MASK_TRIGGER: newAppendEntriesRequest returned null and shouldInstallSnapshot returned (t:1, i:23); the next appender loop would reinstall/renotify the snapshot
MASK_RESOLUTION: completing the snapshot retry restores nextIndex=24
[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

Real consumer/caller: `LogAppenderBase.newAppendEntriesRequest` at `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderBase.java:229` observes the lowered `nextIndex` and suppresses append. Mask: `LogAppender.shouldInstallSnapshot` / `GrpcLogAppender.run` retries snapshot work, and snapshot completion restores `nextIndex`.

## Recommendation
Guard stale append replies against the snapshot boundary. In the `INCONSISTENCY` branch, clamp the computed next index to at least `snapshotIndex + 1` when snapshot progress is already recorded, or ignore append replies whose request range is older than the current snapshot progress.

## Repair round 1 evidence
<!-- specula-repair-token: f27c80c51f94deb865b92452ebbe2335 -->
- **Current violation analysis**: After the repair pass, the remaining current violation is that a follower can generate an INCONSISTENCY reply before snapshot progress is recorded, and the leader can receive that reply after SnapshotInstalled has raised matchIndex, snapshotIndex, and nextIndex. The normal INCONSISTENCY branch still computes a lower nextIndex with LogAppenderBase.getNextIndexForInconsistency and calls FollowerInfoImpl.setNextIndex. This can move nextIndex below the proven snapshot boundary, causing the leader to lose recorded replication progress and retry work below the installed snapshot.
- **Counterexample**: `spec/output/repair-final-MC_hunt_rg3_snapshot_race-20260803-223000.out`

## Phase 4 confirmation after repair round 1

- **Source**: MC
- **Novelty**: NEW
- **Location**: `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:592`

## Description
A stale gRPC `INCONSISTENCY` append reply can still lower follower `nextIndex` after snapshot progress has already recorded `snapshotIndex=S`, `matchIndex=S`, and `nextIndex=S+1`. The defect is real at the shared follower-progress state, but the live consequence is currently masked: the next append construction refuses to append below the available boundary and snapshot retry restores `nextIndex`.

## Trigger scenario
1. Snapshot progress records follower state at `snapshotIndex=23`, `matchIndex=23`, `nextIndex=24`.
2. A previously computed append `INCONSISTENCY` reply arrives later with `requestFirstIndex=24` and `replyNextIndex=23`.
3. `GrpcLogAppender` computes the inconsistency next index and calls `setNextIndex`, lowering `nextIndex` to `23`.
4. `LogAppenderBase.newAppendEntriesRequest` observes the lowered state and returns `null`.
5. `LogAppender.shouldInstallSnapshot` retries snapshot work and snapshot completion restores `nextIndex=24`.

## Developer intent
Open/closed issue and PR search plus fetched git history found adjacent work, including [PR #926](https://github.com/apache/ratis/pull/926), [PR #573](https://github.com/apache/ratis/pull/573), [PR #504](https://github.com/apache/ratis/pull/504), [PR #939](https://github.com/apache/ratis/pull/939), and [PR #1250](https://github.com/apache/ratis/pull/1250). None reports this exact stale `INCONSISTENCY` reply after snapshot-progress mechanism. The local `getNextIndexForInconsistency` comment says `nextIndex` should ideally stay above `matchIndex`, but its `requestFirstIndex` exception still permits this regression.

## Reproduction result
Reproduction test written and executed:

`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/repro/test_bugMC-1_snapshot_stale_inconsistency.sh`

Command:

```bash
timeout 12m /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/repro/test_bugMC-1_snapshot_stale_inconsistency.sh
```

Output excerpt:

```text
LEVEL0: reachable setup uses normal snapshot progress; snapshotIndex=23, matchIndex=23, nextIndex=24, leaderStartIndex=24, leaderNextIndex=33
LEVEL1: timing-only was not sufficient to force reply reordering in this unit harness; escalating to Level2 with the reachable stale-reply order.
LEVEL2: injected reachable stale INCONSISTENCY order; requestFirstIndex=24, replyNextIndex=23
BUG_STATE: stale INCONSISTENCY replyNextIndex=23 overwrote snapshot boundary nextIndex=24; observed nextIndex=23, snapshotIndex=23, matchIndex=23
MASK_TRIGGER: newAppendEntriesRequest returned null and shouldInstallSnapshot returned (t:1, i:23); the next appender loop would retry snapshot work
MASK_RESOLUTION: completing the snapshot retry restores nextIndex=24
LEVEL3: not used because Level2 proved the bad state and the normal snapshot retry mask.
[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

## Recommendation
Clamp stale `INCONSISTENCY` handling to the recorded snapshot boundary, e.g. ignore or clamp append replies whose request range is older than current snapshot progress so `nextIndex` cannot fall below `snapshotIndex + 1`.

---

## Entry 2: Staging appender restart discards proven catch-up progress

- **Finding ID**: MC-2
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:725

## Description

The counterexample’s state shape maps to real Ratis fields: snapshot installation can advance `snapshotIndex`, `matchIndex`, `nextIndex`, and `attemptedSnapshot` on a staging follower. However, the specific failing MC transition does not match current implementation reachability.

`LeaderStateImpl.restart()` removes the sender, then recreates one only if `getPeer(info.getId())` finds that peer in the current Raft configuration. A staging-only peer is introduced before old-new config application, so it is not returned by `server.getRaftConf().getPeer(...)`. In the reproduction, restart removed the staging appenders but did not create a fresh `FollowerInfoImpl`, so the modeled reset branch is over-permitted.

I wrote:
`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/confirmation/MC-2/investigation.md`

For `PENDING REPAIR`, I also wrote:
`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/confirmation/MC-2/repair-request.body.md`

## Trigger scenario

The MC trace reaches:

```text
State 5: MCAddStagingPeer(F2)
State 6: MCSnapshotAlreadyInstalled(F2,1)
  F2 attemptedSnapshot = TRUE
  F2 snapshotIndex = 1
  F2 matchIndex = 1
  F2 nextIndex = 2
State 8: MCRestartAppender(F2)
  F2 attemptedSnapshot = FALSE
  F2 snapshotIndex = 0
  F2 matchIndex = -1
  F2 nextIndex = 0
```

The real reproduction reaches staging snapshot progress, then restarts staging appenders through the existing test hook after public `setConfiguration`.

## Developer intent

`startSetConfiguration()` bootstraps new peers as staging appenders before they are applied into the current configuration. `restart()` is guarded by `getPeer(info.getId())`, so current code only recreates appenders for peers already present in `server.getRaftConf()`.

Prior-report search checked upstream GitHub issue/PR search and local git history. No exact report was found for this modeled mechanism. Adjacent known fixed issue: RATIS-2283 / PR #1250, about restarted gRPC appenders leaving `catchup=false`, not about recreating a staging peer `FollowerInfoImpl` and discarding snapshot/index progress:
https://issues.apache.org/jira/browse/RATIS-2283
https://github.com/apache/ratis/pull/1250

## Reproduction result

Executed:

```text
COMMAND: timeout 12m ./mvnw -pl ratis-test -am -DskipShade -DskipRat -Dcheckstyle.skip -Dspotbugs.skip -Dfindbugs.skip -Dtest=TestSpeculaMC2StagingRestartProgress -DfailIfNoTests=false -Dspecula.ratis.grpc.trace.dir=/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/repro/MC-2-traces -Dsurefire.useFile=false test
[INFO] Running org.apache.ratis.grpc.TestSpeculaMC2StagingRestartProgress
[INFO] Tests run: 2, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

Key real trace output:

```json
{"event":"SnapshotInstalled","node":"L","follower":"F2","snapshotIndex":31,"matchIndex":31,"nextIndex":32,"state":{"matchIndex":31,"nextIndex":32,"snapshotIndex":31,"attemptedSnapshot":true,"caughtUp":false}}
{"event":"SnapshotInstalled","node":"L","follower":"F1","snapshotIndex":31,"matchIndex":31,"nextIndex":32,"state":{"matchIndex":31,"nextIndex":32,"snapshotIndex":31,"attemptedSnapshot":true,"caughtUp":false}}
```

Surefire output confirms the restart was attempted, but the modeled replacement/reset did not occur:

```text
LeaderStateImpl.java:restart(722)) - s0@group-1CE20A15E010-LeaderStateImpl: Restarting GrpcLogAppender for s0@group-1CE20A15E010->s1
LeaderStateImpl.java:restart(722)) - s0@group-1CE20A15E010-LeaderStateImpl: Restarting GrpcLogAppender for s0@group-1CE20A15E010->s2
MC2_LEVEL1_ATTEMPT: snapshot progress observed before restart; appenders before restart=[s1, s2]
MC2_LEVEL1_ARTIFACT: restart stopped staging appenders but did not create replacement FollowerInfo; appenders after restart=[], RestartAppender events=0
```

## Recommendation

Repair the MC action: split or constrain `MCRestartAppender` so a staging-only peer cannot take the replacement/reinitialization branch unless it is present in the current Raft configuration, matching `LeaderStateImpl.getPeer`. A separate model branch can represent the current implementation’s staging restart behavior: stop/remove the appender without recreating `FollowerInfoImpl`.

## Repair round 1 evidence
<!-- specula-repair-token: f27c80c51f94deb865b92452ebbe2335 -->
- **Repair request**: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/spec/repair-requests/RR-001.md`
- **Phase 3 result**: completed with no errors. Current findings retain only MC-1 from RG3.

---

## Entry 3: Stream reconnect and late replies may lose pending-request context

- **Finding ID**: CR-1
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:540

## Description

The pending-request context can be absent when a late AppendEntries `SUCCESS` reply arrives: `timeoutAppendRequest` removes the call id, and the follower can later complete the same real request. However, the suspected harmful outcome was not confirmed. Late `SUCCESS` handling uses monotonic `matchIndex` / `nextIndex` updates, and the reproduced client workload continues to commit and accept a later write.

For `INCONSISTENCY`, the no-request path is guarded by `getNextIndexForInconsistency`, which floors rollback at `matchIndex + 1`; it can discard optimistic unproven progress, but not proven follower progress.

## Trigger scenario

Level 0: normal public `RaftClient` append over gRPC succeeds.

Level 1: a real 3-node `MiniRaftClusterWithGrpc` write is sent, follower state machines are temporarily blocked via the existing test hook, the leader's request timeout removes the pending call id, then the follower later sends a real `SUCCESS` reply for that call id. This reaches `ReceiveSuccessWithoutRequest` without source-logic patching.

## Developer intent

Upstream history has related safeguards, but no exact duplicate report for this mechanism. I checked current `origin/master` and searched upstream issues/closed PRs. Relevant non-duplicates include [RATIS-1909 / PR #939](https://github.com/apache/ratis/pull/939), which added the `matchIndex + 1` reset guard; [RATIS-2135](https://issues.apache.org/jira/browse/RATIS-2135), which involved repeated inconsistency replies with request context present; and [PR #1519](https://github.com/apache/ratis/pull/1519), which fixed heartbeat success progress pollution.

## Reproduction result

Reproduction test: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/repro/test_bugCR-1_late_pending_reply.sh`

Actual output:

```text
CR1_REPRO_COMMAND: timeout 10m ./mvnw -pl ratis-test -am -Dtest=TestBugCR1LatePendingReply#lateSuccessAfterTimeoutKeepsClusterUsable -DskipShade -DskipRat -DskipCheckstyle -DskipSpotbugs -DskipOWASP -DskipJavadoc -DskipSource -Dgpg.skip -Djacoco.skip test
CR1_REPRO_LEVEL0: warmup client append uses normal public RaftClient/gRPC path and succeeds before timing assistance.
CR1_REPRO_LEVEL1: follower state machines are blocked to let the real AppendEntries request time out; no Ratis source logic is patched.
CR1_MAVEN_RESULT: PASS
CR1_TRACE_FILE: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/confirmation/CR-1/worktree/ratis-test/target/specula-traces/cr1-late-success-after-timeout.ndjson
CR1_TRACE_EVIDENCE:
22:{"tag":"ratis-grpc","ts":1785789939952,"event":"SendAppendData","node":"L","follower":"F2","callId":11,"streamEpoch":0,"isHeartbeat":false,"prevIndex":2,"firstIndex":3,"lastIndex":3,"state":{"matchIndex":2,"nextIndex":4,"snapshotIndex":0,"attemptedSnapshot":false,"caughtUp":true,"streamEpoch":0,"streamActive":true,"pendingCount":1,"cancelled":false}}
23:{"tag":"ratis-grpc","ts":1785789939952,"event":"SendAppendData","node":"L","follower":"F1","callId":9,"streamEpoch":0,"isHeartbeat":false,"prevIndex":2,"firstIndex":3,"lastIndex":3,"state":{"matchIndex":2,"nextIndex":4,"snapshotIndex":0,"attemptedSnapshot":false,"caughtUp":true,"streamEpoch":0,"streamActive":true,"pendingCount":1,"cancelled":false}}
48:{"tag":"ratis-grpc","ts":1785789940253,"event":"TimeoutAppend","node":"L","follower":"F2","callId":11,"isHeartbeat":false,"state":{"matchIndex":2,"nextIndex":4,"snapshotIndex":0,"attemptedSnapshot":false,"caughtUp":true,"streamEpoch":0,"streamActive":true,"pendingCount":0,"cancelled":false}}
49:{"tag":"ratis-grpc","ts":1785789940254,"event":"TimeoutAppend","node":"L","follower":"F1","callId":9,"isHeartbeat":false,"state":{"matchIndex":2,"nextIndex":4,"snapshotIndex":0,"attemptedSnapshot":false,"caughtUp":true,"streamEpoch":0,"streamActive":true,"pendingCount":0,"cancelled":false}}
56:{"tag":"ratis-grpc","ts":1785789940354,"event":"FollowerAppendSuccess","node":"L","follower":"F1","callId":9,"streamEpoch":0,"isHeartbeat":false,"prevIndex":2,"firstIndex":3,"lastIndex":3,"result":"SUCCESS","matchIndex":3,"replyNextIndex":4}
57:{"tag":"ratis-grpc","ts":1785789940354,"event":"FollowerAppendSuccess","node":"L","follower":"F2","callId":11,"streamEpoch":0,"isHeartbeat":false,"prevIndex":2,"firstIndex":3,"lastIndex":3,"result":"SUCCESS","matchIndex":3,"replyNextIndex":4}
58:{"tag":"ratis-grpc","ts":1785789940355,"event":"ReceiveSuccessWithoutRequest","node":"L","follower":"F2","result":"SUCCESS","callId":11,"isHeartbeat":false,"matchIndex":3,"replyNextIndex":4,"streamEpoch":0,"prevIndex":2,"firstIndex":3,"lastIndex":3,"state":{"matchIndex":3,"nextIndex":4,"snapshotIndex":0,"attemptedSnapshot":false,"caughtUp":true,"streamEpoch":0,"streamActive":true,"pendingCount":0,"cancelled":false}}
59:{"tag":"ratis-grpc","ts":1785789940355,"event":"ReceiveSuccessWithoutRequest","node":"L","follower":"F1","result":"SUCCESS","callId":9,"isHeartbeat":false,"matchIndex":3,"replyNextIndex":4,"streamEpoch":0,"prevIndex":2,"firstIndex":3,"lastIndex":3,"state":{"matchIndex":3,"nextIndex":4,"snapshotIndex":0,"attemptedSnapshot":false,"caughtUp":true,"streamEpoch":0,"streamActive":true,"pendingCount":0,"cancelled":false}}
60:{"tag":"ratis-grpc","ts":1785789940356,"event":"AdvanceCommitIndex","node":"L","commitIndex":3}
CR1_SUREFIRE_SUMMARY:
[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 3.100 s -- in org.apache.ratis.grpc.TestBugCR1LatePendingReply
[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
[INFO] Finished at: 2026-08-03T20:45:41Z
CR1_ASSERTION: JUnit assertions passed: the timed-out client write succeeded, ReceiveSuccessWithoutRequest was observed, and a later client write succeeded.
```

## Recommendation

Do not file CR-1 as a data-corruption bug. A useful hardening follow-up would be a regression test for late replies without pending context, and optionally debug logging/stream-epoch checks for discarded or contextless replies.

---

## Entry 4: Cancellation, backpressure, and stream resource boundaries may duplicate or retain work

- **Finding ID**: CR-4
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/apache/ratis/pull/1540; fix-status: unfixed)
- **Location**: ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:842

## Description
CR-4 is a duplicate of existing upstream reports. PR #1540 / RATIS-2632 reports the same snapshot backpressure mechanism in `GrpcLogAppender.installSnapshot()` / `StreamObserverWithTimeout`: snapshot chunks can be sent without an explicit `isReady()` gate when the outstanding element limit is disabled. Related open PRs also cover the same CR-4 cancellation/resource-retention family: #1363 for `GrpcLogAppender` stream completion/cancel cleanup and #1368 for `GrpcServerProtocolService.ServerRequestStreamObserver` retention.

## Trigger scenario
A lagging follower requires snapshot installation; the leader streams snapshot chunks; the follower/network is slow; and the install-snapshot outstanding element limit is `0`, disabling the semaphore window. The appendEntries path waits for stream readiness, but the snapshot path has an already-reported gap.

## Developer intent
Upstream already filed fixes for this exact mechanism:
https://github.com/apache/ratis/pull/1540, https://github.com/apache/ratis/pull/1363, https://github.com/apache/ratis/pull/1368. Git history also shows adjacent earlier fixes for RATIS-1883, RATIS-1909, RATIS-558, and RATIS-2283, but the matching reports above are still open/unmerged.

## Reproduction result
Per the bug-confirmation skill, Code Review x already-reported is a Phase-1 drop. I still wrote and executed the requested CR-4 evidence script:

```text
CR-4 known-status prefilter evidence
repo_head=7eedc1deed07fc883bfe448b2d33438b7a0e994e
pr=1540 state=open merged=false title=RATIS-2632. Apply backpressure on install-snapshot chunk loop
url=https://github.com/apache/ratis/pull/1540
pr=1363 state=open merged=false title=RATIS-2421. Gracefully cancel stream after complete in GrpcLogAppender
url=https://github.com/apache/ratis/pull/1363
pr=1368 state=open merged=false title=RATIS-2426. Fix memory leak in ServerRequestStreamObserver
url=https://github.com/apache/ratis/pull/1368
DROPPED_PREFILTER_CONFIRMED: Code Review x known, fix-status=unfixed
```

Wrote:
`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/confirmation/CR-4/investigation.md`

## Recommendation
Do not report CR-4 as a new finding. Track the upstream PRs, especially #1540 for snapshot backpressure, and treat fix status as currently unfixed because the matching PR is open/unmerged.

---
