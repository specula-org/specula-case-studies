# Analysis Report: MongoDB MongoRaftReconfig

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Bug-fix commits analyzed (git history) | ~85 |
| Critical/High severity commits | ~45 |
| Directly reconfig-related commits | ~30 |
| Jira/GitHub issues collected | ~60 |
| Issues deeply read (full discussion) | ~35 |
| Confirmed bugs | ~50 |
| False positives excluded | ~5 (user error, Works as Designed) |
| Core source files fully analyzed | 6 |
| TLA+ specs read | 4 (MongoReplReconfig, RaftMongo, RaftMongoWithRaftReconfig, MCMongoReplReconfig) |

---

## Phase 1: Reconnaissance

### 1.1 Codebase Structure

**Core replication files** (~15,800 LOC):

| File | Lines | Role |
|------|-------|------|
| `replication_coordinator_impl.cpp` | 5,944 | Main reconfig implementation, state machine, election |
| `replication_coordinator_impl.h` | 2,130 | Interface, config state enum |
| `topology_coordinator.cpp` | 4,029 | Config installation, commit point, quorum checks |
| `topology_coordinator.h` | 1,423 | Interface |
| `repl_set_config.cpp` | 862 | Config data structure, majority calculation |
| `repl_set_config.h` | 644 | ConfigVersionAndTerm, member accessors |
| `repl_set_config_checks.cpp` | 618 | Validation for reconfig/initiate/heartbeat |
| `replication_coordinator_impl_heartbeat.cpp` | ~1,100 | Heartbeat response handling, config propagation |
| `check_quorum_for_config_change.cpp` | ~400 | Quorum verification for config changes |
| `member_config.h` | ~300 | Per-member config including newlyAdded behavior |

**Test files** (~4,280 LOC):
- `replication_coordinator_impl_reconfig_test.cpp` (2,742 lines)
- `repl_set_config_checks_test.cpp` (1,538 lines)

### 1.2 TLA+ Spec Landscape

| Spec | Lines | Purpose | Status |
|------|-------|---------|--------|
| `MongoReplReconfig.tla` | 492 | Logless safe reconfig protocol | Active, model-checked |
| `MCMongoReplReconfig.tla` | 19 | MC wrapper (3 servers, MaxTerm=3) | Active |
| `RaftMongo.tla` | 331 | Base Raft with commit point protocol | Active |
| `RaftMongoWithRaftReconfig.tla` | 263 | Log-based reconfig (exploratory) | NOT IMPLEMENTED |

**MongoReplReconfig.tla** variables:
- `currentTerm [Server -> Nat]`, `state [Server -> {Leader, Follower, Down}]`
- `log [Server -> Seq([term: Nat])]`
- `config [Server -> SUBSET Server]`, `configVersion [Server -> Nat]`, `configTerm [Server -> Nat]`
- `immediatelyCommitted` (global ghost variable)

**Actions modeled**: BecomeLeader, ClientRequest, GetEntry, RollbackEntries, CommitEntry, Reconfig, SendConfig, ShutDown, UpdateTermsOnNodes

**Invariants checked**: ElectionSafety (state invariant), NeverRollbackCommitted (temporal property)

### 1.3 Concurrency Model

The implementation uses a single `_mutex` (ReplicationCoordinator) to serialize most state mutations. Key concurrency boundaries:

1. **Replication executor thread pool**: Heartbeat callbacks, election callbacks, reconfig callbacks all run on executor threads. The mutex is acquired/released around state mutations.
2. **Heartbeat arrivals**: Asynchronous — can arrive during any phase of a reconfig or election.
3. **Config state machine**: Guards concurrency via `_rsConfigState` enum (`kConfigSteady` is the only state that allows new reconfigs). But the heartbeat reconfig path (`kConfigHBReconfiguring`) is a distinct state from user reconfig (`kConfigReconfiguring`).
4. **Lock release windows**: The mutex is explicitly released during quorum checks (`_doReplSetReconfig:3636`), disk I/O, and transaction yielding — creating interleaving opportunities.

### 1.4 Three Reconfig Paths (Critical Finding)

| Path | Entry Point | Safety Checks | When Used |
|------|-------------|--------------|-----------|
| **User reconfig** | `processReplSetReconfig` | All (unless force=true) | `replSetReconfig` command |
| **Step-up reconfig** | `doOptimizedReconfig` | None (`skipSafetyChecks=true`) | `signalDrainComplete` at line 1495 |
| **Heartbeat reconfig** | `_scheduleHeartbeatReconfig` | Partial (no old/new compat, no `updateLastCommittedInPrevConfig`) | Heartbeat response with newer config |

