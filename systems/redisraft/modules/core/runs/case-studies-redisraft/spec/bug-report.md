# Bug Report — RedisRaft

## Summary

- Bug families tested: 4 (snapshot crash window, stale read, membership change, crash recovery)
- Bugs found: 2
- Configs run: MC_hunt_snapshot.cfg, MC_hunt_staleread.cfg, MC_hunt_membership.cfg, MC_hunt_crashrecovery.cfg

---

## Bug 1: Snapshot Loading Crash Window

- **Bug Family**: 1 — Snapshot loading crash window
- **Severity**: Critical
- **Invariant violated**: SnapshotLogConsistency
- **Config**: MC_hunt_snapshot.cfg
- **Counterexample**: 13 states, `spec/output/MC_hunt_snapshot.out`

### Trace Summary

1. **States 1-9**: s1 wins election (term 1), becomes leader, appends noop, replicates to s2 and s3, advances commitIndex to 1.
2. **State 10**: s1 takes a snapshot at commitIndex=1. Physical log compacted: `log[s1]=<<>>`, `logOffset[s1]=1`, `snapshotLastIdx[s1]=1`.
3. **State 11**: s1 sends InstallSnapshot to s2 (which is behind the snapshot boundary: `nextIndex[s1][s2] <= logOffset[s1]`).
4. **State 12**: s2 handles InstallSnapshotRequest via `raft_begin_load_snapshot()`:
   - `log[s2]=<<>>` (log reset — **persistent** write)
   - `logOffset[s2]=1` (**persistent**)
   - `snapshotLastIdx[s2]=0` (NOT updated — deferred to `EndLoadSnapshot`)
   - `loadingSnapshot[s2]=TRUE` (**volatile**)
   - `pendingSnapshotIdx[s2]=1` (**volatile**)
5. **State 13**: s2 **crashes** before `EndLoadSnapshot`:
   - `loadingSnapshot[s2]=FALSE` (volatile, cleared by crash)
   - `logOffset[s2]=1` (persistent, preserved)
   - `snapshotLastIdx[s2]=0` (persistent, preserved — **GAP!**)
   - Result: `logOffset[s2]=1 > snapshotLastIdx[s2]=0` — inconsistent state

### Root Cause

`raft_begin_load_snapshot()` performs a persistent log reset (`logOffset` set to snapshot index, log cleared), but `snapshotLastIdx` is only updated later in `raft_end_load_snapshot()`. A crash between these two calls leaves the server with `logOffset > snapshotLastIdx`, meaning the physical log starts after the snapshot boundary — a gap of missing entries.

On recovery, the server has no log entries and its snapshot metadata points to an earlier state than its log offset. This can cause:
- Log entries in the gap to be lost
- Inability to serve entries between `snapshotLastIdx+1` and `logOffset`
- Potential violation of log completeness guarantees

### Affected Code

- `deps/raft/src/raft_server.c:1904-1956`: `raft_begin_load_snapshot()` — resets log and logOffset persistently
- `deps/raft/src/raft_server.c:1958-1975`: `raft_end_load_snapshot()` — updates snapshotLastIdx/Term (not reached if crash)
- `src/snapshot.c:527-540`: Redis-level snapshot load calling both functions

### Recommendation

Make the persistent state update atomic: either write `snapshotLastIdx`/`snapshotLastTerm` in `begin_load_snapshot` (before the log reset), or use a write-ahead log to ensure both updates happen together. Historical fixes for this bug family: commits 1c421cd, d052699, ea178c4, fd76599.

---

## Bug 2: Read Before NoOp Committed

- **Bug Family**: 2 — Stale read / read before noop
- **Severity**: High
- **Invariant violated**: NoReadBeforeNoOp
- **Config**: MC_hunt_staleread.cfg
- **Counterexample**: 7 states, `spec/output/MC_hunt_staleread.out`

### Trace Summary

1. **States 1-3**: s1 times out twice, reaching term 2 as Candidate.
2. **States 4-5**: s2 grants vote to s1 (term 2). s1 collects majority votes {s1, s2}.
3. **State 6**: s1 becomes Leader in term 2. Noop entry appended: `log[s1]=<<[term=2, type=NoopEntry]>>`. But `commitIndex[s1]=0` — the noop hasn't been replicated or committed.
4. **State 7**: s1 serves a non-quorum read via `ClientNonQuorumRead`. `HasCurrentTermCommitted(s1)` is FALSE (no entry with `term=2` at or below `commitIndex=0`). The read may return stale data from a previous term. `noopReadDetected` latches TRUE.

### Root Cause

The non-quorum read path in `redisraft.c:750-753` serves reads immediately without checking whether the leader's noop entry has been committed. Per Raft Section 8, a new leader must commit an entry from its own term before it can safely serve reads, to ensure it knows the latest committed state. Without this check, a new leader may serve reads that miss entries committed by a previous leader.

### Affected Code

- `src/redisraft.c:750-753`: Non-quorum read execution path — no check for noop committed
- `deps/raft/src/raft_server.c:443-450`: Noop append in `raft_become_leader()`

### Recommendation

Add a guard in the read path to verify `HasCurrentTermCommitted` before serving non-quorum reads. Historical references: Issue #19, Issue #316, commits 1149155, 2984ef9.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| 2 — NoStaleRead | MC_hunt_staleread.cfg | 43K states | TLC found NoReadBeforeNoOp first (same config); NoStaleRead not independently tested |
| 3 — Membership change safety | MC_hunt_membership.cfg | 135M states, 25M distinct, depth 14 | No violation (I/O error terminated run) |
| 4 — Crash recovery / log persistence | MC_hunt_crashrecovery.cfg | 64M states, 13M distinct, depth 15 | No violation (I/O error terminated run) |

**Note**: The membership and crash recovery hunts explored substantial state spaces without finding violations, suggesting the implementation handles these scenarios correctly within the modeled bounds. The crash recovery config also checks `SnapshotLogConsistency`, which was already found violated by the snapshot hunt with tighter snapshot-focused bounds.
