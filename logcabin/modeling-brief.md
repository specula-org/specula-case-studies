# Modeling Brief: logcabin/logcabin

## 1. System Overview

- **System**: logcabin/logcabin — C++ Raft consensus library by Diego Ongaro (Raft's co-author)
- **Language**: C++, ~3,037 LOC core logic (`Server/RaftConsensus.cc`)
- **Protocol**: Raft with joint-consensus membership changes, leader disk thread, leader lease (epoch-based step-down)
- **Key architectural choices**:
  - **Monitor pattern**: Single mutex protects all RaftConsensus state; lock released during RPC calls and disk I/O
  - **Leader disk thread**: Leader appends entries to memory, defers disk sync to a background thread (`leaderDiskThread`); followers sync inline
  - **Epoch-based step-down**: Leader uses a `currentEpoch` counter + `stepDownThread` to detect quorum loss (not heartbeat-based)
  - **Two-phase config changes**: STABLE → STAGING → TRANSITIONAL (joint consensus) → STABLE
  - **withholdVotesUntil**: Extension to prevent removed/partitioned servers from disrupting the cluster via elections
  - **stepDown busy-waits on disk thread**: `stepDown()` holds mutex while polling `leaderDiskThreadWorking` with `usleep(500)`, blocking all server operations during disk flush

## 2. Bug Families

### Family 1: Log Truncation and Entry Integrity (HIGH)

**Mechanism**: Log truncation + append operations have a crash window where entries can be lost, and several handlers use assertions (crashes) instead of guards on network-received values.

**Evidence**:
- Historical: #160 (CRITICAL) — missing `break` in AppendEntries packing caused non-contiguous entries to be sent, corrupting follower logs
- Historical: #44 (CRITICAL) — commitment of entries from prior terms violated Raft safety; fixed by adding current-term check in `advanceCommitIndex`
- Historical: commit 8b8e948 — `getTerm()` returned 0 for snapshotted entries, affecting term comparisons in election and replication
- Code analysis: RaftConsensus.cc:1340-1355 — acknowledged non-atomic `truncateSuffix` + `append` crash window in `handleAppendEntries`
- Code analysis: RaftConsensus.cc:1418 — assertion (not guard) on `commitIndex <= lastLogIndex`; buggy leader crashes follower
- Code analysis: RaftConsensus.cc:1392-1399 — PANIC on `EntryType::UNKNOWN` from network
- Code analysis: RaftConsensus.cc:1316,1465 — assertion on leader identity mismatch

**Affected code paths**:
- `handleAppendEntries()` (RaftConsensus.cc:1263-1427) — truncation, append, commit index update
- `advanceCommitIndex()` (RaftConsensus.cc:2174-2225) — commitment rule
- `appendEntries()` (RaftConsensus.cc:2233-2342) — leader-side packing of entries

**Suggested modeling approach**:
- Actions: Model `TruncateAndAppend` as two separate steps with a `Crash` action between them
- Model the fixed commitment rule (current-term check) as an invariant to verify correctness
- Variables: `persistedLog` vs `memoryLog` to distinguish durability states

**Priority**: High
**Rationale**: 2 critical historical bugs (#160, #44) plus an acknowledged crash window. Log integrity is the core safety property for Raft. The truncation crash window is directly model-checkable.

---

### Family 2: Snapshot-Log Interaction (HIGH)

**Mechanism**: Snapshot operations interact with log prefix truncation, creating states where term/entry lookups fail or return incorrect values, and where crash recovery is unreliable.

**Evidence**:
- Historical: #191/#221 (CRITICAL) — zero-byte open segment after crash causes PANIC on restart; correlated power failure bricks entire cluster
- Historical: #174 — repeated PANIC on follower restart during snapshot transfer (byte offset mismatch)
- Historical: commit 445f383 (CRITICAL) — session `lastModified` timestamps missing from snapshot, causing premature session expiration after snapshot load
- Historical: commit 8b8e948 — `getTerm()` returned 0 for entries in truncated log prefix, breaking election and replication term comparisons
- Historical: commit e333046 — `upToDateLeader()` wedged when entire log was discarded and `commitIndex` entry was in snapshot
- Historical: commit 91aa4ed — peer threads leaked when `Configuration::reset()` was called during snapshot load
- Code analysis: RaftConsensus.cc:1502-1520 — no integrity check on snapshot data received from leader
- Code analysis: RaftConsensus.cc:1785-1793 — bogus term=0 written to snapshot header when entries already discarded

**Affected code paths**:
- `handleInstallSnapshot()` (RaftConsensus.cc:1430-1525) — snapshot reception
- `readSnapshot()` (RaftConsensus.cc:2629-2686) — snapshot loading, log prefix replacement
- `beginSnapshot()` / `snapshotDone()` (RaftConsensus.cc:1746-1859) — snapshot creation
- ConfigurationManager `truncatePrefix` / `truncateSuffix` — config history vs snapshot interaction

**Suggested modeling approach**:
- Variables: `lastSnapshotIndex`, `lastSnapshotTerm`, `logStartIndex` to track the snapshot-log boundary
- Actions: `TakeSnapshot` (leader/follower), `InstallSnapshot` (leader→follower transfer), `DiscardLogPrefix`
- Key invariant: after snapshot load, `logStartIndex == lastSnapshotIndex + 1` and all entries in `[logStartIndex, lastLogIndex]` have valid terms
- Model crash during multi-chunk InstallSnapshot transfer

**Priority**: High
**Rationale**: 6 historical bugs (1 critical cluster-bricking, 2 critical data corruption) all share the snapshot-log interaction mechanism. This is the most bug-dense area in LogCabin.

---

### Family 3: Configuration Change Safety (HIGH)

**Mechanism**: Two-phase membership changes (joint consensus) interact with election, replication, and leader step-down in ways that cause cluster unavailability.

**Evidence**:
- Historical: #205 — removed leader continues starting elections after stepping down, preventing remaining servers from electing
- Historical: #56 — removed servers disrupt cluster with RequestVote RPCs; required adding `withholdVotesUntil`
- Historical: #183 — peer threads for removed servers hang in `createSession()`, blocking server exit
- Historical: #210 — reusing a removed server's ID causes stale configuration to win elections
- Code analysis: RaftConsensus.cc:1648-1675 — no absolute timeout on STAGING server catch-up; can block indefinitely
- Code analysis: RaftConsensus.cc:2210-2221 — `advanceCommitIndex` auto-appends C_new when C_{old,new} commits, no error handling
- Code analysis: RaftConsensus.cc:2206 — leader self-exclusion bumps term by 1, forcing cluster-wide step-down

**Affected code paths**:
- `setConfiguration()` (RaftConsensus.cc:1594-1726) — client-facing config change RPC
- `advanceCommitIndex()` (RaftConsensus.cc:2200-2221) — auto-transition from TRANSITIONAL to STABLE
- `startNewElection()` (RaftConsensus.cc:2858-2905) — election start guard for self-excluded servers
- `Configuration::quorumAll/quorumMin` — dual quorum during TRANSITIONAL state
- `stepDown()` (RaftConsensus.cc:2916) — resets STAGING but not TRANSITIONAL

**Suggested modeling approach**:
- Variables: `configState ∈ {Stable, Staging, Transitional}`, `oldServers`, `newServers` per server
- Actions: `ProposeConfigChange` (STABLE→STAGING→TRANSITIONAL), `CommitConfigChange` (TRANSITIONAL→STABLE)
- Model `withholdVotesUntil` extension to verify it prevents removed-server disruption
- Key: election quorum must consider BOTH old and new server sets during TRANSITIONAL

**Priority**: High
**Rationale**: 4 historical bugs, joint-consensus config changes are notoriously difficult, and the interaction with election is the most complex part of Raft. TLA+ is ideal for exploring this state space.

---

### Family 4: Leader Liveness and Disk Sensitivity (MEDIUM)

**Mechanism**: The leader step-down mechanism (epoch-based), election timer, and disk I/O performance interact to cause unnecessary leader changes.

**Evidence**:
- Historical: #200 — slow disk writes in `handleAppendEntries` cause follower to start election; fixed by resetting timer after disk write
- Historical: #202 (OPEN) — leader steps down when followers' disks are slow; step-down timeout = election timeout is too aggressive
- Historical: #49/#50 — GCC condition_variable bug caused 100% CPU, preventing timer thread from releasing lock
- Historical: commit 33785b0 — `leaderDiskThread` race on `stepDown()`, disk thread continued after state transition
- Code analysis: RaftConsensus.cc:2939-2940 — `stepDown()` busy-waits with mutex held during disk flush, blocking ALL operations
- Code analysis: RaftConsensus.cc:2036,2043 — `leaderDiskThreadWorking` set to false outside lock (technically UB on non-x86; actual type is `std::atomic<bool>` per header)
- Code analysis: RaftConsensus.cc:2122-2169 — epoch mechanism shares `currentEpoch` between stepDown, upToDateLeader, and catch-up monitoring

**Affected code paths**:
- `stepDownThreadMain()` (RaftConsensus.cc:2122-2169) — quorum loss detection
- `leaderDiskThreadMain()` (RaftConsensus.cc:2017-2050) — background log sync
- `stepDown()` (RaftConsensus.cc:2907-2951) — leadership termination + busy-wait
- `timerThreadMain()` (RaftConsensus.cc:2054-2079) — election timeout firing

**Suggested modeling approach**:
- Variables: `leaderDiskBlocked [Server → BOOLEAN]`, `lastAckEpoch [Server → Nat]`
- Actions: `StepDownCheck` (leader checks quorum ack), `DiskBlock`/`DiskUnblock` (model slow disk)
- Invariant: leader steps down only when truly partitioned, not when disk is slow
- Model the stepDown busy-wait as an atomic step (it blocks other operations)

**Priority**: Medium
**Rationale**: 1 open unfixed issue (#202). The epoch mechanism is logically sound but the disk sensitivity causes production availability problems. Model checking can verify the step-down logic handles disk delays correctly.

---

### Family 5: Non-Atomic Persistence and Crash Recovery (MEDIUM)

**Mechanism**: Persistence operations span multiple steps (metadata write, log write, segment management), with crash windows between them.

**Evidence**:
- Historical: #191/#221 — segment file creation has a crash window between file creation and version header write
- Code analysis: SegmentedLog.cc:758-800 — metadata uses dual-file alternating writes with fsync (correctly implemented)
- Code analysis: SegmentedLog.cc:642-676 — `truncatePrefix` updates metadata BEFORE deleting segments (crash-safe)
- Code analysis: SegmentedLog.cc:679-755 — `truncateSuffix` renames before truncating; recovery handles trailing bytes
- Code analysis: RaftConsensus.cc:2955-2962 — `updateLogMetadata` writes term+votedFor atomically in one metadata update (NOT two separate writes like hashicorp/raft)
- Code analysis: Log.h:44-49 — follower sync is inline; leader sync is deferred. Leader entries are in memory only until `Sync::wait()` completes.

**Affected code paths**:
- `SegmentedLog::updateMetadata()` — dual-file persistence
- `SegmentedLog::append()` — deferred sync with segment rollover
- `SegmentedLog::truncatePrefix/truncateSuffix` — log trimming with crash windows
- `leaderDiskThreadMain()` — deferred sync for leader entries

**Suggested modeling approach**:
- Variables: `persistedTerm`, `persistedVotedFor`, `persistedLog` vs `memoryLog`
- Actions: `PersistMetadata` (atomic, term+votedFor together), `PersistLogEntries` (deferred for leader, inline for follower), `Crash` + `Recover`
- Key: unlike hashicorp/raft, LogCabin persists term+votedFor atomically (single metadata write), so the two-step persist bug does NOT exist here
- Focus on: crash between `truncateSuffix` and subsequent `append`, crash during segment rollover

**Priority**: Medium
**Rationale**: The dual-metadata scheme is well-designed, and term+votedFor are persisted atomically. The main crash window (truncate+append) is acknowledged in comments. TLA+ can verify the recovery logic is correct.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Joint-consensus config changes | Family 3: 4 bugs, most complex interaction | `configState`, `oldServers`, `newServers`; dual quorum in TRANSITIONAL |
| withholdVotesUntil | Family 3: prevents removed-server election disruption | Timer variable; RequestVote guard |
| Epoch-based step-down | Family 4: unique mechanism, 1 open bug | `currentEpoch`, `lastAckEpoch` per peer; `StepDownCheck` action |
| Leader disk thread (deferred sync) | Family 1, 4: entries in memory before disk flush | `persistedLog` vs `memoryLog`; `LeaderDiskSync` action |
| Snapshot + log prefix truncation | Family 2: 6 bugs, most bug-dense area | `lastSnapshotIndex/Term`; `InstallSnapshot`, `TakeSnapshot`, `DiscardPrefix` |
| Crash and recovery | Family 5: validates persistence correctness | `Crash` action resets volatile state; `Recover` from persisted |
| Log truncation + append | Family 1: acknowledged crash window | Split into two steps with `Crash` between |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Thread lifecycle / destructor races | Family 6: C++ threading issues, not protocol logic |
| GCC condition_variable overflow (#49) | Library bug, not protocol logic |
| Assertion-vs-guard code style | Code quality issue; assertions are correct under non-Byzantine assumptions |
| Session management / exactly-once | Application-layer concern, orthogonal to consensus safety |
| ClusterClock monotonicity | Utility feature, not safety-relevant |
| Network transport details | Below the protocol abstraction layer |
| Snapshot data integrity (checksums) | Implementation concern, not protocol logic |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Joint consensus | `configState`, `oldServers`, `newServers` | Two-phase membership change with dual quorum | Family 3 |
| withholdVotesUntil | `withholdVotesUntil [Server → BOOLEAN]` | Prevent removed servers from disrupting elections | Family 3 |
| Epoch step-down | `currentEpoch`, `lastAckEpoch [Server → Nat]` | Leader quorum loss detection | Family 4 |
| Deferred leader sync | `persistedLog`, `memoryLog` | Model entries durable vs in-memory | Family 1, 4 |
| Snapshot-log boundary | `lastSnapshotIndex`, `lastSnapshotTerm`, `logStartIndex` | Track snapshot replacing log prefix | Family 2 |
| Crash/Recovery | (resets volatile state) | Validate persistence correctness | Family 1, 2, 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard |
| LogMatching | Safety | Same index+term implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in all future leaders' logs | Standard |
| CommitSafety | Safety | Leader only commits entries from current term (with preceding current-term entry) | Family 1 |
| SnapshotLogContinuity | Safety | `logStartIndex == lastSnapshotIndex + 1` always holds after snapshot operations | Family 2 |
| ConfigSafety | Safety | At most one uncommitted config change at a time | Family 3 |
| JointQuorumAgreement | Safety | During TRANSITIONAL, both old and new majorities must agree for commit | Family 3 |
| NoDisruptiveElection | Liveness | A removed server with withholdVotesUntil active cannot win elections | Family 3 |
| StepDownCorrectness | Safety | Leader steps down iff it cannot reach quorum within timeout | Family 4 |
| PersistenceConsistency | Safety | After crash+recovery, `persistedTerm >= term(any persisted entry)` | Family 5 |
| VELivenessInv | Liveness | If leader is healthy and connected to quorum, commits eventually advance | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Crash between truncateSuffix and append in handleAppendEntries | LogMatching or LeaderCompleteness after recovery | 1 |
| MC-2 | Snapshot load replaces log prefix; subsequent election uses stale term info | ElectionSafety or LeaderCompleteness | 2 |
| MC-3 | Multi-chunk InstallSnapshot interrupted by term change; partial snapshot state | SnapshotLogContinuity | 2 |
| MC-4 | TRANSITIONAL config + election: can a server win with only old-set or only new-set quorum? | JointQuorumAgreement | 3 |
| MC-5 | Leader self-exclusion bumps term, cascading step-down in cluster | ElectionSafety, VELivenessInv | 3 |
| MC-6 | Removed server with stale config starts election despite withholdVotesUntil | NoDisruptiveElection | 3 |
| MC-7 | Epoch-based stepDown with slow disk: leader steps down despite reachable quorum | StepDownCorrectness | 4 |
| MC-8 | Leader entries in memory but not persisted; crash loses committed entries | LeaderCompleteness | 1, 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | stepDown busy-waits with mutex held; latency under slow disk | Timing test with injected disk delay |
| TV-2 | `leaderDiskThreadWorking` atomicity (std::atomic correctness) | ThreadSanitizer test |
| TV-3 | `rpcFailuresSinceLastWarning` non-atomic access | ThreadSanitizer test |
| TV-4 | No absolute timeout on staging server catch-up | Integration test with unreachable staging server |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Assertions on network-received values (lines 1316, 1418, 1465) crash server | Convert to guards with rejection responses |
| CR-2 | PANIC on EntryType::UNKNOWN from leader (line 1392-1399) | Reject entry instead of crashing |
| CR-3 | No snapshot data integrity check (no checksum) | Add checksum to InstallSnapshot protocol |
| CR-4 | Bogus term=0 in snapshot header (line 1785-1793) | Return NULL instead of writing bogus header |
| CR-5 | Session timeout hardcoded, not replicated via log (StateMachine.cc:58-63) | Make timeout a replicated config parameter |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/logcabin/analysis-report.md`
- **Key source files**:
  - `artifact/logcabin/Server/RaftConsensus.cc` (core state machine, 3,037 lines)
  - `artifact/logcabin/Server/RaftConsensus.h` (class definitions, 1,725 lines)
  - `artifact/logcabin/Server/RaftConsensusInvariants.cc` (invariant checking, 306 lines)
  - `artifact/logcabin/Storage/SegmentedLog.cc` (persistent log, 1,370 lines)
  - `artifact/logcabin/Server/StateMachine.cc` (state machine, 837 lines)
  - `artifact/logcabin/Protocol/Raft.proto` (RPC definitions, 339 lines)
- **GitHub issues**: #44, #160, #191 (Family 1/2); #56, #183, #205 (Family 3); #200, #202 (Family 4)
- **Reference**: Raft paper (Ongaro & Ousterhout, 2014), Raft dissertation (Ongaro 2014, Sections 4.2.3, 6.2)
