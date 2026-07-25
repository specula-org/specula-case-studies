# Modeling Brief: MongoDB RaftMongo Replication Commit Point

## 1. System Overview

- **System**: MongoDB replication commit point protocol (RaftMongo)
- **Language**: C++, ~15K LOC core logic (replication_coordinator_impl.cpp: 5944, topology_coordinator.cpp: 4029, heartbeat: 1401, rollback: 1504, election: 497)
- **Protocol**: Modified Raft with commit point propagation via heartbeats and sync source metadata
- **Version analyzed**: 8.3.0-alpha3 (master, commit 1425a42f2d)
- **Key architectural choices**:
  - Elections abstracted in existing spec (`BecomePrimaryByMagic`); actual impl uses dry-run + real vote
  - Three-level write pipeline: `lastWritten -> lastApplied -> lastDurable` (TLA+ spec only models 2 levels)
  - Commit point propagation via two channels: heartbeats (term-checked) and sync source (clamped)
  - `_firstOpTimeOfMyTerm` sentinel blocks commit advancement during catchup/drain phase
  - LastVote persisted to disk asynchronously (not atomic with in-memory term update)
- **Concurrency model**: Single-threaded task executor for replication callbacks; `_mutex` protects shared state; RSTL (Replication State Transition Lock) serializes role transitions

## 2. Bug Families

### Family 1: Commit Point Propagation Protocol Bugs (HIGH)

**Mechanism**: The commit point learning protocol has two channels (heartbeat and sync source) with different trust models and term checks. Historical bugs show these checks are fragile and the protocol was redesigned 3+ times. SERVER-39626 documents a known safety violation at bounds the existing spec cannot reach.

**Evidence**:
- Historical: SERVER-39626 — NeverRollbackCommitted violated at 5 servers, 3 terms, 4+ log entries (MCRaftMongo.cfg:19-22)
- Historical: SERVER-27123 — restricted commit point to sync source only (later reverted by SERVER-39367)
- Historical: SERVER-39367 — reverted SERVER-27123 and SERVER-33248, added term check
- Historical: SERVER-39831 — added "never beyond last applied" constraint for sync source path
- Historical: SERVER-54374 — commit point update via heartbeat during rollback was unsafe
- Historical: SERVER-78813 — commit point propagation stalled on exhaust oplog cursors
- Code: topology_coordinator.cpp:3203-3217 — heartbeat path rejects different-term commit points; sync source path clamps to min(commitPoint, myLastWritten)

**Affected code paths**:
- `TopologyCoordinator::advanceLastCommittedOpTimeAndWallTime()` (topology_coordinator.cpp:3174-3246)
- `TopologyCoordinator::updateLastCommittedOpTimeAndWallTime()` (topology_coordinator.cpp:3131-3172)
- Heartbeat handler commit point (replication_coordinator_impl_heartbeat.cpp:322-332)
- Sync source metadata handler (data_replicator_external_state_impl.cpp:96-108)

**Suggested modeling approach**:
- Variables: retain `commitPoint`, `log`, `currentTerm`, `state` from existing spec
- Actions: Keep existing `AdvanceCommitPoint`, `LearnCommitPointWithTermCheck`, `LearnCommitPointFromSyncSourceNeverBeyondLastApplied`
- **Critical**: Run with 5 servers, 3+ terms, 4+ log entries to trigger SERVER-39626
- Use symmetry reduction (`Permutations(Server)`) and state constraints to manage explosion
- Split sync source learning to model the clamping vs rejection distinction

**Priority**: High
**Rationale**: Known unfound violation (SERVER-39626) at larger bounds. Protocol redesigned 3+ times. 8+ historical bug-fix commits on this exact mechanism. The existing spec explicitly documents it cannot trigger the bug.

---

### Family 2: lastWritten / lastApplied / lastDurable Confusion (HIGH)

**Mechanism**: In 2024, MongoDB migrated multiple critical code paths from `lastApplied` to a new `lastWritten` optime, creating a three-level pipeline (written -> applied -> durable). The existing TLA+ spec only models two levels (applied -> durable) and predates this migration. Any path still using `lastApplied` where `lastWritten` is needed, or vice versa, is a potential safety bug.

