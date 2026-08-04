# CR-4 Investigation

## Finding

- Source: Code Review. No model-checking counterexample was supplied for CR-4.
- Candidate: joint membership, staged catch-up, listener promotion, and snapshot-carried configuration may disagree about when a peer has safely caught up.
- Primary location: `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:832`.

## Step 1: Code Audit

### Cited sites

- `RaftServerImpl.setConfigurationAsync` receives public `SetConfigurationRequest` traffic and rejects a new change while the current configuration is not stable, staging is active, or the current configuration entry is not committed: `RaftServerImpl.java:1397-1469`, especially `current.isStable()`, `leaderState.inStagingState()`, and `state.isConfCommitted()` at `1415-1419`.
- `LeaderStateImpl.startSetConfiguration` computes new followers/listeners not already in the current configuration, adds their log appenders, and holds them in `ConfigurationStagingState` until catch-up: `LeaderStateImpl.java:519-552`.
- `LeaderStateImpl.checkProgress` decides when a bootstrapping peer is caught up. The current checkout requires all of these before `CAUGHTUP`: close enough to the committed index, `matchIndex >= server.getRaftConf().getLogEntryIndex()`, recent RPC response, and a snapshot-install attempt flag: `LeaderStateImpl.java:832-844`.
- `LeaderStateImpl.checkStaging` applies the joint old/new configuration only after every not-yet-caught-up appender reports non-progressing absence; then it calls `applyOldNewConf` and `f.catchUp()` for peers now in the configuration: `LeaderStateImpl.java:867-893`.
- `LeaderStateImpl.updateCommit` computes quorum over the current and old configurations for joint consensus: `LeaderStateImpl.java:953-990`.
- `LeaderStateImpl.checkAndUpdateConfiguration` appends the final stable new configuration after the joint configuration commits, then replies to `setConfiguration`: `LeaderStateImpl.java:1041-1081`.
- `ServerState.updateConfiguration` applies configuration entries received through normal AppendEntries. If the server is a listener and the configuration now contains it as a follower, it calls `changeToFollowerAndPersistMetadata`: `ServerState.java:406-419`.
- `SnapshotInstallationHandler.installSnapshotImpl` applies the last configuration entry carried with a snapshot through `state.updateConfiguration(...)`, persists it, and notifies the state machine: `SnapshotInstallationHandler.java:149-159`.
- `RaftServerImpl.shouldSendShutdown` only asks removed candidates to shut down when the current stable configuration is committed, the candidate is not in the current configuration, the candidate log is older than the configuration index, and it is not still a bootstrapping peer: `RaftServerImpl.java:1483-1497`.

### Reachable call chain

The path is reachable through normal Ratis operations:

1. A client/admin issues `RaftClient.admin().setConfiguration(...)`.
2. The leader enters staging through `RaftServerImpl.setConfigurationAsync(...)` and `LeaderStateImpl.startSetConfiguration(...)`.
3. Log appenders replicate entries or install snapshots to new peers/listeners.
4. `LeaderStateImpl.checkStaging()` polls `checkProgress(...)`.
5. Once staging succeeds, the leader appends the transitional old/new configuration and later the final new configuration.
6. Followers/listeners receive those configuration entries via AppendEntries or `lastRaftConfigurationLogEntryProto` in InstallSnapshot and update local role/configuration.

### Trigger scenario recorded for Phase 2

A natural candidate trigger is:

1. Start a stable cluster.
2. Add a new peer or promote a listener while the leader has no usable snapshot, so catch-up must happen by log replication.
3. Keep the new peer close enough to the leader commit index but behind the latest configuration entry.
4. Observe whether the leader declares it caught up, appends/commits the joint and final configurations, or allows election behavior before the new peer has stored the relevant configuration entry or equivalent snapshot.

The current code has explicit safeguards on that sequence: `matchIndex >= server.getRaftConf().getLogEntryIndex()` in `checkProgress`, listener promotion on actual configuration application in `ServerState.updateConfiguration`, and snapshot-carried configuration application through the same `updateConfiguration` path.

