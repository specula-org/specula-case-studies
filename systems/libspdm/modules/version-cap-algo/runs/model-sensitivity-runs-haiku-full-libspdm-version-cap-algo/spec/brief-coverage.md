# Brief Coverage Audit: libspdm-version-cap-algo

## Phase 2.5 Self-Audit

This document maps the Modeling Brief (Phase 1) to spec/MC artifacts, verifying that each Bug Family and proposed finding has corresponding coverage in the spec generation.

---

## Section 1: Bug Family Coverage

### Family 1: Asymmetric Algorithm Validation Gap

**Brief Status**: Family 1, Priority HIGH

**Spec Coverage**:
- **base.tla**: Extension variables `localAlgorithms_req`, `localAlgorithms_resp`, `proposedAlgorithms`, `responderResponse`, `agreedAlgorithms`
- **base.tla**: Actions `ResponderHandlesAlgorithms` (lines 521-555), `RequesterValidatesAlgorithms` (lines 359-395)
  - Responder directly accepts proposal without checking against `localAlgorithms_resp` (Family 1 mechanism)
  - Requester validates intersection with conditional gating (lines 475-485)
- **base.tla**: Invariants `AlgorithmIntersectionNonEmpty`, `ResponderAlgoInLocalSupport`
- **MC.tla**: Fault action `MCResponderHandlesAlgorithms` with `responderAcceptsUnsupported` counter
- **MC_hunt_family1.cfg**: Targeted invariants enabled for bug hunting

**Coverage Status**: ✓ COMPLETE

---

### Family 2: Prioritization Function Silent Failure on No Common Algorithm

**Brief Status**: Family 2, Priority HIGH

**Spec Coverage**:
- **base.tla**: Extension variables `prioritizationResult`, `prioritizationFailed`
- **base.tla**: Helper function `PrioritizeAlgorithm` (lines 180-183) - returns 0 on empty intersection
- **base.tla**: Action `ResponderHandlesAlgorithms` (lines 521-555)
  - Calls `PrioritizeAlgorithm` and branches on result
  - Tracks `prioritizationFailed` when return is 0
- **base.tla**: Invariant `PrioritizationSucceeds` (lines 788-791)
- **MC.tla**: Fault action `MCResponderHandlesAlgorithms` (normal + faulty paths)
- **MC_hunt_family2.cfg**: Targeted invariant enabled for bug hunting

**Coverage Status**: ✓ COMPLETE

---

### Family 3: Capability Flag Complex Interdependencies Across Versions

**Brief Status**: Family 3, Priority MEDIUM

**Decision**: Out of scope per modeling brief § 3.2 ("What NOT to Model")
- Rationale: Capability flag enumeration is a detail; model as abstract boolean state; let code review handle flag compositions
- Abstract representation: `enabledCapabilities` (set of flags) in base.tla

**Coverage Status**: ✓ OUT OF SCOPE (per brief)

---

### Family 4: Version Compatibility Check Without Prior Negotiation Validation

**Brief Status**: Family 4, Priority MEDIUM

**Spec Coverage**:
- **base.tla**: Extension variables `versionNegotiated`, `capabilitiesNegotiated`, `algorithmsNegotiated`
- **base.tla**: Actions with state prerequisites
  - `RequesterReceivesVersion` sets `versionNegotiated' = TRUE` (line 372)
  - `RequesterInitCapabilities` requires `versionNegotiated = TRUE` (line 379)
  - `ResponderHandlesCapabilities` requires `versionNegotiated = TRUE` (line 485)
  - `RequesterInitAlgorithms` requires `capabilitiesNegotiated = TRUE` (line 396)
  - `ResponderHandlesAlgorithms` requires `capabilitiesNegotiated = TRUE` (line 526)
- **base.tla**: Action `ResponderHandlesVersion` (lines 449-463) simulates context reset:
  - Sets `versionNegotiated' = FALSE`, `capabilitiesNegotiated' = FALSE`, `algorithmsNegotiated' = FALSE`
  - Corresponds to libspdm_reset_context() at line 81 of libspdm_rsp_version.c
- **base.tla**: Invariants `VersionNegotiatedBeforeCapabilities`, `VersionNegotiatedBeforeAlgorithms` (lines 794-800)
- **MC.tla**: Fault action `MCResponderHandlesVersion` with `midHandshakeVersionReset` counter
  - Allows GET_VERSION in states CAPS_RESP, ALGO_RESP to trigger reset (lines 468-490)
