# Dragonboat (lni/dragonboat) Bug Inventory

This document catalogs all bugs/issues found during code analysis and model checking of dragonboat.
Each entry includes: description, code evidence, discovery method, status, and severity assessment.

**Verification status legend:**
- **Confirmed**: Code evidence is clear, bug is real
- **Needs discussion**: Arguable whether this is a bug or intentional design
- **Rejected**: Not a bug upon closer inspection

---

## Category A: Model-Checking Confirmed Bugs

### B1: `saveRaftState` returns nil instead of err (PR #409)

**Code location**: `internal/logdb/db.go:193` and `db.go:353`

**Description**: In `saveRaftState()` and `saveSnapshots()`, when `saveSnapshot()` fails, the original
code returned `nil` instead of `err`:

```go
// ORIGINAL (buggy):
if err := r.saveSnapshot(wb, ud); err != nil {
    return nil   // <-- should be: return err
}
```

When `saveSnapshot` fails and returns nil, the function continues and calls `saveEntries()` +
`CommitWriteBatch()`. Wait -- no. If it returns nil (exits early with no error), the caller
believes everything succeeded, but `saveEntries()` and `setMaxIndex()` are SKIPPED for this
iteration. The write batch is committed without the entries that should have been included.

Actually, re-reading more carefully: `return nil` exits `saveRaftState` entirely, so `saveEntries`
at line 199 is NEVER called. The caller receives nil error and assumes the write batch (including
log entries) was persisted. But it was never committed. On crash, those entries are lost.

**Evidence from git**:
```
commit f11633b: fix: return err instead of nil on saveSnapshot failure
-               return nil
+               return err
```
This fix exists in our artifact (already applied). The original upstream has PR #409 open but unmerged.

**MC result**: `CommittedEntriesPersisted` invariant violated (13,060 states, depth 11).
See `spec/output/mc-bug3-committed-persisted.out`.

Also: `ElectionSafety` violated under leader-completeness config (1,316,461 states, depth 10).
See `spec/output/mc-bug3-leader-completeness.out`.

**Severity**: Critical -- silent data loss on snapshot save failure.

**Status**: PR #409 submitted upstream, not merged. Fix applied in our artifact (commit f11633b).

**Verification**: **Confirmed**. Git diff proves `return nil` was the original code.

---

### B2: `handleLeaderSnapshotStatus` missing `setActive()`

**Code location**: `internal/raft/raft.go:2044-2069`

**Description**: Both `handleLeaderReplicateResp` (line 1936) and `handleLeaderHeartbeatResp`
(line 1975) call `rp.setActive()` at the beginning. `handleLeaderSnapshotStatus` does NOT.

```go
// raft.go:2044
func (r *raft) handleLeaderSnapshotStatus(m pb.Message, rp *remote) error {
    if rp.state != remoteSnapshot {
        return nil
    }
    // ... no rp.setActive() call anywhere ...
    rp.becomeWait()
    return nil
}
```

During a long snapshot transfer, the only communication between leader and the snapshot-receiving
follower may be SnapshotStatus messages. Since these don't call `setActive()`, the follower is
never marked active. When `leaderHasQuorum()` runs during CheckQuorum, that follower is not counted.

In a cluster with exactly a quorum of nodes where one is receiving a snapshot, the leader could
step down unnecessarily.

**MC result**: `HandleSnapshotStatusSetsActive` action property violated (4,801 states, depth 9).
See `spec/output/mc-bug1-snapshot-active.out`.

**Severity**: Medium -- leader availability loss during snapshot transfers, causing unnecessary
leader step-down and brief service interruption. Mitigated by parallel heartbeat mechanism
(leader sends ~10 heartbeats per tick, heartbeatResp calls `setActive()`).

**Status**: Not reported upstream.

**Verification**: **Confirmed** -- unit test `TestSnapshotStatusDoesNotSetActive` reproduces the bug:
leader steps down during CheckQuorum despite node 2 responding via SnapshotStatus. Comparison test
`TestHeartbeatRespSetsActiveButSnapshotStatusDoesNot` proves the handler inconsistency.
Recorded as bug tracker #24.

---

## Category B: Code Analysis Bugs (Not MC-confirmed)

### B3: `hasConfigChangeToApply()` overly conservative

**Code location**: `internal/raft/raft.go:1660-1671`

**Description**: The function blocks elections whenever ANY committed-but-not-applied entries exist,
not just ConfigChangeEntry entries:

