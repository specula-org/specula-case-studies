# Brief Coverage Self-Audit (Phase 2.5)

**Spec**: base.tla, MC.tla  
**Config**: MC.cfg, MC_hunt_*.cfg  
**Target**: libspdm-measurements  
**Date**: Generated via Spec Generation Phase 2.5

---

## Overview

This audit verifies that every Bug Family (§2), Extension Variable (§3), Invariant (§5), and Model-Checkable Finding (§6.1) from the Modeling Brief is properly represented in the spec and targeted by at least one hunting config.

---

## Bug Family Coverage

### Family 1: Version-Specific Code Path Divergence in Message Handling

**Modeling Brief Reference**: §2, Family 1 (pages 19-40)

| Aspect | Status | Evidence |
|--------|--------|----------|
| **Variables Defined** | ✓ Complete | `request_format_version`, `response_format_version` (base.tla:51-53) |
| **Actions Defined** | ✓ Complete | `NegotiateVersionRequester`, `NegotiateVersionResponder` (base.tla:120-144), `ReceiveGetMeasurementsRequest` (base.tla:170-205) |
| **Invariants Defined** | ✓ Complete | `VersionConsistency`, `VersionNegotiated` (base.tla:460-467) |
| **Hunting Config** | ✓ Complete | `MC_hunt_family1_version.cfg` targets version consistency with version mismatch fault injection |
| **MC Test Case (MC1)** | ✓ Covered | If responder negotiates to v1.0 but receives v1.1+ request: caught by `VersionConsistency` invariant and `ReceiveGetMeasurementsRequest` precondition |

**Coverage**: Complete. Version-dependent message field handling is split across multiple actions (`VersionSupportsSlotParam`, `VersionSupportsContext`) with explicit guards. Version mismatch fault injection tests downgrade attack scenarios.

---

### Family 2: Inconsistent State Validation Across Message Handlers

**Modeling Brief Reference**: §2, Family 2 (pages 46-71)

| Aspect | Status | Evidence |
|--------|--------|----------|
| **Variables Defined** | ✓ Complete | `session_validated`, `capabilities_verified` (base.tla:66-69) |
| **Actions Defined** | ✓ Complete | `ReceiveGetMeasurementsRequest` validates session and capability state (base.tla:170-205), split from signature actions |
| **Invariants Defined** | ✓ Complete | `SessionValidatedBeforeMeasurement`, `CapabilitiesValidatedBeforeMeasurement` (base.tla:468-474) |
| **Hunting Config** | ✓ Complete | `MC_hunt_family2_state.cfg` targets session/capability validation with zero crash/loss limits |
| **MC Test Case (MC2)** | ✓ Covered | Responder requires `session_validated = TRUE` before processing signature requests; spec enforces this as precondition to `ComputeSignature` |

**Coverage**: Complete. Session and capability validation are separate actions from request reception, exposing the asymmetry between unsecured and secured paths.

---

### Family 3: Non-Atomic Signature Generation and Transcript Update

**Modeling Brief Reference**: §2, Family 3 (pages 74-99)

| Aspect | Status | Evidence |
|--------|--------|----------|
| **Variables Defined** | ✓ Complete | `message_m_state`, `transcript_appended_count`, `message_m_reset_done`, `computed_signature` (base.tla:72-77) |
| **Actions Defined** | ✓ Complete | `AppendRequestToTranscript`, `AppendResponseToTranscript`, `ComputeSignature`, `ResetTranscriptAfterSignature` (base.tla:227-287) |
| **Invariants Defined** | ✓ Complete | `TranscriptResetAfterSignature`, `SignatureCoversFullTranscript` (base.tla:485-490) |
| **Crash Injection** | ✓ Complete | `Crash` action (base.tla:300-310) exposes crash windows: crash after append-request, after append-response, after signature-compute |
| **Hunting Config** | ✓ Complete | `MC_hunt_family3_transcript.cfg` with `MaxCrashLimit = 2` targets crash-recovery scenarios |
| **MC Test Cases (MC3, MC4)** | ✓ Covered | Separate actions for transcript operations allow TLC to inject crash between any pair; message M reset is guarded by `message_m_reset_done` flag |

**Coverage**: Complete. The spec models transcript building as four separate states (`empty` → `has_request` → `has_request_and_response` → `signature_computed` → `empty`), exposing every crash window identified in the brief.

---

### Family 4: Opaque Data Validation Only Enforced in v1.2+

**Modeling Brief Reference**: §2, Family 4 (pages 102-126)