The step-up reconfig is described as "conceptually a no-op in the config consensus group" (line 1479) because it only bumps `configTerm` to the new primary's term without changing membership. However, it goes through `_doReplSetReconfig` with `skipSafetyChecks=true`, bypassing:
- Writable primary check
- Config-term invariant check
- Config majority commitment check
- Oplog commitment check
- Quorum pre-check

---

## Phase 2: Bug Archaeology

### 2.1 Git History Mining

Searched with keywords: `fix`, `bug`, `race`, `deadlock`, `reconfig`, `force`, `heartbeat`, `stepdown`, `correctness`, `config`, `drain` across all repl/ files.

#### Race Conditions (35 commits)

**Reconfig vs Election (6 bugs)**:
- `327a6bd879` SERVER-37255: Reconfig + election invariant crash
- `e8c93d327` SERVER-48257: Heartbeat reconfig during candidate role
- `5a754fb109` SERVER-16455: Election started during HB reconfig
- `565f818c12` SERVER-59409: Config replication + stepup race → stuck cluster
- `4fe9db02bb` SERVER-47636: Force reconfig + step-up concurrent
- `774349f0c3` SERVER-106552: Auto-reconfig (newlyAdded) + stepdown invariant

**Heartbeat Reconfig Serialization (5 bugs)**:
- `8510332444` SERVER-91374: Data race getTerm/updateTerm in _doReplSetReconfig
- `439014433b` SERVER-81480: Data race in _handleHeartbeatResponse (stale lambda capture)
- `2d60b58f16` SERVER-63512: Missing lock in optimized heartbeat reconfig
- `3a6620898c` SERVER-16748: New HB reconfig before state cleared
- `3604c4f47c` SERVER-15756: Interleaving during HB reconfig processing

**Stepdown Races (7 bugs)**:
- `45188cb0db` SERVER-62379: Deadlock between ReplicationCoordinator and BackgroundSync on stepUp
- `4fbb1f65e2` SERVER-50869: bgsync appliedThrough race during stepUp
- `76c01d4b42` SERVER-76581: Stale topologyVersion on heartbeat-triggered stepdown
- `32bd1c0375` SERVER-35951: Unfreeze + election timeout race
- `08310c00be` SERVER-31572: Transition to primary while stepping down
- `f496011618` SERVER-28290: Heartbeat higher-term stepdown discards term
- `6168a6e7f5` SERVER-33383: Internal stepdown + heartbeat stepdown race

**Init/Config Races (4 bugs)**:
- `e238f6aabb` SERVER-87116: replSetInitiate + election race with scope guard
- `e5644e2ca1` SERVER-16257: replSetInitiate + initial sync race
- `acd6c3d067` SERVER-48178: isSelf check interrupted by rollback connection close
- `0935692361` SERVER-62951: Global lock livelock during startup

#### Logic Errors / Missing Checks (25 commits)

**Reconfig Safety (12 bugs)**:
- `2de5fe71f8` SERVER-117353: **CRITICAL** — `$configMajority` halved (`majorityVoteCount/2+1` instead of `majorityVoteCount`)
- `9c1d33e0d3` SERVER-47948: Quorum check compared version only, not version+term
- `b526127542` SERVER-55376: PSA sets could roll back committed writes via reconfig
- `043b3a8393` SERVER-45079: Multi-voter-node change allowed in safe reconfig
- `98086ef843` SERVER-45087: Oplog commitment check outside critical section (TOCTOU)
- `d68c538f0d` SERVER-45085: No config replication check before reconfig
- `89ec7322a5` SERVER-46894: Reconfig before current config committed
- `80195b6a5c` SERVER-45086: lastCommittedInPrevConfig not recorded atomically
- `ffec1baf86` SERVER-45093: Config writes not flushed to disk
- `a397fc4424` SERVER-47205: Unnecessary snapshot drops on reconfig
- `a712924ae7` SERVER-15833: Force reconfig bypassed all compatibility checks
- `4c1debdd95` SERVER-117499: Force reconfig priority port validation by index not ID

