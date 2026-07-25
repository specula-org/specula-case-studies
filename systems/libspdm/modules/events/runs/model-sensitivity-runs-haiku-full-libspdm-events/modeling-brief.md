# libspdm-events Modeling Brief

## 1. System Overview

**System**: libspdm Event Subscription subsystem (SPDM 1.3 event support)  
**Language**: C  
**Category**: **Category A (Distributed / Message-Passing)**  
**Justification**: The event subsystem implements a message-based protocol where requesters and responders exchange structured event data over secure sessions. Protocol safety and message ordering are the primary concerns.

**What it implements**: SPDM 1.3 event subscription capability, allowing requesters to subscribe to events from responders and receive them via SEND_EVENT messages.

**Key architectural choices**:
- Events can only be sent in established secure sessions (SESSION_STATE_ESTABLISHED)
- Event instance IDs can be sequential or non-sequential, with different validation paths for each
- Variable-length event structures with vendor-specific headers and DMTF-standard types
- Event subscription state and event generation are delegated to integrator callbacks (not library-managed)

**Concurrency model**: Single-threaded request/response handlers. Session state is checked at handler entry but could change asynchronously.

---

## 2. Bug Families

### Family 1: Path Inconsistency — Sequential vs. Non-Sequential Event Processing

**Mechanism**: The responder's event ack handler (`libspdm_rsp_event_ack.c`) implements two different event processing paths depending on whether event instance IDs are sequential. The non-sequential path has higher complexity and different code coverage than the sequential path.

**Evidence**:
- Code analysis: `libspdm_rsp_event_ack.c:222-244` — two distinct branches handle sequential vs. non-sequential cases
- Sequential path (lines 222-227): Processes events in order, updating a pointer
- Non-sequential path (lines 228-244): Searches for each event by ID using `libspdm_find_event_instance_id` on every iteration

**Affected code paths**:
- `libspdm_get_response_event_ack` (responder)
- `libspdm_get_encap_response_event_ack` (requester, receives encapsulated events)
- `libspdm_find_event_instance_id` (called only in non-sequential path)

**Suggested modeling approach**:
- Variables: Add explicit state to track whether current sequence is sequential
- Actions: Model SEND_EVENT with separate actions for sequential vs. non-sequential event lists
- Granularity: Split the event validation into three steps: (1) parse headers, (2) validate sequence, (3) process events

**Priority**: High  
**Rationale**: Non-sequential processing is less tested (search-based), creates O(n²) complexity, and has a separate code path. Multiple code paths for the same protocol behavior often harbor bugs.

---

### Family 2: Integer Overflow in Accumulated Request Size Validation

**Mechanism**: The event ack handler accumulates event sizes in `calculated_request_size` without overflow protection. While the final size is validated against `request_size`, an overflow during accumulation could cause inconsistent state or truncation of the validation.

**Evidence**:
- Code analysis: `libspdm_rsp_event_ack.c:119-190` — `calculated_request_size` is accumulated in a loop
- Line 188-190: Each event's size is added; no overflow checks on the sum
- Line 194: Final validation `if (request_size != calculated_request_size)` catches mismatches but not overflow

**Affected code paths**:
- `libspdm_get_response_event_ack:188-190` (responder)
- `libspdm_get_encap_response_event_ack:133-142` (requester)

**Suggested modeling approach**:
- Variables: Track accumulated size explicitly; add overflow flag
- Actions: Extend request validation action to detect size overflow
- Granularity: Model the size accumulation loop and test with pathological event_detail_len values

**Priority**: Medium  
**Rationale**: Integer overflow is a classic vulnerability. While the final check may catch some overflows, intermediate overflow could hide invalid inputs. Testable via model checking with bounded event sizes.

---

### Family 3: Session State Validation Gap — Transient State Changes

**Mechanism**: Session state is validated once at the start of event handlers (`libspdm_secured_message_get_session_state` check), but the state could change between validation and the callback invocation (`process_event` or `libspdm_event_subscribe`).

**Evidence**:
- Code analysis: `libspdm_rsp_event_ack.c:71-98` — session state checked at lines 93-98
- Code analysis: `libspdm_rsp_subscribe_event_types_ack.c:71-77` — session state checked once before callback
- Lines 218-245 in event_ack handler: process_event callback invoked without re-validation
- Integrator callback has no visibility into session state at callback time

**Affected code paths**:
- All event request handlers: `libspdm_get_response_event_ack`, `libspdm_get_response_subscribe_event_types_ack`, `libspdm_get_response_supported_event_types`
- Requester encapsulated handlers: `libspdm_get_encap_response_event_ack`, `libspdm_get_encap_response_supported_event_types`

**Suggested modeling approach**:
- Variables: Track session state transitions explicitly; add "session closed" fault
- Actions: Model session state change as non-deterministic during callback window
- Granularity: Split handler into validation phase (atomic) and processing phase (can be interrupted)

**Priority**: High  
**Rationale**: Transient state changes are common sources of protocol violations in distributed systems. If session closes between validation and processing, subsequent operations become undefined.

---

