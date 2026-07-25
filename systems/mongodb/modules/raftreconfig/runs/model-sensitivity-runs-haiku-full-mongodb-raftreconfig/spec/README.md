# MongoDB Replica Set Reconfiguration: TLA+ Specification

This directory contains the complete TLA+ specification for MongoDB's Raft-based replica set reconfiguration protocol, generated from the modeling brief produced by Phase 1 (code analysis).

## Files Overview

### Phase 1: Base Specification

- **`base.tla`** — Core TLA+ specification modeling the replica set reconfiguration logic
  - 6 bug-family-driven extensions for crash windows, asymmetric comparison, quorum races, etc.
  - Faithful to implementation control flow with source line annotations
  - ~650 lines including full invariants

- **`base.cfg`** — Configuration for base spec with 3-node cluster, standard invariants

### Phase 2: Model Checking Specification

- **`MC.tla`** — MC wrapper with counter-bounded fault injection
  - Wraps base actions with crash, quorum timeout, disk block, response loss, config change limits
  - Defines symmetry reduction and state space pruning
  - ~200 lines

- **`MC.cfg`** — Standard MC configuration for convergence testing
  - Bounds: 2 crashes, 5 quorum checks, 3 disk blocks, 3 response losses, 3 config changes
  - Enables core safety invariants
  - Comments out family-specific invariants (enabled per hunt config)

- **`MC_hunt_Family1.cfg` through `MC_hunt_Family6.cfg`** — Targeted hunting configs
  - One per bug family from the modeling brief
  - Tight bounds (0-4 config changes, selective fault injection)
  - Each enables only the target invariant + core safety invariants
  - Used after MC.cfg converges to find specific bugs

### Phase 2.5: Coverage Audit

- **`brief-coverage.md`** — Self-audit mapping brief §2/§5/§6.1 → spec artifacts
  - Tables showing bug families → hunt configs
  - Invariants → configs where enabled
  - Model-checkable findings → their targeting hunt configs
  - Justification for out-of-scope items

### Phase 3: Trace Validation Specification

- **`Trace.tla`** — Trace spec for replaying implementation executions
  - Event types for each spec action (CompareConfig, ReConfigInitiate, QuorumStart, etc.)
  - Post-state validation for each event
  - Silent action handlers for state changes without trace events
  - ~300 lines

- **`Trace.cfg`** — Configuration for trace validation
  - Enables safety invariants only (liveness skipped)
  - `PROPERTIES TraceMatched` for completion check

### Phase 4: Instrumentation Specification

- **`instrumentation-spec.md`** — Mapping document for harness generation
  - Section 1: Trace event schema and common fields
  - Section 2: Action-to-code mapping (11 actions across 6 families)
  - Section 3: Special considerations (state capture timing, force reconfigs, scope guards, etc.)
  - Section 4: Instrumentation checklist

## Spec Structure

### Variables (base.tla)

**Protocol State**:
- `currentTerm` — current term/epoch per server
- `configTerm`, `configVersion` — in-memory config version and term
- `configState` — structured config state

**Non-Atomic Persistence (Family 2)**:
- `persistedConfigTerm`, `persistedConfigVersion` — durable config on disk
- `pendingConfigWrite` — persistence in-flight flag

**Quorum Checking (Family 3)**:
- `quorumState` — scatter-gather state (idle/in_progress/succeeded/failed)
- `voterResponses` — set of voters who responded
- `respondCount` — response count for sufficiency check

**Commitment Tracking (Family 5)**:
- `committedOptimeInConfig` — highest committed optime per server

**Config State Machine (Family 6)**:
- `configStateEnum` — state transitions (kConfigSteady, kConfigReconfiguring, etc.)

### Actions (base.tla)

**Family 1 (Asymmetric Comparison)**:
- `CompareConfigVersionAndTerm` — read-only query of comparison logic

**Family 2 (Multi-Step Commit)**:
- `DoReplSetReconfig_Initiate` — enter kConfigReconfiguring state
- `QuorumChecker_Start` — begin scatter-gather
- `QuorumChecker_ProcessResponse` — process one response
- `DoReplSetReconfig_Persist` — start disk write
- `JournalFlush_Complete` — durability guaranteed
- `DoReplSetReconfig_FinishInstall` — update in-memory config
- `Crash_RecoverConfigFromDisk` — recovery from crash

**Family 3 (Quorum Races)**:
- `QuorumChecker_Timeout` — quorum check fails

**Family 4 (Config Synchronization)**:
- `Heartbeat_SendCurrentConfig` — send current config to peer

**Family 5 (Commitment Safety)**:
- `AdvanceCommittedOptime` — advance oplog commit point

**Fault Injection**:
- `DiskWriteBlock`, `ResponseLoss` (base spec; bounded in MC.tla)

### Invariants (base.tla)

**Core Safety** (enabled in MC.cfg):
- `MCTypeOK` — type correctness
- `ConfigVersionTermTransitivity` — comparison transitivity (Family 1)
- `ConfigVersionMonotonicity` — no config downgrades (Family 1)
- `PersistentConfigValidity` — persistent >= in-memory after restart (Family 2)
- `QuorumBasedOnActualResponses` — quorum success ⇒ responses received (Family 3)
- `ConfigStateConsistency` — config state consistency (Family 4)

