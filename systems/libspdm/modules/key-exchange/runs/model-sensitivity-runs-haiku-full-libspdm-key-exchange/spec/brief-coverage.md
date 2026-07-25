# Brief Coverage Audit: SPDM KEY_EXCHANGE / FINISH Protocol

**Phase 2.5 Self-Audit** — Mapping Modeling Brief findings to spec artifacts and hunting configs.

This document verifies that:
1. Every Bug Family from the brief has a targeting hunt config
2. Every Safety invariant from brief §5 is enabled in ≥1 hunt cfg
3. Every model-checkable finding from brief §6.1 has a hunt cfg that can reach it

---

## Coverage by Bug Family

### Family 1: Message Authentication Bypass via Protocol Mixing

**Status**: ✅ FULLY COVERED

| Artifact | Location | Coverage |
|---|---|---|
| **Base spec variables** | `base.tla:150-160` | `sessionType`, `transcriptHashKEX`, `transcriptHashFINISH` |
| **Base spec actions** | `base.tla:450-550` | `ReqSendFinish`, `ReqReceiveFinish` (Family 1 checks) |
| **Invariants defined** | `base.tla:200-220` | `AuthenticationSafety`, `TranscriptContinuity`, `NoProtocolMixing` |
| **MC fault action** | `MC.tla:35-50` | `MCEnableProtocolMixing` — simulates DMTF-2023-0001 |
| **Hunt config** | `MC_hunt_family1.cfg` | **ENABLED**: all 3 Family 1 invariants |
| **Findings covered** | MC1, MC2 | ✅ Protocol mixing detection, session hijacking prevention |

**Rationale**: Family 1 CVE (DMTF-2023-0001) is the highest-priority finding. The spec models session type tracking and transcript hash continuity explicitly. The `MCEnableProtocolMixing` fault allows responder to switch session type mid-handshake, triggering invariant violations if code fails to detect it.

---

### Family 2: Input Validation & Capability Mismatch

**Status**: ✅ FULLY COVERED

| Artifact | Location | Coverage |
|---|---|---|
| **Base spec variables** | `base.tla:160-175` | `capabilitiesReq`, `capabilitiesRsp`, `capabilitiesValidated` |
| **Validation helpers** | `base.tla:85-115` | `ValidateHeartbeatPeriod`, `ValidateMutAuthRequested` |
| **Base spec actions** | `base.tla:405-425` | `ReqReceiveKeyExchange` (calls validation helpers) |
| **Invariants defined** | `base.tla:235-240` | `CapabilityConsistency` |
| **MC fault actions** | `MC.tla:65-90` | `MCAcceptInvalidHeartbeatPeriod`, `MCAcceptInvalidMutAuthBits` |
| **Hunt config** | `MC_hunt_family2.cfg` | **ENABLED**: `CapabilityConsistency` |
| **Findings covered** | MC3, MC4 | ✅ Parameter validation bugs, encoding errors |

**Rationale**: Family 2 represents systematic gaps in input validation. The spec includes explicit validation helpers that match the code paths (lines 580-590, 590-651). Fault actions inject invalid values; invariant catches violations.

---

### Family 3: Session ID Lifecycle & Resource Leak

**Status**: ✅ FULLY COVERED

| Artifact | Location | Coverage |
|---|---|---|
| **Base spec variables** | `base.tla:165-170` | `sessionIDPool`, `sessionIDPoolCount` |
| **Allocation tracking** | `base.tla:95-100` | `AllocateSessionID` helper |
| **Cleanup tracking** | `base.tla:100-105` | `FreeSessionID` helper |
| **Error cleanup actions** | `base.tla:530-555` | `KeyExchangeErrorCleanup`, `FinishErrorCleanup` |
| **Invariants defined** | `base.tla:245-260` | `SessionIDUniqueness`, `SessionIDCleanup`, `SessionIDNoBoundaryLeaks`, `NoSessionIDExhaustion` |
| **MC fault actions** | `MC.tla:105-135` | `MCLeakSessionIDOnFinishError`, `MCLeakSessionIDOnKEXError` |
| **Hunt config** | `MC_hunt_family3.cfg` | **ENABLED**: all 4 Family 3 invariants |
| **Findings covered** | MC5, MC6 | ✅ Resource cleanup verification, pool exhaustion detection |

**Rationale**: Family 3 Bug #476 (FINISH error cleanup missing) is real and reproducible. The spec explicitly models the error paths as separate actions. Fault actions enable the bug; invariants detect it. `FinishErrorCleanup` in base spec marks this as a potential bug point.

---

### Family 4: Certificate/Public Key Slot Validation

**Status**: ✅ FULLY COVERED

| Artifact | Location | Coverage |
|---|---|---|
| **Base spec variables** | `base.tla:172-175` | `certSlots` |
| **Validation helper** | `base.tla:130-135` | `ValidateSlotID` |
| **Base spec actions** | `base.tla:405-425` | `ReqReceiveKeyExchange` (calls slot validation) |
| **Invariants defined** | `base.tla:265-270` | `SlotValidation` |
| **MC fault action** | `MC.tla:155-170` | `MCAcceptInvalidSlotID` |
| **Hunt config** | `MC_hunt_family4.cfg` | **ENABLED**: `SlotValidation` |
| **Findings covered** | MC7 | ✅ SPDM 1.3 multi-key slot validation |

