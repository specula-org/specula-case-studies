# TLA+ Specifications for libspdm-mut-auth-encap

This directory contains complete TLA+ specifications for formal verification of the SPDM encapsulated mutual authentication protocol implementation in libspdm.

---

## File Structure

### Phase 1: Base Specification

- **`base.tla`** (15 KB)
  - Core protocol specification with bug-family-driven extensions
  - Defines 6 categories of state variables, 4 key actions, 6 invariants
  - Targets all 6 bug families from the modeling brief
  - Fully annotated with source code line references

- **`base.cfg`** (844 B)
  - Constant definitions and invariant declarations for base spec
  - Standard safety invariants enabled for initial validation

### Phase 2: Model Checking

- **`MC.tla`** (9.0 KB)
  - Wraps base spec with counter-bounded fault injection
  - 6 fault injection actions targeting each bug family:
    - `MCBufferResetFailure` (Family 4)
    - `MCOpaqueDataGenerationFailure` (Family 6)
    - `MCSignatureVerificationFailure` (Family 1)
    - `MCVersionMismatch` (Family 2)
    - `MCMessageAppendFailure` (Family 5)
    - `MCBufferUnderflow` (Family 3)

- **`MC.cfg`** (1.3 KB)
  - Model checking configuration with tuning constants
  - Tight bounds sufficient for spec validation:
    - MaxBufferResetFailures: 2
    - MaxSignatureFailures: 2
    - MaxVersionMismatches: 1
    - MaxMessageAppendFailures: 2
    - MaxBufferUnderflows: 1

- **`MC_hunt_Family*.cfg`** (6 files)
  - Dedicated hunting configs for each bug family
  - Tight bounds (1-3) on target mechanism; 0-1 on unrelated faults
  - Target invariants enabled (others disabled for state space control)
  - Files:
    - `MC_hunt_Family1.cfg` — Non-Atomic State Transitions
    - `MC_hunt_Family2.cfg` — Version-Dependent Field Handling
    - `MC_hunt_Family3.cfg` — Buffer Arithmetic Overflow
    - `MC_hunt_Family4.cfg` — Buffer Reset Race Condition
    - `MC_hunt_Family5.cfg` — Signature Before Transcript Complete
    - `MC_hunt_Family6.cfg` — Opaque Data Generation Failure

### Phase 2.5: Self-Audit

- **`brief-coverage.md`** (8.1 KB)
  - Mandatory self-audit mapping brief to spec
  - Verifies all 6 bug families have hunt configs
  - Verifies all 6 invariants defined and enabled
  - Verifies all 5 model-checkable findings reachable
  - **Status**: ✓ Complete coverage

### Phase 3: Trace Validation

- **`Trace.tla`** (6.5 KB)
  - Category A trace validation spec
  - Replays NDJSON traces against base spec
  - Single cursor `l` walks through trace events
  - 4 action wrappers with post-state validation
  - Temporal property `TraceMatched` ensures all trace events consumed

- **`Trace.cfg`** (870 B)
  - Trace validation configuration
  - Includes `PROPERTIES TraceMatched` for completion checking
  - Validates core safety invariants on real execution traces

### Phase 4: Instrumentation

- **`instrumentation-spec.md`** (15 KB)
  - Mapping from TLA+ actions to source code locations
  - **Section 1**: Trace event schema and field definitions
  - **Section 2**: Action-to-code mapping (4 main actions + state transitions)
  - **Section 3**: Special considerations for each bug family
  - **Section 4**: Trace event examples (success case + underflow bug)
  - **Section 5**: Bootstrap and initial state handling
  - **Section 6**: Temporal constraints and dependencies
  - **Section 7**: Validation checkpoints

---

## Bug Family Coverage

| Family | Name | Actions | Invariants | Hunt Config |
|--------|------|---------|-----------|-------------|
| **1** | Non-Atomic State Transitions | `TransitionToAuthenticated`, `FailedStateTransition` | `AuthenticatedImplesVerified`, `NoPartialStateTransition` | ✓ Family1 |
| **2** | Version-Dependent Field Handling | `RequesterGetEncapResponseChallengeAuth`, `ProcessEncapResponseChallengeAuth` | `VersionConsistency`, `RequestContextEcho` | ✓ Family2 |
| **3** | Buffer Arithmetic Overflow | `RequesterGetEncapResponseChallengeAuth` | `BufferBoundsRespected` | ✓ Family3 |
| **4** | Buffer Reset Race Condition | `ResponderGetEncapRequestChallenge`, `RequesterGetEncapResponseChallengeAuth` | `TypeOK` | ✓ Family4 |
| **5** | Signature Before Transcript | `ProcessEncapResponseChallengeAuth` | `TranscriptBeforeSignature` | ✓ Family5 |
| **6** | Opaque Data Callback Failure | `RequesterGetEncapResponseChallengeAuth` | `TypeOK` | ✓ Family6 |

---

## Invariants

### Safety Invariants (All Enabled)

1. **`TypeOK`** — All state variables have correct types
2. **`AuthenticatedImplesVerified`** — If authenticated, signature verified (Family 1)
3. **`NoPartialStateTransition`** — State changes are atomic (Family 1)

