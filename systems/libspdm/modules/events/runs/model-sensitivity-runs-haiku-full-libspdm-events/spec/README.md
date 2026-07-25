# TLA+ Specification for libspdm-events

## Overview

This directory contains the complete formal specification of the SPDM 1.3 event subscription subsystem from libspdm, generated from the modeling brief in Phase 1.

**System**: libspdm event subscription protocol  
**Category**: Category A (Distributed/Message-Passing)  
**Status**: Phase 2 Complete (Spec Generation)  

---

## Files

### Core Specification

| File | Purpose | Status |
|---|---|---|
| `base.tla` | Core protocol spec with bug-family extensions | ✅ 16 KB |
| `base.cfg` | Constants for base spec | ✅ 475 B |

### Model Checking (Phase 2)

| File | Purpose | Status |
|---|---|---|
| `MC.tla` | Counter-bounded fault injection wrapper | ✅ 8.9 KB |
| `MC.cfg` | Standard MC configuration (for convergence) | ✅ 1.1 KB |
| `MC_hunt_family1_path_divergence.cfg` | Hunting config for sequential vs non-sequential paths | ✅ 1.3 KB |
| `MC_hunt_family2_integer_overflow.cfg` | Hunting config for size accumulation overflow | ✅ 1.3 KB |
| `MC_hunt_family3_session_state_gap.cfg` | Hunting config for transient session state changes | ✅ 1.4 KB |
| `MC_hunt_family4_dmtf_validation.cfg` | Hunting config for event type validation | ✅ 1.4 KB |
| `MC_hunt_family5_subscription_state.cfg` | Hunting config for subscription state divergence | ✅ 1.5 KB |

### Trace Validation (Phase 3)

| File | Purpose | Status |
|---|---|---|
| `Trace.tla` | Trace validation spec with action wrappers | ✅ 6.4 KB |
| `Trace.cfg` | Trace validation configuration | ✅ 793 B |

### Instrumentation & Documentation (Phase 4)

| File | Purpose | Status |
|---|---|---|
| `instrumentation-spec.md` | Action-to-code mapping for trace collection | ✅ 12 KB |
| `brief-coverage.md` | Phase 2.5 coverage self-audit | ✅ 7.6 KB |

---

## Key Design Decisions

### Bug-Family Driven Extensions

All extensions trace back to specific bug families identified in the modeling brief:

| Family | Extension Variables | Key Invariant |
|--------|---|---|
| **Family 1**: Path Divergence | `events_sequential`, `event_id_map` | `SequentialOrGapFree` |
| **Family 2**: Integer Overflow | `msg_size_accum` | `SizeAccumulationBounded` |
| **Family 3**: Session State Gap | `session_state[sid]` + MCSessionClosureFault | `EventsInEstablishedSession` |
| **Family 4**: DMTF Validation | `event_validated[idx]` | `DMTFEventsValidated` |
| **Family 5**: Subscription Delegation | `integrator_subscribed_types`, `subscribed_types` | `SubscriptionConsistency` |

### Action Splitting

Actions are split where code paths diverge:

- **RespSendEventAckSeq** (lines 222-227): Sequential path, simple validation
- **RespSendEventAckNonSeq** (lines 228-244): Non-sequential path, O(n²) search

This granularity enables TLC to find path-specific bugs.

### Fault Injection

Five fault-injection actions, each bounded by a counter:

1. **MCSessionClosureFault** (Family 3): Close session during callback window
2. **MCSizeOverflowFault** (Family 2): Force accumulated size to exceed MaxMessageSize
3. **MCForceSequentialPath** (Family 1): Bias path selection
4. **MCForceNonSequentialPath** (Family 1): Bias path selection
5. **MCMessageLoss** + **MCTimeout** (background faults)

Each hunting config enables specific faults and tightens irrelevant bounds.

---

## Coverage Summary (Phase 2.5 Audit)

✅ **All 5 bug families covered** by dedicated hunting configs  
✅ **All 5 Safety invariants defined and enabled** in at least one hunt cfg  
✅ **All 5 MC-checkable findings (§6.1) reachable** via fault injection  
✅ **All 6 extension variables actively used** in specs and configs  
✅ **Trace spec complete** with 7 action wrappers and strong post-state validation  
✅ **Instrumentation spec detailed** with precise code locations and field mappings  

