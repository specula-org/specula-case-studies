# TLA+ Specification Generation Summary

**System**: MongoDB Logical Session Catalog  
**Category**: Category A (Distributed/Message-Passing)  
**Completion Date**: 2026-06-04  
**Status**: ✓ All phases complete

---

## Deliverables

### Phase 1: Base Specification (✓ Complete)

**Files**:
- `spec/base.tla` (19 KB) — Core TLA+ spec with bug-family driven extensions
- `spec/base.cfg` (673 B) — Base configuration for standard validation

**Coverage**:
- 5 Bug Families modeled with explicit state variables and actions
- 10 core actions modeling implementation control flow (session_catalog.cpp + logical_session_cache_impl.cpp)
- 6 Safety invariants + 5 Structural invariants
- Every action annotated with source code line references
- 2 Liveness properties (session release, job completion)

**Key Features**:
- Session state machine: AVAILABLE → CHECKED_OUT → KILLING → KILLED
- Kill token refcounting with separate interrupt tracking (Family 4)
- Parent-child session relationships with reap consistency (Family 2)
- Background job scheduling for refresh/reap concurrency (Family 3)
- Release unlock-callback race modeling (Family 5)

### Phase 2: Model Checking Specification (✓ Complete)

**Files**:
- `spec/MC.tla` (8.2 KB) — MC wrapper with counter-bounded fault injection
- `spec/MC.cfg` (891 B) — Standard safety/convergence configuration
- `spec/MC_hunt_family1.cfg` — Checkout-Kill-Release race hunting
- `spec/MC_hunt_family2.cfg` — Parent-Child consistency hunting
- `spec/MC_hunt_family3.cfg` — Refresh-Reap async race hunting
- `spec/MC_hunt_family4.cfg` — Kill token ordering hunting
- `spec/MC_hunt_family5.cfg` — Release callback race hunting

**Coverage**:
- 9 counter-bounded fault-injection actions
- 3 unconstrained reactive actions (finalization)
- Symmetry reduction (SessionIds permutations)
- State space pruning (counter bounds enforcement)
- 6 Family-specific hunting configs with:
  - Tight bounds (4-6 for key mechanisms, 1-2 for irrelevant)
  - Targeted invariants (1-2 per family)
  - MCTypeOK + structural baseline

### Phase 2.5: Brief Coverage Audit (✓ Complete)

**Files**:
- `spec/brief-coverage.md` (7.8 KB) — Coverage mapping and self-check

**Verification**:
- ✓ All 5 bug families have dedicated hunt configs
- ✓ All 6 Safety invariants defined, wired, and enabled
- ✓ All 6 model-checkable findings have targeting mechanisms
- ✓ Code path traceability: 8 functions → 10 spec actions
- ✓ Extension variables: 6/6 families covered

### Phase 3: Trace Validation Specification (✓ Complete)

**Files**:
- `spec/Trace.tla` (9.7 KB) — Trace replay spec with post-state validation
- `spec/Trace.cfg` (416 B) — Trace validation configuration

**Coverage**:
- 10 action wrappers (1:1 mapping to base.tla actions)
- 2 silent actions (operation completion, kill status checks)
- Post-state field validation for every action
- Cursor-based trace consumption (linear ordering)
- Stuttering for completed trace
- TraceMatched temporal property (all events consumed)

**Validation Strategy**:
- Type OK during trace replay
- Safety invariants verified at every step
- Structural consistency (parent-child, state validity)
- Bootstrap state matching implementation

### Phase 4: Instrumentation Specification (✓ Complete)

**Files**:
- `spec/instrumentation-spec.md` (15 KB) — Action-to-code mapping guide

**Contents**:
- **Section 1**: Trace event schema and field mappings
  - Common event envelope (event name, timestamp, sessionId, state)
  - 6 state fields → implementation getters
  - Session state derivation logic
- **Section 2**: 10 action-to-code mappings
  - Each action: spec name, code location (file:line), trigger point, trace event name, fields, post-state validation
  - Functions referenced: 8 core implementation functions
  - Code locations: 35 specific line references