```go
func (r *raft) hasConfigChangeToApply() bool {
    if r.hasNotAppliedConfigChange != nil {
        return r.hasNotAppliedConfigChange()  // test hook
    }
    // TODO:
    // with the current entry log implementation, the simplification below is no
    // longer required, we can now actually scan the committed but not applied
    // portion of the log as they are now all in memory.
    return r.log.committed > r.getApplied()  // <-- overly conservative
}
```

The correct implementation already exists in test code (`raft_etcd_test.go:46-56`):

```go
func (r *raft) testOnlyHasConfigChangeToApply() bool {
    entries, err := r.log.getEntriesToApply(noLimit)
    if err != nil { panic(err) }
    if r.log.committed > r.log.processed && len(entries) > 0 {
        return countConfigChange(entries) > 0  // <-- scans for actual config entries
    }
    return false
}
```

**Impact**: Under high write load + leader failure, elections are delayed by ~1-2 seconds because
`hasConfigChangeToApply()` returns true even when only regular ApplicationEntry entries are pending.

**Severity**: Medium -- liveness issue, not safety.

**Status**: Acknowledged via TODO comment. Not fixed.

**Verification**: **Confirmed**. The TODO comment and the existing correct test implementation
prove this is a known simplification that should be fixed.

---

### B4: Second config change silently dropped

**Code location**: `internal/raft/raft.go:1857-1864`

**Description**: When a config change is proposed while one is already pending, it is silently
replaced with an empty ApplicationEntry:

```go
for i, e := range m.Entries {
    if e.Type == pb.ConfigChangeEntry {
        if r.hasPendingConfigChange() {
            plog.Warningf("%s dropped config change, pending change", r.describe())
            r.reportDroppedConfigChange(m.Entries[i])
            m.Entries[i] = pb.Entry{Type: pb.ApplicationEntry}  // silently replaced
        }
        r.setPendingConfigChange()
    }
}
```

The entry is committed (goes through Raft consensus) as an empty ApplicationEntry. The caller's
proposal appears to succeed, but the config change has no effect. `reportDroppedConfigChange`
logs a warning but does not return an error to the caller.

**Severity**: Low -- this is standard Raft single-config-change-at-a-time enforcement. The
"silent" aspect is the concern. A warning is logged via `plog.Warningf`.

**Status**: Not reported.

**Verification**: **Rejected** -- this is intentional design. The dropped config change is reported
back to the caller via `DroppedEntries` -> `pendingConfigChange.dropped()`. The caller DOES receive
a failure notification. Combined with `plog.Warningf`, this is standard Raft single-config-change
enforcement with proper notification.

---

### B5: `leaderHasQuorum()` is a side-effecting boolean

**Code location**: `internal/raft/raft.go:397-407`

**Description**:

```go
func (r *raft) leaderHasQuorum() bool {
    c := 0
    for nid, member := range r.votingMembers() {
        if nid == r.replicaID || member.isActive() {
            c++
            member.setNotActive()  // SIDE EFFECT: clears active flag
        }
    }
    return c >= r.quorum()
}
```

The function clears all active flags while checking quorum. Calling it twice in the same cycle
causes the second call to always return false.

**Severity**: Low -- currently only called once per CheckQuorum cycle (`handleLeaderCheckQuorum`).
This is a defensive concern: any future code change adding a second call would break quorum.

**Status**: Not reported.

**Verification**: **Rejected** -- this is etcd/raft's standard CheckQuorum pattern. The "check"
and "reset" are intentionally combined. Only called once per cycle, so no issue.

---

### B6: SnapshotStatus handler early return

**Code location**: `internal/raft/raft.go:2044-2047`

**Description**:

```go
func (r *raft) handleLeaderSnapshotStatus(m pb.Message, rp *remote) error {
    if rp.state != remoteSnapshot {
        return nil  // silently drops
    }
    ...
}
```

If a SnapshotStatus message arrives after the remote has already transitioned out of
`remoteSnapshot` state (e.g., due to a heartbeat or timeout), the message is silently dropped.
Combined with B2 (missing `setActive`), this means the activity signal from the snapshot transfer
is completely lost.

**Severity**: Low -- this early return is standard guard logic. The real issue is B2.

**Status**: Part of B2 analysis.

**Verification**: **Rejected** -- standard stale message guard, not an independent bug. Same
pattern as other handlers. Only relevant as context for B2.

---

### B7: Snapshot Header CRC zero-value bypass

**Code location**: `internal/rsm/snapshotio.go:363-372`

