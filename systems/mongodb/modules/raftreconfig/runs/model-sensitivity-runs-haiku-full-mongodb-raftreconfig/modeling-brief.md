# Modeling Brief: MongoDB Replica Set Reconfiguration

## 1. System Overview

**System**: MongoDB replica-set reconfiguration (Raft-based)  
**Language**: C++ (~6000 lines in replication_coordinator_impl.cpp)  
**Category**: **Category A (Distributed / Message-Passing)**  
**Justification**: Distributed consensus protocol with RPC messages, replica set membership changes, and persistent configuration state. The core mechanism is a quorum-based configuration protocol where membership changes require coordination across multiple nodes.

**Key Algorithm**: MongoDB uses Raft-style consensus for replica set membership management. Configuration changes follow a multi-step process: quorum checking, validation, persistence, and installation. The system uses both configuration version and term fields to track config precedence.

**Architectural Deviations from Standard Raft**:
- Separate `configTerm` and `configVersion` fields for tracking config precedence
- Force reconfig mechanism sets `configTerm = -1` to override other configs
- Commitment tracking distinguishes between config commitment and oplog commitment
- Multiple concurrent heartbeat and replication channels

**Concurrency Model**: Multi-threaded with replication coordinator holding a central mutex (`_mutex`) that protects:
- Configuration state transitions
- Quorum check results
- Member health information
- Replication progress tracking

## 2. Bug Families

### Family 1: Config Version/Term Comparison Asymmetry

**Mechanism**: The `ConfigVersionAndTerm` comparison operator treats uninitialized terms specially. When either config has term=-1 (uninitialized, used in force reconfigs), the comparison ignores terms and only compares versions. This asymmetric comparison could lead to non-transitive ordering relations and unexpected behavior when mixing force-reconfig and normal-reconfig paths.

**Evidence**:
- Code: `repl_set_config.h:81-114` - ConfigVersionAndTerm operators `operator<` and `operator==` have special handling for `kUninitializedTerm`
- Code: `replication_coordinator_impl.cpp:3453-3460` - Force reconfig generates random high version number
- Code: `replication_coordinator_impl.cpp:5451` - Comparison is used in heartbeat message handling to decide whether to fetch newer configs

**Affected code paths**: 
- `processReplSetReconfig()` - normal reconfig, sets term to current term
- Force reconfig path - sets term to -1
- Heartbeat processing - uses comparison to determine config freshness
- Config installation decision logic

**Suggested modeling approach**:
- **Variables**: Add explicit tracking of force-reconfig state and term initialization status
- **Actions**: Model config comparison as a separate action that can be queried by the state machine
- **Granularity**: Split config installation into: (1) comparison decision, (2) installation, to expose race windows
- **Properties**: Invariant that config precedence is transitive and consistent across nodes

**Priority**: High  
**Rationale**: Config ordering is fundamental to correctness - incorrect ordering could allow stale configs to be installed, breaking safety invariants. The asymmetric comparison is non-obvious and could have unexpected interactions when both force-reconfig and normal-reconfig paths are active.

---

### Family 2: Non-Atomic Configuration Commit

**Mechanism**: The `_doReplSetReconfig()` function performs a multi-step configuration change that spans multiple atomic operations. The process is: (1) parse and validate new config, (2) check quorum, (3) write config to persistent storage with journal flush, (4) call `_finishReplSetReconfig()` to atomically update in-memory state. Between these steps, a process crash could leave the node in an inconsistent state where the persistent config differs from the in-memory installed config.

**Evidence**:
- Code: `replication_coordinator_impl.cpp:3530-3890` - `_doReplSetReconfig()` function
- Code: `replication_coordinator_impl.cpp:3626` - State transitions to `kConfigReconfiguring` before quorum check
- Code: `replication_coordinator_impl.cpp:3842-3878` - Persistent storage write and journal flush
- Code: `replication_coordinator_impl.cpp:3882` - `_finishReplSetReconfig()` called after persistent write

**Affected code paths**:
- `processReplSetReconfig()` - entry point for admin command
- `_doReplSetReconfig()` - main state machine
- `_finishReplSetReconfig()` - in-memory state update
- External state management - `storeLocalConfigDocument()`

**Suggested modeling approach**:
- **Variables**: Explicit persistent state vs. in-memory config with separate version numbers
- **Actions**: Split config commit into multiple sub-actions: validate, quorum-check, persist, install-in-memory
- **Granularity**: Create crash injection points between each sub-action
- **Properties**: Invariant that persisted config version >= in-memory config version after restart

**Priority**: High  
**Rationale**: Crash safety is critical for distributed systems. The multi-step commit creates crash windows where state diverges. This is a canonical distributed systems failure mode that TLA+ is well-suited to catch.

---

### Family 3: Quorum Check Response Accumulation Race