**Drain Mode Logic (5 bugs)**:
- `2546fe1c22` SERVER-47949: Config installed via heartbeat during drain mode
- `31a60aab7a` SERVER-47142: User reconfig allowed during drain mode
- `0db56f8e29` SERVER-36746: Drain mode skipped after failed stepdown
- `17917954b9` SERVER-15779: Drain flag not cleared on stepdown
- `d1153c137c` SERVER-31330: Stepdown during drain triggers invariant

**Term/Vote (2 bugs)**:
- `f496011618` SERVER-28290: Heartbeat stepdown discards pending term
- `5c07a707ef` SERVER-20262: `_stepDownPending` cleared too late

**Other (4 bugs)**:
- `7ebcd89a4f` SERVER-54374: Commit point advanced during rollback via heartbeat
- `4a24ad4171` SERVER-48450: Non-voting nodes from other RS accepted
- `c3019ad939` SERVER-10945: Double member entries after reconfig
- `4c1debdd95` SERVER-117499: Force reconfig checks by index not member ID

#### Deadlocks (12 commits)
- `45188cb0db` SERVER-62379: ReplicationCoordinator + BackgroundSync
- `da9927d08b` SERVER-15750: Global lock + bgsync mutex
- `53698194b2` SERVER-15535: Drain mode + logOp + collection lock
- `c9f371c119` SERVER-19782: Shutdown during transition to primary
- `5d870c10dc` SERVER-14442: Repl deadlock at shutdown
- `81681d4e12` SERVER-15535: Cancel deadlock in ReplicationExecutor
- `41465b6d3e` SERVER-14058: ReplicationExecutor shutdown deadlock
- `038b606d16` SERVER-14449: processReplSetSyncFrom deadlock
- `7361e94af3` SERVER-28181: OplogFetcher constructor deadlock
- `5f0c1cba3d` SERVER-61377: Initial sync shutdown + config race
- `f118314d40` SERVER-61334: Batcher + storage change deadlock
- `0935692361` SERVER-62951: Startup livelock

### 2.2 Jira/GitHub Issue Analysis

#### Critical Safety Issues

| Ticket | Title | Status | Key Finding |
|--------|-------|--------|-------------|
| SERVER-47852 | Two primaries satisfy `w:majority` after partition+reconfig | **Works as Designed** | Fundamental protocol limitation |
| SERVER-54746 | Two primaries via member ID reuse | **Works as Designed** | Config comparison allows it |
| SERVER-55376 | PSA rollback of committed writes | Fixed (4.4.11) | Requires two-step reconfig procedure |
| SERVER-117353 | $configMajority halved | Fixed (2026) | Invisible for 3-node RS, dangerous for 4+ |
| SERVER-78115 | Split brain in sharded cluster after majority write removed | **Open/Active** | Active investigation |

#### Reconfig + State Transition Races

| Ticket | Title | Status | Key Finding |
|--------|-------|--------|-------------|
| SERVER-59409 | Reconfig replication + stepup → stuck cluster | Fixed | ConfigVersion/Term ordering mismatch |
| SERVER-37255 | Reconfig + election → invariant crash | Fixed | TOCTOU in PostMemberStateUpdateAction |
| SERVER-47636 | Force reconfig + step-up concurrent | Fixed | configVersionAndTerm check added |
| SERVER-106552 | Auto-reconfig + stepdown invariant | Fixed | Pending term update during newlyAdded removal |

#### Heartbeat Config Issues

| Ticket | Title | Status | Key Finding |
|--------|-------|--------|-------------|
| SERVER-46897 | REMOVED node never re-learns config | Fixed | Stops heartbeating, can't fetch new config |
| SERVER-47613 | Heartbeat reconfig → `_selfIndex=-1` → vote crash | Fixed | processReplSetRequestVotes invariant |
| SERVER-47949 | Primary installs higher config via heartbeat in drain | Fixed | Inconsistent config term |

#### Config Version Issues

| Ticket | Title | Status | Key Finding |
|--------|-------|--------|-------------|
| SERVER-64955 | High config version from force reconfig | Backlog | 100K+ increments per force reconfig |
| SERVER-55278 | Config version overflow to 2.1B+ | Works as Designed | int32 overflow from repeated force reconfigs |
| SERVER-106614 | Missing replSetConfigVersion → mongos can't connect | **Blocker P1** (Fixed) | Pre-8.0 shard entries missing field |

### 2.3 Bug Hotspot Analysis

Files ranked by bug-fix commit frequency:

