# SPDM GET_MEASUREMENTS Protocol - Modeling Brief

## 1. System Overview

**Name**: libspdm (DMTF SPDM Reference Implementation)  
**Language**: C  
**Scale**: Core measurement logic ~500 LOC (responder + requester handlers)  
**Category**: **Category A (Distributed / Message-Passing)** — libspdm implements SPDM, a hardware security protocol with request-response message exchange between requester and responder endpoints.  
**Protocol**: SPDM GET_MEASUREMENTS attestation (DSP0274 SPDM specification v1.0-v1.3)  
**Key Deviation**: Multi-version support (v1.0, v1.1, v1.2, v1.3) with significant version-specific message format and validation logic changes.  
**Concurrency Model**: Single-threaded library; responder and requester are independent endpoints. No internal concurrency; all state mutations are in single-threaded handlers.

---

## 2. Bug Families

### Family 1: Version-Specific Code Path Divergence in Message Handling

**Mechanism**: GET_MEASUREMENTS request/response format differs across protocol versions, with code paths for v1.0, v1.1, v1.2, v1.3 that have **inconsistent validation logic and parameter interpretations**, creating opportunities for protocol violations when a peer uses unexpected version-specific encodings.

**Evidence**:
- Code analysis: `libspdm_req_get_measurements.c:276-289` — slot_id_param is only included in v1.1+ requests (v1.0 request omits this field)
- Code analysis: `libspdm_rsp_measurements.c:185-206` — responder validates slot_id_param field size differently based on spdm_version at lines 185-206
- Code analysis: `libspdm_req_get_measurements.c:322-335` — requester context (8 bytes) is only included in v1.3+ at lines 322-335
- Code analysis: `libspdm_rsp_measurements.c:251-263` — responder processes requester context differently for v1.3 (lines 487-492)
- Code analysis: `libspdm_rsp_measurements.c:463-467` — v1.2+ adds content_changed bit encoding in param2, earlier versions do not

**Affected code paths**:
- Responder: `libspdm_get_response_measurements()` line 79
- Requester: `libspdm_try_get_measurement()` line 168

**Suspected vulnerabilities**:
1. A responder built for v1.1 receiving a malformed v1.0 request (no slot_id_param field) could skip slot validation
2. A requester built for v1.3 sending to a v1.1 responder could have mismatched message interpretation if connection_version negotiation fails

**Suggested modeling approach**:
- **Variables**: `spdm_version`, `request_format_version`, `response_format_version` (track what versions both endpoints agreed to negotiate)
- **Actions**: Split message reception into "parse_request_header", "parse_version_dependent_fields" to expose version mismatches
- **Granularity**: Model one action per major version group (v1.0, v1.1-v1.2 with incremental fields, v1.3 with context)

**Priority**: High  
**Rationale**: Version negotiation is a critical protocol step; version-specific divergence is high-risk for interop bugs and downgrade attacks. The inconsistent handling across 4 versions creates state space for model checking to explore.

---

### Family 2: Inconsistent State Validation Across Message Handlers

**Mechanism**: GET_MEASUREMENTS request processing applies different validation rules depending on signature request attribute and session state, leading to **code paths that skip critical session state or capability checks** that other paths enforce.

**Evidence**:
- Code analysis: `libspdm_rsp_measurements.c:113-127` — Session ID validation only happens when `last_spdm_request_session_id_valid == true` (line 113); no validation if false (uses NULL session_info). This asymmetry appears in responder but needs verification in requester.
- Code analysis: `libspdm_rsp_measurements.c:128-136` — Session state is only checked if session_info is non-NULL (line 128-130); earlier NULL check skips this
- Code analysis: `libspdm_rsp_measurements.c:159-166` — Capability check (MEAS_CAP) happens only after session/state checks, but these can be skipped
- Code analysis: `libspdm_req_get_measurements.c:238-243` — Requester checks `MEAS_CAP_NO_SIG` capability but only if signature was requested (lines 238-243), creating asymmetry in what gets validated

**Affected code paths**:
- Responder: `libspdm_get_response_measurements()` with unsecured vs secured session
- Requester: `libspdm_try_get_measurement()` with/without signature

**Suspected vulnerabilities**:
1. Unsecured (NULL session) GET_MEASUREMENTS might skip capability checks that secured sessions enforce
2. A responder accepting a measurement request without validating session state in certain orderings