- **Section 3**: Special implementation considerations
  - Concurrency and lock boundaries
  - State aliasing (implicit → explicit sessionState)
  - Operation context ID mapping (pointer → stable ID)
  - Bootstrap state, kill token refcounting, parent-child reaping
  - Cache state transitions, serialization notes
- **Section 4**: Harness implementation checklist (10 items)

---

## Bug Family Coverage Matrix

| Family | Mechanism | Base Variables | MC Actions | Hunt Config | Target Invariants | Model-Checkable Findings |
|--------|-----------|-------|-----------|-----------|----------|----------|
| **F1** | Checkout-Kill-Release race | sessionState, killsRequested, checkoutOpCtx | CheckOutInner, Kill, Release (bounded) | family1.cfg | CheckedOutXorKilled | MC1, MC5, MC6 |
| **F2** | Parent-Child consistency | parentOf, childrenOf, markedForReap, reapMode | CreateChild, ScanReap (bounded) | family2.cfg | ParentNotReapedWithChildren, NoOrphanedChildren | MC3, MC6 |
| **F3** | Refresh-Reap async race | refreshRunning, reapRunning, cacheState, activeSessions | PeriodicRefresh, PeriodicReap (bounded) | family3.cfg | (Liveness) | MC4 |
| **F4** | killsRequested counter ordering | killsRequested, killsRequested_interrupted | Kill, CheckOut (bounded) | family4.cfg | InterruptConsistency, KillCountNonNegative | MC2 |
| **F5** | Release unlock-callback race | pendingCallbacks, callbackExecuting | ReleaseSession, Callback* (bounded) | family5.cfg | CallbackExecution | (Ordering) |

---

## Spec Statistics

| Metric | Value |
|--------|-------|
| **Total TLA+ lines** | ~1,100 (base.tla: 700, MC.tla: 400) |
| **Actions** | 13 (10 core + 3 reactive) |
| **Variables** | 16 (8 base + 8 extensions) |
| **Invariants** | 11 (6 safety + 5 structural) |
| **Temporal properties** | 2 (liveness) |
| **Hunt configs** | 5 (1 per family) |
| **Code annotations** | 35+ line references to source |
| **Instrumentation points** | 10 (1 per action) |
| **Trace events** | 10 (1:1 with actions) |

---

## Design Decisions

### Category A Justification
While the session catalog has concurrent state machine characteristics, the primary concurrency is through message-passing style (checkout/kill/release operations) and background job scheduling, not lock-free data structures. The spec models:
- Shared session state protected by mutex (implicit in actions)
- Explicit operation sequencing via state transitions
- Non-deterministic job interleaving (refresh/reap)

### Action Granularity
Each operation is split at real semantic boundaries where concurrency matters:
- **Checkout**: Precondition check → state transition → context assignment
- **Kill**: Counter increment → interrupt decision → actual interrupt
- **Release**: Decrement → state reset → callback invocation
- **Reap**: Decision → marking → erasure

This captures the race windows identified in the brief without over-fragmentation.

### Extension Variables
All 6 extensions trace directly to brief §3.1 recommendations:
1. **sessionState** — Explicit tracking (F1)
2. **killsRequested_interrupted** — Separate from counter (F4)
3. **parentOf/childrenOf** — Relationship tracking (F2)
4. **markedForReap/reapMode** — Reap marking (F2)
5. **refreshRunning/reapRunning** — Job scheduling (F3)
6. **pendingCallbacks/callbackExecuting** — Callback race (F5)

### MC Bounds Strategy
Tight bounds maximize interleaving of target mechanisms:
- F1 hunt: 6 checkouts, 6 kills, 6 releases (small sessions: 2)
- F2 hunt: 5 reaps, 5 child creations (full sessions: 3)
- F3 hunt: 5 refreshes, 5 reaps (small sessions: 3)
- F4 hunt: 5 kills, 5 checkouts (small sessions: 2)
- F5 hunt: 5 releases, 5 callbacks (small sessions: 2)

Irrelevant actions bounded to 1-2 to keep state space manageable.

---

## Next Steps

