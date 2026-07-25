# Modeling Brief: MongoDB MongoRaftReconfig — Logless Dynamic Reconfiguration

## 1. System Overview

- **System**: MongoDB replica set reconfiguration (`mongodb/mongo`)
- **Language**: C++, ~15,800 LOC core logic across 4 files
- **Protocol**: MongoRaftReconfig — logless dynamic reconfiguration with TLAPS-proven safety
- **Key architectural choices**:
  - **Three distinct reconfig paths**: user reconfig (`processReplSetReconfig`), step-up optimized reconfig (`doOptimizedReconfig`, skips safety checks), heartbeat reconfig (`_scheduleHeartbeatReconfig`, skips old/new compatibility validation)
  - **Force reconfig** uses `configTerm = -1` to bypass all safety invariants; `ConfigVersionAndTerm` comparison ignores terms when either is -1 (`repl_set_config.h:82-99`)
  - **`newlyAdded` field**: two-phase voter addition — new members added as non-voting (`newlyAdded=true`), auto-promoted via heartbeat-triggered async reconfig. Not modeled in any TLA+ spec.
  - Config persisted to disk BEFORE installed in memory (`replication_coordinator_impl.cpp:3859` vs `:3997`)
  - `$configMajority` counts arbiters as voters for config commitment; `$majority` excludes arbiters for oplog commitment
- **Concurrency model**: Single `_mutex` protects replication state; replication executor runs callbacks on thread pool; heartbeats arrive asynchronously; elections run on separate executor events
- **Existing TLA+ spec**: `MongoReplReconfig.tla` (492 lines) — proves ElectionSafety and NeverRollbackCommitted via ConfigIsSafe precondition. Uses shared-state abstraction (no messages). Does NOT model: force reconfig, heartbeat propagation, newlyAdded, arbiters, crash recovery, drain mode, or concurrent operations.

## 2. Bug Families

### Family 1: Force Reconfig Safety Bypass (HIGH)

**Mechanism**: Force reconfig (`rs.reconfig({...}, {force: true})`) bypasses ALL three ConfigIsSafe preconditions — config quorum check, term quorum check, and oplog commitment — plus the single-node-change restriction. Combined with `configTerm=-1` and random version bumps, this creates configs that can violate quorum overlap.

**Evidence**:
- Historical: SERVER-47852, SERVER-54746 — two primaries satisfying `w:majority` after partition+reconfig, both closed as "Works as Designed"
- Historical: SERVER-55376 — reconfig can roll back committed writes in PSA sets
- Historical: SERVER-15833 (commit `a712924ae7`) — force reconfig bypassed all compatibility checks
- Code analysis: `replication_coordinator_impl.cpp:3563-3624` — three `if (!force && !skipSafetyChecks)` guards skip primary check, config-term invariant, config commitment, and oplog commitment
- Code analysis: `repl_set_config_checks.cpp:573-578` — single-node-change validation skipped for force
- Code analysis: `replication_coordinator_impl.cpp:3453-3460` — version bumped by `10,000 + random(0,100000)`, non-monotonic under concurrent force reconfigs
- Code analysis: `repl_set_config.h:82-99` — `ConfigVersionAndTerm` comparison ignores terms when either is -1, allowing force configs to override safe configs

**Affected code paths**:
- `processReplSetReconfig()` with `args.force=true`
- `_doReplSetReconfig()` force guard at lines 3563, 3579, 3593, 3613, 3830
- `_finishReplSetReconfig()` force step-down path at line 3923

**Suggested modeling approach**:
- Variables: `isForceConfig [Server -> BOOLEAN]` tracking which servers have force-installed configs
- Actions: `ForceReconfig(i, newConfig)` — no ConfigIsSafe precondition, sets `configTerm'=-1`, allows multi-node changes
- Config comparison: model the term=-1 semantics where version alone determines ordering
- Key invariant to check: can two force reconfigs on partitioned nodes produce overlapping-quorum-violating configs?

**Priority**: High
**Rationale**: SERVER-47852 and SERVER-54746 confirm two-primary scenarios ARE possible. The existing TLA+ spec cannot find these because it doesn't model force reconfig. This is the highest-value modeling target because the TLAPS proof explicitly does not cover this path.