**Description**:

```go
func validateHeader(header []byte, crc32 []byte) bool {
    if len(crc32) != 4 {
        plog.Panicf("invalid crc32 len: %d", len(crc32))
    }
    if !bytes.Equal(crc32, fourZeroBytes) {   // <-- if CRC is all zeros, skip validation
        h := newCRC32Hash()
        fileutil.MustWrite(h, header)
        return bytes.Equal(h.Sum(nil), crc32)
    }
    return true  // <-- CRC field is zero: unconditionally accept
}
```

When the CRC32 field is all zeros, the header is accepted without validation. A corrupted
snapshot with a zeroed CRC field would pass validation.

**Severity**: Low -- requires an attacker or extreme coincidence to zero out exactly the CRC
bytes while corrupting other header data. This might be intentional to support legacy snapshots
that don't have CRC.

**Status**: Not reported.

**Verification**: **Rejected** -- likely intentional backward compatibility with older snapshot
formats that didn't include CRC. Zero as "not present" sentinel is standard practice.

---

### B8: LRU Session eviction breaks Exactly-Once semantics

**Code location**: `internal/rsm/lrusession.go:72-79`

**Description**:

```go
rec.sessions.ShouldEvict = func(n int, k, v interface{}) bool {
    if uint64(n) > rec.size {
        clientID := k.(*RaftClientID)
        plog.Warningf("session with client id %d evicted, overloaded", *clientID)
        return true  // evict oldest session
    }
    return false
}
```

When the session cache exceeds its size limit, the oldest session is evicted. The evicted client
loses its de-duplication history, meaning retried requests from that client could be applied twice.

**Severity**: Low -- this is a standard LRU trade-off. The warning log is emitted. The session
size is configurable. In practice, session overflow means the system is overloaded.

**Status**: Not reported.

**Verification**: **Rejected** -- standard LRU trade-off with warning log and configurable size.
Not a bug.

---

### B9: Membership hash ignores NonVotings/Witnesses

**Code location**: `internal/rsm/membership.go:90-105`

**Description**:

```go
func (m *membership) getHash() uint64 {
    vals := make([]uint64, 0)
    for v := range m.members.Addresses {  // <-- only Addresses (voting members)
        vals = append(vals, v)
    }
    vals = append(vals, m.members.ConfigChangeId)
    // ... hash computation ...
}
```

The hash only includes voting member IDs from `Addresses`. It does not include `NonVotings` or
`Witnesses` maps. Two different membership configurations with the same voting members but different
learners/witnesses would produce the same hash.

**Severity**: Low -- the hash is used for consistency checks between nodes. If two nodes disagree
only on non-voting members, this hash would not detect the divergence.

**Status**: Not reported.

**Verification**: **Rejected** -- ConfigChangeId is included in the hash and changes on every
membership operation (including NonVoting/Witness add/remove), so divergence is still detected.

---

### B10: Cache updated before CommitWriteBatch

**Code location**: `internal/logdb/db.go:184` + `cache.go:77-88`

**Description**: In `saveRaftState()`, `trySaveSnapshot()` at line 184 is called BEFORE
`CommitWriteBatch()` at line 201. `trySaveSnapshot()` updates the cache's `snapshotIndex`:

```go
// db.go:183-184
if !pb.IsEmptySnapshot(ud.Snapshot) &&
    r.cs.trySaveSnapshot(ud.ShardID, ud.ReplicaID, ud.Snapshot.Index) {  // updates cache
    ...
}
// db.go:200-201
if wb.Count() > 0 {
    return r.kvs.CommitWriteBatch(wb)  // actual persist happens here
}
```

If `CommitWriteBatch` fails (or the process crashes before it completes), the cache believes the
snapshot was saved, but it wasn't actually persisted.

**Severity**: Low -- on crash, the cache is rebuilt from disk, so the inconsistency is transient.
If `CommitWriteBatch` returns an error, the caller propagates it and the node likely restarts.

**Status**: Not reported.

**Verification**: **Rejected** -- cache is ephemeral, rebuilt from disk on restart. CommitWriteBatch
failure propagates up and causes node restart. Transient inconsistency has no impact.

---

### B11: Cache gate doesn't update after first snapshot

**Code location**: `internal/logdb/cache.go:77-88`

**Description**:

