# MC-2 Investigation

## Finding

MC-2 reports that `LeaderStateImpl.restart(LogAppender)` discards useful staging
catch-up progress by removing a staging appender and recreating a fresh
`FollowerInfoImpl` through `addAndStartSenders`, resetting `matchIndex`,
`snapshotIndex`, `nextIndex`, and `attemptedSnapshot`.

## Counterexample

The TLC counterexample in
`spec/output/final-MC_hunt_rg4_staging_restart-20260803-192310.out` violates
`RestartPreservesUsefulProgress`. The important steps are:

- State 5: `MCAddStagingPeer(F2)`.
- State 6: `MCSnapshotAlreadyInstalled(F2,1)` sets F2
  `attemptedSnapshot = TRUE`, `snapshotIndex = 1`, `matchIndex = 1`, and
  `nextIndex = 2`.
- State 7: `MCSnapshotAttemptForStagingPeer(F2)` preserves that progress.
- State 8: `MCRestartAppender(F2)` resets F2 to `attemptedSnapshot = FALSE`,
  `snapshotIndex = 0`, `matchIndex = -1`, and `nextIndex = 0`.

## Code Investigation

`startSetConfiguration` creates appenders for staging peers before assigning
`stagingState`; those staging peers are new members not yet in
`server.getRaftConf()` (`LeaderStateImpl.java:519-553`).

`restart(LogAppender)` removes the sender, then re-adds a sender only when
`getPeer(info.getId())` returns a peer from the current Raft configuration:

```java
stopAndRemoveSenders(Collections.singleton(sender));

Optional.ofNullable(getPeer(info.getId()))
    .ifPresent(peer -> addAndStartSenders(Collections.singleton(peer)));
```

The guard uses:

```java
return server.getRaftConf().getPeer(id, RaftPeerRole.FOLLOWER, RaftPeerRole.LISTENER);
```

For a peer that is only in the staging configuration, `getPeer` returns `null`.
Therefore the real code can remove the staging appender on restart, but cannot
take the model's replacement step that creates a fresh `FollowerInfoImpl` and
resets progress.

If a peer is re-added by `addAndStartSenders`, the constructor path does reset
state (`LeaderStateImpl.java:666-688`, `FollowerInfoImpl.java:41-60`), while
snapshot progress normally writes `snapshotIndex`, `matchIndex`, and `nextIndex`
through `FollowerInfoImpl.setSnapshotIndex` (`FollowerInfoImpl.java:147-150`) and
records `attemptedSnapshot` through `setAttemptedToInstallSnapshot`
(`FollowerInfoImpl.java:154-156`). That confirms the state semantics, but not the
counterexample's reachability for a staging-only peer.

## Reproduction

Wrote and executed:

`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/repro/test_bugMC-2_staging_restart_progress.sh`

Output:

`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/repro/test_bugMC-2_staging_restart_progress.output.txt`

The script temporarily installs a JUnit test under `ratis-test`, runs it with
`./mvnw`, and removes the temporary test source on exit.

The Level 0 case uses public admin `setConfiguration` and reaches staging
snapshot progress and normal application. The Level 1 case uses the same public
operation plus the existing test hook `RaftServerTestUtil.restartLogAppenders`
after snapshot progress is observed. The restart occurs, but the expected
replacement/reset event does not occur:

- Maven result: `Tests run: 2, Failures: 0, Errors: 0, Skipped: 0` and
  `BUILD SUCCESS`.
- Trace lines show staging snapshot progress:
  `SnapshotInstalled` for F2/F1 with `snapshotIndex = 31`, `matchIndex = 31`,
  `nextIndex = 32`, `attemptedSnapshot = true`.
- Surefire output shows `LeaderStateImpl.restart` was called for staging
  appenders `s1` and `s2`.
- Surefire output then reports:
  `restart stopped staging appenders but did not create replacement FollowerInfo;
  appenders after restart=[], RestartAppender events=0`.

## Prior Reports

Checked local git history for Ratis restart/catch-up/staging fixes and found
RATIS-2283 / PR #1250:

- https://issues.apache.org/jira/browse/RATIS-2283
- https://github.com/apache/ratis/pull/1250

That prior fixed report is adjacent: restarted gRPC appender threads left
`caughtUp=false` and blocked reconfiguration progress. It does not report the
exact MC-2 mechanism where `LeaderStateImpl.restart` recreates a staging peer's
`FollowerInfoImpl` and discards proven snapshot/index progress. No exact prior
report was found for this mechanism.

## Verdict

PENDING_REPAIR. The counterexample maps to real state fields and real snapshot
catch-up progress, but the specific `MCRestartAppender` transition over-permits
the implementation for a staging-only peer: current code removes the appender and
does not recreate a replacement `FollowerInfoImpl` because `getPeer` reads only
the current configuration.