**Suggested modeling approach**:
- **Variables**: `session_valid`, `session_state` (ESTABLISHED vs other), `capabilities_verified`
- **Actions**: Separate "validate_session" and "validate_capabilities" as distinct pre-conditions to measurement collection
- **Granularity**: Model both unsecured and secured paths as distinct action variants

**Priority**: High  
**Rationale**: Session state and capability validation are foundational protocol safety properties; skipping them violates attestation integrity assumptions.

---

### Family 3: Non-Atomic Signature Generation and Transcript Update

**Mechanism**: The responder generates a measurement signature over a **transcript that is built incrementally in multiple append operations**, with a **reset that occurs at different points depending on whether signature is requested**. This creates non-atomic persistence windows.

**Evidence**:
- Code analysis: `libspdm_rsp_measurements.c:494-512` — Responder appends request to message M (line 497), then appends partial response without signature (line 505-506), then generates signature (line 517-527), then resets message M (line 529)
- Code analysis: `libspdm_req_get_measurements.c:521-544` — Requester appends request (line 521-522), then appends response (line 527-528), then verifies signature (line 537-542), then resets message M (line 544) — **different order than responder**
- Code analysis: `libspdm_req_get_measurements.c:634-644` — When no signature is requested, requester appends request and response but only calls append once per message (lines 634-641), not split

**Affected code paths**:
- Responder: `libspdm_get_response_measurements()` lines 494-530
- Requester: `libspdm_try_get_measurement()` lines 521-544 (with signature) and 634-644 (without)

**Suspected vulnerabilities**:
1. Responder crashes between append_message_m calls (line 497 then 505): message M buffer is left in inconsistent state; next message build could read stale data
2. Responder signature generation (line 517) uses L1L2 transcript, then resets message M (line 529) — if crash occurs after signature generation but before reset, next request sees stale M
3. Requester message M reset (line 544) happens AFTER signature verification — if crash occurs during verification, message M is not reset and next measurement request sees stale transcript

**Suggested modeling approach**:
- **Variables**: `message_m_buffer_state`, `signature_computed`, `message_m_reset_done`
- **Actions**: Model signature generation as multi-step: "prepare_transcript", "compute_signature", "reset_transcript" with crash possible between any pair
- **Granularity**: Three separate actions for responder (append request, append response, compute+reset) and two for requester (append+verify, reset)

**Priority**: High  
**Rationale**: Transcript integrity is core to signature verification; crashes during append/reset create windows where cached transcripts could be used across unrelated measurements, violating freshness guarantees.

---

### Family 4: Opaque Data Validation Only Enforced in v1.2+

**Mechanism**: Opaque data validation is **only performed for SPDM v1.2 and later** with specific format checks, while v1.1 and earlier versions accept opaque data without validating internal structure or padding. This creates protocol-version-dependent behavior where older endpoints are more permissive.

**Evidence**:
- Code analysis: `libspdm_com_opaque_data.c:277-345` — `libspdm_process_general_opaque_data_check()` only validates opaque data if `connection_version >= SPDM_MESSAGE_VERSION_12` (line 277) and format is OPAQUE_DATA_FORMAT_1 (line 279)
- Code analysis: `libspdm_com_opaque_data.c:102-131` — In `libspdm_get_element_from_opaque_data_with_element_id()`, different header structures used for v1.2+ (spdm_general_opaque_data_table_header_t) vs v1.1 (secured_message_general_opaque_data_table_header_t), but v1.1 path does fewer spec_id/version checks
- Code analysis: `libspdm_req_get_measurements.c:454-461` — Requester validates opaque data format only if v1.2+ and format is OPAQUE_DATA_FORMAT_NONE (lines 454-461), not for v1.1

**Affected code paths**:
- Responder opaque data generation: `libspdm_get_response_measurements()` lines 330-356
- Requester opaque data validation: `libspdm_try_get_measurement()` lines 449-461 (signature case) and lines 454-461 (non-signature case)

**Suspected vulnerabilities**:
1. A v1.1 responder could send malformed opaque data (invalid element structure, missing padding) that a v1.1 requester accepts but a v1.2+ requester rejects
2. Version downgrade attack: if negotiation can be manipulated to v1.1, opaque data validation is bypassed entirely

**Suggested modeling approach**:
- **Variables**: `opaque_data_validation_enabled` (boolean flag based on version and format support)
- **Actions**: Split opaque data reception into "parse_opaque_data_header", "validate_opaque_structure" (conditional on version)
- **Granularity**: Model as variant actions based on SPDM version

**Priority**: Medium  
**Rationale**: Opaque data is vendor-extensible and less critical to core attestation than measurements themselves, but version-dependent validation gaps could allow subtle protocol violations if peers have different version assumptions.