**Evidence**:
- Historical: SERVER-85701 (commit cec86a95e6) — commit point calc changed from lastApplied to lastWritten when !journal
- Historical: SERVER-87920 (commit a09ac7ed96) — commit point bound from sync source changed from lastApplied to lastWritten
- Historical: SERVER-84196 (commit 56d4a13603) — election vote freshness check changed from lastApplied to lastWritten
- Historical: SERVER-85702 (commit ea4904589d) — secondary term check changed to use lastWritten
- Code: topology_coordinator.cpp:3141 — `useDurableOpTime` flag selects between lastDurable and lastWritten for commit calculation
- Code: topology_coordinator.cpp:3204 — term check uses `getMyLastWrittenOpTime().getTerm()`
- Spec gap: RaftMongoReplTimestamp.tla has no `lastWritten` variable; `ClientWrite` atomically sets `lastApplied` on leader (lines 262-263)
- Spec gap: `Agree()` in RaftMongoReplTimestamp.tla always uses `lastDurable` (line 109-112); code uses lastWritten for non-journal case

**Affected code paths**:
- `TopologyCoordinator::updateLastCommittedOpTimeAndWallTime()` (topology_coordinator.cpp:3141-3152)
- `TopologyCoordinator::advanceLastCommittedOpTimeAndWallTime()` (topology_coordinator.cpp:3203-3217)
- `processReplSetRequestVotes()` vote freshness (topology_coordinator.cpp:3761-3767)
- `setMyLastWrittenOpTimeAndWallTimeForward()` (replication_coordinator_impl.cpp:1640-1700)
- `setMyLastAppliedAndLastWrittenOpTimeAndWallTimeForward()` (replication_coordinator_impl.cpp:1603-1621)

**Suggested modeling approach**:
- Variables: Add `lastWritten [Server -> [term: Nat, index: Nat]]` alongside existing `lastApplied` and `lastDurable`
- Actions: Split `ClientWrite` on leader into WriteToOplog (updates lastWritten) + ApplyToData (updates lastApplied). On follower, `AppendOplog` updates lastWritten; separate `ApplyOplog` updates lastApplied.
- Add `writeConcernMajorityShouldJournal` constant to switch Agree() between lastDurable and lastWritten
- Invariant: `lastWritten >= lastApplied` should always hold (except during rollback)

**Priority**: High
**Rationale**: 4 bug-fix commits in 2024 on this exact mechanism. The TLA+ spec is stale and doesn't model this. The non-journal commit point path (`lastWritten`-based) is entirely unverified by any TLA+ spec. This is the most likely source of undiscovered bugs.

---

### Family 3: Election / Catchup / Stepdown Commit Point Interaction (MEDIUM)

**Mechanism**: The transition from Follower -> Candidate -> Primary involves multiple phases (dry-run vote, real vote, catchup, drain, write no-op) where the commit point must be carefully frozen and then unblocked. Historical bugs show this sequence is error-prone, especially when concurrent term changes arrive.

**Evidence**:
- Historical: SERVER-114780 (commit a637cb5abd) — node voted in term T after having voted in term T' > T
- Historical: SERVER-101936 (commit 8b5b50286f) — newer term discovered during catchup before transition to writable primary
- Historical: SERVER-34682 (commit 6ccdeffc5a) — old primary should store lastVote when casting vote in new term
- Historical: SERVER-53813 (commit ee0c25083f) — stale majority reads on new primary after election
- Code: topology_coordinator.cpp:2935 — `_firstOpTimeOfMyTerm` set to INT_MAX during catchup (blocks all commit advancement)
- Code: topology_coordinator.cpp:3278 — `_firstOpTimeOfMyTerm` set to no-op optime during completeTransitionToPrimary
- Code: replication_coordinator_impl_elect_v1.cpp:338-348 — lastVote persisted asynchronously outside mutex
- Finding: `_electionSleepUntil` (topology_coordinator.h:1218) is assigned at topology_coordinator.cpp:3301 but never read (dead code)

