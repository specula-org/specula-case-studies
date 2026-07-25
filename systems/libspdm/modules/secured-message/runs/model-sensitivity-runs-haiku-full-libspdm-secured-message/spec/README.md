# libspdm-secured-message TLA+ Specification

## Overview

This directory contains complete TLA+ specifications for formal verification of the libspdm-secured-message library, based on the modeling brief (`../modeling-brief.md`).

**System**: libspdm-secured-message (SPDM DSP0277 Secured Messages)  
**Category**: A (Distributed/Message-Passing)  
**Bug Families Modeled**: 5 (Families 1-5 from brief)

---

## Files

### Core Specification

| File | Purpose |
|---|---|
| **base.tla** | Base specification with all bug-family extensions and invariants |
| **base.cfg** | Configuration for base spec (constants + invariants) |

### Model Checking

| File | Purpose |
|---|---|
| **MC.tla** | Model checking wrapper with counter-bounded fault injection |
| **MC.cfg** | Standard MC configuration (safety + structural invariants enabled, bug-family invariants commented out) |
| **MC_hunt_family1.cfg** | Hunting config for Family 1 (endianness determination race) |
| **MC_hunt_family2.cfg** | Hunting config for Family 2 (key update desync) |
| **MC_hunt_family3.cfg** | Hunting config for Family 3 (session state transition non-atomicity) |
| **MC_hunt_family4.cfg** | Hunting config for Family 4 (sequence number overflow) |

### Trace Validation

| File | Purpose |
|---|---|
| **Trace.tla** | Trace validation wrapper (replays recorded execution) |
| **Trace.cfg** | Trace validation configuration |

### Instrumentation & Documentation

| File | Purpose |
|---|---|
| **instrumentation-spec.md** | Maps TLA+ actions to source code locations for harness generation |
| **brief-coverage.md** | Self-audit of spec vs. modeling brief (verification checklist) |
| **README.md** | This file |

---

## Quick Start

### 1. Validate Base Spec (Convergence Check)

Run the base spec to verify it reaches a fixed point:

```bash
tlc base -config base.cfg -depth 50
```

This checks that the spec is consistent and invariants are reachable without fault injection.

### 2. Run Standard Model Checking

Run MC spec with standard invariants to explore the state space:

```bash
tlc MC -config MC.cfg -depth 100
```

This includes base safety and structural invariants; bug-detection invariants are commented out to avoid noise during convergence.

### 3. Hunt for Bugs (Family-Specific)

Run one hunting config at a time to search for bugs in specific families:

```bash
tlc MC -config MC_hunt_family1.cfg -depth 100
tlc MC -config MC_hunt_family2.cfg -depth 100
tlc MC -config MC_hunt_family3.cfg -depth 100
tlc MC -config MC_hunt_family4.cfg -depth 100
```

Each hunting config:
- Uses tight bounds (irrelevant actions capped at 0-1)
- Enables only the family-specific invariants
- Includes fault injection for the target bug mechanism

**Expected results**: If bugs exist in the implementation, one of these configs should violate its invariants.

### 4. Validate Against Traces

After instrumenting the source code (using `instrumentation-spec.md`), collect execution traces and validate them:

```bash
tlc Trace -config Trace.cfg -IOEnv JSON=../traces/trace.ndjson
```

This replays the recorded execution and verifies consistency with the spec.

---

## Architecture

### Base Spec (base.tla)

**Variables** (organized by extension family):

- **Core Protocol**: `session_state`, `request_seq_num`, `response_seq_num`, `messages`, `msg_history`
- **Family 1 (Endianness)**: `seq_num_endian`, `endian_determined_at`
- **Family 2 (Key Update)**: `key_update_phase`, `backup_valid`, `application_secret`, `application_secret_backup`
- **Family 3 (State Transition)**: `secrets_cleared`
- **Family 4 (Overflow)**: (implicit in `request_seq_num`, `response_seq_num`, `session_state` transitions)
- **Family 5 (IV)**: (implicit in `EncodeSecuredMessage`, `AttemptDecodeFirstEndian` actions)

**Actions**:

- **Initialization**: `InitializeSession`, `TransitionToEstablished`
- **Encoding/Decoding**: `EncodeSecuredMessage`, `AttemptDecodeFirstEndian`
- **Key Management**: `InitiateKeyUpdate`, `ConfirmKeyUpdate`, `RollbackToBackupKey`
- **State Management**: `CompleteZeroization`, `CloseSessionAtMaxSeqNum`

**Invariants** (9 total):

- `EndianStableAfterDetermination` (Family 1)
- `KeyUpdateSynchronized`, `BackupValidConsistency`, `NoRollbackAfterConfirm` (Family 2)
- `SessionStateTransitionLinear`, `SecretsZeroizedAfterTransition` (Family 3)
- `SequenceNumberBounded`, `SequenceNumberOverflowPolicy` (Family 4)
- `IVDeterministic` (Family 5)

### Model Checking Spec (MC.tla)

**Fault Injection Actions** (4 total):