---

### Family 5: Requester Context Echo-Back Validation

**Mechanism**: In SPDM v1.3+, the responder echoes back the requester-provided context (8 bytes) in the response, and the requester verifies it matches. However, the **context is optional (can be all-zeros) and the validation is only performed for v1.3+**, creating potential for context confusion or downgrade.

**Evidence**:
- Code analysis: `libspdm_req_get_measurements.c:322-335` — Requester context is included in v1.3+ requests (lines 322-335); zeros it if NULL (line 324)
- Code analysis: `libspdm_rsp_measurements.c:487-492` — Responder copies context from request to response for v1.3+ (lines 487-492); no context in earlier versions
- Code analysis: `libspdm_req_get_measurements.c:511-517` — Requester validates context matches only for v1.3+ (lines 511-517); comparison uses `libspdm_consttime_is_mem_equal()` (good practice)
- Code analysis: `libspdm_req_get_measurements.c:507` — Context is checked AFTER append to message M, so a mismatched context would be detected only after transcript was updated

**Affected code paths**:
- Requester: `libspdm_try_get_measurement()` lines 322-335 (send) and 511-517 (verify)
- Responder: `libspdm_get_response_measurements()` lines 487-492

**Suspected vulnerabilities**:
1. If requester sends zero context, responder echoes zero context, and requester accepts it — context provides no binding
2. Requester processes response and updates message M before validating context (line 527-528 append happens before line 544 reset) — if context validation fails, message M must be reset, but it's only reset after all validation

**Suggested modeling approach**:
- **Variables**: `requester_context_sent`, `requester_context_received`, `context_validated`
- **Actions**: Model context generation and echo-back as separate steps; validate context before appending response to message M
- **Granularity**: Context validation as a guard before transcript finalization

**Priority**: Medium  
**Rationale**: Context is a v1.3+ feature; validation happens but order of operations (append before validate) could leave stale transcript if validation fails mid-way. Low severity because const-time comparison is used, but sequence matters for transcript integrity.

---

### Family 6: Inconsistent Signature Verification Path for Slot ID

**Mechanism**: The responder validates slot_id_param based on the presence of a certificate chain or public key, while the requester uses a different validation path during signature verification. The **slot ID interpretation differs between responder signature generation and requester signature verification**.

**Evidence**:
- Code analysis: `libspdm_rsp_measurements.c:421-449` — Responder validates slot_id_param at lines 425-432 (checks if <= SPDM_MAX_SLOT_COUNT or == 0xF), then checks certificate presence at lines 433-449
- Code analysis: `libspdm_req_get_measurements.c:11-94` — Requester verifies signature using slot_id parameter; gets public key from either cert chain (slot_id < SPDM_MAX_SLOT_COUNT) or public key provision (slot_id == 0xF)
- Code analysis: `libspdm_req_get_measurements.c:66-93` — For non-0xF slot IDs, requester extracts leaf cert from chain (lines 71-89); for 0xF, uses peer_public_key_provision (line 91)
- Code analysis: `libspdm_rsp_measurements.c:441-449` — Responder checks multi_key_conn_rsp for v1.3+ to validate key usage (lines 451-460)

**Affected code paths**:
- Responder: `libspdm_get_response_measurements()` lines 423-469
- Requester: `libspdm_verify_measurement_signature()` lines 48-94

**Suspected vulnerabilities**:
1. Responder signs using one slot_id path, requester verifies using a different cert/key lookup path — if cert chain is missing or modified, mismatch could occur
2. v1.3+ multi-key mode validates key usage (line 454-460), but v1.1/v1.2 paths skip this — downgrade attack to v1.1 could allow signing with wrong key

**Suggested modeling approach**:
- **Variables**: `slot_id`, `cert_chain_available[slot_id]`, `public_key_available`, `key_usage_valid`
- **Actions**: Model slot_id resolution as a separate validation action; ensure both responder and requester agree on key source
- **Granularity**: One action for responder slot validation, one for requester key lookup