**Affected code paths**:
- `_startRealElection` (replication_coordinator_impl_elect_v1.cpp:280-348)
- `processWinElection` (topology_coordinator.cpp:2924-2937)
- `completeTransitionToPrimary` (topology_coordinator.cpp:3271-3278)
- `signalApplierDrainComplete` (replication_coordinator_impl.cpp:1394-1540)
- `_updateTerm` returning `kTriggerStepDown` (replication_coordinator_impl.cpp:5573-5588)

**Suggested modeling approach**:
- Variables: Replace `BecomePrimaryByMagic` with explicit `StartElection`, `CastVote`, `WinElection`, `CatchUp`, `WritePrimaryNoOp`, `CompletePrimary` actions
- Model `_firstOpTimeOfMyTerm` as a variable: set to Infinity on WinElection, updated to actual optime on CompletePrimary
- Model `lastVote` persistence: split into in-memory update + async disk write + Crash between
- Add `CatchupAbort` action when higher term discovered during catchup

**Priority**: Medium
**Rationale**: 4+ historical bugs. The existing spec completely abstracts elections. Modeling the catchup/drain/no-op sequence would reveal interactions not tested by the existing spec. However, the commit point freeze mechanism (`_firstOpTimeOfMyTerm = INT_MAX`) is simple and appears correct.

---

### Family 4: Heartbeat as Side-Channel for State Changes (MEDIUM)

**Mechanism**: Heartbeat responses carry commit point, term, config, and member state. Processing a heartbeat response applies these in a specific order: commit point first, then metadata term, then response-body term, then member data. This ordering creates windows where stale or out-of-order information is partially applied.

**Evidence**:
- Historical: SERVER-81480 (commit 439014433b) — data race in `_handleHeartbeatResponse`
- Historical: SERVER-48257 (commit e8c93d3278) — reconfig via heartbeat during election
- Historical: SERVER-47949 (commit 2546fe1c22) — config fetch via heartbeat during drain mode
- Historical: SERVER-42305 (commit 2a4d319f02) — commit point advance before repl initialized
- Code: replication_coordinator_impl_heartbeat.cpp:331 — commit point advanced BEFORE term update at line 371
- Code: replication_coordinator_impl_heartbeat.cpp:368-369 — TODO(sz) acknowledges dual term update from metadata and response body
- Code: replication_coordinator_impl_heartbeat.cpp:326-332 — commit point blocked during rollback/startup states

**Affected code paths**:
- `_handleHeartbeatResponse` (replication_coordinator_impl_heartbeat.cpp:233-468)
- `_scheduleHeartbeatReconfig` (replication_coordinator_impl_heartbeat.cpp:674-741)
- `_heartbeatReconfigFinish` (replication_coordinator_impl_heartbeat.cpp:899-1072)
- `TopologyCoordinator::processHeartbeatResponse` (topology_coordinator.cpp:1119-1295)

**Suggested modeling approach**:
- Variables: Model heartbeat as explicit messages with `{term, commitPoint, configVersion, configTerm}` payload
- Actions: `SendHeartbeat`, `ReceiveHeartbeatResponse` with explicit ordering of field processing
- Model message loss, delay, and reordering to test whether commit point-before-term-update is safe
- Model reconfig-via-heartbeat with guards for election/drain/rollback states

**Priority**: Medium
**Rationale**: 4+ historical bugs on heartbeat processing. The commit-point-before-term-update ordering is a deliberate design choice but creates subtle windows. The existing spec has no message model at all, making this entirely unexplored territory for model checking.

---

### Family 5: Rollback / Commit Point Regression Safety (LOW for new bugs)

**Mechanism**: Rolling back past the commit point would violate the fundamental safety property. MongoDB enforces this via fatal assertions (fasserts) — the node crashes rather than regressing. Multiple bugs have required adding guards to prevent commit point advancement during states that could lead to rollback.

**Evidence**:
- Historical: SERVER-30940 (commit a14ac80417) — ensure never roll back behind commit point
- Historical: SERVER-55376 (commit b526127542) — reconfig can roll back committed writes in PSA sets
- Historical: SERVER-61977 (commit 992e538d26) — concurrent rollback and stepUp race
- Code: rollback_impl.cpp:1231-1236 — four fasserts checking commonPoint >= commitPoint/committedSnapshot
- Code: rollback_impl.cpp:1240-1245 — fassert checking commonPoint >= stableTimestamp
- Code: topology_coordinator.cpp:3223-3229 — commit point monotonicity enforcement

