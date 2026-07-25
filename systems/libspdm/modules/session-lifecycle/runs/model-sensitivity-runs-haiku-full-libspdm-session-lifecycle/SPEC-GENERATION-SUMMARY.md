# TLA+ Spec Generation Summary

**System**: libspdm-session-lifecycle  
**Category**: A (Distributed/Message-Passing)  
**Date**: 2026-06-04  
**Based on**: Phase 1 Modeling Brief

---

## Output Files

All specifications have been written to `/spec/` directory:

### Phase 1: Base Specification

- **`base.tla`** (17 KB)
  - Core protocol specification with bug-family driven extensions
  - 13 actions modeling session lifecycle, key updates, heartbeat, cleanup
  - 6 safety invariants (standard + extension invariants per bug family)
  - Annotations: every action traces to source code locations (file:line)
  
- **`base.cfg`** (351 B)
  - Configuration with SessionIds = {s1, s2}
  - Core invariants enabled for validation

### Phase 2: Model Checking Specification

- **`MC.tla`** (5.6 KB)
  - Wrapper extending base.tla with fault injection
  - Counter-bounded message loss action (MCDropMessage)
  - 5 extension invariants (one per bug family)
  - Temporal properties, symmetry reduction, state space pruning
  
- **`MC.cfg`** (817 B)
  - Standard convergence configuration
  - Core safety + structural invariants active
  - Extension invariants commented out (enabled in hunt cfgs)
  - Bounds: MaxMessageDrops=3, MaxMessageBuffer=10

### Phase 2: Hunting Configurations (Bug-Specific)

Five hunt configs, one per bug family:

- **`MC_hunt_family1.cfg`** — Key Update State Divergence
  - Target: `KeyDivergenceFreedom` invariant
  - Tight bounds: single session, MaxMessageDrops=5
  
- **`MC_hunt_family2.cfg`** — State Machine Guard Validation
  - Target: `StateTransitionValidity` invariant
  - Tight bounds: single session, MaxMessageDrops=4
  
- **`MC_hunt_family3.cfg`** — Regular vs Encapsulated Updates
  - Target: `RegularVsEncapConsistency` invariant
  - Tight bounds: single session, MaxMessageDrops=3
  
- **`MC_hunt_family4.cfg`** — Session End & Resource Cleanup
  - Target: `SessionCleanupConsistency` invariant
  - Tight bounds: single session, MaxMessageDrops=5
  
- **`MC_hunt_family5.cfg`** — Heartbeat Liveness vs Config
  - Target: `HeartbeatAvailability` invariant
  - Tight bounds: single session, MaxMessageDrops=2

### Phase 3: Trace Validation Specification

- **`Trace.tla`** (8.7 KB)
  - Trace replay spec validating implementation against base spec
  - 12 action wrappers (one per spec action)
  - Event matching, post-state validation, silent actions
  - TraceMatched temporal property for completion check
  
- **`Trace.cfg`** (364 B)
  - Configuration for trace validation
  - Safety invariants enabled
  - TraceMatched property required for completion

### Phase 4: Instrumentation Specification

- **`instrumentation-spec.md`** (12 KB)
  - Section 1: Trace event schema (event envelope, state/message fields)
  - Section 2: Action-to-code mapping (13 entries, all with file:line locations)
  - Section 3: Special considerations
    - State capture timing, message capture, key update state machine
    - Key activation order (Family 1), session cleanup asymmetry (Family 4)
    - Heartbeat configuration (Family 5), bootstrap state
  - Validation checklist for harness generation

### Phase 2.5: Self-Audit

- **`brief-coverage.md`** (9.2 KB)
  - Maps brief §2 bug families → hunt configs (5/5 coverage)
  - Maps brief §5 safety invariants → spec artifacts (6/6 coverage)
  - Maps brief §6.1 findings → reachable hunt configs (5/5 coverage)
  - Spec-trace validation readiness checklist
  - Gaps and justifications (no encapsulated actions, error paths, dynamic heartbeat)

---

## Modeling Decisions

### Bug Families Addressed

1. **Family 1: Key Update State Divergence** (HIGH priority)
   - Models multi-phase UPDATE (create before ACK) + VERIFY
   - Separate `requester_key_created` and `requester_key_active` to expose divergence window
   - Message loss injection during key update ACK

