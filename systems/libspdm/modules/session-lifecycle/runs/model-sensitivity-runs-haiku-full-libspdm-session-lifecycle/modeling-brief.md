# SPDM Session Lifecycle Modeling Brief

## 1. System Overview

**System**: libspdm (DMTF Security Protocol and Data Model)  
**Scope**: Session lifecycle operations - HEARTBEAT, KEY_UPDATE, END_SESSION  
**Language**: C  
**Core LOC**: ~1500 lines (requester + responder handlers)  
**Category**: **Category A (Distributed / Message-Passing)**  
**Category Justification**: SPDM is a protocol-based system with request-response message exchanges between requester and responder. State machines manage session lifecycle through multi-message sequences with explicit protocol state transitions. Session safety depends on coordinating state changes across the request-response boundary with potential message loss.

**Reference Algorithm**: DMTF SPDM v1.3 specification (DSP0277)  
**Key Protocol Features**:
- Secured sessions with session IDs
- Heartbeat for keep-alive in established sessions
- Key update with two-phase commit (UPDATE + VERIFY)
- Responder-initiated key updates via encapsulation
- Session termination with optional cache preservation

**Concurrency Model**: Single-threaded event loop (libspdm is primarily sync/blocking); session operations are serialized per session.

---

## 2. Bug Families

### Family 1: Requester-Responder Key Update State Divergence

**Mechanism**: Multi-phase key update (UPDATE + VERIFY) requires both sides to coordinate state creation and activation. The requester pre-creates keys before receiving the responder's ACK, creating a window where state can diverge if the ACK is lost or delayed.

**Evidence**:
- Code analysis: 
  - libspdm_req_key_update.c:111-122 — Requester creates responder key **before** receiving UPDATE_ALL_KEYS ACK
  - libspdm_req_key_update.c:167-182 — If UPDATE_ALL_KEYS response fails, requester tries to revert responder key to old one
  - libspdm_rsp_key_update_ack.c:140-192 — Responder creates requester key, creates responder key, activates responder key in sequence
  - libspdm_req_key_update.c:184-195 — Requester activates responder key only after ACK received

**Affected code paths**: 
- `libspdm_try_key_update()` (requester UPDATE_ALL_KEYS path)
- `libspdm_get_response_key_update()` (responder KEY_UPDATE handler)
- `libspdm_activate_update_session_data_key()`

**Suggested modeling approach**:
- Variables: session_key_state (IDLE → KEY_CREATED → KEY_ACTIVATED), pending_key_update_phase (NONE, UPDATE, VERIFY)
- Actions: split UPDATE into separate "create" and "activate" steps; model message loss between UPDATE request and ACK
- Granularity: UPDATE_ALL_KEYS should be a multi-step action to expose the divergence window

**Priority**: High  
**Rationale**: This is the core protocol safety mechanism for symmetric key synchronization. A divergence here allows one side to have keys the other doesn't, breaking confidentiality. Past SPDM implementations have had key-synchronization bugs (e.g., ECC identity issues, salt reuse); this state coordination is a known bug-dense area.

---

### Family 2: Key Update State Machine Guard Validation

**Mechanism**: The responder maintains `last_key_update_request` to enforce valid state transitions: UPDATE_KEY must follow an IDLE state (all zeros), VERIFY_NEW_KEY must follow UPDATE. The check uses constant-time comparison, but doesn't validate recovery from partial states or concurrent key-update attempts.

**Evidence**:
- Code analysis:
  - libspdm_rsp_key_update_ack.c:108-116 — Uses `libspdm_consttime_is_mem_equal(...&spdm_key_init_update_operation)` to validate state
  - libspdm_rsp_key_update_ack.c:194-199 — VERIFY_NEW_KEY requires prior UPDATE (checks prev param1)
  - libspdm_rsp_encap_key_update.c:97-102, 141-146 — Encapsulated key update follows same state machine
  - libspdm_com_context_data_session.c:75 — `last_key_update_request` is zeroed during session init, but not explicitly persisted

**Affected code paths**:
- `libspdm_get_response_key_update()` switch cases: UPDATE_KEY, UPDATE_ALL_KEYS, VERIFY_NEW_KEY
- `libspdm_get_encap_response_key_update()` (responder-initiated update variant)

