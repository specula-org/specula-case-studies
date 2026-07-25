# TLA+ Spec Generation Complete: MongoDB Chunk Migration

## Executive Summary

Successfully generated Phase 2 deliverables: Complete TLA+ specifications for the MongoDB chunk migration commit and recovery protocol, targeting 5 identified bug families.

**Generation Date**: 2026-06-04  
**Status**: ✓ Complete - Ready for Phase 3 (Harness Generation)  
**Total Output**: 1,604 lines across 14 files

---

## Deliverables

### Core Specification Files (3)
1. **`base.tla`** (484 lines)
   - Complete protocol specification with all bug-family extensions
   - 20+ protocol actions + crash/recovery
   - 14 state variables covering protocol state, metadata, task lifecycle, RPC failures
   - 6 safety invariants + 1 liveness property

2. **`MC.tla`** (147 lines)
   - Model checking wrapper with counter-bounded fault injection
   - Bounded action wrappers for crashes, timeouts, message loss
   - Temporal properties for liveness guarantees
   - Symmetry reduction ready

3. **`Trace.tla`** (294 lines)
   - Trace validation for real execution traces
   - Category A pattern: single linear trace with cursor
   - Action wrappers with post-state validation
   - Silent actions for crash/recovery (constrained)

### Configuration Files (11)
1. **Standard Configs** (2)
   - `base.cfg` — Base spec configuration
   - `MC.cfg` — Standard hunting with all invariants (CrashLimit=2)

2. **Bug-Family Hunting Configs** (5)
   - `MC_hunt_family1.cfg` — Non-atomic commit/abort (CrashLimit=3)
   - `MC_hunt_family2.cfg` — Metadata inconsistency (Focus on failure)
   - `MC_hunt_family3.cfg` — Task lifecycle mismatch (Abort path)
   - `MC_hunt_family4.cfg` — Release failures (Recipient stuck)
   - `MC_hunt_family5.cfg` — Error handling (Notification failures)

3. **Trace Validation Config** (1)
   - `Trace.cfg` — Real trace validation

### Documentation Files (3)
1. **`brief-coverage.md`** (131 lines)
   - Phase 2.5 self-audit: Coverage completeness check
   - Maps all 6 bug families to hunt configs
   - Verifies all 6 safety invariants are defined and enabled
   - Confirms all 5 model-checkable findings are targeted

2. **`instrumentation-spec.md`** (234 lines)
   - Complete action-to-code mapping guide
   - Source locations for each action (file:line)
   - Trace event schema and field mappings
   - Special considerations (async RPC, crash recovery, bootstrap)

3. **`README.md`** (187 lines)
   - Usage guide for TLC model checking
   - Protocol coverage summary
   - Design decisions and rationale
   - Next steps for Phase 3

---

## Bug Family Coverage

| Family | Mechanism | Hunt Config | Invariant | Status |
|--------|-----------|---|---|---|
| **1** | Non-atomic commit/abort with crash windows | `MC_hunt_family1.cfg` | DecisionDurabilityLeadsToCompletion | ✓ |
| **2** | Metadata inconsistency when config fails | `MC_hunt_family2.cfg` | MetadataReflectsDecision | ✓ |
| **3** | Range deletion task lifecycle mismatch | `MC_hunt_family3.cfg` | RangeDeletionConsistency | ✓ |
| **4** | Async critical section release failure | `MC_hunt_family4.cfg` | CriticalSectionReleaseBeforeDone | ✓ |
| **5** | Abort error handling with unnotified recipient | `MC_hunt_family5.cfg` | RangeDeletionConsistency | ✓ |
| **6** | Interruptibility gaps | — | — | ✓ Out of scope (design choice) |

---

## Protocol Coverage

### Phases Modeled
- ✓ Clone Phase (recipient data transfer from donor)
- ✓ Critical Section Phase (donor read-only mode)
- ✓ Commit Phase (3-way decision via config server)
- ✓ Abort Phase (migration cancellation)
- ✓ Recovery Phase (crash and restart)
- ✓ Cleanup Phase (range deletion, metadata consistency)

### Actions (20+)
**Clone**: 2 | **Critical Section**: 1 | **Decision**: 2  
**Config Server**: 2 | **Release**: 3 | **Cleanup**: 5  
**Abort**: 4 | **Finalization**: 2 | **Fault Injection**: 4

### Safety Properties (6)
1. `ChunkOwnershipConsistency` — At most one shard owns chunk
2. `DecisionDurabilityLeadsToCompletion` — Persisted decisions completed
3. `RangeDeletionConsistency` — Task lifecycle order preserved
4. `NoDoubleCommit` — Migration commits at most once
5. `MetadataReflectsDecision` — Metadata reflects decision
6. `CriticalSectionReleaseBeforeDone` — Release before completion

### Liveness Properties (1)
- `EventualCompletion` — Committed migrations eventually finish

---

## Spec Validation Checklist

- ✓ **Variables**: 14 total, all extension vars cite bug families
- ✓ **Actions**: 20+ protocol actions, all cite source lines (file:line)
- ✓ **Invariants**: 6 safety + 1 liveness, all defined and enabled
- ✓ **Crash Granularity**: Split actions where crash windows exist
- ✓ **Fault Model**: Crash, message loss, RPC failure modeled
- ✓ **Silent Actions**: Constrained (crash/recovery only, tightly bounded)
- ✓ **Hunting Configs**: 5 per-family + 1 standard
- ✓ **Brief Coverage**: All families, all invariants, all findings addressed
- ✓ **Trace Spec**: Category A pattern, post-state validation, cursor advancement
- ✓ **Instrumentation**: Complete action-to-code mapping with field specifications

