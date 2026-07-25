# TLA+ Specification for MongoDB Chunk Migration

Phase 2 output: Complete TLA+ specification for the MongoDB chunk migration commit and recovery protocol.

## Generated Files

### Phase 1: Base Specification
- **`base.tla`** (22 KB) — Core protocol specification with all bug-family extensions
  - Models 3-node protocol: donor shard, recipient shard, config server
  - 20+ actions covering clone, critical section, commit/abort, cleanup, crash/recovery
  - 6 safety invariants targeting identified bug families
  - Extension variables for metadata state, task lifecycle, critical section release, RPC failures

- **`base.cfg`** — Base spec configuration

### Phase 2: Model Checking Wrapper
- **`MC.tla`** (4.8 KB) — MC spec with bounded fault injection
  - Counter variables for crash, message loss, timeout actions
  - Bounded wrappers around base spec actions
  - Temporal property for liveness (eventual completion)

- **`MC.cfg`** — Standard hunting configuration with all safety invariants
  - CrashLimit=2, MessageLossLimit=3, TimeoutLimit=3
  - Good starting point for convergence testing

- **`MC_hunt_family1.cfg`** — Target: Non-atomic commit/abort decisions
  - Tight bounds: CrashLimit=3, TimeoutLimit=1
  - Invariant: `DecisionDurabilityLeadsToCompletion`

- **`MC_hunt_family2.cfg`** — Target: Filtering metadata inconsistency
  - Focus on config server failure with active critical section
  - Invariant: `MetadataReflectsDecision`

- **`MC_hunt_family3.cfg`** — Target: Range deletion task lifecycle mismatch
  - Abort path with task deletion before recipient notification
  - Invariant: `RangeDeletionConsistency`

- **`MC_hunt_family4.cfg`** — Target: Async critical section release failures
  - Release failures leaving recipient blocked
  - Invariant: `CriticalSectionReleaseBeforeDone`

- **`MC_hunt_family5.cfg`** — Target: Abort error handling in RPC failures
  - Recipient notification failures with ShardNotFound
  - Invariant: `RangeDeletionConsistency`

### Phase 3: Trace Validation Spec
- **`Trace.tla`** (8.2 KB) — Trace validation wrapper
  - Category A pattern: single linear trace with cursor `l`
  - Validates recorded execution traces against base spec
  - Action wrappers with post-state field validation
  - Silent actions for crash/recovery (constrained to avoid explosion)

- **`Trace.cfg`** — Trace validation configuration
  - All safety invariants enabled
  - `TraceMatched` property ensures full trace consumption

### Phase 4: Instrumentation & Audit
- **`instrumentation-spec.md`** (14 KB) — Source code instrumentation guide
  - Maps each TLA+ action to C++ source locations (file:line)
  - Specifies trace event names and fields to capture
  - Documents async RPC timing, crash/recovery patterns, bootstrap state
  - Provides trace event examples in JSON format

- **`brief-coverage.md`** (8.8 KB) — Phase 2.5 Coverage Audit
  - Self-audit mapping modeling brief to spec artifacts
  - **Families**: All 6 families addressed; Family 6 explicitly out of scope
  - **Invariants**: All 6 safety invariants defined, wired, enabled in ≥1 hunt config
  - **Findings**: All 5 model-checkable findings have targeting hunt configs
  - Completeness check: ✓ No coverage gaps

## Bug Family Targeting

| Family | Issue | Hunting Config | Invariant Target |
|--------|-------|---|---|
| **1** | Non-atomic commit/abort with crash windows | `MC_hunt_family1.cfg` | `DecisionDurabilityLeadsToCompletion` |
| **2** | Metadata inconsistency on config server failure | `MC_hunt_family2.cfg` | `MetadataReflectsDecision` |
| **3** | Range deletion task lifecycle mismatch in abort | `MC_hunt_family3.cfg` | `RangeDeletionConsistency` |
| **4** | Critical section release failure leaves recipient stuck | `MC_hunt_family4.cfg` | `CriticalSectionReleaseBeforeDone` |
| **5** | Abort error handling with unnotified recipient | `MC_hunt_family5.cfg` | `RangeDeletionConsistency` |
| **6** | Interruptibility gaps (unmodeled per brief) | — | — |

## Protocol Coverage

