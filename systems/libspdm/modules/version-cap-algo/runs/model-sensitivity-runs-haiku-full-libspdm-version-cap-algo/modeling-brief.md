# libspdm-version-cap-algo: Modeling Brief

## 1. System Overview

**System**: libspdm (SPDM - Security Protocol Data Model implementation)
**Language**: C
**Core Logic**: ~1000 LOC focused on VERSION / CAPABILITIES / NEGOTIATE_ALGORITHMS handshake
**Category**: **Category A (Distributed/Message-Passing)**

The libspdm library implements the SPDM protocol, a request-response message exchange for secure device authentication and key negotiation. The analyzed scope focuses on the initial handshake: GET_VERSION → VERSION, GET_CAPABILITIES → CAPABILITIES, and NEGOTIATE_ALGORITHMS → ALGORITHMS.

**Concurrency Model**: Single-threaded event loop. Request-response pairs, no concurrent message handling or state mutations.

**Key Architectural Choices**:
- Responder directly accepts requester-proposed algorithms, then attempts negotiation
- Algorithm validation relies on bitwise AND for intersection checking
- Multiple version-specific capability flag rules (1.1, 1.2, 1.3, 1.4) with complex interdependencies
- Asymmetric validation: responder accepts requester proposals; requester validates responder's response conditionally

**Reference Algorithm**: SPDM 1.4 (DSP0274), with support for versions 1.0–1.4

---

## 2. Bug Families

### Family 1: Asymmetric Algorithm Validation Gap

**Mechanism**: The responder directly assigns requester-proposed algorithms to connection state without validating they exist in the responder's local capabilities. The validation logic relies on a conditional bitwise AND check that the requester performs on the response, but the responder doesn't validate before accepting.

**Evidence**:
- Code analysis: `libspdm_rsp_algorithms.c:565–566`, lines 585–594, 603–604, 621–622, 640–641, 662–663, 684–685
  - Direct assignment: `spdm_context->connection_info.algorithm.base_asym_algo = spdm_request->base_asym_algo;`
  - No preceding validation against `spdm_context->local_context.algorithm.base_asym_algo`
- Code analysis: `libspdm_req_negotiate_algorithms.c:529–533`
  - Requester validates with: `if ((connection.algo & local.algo) == 0) return NEGOTIATION_FAIL`
  - But this check only fires if certain capabilities are enabled (lines 503–515)

**Affected code paths**:
- Responder: `libspdm_get_response_algorithms()` — algorithm assignment phase (lines 557–695)
- Requester: `libspdm_try_negotiate_algorithms()` — response validation phase (lines 474–541)
- Struct tables: DHE, AEAD, REQ_BASE_ASYM_ALG, KEY_SCHEDULE, REQ_PQC_ASYM_ALG, KEM_ALG

**Suggested modeling approach**:
- **Variables**: Extend connection state to track "agreed_algorithms_valid" (boolean) and "unsupported_algorithm_mask" (bitmask)
- **Actions**: Split algorithm negotiation into separate steps: (1) responder accepts proposal, (2) responder validates intersection, (3) requester validates intersection. Detect when both sides claim a negotiated algorithm but one doesn't support it.
- **Granularity**: Multiple actions; algorithm negotiation is not atomic.

**Priority**: **High**
**Rationale**: This family directly violates protocol safety — both sides can end up with different understanding of negotiated algorithms. Historical precedent: multi-version protocols (TLS, etc.) frequently have version-specific validation gaps. The conditional validation on the requester side (only in certain capability modes) suggests this mechanism is fragile.

---

### Family 2: Prioritization Function Silent Failure on No Common Algorithm

**Mechanism**: `libspdm_prioritize_algorithm()` returns 0 when no common algorithm exists (bitwise AND == 0), but callers don't consistently check for this failure. The responder then stores a 0 value in connection state and uses it in further prioritization, potentially cascading failures.

**Evidence**:
- Code analysis: `libspdm_rsp_algorithms.c:42–56` — prioritization function returns 0 on no match
- Code analysis: `libspdm_rsp_algorithms.c:585–594`, 739–747 — calls to prioritize_algorithm without checking for 0 return before finalizing response
- Code analysis: `libspdm_req_negotiate_algorithms.c:587–612` — similar pattern on requester

**Affected code paths**:
- Responder: All algorithm negotiation switch cases (lines 577–705)
- Response construction: Lines 724–747 (measurement spec, base_asym, base_hash, pqc_asym)