| File | Bug-Fix Commits | Primary Categories |
|------|----------------|-------------------|
| `replication_coordinator_impl.cpp` | ~40 | Races, logic errors, deadlocks |
| `topology_coordinator.cpp` | ~15 | Config installation, election, heartbeat |
| `replication_coordinator_impl_heartbeat.cpp` | ~12 | HB reconfig, data races, config propagation |
| `repl_set_config_checks.cpp` | ~8 | Validation gaps, PSA safety |
| `repl_set_config.cpp` | ~5 | Majority calculation, config comparison |

---

## Phase 3: Deep Analysis

### 3.1 ConfigIsSafe: Spec vs Implementation Mapping

| TLA+ Precondition | Implementation | Fidelity |
|-------------------|----------------|----------|
| **ConfigQuorumCheck**: quorum shares same (configVersion, configTerm) | `$configMajority` write concern with `makeConfigPredicate` (topology_coordinator.cpp:1425) | High |
| **TermQuorumCheck**: quorum has term <= primary's term | Indirect: election proves quorum was in term, step-up bumps configTerm | High (indirect) |
| **OpCommittedInConfig**: committed entries remain committed | `max(_lastCommittedInPrevConfig, _firstOpTimeOfMyTerm)` replicated to `$majority` (replication_coordinator_impl.cpp:3602-3623) | High |
| **Single-node change**: `|old \ new| + |new \ old| <= 1` | `validateSingleNodeChange` (repl_set_config_checks.cpp:574) | High |
| **Quorum overlap**: old and new configs overlap | Structural (single-node change implies overlap) | High |

### 3.2 Force Reconfig: What Is Bypassed

| Check | Code Location | Bypassed? |
|-------|--------------|-----------|
| Writable primary | `replication_coordinator_impl.cpp:3563` | YES |
| Config term invariant | `:3579` | YES |
| Config majority committed | `:3593` | YES |
| Oplog commitment in config | `:3613` | YES |
| Single-node change | `repl_set_config_checks.cpp:573` | YES |
| Quorum pre-check | `replication_coordinator_impl.cpp:3830` | YES |
| Electability in new config | `:3784` | YES |
| newlyAdded field setting | `:3481` | YES |
| Config version monotonicity | `:3453-3460` (random bump) | WEAKENED |

### 3.3 Heartbeat Reconfig: What Is Different

| Check | User Reconfig | Heartbeat Reconfig | Impact |
|-------|--------------|-------------------|--------|
| Old/new compatibility | `validateOldAndNewConfigsCompatible` | Skipped | Trusts primary validated it |
| Single-node change | `validateSingleNodeChange` | Skipped | Same |
| `updateLastCommittedInPrevConfig` | Called (`:4003`) | NOT called (`:1052`) | Secondary may become primary with stale commit point |
| Candidate role check | N/A (must be primary) | Rejected if kCandidate (`:718`) | Correct |
| Drain mode check | Rejected (`:3563`) | Allowed for force configs (term=-1) at `:707-716` | Force configs via HB allowed in drain |

### 3.4 ConfigVersionAndTerm Comparison Semantics

From `repl_set_config.h:82-99`:
- `operator==`: If EITHER term is -1, compare versions only
- `operator<`: If EITHER term is -1, compare versions only
- Force reconfigs set `configTerm = -1` (kUninitializedTerm)
- Force reconfig bumps version by `10,000 + random(0,100000)`

**Implication**: A force reconfig with a sufficiently high version number overrides ANY safe reconfig regardless of term. Two partitioned nodes doing independent force reconfigs can produce configs with the same high version (due to randomness) or divergent ordering.

### 3.5 newlyAdded Mechanism (Not in TLA+ Spec)

**Behavior**: `member_config.h:177-186` — `isVoter()` returns false for newlyAdded nodes, causing them to be excluded from all quorum calculations. `getPriority()` returns 0.0, preventing them from becoming primary.

**Two-phase addition**:
1. User reconfig adds node → `newlyAdded=true` set automatically
2. Heartbeat shows node reached SECONDARY → auto-reconfig removes `newlyAdded`

**Safety gap with force reconfig**: Force reconfig skips `newlyAdded` setting (`replication_coordinator_impl.cpp:3481`). A force-added voter immediately counts toward quorum without completing initial sync, potentially allowing it to participate in elections before it has the full oplog.

### 3.6 Topology Coordinator Findings

**Config installation** (`topology_coordinator.cpp:2611-2651`):
- Invariant: `_role != Role::kCandidate` (line 2612) — cannot install config during election
- Leader stays leader if still electable (line 2644) — does NOT go through normal stepdown
- Leader demoted to follower (line 2646) without setting `_stepDownUntil` — can immediately re-elect