**Mechanism**: The `QuorumChecker` class accumulates responses from remote nodes in a scatter-gather pattern. The class maintains state (_responses, _successfulVoterCount, _numElectable) that is updated via `processResponse()` callbacks. If responses arrive concurrently or if `hasReceivedSufficientResponses()` is called while responses are being processed, the quorum decision could be made based on partially-updated state.

**Evidence**:
- Code: `check_quorum_for_config_change.cpp:64-93` - QuorumChecker constructor, initializes self as "responded"
- Code: `check_quorum_for_config_change.cpp:157-163` - `processResponse()` calls `_onQuorumCheckComplete()` if sufficient
- Code: `check_quorum_for_config_change.cpp:238-322` - `_tabulateHeartbeatResponse()` updates state vectors
- Code: `check_quorum_for_config_change.cpp:308-318` - Updates `_responses`, `_successfulVoterCount`, `_numElectable`
- Code: `check_quorum_for_config_change.cpp:324-331` - `hasReceivedSufficientResponses()` reads state

**Affected code paths**:
- `QuorumChecker::processResponse()` - called by ScatterGatherRunner
- `QuorumChecker::_tabulateHeartbeatResponse()` - updates response tracking state
- Quorum decision logic in `_onQuorumCheckComplete()`

**Suggested modeling approach**:
- **Variables**: Explicit response bitmap per member, separate tracking for main port vs. priority port
- **Actions**: Model response arrival as discrete events, quorum decision as atomic check-and-commit
- **Granularity**: Add intermediate states to show partial response collection
- **Properties**: Invariant that quorum decision is monotonic (once true, remains true), and that decision respects actual responses received

**Priority**: Medium  
**Rationale**: Scatter-gather patterns are known to have subtle race conditions. However, MongoDB uses ScatterGatherRunner which likely provides synchronization. The main risk is if responses arrive out of order relative to the sufficiency check, leading to off-by-one errors in vote counting.

---

### Family 4: Config Installation and Member State Synchronization

**Mechanism**: When `_setCurrentRSConfig()` is called (line 4572), it updates multiple interdependent pieces of state:
1. Updates topology coordinator with new config
2. Updates _termShadow to match new term
3. Updates _rsConfig reference
4. Updates _selfIndex
5. Updates member state
6. Cancels and reschedules heartbeats

If a crash occurs during this sequence, or if external threads read these values concurrently, they could observe inconsistent state (e.g., old config with new term, or new config with old selfIndex).

**Evidence**:
- Code: `replication_coordinator_impl.cpp:4572-4742` - `_setCurrentRSConfig()` function
- Code: `replication_coordinator_impl.cpp:4581` - `_topCoord->updateConfig()`
- Code: `replication_coordinator_impl.cpp:4584` - `_termShadow.store()`
- Code: `replication_coordinator_impl.cpp:4587` - `_rsConfig.update()`
- Code: `replication_coordinator_impl.cpp:4686` - `_selfIndex = myIndex`

**Affected code paths**:
- `_setCurrentRSConfig()` - called from `_doReplSetReconfig()` and other config-change paths
- Concurrent readers via `getConfig()`, `getTerm()`, `_selfIndex` accesses
- Heartbeat and replication subsystems that depend on consistent config/term/selfIndex

**Suggested modeling approach**:
- **Variables**: Track each piece of state separately with explicit ordering constraints
- **Actions**: Model config installation as a series of updates with potential crash points
- **Granularity**: Expose intermediate states between topology update and in-memory reference update
- **Properties**: Invariant that all components using a config see the same version/term

**Priority**: High  
**Rationale**: Configuration state is read by multiple subsystems (heartbeat, replication, elections). If reads see partially-updated state, they could make decisions based on a mix of old and new configs, potentially violating quorum assumptions.

---

### Family 5: Commit Point Tracking Across Config Changes

**Mechanism**: The system tracks two different commit points:
1. Config document commitment (needs majority in current config)
2. Oplog commitment (for entries before the config change)

Before installing a new config, the code checks that "the latest committed optime from the previous config is committed in the current config" (lines 3602-3624). However, the logic distinguishes between "force configs" (term=-1) and regular configs. If the state machine crashes while checking these conditions or while `lastCommittedInPrevConfig` is being calculated, the installation could proceed with incorrect assumptions about what's been committed.

**Evidence**:
- Code: `replication_coordinator_impl.cpp:3602-3624` - Oplog commitment check
- Code: `replication_coordinator_impl.cpp:3609-3610` - Check if leaving force config
- Code: `replication_coordinator_impl.cpp:4003` - `_topCoord->updateLastCommittedInPrevConfig()`
- Code: `replication_coordinator_impl.cpp:4005-4019` - Snapshot management based on config changes