**Priority**: Medium  
**Rationale**: Signature verification requires consistent slot ID interpretation; divergence between responder and requester could lead to accepting a signature signed with the wrong key. v1.3+ multi-key addition creates new path that earlier versions don't have.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| **Version negotiation and version-specific message format** | Family 1: version divergence is root cause of multiple code path inconsistencies | Introduce `spdm_version` state variable; model message parsing as version-dependent actions that fail if format doesn't match version |
| **Session state validation** | Family 2: session state and capability checks are skipped in some paths | Add `session_state` variable (UNSECURED, SESSION_ESTABLISHED); make signature generation conditional on correct session state |
| **Multi-step transcript building** | Family 3: non-atomic operations create crash windows during signature generation | Model transcript as separate variable; split signature generation into "append request", "append response", "compute signature", "reset transcript" with crash injection between steps |
| **Opaque data structure validation** | Family 4: validation only in v1.2+ creates version-dependent behavior | Add opaque data validation as version-conditional action; model validation failure as error path |
| **Requester context binding** | Family 5: context echo-back is v1.3+ feature with ordering issues | Model context as variable; validate context BEFORE appending final response to transcript |
| **Signature computation and verification** | Families 1, 3, 5, 6: signature is dependent on transcript, version, and slot ID | Model responder signing and requester verification as separate but coordinated actions; use the same L1/L2 calculation model for both |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| **Cryptographic algorithms** | libspdm uses pluggable crypto (RSA, ECDSA, post-quantum); algorithm correctness is crypto-library's responsibility, not SPDM protocol's. Model signature verification as abstract "check_signature()" that is correct or fails. |
| **Random number generation** | Nonce generation is implementation detail; model nonce as a free variable (unknown input) rather than simulating PRNG. |
| **Buffer overflow / memory safety** | libspdm is C code; buffer sizes are checked at each step. Model message sizes as abstract quantities; don't simulate exact byte counts unless a specific size boundary is a protocol invariant. |
| **Opaque data vendor extensions** | Opaque data is vendor-extensible and not critical to core measurement protocol. Model opaque data presence/absence but not detailed structure. |
| **Secured message encryption/decryption** | GET_MEASUREMENTS can be sent unsecured or within a secured session. Model session presence/absence but abstract away AEAD encryption/decryption details. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| VersionDependentMessageFormat | `spdm_version`, `request_format_version`, `response_format_version` | Capture version-specific message field presence/absence (slot_id_param in v1.0 vs v1.1+, context in v1.3+) | Family 1 |
| SessionStateTracking | `session_valid`, `session_state`, `capabilities_verified` | Track which validation steps have been performed before measurement collection | Family 2 |
| TranscriptAtomicity | `message_m_buffer_state`, `transcript_appended_count`, `message_m_reset_done` | Expose multi-step transcript building with crash windows | Family 3 |
| OpaqueDataVersionControl | `opaque_data_validation_enabled` | Version-conditional opaque data validation | Family 4 |
| RequesterContextBinding | `requester_context_sent`, `requester_context_validated` | Context echo-back and validation ordering | Family 5 |
| SlotIDResolution | `slot_id`, `key_source_responder`, `key_source_requester` | Ensure consistent slot ID interpretation between responder and requester | Family 6 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| **VersionConsistency** | Safety | Request spdm_version == Response spdm_version (no version mismatch responses) | Family 1 |
| **SessionValidatedBeforeMeasurement** | Safety | If session is required, session_state == ESTABLISHED before measurement collection | Family 2 |
| **CapabilitiesValidatedBeforeMeasurement** | Safety | Capability flags are validated before measurement collection based on request attributes | Family 2 |
| **TranscriptResetAfterSignature** | Safety | message_m_reset_done == true after signature generation (no stale transcript on next request) | Family 3 |
| **SignatureCoversFullTranscript** | Safety | Signature is computed over request + response (no partial transcripts) | Family 3 |
| **OpaqueDataStructureValid** | Safety | If opaque data is present and version >= 1.2, opaque data structure is valid (elements aligned, padding correct) | Family 4 |
| **ContextEchoedCorrectly** | Safety | If v1.3+, requester_context in response matches requester_context in request | Family 5 |
| **ContextValidatedBeforeResponseAppend** | Safety | requester_context_validated == true before response is appended to transcript | Family 5 |
| **SlotIDConsistency** | Safety | Signature is generated with same slot ID that requester used for verification | Family 6 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC1 | If responder negotiates to v1.0 but receives a v1.1+ request (with slot_id_param field), does responder fail validation or process garbage? | VersionConsistency, INVALID_REQUEST error | Family 1 |
| MC2 | If session state is not ESTABLISHED (e.g., SESSION_NOT_STARTED), can responder still generate measurements? | SessionValidatedBeforeMeasurement | Family 2 |
| MC3 | If responder crashes after appending request to message M but before appending response, does the next measurement request see stale M data? | TranscriptResetAfterSignature | Family 3 |
| MC4 | If responder generates signature but then crashes before resetting message M, and next request happens in same session, is the old signature reused? | SignatureCoversFullTranscript | Family 3 |
| MC5 | In v1.1 mode, can a responder send malformed opaque data (invalid element count, truncated elements) that a v1.1 requester accepts? | OpaqueDataStructureValid | Family 4 |
| MC6 | If v1.3 requester sends non-zero context but responder echoes different context (e.g., due to state corruption), is the mismatch detected before or after transcript is finalized? | ContextEchoedCorrectly, ContextValidatedBeforeResponseAppend | Family 5 |
| MC7 | If responder is configured with multiple slots and requester asks for signature with slot_id=0xF (public key), but responder has no public key provision, what error is returned? | SlotIDConsistency | Family 6 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV1 | Verify that signature generation correctly includes all bytes of request + response in transcript, no skipped fields | Unit test: mock measurement_collection() to return fixed values, verify signature over known transcript |
| TV2 | Verify that message_m is actually reset after signature generation (not left in stale state) | Integration test: make two consecutive GET_MEASUREMENTS requests, verify signatures differ if measurements changed |
| TV3 | Verify that requester context (if provided) is correctly copied in request and echoed in response for v1.3+ | Unit test: send known context value, verify response contains exact same bytes |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | Verify that all error paths that call `libspdm_reset_message_m()` actually reset the transcript (not a no-op). Check that LIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT compile flag doesn't create paths where reset is skipped. | Review all calls to libspdm_reset_message_m() in libspdm_rsp_measurements.c and libspdm_req_get_measurements.c; verify reset happens in both RECORD and non-RECORD modes |
| CR2 | Check for version negotiation conflicts: if requester and responder negotiate different SPDM versions due to out-of-order message arrival, what is the recovery mechanism? | Review version negotiation in GET_VERSION / NEGOTIATE_ALGORITHMS; verify GET_MEASUREMENTS checks negotiated version consistently |
| CR3 | In libspdm_req_get_measurements.c line 511-517, context is validated using libspdm_consttime_is_mem_equal(). Verify this function is actually constant-time (no early exit on mismatch). | Audit libspdm_consttime_is_mem_equal() implementation for timing side-channels |

