# Modeling Brief: libspdm PSK Exchange Protocol

## System Overview

**System**: libspdm-psk-exchange (Pre-Shared Key Session Establishment)  
**Language**: C  
**Core Logic**: ~1500 LOC across requester, responder, and common session management  
**Category**: **Category A (Distributed / Message-Passing)**  
**Justification**: SPDM PSK exchange is a message-passing protocol with handshake phases, cryptographic state negotiation, and session establishment across two independent endpoints (requester/responder).

**Algorithm**: SPDM (Secure Protocol and Data Model) PSK-based session establishment per DMTF DSP0274 (v1.1–v1.4)

**Key Architectural Features**:
- Requester-initiated session with pre-shared key (PSK) hint
- Two-phase exchange: PSK_EXCHANGE (negotiation) → PSK_FINISH (confirmation)
- Transcript hashing (TH) for handshake integrity
- Opaque data exchange for version negotiation (secured message version)
- Session ID generation from requester and responder session IDs
- Separate handshake and data session keys

---

## Bug Families

### Family 1: Path Inconsistency in Opaque Data Validation

**Mechanism**: Requester-side and responder-side message parsers apply asymmetric validation rules to the same message fields (opaque_length), allowing invalid messages on one path that would be rejected on the other.

**Evidence**:
- Historical: GitHub issue #3597 "PSK_FINISH/PSK_FINISH_RSP Missing Explicit Responder Max-Bound Check for SPDM 1.4 Request Opaque Length" (2026-05-20); issue #3592 "PSK_FINISH/PSK_FINISH_RSP Opaque-Length Validation and Response Completeness Gaps" (2026-04-22)
- Code analysis:
  - **Requester PSK_EXCHANGE**: `libspdm_req_psk_exchange.c:425-428` explicitly checks `if (spdm_response->opaque_length > SPDM_MAX_OPAQUE_DATA_SIZE) { status = LIBSPDM_STATUS_INVALID_MSG_FIELD; goto receive_done; }`
  - **Responder PSK_EXCHANGE**: `libspdm_rsp_psk_exchange_rsp.c:238-241` only checks size consistency `if (request_size < ... opaque_length)` without explicit max-bound reject
  - **Requester PSK_FINISH_RSP**: `libspdm_req_psk_finish.c:292-295` explicitly checks `if (opaque_data_size > SPDM_MAX_OPAQUE_DATA_SIZE)`
  - **Responder PSK_FINISH**: `libspdm_rsp_psk_finish_rsp.c:171-182` reads opaque_data_size but lacks explicit max-bound check

**Affected code paths**: 
- `libspdm_req_psk_exchange()` → receive path (lines 425-428)
- `libspdm_get_response_psk_exchange()` → request parsing (lines 238-241)
- `libspdm_try_send_receive_psk_finish()` → receive path (lines 292-295)
- `libspdm_get_response_psk_finish()` → request parsing (lines 171-182)

**Suggested modeling approach**:
- **Variables**: `opaque_length_valid` flag; separate validation state for requester and responder
- **Actions**: Split message reception into two sub-actions: (1) parse header + length, (2) validate bounds. Model the asymmetry by allowing validation to fail only on requester side
- **Granularity**: Model as distinct action variants per endpoint (requester_recv vs responder_recv) to capture path divergence
- **Invariant**: "If a message is accepted by requester, it must pass explicit size bounds; responder must apply equivalent bounds"

**Priority**: High  
**Rationale**: This is a confirmed inconsistency (documented in open GitHub issues), affects two message types (PSK_EXCHANGE, PSK_FINISH), and could allow a malicious responder or MITM to inject messages with opaque_length values that bypass requester-side validation. TLA+ can model the asymmetry and verify whether the responder-side lack of explicit bounds checking creates an exploitable gap.

---

### Family 2: Session ID Resource Leak on Allocation → Error Path

**Mechanism**: `libspdm_try_send_receive_psk_exchange()` allocates a requester session ID early in the function, but multiple error-return paths (before session assignment) release the sender buffer but do NOT deallocate the session ID, leaving a dangling allocated ID that wastes the session ID pool.

**Evidence**:
- Historical: GitHub issue #1614 "libspdm_try_send_receive_psk_exchange function should call libspdm_release_sender_buffer function before return error." (2023-06-26, CLOSED); issue #2090 "Miss libspdm_free_session_id before return libspdm_generate_error_response" (2023-06-06, CLOSED)
- Code analysis: `libspdm_req_psk_exchange.c:199-235`
  - Line 199: `req_session_id = libspdm_allocate_req_session_id(spdm_context, true);`
  - Line 200-201: Check allocation success, return if fail (acceptable, no leak)
  - Lines 213, 218, 224, 228: Early returns after algorithm validation (inside lines 205-230 block) without freeing req_session_id
  - Line 235: Return from `libspdm_acquire_sender_buffer()` error without freeing req_session_id