---

### Family 2: Reconfig vs Election/Stepdown/Drain Races (HIGH)

**Mechanism**: Concurrent reconfig and state transitions (election, stepdown, drain mode) create TOCTOU windows where safety invariants assumed by one operation are violated by the other.

**Evidence**:
- Historical: SERVER-37255 (commit `327a6bd879`) — reconfig + concurrent election triggers invariant crash
- Historical: SERVER-47636 (commit `4fe9db02bb`) — force reconfig + step-up race, fix: check configVersionAndTerm hasn't changed
- Historical: SERVER-48257 (commit `e8c93d327`) — heartbeat reconfig during candidate role; fix: reject HB reconfig if kCandidate
- Historical: SERVER-59409 (commit `565f818c12`) — config replication + stepup race leaves cluster stuck
- Historical: SERVER-106552 (commit `774349f0c3`) — auto-reconfig (newlyAdded removal) + stepdown race triggers invariant
- Historical: SERVER-47949 (commit `2546fe1c22`) — heartbeat config install during drain mode corrupts step-up
- Historical: SERVER-47142 (commit `31a60aab7a`) — user reconfig during drain mode
- Code analysis: `replication_coordinator_impl.cpp:3903-3918` — election cancelled after `_finishReplSetReconfig` entry, brief window where both are in-progress

**Affected code paths**:
- `_doReplSetReconfig()` primary check at line 3563
- `_finishReplSetReconfig()` election cancellation at line 3903
- `doOptimizedReconfig()` during `signalDrainComplete()` at line 1495
- `_handleHeartbeatResponse()` reconfig scheduling at line 718

**Suggested modeling approach**:
- Variables: `drainMode [Server -> BOOLEAN]`, `electionInProgress [Server -> BOOLEAN]`
- Actions: Model step-up as multi-step: `WinElection` → `DrainMode` → `CompleteDrain` (with config term bump)
- Interleave `Reconfig` and `ForceReconfig` between drain mode steps
- Key: the step-up config term bump (`doOptimizedReconfig`) skips safety checks — what if a user reconfig arrives during the drain window?

**Priority**: High
**Rationale**: 7+ confirmed production bugs sharing this mechanism. The existing spec makes elections atomic (single `BecomeLeader` action), missing all multi-step interactions. Each new fix has introduced a new race variant, suggesting the design space is not fully explored.

---

### Family 3: Heartbeat Config Propagation Asymmetry (HIGH)

**Mechanism**: Heartbeat-based config propagation follows a different code path than user reconfig, with fewer safety checks and different atomicity guarantees. Configs received via heartbeat skip old/new compatibility validation and don't record the previous config's commit point.

**Evidence**:
- Historical: SERVER-46897 (commit) — REMOVED node stops heartbeating, can never learn it's re-added
- Historical: SERVER-47613 (commit) — heartbeat reconfig sets `_selfIndex=-1`, subsequent vote request crashes
- Historical: SERVER-63512 (commit `2d60b58f16`) — `_selfIndex` and `_rsConfig` accessed without lock during heartbeat reconfig
- Historical: SERVER-15756, SERVER-16748 — three generations of heartbeat reconfig serialization bugs
- Code analysis: `repl_set_config_checks.cpp:588-614` — `validateConfigForHeartbeatReconfig` does NOT call `validateOldAndNewConfigsCompatible` or `validateSingleNodeChange`
- Code analysis: `replication_coordinator_impl_heartbeat.cpp:1052-1055` — heartbeat reconfig does NOT call `updateLastCommittedInPrevConfig()` (contrast with `replication_coordinator_impl.cpp:4003`)
- Code analysis: `replication_coordinator_impl_heartbeat.cpp:707-716` — force reconfigs (term=-1) allowed during drain mode via heartbeat

**Affected code paths**:
- `_scheduleHeartbeatReconfig()` at line 700
- `_heartbeatReconfigStore()` at line 760
- `_heartbeatReconfigFinish()` at line 949
- `validateConfigForHeartbeatReconfig()` in `repl_set_config_checks.cpp:588`

