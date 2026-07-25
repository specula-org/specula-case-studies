# Analysis Report: MongoDB RaftMongo Replication Commit Point

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Core source files read in full | 6 (topology_coordinator.cpp, replication_coordinator_impl.cpp, heartbeat.cpp, elect_v1.cpp, step_up_step_down.cpp, rollback_impl.cpp) |
| Additional files partially read | 8 (bgsync.cpp, oplog_fetcher.cpp, member_data.h/cpp, repl_set_heartbeat_response.h, data_replicator_external_state_impl.cpp, topology_coordinator.h) |
| Bug-fix commits analyzed | 80+ across 8 keyword categories |
| SERVER tickets identified | 45+ |
| SERVER tickets deeply analyzed | 25+ (full commit diffs reviewed) |
| TODO/FIXME/HACK signals found | 15+ across core files |
| TLA+ spec files read in full | 6 (.tla and .cfg for RaftMongo and RaftMongoReplTimestamp) |

---

## Phase 1: Reconnaissance

### Codebase Structure

MongoDB replication (src/mongo/db/repl/) contains 401 C++/header files totaling ~162K lines. The commit point protocol spans:

| File | Lines | Role |
|------|-------|------|
| topology_coordinator.cpp | 4,029 | Commit point calculation, election logic, heartbeat processing, sync source selection |
| replication_coordinator_impl.cpp | 5,944 | Top-level coordination, stable timestamp, write concern, state transitions |
| replication_coordinator_impl_heartbeat.cpp | 1,401 | Heartbeat response handling, commit point propagation, reconfig via heartbeat |
| replication_coordinator_impl_elect_v1.cpp | 497 | Election protocol (dry-run + real vote) |
| replication_coordinator_impl_step_up_step_down.cpp | 391 | Stepup/stepdown transitions |
| replication_coordinator_impl_catchup.cpp | 451 | Primary catchup after election |
| rollback_impl.cpp | 1,504 | Rollback mechanism, commit point safety checks |

### Existing TLA+ Specifications

Four specs exist in the repository:

1. **RaftMongo.tla** (331 lines): Base commit point protocol. Variables: `currentTerm`, `state`, `commitPoint`, `log`, `committedEntries`. Abstracts elections via `BecomePrimaryByMagic`. No messages, no network.

2. **RaftMongoReplTimestamp.tla** (~450 lines): Extends base with `lastDurable`, `lastApplied`, `committedSnapshot`, `Restart` action. Adds durability separation but still no `lastWritten`.

3. **MongoReplReconfig.tla** (~492 lines): Separate spec for reconfig protocol.

4. **RaftMongoWithRaftReconfig.tla** (~260 lines): Experimental/exploratory spec.

### Key Architectural Insight: Three-Level Write Pipeline

The real implementation has a three-level pipeline not reflected in any TLA+ spec:
```
Write to oplog (lastWritten) -> Apply to collections (lastApplied) -> Journal flush (lastDurable)
```
The TLA+ spec models only two levels: `lastApplied` and `lastDurable`.

---

## Phase 2: Bug Archaeology

### Category 1: Commit Point Propagation (16+ commits)

The commit point protocol was redesigned at least 3 times:

**Iteration 1** (SERVER-27123, commit 87f49488f1): Restricted commit point learning to sync source only. This was too restrictive — stalled commit point propagation.

**Iteration 2** (SERVER-39367, commit a78f546ff0): Reverted SERVER-27123. Added term check: secondaries only learn commit points whose term matches their own last log term. This was the fix discovered via TLA+ model checking (TLAConf 2019).

**Iteration 3** (SERVER-39831, commit 6803c64d71): Added "never beyond last applied" constraint — secondary learning commit point from sync source clamps to min(commitPoint, lastApplied). A 20-file change.

**Iteration 4** (SERVER-85701/87920, 2024): Changed the bounding from `lastApplied` to `lastWritten` throughout.

Key bug-fix commits:
- SERVER-54374: Blocked commit point update during rollback state
- SERVER-42305: Ensured replication initialized before heartbeat commit point
- SERVER-78813: Fixed stalled commit point on exhaust oplog cursors
- SERVER-85701: Commit point calc switched from lastApplied to lastWritten
- SERVER-87920: Sync source bound switched from lastApplied to lastWritten

### Category 2: Election / Term Safety (15+ commits)

- SERVER-114780: Ensured node cannot vote in term T after voting in T' > T
- SERVER-101936: Check for newer term during catchup before writable primary
- SERVER-84196: Election freshness check changed from lastApplied to lastWritten
- SERVER-34682: Old primary stores lastVote when casting vote in new term
- SERVER-53813: Prevented stale majority reads on new primary after election
- SERVER-37255: Fixed invariant violation when reconfig races with election
- SERVER-48257: Rejected reconfig via heartbeat during election

### Category 3: Rollback Safety (10+ commits)