### Family 4: DMTF Event Type Validation Coupling

**Mechanism**: DMTF event type validation (`libspdm_validate_dmtf_event_type`) is tightly coupled to the event parsing loop and is only called for specific SVH IDs. If the SVH ID field is malformed or validation logic diverges across code paths, invalid events could pass through.

**Evidence**:
- Code analysis: `libspdm_rsp_event_ack.c:175-180` — validation only for `SPDM_REGISTRY_ID_DMTF`
- Code analysis: `libspdm_com_event.c:11-25` — validation function checks against hardcoded event type sizes
- Coupling: Vendor ID validation (`libspdm_validate_svh_vendor_id_len:157`) is separate and earlier
- Two code paths parse events differently (sequential vs. non-sequential) but both must call validation correctly

**Affected code paths**:
- `libspdm_get_response_event_ack:175-180`
- `libspdm_validate_dmtf_event_type` (integration point)
- `libspdm_parse_and_send_event:63-65` (process_event callback)

**Suggested modeling approach**:
- Variables: Add event_type validation state; track which events received validation
- Actions: Model event type validation as optional/conditional rather than mandatory
- Granularity: Separate event header parsing from event type validation

**Priority**: Medium  
**Rationale**: Validation logic spread across multiple functions creates the risk of divergent paths. If a code path skips validation or the integrator's callback doesn't re-validate, invalid events could be processed.

---

### Family 5: Subscription State Management — No Library-Level Tracking

**Mechanism**: Event subscription state (which events a session is subscribed to) is entirely delegated to integrator callbacks (`libspdm_event_subscribe`). The library provides no consistency guarantees or recovery mechanism if subscription state diverges between requester and responder.

**Evidence**:
- Code analysis: `libspdm_rsp_subscribe_event_types_ack.c:131-137` — delegates to integrator callback, no library state machine
- Code analysis: `eventlib.h:36-42, 72-79` — callbacks are extern, not in library
- Sample implementation: `os_stub/.../event.c:56-110` — shows integrator manages all state via global variables
- No protocol-level recovery if subscription state becomes inconsistent across peers

**Affected code paths**:
- Subscribe request handlers: `libspdm_get_response_subscribe_event_types_ack`, `libspdm_req_subscribe_event_types`
- Event generation: `libspdm_generate_event_list` (integrator callback)
- Event processing: `libspdm_event_subscribe`, `libspdm_event_get_types`

**Suggested modeling approach**:
- Variables: Add library-level subscription state (subscribed event types per session)
- Actions: Model subscription update as two-phase: (1) validate callback, (2) update library state
- Granularity: Explicitly model the gap between what the library knows and what the integrator tracks

**Priority**: Medium  
**Rationale**: Delegation of critical protocol state to external callbacks is a source of inconsistency bugs. Model checking can reveal whether the protocol is robust to divergent integrator implementations.

---

## 3. Modeling Recommendations

### 3.1 Model (with Rationale)

| Item | Why | How |
|------|-----|-----|
| **Secure session requirement** | Events can only be sent in ESTABLISHED sessions; state is checked once but may change | Add session state as TLA+ variable; model session close as non-deterministic event |
| **Sequential vs. non-sequential event processing** | Two code paths, different test coverage; non-sequential uses O(n²) search | Model event list validation with separate sequential/non-sequential branches |
| **Event instance ID validation** | Complex constraints: sequential OR (no gaps AND no duplicates); different branches have different validation logic | Model ID ordering as explicit invariant; verify both paths enforce it |
| **Subscription state as integrator responsibility** | Library delegates to callbacks; no library-level consistency | Model subscription update as abstract callback; track what library knows vs. what integrator does |
| **Integer overflow in size accumulation** | Potential for overflow during loop accumulation; final validation catches mismatches but not intermediate overflow | Model size accumulation with explicit bounds; test pathological event_detail_len values |

### 3.2 Do Not Model (with Rationale)