**Suggested modeling approach**:
- Variables: split config propagation into `ReceiveConfigViaHeartbeat` (weaker checks) vs `SendConfig` (TLA+ spec's current model)
- Model the missing `updateLastCommittedInPrevConfig` — can a secondary receive a config via heartbeat, then become primary, and have a stale `_lastCommittedInPrevConfig`?
- Model REMOVED node liveness: node removed from config, stops heartbeating, can it re-learn it's been re-added?

**Priority**: High
**Rationale**: 6+ bugs across 3 generations. The TLA+ spec's `SendConfig` action is a single atomic operation that doesn't distinguish heartbeat vs. user reconfig. The implementation has fundamentally different validation and state-update paths for each.

---

### Family 4: Config Quorum Calculation Errors (MEDIUM)

**Mechanism**: Incorrect computation of the quorum thresholds used for config commitment and oplog commitment checks during reconfig. The `$configMajority` and `$majority` write concerns use different quorum definitions that diverge from the TLA+ spec's uniform `Quorums(config[i])`.

**Evidence**:
- Historical: SERVER-117353 (commit `2de5fe71f8`) — CRITICAL: `$configMajority` calculated as `_majorityVoteCount / 2 + 1` instead of `_majorityVoteCount`, effectively requiring only ~1/4 of voters for 4+ node clusters
- Historical: SERVER-47948 (commit `9c1d33e0d3`) — quorum check compared config version only, not version AND term
- Historical: SERVER-13070 — arbiters in majority calculation broke balancing
- Code analysis: `$configMajority` counts arbiters (`kConfigVoterTagName`); `$majority` excludes arbiters (`kVoterTagName` with `_writeMajority`). The TLA+ spec uses one `Quorums(config[i])` for both.

**Affected code paths**:
- `repl_set_config.cpp:683-688` — `$configMajority` pattern definition
- `repl_set_config.cpp:637-648` — `_majorityVoteCount` and `_writeMajority` computation
- `topology_coordinator.cpp:1425-1428` — `makeConfigPredicate` for config version/term check

**Suggested modeling approach**:
- Model arbiters explicitly: nodes that can vote and acknowledge configs but do NOT hold data
- Define separate quorum functions: `ConfigQuorum` (all voters including arbiters) vs `DataQuorum` (voters minus arbiters)
- Check: can a config be "committed" (ConfigQuorum satisfied) while not enough data-bearing nodes have it for oplog safety?

**Priority**: Medium
**Rationale**: SERVER-117353 was a critical correctness bug (fixed). The arbiter quorum asymmetry is by-design but creates a gap vs. the TLA+ spec. Worth modeling to verify the arbiter handling is safe.

---

### Family 5: newlyAdded Two-Phase Voter Addition (MEDIUM)

**Mechanism**: New voting members are added with `newlyAdded=true` (non-voting), then auto-promoted to voting via asynchronous heartbeat-triggered reconfig. This breaks the Raft single-voter-change invariant by design (multiple newlyAdded nodes can be added simultaneously). The auto-reconfig is retry-based and can race with user reconfigs.

**Evidence**:
- Historical: SERVER-46351 (commit `b2623b7138`) — user reconfigs didn't preserve `newlyAdded` fields
- Historical: SERVER-47717 — single-voter-change check not accounting for newlyAdded
- Historical: SERVER-47128 — race between newlyAdded removal and step-up reconfig
- Historical: SERVER-47495 — force reconfig could carry forward stale newlyAdded fields
- Code analysis: `member_config.h:177-186` — `isVoter()` returns false for newlyAdded, affecting all quorum calculations
- Code analysis: `replication_coordinator_impl.cpp:3480-3483` — force reconfig skips newlyAdded, adding voters immediately
- Code analysis: `replication_coordinator_impl_heartbeat.cpp:409-443` — heartbeat triggers auto-reconfig
- Not modeled in any existing TLA+ spec

**Affected code paths**:
- `processReplSetReconfig()` newlyAdded field setting at line 3464
- `_reconfigToRemoveNewlyAddedField()` at line 4110
- `_handleHeartbeatResponse()` trigger at line 409

**Suggested modeling approach**:
- Variables: `newlyAdded [Server -> BOOLEAN]`, `effectiveVoters(config) = {s \in config : ~newlyAdded[s]}`
- Actions: `AddNodeWithNewlyAdded(i, j)` (add to config, mark non-voting), `RemoveNewlyAdded(i, j)` (auto-reconfig, one at a time)
- Key: force reconfig skips newlyAdded — a force-added voter immediately counts toward quorum without completing initial sync

**Priority**: Medium
**Rationale**: Not modeled in any existing spec. The interaction between newlyAdded and force reconfig is a potential safety gap. Multiple historical bugs in this area.

---

### Family 6: Non-Atomic Config Installation and Crash Recovery (LOW)

**Mechanism**: Config is written to disk before being installed in memory, with operations between the two steps. Crash between disk write and memory install is safe (disk config loaded on restart), but concurrent operations during this window see old in-memory config while new config is durable.

**Evidence**:
- Historical: SERVER-45093 (commit `ffec1baf86`) — config writes weren't flushed to disk before
- Historical: SERVER-45086 (commit `80195b6a5c`) — `lastCommittedInPrevConfig` not recorded atomically
- Code analysis: `replication_coordinator_impl.cpp:3859` (disk write) vs `:3997` (memory install) — mutex released between steps at `:3634`
- Code analysis: `replication_coordinator_impl.cpp:3941,3946` — duplicate `arsd.emplace` creates brief RSTL release window during force reconfig step-down

**Priority**: Low
**Rationale**: The mutex serializes most concurrent access. Crash recovery is well-designed (disk always has the authoritative config). The main risk is the RSTL release window during force reconfig step-down.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Force reconfig | Family 1: bypasses all safety invariants, confirmed two-primary scenarios (SERVER-47852, SERVER-54746) | `ForceReconfig` action with no ConfigIsSafe precondition, `configTerm=-1`, multi-node changes allowed |
| ConfigVersionAndTerm with term=-1 | Family 1: the mechanism enabling force reconfig override | Config comparison operator that ignores term when either is -1 |
| Multi-step election (drain mode) | Family 2: 7+ races between reconfig and election steps | Split `BecomeLeader` into `WinElection` → `DrainMode` → `CompleteDrain` (with config term bump) |
| Heartbeat config propagation | Family 3: different validation path, missing commit point recording | `ReceiveConfigViaHeartbeat` action with weaker preconditions than `Reconfig` |
| Arbiter quorum semantics | Family 4: different quorum for config vs data commitment | Arbiter node type: votes + acknowledges config, but no data. Two quorum functions. |
| newlyAdded field | Family 5: two-phase voter addition, not in existing spec | `newlyAdded` variable, effective voters exclude newlyAdded nodes |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Snapshots / initial sync | Not related to any high-priority bug family. Would dramatically expand spec scope. |
| Network message ordering / loss | The existing spec uses shared-state abstraction; adding messages would be a complete rewrite for modest additional coverage |
| Read/write concern semantics | Application-layer concern, not protocol safety |
| RSTL / global lock ordering | Implementation-level deadlock concern, not protocol logic |
| `replSetInitiate` | Different code path from reconfig; initiate-specific bugs are one-time startup issues |
| Stepdown timeout / catchup period | Timing-based mechanisms better tested with integration tests |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Force reconfig | `isForceConfig` | Model safety bypass, configTerm=-1, multi-node changes | Family 1 |
| ConfigVersionAndTerm comparison | (in operators) | Model term=-1 ignoring semantics | Family 1 |
| Multi-step election | `drainMode`, `electionInProgress` | Model reconfig during drain window | Family 2 |
| Heartbeat config path | (split action) | Model weaker validation on heartbeat configs | Family 3 |
| Arbiter type | `isArbiter` | Model quorum asymmetry for config vs data | Family 4 |
| newlyAdded mechanism | `newlyAdded` | Model two-phase voter addition | Family 5 |
| REMOVED node state | `Down` already in spec | Model node removal and re-addition liveness | Family 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard, Family 2 |
| NeverRollbackCommitted | Safety | Committed entries never rolled back | Standard, Family 1, 4 |
| ForceReconfigQuorumOverlap | Safety | After force reconfig, can two disjoint quorums exist? | Family 1 |
| NoTwoActiveForcedConfigs | Safety | Two partitioned force reconfigs cannot both elect leaders | Family 1 |
| ConfigPropagationSafety | Safety | Heartbeat-propagated config does not violate commit point preservation | Family 3 |
| NewlyAddedSafety | Safety | A newlyAdded node never counts toward data quorum | Family 5 |
| DrainModeReconfigSafety | Safety | Reconfig during drain mode does not produce two primaries | Family 2 |
| ArbiterQuorumOverlap | Safety | Config quorum (with arbiters) overlaps with data quorum (without arbiters) | Family 4 |
| PSAWriteSafety | Safety | In PSA set, reconfig cannot roll back `w:majority` writes | Family 1, 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| F1-A | Two concurrent force reconfigs on partitioned nodes produce non-overlapping quorums | ForceReconfigQuorumOverlap | 1 |
| F1-B | Force reconfig with configTerm=-1 overrides safe config, allowing stale leader | ElectionSafety | 1 |
| F1-C | PSA reconfig: change non-voter to voter, elect with arbiter, roll back committed writes | PSAWriteSafety, NeverRollbackCommitted | 1, 4 |
| F2-A | User reconfig during drain mode (before config term bump) produces two primaries | DrainModeReconfigSafety | 2 |
| F2-B | Force reconfig during step-up: both old and new primary think they are primary | ElectionSafety | 2 |
| F3-A | Secondary receives config via heartbeat, becomes primary — stale lastCommittedInPrevConfig | ConfigPropagationSafety | 3 |
| F4-A | Arbiter-heavy config: config committed (with arbiters) but data not replicated to data majority | ArbiterQuorumOverlap | 4 |
| F5-A | Force reconfig adds voter (skips newlyAdded), voter counts toward quorum before sync | NewlyAddedSafety | 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T1 | Duplicate `arsd.emplace` RSTL release window (`replication_coordinator_impl.cpp:3941,3946`) | Race test with concurrent operations during force reconfig step-down |
| T2 | Heartbeat reconfig during kCandidate role (SERVER-48257 regression) | Integration test: trigger election + send heartbeat with newer config |
| T3 | REMOVED node heartbeat cessation (SERVER-46897 regression) | Test: remove node, re-add, verify it eventually learns new config |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| C1 | Heartbeat reconfig path missing `updateLastCommittedInPrevConfig` (`replication_coordinator_impl_heartbeat.cpp:1052`) | Review whether secondaries need this; compare with primary reconfig path |
| C2 | `doOptimizedReconfig` (`skipSafetyChecks=true`) during step-up — verify this is always safe | Review: what if concurrent force reconfig changes membership during drain? |
| C3 | `_firstOpTimeOfMyTerm` sentinel `{INT_MAX, INT_MAX}` blocks oplog commitment check during kLeaderElect | Review: is reconfig possible during kLeaderElect? Config state should block it. |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/mongodb-raftreconfig/analysis-report.md`
- **Existing TLA+ spec**: `artifact/mongo-src/src/mongo/tla_plus/Replication/MongoReplReconfig/MongoReplReconfig.tla`
- **Companion specs**: `RaftMongo.tla` (base Raft, commit point protocol), `RaftMongoWithRaftReconfig.tla` (exploratory log-based reconfig, NOT implemented)
- **Key source files**:
  - `artifact/mongo-src/src/mongo/db/repl/replication_coordinator_impl.cpp` (5944 lines) — main reconfig at lines 3400-4200
  - `artifact/mongo-src/src/mongo/db/repl/topology_coordinator.cpp` (4029 lines) — config installation, quorum, commit point
  - `artifact/mongo-src/src/mongo/db/repl/repl_set_config_checks.cpp` (618 lines) — validation
  - `artifact/mongo-src/src/mongo/db/repl/repl_set_config.h` (644 lines) — ConfigVersionAndTerm comparison
  - `artifact/mongo-src/src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp` — heartbeat reconfig
- **Key Jira tickets**: SERVER-47852, SERVER-54746 (two-primary by design), SERVER-55376 (PSA rollback), SERVER-117353 ($configMajority miscalculation), SERVER-59409 (reconfig+stepup race), SERVER-37255 (reconfig+election crash)
- **Shared harness**: `case-studies/mongodb-shared-harness.md` — Docker compose template for 3-node RS, log parsing approach