---

## 7. Reference Pointers

- **Primary Analysis Files**:
  - `libspdm_rsp_measurements.c`: Responder GET_MEASUREMENTS handler (79-533)
  - `libspdm_req_get_measurements.c`: Requester GET_MEASUREMENTS sender/receiver (11-870)
  - `libspdm_com_opaque_data.c`: Opaque data parsing and validation (full file)

- **SPDM Specification**:
  - DSP0274 SPDM Specification versions 1.0.2, 1.1.4, 1.2.3, 1.3.2
  - GET_MEASUREMENTS request/response format defined in each version (section varies)

- **Key Data Structures**:
  - `spdm_get_measurements_request_t`: Request format (version-dependent fields)
  - `spdm_measurements_response_t`: Response format (version-dependent fields)
  - `spdm_measurement_block_dmtf_t`: Measurement block structure
  - `spdm_general_opaque_data_table_header_t` (v1.2+) vs `secured_message_general_opaque_data_table_header_t` (v1.1 and earlier)

- **Related Functions**:
  - `libspdm_generate_measurement_signature()` (79-78): Responder signature generation
  - `libspdm_verify_measurement_signature()` (requester, 11-142): Requester signature verification
  - `libspdm_measurement_collection()`: Platform callback for measurement data (app-specific)
  - `libspdm_append_message_m()`: Transcript building helper
  - `libspdm_reset_message_m()`: Transcript reset helper
  - `libspdm_process_general_opaque_data_check()`: Opaque data validation
  - `libspdm_get_element_from_opaque_data_with_element_id()`: Opaque data parsing

---

## Summary

This analysis identifies **6 Bug Families** in libspdm's GET_MEASUREMENTS implementation, with primary risk in:

1. **Version-dependent message format handling** (Family 1) — inconsistent parsing across v1.0, v1.1, v1.2, v1.3
2. **Non-atomic transcript building** (Family 3) — crash windows during signature generation and reset
3. **State validation gaps** (Family 2) — session and capability checks skipped in certain paths

These are well-suited for TLA+ model checking because they are **protocol-level logic questions** about message ordering, state transitions, and version-dependent branching — not implementation details. The next phase (Spec Generation) should focus on modeling these as separate actions with version-conditional guards and crash injection points.