**Family-Specific** (commented in MC.cfg, enabled in hunt configs):
- `CommittedEntriesPreserved` — committed entries don't disappear (Family 5)
- `OneConfigurationInTransition` — at most one reconfig in-flight (Family 6)
- `ConfigStateValidity` — valid state transitions (Family 6)

## Verification Workflow

### Step 1: Convergence Test (MC.cfg)

Run the standard MC.cfg to verify the spec is well-formed and core invariants hold:

```bash
tlc MC
```

Expected: No errors, state space explores without deadlock.

### Step 2: Bug Hunting (MC_hunt_*.cfg)

Run each family's hunting config to look for family-specific violations:

```bash
tlc -config MC_hunt_Family1.cfg MC
tlc -config MC_hunt_Family2.cfg MC
tlc -config MC_hunt_Family3.cfg MC
tlc -config MC_hunt_Family4.cfg MC
tlc -config MC_hunt_Family5.cfg MC
tlc -config MC_hunt_Family6.cfg MC
```

For each family, the spec will either:
- **Find a violation**: TLC reports the invariant violated and provides a counterexample (sequence of states)
- **Complete without violation**: The mechanism is not reachable or the code is safe

### Step 3: Trace Validation (Trace.cfg)

After harness generation produces traces:

```bash
tlc -config Trace.cfg Trace
```

Expected: No deadlock, entire trace consumed (`TraceMatched` holds), post-state validation passes on every event.

## Source Code Mapping

Every action in base.tla is annotated with source lines from:

- **Core reconfig logic**: `src/mongo/db/repl/replication_coordinator_impl.cpp` (lines 3412-3890, 4572-4742)
- **Quorum checking**: `src/mongo/db/repl/check_quorum_for_config_change.cpp` (lines 64-322)
- **Config comparison**: `src/mongo/db/repl/repl_set_config.h` (lines 76-129)
- **Topology coordination**: `src/mongo/db/repl/topology_coordinator.h/.cpp`

## Bug Families Modeled

| Family | Mechanism | Root Cause | Expected Violation |
|--------|-----------|------------|---|
| 1 | Asymmetric comparison when term=-1 | `repl_set_config.h:92-96` ignores term field for force reconfigs | `ConfigVersionTermTransitivity` or `ConfigVersionMonotonicity` |
| 2 | Non-atomic multi-step commit | Crash between persistence (line 3878) and installation (line 3882) | `PersistentConfigValidity` (in-memory diverged from persisted) |
| 3 | Quorum response accumulation race | Responses arrive out-of-order, check could succeed without actual majority | `QuorumBasedOnActualResponses` (quorum succeeded without sufficient responses) |
| 4 | Config state synchronization | Concurrent readers see partially-updated topology/config/term | `ConfigStateConsistency` (observed mixed old/new state) |
| 5 | Commitment safety across configs | Force-reconfig bypasses oplog commitment checks (line 3608-3609) | `CommittedEntriesPreserved` (optime committed in old config, lost in new) |
| 6 | Config state machine consistency | Scope guard revert race or multiple reconfigs in-flight | `OneConfigurationInTransition` (multiple nodes reconfiguring simultaneously) |

## Notes

### Granularity Decisions

The spec splits `_doReplSetReconfig()` into 7 separate actions (not one atomic action) because:
- TLA+ faithfully models the implementation's actual execution granularity
- Crash windows are explicitly exposed between actions
- Each action boundary is a potential interleaving point
- This enables exhaustive exploration of timing-dependent bugs

Merging actions would hide these bugs by assumption.

### Config Version/Term Comparison

Lines 81-100 in `repl_set_config.h` define asymmetric operators:
- If either term is -1 (uninitialized/force), ignore term and compare versions only
- Otherwise, compare term first, then version

This design allows force-reconfigs to override any previous config by using a high version number. The asymmetry can lead to non-transitive comparisons if not carefully handled.

### Force Reconfig (-1 Term)

When a reconfig is forced (e.g., `replSetReconfig({force: true})`):
- Config term is explicitly set to -1 (line 3425: `OpTime::kUninitializedTerm`)
- Config version is bumped by 10,000 + random (lines 3455-3456)
- Comparison operator ignores the -1 term (lines 94-96)
- Commitment checks are skipped (lines 3608-3609)

This design is intentional but requires careful verification to ensure it doesn't enable invalid transitions.

### Scope Guard

Lines 3627-3631 set a scope guard to revert `_rsConfigState` to `kConfigSteady` if an error occurs. On success, the guard is dismissed at line 3881. The guard revert is modeled by `Crash_RecoverConfigFromDisk` (simplified; in reality the crash/recovery is implicit).

## Future Work

- Add secondary replication modeling (currently assumes replication works)
- Model priority port (dual-path quorum checks)
- Model implicit default write concern changes
- Model force reconfig consensus (currently simplified)
- Extend to >3 nodes if state space allows

## Contact

For questions about the spec or mapping to implementation, see:
- `modeling-brief.md` (Phase 1 analysis)
- `instrumentation-spec.md` (harness generation guide)
- `/home/ubuntu/Specula/.claude/skills/spec_generation/` (reference materials)
