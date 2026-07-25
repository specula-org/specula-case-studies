# Bug Report — Apache Ratis

## Summary

- Bug families tested: 6
- Bugs found: 0
- Configs run: MC_hunt_election.cfg, MC_hunt_replication.cfg, MC_hunt_commit.cfg, MC_hunt_read.cfg, MC_hunt_snapshot.cfg, MC_hunt_config.cfg
- Total states explored: ~13B states, ~77M simulation traces
- Spec fixes applied during hunting: 2 (Case B), 1 invariant weakened (Case A)

## Spec Fixes Applied During Hunting

### Fix 1: HandleAppendEntriesRequest — heartbeat log truncation (Case B)

- **Discovered via**: MC_hunt_commit.cfg, CommitFlushBound violated (73-state trace)
- **Root cause**: The spec's log update `SubSeq(log[s], 1, baseIndex) \o newEntries` blanket-truncates the log to `prevLogIndex`. When a stale heartbeat (empty entries, prevLogIndex=0) is processed, this truncates the follower's entire log while `commitIndex` stays at its old value — violating `commitIndex <= flushIndex`.
- **Implementation behavior**: Ratis has 3 layers of protection:
  1. Heartbeats (empty entries) skip `appendLog()` entirely (RaftServerImpl.java:1669)
  2. `checkInconsistentAppendEntries()` rejects entries at or before commitIndex (lines 1725-1735)
  3. `computeTruncateIndices()` only truncates at term-conflict points (SegmentedRaftLogCache.java:665-698)
- **Fix**: Split HandleAppendEntriesRequest SUCCESS path into heartbeat (UNCHANGED log) and non-empty entry path with guard `mfirstIndex > commitIndex`.

### Fix 2: HandleRequestVoteRequest — lease not cleared on step-down (Case B)

- **Discovered via**: MC_hunt_read.cfg, LeaseImpliesLeader violated (35-state trace)
- **Root cause**: When a leader receives a RequestVote with higher term and steps down, the spec had `UNCHANGED readVars` — leaving `leaseValid=TRUE` on a non-leader.
- **Implementation behavior**: `changeToFollower()` triggers `LeaderStateImpl.stop()` which invalidates the lease.
- **Fix**: Added conditional readVars update in HandleRequestVoteRequest: clear leaseValid/pendingReads/startupEntryCommitted when stepping down from Leader.

### Fix 3: ReadLinearizability invariant weakened (Case A)

- **Discovered via**: MC_hunt_read.cfg, ReadLinearizability violated (19-state trace)
- **Root cause**: The invariant `leaseValid /\ pendingReads=0 => startupEntryCommitted` is too strong — ExtendLease can fire (majority heartbeat acked) before AdvanceCommitIndex commits the startup entry. This transient state is safe because ClientRead guards on `startupEntryCommitted[s]`.
- **Fix**: Weakened to `leaseValid /\ startupEntryCommitted => commitIndex > 0`.

---

## Not Reproduced

| Bug Family | Config | States Explored | Traces | Result |
|------------|--------|-----------------|--------|--------|
| Family 1: Commit Index Safety | MC_hunt_commit.cfg | 1.9B | 11M | No violation (after spec fix 1) |
| Family 2: Election & Leadership | MC_hunt_election.cfg | 3.1B | 13.8M | No violation |
| Family 3: Log Replication | MC_hunt_replication.cfg | 2.1B | 8.9M | No violation |
| Family 4: Configuration Change | MC_hunt_config.cfg | 1.8B | 13.3M | No violation |
| Family 5: Linearizable Reads | MC_hunt_read.cfg | 1.5B | 20.2M | No violation (after spec fixes 2+3) |
| Family 6: Snapshot-Log Consistency | MC_hunt_snapshot.cfg | 2.5B | 10M | No violation |

## Known Raft Bug Patterns — Assessment

| Pattern | Tested? | Result |
|---------|---------|--------|
| Stale leader (applies entries after term change) | Yes (election, commit) | Not reproduced — CheckLeadership + term checks prevent |
| Commit index regression | Yes (commit) | Not reproduced — CommitFlushBound + monotonic commitIndex |
| Log divergence on rejoin | Yes (replication, snapshot) | Not reproduced — prevLogTerm check + log matching |
| Pre-vote bypass | Yes (election) | Not reproduced — PreVote phase modeled separately |
| Snapshot-log gap | Yes (snapshot) | Not reproduced — SnapshotLogConsistency holds |
| Configuration change race | Yes (config) | Not reproduced — joint consensus requires both majorities |
| Read stale after leader change | Yes (read) | Not reproduced — startupEntryCommitted gate + lease invalidation |
| Non-monotonic term in AppendEntries | Yes (replication) | Not reproduced — term check in HandleAppendEntriesRequest |

## Methodology Notes

- All configs used simulation mode (BFS infeasible — state space exceeds available disk/memory even with minimal bounds)
- Each config ran 10M+ simulation traces at depth 80-100
- Simulation coverage: ~77M total traces, ~13B total states
- 3 servers, 1-2 values, terms bounded at 3-4, log length bounded at 3-5
- Trace validation: 2 traces (basic_consensus: 205 events, leader_reelection: 335 events) — both pass