### Extension Invariants (Commented in MC.cfg; Enabled in Hunt Configs)

4. **`VersionConsistency`** — All messages use negotiated version (Family 2)
5. **`RequestContextEcho`** — Request context matches in v1.3+ (Family 2)
6. **`BufferBoundsRespected`** — Opaque data does not overflow buffer (Family 3)
7. **`TranscriptBeforeSignature`** — Signature only after full transcript (Family 5)

---

## Action Specification

### 1. ResponderGetEncapRequestChallenge
**Source**: `libspdm_rsp_encap_challenge.c:12-78`
- Initiates challenge request from responder side
- Targets: Family 4 (buffer reset)
- Key state: version negotiation, buffer reset status

### 2. RequesterGetEncapResponseChallengeAuth
**Source**: `libspdm_req_encap_challenge_auth.c:12-237`
- Generates challenge auth response on requester side
- Targets: Family 2 (version), Family 3 (buffer arithmetic), Family 6 (opaque data)
- Key state: opaque_data_size calculation, message transcript appends, signature generation

### 3. ProcessEncapResponseChallengeAuth
**Source**: `libspdm_rsp_encap_challenge.c:80-268`
- Processes and verifies response on responder side
- Targets: Family 1 (state transition), Family 2 (version), Family 5 (transcript)
- Key state: signature verification, request context echo validation, state transition

### 4. TransitionToAuthenticated
**Source**: `libspdm_rsp_encap_challenge.c:263`
- Completes non-atomic state transition to AUTHENTICATED
- Targets: Family 1 (non-atomic transition atomicity)
- Key state: final connection state update

---

## Recommended Next Steps

### 1. Spec Validation
```bash
tlc -config MC.cfg -depth 50 MC
```

Expected outcome: No invariant violations with default bounds.

### 2. Bug Hunting (Per-Family)
```bash
tlc -config MC_hunt_Family1.cfg -depth 100 MC
tlc -config MC_hunt_Family2.cfg -depth 100 MC
tlc -config MC_hunt_Family3.cfg -depth 100 MC
tlc -config MC_hunt_Family4.cfg -depth 100 MC
tlc -config MC_hunt_Family5.cfg -depth 100 MC
tlc -config MC_hunt_Family6.cfg -depth 100 MC
```

Expected outcome: Hunting configs may find invariant violations corresponding to bug mechanisms.

### 3. Trace Validation (After Harness Instrumentation)
```bash
tlc -config Trace.cfg -depth 500 Trace
```

Expected outcome: All trace events consumed (TraceMatched property holds).

---

## Model Statistics

| Metric | Value |
|--------|-------|
| Base spec state variables | 19 |
| MC spec counter variables | 7 |
| Trace spec cursor variable | 1 |
| Actions (deterministic) | 5 |
| Fault injection actions | 6 |
| Safety invariants | 7 |
| Temporal properties | 1 (TraceMatched) |
| Hunt configs | 6 |

---

## Design Notes

### Variable Grouping for UNCHANGED Clauses

Variables organized by category:
- **Protocol state**: requester_state, responder_state, connection_state
- **Message state**: message_transcript, transcript_complete, last_request, last_response
- **Version state**: protocol_version, req_context, req_context_echo_match
- **Verification state**: signature_verified, pending_state_transition
- **Buffer state**: response_buffer_size, opaque_data_offset, opaque_data_size, hash_size, signature_size
- **Error state**: buffer_reset_status

### Action Granularity

Actions are split at code path divergence points:
- `RequesterGetEncapResponseChallengeAuth` vs `ProcessEncapResponseChallengeAuth` separate requester and responder roles
- `TransitionToAuthenticated` vs `FailedStateTransition` separate success and failure paths
- Opaque data calculations modeled in action preconditions to expose arithmetic errors

### Fault Injection Bounds

Counter limits chosen to:
- Explore multiple fault interleavings (2-3 occurrences per fault)
- Keep state space manageable (<1M states per hunt config)
- Ensure all 6 bug mechanisms are reachable

---

## Critical Implementation Details Modeled

1. **Family 3 - Buffer Underflow** (Line 169-173 of req_encap_challenge_auth.c)
   ```c
   opaque_data_size = *response_size - (sizeof(...) + hash_size + ... + signature_size)
   ```
   Spec models this as an arithmetic expression that may underflow. The calculation
   result is captured directly (including wrapping on underflow).

2. **Family 5 - Incomplete Transcript** (Lines 214-228 of req_encap_challenge_auth.c)
   - Two sequential message appends with no transactional guarantee
   - If first succeeds and second fails, transcript is incomplete
   - Signature verification should not proceed

3. **Family 1 - Non-Atomic State Transition** (Line 263 of rsp_encap_challenge.c)
   - State is set unconditionally after signature verification
   - No atomic guarantee that verification+state-change are together
   - Interleaving could set state before verification completes

---

## Reference

- **Source Code**: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-mut-auth-encap/artifact/libspdm`
- **Modeling Brief**: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-mut-auth-encap/modeling-brief.md`
- **SPDM Specification**: DSP0274 (versions 1.1-1.4)

---

Generated by spec-generation skill (Phase 1-4)
Completion date: 2026-06-04