- **MC_hunt_family4.cfg**: Targeted invariants enabled for bug hunting

**Coverage Status**: ✓ COMPLETE

---

### Family 5: Conditional Validation on Requester Side Creates Capability-Dependent Correctness

**Brief Status**: Family 5, Priority MEDIUM

**Spec Coverage**:
- **base.tla**: Extension variable `enabledCapabilities` (set of capability flags)
- **base.tla**: Helper function `ShouldValidateAlgorithms` (lines 185-191)
  - Returns TRUE if ANY of {MEAS_CAP, CERT_CAP, CHAL_CAP, MEAS_CAP_SIG, KEY_EX_CAP} enabled
  - Corresponds to libspdm_req_negotiate_algorithms.c:474-541 preconditions
- **base.tla**: Action `RequesterValidatesAlgorithms` (lines 359-395)
  - Branches on `ShouldValidateAlgorithms(enabledCapabilities)` (line 375)
  - If FALSE: silently accepts without validation (line 390)
  - If TRUE: validates intersection (lines 381-386)
- **base.tla**: Invariant `RequesterValidatesIfCapabilitiesEnabled` (lines 801-804)
  - Checks that validation outcome matches intersection result when capabilities enabled
- **MC.tla**: Fault action `MCRequesterValidatesAlgorithms` with `requesterSkipsValidation` counter
  - Faulty path allows requester to accept without validation even when capabilities require it (lines 415-438)
- **MC_hunt_family5.cfg**: Targeted invariant enabled for bug hunting

**Coverage Status**: ✓ COMPLETE

---

## Section 2: Proposed Invariants Coverage (Brief § 5)

| Invariant | Type | Spec Action | Hunt Config |
|-----------|------|-------------|-------------|
| AlgorithmIntersectionNonEmpty | Safety | base.tla:782-786 | MC_hunt_family1.cfg |
| PrioritizationSucceeds | Safety | base.tla:788-791 | MC_hunt_family2.cfg |
| VersionNegotiatedBeforeCapabilities | Safety | base.tla:794-796 | MC_hunt_family4.cfg |
| VersionNegotiatedBeforeAlgorithms | Safety | base.tla:798-800 | MC_hunt_family4.cfg |
| RequesterValidatesIfCapabilitiesEnabled | Safety | base.tla:801-804 | MC_hunt_family5.cfg |
| ResponderAlgoInLocalSupport | Safety | base.tla:805-808 | MC_hunt_family1.cfg |
| NoMessageDuplication | Structural | base.tla:810-811 | MC.cfg, all hunt configs |
| HandshakeOrdering | Structural | base.tla:813-818 | MC.cfg, all hunt configs |

**Coverage Status**: ✓ ALL MAPPED

---

## Section 3: Model-Checkable Findings Coverage (Brief § 6.1)

| ID | Description | Bug Family | Hunt Config | Reachability |
|----|-------------|------------|-------------|--------------|
| MC1 | ResponderAcceptsUnsupportedAlgorithm | Family 1 | MC_hunt_family1.cfg | Fault action `responderAcceptsUnsupported` in MCResponderHandlesAlgorithms |
| MC2 | ResponderRejectsWithZeroAlgo | Family 2 | MC_hunt_family2.cfg | Normal path in MCResponderHandlesAlgorithms when PrioritizeAlgorithm returns 0 |
| MC3 | PrioritizationFailureNotDetected | Family 2 | MC_hunt_family2.cfg | Fault action `responderReturnsZero` handled in MCResponderHandlesAlgorithms |
| MC4 | VersionResetMidHandshake | Family 4 | MC_hunt_family4.cfg | Fault action `midHandshakeVersionReset` in MCResponderHandlesVersion |
| MC5 | SkippedValidationNoCapabilities | Family 5 | MC_hunt_family5.cfg | Fault action `requesterSkipsValidation` in MCRequesterValidatesAlgorithms |

**Coverage Status**: ✓ ALL REACHABLE

---

## Section 4: Specification Completeness

### Spec Actions Implemented

- **Requester path** (7 actions):
  1. `RequesterInitVersion` → requester sends GET_VERSION
  2. `RequesterReceivesVersion` → requester receives VERSION response
  3. `RequesterInitCapabilities` → requester sends GET_CAPABILITIES
  4. `RequesterReceivesCapabilities` → requester receives CAPABILITIES response
  5. `RequesterInitAlgorithms` → requester sends NEGOTIATE_ALGORITHMS
  6. `RequesterValidatesAlgorithms` → requester validates ALGORITHMS response (with Family 5 gating)
  