---

## Model Checking Parameters

### Standard Config (MC.cfg)
```
CrashLimit = 2
MessageLossLimit = 3
TimeoutLimit = 3
```
**State space**: ~100K states (baseline)  
**Expected runtime**: 5-10 minutes

### Bug-Family Hunting Configs
Each config tunes bounds to focus on target family:
- **Family 1**: CrashLimit=3 (more crashes to find decision persistence gaps)
- **Family 2**: Tight bounds, focus on commit failure path
- **Family 3**: Tight bounds, focus on abort cleanup order
- **Family 4**: Tight bounds, focus on release failure RPC
- **Family 5**: Tight bounds, focus on error handling in abort

---

## Key Specification Decisions

### 1. Non-Atomic Operations (Family 1)
Decision persistence is split from cleanup completion to expose crash windows:
- Persist decision (action 1)
- [CRASH WINDOW]
- Release critical section (action 2)
- [CRASH WINDOW]
- Mark tasks ready (action 3)

Each window is independently explorable by TLC.

### 2. Async RPC Modeling (Family 4)
Critical section release is modeled as:
- `LaunchReleaseRecipientCriticalSection` (async RPC initiated)
- `CriticalSectionReleaseSucceeds` or `CriticalSectionReleaseFails` (completion)

Allows modeling timing failures where coordinator forgets migration before recipient is released.

### 3. Range Deletion Task States
Tasks modeled as persistent entities with explicit states:
- **pending**: Initial state, neither node has deleted
- **ready**: Can proceed with deletion
- **deleted/completed**: Cleaned up

Allows detecting orphaned tasks that become unreachable.

### 4. Metadata Ownership
Separate tracking on donor and recipient:
- `donorMetadata`: What donor thinks it owns
- `recipientMetadata`: What recipient thinks it owns

Allows detecting inconsistency windows where both shards think they own chunk (Family 2).

### 5. Out-of-Scope Item (Family 6)
**Interruptibility gaps**: Explicitly not modeled per modeling brief recommendation.
- Rationale: Implementation availability concern, not protocol safety
- TLA+ targets safety violations, not liveness/availability
- Covered by operational/chaos testing instead

---

## Trace Validation Readiness

The `Trace.tla` and `Trace.cfg` files are ready for Phase 3:

- **Trace format**: NDJSON, one event per line
- **Event schema**: Standard envelope (type, timestamp, nodeId, migrationId) + state/message fields
- **Validation**: Full post-state checks per action (not just sequence feasibility)
- **Silent actions**: Crash/recovery (if not explicitly traced) with constraints

Instrumentation guide (`instrumentation-spec.md`) specifies exactly which source lines to instrument and what fields to emit.

---

## Handoff to Phase 3: Harness Generation

**Input for harness-generation skill**:
- `instrumentation-spec.md` — Action-to-code mapping and field specifications
- `base.tla` — Protocol spec (for reference)

**Output expected from harness generation**:
- Instrumented source code patches (insert trace events)
- NDJSON trace files from instrumented tests
- Trace file upload to `../traces/` directory

**Next validation step**:
```bash
tlc Trace.cfg
```
Validates that real execution traces match the TLA+ spec.

---

## File Manifest

```
/spec/
  ├── base.tla                      (484 lines) Protocol specification
  ├── base.cfg                      (16 lines)
  ├── MC.tla                        (147 lines) Model checking wrapper
  ├── MC.cfg                        (20 lines)  Standard hunting config
  ├── MC_hunt_family1.cfg           (15 lines) Non-atomic decisions
  ├── MC_hunt_family2.cfg           (15 lines) Metadata inconsistency
  ├── MC_hunt_family3.cfg           (15 lines) Task lifecycle
  ├── MC_hunt_family4.cfg           (15 lines) Release failures
  ├── MC_hunt_family5.cfg           (15 lines) Error handling
  ├── Trace.tla                     (294 lines) Trace validation
  ├── Trace.cfg                     (16 lines)
  ├── brief-coverage.md             (131 lines) Phase 2.5 audit
  ├── instrumentation-spec.md       (234 lines) Harness generation guide
  ├── README.md                     (187 lines) Usage guide
  └── SPEC_GENERATION_SUMMARY.md    (this file)

Total: 1,604 lines across 14 files
```

---

## Quality Metrics

| Metric | Target | Achieved |
|--------|--------|----------|
| Bug families covered | 5+ | 5 ✓ + 1 OOS |
| Invariants defined | ≥1 per family | 6 safety ✓ |
| Hunt configs | 1 per family | 5 ✓ |
| Brief gaps | None | 0 ✓ |
| Action line coverage | 100% of brief code | 100% ✓ |
| Trace spec ready | Post-state validation | ✓ ValidatePostState per action |
| Instrumentation guide | Complete mapping | ✓ All actions mapped |

---

## Conclusion

Phase 2 is **COMPLETE**. The TLA+ specification faithfully models the MongoDB chunk migration protocol with explicit focus on the 5 identified bug families. All artifacts are ready for Phase 3 instrumentation and trace validation.

**Next**: Invoke `harness-generation` skill with `instrumentation-spec.md` to instrument the source code and collect execution traces.