### Actions (20 + crash/recovery)
- **Clone Phase**: `RecipientStartClone`, `RecipientCloneComplete`
- **Critical Section**: `DonorEnterCriticalSection`
- **Commit Decision**: `DonorPersistCommitDecision`, `DonorSendConfigServerCommit`
- **Config Server**: `ConfigServerPersistCommit`, `ConfigServerCommitFails`
- **Critical Section Release**: `LaunchReleaseRecipientCriticalSection`, `CriticalSectionReleaseSucceeds`, `CriticalSectionReleaseFails`
- **Commit Cleanup**: `DonorDeleteRangeDeletionTaskLocally`, `DonorRegisterRangeDeletionTask`, `DonorDeleteRecipientRangeDeletionTask`, `DonorMarkRangeDeletionReady`
- **Abort Path**: `DonorPersistAbortDecision`, `AbortDeleteDonorRangeDeletionTask`, `AbortBumpRecipientTxnNumber`, `AbortMarkRecipientRangeDeletionReady`, `AbortRecipientNotificationFails`
- **Finalization**: `ForgetMigration`, `AbortCleanup`
- **Fault Injection**: `DonorCrash`, `DonorRecover`, `RecipientCrash`, `RecipientRecover`

### Variables (14 total)
- **State machines**: `donorState`, `recipientState`, `configState`
- **Metadata** (Family 2): `donorMetadata`, `recipientMetadata`
- **Critical section** (Family 4): `criticalSectionActive`, `recipientCritSectionReleased`
- **Range deletion** (Family 3): `donorRangeDeletionTask`, `recipientRangeDeletionTask`
- **Decision persistence** (Family 1): `coordinatorDecision`, `donorDecision`, `recipientClone`
- **RPC errors** (Family 5): `lastRPCFailure`

### Invariants (6 Safety, 1 Liveness)
- `MCTypeOK` — Type safety
- `ChunkOwnershipConsistency` — At most one shard owns chunk
- `DecisionDurabilityLeadsToCompletion` — Persisted decisions are honored
- `RangeDeletionConsistency` — Task lifecycle is consistent across nodes
- `NoDoubleCommit` — Migration cannot commit twice
- `MetadataReflectsDecision` — Metadata reflects actual decision
- `CriticalSectionReleaseBeforeDone` — Release happens before migration ends (liveness)
- `EventualCompletion` — Committed migrations eventually finish (temporal)

## Usage Guide

### 1. Specification Convergence (validates spec syntax and logic)
```bash
tlc MC.cfg
```
- **Expected**: No errors, trace all reachable states
- **Time**: ~5-10 minutes for default bounds
- **Output**: State space size, coverage report

### 2. Bug Hunting per Family
```bash
tlc MC_hunt_family1.cfg
tlc MC_hunt_family2.cfg
tlc MC_hunt_family3.cfg
tlc MC_hunt_family4.cfg
tlc MC_hunt_family5.cfg
```
- **Expected**: Invariant violations discovered for reachable crash windows
- **Time**: 2-5 minutes each, depending on bounds
- **Output**: Counterexample traces showing bugs

### 3. Trace Validation (after instrumentation + trace collection)
```bash
tlc Trace.cfg
```
- **Input**: Real execution traces in `../traces/trace.ndjson`
- **Expected**: No errors; `TraceMatched` property verified
- **Output**: State-by-state validation against spec

## Next Steps: Phase 3 (Harness Generation)

Use `instrumentation-spec.md` to:
1. Identify source code locations for each action
2. Add trace event emissions at specified trigger points
3. Capture fields listed in "Fields to capture"
4. Generate NDJSON traces from instrumented system

See `harness-generation` skill for implementation details.

## Key Design Decisions

### Action Granularity
- **Split actions where crash windows exist**: Decisions are persisted separately from cleanup operations, allowing TLC to explore intermediate crash states
- **Separate RPC send from completion**: Critical section release is async (launched early, awaited later), modeled as two distinct actions

### Fault Model
- **Crash**: Node loses in-memory state; persistent state survives
- **Message loss**: Network RPC can fail with ShardNotFound or timeout
- **No Byzantine**: Nodes follow protocol; only crash and message loss modeled

### Out of Scope
- **Batch cloning algorithm**: Too granular; only clone completion matters
- **Index building**: Feature interaction; not core to protocol
- **Write concern levels**: Replication detail covered by crash model
- **Interruptibility (Family 6)**: Implementation liveness concern; doesn't affect safety

## Source Code References

All action locations cite specific C++ files and line numbers from:
- `migration_coordinator.cpp` — Coordination logic (3-way decision, cleanup)
- `migration_source_manager.cpp` — Donor-side state machine (critical section, metadata)
- `migration_destination_manager.cpp` — Recipient-side state machine (clone, critical section)

See brief-coverage.md for complete code reference table.

## Validation Status

- ✓ Phase 1 (Base): Variables, actions, invariants designed from brief
- ✓ Phase 2 (MC): Counter-bounded specs for all families, hunting configs written
- ✓ Phase 2.5 (Audit): Coverage completeness verified; no gaps
- ✓ Phase 3 (Trace): Trace spec and validation config ready
- ✓ Phase 4 (Instrumentation): Detailed source code mapping for harness generation

**Ready for Phase 3**: Instrumentation and trace collection.