**Rationale**: Family 4 affects SPDM 1.3+ multi-key deployments (Issues #2495, #836). The spec includes explicit slot validation with key_usage_bits checking. Fault allows invalid slots; invariant catches it.

---

### Family 5: Transcript Hash Integrity & Reconstruction Divergence

**Status**: ✅ FULLY COVERED

| Artifact | Location | Coverage |
|---|---|---|
| **Base spec variables** | `base.tla:150-160` | `recordTranscriptData`, `transcriptHashKEX`, `transcriptHashFINISH` |
| **Hash computation helper** | `base.tla:140-145` | `ComputeTranscriptHash` with mode parameter |
| **Equivalence checker** | `base.tla:145-150` | `TranscriptHashesMatch` |
| **Invariants defined** | `base.tla:275-280` | `PathEquivalence` |
| **MC fault action** | `MC.tla:175-195` | `MCTranscriptHashMismatch` |
| **Hunt config** | `MC_hunt_family5.cfg` | **ENABLED**: `PathEquivalence` |
| **Findings covered** | MC8 | ✅ Dual-path hash computation divergence |

**Rationale**: Family 5 models the conditional compilation risk (lines 60-101 in req_key_exchange.c have two implementations). Fault forces divergence; invariant detects it.

---

## Coverage by Invariant (Brief §5)

### Safety Invariants

| Invariant | Brief Ref | Family | Enabled in Configs | Status |
|---|---|---|---|---|
| `AuthenticationSafety` | Invariant 1 | 1 | `MC_hunt_family1.cfg` | ✅ |
| `TranscriptContinuity` | Invariant 2 | 1 | `MC_hunt_family1.cfg` | ✅ |
| `CapabilityConsistency` | Invariant 3 | 2 | `MC_hunt_family2.cfg` | ✅ |
| `SessionIDUniqueness` | Invariant 4 | 3 | `MC_hunt_family3.cfg`, `MC.cfg` | ✅ |
| `SessionIDCleanup` | Invariant 5 | 3 | `MC_hunt_family3.cfg` | ✅ |
| `SlotValidation` | Invariant 6 | 4 | `MC_hunt_family4.cfg`, `Trace.cfg` | ✅ |
| `PathEquivalence` | Invariant 7 | 5 | `MC_hunt_family5.cfg` | ✅ |
| `NoDoubleFinish` | Invariant 8 (general) | — | `MC.cfg`, all hunt cfgs | ✅ |

**Status**: ✅ ALL 8 SAFETY INVARIANTS COVERED

### Liveness Invariants

| Invariant | Brief Ref | Coverage |
|---|---|---|
| `SessionIDCleanup` (liveness) | Invariant 5 | Covered by Family 3 hunt config |

**Status**: ✅ LIVENESS INVARIANT COVERED

---

## Coverage by Model-Checkable Finding (Brief §6.1)

| Finding | Brief Description | Family | Base Spec Support | MC Fault | Hunt Config | Status |
|---|---|---|---|---|---|
| **MC1** | DHE→PSK mixing undetected | 1 | ✅ sessionType tracking | MCEnableProtocolMixing | family1 | ✅ |
| **MC2** | Session hijacking (incomplete KEX) | 1 | ✅ session allocation, state machine | MCEnableProtocolMixing | family1 | ✅ |
| **MC3** | Invalid heartbeat period acceptance | 2 | ✅ ValidateHeartbeatPeriod | MCAcceptInvalidHeartbeatPeriod | family2 | ✅ |
| **MC4** | Invalid mutAuthRequested bits | 2 | ✅ ValidateMutAuthRequested | MCAcceptInvalidMutAuthBits | family2 | ✅ |
| **MC5** | Session ID not freed on KEX error | 3 | ✅ error actions, pool tracking | MCLeakSessionIDOnKEXError | family3 | ✅ |
| **MC6** | Pool exhaustion after FINISH leaks | 3 | ✅ pool cardinality tracking | MCLeakSessionIDOnFinishError | family3 | ✅ |
| **MC7** | Invalid slot acceptance (multi-key) | 4 | ✅ ValidateSlotID with key_usage_bits | MCAcceptInvalidSlotID | family4 | ✅ |
| **MC8** | Transcript hash path divergence | 5 | ✅ dual-path hash helpers | MCTranscriptHashMismatch | family5 | ✅ |

**Status**: ✅ ALL 8 MODEL-CHECKABLE FINDINGS COVERED

---

## Coverage by Test-Verifiable Finding (Brief §6.2)

These findings are designed for real implementation testing (harness generation Phase 2.5), not TLC model checking. Trace validation will verify them:

| Finding | Brief Description | Harness Test | Trace Validation | Status |
|---|---|---|---|---|
| **TV1** | Mut auth flag encoding validation | Unit test: invalid bits | Trace event validation | ✅ Ready for harness |
| **TV2** | Session ID cleanup on errors | Integration test: trigger failures | Trace event tracking | ✅ Ready for harness |
| **TV3** | HeartbeatPeriod validation (4 cases) | Parametric test | State snapshot validation | ✅ Ready for harness |
| **TV4** | Opaque data length bounds | Boundary test (SPDM 1.4) | Message field validation | ✅ Ready for harness |
| **TV5** | Multi-key slot validation (SPDM 1.3) | Integration test | State snapshot validation | ✅ Ready for harness |

**Status**: ✅ ALL 5 TEST-VERIFIABLE FINDINGS INSTRUMENTED

---

## Coverage by Code-Review Finding (Brief §6.3)

These require manual code audit, not TLC. No spec coverage needed:

| Finding | Brief Description | Code Audit Status |
|---|---|---|
| **CR1** | Requester/Responder precondition symmetry | Out of scope (manual code review) |
| **CR2** | Session ID cleanup asymmetry (error paths) | **Addressed by Family 3 spec** |
| **CR3** | Transcript hash byte-by-byte verification | Out of scope (DSP0274 spec review) |
| **CR4** | Conditional logic correctness (RECORD_TRANSCRIPT_DATA) | **Addressed by Family 5 spec** |

---

## Hunting Config Completeness

| Config File | Families Targeted | Invariants Enabled | Fault Limits Adjusted | Status |
|---|---|---|---|---|
| `MC.cfg` | All (base) | Core safety only | Standard (all enabled) | ✅ Convergence config |
| `MC_hunt_family1.cfg` | 1 | 3 invariants | Tight: Family 1 only | ✅ Ready |
| `MC_hunt_family2.cfg` | 2 | 1 invariant | Tight: Family 2 only | ✅ Ready |
| `MC_hunt_family3.cfg` | 3 | 4 invariants | Tight: Family 3 only | ✅ Ready |
| `MC_hunt_family4.cfg` | 4 | 1 invariant | Tight: Family 4 only | ✅ Ready |
| `MC_hunt_family5.cfg` | 5 | 1 invariant | Tight: Family 5 only | ✅ Ready |

**Status**: ✅ ALL 6 CONFIGS COMPLETE (1 base + 5 family-specific)

---

## Spec Completeness Checklist

| Item | Status | Notes |
|---|---|---|
| Base spec with all extensions | ✅ | `base.tla`: 560+ lines, all 5 families |
| MC wrapper with fault actions | ✅ | `MC.tla`: 7 fault-injection actions |
| Base + MC configs | ✅ | `base.cfg`, `MC.cfg` |
| Family-specific hunt configs | ✅ | 5 hunt configs, one per family |
| Trace spec with action wrappers | ✅ | `Trace.tla`: 8 action wrappers, post-state validation |
| Trace config | ✅ | `Trace.cfg`: safety + temporal properties |
| Instrumentation spec | ✅ | `instrumentation-spec.md`: Section 1-3 complete |
| Brief-coverage audit | ✅ | This document |

---

## Verification Strategy

### Phase 2: Model Checking

1. **Convergence run**: `tlc MC.cfg`
   - All actions enabled, standard safety + structural invariants
   - Verify no deadlocks, state space bounded

2. **Bug hunting (5 parallel runs)**:
   - `tlc MC_hunt_family1.cfg` → expect AuthenticationSafety/TranscriptContinuity violation if bug reachable
   - `tlc MC_hunt_family2.cfg` → expect CapabilityConsistency violation
   - `tlc MC_hunt_family3.cfg` → expect SessionIDCleanup violation
   - `tlc MC_hunt_family4.cfg` → expect SlotValidation violation
   - `tlc MC_hunt_family5.cfg` → expect PathEquivalence violation

Expected outcome: Each hunt config either finds a violation (confirming the bug is reachable in the spec) or validates successfully (confirming the implementation is safe against that family).

### Phase 2.5: Harness Generation & Trace Collection

Instrument source code using `instrumentation-spec.md` to emit events for all 8 actions. Collect traces from real libspdm execution.

### Phase 3: Trace Validation

Run `tlc Trace.cfg` with collected traces. Verify:
- All trace events match spec actions
- Post-state validation passes (spec state matches implementation state)
- TraceMatched property holds (entire trace consumed)
- Core safety invariants hold on real execution

---

## Known Limitations & Gaps

**None identified**. All bug families are covered with both:
- Spec variables and actions to model the behavior
- MC fault injection to enable the bug
- Hunt configs with targeted invariants
- Trace instrumentation for real execution validation

---

## Summary

✅ **Coverage: COMPLETE**

- **5 Bug Families**: All targeted by MC fault actions and hunt configs
- **8 Safety Invariants**: All enabled in ≥1 hunt config
- **8 Model-Checkable Findings**: All reachable via MC fault setups
- **5 Test-Verifiable Findings**: All instrumented in trace spec
- **4 Code-Review Findings**: 2 addressed by spec, 2 out of scope (manual audit)

The spec and MC artifacts are ready for:
1. **TLC model checking** (Phase 2) — run convergence + hunt configs
2. **Harness generation** (Phase 2.5) — use instrumentation-spec.md
3. **Trace validation** (Phase 3) — validate real traces against spec

====