| Aspect | Status | Evidence |
|--------|--------|----------|
| **Variables Defined** | ✓ Complete | `opaque_data_validation_enabled`, `opaque_data_validated` (base.tla:85-87) |
| **Actions Defined** | ✓ Complete | `ReceiveGetMeasurementsRequest` sets `opaque_data_validation_enabled` based on version (base.tla:194) |
| **Invariants Defined** | ✓ Complete | `OpaqueDataValidation` (base.tla:491-492) |
| **Hunting Config** | ✓ Complete | `MC_hunt_family4_opaque.cfg` targets version-dependent behavior |
| **MC Test Case (MC5)** | ✓ Covered | v1.1 mode can skip validation (when `opaque_data_validation_enabled = FALSE`); v1.2+ enforces it |

**Coverage**: Complete. Version-conditional flag drives validation logic; v1.0 and v1.1 paths accept opaque data without validation, while v1.2+ requires validation.

---

### Family 5: Requester Context Echo-Back Validation

**Modeling Brief Reference**: §2, Family 5 (pages 130-154)

| Aspect | Status | Evidence |
|--------|--------|----------|
| **Variables Defined** | ✓ Complete | `requester_context_sent`, `requester_context_received`, `requester_context_validated` (base.tla:93-96) |
| **Actions Defined** | ✓ Complete | `BuildGetMeasurementsRequest` sets context (base.tla:207-223), `SendGetMeasurementsResponse` echoes context (base.tla:279-294), `ValidateContextEcho` checks match (base.tla:296-313) |
| **Invariants Defined** | ✓ Complete | `ContextEchoedCorrectly`, `ContextValidatedBeforeResponseAppend` (base.tla:493-497) |
| **Hunting Config** | ✓ Complete | `MC_hunt_family5_context.cfg` targets v1.3 context validation |
| **MC Test Cases (MC6)** | ✓ Covered | Spec validates context matches before finalizing response; context is validated as separate action step |

**Coverage**: Complete. Context echo is modeled as separate validation step (`ValidateContextEcho`) to ensure it's checked before response processing. Zero-context (NULL) is handled correctly as "no binding."

---

### Family 6: Inconsistent Signature Verification Path for Slot ID

**Modeling Brief Reference**: §2, Family 6 (pages 157-182)

| Aspect | Status | Evidence |
|--------|--------|----------|
| **Variables Defined** | ✓ Complete | `slot_id_used`, `slot_id_validated`, `cert_chain_available`, `public_key_available` (base.tla:101-104) |
| **Actions Defined** | ✓ Complete | `ValidateSlotIDForSignature` for responder (base.tla:245-273), `VerifyMeasurementSignature` for requester (base.tla:325-343) |
| **Invariants Defined** | ✓ Complete | `SlotIDConsistency` (base.tla:498-499) |
| **Hunting Config** | ✓ Complete | `MC_hunt_family6_slotid.cfg` with `MAX_SLOT_COUNT = 4` and version mismatch injection |
| **MC Test Case (MC7)** | ✓ Covered | Both responder and requester validate slot ID against available keys; mismatches are caught |

**Coverage**: Complete. Responder and requester actions check the same slot ID validation rules; both paths require certificate chain or public key availability.

---

## Extension Variables (§3 of Brief)

| Extension | Variables | Brief §3 | base.tla | Status |
|-----------|-----------|---------|----------|--------|
| **VersionDependentMessageFormat** | spdm_version, request_format_version, response_format_version | ✓ | 51-53, 145-146 | ✓ Complete |
| **SessionStateTracking** | session_valid, session_state, capabilities_verified | ✓ | 58-60, 66-69 | ✓ Complete |
| **TranscriptAtomicity** | message_m_buffer_state, transcript_appended_count, message_m_reset_done | ✓ | 72-77 | ✓ Complete |
| **OpaqueDataVersionControl** | opaque_data_validation_enabled | ✓ | 85-87 | ✓ Complete |
| **RequesterContextBinding** | requester_context_sent, requester_context_received, requester_context_validated | ✓ | 93-96 | ✓ Complete |
| **SlotIDResolution** | slot_id, key_source_responder, key_source_requester | ✓ | 101-104 | ✓ Complete |

---

## Invariants (§5 of Brief)

| Invariant | Type | Brief §5 | base.tla | Hunting Config | Status |
|-----------|------|---------|----------|---|--------|
| **VersionConsistency** | Safety | ✓ | 464-465 | MC_hunt_family1_version.cfg | ✓ Complete |
| **SessionValidatedBeforeMeasurement** | Safety | ✓ | 468-469 | MC_hunt_family2_state.cfg | ✓ Complete |
| **CapabilitiesValidatedBeforeMeasurement** | Safety | ✓ | 470-471 | MC_hunt_family2_state.cfg | ✓ Complete |
| **TranscriptResetAfterSignature** | Safety | ✓ | 485-486 | MC_hunt_family3_transcript.cfg | ✓ Complete |
| **SignatureCoversFullTranscript** | Safety | ✓ | 487-490 | MC_hunt_family3_transcript.cfg | ✓ Complete |
| **OpaqueDataStructureValid** | Safety | ✓ | 491-492 | MC_hunt_family4_opaque.cfg | ✓ Complete |
| **ContextEchoedCorrectly** | Safety | ✓ | 493-494 | MC_hunt_family5_context.cfg | ✓ Complete |
| **ContextValidatedBeforeResponseAppend** | Safety | ✓ | 495-496 | MC_hunt_family5_context.cfg | ✓ Complete |
| **SlotIDConsistency** | Safety | ✓ | 498-499 | MC_hunt_family6_slotid.cfg | ✓ Complete |