- `MCBugEndianWrongChoice` → Force wrong endianness at seq=1 (Family 1)
- `MCBugKeyUpdateDesync` → Block responder from following key update (Family 2)
- `MCBugEncodeBeforeZeroization` → Allow encoding with uncleared secrets (Family 3)
- `MCBugSequenceOverflow` → Jump sequence number to boundary (Family 4)

**Counter Variables**: `faultCounters` tracks firing counts for each fault action.

### Trace Spec (Trace.tla)

**Event-driven model**: Reads JSON trace file, matches events to spec actions, validates post-state.

**Key variables**:
- `l` — cursor into trace (advances from 1 to Len(TraceLog))
- `TraceLog` — loaded from JSON file

**Action wrappers**: Each spec action has a corresponding trace wrapper that:
1. Checks next trace event matches
2. Fires the base spec action
3. Validates post-state against captured fields
4. Advances cursor

**Silent actions**: Minimal set for initialization; most state changes are captured in trace.

---

## Constants & Configuration

### Standard Constants (base.cfg, MC.cfg)

```tla
MaxSeqNum = 3
MaxKeyUpdateOps = 2
NumSessions = 2
SessionIDs = {sid1, sid2}
Roles = {requester, responder}
```

### Model Checking Constants (MC.cfg, MC_hunt_*.cfg)

```tla
MaxEndianSwaps = 2
MaxKeyUpdateInitiations = 2
MaxMessageLosses = 1
MaxSequenceJumps = 1
```

Hunting configs tighten these bounds to reduce irrelevant branches:

| Family | Hunt Config | Tight Bounds |
|---|---|---|
| 1 | MC_hunt_family1.cfg | MaxEndianSwaps=2, others=0 |
| 2 | MC_hunt_family2.cfg | MaxKeyUpdateInitiations=2, others=0 |
| 3 | MC_hunt_family3.cfg | All fault bounds=0 (focus on state transition logic) |
| 4 | MC_hunt_family4.cfg | MaxSequenceJumps=2, others=0 |

---

## Invariants & Properties

### Safety Invariants (checked at every state)

All 9 invariants in base.cfg are safety properties (prefix-closed):

- If they are true in the initial state and after every action, they are always true.
- Violation indicates a bug in the implementation or spec.

### Temporal Properties

**Trace validation** (`Trace.cfg`) includes:

```tla
PROPERTIES TraceMatched
```

This checks that the entire trace is consumed (`<>(l > Len(TraceLog))`).

---

## Common Tasks

### Adjust State Space Size

If TLC runs out of memory or takes too long:

1. Reduce `MaxSeqNum` in base.cfg / MC.cfg (e.g., from 3 to 2)
2. Reduce `NumSessions` (e.g., from 2 to 1, though this may miss multi-session bugs)
3. Reduce fault bounds in MC.cfg

### Focus on One Family

Create a custom `.cfg` with:
- Only the family's variables as CONSTANTS
- Only that family's invariants in INVARIANT declarations
- Tight bounds on that family's fault actions

### Debug an Invariant Violation

1. Run `tlc MC -config MC.cfg -debugger` to step through violating trace
2. Check the brief's description of what the invariant protects
3. Compare spec action preconditions/effects with code implementation
4. Either fix the spec or the implementation (or code is correct and spec guard is too weak)

### Add New Bug Family

If a 6th bug family is identified post-spec:

1. Add variables to base.tla (cite the family number)
2. Add actions or guards to expose the bug
3. Add invariants to detect it
4. Add MCBugXxx fault injection action
5. Create MC_hunt_family6.cfg
6. Update brief-coverage.md

---

## References

- **Modeling Brief**: `../modeling-brief.md` (bug families, invariants, findings)
- **Instrumentation Spec**: `instrumentation-spec.md` (code locations, trace event schema)
- **Coverage Audit**: `brief-coverage.md` (mapping brief → spec → configs)
- **Source Code**: `../artifact/libspdm/library/spdm_secured_message_lib/`

---

## Contact & Troubleshooting

For questions on spec design, see:
- Base spec comments (every action annotated with source lines)
- Instrumentation spec for code-to-spec mapping
- Brief-coverage audit for verification of modeling decisions

For TLC issues:
- Check TLC output for deadlock or state limit exceeded
- Run with `-depth N` to limit search depth
- Run with `-seed <N>` to reproduce violations
- See TLC manual for heap / GC tuning

---

## Next Steps (Harness Generation & Trace Validation)

1. **Phase 2.5 (Harness Generation)**:
   - Use `instrumentation-spec.md` to instrument source code
   - Generate test scenarios that exercise all spec actions
   - Collect execution traces as JSON files

2. **Phase 3 (Trace Validation)**:
   - Run `tlc Trace -config Trace.cfg` with collected traces
   - Verify spec consistency with implementation
   - Debug any post-state validation failures

3. **Phase 4 (Verification Loop)**:
   - Iterate between MC spec and trace validation
   - Refine spec based on implementation behavior
   - Ensure spec faithfully models the system

---

**Generated**: 2026-06-04  
**Spec Language**: TLA+ (v2)