**Suggested modeling approach**:
- **Variables**: Add "prioritization_failed" flag, track which algorithm negotiations returned 0
- **Actions**: Model prioritize_algorithm with explicit failure outcome; check return values before response finalization
- **Granularity**: Single action but with multiple failure branches

**Priority**: **High**
**Rationale**: Silent failure (returning 0) is error-prone. If both sides send incompatible algorithm lists, the responder could construct a response with alg_supported=0, which the requester interprets as "no agreement" — but the responder may have already accepted a non-zero value for the same algorithm type, leading to internal inconsistency.

---

### Family 3: Capability Flag Complex Interdependencies Across Versions

**Mechanism**: The capabilities validation function checks 20+ mutually inclusive/exclusive flag relationships, with version-specific rules for SPDM 1.1, 1.2, 1.3, and 1.4. Risk of rule inconsistencies, missing checks for new versions, or rules that fail to compose correctly.

**Evidence**:
- Code analysis: `libspdm_rsp_capabilities.c:49–162` — `libspdm_check_request_flag_compatibility()`
  - Lines 68–135: Version >= 1.1 checks (PSK_CAP reserved values, KEY_EX_CAP + MAC_CAP interdependency, CERT_CAP + PUB_KEY_ID_CAP mutual exclusion, etc.)
  - Lines 137–142: Version == 1.1 specific (MUT_AUTH_CAP requires ENCAP_CAP)
  - Lines 144–153: Version >= 1.3 checks (EP_INFO_CAP, MULTI_KEY_CAP reserved values)
  - Comment at lines 155–161: "Checks deferred to when a message is received"

**Affected code paths**:
- Responder: `libspdm_get_response_capabilities()` — lines 223–228
- Both sides: Capability checks in GET_CAPABILITIES request validation

**Suggested modeling approach**:
- **Variables**: Capability flags state (one flag per capability)
- **Actions**: Separate invariant checks per version tier; use TLA+ action preconditions to enforce flag relationships
- **Granularity**: One action with multiple invariant guards

**Priority**: **Medium**
**Rationale**: The comment at lines 155–161 acknowledges deferred checks, suggesting the design itself knows there are validation gaps. Historical bug pattern: capability flag checkers in multi-version protocols often have off-by-one version checks (e.g., checking "version >= 1.3" when it should be "version >= 1.2"). The 60+ lines of flag validation is a code smell for maintainability issues.

---

### Family 4: Version Compatibility Check Without Prior Negotiation Validation

**Mechanism**: The responder's capabilities handler checks if the incoming GET_CAPABILITIES request's version matches a supported version, but doesn't validate that this version was actually negotiated in the preceding VERSION exchange. The GET_VERSION handler resets context on receipt, which could lose prior state.

**Evidence**:
- Code analysis: `libspdm_rsp_capabilities.c:21–35` — `libspdm_check_request_version_compatibility()`
  - Line 31: Sets `spdm_context->connection_info.version = version << SPDM_VERSION_NUMBER_SHIFT_BIT`
  - No check that this version matches what was agreed in VERSION exchange
- Code analysis: `libspdm_rsp_version.c:81` — GET_VERSION handler calls `libspdm_reset_context()`
  - Line 66: Sets connection state to NOT_STARTED
  - Line 81: Resets message buffer
  - Could lose CAPABILITIES or ALGORITHMS state if GET_VERSION arrives mid-handshake

**Affected code paths**:
- Responder: `libspdm_get_response_version()` (lines 54–127)
- Responder: `libspdm_get_response_capabilities()` (lines 165–380)
- State management: `libspdm_reset_context()`, `libspdm_set_connection_state()`

**Suggested modeling approach**:
- **Variables**: Track "version_negotiated" separately from "current_request_version"; add state counter to detect mid-handshake resets
- **Actions**: Model VERSION exchange as atomic, reject subsequent GET_VERSION before next handshake phase
- **Granularity**: One action per message type with state guards

**Priority**: **Medium**
**Rationale**: GET_VERSION at line 54 checks for session ID validity, suggesting the protocol allows resets mid-connection. However, unconditional reset could lose state. The responder doesn't validate the version was previously agreed.

---

### Family 5: Conditional Validation on Requester Side Creates Capability-Dependent Correctness

