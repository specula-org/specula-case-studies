# CR-5 Investigation

## Finding

Source: Code Review.

Title: Reconfiguration catch-up and leader recognition may use inconsistent membership guards.

## Step 1: Code Audit

Relevant code:

- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1391-1458`: `setConfigurationAsync` is the public client path. It rejects a new reconfiguration unless the current conf is stable, no staging state exists, and the current conf entry is committed. It then computes the new peer set, adds peer RPC endpoints, and calls `LeaderStateImpl.startSetConfiguration`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:519-557`: `startSetConfiguration` creates a `ConfigurationStagingState`. If new peers/listeners must catch up, it starts new appenders and leaves the leader in staging. If no catch-up is needed, it immediately calls `applyOldNewConf`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:838-850`: `checkProgress` only marks a bootstrapping follower caught up when it has recent progress, attempted snapshot install, is within the catch-up gap, and its match index is at least the current conf log-entry index. This is the RATIS-2274 fix site.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:631-649`: `applyOldNewConf` appends the transitional `(old,new)` configuration and then installs it as in-memory current state on the leader.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftConfigurationImpl.java:264-282`: majority checks require both new-conf and old-conf majorities while transitional.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:956-993`: leader commit advancement also computes majority/min across both new and old follower sets when transitional.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:1045-1065`: once the final stable new configuration is committed, a leader not included in the new conf disables lease and closes itself after a min-RPC-timeout grace period.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1648-1711`: `appendEntriesAsync` recognizes the leader, steps down/persists metadata as needed, sets `leaderId`, checks append consistency, updates in-memory configuration from configuration entries, and only replies success through the append future.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java:329-343`: `recognizeLeader` checks term and same-term current-leader conflicts only; it does not directly call `containsInConf`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java:182-190` and `257-274`: snapshot install and snapshot notification use the same term/current-leader recognition guard before accepting a leader.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/VoteContext.java:54-60`: RequestVote first requires the candidate to be in the current/new configuration (`containsInConf`), not merely in the old conf.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/VoteContext.java:114-127`: candidate recognition applies the current-conf guard, term guard, and valid-current-leader guard before vote decision.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RoleInfo.java:190-193`: follower role info resolves the stored leader id via `getPeer`, and `RaftConfigurationImpl.getPeer` searches both new and old configs while transitional.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ConfigurationManager.java:96-103`: if later log truncation removes a configuration entry, current in-memory configuration rolls back to the previous configuration.

Reachability:

- Level-0 public API path is reachable through `RaftClient.admin().setConfiguration(...)` and is already used by `RaftReconfigurationBaseTest.testLeaderStepDown`, which removes the leader from the new configuration through normal client operations.
- Stale old-leader/revert path is reachable when the old leader is isolated while a configuration entry is appended but not committed. `RaftReconfigurationBaseTest.testRevertConfigurationChange` uses existing test hooks to widen that timing window, then unblocks the old leader and expects the client to observe `NotLeaderException` rather than a successful stale-leader result.
- A transitional configuration with a leader in old conf is reachable during leader removal. AppendEntries leader recognition being broader than RequestVote candidate recognition is consistent with allowing the current same-term old leader to finish joint consensus while preventing an old-only peer from starting a new term as candidate.

Safeguards encountered:

- Public reconfiguration rejects overlap until current conf is stable and committed.
- Bootstrapping cannot complete until the new peer has the current configuration log index.
- Transitional commit and leadership checks use joint old/new majority.
- Followers reply AppendEntries success only after append futures complete; leader commit uses flushed indexes.
- ConfigurationManager removes later configuration entries on truncation and restores the previous current conf.
- Final stable new-conf commit closes a removed leader.
- RequestVote prevents an old-only peer from being newly elected under the new/current conf.

Concrete trigger scenarios for reproduction:

1. Level 0: Start a five-peer simulated cluster, add two peers, remove two peers including the current leader, issue `setConfiguration` through the client API, and wait for the stable new conf.
2. Level 1: Start a five-peer simulated cluster, block the old leader's incoming/outgoing request handling while a configuration-change client request is in flight, let the old leader persist but not commit the configuration entry, unblock it, and check that the client receives `NotLeaderException` and the log/configuration converges.
3. Level 2: Use the existing test utility to install a reachable transitional single-to-HA configuration, then run leadership transfer/election behavior against that transitional state.

## Step 2: Developer Knowledge Search

Local git history and PR/Jira search:

- `git log --all --grep='recognizeLeader|membership|configuration|reconfig|RequestVote|InstallSnapshot|AppendEntries|RATIS-1995|RATIS-2234|RATIS-1305' --extended-regexp` found no commit message reporting this exact "AppendEntries/InstallSnapshot leader recognition versus RequestVote membership guard" mechanism.
- GitHub issues are disabled for `apache/ratis`; Ratis issue search is via ASF Jira. Web/Jira searches for `recognizeLeader membership reconfiguration AppendEntries InstallSnapshot RequestVote`, `VoteContext containsInConf`, `old leader AppendEntries reconfiguration`, and related terms did not find this exact mechanism as a filed issue.
- `gh pr list --repo apache/ratis --state all --search 'recognizeLeader membership reconfiguration AppendEntries InstallSnapshot RequestVote'` found no exact PR.
- `gh pr list --repo apache/ratis --state all --search '"newly added peer" configuration election failure'` found PR #1246 / RATIS-2274, merged 2025-04-05. That PR fixed `LeaderStateImpl.checkProgress` by requiring the bootstrapping follower's match index to cover the current conf log-entry index. It is adjacent but not the same site/mechanism as leader recognition guard divergence.
- `gh pr view 1148` / RATIS-2154, merged 2024-09-12, concerns old leader AppendEntries after term changed and changes term update ordering in `changeToFollower`; it is adjacent but not the same membership-guard mechanism.
- `gh pr view 1024` / RATIS-2008, merged 2024-01-24, concerns pre-vote rejection when candidate id equals the currently recognized leader; it is adjacent but not the same old/new configuration membership mechanism.

Developer intent evidence:

- `RaftConfigurationImpl` comments define transitional configuration as an expected peer-change state, and its majority methods explicitly require both new and old majority while transitional.
- `LeaderStateImpl.checkAndUpdateConfiguration` explicitly allows a leader that is not included in the final new configuration to continue until the stable new configuration entry is committed, then shuts it down.
- `RaftReconfigurationBaseTest.testLeaderStepDown` intentionally exercises removal of the current leader and expects the new configuration to take effect.
- `RaftReconfigurationBaseTest.testRevertConfigurationChange` intentionally exercises old leader persistence of an uncommitted configuration entry and expects NotLeader/commit recovery rather than treating the transient as live harm.

## Step 3: Known Status

No existing issue, PR, CVE, advisory, or prior dataset entry was found that reports this exact mechanism at the same sites. Adjacent known work exists (RATIS-2274, RATIS-2154, RATIS-2008), but it does not duplicate CR-5. Novelty for this mechanism: NEW.