### Phase 3a: Spec Convergence
```bash
cd spec/
tlc -config MC.cfg MC.tla
# Run until no new states discovered (stabilization)
# Expected time: 5-15 minutes on standard hardware
```

### Phase 3b: Bug Hunting
```bash
# Run hunting configs after spec converges
for family in 1 2 3 4 5; do
  tlc -config MC_hunt_family$family.cfg MC.tla
  # Analyze any invariant violations
done
```

### Phase 2.5 (Parallel): Instrumentation
Using `instrumentation-spec.md`:
1. Instrument MongoDB source with trace hooks at 10 action points
2. Build instrumented binary
3. Run test scenarios (checkout → kill → reap, parent-child creation, etc.)
4. Collect traces to `../traces/mongodb-session.ndjson`

### Phase 3c: Trace Validation
```bash
tlc -config Trace.cfg Trace.tla
# Validate collected traces against spec
# Expected: All events consumed, invariants satisfied
```

### Phase 4: Iterate
If spec/trace divergence or model checking violations occur:
1. Review the brief and code for missed details
2. Update spec (add variables, split actions, refine guards)
3. Re-run convergence and hunting
4. Update instrumentation and re-collect traces

---

## Files Summary

**Spec Files** (13 total):
```
spec/
├── base.tla                 # Core spec
├── base.cfg                 # Base config
├── MC.tla                   # MC wrapper
├── MC.cfg                   # Standard MC config
├── MC_hunt_family1.cfg      # Family 1 hunting
├── MC_hunt_family2.cfg      # Family 2 hunting
├── MC_hunt_family3.cfg      # Family 3 hunting
├── MC_hunt_family4.cfg      # Family 4 hunting
├── MC_hunt_family5.cfg      # Family 5 hunting
├── Trace.tla                # Trace validation
├── Trace.cfg                # Trace config
├── brief-coverage.md        # Coverage audit
└── instrumentation-spec.md  # Instrumentation guide
```

**Related Files**:
```
../
├── modeling-brief.md        # Phase 1 output (input to this phase)
├── artifact/                # Source code reference
└── traces/                  # (To be populated by harness generation)
    └── mongodb-session.ndjson
```

---

## Validation Checklist

- [x] Every action in base.tla has source code line annotations
- [x] Every Bug Family has a dedicated hunt config
- [x] Every Safety invariant in brief §5 is defined and enabled in ≥1 cfg
- [x] Every model-checkable finding in brief §6.1 has a targeting mechanism
- [x] Trace spec has 1:1 action wrappers with post-state validation
- [x] Instrumentation spec maps every action to code locations
- [x] Extension variables all cite brief recommendations
- [x] MC.cfg has structural invariants; hunt cfgs have targeted invariants
- [x] State space pruning and symmetry reduction in MC.tla
- [x] Brief coverage audit complete and self-checked

---

## Known Limitations and Future Work

1. **Database Operations**: Persistent storage (sessions collection) modeled as atomic black-box. Real implementation has non-atomic multi-step DB operations.

2. **Sharding**: Single-node focus; sharding migration and cluster-wide consistency out of scope.

3. **Performance**: Specification prioritizes correctness over performance modeling. No latency or throughput analysis.

4. **External Services**: RPC, network failures, and service context interrupt mechanism (from server.cpp) treated as black-box.

5. **Memory Safety**: C++ unique_ptr lifetime and memory reclamation not modeled (mutex protects map, so not a concurrency source).

---

## References

- **Modeling Brief**: `modeling-brief.md` (input)
- **Spec Generation Methodology**: Specula skill `spec_generation/guide.md`
- **Base Spec Pattern**: `spec_generation/references/base-spec-methodology.md`
- **MC Spec Pattern**: `spec_generation/references/mc-spec-pattern.md`
- **Trace Spec Pattern**: `spec_generation/references/trace-spec-pattern.md`
- **Instrumentation Format**: `spec_generation/references/instrumentation-spec-format.md`

---

**Generated by**: TLA+ Spec Generation (Phase 1-4 complete)  
**Ready for**: Model checking, trace validation, harness generation