**Affected code paths**:
- Config commitment safety checks in `_doReplSetReconfig()`
- Topology coordinator's commit tracking
- Snapshot creation and management

**Suggested modeling approach**:
- **Variables**: Separate tracking for committed optime in old config vs. new config
- **Actions**: Model commitment check and update as distinct phases
- **Granularity**: Separate the check (safety condition) from the action (optime update)
- **Properties**: Invariant that configs are only installed after verifying previous config's commits are safe

**Priority**: Medium  
**Rationale**: Commitment tracking is subtle and has different rules for force vs. normal reconfigs. The interactions between config versions, terms, and commit points create a complex state space that TLA+ can efficiently explore.

---

### Family 6: Config State Machine State Consistency

**Mechanism**: The replication coordinator maintains a state machine for configuration states: `kConfigUninitialized`, `kConfigInitiating`, `kConfigSteady`, `kConfigReconfiguring`, `kConfigHBReconfiguring`, `kConfigStartingUp`, `kConfigPreStart`. The state transitions are guarded by conditions like "must be in kConfigSteady to start a reconfig" (line 3541). However, the state is set with scope guards (lines 3627-3631), and multiple paths could potentially race on state transitions if error handling or concurrent operations interfere.

**Evidence**:
- Code: `replication_coordinator_impl.cpp:3540-3558` - State switch checking valid transitions
- Code: `replication_coordinator_impl.cpp:3626` - Sets state to kConfigReconfiguring
- Code: `replication_coordinator_impl.cpp:3627-3631` - ScopeGuard reverts state to kConfigSteady
- Code: `replication_coordinator_impl.cpp:3881` - configStateGuard.dismiss() on success

**Affected code paths**:
- `_doReplSetReconfig()` - main state transition
- `_setConfigState()` - state updates
- Scope guard lifetime management

**Suggested modeling approach**:
- **Variables**: Explicit config state variable with transitions
- **Actions**: Model state transitions as atomic updates with explicit guards
- **Granularity**: Show what happens if guard conditions are violated mid-operation
- **Properties**: Invariant that only one reconfiguration is in-flight at a time

**Priority**: Low-Medium  
**Rationale**: State machine consistency is important but MongoDB's use of scope guards and mutexes likely prevents most issues. However, examining the state transitions could reveal edge cases.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|-----|-----|-----|
| Config version/term comparison semantics | Family 1 - asymmetric comparison could violate transitivity | Add explicit comparison action that checks both term and version independently |
| Multi-step config commit with crash windows | Family 2 - non-atomic operations can leave persistent/in-memory state diverged | Split config installation into validate → quorum → persist → install phases with crash points between |
| Quorum sufficiency checking | Family 3 - response accumulation could have race conditions | Model response arrival as events, quorum decision as atomic action checking accumulated state |
| Config state synchronization across subsystems | Family 4 - config/term/selfIndex updates not atomic | Track each piece of state separately, check invariant that concurrent readers see consistent versions |
| Commit point safety across config changes | Family 5 - oplog commitment check has special rules for force configs | Model committed optime tracking separately from config version, verify committed entries remain committed across reconfig |
| Config installation atomicity | Family 4+2 - multiple reads during installation could see partial updates | Create explicit ordering between topology update and _rsConfig update |

### 3.2 Do Not Model (with rationale)