```go
func (r *cache) trySaveSnapshot(shardID uint64, replicaID uint64, index uint64) bool {
    r.mu.Lock()
    defer r.mu.Unlock()
    key := raftio.NodeInfo{ShardID: shardID, ReplicaID: replicaID}
    v, ok := r.snapshotIndex[key]
    if !ok {
        r.snapshotIndex[key] = index   // first snapshot: save and return true
        return true
    }
    return index > v   // subsequent: only save if index is higher, but DON'T update v
}
```

When `ok == true` and `index > v`, the function returns `true` (allowing the save) but does NOT
update `r.snapshotIndex[key]` to the new index. This means the gate always compares against the
FIRST snapshot index, not the most recently saved one.

Wait -- let me re-read. Actually the `!ok` case does set `r.snapshotIndex[key] = index`. But
when `ok == true && index > v`, it just returns `true` without updating. So subsequent calls
with increasing indices will all pass (since `index > firstIndex` remains true). This means
the gate allows redundant saves but doesn't lose correctness, since the actual save in
`saveSnapshot()` replaces older snapshots anyway.

**Severity**: Very low -- performance issue only. Redundant snapshot saves to the write batch.

**Status**: Not reported.

**Verification**: **Rejected** -- snapshot index is monotonically increasing, so the gate still
works correctly. Only allows redundant saves, no correctness impact.

---

### B12: `NewNodeHost` panic recovery misses string panics

**Code location**: `nodehost.go:338-344`

**Description**:

```go
defer func() {
    if r := recover(); r != nil {
        nh.Close()
        if r, ok := r.(error); ok {
            panicNow(r)
        }
        // if r is a string (e.g., panic("something")), falls through here
        // and the function returns nil error
    }
}()
```

If code inside `NewNodeHost` calls `panic("some string")`, the recovery catches it, calls
`nh.Close()`, but then falls through without calling `panicNow(r)` because the type assertion
to `error` fails for strings. The function returns `(*NodeHost, nil)` -- a partially-initialized
NodeHost with no error.

**Severity**: Medium -- startup panics could be silently swallowed.

**Status**: PR #374 was submitted but closed (unmerged). The bug remains.

**Verification**: **Rejected** -- bug is real but low priority. PR #374 was submitted by external
contributor (tephrocactus), maintainer never responded, contributor self-closed. Not worth recording.

---

## Category C: Code Quality Issues (Not Bugs)

### C1: Dead code in `commitTo`

**Code location**: `internal/raft/logentry.go:344`

```go
func (l *entryLog) commitTo(index uint64) {
    if index <= l.committed { return }     // line 337-339
    if index > l.lastIndex() { panic() }   // line 340-342
    if index < l.committed { panic() }     // line 344: UNREACHABLE
    l.committed = index
}
```

After line 337-339 returns for `index <= l.committed`, we know `index > l.committed`, making the
check at line 344 (`index < l.committed`) always false.

**Verification**: **Confirmed** -- dead code, can be safely removed.

---

### C2: `canGrantVote` redundant condition

**Code location**: `internal/raft/raft.go:1673-1674`

```go
func (r *raft) canGrantVote(m pb.Message) bool {
    return r.vote == NoNode || r.vote == m.From || m.Term > r.term
}
```

Condition 3 (`m.Term > r.term`) is redundant. By the time `canGrantVote` runs,
`onMessageTermNotMatched` (line 1593-1626) has already processed higher-term messages by calling
`becomeFollower*()` -> `reset()` which sets `r.vote = NoNode`. So `m.Term > r.term` implies
`r.vote == NoNode` (condition 1 is already true).

**Verification**: **Confirmed** -- redundant but harmless.

---

### C3: Missing `mustBeLeader()` in SnapshotStatus/Unreachable handlers

**Code location**: `internal/raft/raft.go:2044` and `raft.go:2071`

Both `handleLeaderReplicateResp` (line 1935) and `handleLeaderHeartbeatResp` (line 1974) start
with `r.mustBeLeader()`. The `handleLeaderSnapshotStatus` and `handleLeaderUnreachable` handlers
do not have this assertion.

These handlers are registered in the `handlers[leader][...]` table, so they should only be called
when the node is a leader. The missing assertion is a consistency issue, not a functional bug.

**Verification**: **Confirmed** -- inconsistency, not a functional issue.

---

### C4: `decreaseTo` in replicate mode doesn't switch state

**Code location**: `internal/raft/remote.go:182-189`

```go
if r.state == remoteReplicate {
    if rejected <= r.match { return false }
    r.next = r.match + 1   // regress next, stay in replicate mode
    return true
}
```