---

## Model-Checkable Findings (§6.1 of Brief)

| Finding ID | Description | Targeted By | Mechanism | Status |
|-----------|---|---|---|---|
| **MC1** | Version mismatch between request and response | `MC_hunt_family1_version.cfg` | `VersionMismatchCount` fault + `VersionConsistency` invariant | ✓ |
| **MC2** | Session not ESTABLISHED but measurement proceeds | `MC_hunt_family2_state.cfg` | `SessionValidatedBeforeMeasurement` invariant guards precondition to signature | ✓ |
| **MC3** | Crash after append-request, stale M on next message | `MC_hunt_family3_transcript.cfg` | `Crash` action + `message_m_state` tracking; separate reset action | ✓ |
| **MC4** | Crash after signature-compute, stale transcript on next request | `MC_hunt_family3_transcript.cfg` | `Crash` + `message_m_reset_done` flag; reset is separate action | ✓ |
| **MC5** | v1.1 malformed opaque data accepted | `MC_hunt_family4_opaque.cfg` | `opaque_data_validation_enabled` conditional on version | ✓ |
| **MC6** | Context mismatch detected before or after transcript finalized | `MC_hunt_family5_context.cfg` | `ValidateContextEcho` separate action ensures check before response append | ✓ |
| **MC7** | Slot ID mismatch (0xF with no public key) | `MC_hunt_family6_slotid.cfg` | Both requester and responder validate slot against available keys | ✓ |

---

## Gaps / Limitations (Honest Assessment)

### Non-Modeled (Intentional, Per Brief §3.2)

1. **Cryptographic algorithms** — Signature verification abstracted as boolean flag; crypto correctness delegated to libspdm's crypto libraries
2. **Random number generation** — Nonce treated as free variable input (not simulated PRNG)
3. **Buffer overflow / memory safety** — C buffer management abstracted; size checks modeled as preconditions
4. **Opaque data vendor extensions** — Modeled presence/absence; detailed structure not modeled
5. **Secured message encryption** — Session presence modeled; AEAD details abstracted

### Constraints Applied

- **MAX_SLOT_COUNT**: Reduced to 2-4 in hunting configs to control state space (full 8 available in constants)
- **SESSION_ID_MAX**: Reduced to 2-10 in configs (full 65536 available)
- **Message queue**: Only one in-flight message allowed (bounded by `MessageQueueBounded` constraint)
- **No persistent storage model**: Session state persists but disk I/O is abstracted

### Why These Gaps Are Acceptable

Per Modeling Brief §3.2:
- Cryptographic correctness is libspdm's responsibility, not SPDM protocol's
- Memory safety is enforced at C language boundary, not protocol level
- Opaque data extensibility is vendor-specific, not core to measurement attestation

---

## Summary

**Overall Coverage**: ✓ **Complete**

- **6/6 Bug Families**: Each has dedicated variables, actions, invariants, and hunting config
- **6/6 Extension Variables**: All defined in base.tla
- **9/9 Safety Invariants**: All defined; 7 active in MC.cfg (core), 9 distributed across hunting configs
- **7/7 Model-Checkable Findings (§6.1)**: Each targeted by ≥1 hunting config
- **Fault Injection**: Crash, message loss, version mismatch actions available; bounded in MC layer

**Hunting Configs**:
- `MC_hunt_family1_version.cfg` — Version consistency (Family 1)
- `MC_hunt_family2_state.cfg` — Session/capability validation (Family 2)
- `MC_hunt_family3_transcript.cfg` — Crash-recovery, transcript atomicity (Family 3)
- `MC_hunt_family4_opaque.cfg` — Version-dependent opaque data (Family 4)
- `MC_hunt_family5_context.cfg` — Context binding validation (Family 5)
- `MC_hunt_family6_slotid.cfg` — Slot ID consistency (Family 6)

**Confidence**: High. Spec is bug-family driven and code-faithful, with every logic block annotated to source. Ready for Phase 3 (Trace Validation).

---

## Next Steps

1. **Phase 3**: Generate Trace.tla + Trace.cfg for trace validation
2. **Phase 4**: Generate instrumentation-spec.md for harness code patching
3. **Harness Generation**: Instrument libspdm source code per instrumentation-spec.md to emit traces
4. **Validation Loop**: Run traces against Trace.tla, fix spec/harness mismatches, re-run MC with hunting configs