---

## Next Steps

### Phase 2: Model Checking

Run TLC on the hunting configs to find violations:

```bash
# Standard convergence check (ensure spec is well-formed)
tlc MC.cfg

# Hunt for Family 1 bugs (path divergence)
tlc MC_hunt_family1_path_divergence.cfg

# Hunt for Family 2 bugs (integer overflow)
tlc MC_hunt_family2_integer_overflow.cfg

# Hunt for Family 3 bugs (session state races)
tlc MC_hunt_family3_session_state_gap.cfg

# Hunt for Family 4 bugs (validation gaps)
tlc MC_hunt_family4_dmtf_validation.cfg

# Hunt for Family 5 bugs (subscription divergence)
tlc MC_hunt_family5_subscription_state.cfg
```

Expected outputs:
- Invariant violations indicate bugs in the implementation
- No violations indicate the implementation matches the spec

### Phase 3: Trace Validation

1. **Instrument the system** using `instrumentation-spec.md` to emit NDJSON traces
2. **Collect traces** from integration tests covering each bug family
3. **Run trace validation**:
   ```bash
   tlc Trace.cfg -DJson=<path-to-trace.ndjson>
   ```

4. **Fix mismatches** between spec and implementation

### Phase 4: Remediation

Once model checking or trace validation finds a bug:
1. Review the counterexample
2. Determine root cause in the implementation (typically in libspdm_rsp_event_ack.c)
3. Apply fix and re-run validation
4. Confirm no regressions

---

## Spec Annotations

Every action and logic block is annotated with source code references (file:line) per the methodology. For example:

```tla
\* libspdm_rsp_event_ack.c:202-210: gap-free validation logic
ValidEventSequence(ids, is_seq) == ...

\* libspdm_rsp_event_ack.c:93-98: session state checked once at entry
RespSubscribeEventTypesAck(sid) == ...
```

This enables cross-referencing between spec and implementation.

---

## Common Questions

**Q: Why are there two SEND_EVENT_ACK actions?**  
A: libspdm_rsp_event_ack.c has two code paths (lines 222-227 vs 228-244) with different logic. Splitting preserves path divergence so TLC can find path-specific bugs.

**Q: Why is session closure non-deterministic?**  
A: Family 3 identifies a race condition where session state can change between validation (line 93) and callback (line 236). Model checking must explore this interleaving.

**Q: What if Trace.tla finds a mismatch?**  
A: Trace validation failures indicate the implementation behaves differently than the spec predicts. Debug steps:
  1. Review the trace JSON to understand what happened
  2. Check if spec variables are initialized correctly (TraceInit)
  3. Verify instrumentation is capturing state at the right granularity
  4. Fix the spec or the harness

**Q: Can I run MC without hunting configs?**  
A: Yes, `MC.cfg` provides a standard configuration for convergence testing. Hunting configs are only for bug-family-specific searches after the spec is stable.

---

## Files Generated by Phase

| Phase | Output | Location |
|---|---|---|
| Phase 1 (Code Analysis) | `modeling-brief.md` | `../modeling-brief.md` |
| **Phase 2 (Spec Generation)** | **base.tla, MC.tla, Trace.tla, instrumentation-spec.md** | **`./` (this directory)** |
| Phase 2.5 (Harness Generation) | Instrumented code, trace harness | `../harness/` |
| Phase 3 (Validation) | Trace files, MC results | `../traces/`, `../results/` |

---

## References

- **Modeling Brief**: ../modeling-brief.md
- **Spec Generation Guide**: /home/ubuntu/Specula/.claude/skills/spec_generation/guide.md
- **Base Spec Methodology**: /home/ubuntu/Specula/.claude/skills/spec_generation/references/base-spec-methodology.md
- **MC Spec Pattern**: /home/ubuntu/Specula/.claude/skills/spec_generation/references/mc-spec-pattern.md
- **Trace Spec Pattern**: /home/ubuntu/Specula/.claude/skills/spec_generation/references/trace-spec-pattern.md
- **Instrumentation Format**: /home/ubuntu/Specula/.claude/skills/spec_generation/references/instrumentation-spec-format.md

---

## Authors & Timeline

**Generated**: 2026-06-04  
**System**: libspdm-events (SPDM 1.3 event subscription)  
**Target**: libspdm C implementation  