**Affected code paths**:
- `RollbackImpl::_findCommonPoint()` (rollback_impl.cpp:1182-1248)
- `_transitionToRollback()` (rollback_impl.cpp:385-431)
- `resetLastOpTimesFromOplog()` (replication_coordinator_impl.cpp:4962-4984)

**Suggested modeling approach**:
- Already partially modeled in RaftMongoReplTimestamp.tla via `Restart` action
- Extend with `Rollback` action that truncates to common point with sync source
- Add `Crash` action that recovers from `max(lastDurable, committedSnapshot)`
- Check `NeverRollbackCommitted` and `NeverRollbackBeforeCommitPoint` invariants

**Priority**: Low (for new bugs)
**Rationale**: The existing safety mechanisms (fasserts) are robust — the system crashes rather than corrupting. PSA-specific bugs (SERVER-55376) require reconfig modeling. The stable-timestamp-based recovery makes regression unlikely. Main value is confirming existing guards are sufficient under the new lastWritten regime.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Commit point at larger bounds | Family 1: SERVER-39626 known violation at 5 servers | Run existing spec with 5 servers, MaxTerm=3, MaxLogLen=4; use symmetry |
| `lastWritten` three-level pipeline | Family 2: 4 bugs in 2024, TLA+ spec is stale | Add `lastWritten` variable; split ClientWrite into write + apply steps |
| `writeConcernMajorityShouldJournal` flag | Family 2: switches Agree() between lastDurable and lastWritten | Add constant; parameterize `Agree()` |
| Explicit heartbeat messages | Family 4: commit point propagation ordering | Replace direct-read with message passing; model delay/loss |
| Election detail (at least vote + catchup) | Family 3: `BecomePrimaryByMagic` hides real protocol | Model VoteRequest/Response, `_firstOpTimeOfMyTerm` lifecycle |
| Rollback with commit point check | Family 5: validate fassert-enforced invariant | `Rollback` action truncates to common point; invariant checks |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Deadlocks / lock ordering | Families are implementation-level concurrency, not protocol logic. 15+ deadlock fixes all involve mutex/RSTL ordering — better tested by TSAN. |
| Oplog batching / applier pipeline | Performance optimization, not safety-relevant. The batch boundaries don't affect commit point correctness. |
| Initial sync | Separate protocol with different safety properties. Not related to commit point propagation bugs. |
| Read concern / snapshot isolation | Would massively expand spec scope. The commit point feeds into read concern, but the read path bugs are about timestamps and storage, not protocol logic. |
| Transaction integration | Cross-layer interaction but primarily affects prepared transaction handling, not commit point protocol. |
| Reconfig (in this round) | MongoReplReconfig.tla already exists as a separate spec. PSA bugs (SERVER-55376) are reconfig-specific. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Larger model bounds | (parameter change) | Trigger SERVER-39626 at 5 servers, 3 terms, 4 log entries | Family 1 |
| lastWritten pipeline | `lastWritten [Server -> [term, index]]` | Model 3-level write pipeline, verify non-journal commit path | Family 2 |
| Journal config flag | `writeConcernMajorityShouldJournal` (constant) | Switch Agree() between lastDurable and lastWritten | Family 2 |
| Heartbeat messages | `heartbeatMessages` (message bag) | Model commit point propagation ordering and message loss | Family 4 |
| Explicit election protocol | `votesGranted`, `lastVote`, `firstOpTimeOfMyTerm` | Replace BecomePrimaryByMagic with real voting + catchup | Family 3 |
| Crash and recovery | `crashed [Server -> BOOLEAN]` | Model crash between lastVote write and term persist | Family 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NeverRollbackCommitted | Safety | No committed entry is ever the target of a rollback | Family 1, Family 5 (existing) |
| NeverRollbackBeforeCommitPoint | Safety | Oplog never shorter than own commit point after rollback | Family 1, Family 5 (existing) |
| NoTwoPrimariesInSameTerm | Safety | At most one leader per term | Family 3 (existing) |
| CommitPointNeverExceedsLastWritten | Safety | `commitPoint[s] <= lastWritten[s]` for all non-arbiter servers | Family 2 |
| WriteApplyOrdering | Safety | `lastWritten[s] >= lastApplied[s]` always (except during rollback) | Family 2 |
| CommitPointOnCorrectBranch | Safety | If commitPoint[s].term != LastTerm(log[s]), then commitPoint[s] <= lastWritten[s] | Family 1, 4 |
| FirstOpTimeGuard | Safety | Primary never commits optime < firstOpTimeOfMyTerm | Family 3 |
| HeartbeatTermMonotonicity | Safety | A heartbeat response with higher term triggers stepdown before commit point use | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | SERVER-39626 at 5 servers, 3 terms, 4+ log entries | NeverRollbackCommitted | 1 |
| MC-2 | Non-journal commit point uses lastWritten — is the 3-level pipeline safe? | CommitPointNeverExceedsLastWritten | 2 |
| MC-3 | Heartbeat commit point advanced before term update — safe under message reordering? | CommitPointOnCorrectBranch | 4 |
| MC-4 | LastVote crash between in-memory update and disk persist | NoTwoPrimariesInSameTerm | 3 |
| MC-5 | Catchup abort on higher term — does commit point freeze correctly? | FirstOpTimeGuard | 3 |
| MC-6 | Sync source clamping: can min(committedOpTime, myLastWritten) still violate safety? | NeverRollbackCommitted | 1, 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | SERVER-91374 data race between getTerm and updateTerm in _doReplSetReconfig | Thread sanitizer test with concurrent reconfig + heartbeat |
| TV-2 | Dual term update in heartbeat response (TODO(sz) at heartbeat.cpp:368) | Integration test: send heartbeat with metadata term != body term |
| TV-3 | `_electionSleepUntil` dead code (assigned at topology_coordinator.cpp:3301, never read) | Code review: delete dead assignment |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | SERVER-108961 — unsafe Timestamp-to-Date_t conversion in heartbeat electionTime (repl_set_heartbeat_response.cpp:76,156) | Fix TODO: use proper conversion |
| CR-2 | SERVER-29729 — deprecated _waitUntilOpTimeForReadDeprecated still present (replication_coordinator_impl.cpp:2040) | Remove deprecated code path |
| CR-3 | SERVER-30852 — kNotLeader case in mode transitions still has TODO (topology_coordinator.cpp:2849,2855) | Review whether removal is safe |