**Suggested modeling approach**:
- Variables: prev_key_update_operation (tracks last operation: NONE, UPDATE_KEY, UPDATE_ALL_KEYS, VERIFY)
- Actions: model each key update request type separately; add failure injection at the consttime check
- Granularity: The state machine should be part of the session state; violations should trigger error responses

**Priority**: High  
**Rationale**: The state machine enforces protocol sequencing. A bug here allows UPDATE_KEY to be issued twice, or VERIFY to occur before UPDATE, which would desynchronize keys or leave keys in an inconsistent state. The constant-time check is security-critical (timing attack prevention) but adds complexity to the state machine.

---

### Family 3: Asymmetry Between Regular and Encapsulated Key Updates

**Mechanism**: Requester-initiated KEY_UPDATE supports both UPDATE_KEY and UPDATE_ALL_KEYS. Responder-initiated ENCAP_KEY_UPDATE (in heartbeat encapsulation) only supports UPDATE_KEY. This asymmetry could cause protocol violations if a responder attempts bidirectional update via encapsulation.

**Evidence**:
- Code analysis:
  - libspdm_rsp_encap_key_update.c:114-116 — `SPDM_KEY_UPDATE_OPERATIONS_UPDATE_ALL_KEYS: result = false; break;` — explicitly rejects this operation
  - libspdm_req_key_update.c:95-99 — Requester supports both UPDATE_KEY and UPDATE_ALL_KEYS
  - libspdm_rsp_key_update_ack.c:113-146 — Responder handler supports both

**Affected code paths**:
- `libspdm_get_encap_response_key_update()` — Encapsulated variant only handles UPDATE_KEY and VERIFY
- Normal KEY_UPDATE handlers have no such restriction

**Suggested modeling approach**:
- Variables: encap_context.last_encap_request (tracks encapsulated requests separately)
- Actions: separate actions for "regular key update request" and "encapsulated key update request"
- Granularity: Model both paths and assert they converge to same key state

**Priority**: Medium  
**Rationale**: The asymmetry is intentional (encapsulated updates are simpler), but it creates a dual code path that could be a source of divergence. If the responder's encapsulation logic is ever extended to support UPDATE_ALL_KEYS without updating the request path, keys could diverge.

---

### Family 4: Session End and Resource Cleanup

**Mechanism**: END_SESSION handler frees the session ID and sets session state to NOT_STARTED. If the END_SESSION_ACK message is lost, the requester still frees the session but the responder hasn't freed it, leaving a stale session object.

**Evidence**:
- Code analysis:
  - libspdm_req_end_session.c:136-141 — Requester sets session to NOT_STARTED and calls `libspdm_free_session_id()` on reception of ACK
  - libspdm_rsp_end_session_ack.c:89-94 — Responder sets end_session_attributes and preserves negotiated state flag but does NOT explicitly free the session in the response path
  - libspdm_com_context_data_session.c:9-39 — Session info init/cleanup does not explicitly handle end-session state

**Affected code paths**:
- `libspdm_try_send_receive_end_session()` (requester)
- `libspdm_get_response_end_session()` (responder)
- Session ID allocation/deallocation in context management

**Suggested modeling approach**:
- Variables: session_active (boolean per session), session_freed_by_requester, session_freed_by_responder
- Actions: model END_SESSION as non-idempotent; add message loss between END_SESSION_ACK and requester
- Granularity: Track session lifecycle (IDLE → ESTABLISHED → ENDING → FREED) to detect cleanup races

**Priority**: Medium  
**Rationale**: Resource cleanup bugs can cause session ID exhaustion and are often overlooked in protocol testing. The asymmetry between requester and responder cleanup could cause leaks if sessions are re-created quickly.

---

### Family 5: Heartbeat Liveness vs. Session Establishment

**Mechanism**: HEARTBEAT can only be sent if `session_info->heartbeat_period > 0`. This requires explicit configuration and creates a dependency between session establishment parameters and heartbeat availability. If heartbeat_period is zero, no heartbeats are possible, potentially breaking timeout-dependent logic.