**Mechanism**: The requester's algorithm validation (bitwise AND checks for intersection) only executes if certain capabilities are enabled. This means a requester with minimal capabilities enabled might accept unsupported algorithms without validation.

**Evidence**:
- Code analysis: `libspdm_req_negotiate_algorithms.c:474–541`
  - Lines 474–501: base_hash validation only if MEAS_CAP, CERT_CAP, CHAL_CAP, MEAS_CAP_SIG, or KEY_EX_CAP
  - Lines 503–541: base_asym, DHE, AEAD, REQ_BASE_ASYM_ALG, etc. each gated by capability checks
  - If a requester disables all these capabilities, lines 496–630 are skipped entirely

**Affected code paths**:
- Requester: `libspdm_try_negotiate_algorithms()` response validation phase

**Suggested modeling approach**:
- **Variables**: Requester capability flags state
- **Actions**: Model algorithm validation as conditional on capabilities; verify that "no validation" scenarios don't lead to invalid connection state
- **Granularity**: One action with multiple preconditions

**Priority**: **Medium**
**Rationale**: This design is intentional — if capabilities aren't used, algorithm validation is deferred. However, it creates a subtle correctness dependency: the safety of algorithm negotiation depends on capability flags being correctly set. If capabilities are negotiated incorrectly, algorithm validation may silently skip.

---

## 3. Modeling Recommendations

### 3.1 What to Model

| What | Why | How |
|------|-----|-----|
| **Algorithm Intersection Validation** | Family 1: Responder doesn't validate before accepting; requester validates conditionally. Model both sides' checks and detect disagreement. | Extend state: `connection.agreed_algo`, `local.supported_algo`. Actions: (1) responder accepts proposal, (2) compute intersection, (3) requester validates. Invariant: if both claim agreement, intersection must be non-empty. |
| **Prioritization Failure Modes** | Family 2: Prioritize returns 0 on failure; callers don't check. Model what happens when no common algorithm exists. | Add outcome variable to prioritize_algorithm; check for 0 before finalizing. Invariant: response.alg_supported ≠ 0 OR both sides sent empty lists. |
| **Version State Consistency** | Family 4: GET_VERSION resets context; capabilities check doesn't validate prior negotiation. Model version negotiation as prerequisite for capabilities. | Extend state: `connection.version_negotiated`, `connection.capabilities_negotiated`, `connection.algorithms_negotiated`. Guard actions: GET_CAPABILITIES requires version_negotiated; NEGOTIATE_ALGORITHMS requires capabilities_negotiated. |
| **Asymmetric Validation Across Sides** | Family 1, 5: Responder accepts; requester validates conditionally. Model both sides' logic independently. | Separate responder and requester processes; track their local decisions and compare. |

### 3.2 What NOT to Model