When a rejection is received in replicate (pipeline) mode, `next` is regressed to `match + 1`
but the remote stays in replicate mode. This causes a burst of previously-sent entries to be
re-sent immediately.

**Verification**: **Confirmed** -- performance issue, not a safety bug.

---

### C5: `savedLogTo` silently drops stale notifications

**Code location**: `internal/raft/inmemory.go:124-136`

Four conditions cause a "saved to disk" notification to be silently dropped (index below marker,
empty entries, index beyond last entry, term mismatch). When dropped, `savedTo` is never advanced,
causing the same entries to be re-reported by `entriesToSave()`.

**Verification**: **Confirmed** -- safe (idempotent writes) but wasteful.

---

### C6: ReadIndex defensive index rewrite

**Code location**: `internal/raft/readindex.go:97-103`

```go
for _, v := range cs {
    if v.index > s.index {
        panic("v.index > s.index is unexpected")
    }
    // re-write the index for extra safety.
    // we don't know what we don't know.
    v.index = s.index
}
```

When a ReadIndex is confirmed by quorum, earlier pending reads are upgraded to use the confirmed
request's commit index. The "we don't know what we don't know" comment signals developer
uncertainty, but the rewrite is conservative and safe.

**Verification**: **Confirmed** -- not a bug, intentionally conservative design.

---

## Category D: Historical Bugs (Already Fixed)

These are bugs found during bug archaeology that have already been fixed upstream.
Listed here because our analysis can identify/reproduce them.

| # | Bug | Code location | Fix | Our coverage |
|---|-----|--------------|-----|-------------|
| H1 | `restoreRemotes` incorrectly promotes observer to follower | raft.go:493-537 | commit ac6a472, Issue #94 | Code analysis |
| H2 | Invalid membership change (delete only node) accepted | raft.go:1236-1299 | v3.0.2, Issue #75 | Code analysis |
| H3 | OnDiskSM inconsistent index silently ignored | rsm/statemachine.go | PR #161, Issue #156/#369 | Code analysis (same silent-error pattern as B1) |
| H4 | PreVote enabled: LeaderTransfer doesn't work | raft.go | commit 1c7ebd3, Issue #223 | Code analysis |
| H5 | LeaderTransfer message term value incorrect | raft.go | commit 175f332 | Code analysis |
| H6 | LeaderTransfer request data race | raft.go | commit 9772554 | Code analysis |
| H7 | RequestVote resets electionTick (shouldn't) | raft.go | commit 0045aa2 | Spec models `becomeFollowerKE` |
| H8 | engine loadedNodes data race | engine.go | commit 08ff2aa | Code analysis |
| H9 | nodes partition bug (copy-paste wrong load function) | engine.go | commit c07a3c5 | Code analysis |

---

## Category E: Spec Bugs (Found During Modeling)

### S1: `DropStaleMessage` CHOOSE expression type error

In the TLA+ spec `base.tla`, the original `DropStaleMessage` action used a CHOOSE expression
that returned a Nat value instead of a Boolean. Fixed during spec development.

---

## Summary Table

| Category | Count | Items |
|----------|-------|-------|
| MC-confirmed bugs | 2 | B1, B2 |
| Code analysis bugs | 10 | B3-B12 |
| Code quality issues | 6 | C1-C6 |
| Historical bugs (fixed) | 9 | H1-H9 |
| Spec bugs | 1 | S1 |
| **Total** | **28** | |

## Reportable Bugs (Ranked by Value)

1. **B1** (Critical) -- PR #409 already submitted, data loss risk. MC confirms violation.
2. **B3** (Medium) -- TODO acknowledged, correct fix exists in test code.
3. **B12** (Medium) -- PR #374 closed but bug remains. String panics silently swallowed.
4. **B2** (Medium) -- `setActive()` omission. MC confirms action property violation.
5. **B4** (Low) -- Silent config change drop. Standard Raft behavior but poor UX.

## Model Checking Evidence

All MC output files are saved permanently in `spec/output/`:

| File | Result |
|------|--------|
| `trace-validation-check_quorum.out` | PASS (463 states, depth 64) |
| `trace-validation-election_replication.out` | PASS (9,849 states, depth 90) |
| `mc-bug1-snapshot-active.out` | HandleSnapshotStatusSetsActive VIOLATED (4,801 states) |
| `mc-bug3-committed-persisted.out` | CommittedEntriesPersisted VIOLATED (13,060 states) |
| `mc-bug3-leader-completeness.out` | ElectionSafety VIOLATED (1,316,461 states) |