**Evidence**:
- Code analysis:
  - libspdm_req_heartbeat.c:63-65 — Requester checks `if (session_info->heartbeat_period == 0) return error`
  - libspdm_rsp_heartbeat.c:99-103 — Responder also checks heartbeat_period and rejects if zero
  - libspdm_com_context_data_session.c — No explicit initialization of heartbeat_period in session_info_init()

**Affected code paths**:
- `libspdm_try_heartbeat()` (requester)
- `libspdm_get_response_heartbeat()` (responder)
- Session initialization and configuration

**Suggested modeling approach**:
- Variables: heartbeat_enabled (derived from heartbeat_period > 0)
- Actions: explicitly model heartbeat_period initialization; add invariant checking that if heartbeat is sent, period was set
- Granularity: Separate action for heartbeat vs. message exchange; fail heartbeat if period is unset

**Priority**: Medium  
**Rationale**: Configuration errors are common sources of subtle bugs. If heartbeat_period is misconfigured (e.g., set to 0 unexpectedly), sessions could become unresponsive without explicit error messaging.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Key update state machine coordination | Family 1, 2: The two-phase commit (CREATE + ACTIVATE) and state validation (UPDATE → VERIFY) are core protocol safety mechanisms | Introduce explicit action for key creation vs. activation; separate state variable for update phase |
| Message loss and reordering | Category A / distributed systems: ACK loss can leave requester and responder with divergent key state | Add message-loss injection between UPDATE request and ACK, between VERIFY request and ACK |
| Session lifecycle state transitions | Family 4: Session end requires coordinated cleanup; state must be consistent (ESTABLISHED → NOT_STARTED → FREED) | Track session state as enum; assert cleanup is idempotent and consistent |
| Heartbeat availability constraints | Family 5: Heartbeat depends on heartbeat_period configuration; missing config creates availability gap | Model heartbeat_period as part of session context; check heartbeat preconditions |
| Requester-responder key activation asymmetry | Family 1: Requester pre-creates keys; responder creates on receipt. Timing creates divergence window | Model key creation and activation as separate, potentially interleaved steps |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Cryptographic key derivation | Too low-level for protocol-level bugs; crypto lib is separately tested; modeling key schedules adds complexity without catching protocol issues |
| Transport layer (MCTP/PCI DoE) | Session lifecycle is message-agnostic; transport-specific bugs are orthogonal to session state machine |
| Message encryption/decryption | Secured message lib has separate verification; focus on plaintext protocol logic and state |
| Configuration negotiation (GET_CAPABILITIES) | Happens before sessions; out of scope for session lifecycle (assumes capabilities already negotiated) |
| Timeout and retry logic | Retry loop is implementation detail; focus on single-attempt semantics first |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| KeyUpdatePhase | prev_operation ∈ {NONE, UPDATE_KEY, UPDATE_ALL_KEYS, VERIFY} | Track state machine progression; enforce UPDATE → VERIFY sequencing | Family 2 |
| KeyState per endpoint | requester_key_created, responder_key_created, requester_key_active, responder_key_active (booleans) | Expose divergence window between key creation and activation | Family 1 |
| SessionLifecycle | session_state ∈ {IDLE, ESTABLISHED, ENDING, FREED} | Ensure cleanup is consistent across requester/responder | Family 4 |
| HeartbeatConfig | heartbeat_enabled (derived from period > 0) | Track whether heartbeat is available; model precondition violations | Family 5 |
| MessageAckTracking | last_update_request_acked, last_verify_request_acked (booleans) | Detect lost ACKs that leave one side with stale state | Family 1 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| SessionStateConsistency | Safety | If requester session_state == ESTABLISHED, then responder session_state == ESTABLISHED (for the same session_id) | Family 4 |
| KeyUpdateSequencing | Safety | If prev_operation == UPDATE_KEY, then only VERIFY_NEW_KEY or another UPDATE_KEY is allowed next; no two UPDATE_ALL_KEYS in a row | Family 2 |
| KeyActivationOrder | Safety | If requester has key_activated, responder must have corresponding key (either created or activated) for the same session | Family 1 |
| HeartbeatPrecondition | Safety | If a HEARTBEAT request is sent, then heartbeat_enabled == true and session_state == ESTABLISHED | Family 5 |
| EndSessionIdempotence | Liveness | If END_SESSION is sent twice (due to retry), the second should not error (idempotent cleanup) | Family 4 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected Invariant Violation | Bug Family |
|----|-----------|-------------------------------|------------|
| MC1 | If UPDATE_ALL_KEYS request is sent but ACK is lost, can requester and responder keys diverge (requester has activated new responder key, responder hasn't)? | KeyActivationOrder violated: requester has new responder key; responder still has old one | Family 1 |
| MC2 | Can a second UPDATE_KEY be issued before VERIFY_NEW_KEY completes, violating the state machine? | KeyUpdateSequencing violated: prev_operation still set to UPDATE_KEY when new UPDATE_KEY arrives | Family 2 |
| MC3 | If HEARTBEAT is sent but heartbeat_period was never set to nonzero, is it rejected consistently on both sides? | HeartbeatPrecondition: one side rejects, other side accepts due to check ordering | Family 5 |
| MC4 | If END_SESSION_ACK is lost, does requester free the session ID while responder keeps it active, causing ID reuse conflict? | SessionStateConsistency: requester in FREED state, responder still in ENDING/ESTABLISHED | Family 4 |
| MC5 | In encapsulated key update (UPDATE_KEY phase), is the responder's responder-key activation correctly sequenced relative to the next VERIFY? | KeyActivationOrder: responder activates key before ACK but requester hasn't created its corresponding key yet | Family 1, 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-----------|----------------------|
| TV1 | Verify that key derivation produces identical keys on both sides after UPDATE + VERIFY cycle | Unit test: compare derived key material before/after update |
| TV2 | Verify that HEARTBEAT works only if heartbeat_period > 0, and fails gracefully otherwise | Integration test: set heartbeat_period to 0 and attempt heartbeat |
| TV3 | Verify that session IDs are reused correctly after END_SESSION cleanup | Integration test: create session, end it, create new session, verify ID reuse |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-----------|-----------------|
| CR1 | libspdm_req_key_update.c:169-182 — Error handling on UPDATE_ALL_KEYS failure attempts to revert responder key to old state. Verify that revert path is exhaustive and handles all failure cases. | Audit error paths for completeness; verify old key state is correctly preserved |
| CR2 | libspdm_rsp_key_update_ack.c:215-216 — `last_key_update_request` is cleared only at end of VERIFY phase. Verify this doesn't race with concurrent session accesses. | Review concurrency model; confirm single-threaded assumption |
| CR3 | libspdm_req_end_session.c:141 — `libspdm_free_session_id()` is called on ACK receipt. Verify this is idempotent and handles double-free gracefully. | Check session allocation/deallocation logic for reentrancy safety |

---

## 7. Reference Pointers

- **Full code analysis**: See analysis-report.md (if generated)
- **Core requester implementation**:
  - libspdm_req_heartbeat.c:25-172
  - libspdm_req_key_update.c:32-349
  - libspdm_req_end_session.c:26-177
- **Core responder implementation**:
  - libspdm_rsp_heartbeat.c:11-119
  - libspdm_rsp_key_update_ack.c:12-239
  - libspdm_rsp_end_session_ack.c:9-107
  - libspdm_rsp_encap_key_update.c:12-107 (responder-initiated variant)
- **Session management**:
  - libspdm_com_context_data_session.c:9-119
  - libspdm_secmes_session.c (key derivation and state)
- **GitHub**: https://github.com/DMTF/libspdm
- **SPDM Specification**: DSP0277 (v1.3+)

---

## Analysis Methodology Notes

- **Phase 1 Reconnaissance**: Mapped 6 core handler files (requester + responder), session state management, key update state machine
- **Phase 2 Bug Archaeology**: No explicit git commit history available; inferred bug-prone areas from code patterns (non-atomic updates, state coordination windows, state machine guards)
- **Phase 3 Deep Analysis**: Identified 5 distinct bug families through code path tracing, state machine validation, and requester-responder interaction analysis
- **Phase 4 Modeling Brief**: Synthesized findings into actionable modeling targets; prioritized by protocol safety impact and likelihood of divergence