2. **Family 2: State Machine Guard Validation** (HIGH priority)
   - Models state machine: NONE → UPDATE_KEY/UPDATE_ALL_KEYS → VERIFY → NONE
   - Validates transitions via preconditions in HandleKeyUpdate
   - Targets invalid VERIFY before UPDATE, or UPDATE twice

3. **Family 3: Regular vs Encapsulated Updates** (MEDIUM priority)
   - Models both paths' key state outcomes
   - Checks convergence via `RegularVsEncapConsistency`
   - No separate actions; paths differ in test harness, not spec

4. **Family 4: Session End & Resource Cleanup** (MEDIUM priority)
   - Models asymmetric cleanup: `session_freed_by_requester` vs `session_freed_by_responder`
   - Message loss on END_SESSION_ACK can cause requester to free while responder doesn't
   - Tracks session state transition: IDLE → ESTABLISHED → ENDING → FREED

5. **Family 5: Heartbeat Liveness** (MEDIUM priority)
   - Models `heartbeat_enabled` as separate state variable
   - Enforces preconditions: heartbeat must be enabled AND session ESTABLISHED
   - Detects missing initialization or misconfiguration

### Key Design Choices

- **Action Granularity**: 13 actions split at semantic boundaries
  - InitiateKeyUpdate (requester creates key BEFORE ACK)
  - SendKeyUpdateVerify (requester activates key AFTER ACK)
  - HandleKeyUpdateVerify (responder activates key on VERIFY)
  - Separate send and receive for each message type

- **Message Passing**: Base spec uses message bag (DropMessage fault)
  - MC spec bounds message loss to explore packet loss scenarios
  - Trace spec validates order and content of actual trace events

- **State Machine**: Explicit prev_key_update_operation tracking
  - Enforces sequencing (UPDATE → VERIFY)
  - Detects invalid transitions (UPDATE twice, VERIFY before UPDATE)

- **Session Cleanup**: Explicit freed_by_requester/responder flags
  - Detects asymmetric cleanup (one side freed, other didn't)
  - Validates idempotence of END_SESSION

---

## Verification Workflow

### Step 1: Convergence (MC.cfg)

```bash
tlc MC.cfg
```

- Establishes baseline: spec is internally consistent
- All core safety invariants should pass
- Expected outcome: no deadlock, converges

### Step 2: Bug Hunting (MC_hunt_*.cfg)

After convergence, run each hunt config:

```bash
tlc MC_hunt_family1.cfg
tlc MC_hunt_family2.cfg
...
```

- Each config targets one bug family
- Tight bounds ensure state space is manageable
- Counterexample path shows how fault injection triggers bug (if found)

### Step 3: Trace Validation (Trace.cfg)

After instrumentation:

```bash
tlc Trace.cfg
```

- Validates real implementation traces against spec
- Checks TraceMatched completion property
- Post-state validation confirms spec matches implementation

---

## Next Steps

1. **Harness Generation (Phase 2.5)**
   - Use `instrumentation-spec.md` to instrument source code
   - Insert trace event emissions at specified code locations
   - Compile instrumented libspdm; run test suite to collect traces

2. **Trace Validation (Phase 3)**
   - Convert collected NDJSON traces to JSON format
   - Run Trace.tla against real traces
   - Resolve any post-state mismatches between spec and impl

3. **Model Checking (Phase 2)**
   - Run MC.cfg for convergence
   - Run each MC_hunt_*.cfg to search for bugs
   - Analyze counterexample if invariant is violated

---

## Artifact Locations

```
spec/
├── base.tla              # Core protocol
├── base.cfg              # Base configuration
├── MC.tla                # Model checking wrapper
├── MC.cfg                # Convergence config
├── MC_hunt_family1.cfg   # Family 1 hunting
├── MC_hunt_family2.cfg   # Family 2 hunting
├── MC_hunt_family3.cfg   # Family 3 hunting
├── MC_hunt_family4.cfg   # Family 4 hunting
├── MC_hunt_family5.cfg   # Family 5 hunting
├── Trace.tla             # Trace validation spec
├── Trace.cfg             # Trace validation config
└── instrumentation-spec.md  # Code-to-spec mapping
```

All files ready for Phase 2.5 (harness generation) and Phase 3 (validation).

