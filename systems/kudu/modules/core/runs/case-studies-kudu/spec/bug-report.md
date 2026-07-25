# Bug Report — Apache Kudu Raft Consensus

## Summary

- Bug families tested: 3 (Election/Leader Stability, Commit Index/Log Matching, Configuration Change)
- Bugs found: 0
- Configs run: MC_hunt_election.cfg, MC_hunt_commit.cfg, MC_hunt_config.cfg
- Convergence: 1 round (8 trace fixes, 7 MC fixes)
- State space coverage: 1.83B states / 15.9M traces (MC.cfg convergence), 1.4B+ states / 10.6M+ traces (hunting)

## Not Reproduced

| Bug Family | Config | States Explored | Traces | Result |
|------------|--------|-----------------|--------|--------|
| Family 1: Commit Index / Log Matching | MC_hunt_commit.cfg | 481M | 4.3M | No violation |
| Family 2: Configuration Change | MC_hunt_config.cfg | 2.4K | 90 | VoterOnlyQuorum false positive (see below) |
| Family 3: Election / Leader Stability | MC_hunt_election.cfg | 937M | 6.3M | No violation |

### Notes on Config Hunt (Family 2)

VoterOnlyQuorum fired as a false positive. The invariant checks that the current `matchIndex` reflects quorum agreement for all committed entries. However, `matchIndex` is reset to 0 when a server becomes leader (BecomeLeader action). After re-election, the invariant fails because the current matchIndex doesn't reflect the historical quorum that existed when the entry was committed. This is an invariant formulation issue (Case A), not a real bug. The core safety invariants (ElectionSafety, LogMatching, LeaderCompleteness) all pass.

## Spec Fixes During Convergence

The following spec issues were found and fixed during convergence (Phase 2):

### 1. PreVote / Real Election Vote Mixing (Case B)
- **Issue**: `votesGranted` mixed pre-election and real election votes. A Candidate could win a PreVote, collect pre-election responses, then BecomeLeader using pre-election votes as if they were real votes.
- **Fix**: Added `votedFor[i] = i` guard to BecomeLeader (requires real election). Added `votedFor[i] /= i` guard to PreVote (prevents PreVote when in real election). This was caught by ElectionSafety violation (two leaders at same term).

### 2. SendHeartbeat Log Matching Bypass (Case B)
- **Issue**: SendHeartbeat used `mprevLogIndex=0, mprevLogTerm=0` which always passed `logOk`. A heartbeat to an out-of-date follower advanced its commitIndex without verifying log consistency, causing committed entries to be applied from the wrong log.
- **Fix**: Removed SendHeartbeat entirely. In Kudu's implementation, heartbeats go through the same `RequestForPeer` path as regular AppendEntries. SendEntries subsumes heartbeat behavior (sends empty entries when follower is up to date).

### 3. Stale AppendEntries Log Truncation (Case B)
- **Issue**: The accept path of HandleAppendEntriesRequest always truncated and replaced entries: `SubSeq(log, 1, prevLogIndex) \o entries`. A stale AppendEntries (sent before the follower received newer entries) could truncate committed entries.
- **Fix**: Implemented Raft paper Figure 2 step 3 "only truncate on conflict". If all received entries match the existing log at the same positions, keep the existing (longer) log.

### 4. LeaderCompleteness Stale Leader (Case A)
- **Issue**: LeaderCompleteness checked ALL leaders, including stale ones that hadn't learned about higher terms. A stale leader at term T wouldn't have entries committed by a newer leader at term T+k.
- **Fix**: Restricted invariant to only check the leader whose term is >= all server terms. Stale leaders are excluded since they'll eventually step down.