| What | Why |
|------|-----|
| **Cryptographic Details** | Algorithm names (SHA256, ECDSA, etc.) are opaque integers. Model only intersection/compatibility logic. |
| **Message Encoding/Decoding** | Focus on semantic state machine, not wire format. |
| **Extended Algorithms (ext_asym, ext_hash)** | Currently unsupported per comment at line 10 of `libspdm_rsp_algorithms.c`. Model only fixed algorithms. |
| **Transport Layer** | Model message send/receive as atomic; don't model MCTP/PCI-DOE. |
| **Capability Flag Enumerations (Family 3)** | The 20+ flag rules are a detail. Model as abstract boolean state; let code review handle flag compositions. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Algorithm intersection tracking | `connection.algo_agreed`, `local.algo_supported`, `peer.algo_proposed` | Detect when responder accepts but requester can't support (Family 1) | Family 1 |
| Prioritization outcome tracking | `prioritize_result`, `prioritize_failed` | Detect when prioritize returns 0 but caller treats it as success (Family 2) | Family 2 |
| Version negotiation prerequisite | `connection.version_negotiated` (boolean) | Ensure capabilities/algorithms only proceed after version is settled (Family 4) | Family 4 |
| Capability-conditional validation flag | `validation_required` (boolean derived from capabilities) | Track whether algorithm validation is expected (Family 5) | Family 5 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| **AlgorithmIntersectionNonEmpty** | Safety | If both sides claim a negotiated algorithm, their local supports must intersect on that algorithm. | Family 1 |
| **PrioritizationSucceeds** | Safety | If prioritize_algorithm is called with non-zero local and peer, result must be non-zero OR both sides must have empty support. | Family 2 |
| **VersionNegotiatedBeforeCapabilities** | Safety | Responder must negotiate version before accepting GET_CAPABILITIES. | Family 4 |
| **VersionNegotiatedBeforeAlgorithms** | Safety | Responder must negotiate version and capabilities before accepting NEGOTIATE_ALGORITHMS. | Family 4 |
| **RequesterValidatesIfCapabilitiesEnabled** | Safety | If requester enables signature or encryption capabilities, algorithm validation must not be skipped. | Family 5 |
| **AsymmetricAlgoValidation** | Safety | Responder base_asym_algo in response must be in responder's local.base_asym_algo. Requester must validate intersection. | Family 1 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected Invariant Violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC1 | If responder's local supported algorithms are empty but requester sends non-empty proposal, what does responder store in connection_info? | ResponderAcceptsUnsupportedAlgorithm: responder stores non-empty algo in connection but algo ∉ local.supported | Family 1 |
| MC2 | If responder sends base_asym_algo=0 in response and requester has base_asym validation enabled, does negotiation fail correctly? | ResponderRejectsWithZeroAlgo: responder sends 0; requester correctly rejects with NEGOTIATION_FAIL (verify bitwise AND check fires) | Family 1 |
| MC3 | If local supports {SHA256, SHA384} and peer sends {SHA512}, does prioritize return 0, and is response valid? | PrioritizationFailureNotDetected: responder accepts responder's 0 return value and includes it in response without error | Family 2 |
| MC4 | Can GET_VERSION arrive after GET_CAPABILITIES, reset context, and lose capability state? | VersionResetMidHandshake: responder accepts GET_CAPABILITIES, then GET_VERSION, then receives subsequent message expecting capabilities state | Family 4 |
| MC5 | If requester disables all signature/encryption capabilities, does algorithm validation skip, and can it accept unsupported algorithm? | SkippedValidationNoCapabilities: requester accepts algo; validation at lines 474–541 never executes | Family 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested Test Approach |
|----|-------------|----------------------|
| TV1 | Algorithm priority table ordering affects prioritize_algorithm output; verify consistency across all algorithm types (hash, asym, DHE, AEAD, key_schedule, PQC, KEM). | Unit test: mock priority tables with overlapping sets; verify prioritize always returns highest-priority match or 0 |
| TV2 | Capability flag validation for SPDM 1.4 PQC features (req_pqc_asym_algo, kem_algo) — check that new flags don't break old version constraints. | Integration test: requester 1.3 ↔ responder 1.4; verify 1.3 rejects unknown algorithm types gracefully |

### 6.3 Code-Review-Only

| ID | Description | Suggested Action |
|----|-------------|-----------------|
| CR1 | Line 589, 607, 625, 644, 666, 688: `alg_count = 0x20` is hardcoded. Verify this is intentional (fixed_alg_size=2 bytes) and not a latent bug. | Manual code review: confirm 0x20 encoding is per-spec and consistent with struct_table.alg_count parsing (lines 470–471, 388–390) |
| CR2 | Comment at lines 155–161 in capabilities checker: "Checks deferred to when a message is received". Identify which checks are deferred and verify they execute. | Code audit: grep for "deferred" comment; cross-reference with actual checks in GET_CAPABILITIES response handling |
| CR3 | Asymmetric algorithm handling: requester checks base_asym_algo intersection (line 530) but responder doesn't. Verify this is intentional design or a missing check. | Design review: confirm whether responder should validate responder's own base_asym_algo against requester's |

---

## 7. Reference Pointers

- **Full Analysis Report**: (to be generated as analysis-report.md after deep analysis completion)
- **Key Source Files**:
  - Responder algorithm negotiation: `/library/spdm_responder_lib/libspdm_rsp_algorithms.c` (lines 59–850+)
  - Responder capabilities: `/library/spdm_responder_lib/libspdm_rsp_capabilities.c` (lines 21–380)
  - Responder version: `/library/spdm_responder_lib/libspdm_rsp_version.c` (lines 33–127)
  - Requester algorithm negotiation: `/library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c` (lines 73–650+)
  - Requester version: `/library/spdm_requester_lib/libspdm_req_get_version.c` (lines 40–230)
- **SPDM Specification**: DSP0274 (SPDM 1.4)
- **Related Issues**: (No git history available in this artifact; changelog.md documents 2.3→3.0 changes including "Many bug fixes and alignment with SPDM spec")