**Affected code paths**:
- PSK_EXCHANGE requester, algorithm validation phase (lines 205-230): 4 early return sites
- PSK_EXCHANGE requester, sender buffer acquisition (line 233-235): 1 return site

**Suggested modeling approach**:
- **Variables**: Track `allocated_session_ids` set; model allocation and deallocation as explicit transitions
- **Actions**: Model "allocate_session_id" and "free_session_id" as separate actions; add precondition checks on free
- **Granularity**: One action per allocation/deallocation pair; include error paths as distinct action variants
- **Invariant**: "If a session ID is allocated, it must eventually be freed, either on success (when assigned) or on error (before returning)"

**Priority**: Medium  
**Rationale**: This is a resource exhaustion bug confirmed in historical issues. The impact is bounded (session ID pool is finite, limited by `max_psk_session_count`), but a malicious peer triggering repeated algorithm-validation failures could exhaust the pool and cause legitimate sessions to fail to allocate. TLA+ can verify that all allocation/deallocation paths are paired correctly.

---

### Family 3: Opaque Data Handling and Secured Message Version Negotiation

**Mechanism**: Discrepancy in how opaque data is treated during PSK_EXCHANGE: the requester sends opaque data (version selection list) and expects the responder's opaque data to contain version selection data, but the responder is permitted to either return default version data OR let the integrator override with custom opaque data. This can lead to version mismatch or missing version negotiation.

**Evidence**:
- Historical: GitHub issue #1993 "Handling of key exchange opaque data" (2024-06-23, OPEN); follow-up comments discuss DSP0277 mandatory version field
- Code analysis: 
  - **Requester PSK_EXCHANGE send**: `libspdm_req_psk_exchange.c:312-314` builds opaque data via `libspdm_build_opaque_data_supported_version_data()` (default) or uses caller-provided data
  - **Requester PSK_EXCHANGE receive**: `libspdm_req_psk_exchange.c:402-407` processes responder opaque data to extract `secured_message_version`
  - **Responder PSK_EXCHANGE**: `libspdm_rsp_psk_exchange_rsp.c:287-314` calls integrator hook `libspdm_psk_exchange_rsp_opaque_data()` first, falls back to default version selection if hook returns false
  - **Design asymmetry**: Responder's opaque data is optional/customizable, but requester always expects it to contain version data

**Affected code paths**:
- Requester: `libspdm_try_send_receive_psk_exchange()` opaque send (lines 312-314) and receive parsing (lines 402-407)
- Responder: `libspdm_get_response_psk_exchange()` opaque generation (lines 274-341)

**Suggested modeling approach**:
- **Variables**: `responder_opaque_data`, `secured_message_version`, `use_default_opaque`
- **Actions**: Split opaque data handling into three actions: (1) requester builds and sends, (2) responder decides (hook vs default), (3) requester parses response
- **Granularity**: One action per phase; model hook failure/success as nondeterministic branch
- **Invariant**: "If opaque data is present in PSK_EXCHANGE_RSP, it must decode to valid secured_message_version" OR "secured_message_version must be set by end of PSK_EXCHANGE (either from opaque data or default)"

**Priority**: Medium  
**Rationale**: This is a specification interpretation issue (DSP0277 vs DSP0274 requirements on version negotiation). The bug is not a crash or data loss, but rather a gap in the requirement enforcement. TLA+ can model both requester and responder expectations and verify whether the asymmetry creates a scenario where version negotiation silently succeeds with mismatched versions.

---

### Family 4: Context Length Validation and Boundary Checks

**Mechanism**: Context buffers (requester_context, responder_context) are validated for presence/absence based on responder capability flags, but there is no explicit upper-bound check against LIBSPDM_PSK_CONTEXT_LENGTH during responder-side request parsing, only implicit size-flow checks.