**Commit point advancement** (`topology_coordinator.cpp:3131-3172`):
- Only primary advances commit point
- Refused during `kSteppingDown` but allowed during `kAttemptingStepDown`
- Uses `_writeMajority` (excludes arbiters) not `_majorityVoteCount` (includes arbiters)

**`getConfigOplogCommitmentOpTime`** (`topology_coordinator.cpp:1705-1710`):
- Returns `max(_lastCommittedInPrevConfig, _firstOpTimeOfMyTerm)`
- During `kLeaderElect` (before drain complete), `_firstOpTimeOfMyTerm` is `{INT_MAX, INT_MAX}`, blocking all reconfigs

**Arbiter in quorum** (`topology_coordinator.cpp:1425-1431`):
- `$configMajority` includes arbiters (they report configVersion/configTerm via heartbeats)
- `$majority` excludes arbiters (they have no oplog data)
- This asymmetry is intentional but not modeled in TLA+ spec

### 3.7 Developer Signals (TODO/FIXME/HACK)

| Location | Comment | Relevance |
|----------|---------|-----------|
| `repl_set_config_checks.cpp:320` | `TODO (SERVER-112863) Remove these checks` | Priority port feature flag cleanup |
| `replication_coordinator_impl_heartbeat.cpp:368` | `TODO(sz) term duplicated in ReplSetMetaData` | Minor cleanup |
| `repl_set_config.h:143` | `TODO(SERVER-47937) const_cast` | IDL limitation |
| `topology_coordinator.cpp:2849,2855` | `TODO(SERVER-30852) remove this case` | Leader→NotLeader transition via updateConfig |
| `repl_set_config_checks.cpp:264` | `enableReconfigRollbackCommittedWritesCheck` can be disabled | Test-only parameter; production exposure would be dangerous |

### 3.8 Duplicate RSTL Acquisition (Potential Bug)

At `replication_coordinator_impl.cpp:3941,3946`, the RSTL is acquired twice in succession:
```cpp
arsd.emplace(this, opCtx, ...kStepDown);  // line 3941
// timing log
arsd.emplace(this, opCtx, ...kStepDown);  // line 3946
```

The second `emplace` destroys the first `AutoGetRstlForStepUpStepDown` (releasing the RSTL), then re-acquires it. This creates a brief window where the RSTL is not held during a force reconfig step-down. The heartbeat reconfig path (`replication_coordinator_impl_heartbeat.cpp:966`) only acquires once.

---

## Phase 4: Bug Family Synthesis

### Family 1: Force Reconfig Safety Bypass
- **Bug count**: 4 historical + 2 "Works as Designed" acknowledgments + 3 code analysis findings
- **Severity**: Critical (two-primary scenarios confirmed by MongoDB team)
- **TLA+ suitability**: HIGH — the existing spec's safety proof explicitly does not cover this path

### Family 2: Reconfig vs Election/Stepdown/Drain Races
- **Bug count**: 7 historical + 2 code analysis findings
- **Severity**: High (production crashes, stuck clusters)
- **TLA+ suitability**: HIGH — the spec's atomic election model misses all multi-step interactions

### Family 3: Heartbeat Config Propagation Asymmetry
- **Bug count**: 6 historical across 3 generations + 3 code analysis findings
- **Severity**: High (invariant crashes, stale state)
- **TLA+ suitability**: HIGH — spec has one config propagation action, code has two with different semantics

### Family 4: Config Quorum Calculation Errors
- **Bug count**: 3 historical (1 critical) + 1 code analysis finding
- **Severity**: Critical (SERVER-117353 undermined entire config safety)
- **TLA+ suitability**: MEDIUM — mainly caught by code review, but arbiter quorum modeling could reveal structural issues

### Family 5: newlyAdded Two-Phase Voter Addition
- **Bug count**: 6 historical + 2 code analysis findings
- **Severity**: Medium (correct by design, bugs in implementation details)
- **TLA+ suitability**: MEDIUM — models async state machine not captured by existing spec

### Family 6: Non-Atomic Config Installation
- **Bug count**: 4 historical + 2 code analysis findings
- **Severity**: Medium (crash recovery is correct, but concurrent operation windows exist)
- **TLA+ suitability**: LOW — mainly about lock ordering and crash recovery, which the shared-state spec abstracts away