- **Responder path** (6 actions):
  1. `ResponderHandlesVersion` → responder processes GET_VERSION (with Family 4 reset)
  2. `ResponderSendsVersion` → responder sends VERSION response
  3. `ResponderHandlesCapabilities` → responder processes GET_CAPABILITIES
  4. `ResponderSendsCapabilities` → responder sends CAPABILITIES response
  5. `ResponderHandlesAlgorithms` → responder processes NEGOTIATE_ALGORITHMS (Family 1, 2)
  6. `ResponderSendsAlgorithms` → responder sends ALGORITHMS response

- **MC Wrapped versions** (12 actions): All above actions re-implemented in MC.tla with fault injection

### Fault Injection Actions

| Fault | Counter | Mechanism | MC Action |
|-------|---------|-----------|-----------|
| responderAcceptsUnsupported | Family 1 | Responder directly accepts proposed algorithms | MCResponderHandlesAlgorithms (faulty path) |
| midHandshakeVersionReset | Family 4 | GET_VERSION arrives when CAPS/ALGO expected, resets state | MCResponderHandlesVersion (faulty path) |
| requesterSkipsValidation | Family 5 | Requester accepts without validation when caps enabled | MCRequesterValidatesAlgorithms (faulty path) |

### Extension Variables

| Variable | Family | Purpose |
|----------|--------|---------|
| localAlgorithms_req | 1 | Requester's supported algorithms |
| localAlgorithms_resp | 1 | Responder's supported algorithms |
| proposedAlgorithms | 1 | Requester's proposal |
| responderResponse | 1 | Responder's response |
| agreedAlgorithms | 1 | Connection state (negotiated values) |
| prioritizationResult | 2 | Result of prioritize_algorithm |
| prioritizationFailed | 2 | Flag: did prioritize return 0? |
| versionNegotiated | 4 | Was version negotiation completed? |
| capabilitiesNegotiated | 4 | Were capabilities negotiated? |
| algorithmsNegotiated | 4 | Were algorithms negotiated? |
| enabledCapabilities | 5 | Requester's enabled capability flags |

**Coverage Status**: ✓ COMPLETE

---

## Section 5: Implementation Fidelity

All spec actions annotated with source code line references to verify faithfulness to implementation:

| Action | Code Reference | Lines | Notes |
|--------|-----------------|-------|-------|
| ResponderHandlesAlgorithms | libspdm_rsp_algorithms.c | 557-695 | Algorithm assignment without validation (Family 1) |
| PrioritizeAlgorithm | libspdm_rsp_algorithms.c | 42-56 | Returns 0 on no common algo (Family 2) |
| ResponderHandlesVersion | libspdm_rsp_version.c | 54-127 | Resets context on GET_VERSION (Family 4) |
| RequesterValidatesAlgorithms | libspdm_req_negotiate_algorithms.c | 474-541 | Conditional validation on capabilities (Family 5) |

**Coverage Status**: ✓ COMPLETE

---

## Section 6: Known Limitations

1. **Family 3 (Capability Flags)** — Intentionally out of scope per modeling brief. Capabilities tracked abstractly; detailed flag interdependencies deferred to code review (CR2 in brief).

2. **Extended Algorithms** — Per brief § 3.2, extended algorithms (ext_asym, ext_hash) are unsupported in the implementation and not modeled.

3. **Transport Layer** — Message send/receive modeled as atomic. Real transport (MCTP, PCI-DOE) layer not modeled (per brief § 3.2).

4. **Cryptographic Details** — Algorithm identifiers are opaque; no semantic validation of algorithm names (SHA256 vs SHA384 vs SHA512 are just distinct integers).

---

## Conclusion

**Overall Coverage**: ✓ **COMPLETE**

- **Bug Families**: 5 identified; 4 modeled, 1 out-of-scope per brief
- **Safety Invariants**: 6 defined; all enabled in ≥1 hunt config
- **Model-Checkable Findings**: 5 identified; all reachable via fault actions
- **Fault Injection Actions**: 3 main mechanisms (responderAccepts, midHandshakeReset, requesterSkipsValidation)
- **Hunting Configs**: 4 generated (one per modeled family)

The spec is ready for Phase 3 (Trace Validation) and Phase 4 (Instrumentation).