**Evidence**:
- Code analysis: 
  - **Requester PSK_EXCHANGE request build**: `libspdm_req_psk_exchange.c:253-258` sets `spdm_request->context_length = requester_context_in_size` with assertion `LIBSPDM_ASSERT (requester_context_in_size <= LIBSPDM_PSK_CONTEXT_LENGTH)`
  - **Requester PSK_EXCHANGE response receive**: `libspdm_req_psk_exchange.c:438-441` checks `if (spdm_response->context_length == 0)` based on responder capability; no explicit max bound
  - **Responder PSK_EXCHANGE request parse**: `libspdm_rsp_psk_exchange_rsp.c:238-241` size-flow check includes context_length but no explicit `> LIBSPDM_PSK_CONTEXT_LENGTH` reject
  - **Responder PSK_EXCHANGE response build**: No explicit bounds check before reading context

**Affected code paths**:
- Requester PSK_EXCHANGE: request build (lines 253-258), response receive validation (lines 438-441)
- Responder PSK_EXCHANGE: request parse (lines 238-241)

**Suggested modeling approach**:
- **Variables**: `context_length`, `capability_flag_psk_responder`
- **Actions**: Model context parsing as two steps: (1) read length, (2) validate bounds given capability
- **Granularity**: One action for requester send, one for responder receive/validate
- **Invariant**: "context_length must be 0 if responder lacks PSK_CAP_RESPONDER, else 0 ≤ context_length ≤ LIBSPDM_PSK_CONTEXT_LENGTH"

**Priority**: Low  
**Rationale**: Less immediately exploitable than Family 1 (asymmetric validation), as size-flow checks still apply. But it is part of the same pattern (inconsistent explicit bounds checking). Include for completeness of pattern analysis.

---

### Family 5: Handshake State Validation and Session Lifecycle

**Mechanism**: Session state transitions during PSK handshake are validated via `libspdm_session_state_t` enum, but the validation logic differs between requester and responder, and there is no explicit interlock preventing, e.g., a PSK_FINISH request to an already-established session or a PSK_EXCHANGE request during an in-progress handshake.

**Evidence**:
- Historical: GitHub issue #3279 "What happens if try to send FINISH/PSK_FINISH request to an already established session?" (2025-10-13, CLOSED as question/design); issue #3171 "Some invocations of libspdm_reset_message_buffer_via_request_code do not have session info" (2025-08-25, OPEN)
- Code analysis:
  - **Requester PSK_EXCHANGE**: No pre-check for "no active session" (checked implicitly by session allocation)
  - **Requester PSK_FINISH**: Line 163 in `libspdm_req_psk_finish.c` checks session state `if (session_state != LIBSPDM_SESSION_STATE_HANDSHAKING)` — enforces correct state
  - **Responder PSK_FINISH**: Line 160 in `libspdm_rsp_psk_finish_rsp.c` also checks state `if (session_state != LIBSPDM_SESSION_STATE_HANDSHAKING)`
  - **Gap**: No check preventing PSK_EXCHANGE on top of an already-established session (the check at `libspdm_rsp_psk_exchange_rsp.c:164-168` uses `last_spdm_request_session_id_valid`, not session state)

**Affected code paths**:
- Requester: `libspdm_try_send_receive_psk_exchange()` (no state check)
- Requester: `libspdm_try_send_receive_psk_finish()` (has state check at line 163)
- Responder: `libspdm_get_response_psk_exchange()` (uses session ID flag, not state)
- Responder: `libspdm_get_response_psk_finish()` (has state check at line 160)

**Suggested modeling approach**:
- **Variables**: `session_state`, `active_session_id`, `last_request_session_id_valid`
- **Actions**: Model as pre-check on each handler (RequestReceived_PSK_EXCHANGE, RequestReceived_PSK_FINISH); each action verifies state before proceeding
- **Granularity**: One action per request type; state validation is part of the precondition
- **Invariant**: "PSK_EXCHANGE must be received when no session is active (or after prior session is cleared); PSK_FINISH must be received when session is in HANDSHAKING state"

**Priority**: Medium  
**Rationale**: This is a state machine correctness issue. While the current implementation prevents many violations through other checks (session ID validation, state checks on FINISH), the lack of an explicit precondition check on PSK_EXCHANGE leaves a potential gap. TLA+ can verify the state transitions are consistent across both endpoints.

---

## Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| **Opaque data validation asymmetry** | Family 1 evidence: requester validates max-bound explicitly, responder doesn't; affects PSK_EXCHANGE and PSK_FINISH | Add `opaque_max_bound_check` flag; split message-receive action into two: (1) parse, (2) validate bounds; require both requester and responder to apply bounds |
| **Session ID lifecycle** | Family 2 evidence: allocated IDs not freed on error paths before `libspdm_assign_session_id()`; affects pool exhaustion | Track allocation/deallocation pairs via separate action variants; add precondition `id_is_allocated(session_id)` before `free_session_id()` |
| **Secured message version negotiation** | Family 3 evidence: opaque data handling asymmetry; responder can skip version data or override via hook; requester assumes version is present | Model opaque data as explicit message field; track `version_negotiation_complete` flag; require both endpoints to agree on version by end of PSK_EXCHANGE |
| **Session state machine** | Family 5 evidence: state checks missing on PSK_EXCHANGE requester side; different paths to establish session | Explicitly model state transitions (IDLE → HANDSHAKING → ESTABLISHED); require state preconditions on all handlers |
| **Context and hint validation** | Family 4 evidence: implicit rather than explicit bounds; context_length lacks max-bound check on responder | Add explicit context_length bounds checks mirroring opaque_length treatment; add hint_length bounds checks |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| **Cryptographic primitives (HMAC, hash)** | Implementation-level detail; crypto correctness is out of scope for protocol state machine. Assume crypto functions work correctly. |
| **Transcript caching (TH management)** | Implementation optimization (caching vs recomputation); not a protocol-level concern. Assume TH is computed correctly. |
| **Message buffer management (acquire/release sender/receiver buffer)** | Transport-layer resource management; orthogonal to protocol logic. Assume buffers are acquired/released correctly. |
| **Capability flag interactions** | While important, detailed capability negotiation is part of pre-requisite (GET_CAPABILITIES) phase, not PSK_EXCHANGE scope. Assume capabilities are pre-negotiated. |
| **Measurement hash computation** | Measurement summary hash is part of device measurement subsystem. Assume it is computed correctly; focus on how it flows through PSK_EXCHANGE. |
| **Heartbeat period and timer semantics** | Timing behavior is separate from handshake correctness. Heartbeat is a post-session-establishment feature. |

---

## Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| opaque_max_bound_validation | opaque_length, SPDM_MAX_OPAQUE_DATA_SIZE, opaque_valid | Explicit max-bound check on opaque_length in both requester and responder message receive paths | Family 1 |
| session_id_allocation_tracking | allocated_req_session_ids (set), current_psk_session_count | Track allocated-but-not-assigned session IDs; verify all allocations are freed on error | Family 2 |
| secured_message_version_negotiation | opaque_data (message field), secured_message_version, version_select_data, use_default_opaque | Explicit version negotiation via opaque data; requester builds list, responder returns selection | Family 3 |
| session_state_preconditions | session_state (IDLE, HANDSHAKING, ESTABLISHED), active_session_id | Enforce state preconditions on PSK_EXCHANGE and PSK_FINISH; PSK_EXCHANGE requires no active session, PSK_FINISH requires HANDSHAKING state | Family 5 |
| context_length_bounds | context_length, LIBSPDM_PSK_CONTEXT_LENGTH, responder_context_flag | Explicit bounds check on context_length in responder PSK_EXCHANGE response parse | Family 4 |

---

## Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| OpaqueLengthConsistency | Safety | If opaque_length > 0, then opaque_length ≤ SPDM_MAX_OPAQUE_DATA_SIZE on both requester and responder message receive | Family 1 |
| SessionIDAllocationFreeing | Safety | For all req_session_id allocations: if allocated and not assigned to a session, must be freed before function returns | Family 2 |
| SecuredMessageVersionAgreement | Safety | By end of PSK_EXCHANGE, both requester and responder must have agreed on secured_message_version (either from opaque data or default) | Family 3 |
| PSKExchangeNoActiveSession | Safety | PSK_EXCHANGE request must be received when no session with that session_id is active | Family 5 |
| PSKFinishHandshakingState | Safety | PSK_FINISH request must be received only when session is in HANDSHAKING state | Family 5 |
| ContextLengthBounds | Safety | responder_context_length must be 0 if responder lacks PSK_CAP_RESPONDER, else 0 ≤ responder_context_length ≤ LIBSPDM_PSK_CONTEXT_LENGTH | Family 4 |
| HandshakeTranscriptIntegrity | Safety | Transcript (TH) must be identical at requester and responder by end of PSK_FINISH for HMAC verification to succeed | Families 1, 3 (structural) |

---

## Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC1 | Can a responder accept a PSK_EXCHANGE_RSP with opaque_length = SPDM_MAX_OPAQUE_DATA_SIZE + 1 if the requester's size-flow check is bypassed? | OpaqueLengthConsistency violation on responder side (no explicit max-bound check); requester side would reject. | Family 1 |
| MC2 | If PSK_EXCHANGE request parsing fails after req_session_id allocation but before session assignment, is the allocated ID freed before returning? | SessionIDAllocationFreeing violation; allocated_req_session_ids grows unbounded. | Family 2 |
| MC3 | Can a responder return PSK_EXCHANGE_RSP with empty opaque data (opaque_length = 0) when requester expects version selection data, leading to version mismatch? | SecuredMessageVersionAgreement violation; version_negotiation_complete flag remains false. | Family 3 |
| MC4 | Can PSK_EXCHANGE be initiated when a PSK session is already established on the same session_id? | PSKExchangeNoActiveSession violation; responder accepts overlapping handshake. | Family 5 |
| MC5 | If responder_context_length is sent as non-zero by a responder lacking PSK_CAP_RESPONDER flag, is it caught by requester validation? | ContextLengthBounds violation; requester checks but responder generation might be inconsistent. | Family 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV1 | Resource leak on algorithm validation error in PSK_EXCHANGE | Unit test: trigger algorithm check failure (e.g., measurement_spec mismatch) after allocate_req_session_id(); verify allocated ID is freed via session ID pool audit. |
| TV2 | Buffer overflow on oversized opaque_length | Fuzz test: send PSK_EXCHANGE/PSK_FINISH with opaque_length = 0xFFFF; verify boundary checks on both endpoints. |
| TV3 | Secured message version default fallback | Integration test: responder with integrator hook returning false; verify requester receives and accepts default version selection data. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | Explicit bounds checks missing on responder-side opaque_length parsing in PSK_EXCHANGE and PSK_FINISH | Add explicit check: `if (opaque_length > SPDM_MAX_OPAQUE_DATA_SIZE) return INVALID_MSG_FIELD;` in `libspdm_get_response_psk_exchange()` (after line 241) and `libspdm_get_response_psk_finish()` (after line 182). |
| CR2 | Session ID leak on early error returns in PSK_EXCHANGE requester | Refactor early returns to use common cleanup path with `libspdm_free_session_id()` call before returning. Alternatively, wrap allocation and defer assignment until after all validation checks pass. |
| CR3 | Context length validation inconsistency | Add explicit bounds check on responder-side: `if (context_length > LIBSPDM_PSK_CONTEXT_LENGTH) return INVALID_MSG_FIELD;` in `libspdm_get_response_psk_exchange()`. |

---

## Reference Pointers

**Artifact location**: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-psk-exchange/artifact/libspdm`

**Core source files** (lines of interest):
- `library/spdm_requester_lib/libspdm_req_psk_exchange.c:199-235` (session ID leak), `425-428` (opaque_length check)
- `library/spdm_requester_lib/libspdm_req_psk_finish.c:290-295` (opaque_length check)
- `library/spdm_responder_lib/libspdm_rsp_psk_exchange_rsp.c:238-241` (no explicit opaque check), `274-341` (opaque data handling)
- `library/spdm_responder_lib/libspdm_rsp_psk_finish_rsp.c:171-182` (no explicit opaque check)
- `library/spdm_common_lib/libspdm_com_context_data_session.c:9-40` (session info init)

**GitHub issues**:
- #3597 "PSK_FINISH/PSK_FINISH_RSP Missing Explicit Responder Max-Bound Check" (OPEN, 2026-05-20)
- #3592 "PSK_FINISH/PSK_FINISH_RSP Opaque-Length Validation Gaps" (OPEN, 2026-04-22)
- #1993 "Handling of key exchange opaque data" (OPEN, 2024-06-23)
- #1614 "libspdm_try_send_receive_psk_exchange should call libspdm_release_sender_buffer" (CLOSED, 2023-06-26)
- #2090 "Missing libspdm_free_session_id before return" (CLOSED, 2023-06-06)
- #3279 "What happens if try to send FINISH/PSK_FINISH to already established session?" (CLOSED, 2025-10-13)
- #3171 "Some invocations of libspdm_reset_message_buffer do not have session info" (OPEN, 2025-08-25)

**Specification**: DMTF DSP0274 (SPDM Protocol Specification v1.1–v1.4), DSP0277 (Secured Messages)

---

## Coverage Statistics

- **Files analyzed**: 7 core files (4 PSK handlers + 3 session management)
- **GitHub issues reviewed**: 8 (5 open, 3 closed PSK-related)
- **Code path inconsistencies identified**: 5 distinct paths per message type (requester send, requester receive, responder receive, responder send, responder build response)
- **Bug families grouped**: 5 families by shared mechanism
- **MC findings proposed**: 5
- **Code-review findings proposed**: 3
- **Test-verifiable findings proposed**: 3