| What | Why |
|-----|-----|
| Split horizon networking | Configuration detail - DNS/network resolution is not a config correctness issue |
| Write concern majority calculation | Orthogonal to config reconfiguration - handled separately by write concern machinery |
| Heartbeat message formatting | Protocol detail, not a reconfiguration correctness issue |
| Memory efficiency of config storage | Performance concern, not correctness |
| Arbiters vs. regular nodes | Orthogonal consideration - doesn't affect the reconfiguration safety mechanism |
| Log replication during reconfig | Handled separately; assumes replication is working correctly |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| ConfigVersionAndTermComparison | configVersion, configTerm, isForceReconfig | Explicitly model the asymmetric comparison of configs with uninitialized terms | Family 1 |
| MultiStepConfigCommit | persistedConfigVersion, inMemoryConfigVersion, persistedConfigTerm | Track persistent vs. in-memory divergence across crashes | Family 2 |
| QuorumResponseTracking | mainPortResponses, priorityPortResponses, successfulVoters | Model scatter-gather response accumulation with explicit response events | Family 3 |
| ConfigStateConsistency | topCoordConfig, replCoordConfig, selfIndex, currentTerm | Ensure configuration state is consistent when read by concurrent subsystems | Family 4 |
| CommitmentSafety | committedOptimeInOldConfig, committedOptimeInNewConfig, configInstalled | Track commitment point transitions during reconfig | Family 5 |
| ConfigStateMachine | configState (enum: Steady, Reconfiguring, Initializing, etc.) | Model state transitions and guard conditions | Family 6 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ConfigVersionTermTransitivity | Safety | Config comparison is transitive: if A < B and B < C, then A < C | Family 1 |
| ConfigVersionMonotonicity | Safety | A node never installs a config older than its current config (by ConfigVersionAndTerm) | Family 1 |
| PersistentConfigValidity | Safety | The configuration persisted to disk is always >= the configuration in memory (by version/term) after restart | Family 2 |
| QuorumBasedOnActualResponses | Safety | A quorum check only succeeds if a majority of members actually responded (not assumed) | Family 3 |
| CommittedEntriesPreserved | Safety | If an entry is committed in config C1, it remains committed after installing config C2 that requires C1's oplog commitment | Family 5 |
| NoLostConfigChanges | Safety | If a config is persisted and durable on a node, that node will eventually install it (unless overridden by newer config) | Family 2 |
| OneConfigurationInTransition | Safety | At most one configuration reconfiguration operation is in-progress at any point | Family 6 |
| QuorumTermConsistency | Safety | All members agreeing to install a config must have seen the same term and version pair (ignoring force reconfig -1 term) | Family 1 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Can a node with a persistent force-reconfig (term=-1, high version) fail to install it after crash if it later learns of a normal reconfig with term=T and version=V where V < force version? | QuorumTermConsistency violated | Family 1 |
| MC-2 | If a node persists new config but crashes before calling _setCurrentRSConfig, can it diverge from the cluster when restarted (installing old config from memory while others have new config)? | ConfigVersionMonotonicity violated | Family 2 |
| MC-3 | Can two nodes make conflicting quorum check decisions if responses arrive out of order and each node's ScatterGatherRunner has different ordering of responses? | QuorumBasedOnActualResponses violated | Family 3 |
| MC-4 | If topology coordinator's config is updated but repl coordinator's _rsConfig is not (or vice versa due to crash/concurrency), can heartbeat processing use mismatched config versions? | ConfigStateConsistency violated | Family 4 |
| MC-5 | Is there a scenario where a config is marked as committed by quorum check before oplog entries from previous config are actually replicated to all members of new config? | CommittedEntriesPreserved violated | Family 5 |
| MC-6 | Can config state revert to kConfigSteady and allow a second reconfig while the first is still partially installed (scope guard dismissal race)? | OneConfigurationInTransition violated | Family 6 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | Verify that force reconfig can override any version from previous non-force configs | Unit test: create configs with uninitialized vs. initialized terms, verify comparison operator |
| TV-2 | Verify persistent config write and journal flush both complete before config is installed | Integration test: inject crashes between persistence and installation, verify recovery behavior |
| TV-3 | Verify quorum decision matches actual voting member responses | Unit test: mock responses, verify QuorumChecker counts match expected quorum |
| TV-4 | Verify selfIndex matches topology coordinator's view of self in config | Integration test: read both values concurrently after reconfig, verify consistency |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | ConfigVersionAndTerm comparison treats uninitialized term asymmetrically - document design rationale | Review design notes, add comments explaining why -1 term should ignore term field |
| CR-2 | _doReplSetReconfig uses scope guards for state management - verify all exit paths properly restore state | Code audit: trace all return paths to ensure state revert |
| CR-3 | QuorumChecker initializes self as responded - verify this matches quorum calculation assumptions | Review quorum check logic to ensure self-response is counted correctly |
| CR-4 | Config commitment checks differ for force vs. normal reconfigs - verify all safety invariants still hold for force path | Design review: verify force reconfig safety assumptions |

## 7. Reference Pointers

**Source files**:
- Core reconfiguration logic: `src/mongo/db/repl/replication_coordinator_impl.cpp` (lines 3412-3890, 4572-4742)
- Quorum checking: `src/mongo/db/repl/check_quorum_for_config_change.cpp` (lines 64-322)
- Config version/term comparison: `src/mongo/db/repl/repl_set_config.h` (lines 76-114)
- Topology coordination: `src/mongo/db/repl/topology_coordinator.h` + `.cpp` (config update and member state)

**Reference algorithm**: Raft (original paper: https://raft.github.io/raft.pdf), but MongoDB's implementation diverges in:
- Explicit configTerm field separate from log term
- Force reconfig mechanism with term=-1
- Commitment tracking across config changes
- Split of config decision and installation into multiple steps

**Key design documents** (if available in MongoDB repository):
- Replica set reconfiguration safety requirements
- Force reconfig semantics and guarantees
- Heartbeat protocol and config propagation

**Related test files**:
- `src/mongo/db/repl/replication_coordinator_impl_reconfig_test.cpp` - extensive reconfig test suite
- `src/mongo/db/repl/check_quorum_for_config_change_test.cpp` - quorum check tests