- SERVER-30940: Ensured never roll back behind commit point
- SERVER-61977: Concurrent rollback and stepUp race fixed
- SERVER-55376: Reconfig cannot roll back committed writes in PSA sets
- SERVER-54374: Commit point update blocked during rollback

### Category 4: Race Conditions (16+ commits)

Data races cluster around:
- Heartbeat response handling (SERVER-81480, SERVER-91374)
- Term updates during reconfig (SERVER-91374)
- BackgroundSync vs state transitions (SERVER-87521, SERVER-62379)
- WaitForMajorityService iterators (SERVER-68240)

### Category 5: Deadlocks (15+ commits)

Lock ordering violations between _mutex, BackgroundSync mutex, RSTL, and global lock:
- SERVER-62379: ReplicationCoordinator vs BackgroundSync on stepUp
- SERVER-87728: oplog buffer waitForSpace vs bgSync mutex
- SERVER-55277: _createOplogBuffer vs stepDown
- SERVER-19782: Shutdown mid-transition to primary

### Category 6: Heartbeat Protocol (8+ commits)

- SERVER-81480: Data race in _handleHeartbeatResponse
- SERVER-47949: Config fetch via heartbeat during drain mode
- SERVER-48257: Reconfig via heartbeat during election
- SERVER-42305: Commit point advance before repl initialized
- SERVER-76581: Stale topologyVersion from heartbeats during stepdown

---

## Phase 3: Deep Analysis

### 3.1 Commit Point Advancement — Primary Path

**Entry**: `TopologyCoordinator::updateLastCommittedOpTimeAndWallTime()` (topology_coordinator.cpp:3131)

1. Must be primary and NOT in `kSteppingDown` mode (line 3136). Note: `kAttemptingStepDown` is deliberately allowed.
2. Checks `getWriteConcernMajorityShouldJournal()` to choose between `lastDurable` and `lastWritten` (line 3141).
3. Collects optimes from all voting members (lines 3143-3156).
4. Sorts and picks `votingOptimes[size - writeMajority]` (line 3166-3168).
5. Delegates to `advanceLastCommittedOpTimeAndWallTime()`.

### 3.2 Commit Point Advancement — Secondary Paths

**Heartbeat path** (replication_coordinator_impl_heartbeat.cpp:322-332):
- Extracts `lastOpCommitted` from ReplSetMetadata
- Blocked during startup, startup2, and rollback states (line 326-328)
- Calls `_advanceCommitPoint()` with `fromSyncSource=false`
- In `advanceLastCommittedOpTimeAndWallTime`: if term differs from myLastWritten, **rejected entirely** (line 3208-3215)

**Sync source path** (data_replicator_external_state_impl.cpp:96-108):
- Extracts `lastOpCommitted` from OplogQueryMetadata
- Calls `advanceCommitPoint()` with `fromSyncSource=true`
- In `advanceLastCommittedOpTimeAndWallTime`: if term differs, **clamped** to min(commitPoint, myLastWritten) (line 3206)

### 3.3 The `_firstOpTimeOfMyTerm` Sentinel

This variable controls when a primary can advance the commit point:

| State | Value | Effect |
|-------|-------|--------|
| processWinElection | `{INT_MAX, INT_MAX}` | Blocks ALL commit point advancement during catchup/drain |
| completeTransitionToPrimary | actual first optime of term | Allows commit only for optimes >= this value |

Guard at topology_coordinator.cpp:3193: `if (_iAmPrimary() && committedOpTime.opTime < _firstOpTimeOfMyTerm) return false`

This implements the Raft safety rule: a new leader must commit an entry from its own term before committing entries from previous terms.

### 3.4 Heartbeat Response Processing Order

In `_handleHeartbeatResponse` (replication_coordinator_impl_heartbeat.cpp:233-468):

1. Lock _mutex (line 241)
2. Parse response (line 268-272)
3. **Advance commit point** (line 331) — BEFORE term update
4. **Update term from metadata** (line 337) — may trigger stepdown
5. **Update term from response body** (line 371) — second term update
6. Process heartbeat data (line 391) — updates member optimes
7. Recalculate commit on primary (line 400) — if optime advanced

The commit-point-before-term-update ordering means a primary could advance its commit point and then immediately step down in the same callback. The guards in `advanceLastCommittedOpTimeAndWallTime` (term check, _firstOpTimeOfMyTerm, monotonicity) make this safe, but it creates a subtle window.

### 3.5 Election Protocol Details

**Dry-run phase** (elect_v1.cpp:215): Uses current term. No persistent state changes.

**Real election** (elect_v1.cpp:280-348):
1. Under _mutex: increment term, self-vote (updates _lastVote in memory)
2. Outside _mutex: persist lastVote to disk asynchronously (line 338-348)
3. Schedule VoteRequester to gather votes from other members

**Vote granting** (topology_coordinator.cpp:3740-3806):
- Check `_lastVote.getTerm() >= args.getTerm()` — prevent double-voting (line 3768)
- Check `args.getLastWrittenOpTime() < getMyLastWrittenOpTime()` — freshness (line 3761)
- Config version and term must match (line 3782)