## 7. Reference Pointers

- **Existing TLA+ specs**:
  - `artifact/mongo-src/src/mongo/tla_plus/Replication/RaftMongo/RaftMongo.tla` (331 lines, base spec)
  - `artifact/mongo-src/src/mongo/tla_plus/Replication/RaftMongoReplTimestamp/RaftMongoReplTimestamp.tla` (~450 lines, durability extension)
  - `artifact/mongo-src/src/mongo/tla_plus/Replication/MongoReplReconfig/MongoReplReconfig.tla` (~492 lines, reconfig spec)
- **Key source files**:
  - `artifact/mongo-src/src/mongo/db/repl/topology_coordinator.cpp` (4029 lines) — commit point calc, election, heartbeat processing
  - `artifact/mongo-src/src/mongo/db/repl/replication_coordinator_impl.cpp` (5944 lines) — coordination, stable timestamp
  - `artifact/mongo-src/src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp` (1401 lines) — heartbeat response handling
  - `artifact/mongo-src/src/mongo/db/repl/rollback_impl.cpp` (1504 lines) — rollback safety
  - `artifact/mongo-src/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp` (497 lines) — election
- **Key SERVER tickets**: SERVER-39626, SERVER-85701, SERVER-87920, SERVER-84196, SERVER-114780, SERVER-54374, SERVER-61977, SERVER-55376
- **TLA+ Conference talk**: https://conf.tlapl.us/07_-_TLAConf19_-_William_Schultz_-_Fixing_a_MongoDB_Replication_Protocol_Bug_with_TLA.pdf
- **Shared harness**: `case-studies/mongodb-shared-harness.md` (3-node RS template, log parsing approach)