## Step 2: Developer-Knowledge Search

### Upstream issue/PR search

Commands run from the Ratis worktree:

- `git fetch origin --prune`
- `git log --all --oneline --grep=setConfiguration --grep=listener --grep=snapshot --grep=reconfiguration --grep=catchup --grep=catch-up --grep=configuration --since='2024-01-01'`
- `git log --all --oneline --grep='RATIS-2274'`
- `gh pr view 1246 --repo apache/ratis --json number,title,state,mergedAt,url,body,files,commits`
- `gh pr view 1331 --repo apache/ratis --json number,title,state,mergedAt,url,body,files,commits`
- `gh search prs "RATIS-2274" --repo apache/ratis --json number,title,state,url,closedAt,body --limit 20`
- `gh search prs "fix listener role transition" --repo apache/ratis --json number,title,state,url,closedAt,body --limit 20`

`gh search issues` for `RATIS-2274`, `stagingCatchupGap configuration follower caught up`, and `listener role transition` returned no GitHub issue hits, which is expected because Apache Ratis tracks RATIS issues in Jira while GitHub PRs carry the RATIS keys.

### Upstream evidence

- PR #1246: `https://github.com/apache/ratis/pull/1246`, title `RATIS-2274. Newly added peer may retain outdated configuration after membership change, causing election failure.`, state `MERGED`, merged at `2025-04-05T17:03:40Z`. Its body says the leader with no snapshot may force log-based catch-up, the new peer may lack timely configuration change logs due to `stagingCatchupGap`, leaving the new peer with outdated configurations and violating membership-change safety. The stated fix is to make `CAUGHTUP` complete only after the follower receives the latest configuration logs from the leader.
- Commit `c1301b082c3f9359dc510e6f5c26ff0d7a8a7e21` implements PR #1246 by adding `follower.getMatchIndex() >= server.getRaftConf().getLogEntryIndex()` to `LeaderStateImpl.checkProgress`.
- PR #1331: `https://github.com/apache/ratis/pull/1331`, title `RATIS-2378. fix listener role transition`, state `MERGED`, merged at `2026-01-03T21:02:02Z`. It updates listener role transition and snapshot configuration application sites: `RaftServerImpl.java`, `ServerState.java`, `SnapshotInstallationHandler.java`, and `LeaderElectionTests.java`.
- Commit `d7370f897f43aa31d44beb3bf61933430bfb8355` implements PR #1331 by changing listener-to-follower transition guards, invoking `changeToFollowerAndPersistMetadata(...)` when a listener applies a configuration entry that contains it as a follower, and routing snapshot-carried configuration through `state.updateConfiguration(...)`.

### Comments, blame, and tests

- `LeaderStateImpl.checkProgress` includes a local comment describing caught-up criteria, then current code enforces the latest-configuration-index guard before returning `CAUGHTUP`.
- `ServerState.updateConfiguration` now makes listener promotion a side effect of applying a real configuration entry, not merely a role change from unrelated traffic.
- PR #1331 added/updated `LeaderElectionTests` assertions that listeners are no longer present after the role transition.

## Step 3: Known-Status / Precedent

This is code-review sourced and duplicates already-reported upstream defects:

- The staged catch-up/new quorum portion is the same mechanism and site as RATIS-2274 / PR #1246: newly added peer, log-based catch-up, `stagingCatchupGap`, missing latest configuration logs, and `LeaderStateImpl.checkProgress`.
- The listener-promotion/snapshot-carried-configuration portion is covered by RATIS-2378 / PR #1331 at the same listener-transition and snapshot-update sites listed in CR-4.

Known status: `KNOWN (cite: https://github.com/apache/ratis/pull/1246 and https://github.com/apache/ratis/pull/1331; fix-status: fixed)`.

Per the bug-confirmation decision table, because CR-4 is code-review sourced and already reported/fixed upstream at the same mechanism and sites, it is a Phase-1 pre-filter drop.