**Crash window**: LastVote is persisted asynchronously. Between in-memory update and disk write, a crash could lose the vote record. The comment at replication_coordinator_impl.cpp:5325-5328 acknowledges this but argues it's safe because term monotonicity is enforced on recovery.

### 3.6 Rollback Safety Mechanisms

**Hard safety**: Four fasserts in rollback_impl.cpp:1231-1236 ensure `commonPoint >= commitPoint`. Violation = process crash. This is the ultimate safety net.

**Soft safety**:
- Heartbeat commit point blocked during rollback (heartbeat.cpp:326-328)
- Commit point monotonicity enforced (topology_coordinator.cpp:3223-3229)
- RSTL prevents concurrent rollback + stepUp

### 3.7 lastWritten / lastApplied / lastDurable Deep Dive

**Definitions** (from member_data.h:362-372):
- `lastWritten`: oplog entry written to oplog collection in memory
- `lastApplied`: oplog entry applied to data collections
- `lastDurable`: oplog entry journaled to disk

**Ordering invariant**: `lastWritten >= lastApplied` enforced at replication_coordinator_impl.cpp:1577, 1594, 1612

**Commit point calculation** (topology_coordinator.cpp:3141):
```cpp
const bool useDurableOpTime = _rsConfig.getWriteConcernMajorityShouldJournal();
```
- `true` (default): uses `lastDurable` per member
- `false`: uses `lastWritten` per member

**TLA+ spec gap**: RaftMongoReplTimestamp.tla always uses `lastDurable` in `Agree()`. The `lastWritten` path is entirely unverified.

### 3.8 Developer Signal Analysis

| Signal | File:Line | Context |
|--------|-----------|---------|
| TODO(sz) | heartbeat.cpp:368-369 | Dual term update from metadata and response body |
| TODO | topology_coordinator.cpp:2299 | Revisit FeatureFlagAllMongodsAreSharded |
| TODO | topology_coordinator.cpp:2849,2855 | Remove kNotLeader case from mode transitions |
| TODO | repl_set_heartbeat_response.cpp:76,156 | Unsafe Timestamp-to-Date_t conversion |
| TODO | replication_coordinator_impl.cpp:2040 | Remove deprecated wait method |
| Dead code | topology_coordinator.h:1218 | `_electionSleepUntil` assigned but never read |

---

## Phase 4: Bug Family Synthesis

### Family 1: Commit Point Propagation Protocol Bugs
- **Bug density**: 16+ commits, 3+ redesigns
- **Severity**: Critical (safety violation confirmed at larger bounds)
- **TLA+ suitability**: Excellent — this is exactly what the existing spec targets
- **Key action**: Run with 5 servers, 3 terms, 4+ log entries to trigger SERVER-39626

### Family 2: lastWritten / lastApplied / lastDurable Confusion
- **Bug density**: 4 commits in 2024
- **Severity**: High (recent migration, TLA+ spec not updated)
- **TLA+ suitability**: Excellent — requires adding one variable and splitting one action
- **Key action**: Add `lastWritten`, model non-journal commit path

### Family 3: Election / Catchup / Stepdown Interaction
- **Bug density**: 15+ commits
- **Severity**: High (election safety)
- **TLA+ suitability**: Good — requires replacing BecomePrimaryByMagic with explicit protocol
- **Key action**: Model vote + catchup + drain + no-op sequence

### Family 4: Heartbeat Side-Channel
- **Bug density**: 8+ commits
- **Severity**: Medium (ordering concerns, guards mostly in place)
- **TLA+ suitability**: Good — requires adding message model
- **Key action**: Model heartbeat as messages with explicit ordering

### Family 5: Rollback / Commit Point Regression
- **Bug density**: 10+ commits
- **Severity**: High (but well-guarded by fasserts)
- **TLA+ suitability**: Good — extends existing Restart action
- **Key action**: Validate fassert-enforced invariants hold under new lastWritten regime

---

## Excluded Items (False Positives / Out of Scope)

| Item | Reason for Exclusion |
|------|---------------------|
| Deadlocks (15+ commits) | Implementation-level lock ordering, not protocol logic. Better tested by TSAN/runtime verification. |
| Oplog batching/visibility | Performance optimization. Batch boundaries don't affect commit point protocol correctness. |
| Initial sync protocol | Separate protocol. Commit point is not advanced during initial sync (skipped at replication_coordinator_impl.cpp:5125). |
| Read concern levels | Downstream of commit point. The commit point feeds into majority reads, but read bugs are about timestamps/storage. |
| Transaction handling | Cross-layer but primarily affects prepared transaction lifecycle, not commit point propagation. |
| _electionSleepUntil dead code | Cosmetic issue. No safety impact. |
| SERVER-108961 timestamp conversion | Serialization bug in heartbeat response. Does not affect commit point protocol. |
