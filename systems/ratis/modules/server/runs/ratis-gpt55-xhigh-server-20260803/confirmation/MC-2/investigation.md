# MC-2 Investigation

## Scope

- Finding: MC-2, old leader lease read racing with NOT_LEADER reply handling.
- Source tree: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/confirmation/MC-2/worktree`
- HEAD: `7eedc1deed07fc883bfe448b2d33438b7a0e994e`
- Reproduction script: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/repro/test_bugMC-2_old_leader_lease_read.sh`

## Code Evidence

- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java:103-106` calls `appendEntries`, records `lastRpcResponseTime`, then records `lastRespondedAppendEntriesSendTime(sendTime)` before reply handling.
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java:221-223` handles `NOT_LEADER` later by calling `onFollowerTerm(reply.getTerm())`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:1214-1221` serves linearizable reads through the leader-lease fast path when `hasLease()` succeeds.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:1249-1264` extends the lease from recent follower append response send times.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1109-1112` rejects follower-side ReadIndex when the local server does not know a leader.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1125-1145` routes linearizable reads through leader-state ReadIndex when still leader, otherwise through follower ReadIndex.

## Prior-Report Search

- Git history search for `leader lease`, `ReadIndex`, `NOT_LEADER`, `old leader`, `RATIS-1864`, `RATIS-2044`, `RATIS-2154`, and `RATIS-2382` found related ReadIndex/lease work, including `RATIS-1864`, `RATIS-2044`, `RATIS-2154`, and `RATIS-2382`, but no exact old-leader lease-read race caused by `LogAppenderDefault` recording a NOT_LEADER response timestamp before demotion.
- GitHub issue/PR search `repo:apache/ratis "NOT_LEADER" "ReadIndex"` returned `total_count: 0`.
- GitHub issue/PR searches for `"leader lease" "ReadIndex"` and `"AppendEntries" "leader lease"` found related PRs such as #1334, #1296, #730, and stale/unmerged #383, but not this specific mechanism.
- Novelty disposition: `NEW`.

## Reproduction

The repro script writes a temporary JUnit test under `ratis-server/src/test/java/org/apache/ratis/TestBugMC2OldLeaderLeaseRead.java`, executes it, and removes it on exit. It also temporarily patches `LogAppenderDefault` only for Level 3 to delay after `updateLastRespondedAppendEntriesSendTime(sendTime)` when the reply result is `NOT_LEADER`; the source file is restored on exit.

Executed command:

```text
/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/repro/test_bugMC-2_old_leader_lease_read.sh
```

Final output file:

```text
/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/repro/test_bugMC-2_old_leader_lease_read.out
```

Observed:

```text
MC2_REPRO_START 2026-08-04T11:34:26Z
HEAD=7eedc1deed07fc883bfe448b2d33438b7a0e994e
LEVEL0_COMMAND_STATUS=0
LEVEL1_COMMAND_STATUS=0
LEVEL3_PATCH=delay_after_updateLastRespondedAppendEntriesSendTime_for_NOT_LEADER
LEVEL3_COMMAND_STATUS=0
MC2_REPRO_END 2026-08-04T11:37:26Z
```

Surefire captured Level 3 results:

```text
MC2_RESULT level=LEVEL3 attempt=1 staleReadObserved=false replacementLeaderObserved=true oldLeaseExpiredBeforeReplacement=true oldLeaderFinalRole=FOLLOWER newLeaderId=s0 notLeaderTimestampObserved=false readAttempts=216 staleValue=-1 detail="first=FAILED_REPLY exception=org.apache.ratis.protocol.exceptions.ReadIndexException: s1@group-8B38FF8D44AE: Leader is unknown.; last=FAILED_REPLY exception=org.apache.ratis.protocol.exceptions.ReadIndexException: s1@group-8B38FF8D44AE: Leader is unknown."
MC2_RESULT level=LEVEL3 attempt=6 staleReadObserved=false replacementLeaderObserved=true oldLeaseExpiredBeforeReplacement=true oldLeaderFinalRole=FOLLOWER newLeaderId=s2 notLeaderTimestampObserved=false readAttempts=218 staleValue=-1 detail="first=FAILED_REPLY exception=org.apache.ratis.protocol.exceptions.ReadIndexException: s1@group-FD3ADB2F0A87: Leader is unknown.; last=FAILED_REPLY exception=org.apache.ratis.protocol.exceptions.ReadIndexException: s1@group-FD3ADB2F0A87: Leader is unknown."
MC2_FINAL level=LEVEL3 last="MC2_RESULT level=LEVEL3 attempt=6 staleReadObserved=false replacementLeaderObserved=true oldLeaseExpiredBeforeReplacement=true oldLeaderFinalRole=FOLLOWER newLeaderId=s2 notLeaderTimestampObserved=false readAttempts=218 staleValue=-1 detail="first=FAILED_REPLY exception=org.apache.ratis.protocol.exceptions.ReadIndexException: s1@group-FD3ADB2F0A87: Leader is unknown.; last=FAILED_REPLY exception=org.apache.ratis.protocol.exceptions.ReadIndexException: s1@group-FD3ADB2F0A87: Leader is unknown.""
```

## Verdict Rationale

- Level 0 and Level 1 did not produce an old-value read.
- The targeted Level 3 source-delay marker did not fire (`notLeaderTimestampObserved=false`), so the exact timestamp-after-NOT_LEADER window was not observed in the harness.
- In every Level 3 attempt, a replacement leader was observed, the old leader lease had expired before replacement, and the old server ended as `FOLLOWER`.
- The real read consumer did not observe stale state. It received `ReadIndexException: Leader is unknown` through the follower read path, matching `RaftServerImpl.sendReadIndexAsync`.
- This is therefore not a code-level reproduction. The tested real-server path is masked by role demotion plus the follower ReadIndex unknown-leader guard.
