# Brief Coverage Audit (Phase 2.5)

This document audits the TLA+ specification against the modeling brief requirements to verify that all bug families, safety invariants, and model-checkable findings are properly covered in the spec and hunting configs.

## Audit Date

Generated as part of Phase 2 spec generation.

---

## §2 Bug Families Coverage

| Family | Name | Hunt Config | Status | Notes |
|--------|------|-------------|--------|-------|
| 1 | Path Inconsistency in Opaque Data Validation | `MC_hunt_family1.cfg` | ✓ Covered | Opaque_length asymmetry between requester (explicit check) and responder (implicit check). Targets `OpaqueLengthConsistency` invariant. |
| 2 | Session ID Resource Leak on Allocation → Error | `MC_hunt_family2.cfg` | ✓ Covered | Session ID allocated but not freed on error paths (lines 199-235 in libspdm_req_psk_exchange.c). Targets `SessionIDAllocationFreeing` invariant. |
| 3 | Opaque Data Handling and Secured Message Version | `MC_hunt_family3.cfg` | ✓ Covered | Responder opaque data optional; requester expects version data. Asymmetry in version negotiation. Targets `SecuredMessageVersionAgreement` invariant. |
| 4 | Context Length Validation and Boundary Checks | `MC_hunt_family4.cfg` | ✓ Covered | No explicit upper-bound check on context_length in responder. Targets `ContextLengthBounds` invariant. |
| 5 | Handshake State Validation and Session Lifecycle | `MC_hunt_family5.cfg` | ✓ Covered | State checks missing on PSK_EXCHANGE requester side; state machine validation. Targets `PSKExchangeNoActiveSession`, `PSKFinishHandshakingState`, `HandshakeTranscriptIntegrity` invariants. |

## §5 Proposed Safety Invariants Coverage

| Invariant Name | Defined | Wired in MC.tla | Enabled in Hunt Cfg(s) | Status |
|---|---|---|---|---|
| OpaqueLengthConsistency | base.tla | MC.cfg | MC_hunt_family1.cfg | ✓ Covered |
| SessionIDAllocationFreeing | base.tla | MC.cfg | MC_hunt_family2.cfg | ✓ Covered |
| SecuredMessageVersionAgreement | base.tla | MC.cfg | MC_hunt_family3.cfg | ✓ Covered |
| PSKExchangeNoActiveSession | base.tla | MC.cfg | MC_hunt_family5.cfg | ✓ Covered |
| PSKFinishHandshakingState | base.tla | MC.cfg | MC_hunt_family5.cfg | ✓ Covered |
| ContextLengthBounds | base.tla | MC.cfg | MC_hunt_family4.cfg | ✓ Covered |
| HandshakeTranscriptIntegrity | base.tla | MC.cfg | MC_hunt_family5.cfg | ✓ Covered |

## §6.1 Model-Checkable Findings Coverage

| ID | Description | Finding | Hunt Cfg | Trigger Mechanism | Expected Violation |
|----|---|---|---|---|---|
| MC1 | Oversized opaque_length on responder accept | "Can a responder accept opaque_length > MAX?" | MC_hunt_family1.cfg | MCOversizeOpaqueLength action injects oversized opaque_data | OpaqueLengthConsistency |
| MC2 | Session ID leak on error path | "Is allocated ID freed before return?" | MC_hunt_family2.cfg | MCSessionIdLeak action forces error without deallocation | SessionIDAllocationFreeing |
| MC3 | Version mismatch on empty opaque data | "Can responder send empty opaque when version expected?" | MC_hunt_family3.cfg | MCVersionMismatch action sends PSK_EXCHANGE_RSP without version | SecuredMessageVersionAgreement |
| MC4 | Duplicate PSK_EXCHANGE on established session | "Can PSK_EXCHANGE be initiated on active session?" | MC_hunt_family5.cfg | MCStateMachineViolation action sends PSK_EXCHANGE when not IDLE | PSKExchangeNoActiveSession |
| MC5 | Context_length overshoot on responder | "Is context_length caught by requester validation?" | MC_hunt_family4.cfg | MCContextLengthViolation action sends context_length > MAX | ContextLengthBounds |

---

## Spec Artifacts Generated

### Phase 1: Base Spec
- ✓ `base.tla` — Core spec with 8 bug-family driven extension variables
- ✓ `base.cfg` — Configuration with 7 safety invariants

### Phase 2: MC Spec
- ✓ `MC.tla` — Model checking wrapper with 8 counter-bounded fault actions
- ✓ `MC.cfg` — Standard MC configuration (invariants listed, extension ones commented out)
- ✓ `MC_hunt_family1.cfg` — Hunting config for opaque data validation
- ✓ `MC_hunt_family2.cfg` — Hunting config for session ID leak
- ✓ `MC_hunt_family3.cfg` — Hunting config for version negotiation
- ✓ `MC_hunt_family4.cfg` — Hunting config for context bounds
- ✓ `MC_hunt_family5.cfg` — Hunting config for state machine