| Item | Why |
|------|-----|
| **Cryptographic processing** | Outside protocol logic; session establishment already validated; event encryption/decryption is library-managed |
| **Buffer allocation and memory management** | Implementation detail; focus on protocol state, not C memory semantics |
| **Integrator callback internals** | Callbacks are external; model them as abstract operations with pre/post conditions |
| **Transport layer details** | SPDM encapsulation (MCTP, PCI-DOE) is transport-specific; focus on SPDM message semantics |
| **Retry and timeout logic** | Fault handling orthogonal to event protocol correctness; model as abstract retry abstraction |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| **Sequential Event Processing Mode** | `events_sequential : BOOLEAN` | Track whether current event list has sequential IDs to model path divergence | Family 1 |
| **Non-Sequential Event Index Lookup** | `event_id_map : [event_id → event_index]` | Model the search-based lookup in non-sequential path; verify correctness of O(n²) algorithm | Family 1 |
| **Session State Transitions** | `session_state[sid] : {NEGOTIATED, ESTABLISHED, CLOSED}` | Model transient session state changes between validation and callback invocation | Family 3 |
| **Accumulated Size Tracking** | `msg_size_accum : Int` | Track accumulated size during event parsing loop; detect overflow | Family 2 |
| **Subscription State Per Session** | `subscribed_events[sid] : SET of event_type` | Track what subscription state the library believes (vs. integrator's actual state) | Family 5 |
| **Event Type Validation Flag** | `event_validated[event_index] : BOOLEAN` | Track whether each event passed DMTF type validation | Family 4 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| **EventsInEstablishedSession** | Safety | Events can only be sent or processed when session state is LIBSPDM_SESSION_STATE_ESTABLISHED | Family 3 |
| **SequentialOrGapFree** | Safety | Event instance IDs must be either sequential (n, n+1, n+2, ...) OR form a gap-free range with no duplicates | Family 1 |
| **SizeAccumulationBounded** | Safety | Accumulated event size never overflows; final accumulated size matches actual message size | Family 2 |
| **DMTFEventsValidated** | Safety | All events with SPDM_REGISTRY_ID_DMTF must pass type validation before being processed | Family 4 |
| **SubscriptionConsistency** | Liveness | If subscription state diverges between library and integrator, integrator-generated events should match integrator's subscription state (not library's) | Family 5 |
| **EventProcessingCompletes** | Liveness | If validation succeeds, event processing completes (no indefinite hangs in callback) | Families 1, 3 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable Findings

| ID | Description | Expected Invariant Violation | Bug Family |
|----|-------------|----------------------------|------------|
| **MC1** | If session state changes from ESTABLISHED to CLOSED between state check and process_event callback, what happens to pending event processing? Does the protocol guarantee delivery? | SessionStateViolation: process_event called on closed session | Family 3 |
| **MC2** | In non-sequential event processing, if event_instance_id_max overflows (e.g., UINT32_MAX - N events with large IDs), does the gap-check algorithm (line 204) still work correctly? | IntegerOverflowViolation or SequentialCheckFailure | Family 1, Family 2 |
| **MC3** | Can a maliciously crafted event list (non-sequential IDs with specific spacing) cause the search-based lookup in non-sequential path to exceed buffer bounds? | BufferOverflowViolation or OutOfBoundsMemoryAccess | Family 1 |
| **MC4** | If accumulated size overflows during the loop (line 188-190), will the final validation (line 194) catch all possible overflows, or are there inputs where overflow is silent? | IntegerOverflowViolation: size matches by wrapping | Family 2 |
| **MC5** | What happens if an integrator's libspdm_event_subscribe callback returns false after the library has already sent a SUBSCRIBE_EVENT_TYPES_ACK? Is the session left in an inconsistent state? | SubscriptionInconsistency: mismatched subscribe state | Family 5 |

### 6.2 Test-Verifiable Findings

| ID | Description | Suggested Test Approach |
|----|-------------|------------------------|
| **TV1** | Test event list validation with maximum event_detail_len (65535) repeated N times to trigger size accumulation patterns | Fuzzing test with large detail_len; verify no overflow |
| **TV2** | Test non-sequential event processing with permuted event IDs (e.g., [3,1,2] vs. [1,3,2]) to ensure both paths validate correctly | Unit test with various permutations |
| **TV3** | Test session state transitions during event processing (mocking session close after state check) | Integration test with session closure fault injection |

### 6.3 Code-Review-Only Findings

| ID | Description | Suggested Action |
|----|-------------|-----------------|
| **CR1** | `libspdm_find_event_instance_id` lacks buffer bounds parameter; relies on caller to ensure event_count is correct. Verify all callers validate bounds. | Audit all callers to confirm bounds validation |
| CR2** | SVH vendor ID length validation (`libspdm_validate_svh_vendor_id_len`) is called before reading the vendor ID buffer. Verify the bounds check on line 162-163 prevents read overflow. | Manual review of bounds arithmetic |
| **CR3** | Integrator callbacks (`process_event`, `libspdm_event_subscribe`) are documented as being called in secure session context, but no re-validation of session state occurs at callback time. Verify integrators don't assume session is still open. | Documentation review; integrator best-practices guidance |

---

## 7. Reference Pointers

- **Core implementation files**:
  - `/library/spdm_responder_lib/libspdm_rsp_event_ack.c` — Primary event processing in responder (lines 1-260)
  - `/library/spdm_responder_lib/libspdm_rsp_subscribe_event_types_ack.c` — Subscription handling (lines 12-152)
  - `/library/spdm_requester_lib/libspdm_req_send_event.c` — Event sending from requester (lines 11-129)
  - `/library/spdm_common_lib/libspdm_com_event.c` — Shared event parsing (lines 27-73)

- **Protocol definitions**:
  - `/include/industry_standard/spdm.h` — Message structures (lines 1550-1585)

- **Integrator interface**:
  - `/include/hal/library/eventlib.h` — Event callbacks (libspdm_event_subscribe, libspdm_event_get_types, libspdm_generate_event_list)
  - `/os_stub/spdm_device_secret_lib_sample/event.c` — Sample implementation

- **SPDM Specification**: SPDM 1.3 specification, Section on Event Subscription (external reference)