### Phase 2.5: Brief Coverage Audit
- ✓ `brief-coverage.md` — This document

### Phase 3: Trace Validation Spec
- ⧗ `Trace.tla` — Pending (will be generated next)
- ⧗ `Trace.cfg` — Pending (will be generated next)

### Phase 4: Instrumentation Spec
- ⧗ `instrumentation-spec.md` — Pending (will be generated next)

---

## Summary of Coverage

**All 5 bug families are covered** with one hunt config per family. Each family's primary invariant(s) are defined in the base spec, wired into the MC spec, and enabled in the corresponding hunt config. All 7 safety invariants from brief §5 are implemented and targeted.

**All 5 model-checkable findings** (brief §6.1) have corresponding hunt configs with appropriate fault-injection mechanisms to make the violations reachable:
- MC1: opaque_length overflow → OpaqueLengthConsistency violation
- MC2: session ID leak → SessionIDAllocationFreeing violation
- MC3: version mismatch → SecuredMessageVersionAgreement violation
- MC4: state machine skip → PSKExchangeNoActiveSession violation
- MC5: context bounds → ContextLengthBounds violation

**Action granularity** follows the brief's guidance:
- Requester and responder actions are split (RequesterSendPskExchange vs ResponderRecvPskExchange)
- Send and receive phases are separate actions to model message delivery timing
- Error paths are modeled as distinct actions to capture leak scenarios

**No out-of-scope findings**: All safety invariants from the brief are modeled. No additional "defensive" invariants were added beyond what the brief proposes.

---

## Hunting Execution Strategy

1. **Phase 2 (Spec Convergence)**: Run `TLC MC.cfg` to validate base spec semantics with loose constraints
2. **Phase 2 (Bug Hunting)**: Run TLC with each `MC_hunt_family*.cfg` sequentially
   - `TLC -config MC_hunt_family1.cfg` → expect OpaqueLengthConsistency violation
   - `TLC -config MC_hunt_family2.cfg` → expect SessionIDAllocationFreeing violation
   - `TLC -config MC_hunt_family3.cfg` → expect SecuredMessageVersionAgreement violation
   - `TLC -config MC_hunt_family4.cfg` → expect ContextLengthBounds violation
   - `TLC -config MC_hunt_family5.cfg` → expect PSKExchangeNoActiveSession violation
3. **Phase 3 (Trace Validation)**: Instrument source code and collect traces, validate against Trace.tla

---

## Known Limitations and Design Notes

### Simplifications Made (Acceptable for Protocol State Modeling)
1. **Cryptographic operations**: Assumed correct; not modeled
2. **Transcript hashing (TH)**: Assumed correct; presence tracked as `HandshakeTranscriptIntegrity`
3. **Message buffer management**: Assumed correct; focus on protocol logic
4. **Capability negotiation**: Assumed pre-negotiated; not re-negotiated in this spec
5. **Measurement hash**: Simplified to boolean presence; content not modeled

### Extensions Explicitly NOT Modeled (Per Brief §3.2)
- PSK_CAP_REQUESTER vs PSK_CAP_RESPONDER capability differences (assumed pre-set)
- Heartbeat period semantics (timing is separate from handshake correctness)
- Secure message versioning negotiation details (simplified to binary version agreement)

These omissions are appropriate because:
- They are orthogonal to the 5 bug families identified
- The brief explicitly marks them "Do Not Model"
- Modeling them would not improve bug-finding power for the target mechanisms

---

## Next Steps

1. **Validate base.tla syntax** with TLA+ toolbox
2. **Run MC.cfg** to verify base spec converges
3. **Run each MC_hunt_family*.cfg** to hunt for target bugs
4. **Generate Trace.tla and instrumentation-spec.md** (Phase 3-4)
5. **Instrument source code** and collect execution traces
6. **Validate traces** against Trace.tla (Phase 3)

---

## Audit Checklist

- [x] All 5 bug families have a corresponding hunt config
- [x] All 7 safety invariants are defined in base.tla
- [x] All 7 safety invariants are enabled in ≥1 hunt config
- [x] All 5 model-checkable findings (brief §6.1) have reachable fault mechanisms
- [x] No safety invariant is commented out in hunt cfgs (only in MC.cfg)
- [x] No silent gaps: each family/invariant/finding is explicitly traced to a cfg
- [x] Counter bounds are tight (2-3 per fault mechanism) to reduce irrelevant exploration
- [x] Message buffer constraints applied (messages set)
- [x] View excludes counter variables for symmetry
- [x] All 8 extension variables from Bug Families are implemented in base.tla
