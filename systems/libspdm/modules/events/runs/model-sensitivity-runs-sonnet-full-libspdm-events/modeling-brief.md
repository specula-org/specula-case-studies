# Modeling Brief: libspdm — SPDM 1.3 Event Subscription Subsystem

## 1. System Overview

- **System**: DMTF/libspdm — C reference implementation of the Security Protocol and Data Model (SPDM) specification
- **Language**: C, ~700 LOC core event logic across 12 files
- **Protocol**: SPDM 1.3 event subscription (new feature) — Event Notifier pushes signed events to Event Recipient over an established secure session
- **System category**: **Category A (Distributed / Message-Passing)** — all event interactions are structured request/response message exchanges over an established cryptographic session, with explicit state machine control via `response_state` and `session_state`
- **Key architectural choices**:
  - Two orthogonal event flow directions: (A) Responder-as-Notifier via ENCAP flow; (B) Requester-as-Notifier via direct SEND_EVENT
  - Subscription can be established at KEY_EXCHANGE time (via `SESSION_POLICY_EVENT_ALL_POLICY`) or post-session via `SUBSCRIBE_EVENT_TYPES`
  - `libspdm_event_subscribe()` and `libspdm_event_get_types()` are integrator-provided HAL callbacks (not implemented by libspdm itself)
  - Encapsulated flow uses `response_state = LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP` to block other requests
- **Concurrency model**: Single-threaded, event-driven — one in-flight request at a time per session; response_state serializes concurrent operations

---

## 2. Bug Families

### Family 1: Response State Check Ordering in SEND_EVENT Handler

**Mechanism**: `libspdm_rsp_event_ack.c` checks SPDM version and request version-mismatch BEFORE checking `response_state`, while every other event-related handler checks `response_state` first. When the responder is in `LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP` (concurrently sending encapsulated events as Notifier), an incoming direct `SEND_EVENT` from the Requester (acting as Notifier in the reverse direction) will not receive `REQUEST_IN_FLIGHT` as expected — it will receive a version error instead, or skip the state check entirely if versions match.

**Evidence**:
- Code analysis: `libspdm_rsp_event_ack.c:37-51` — order is (1) version check (2) version mismatch check (3) response_state
- Code analysis: `libspdm_rsp_supported_event_types.c:33-37` — response_state checked FIRST
- Code analysis: `libspdm_rsp_subscribe_event_types_ack.c:35-39` — response_state checked FIRST
- Code analysis: `libspdm_rsp_handle_response_state.c:53-56` — `PROCESSING_ENCAP` returns `REQUEST_IN_FLIGHT` error when dispatched correctly

**Affected code paths**:
- `libspdm_get_response_event_ack()` (`libspdm_rsp_event_ack.c:14`)
- `libspdm_responder_handle_response_state()` (`libspdm_rsp_handle_response_state.c:9`)
- `libspdm_get_encap_request_send_event()` / `libspdm_process_encap_response_event_ack()` (`libspdm_rsp_encap_send_event.c`)
- `libspdm_init_send_event_encap_state()` (`libspdm_rsp_encap_response.c:246-266`) — sets `PROCESSING_ENCAP`

**Suggested modeling approach**:
- Variables: `responder_response_state ∈ {NORMAL, PROCESSING_ENCAP, BUSY, NOT_READY}`, `requester_last_request ∈ {SEND_EVENT, ...}`, `session_state`
- Actions: Split `HandleSendEvent` into two variants — one for `NORMAL` state (correct processing) and one for `PROCESSING_ENCAP` state (should return `REQUEST_IN_FLIGHT` but currently may not)
- Key: model the event_ack handler explicitly checking state AFTER version, versus other handlers checking state BEFORE version — shows the inconsistency can lead to different behavior

**Priority**: High
**Rationale**: Direct code path inconsistency across sibling handlers. When both event directions are active simultaneously (open issue #3169), this becomes a live protocol defect.

---

### Family 2: Subscription State Transitions — SUBSCRIBE_ALL Override

**Mechanism**: Event subscription state has three possible values (`SUBSCRIBE_ALL`, `SUBSCRIBE_NONE`, `SUBSCRIBE_LIST`) that can be set by two independent mechanisms: (1) `SESSION_POLICY_EVENT_ALL_POLICY` at `KEY_EXCHANGE` sets `SUBSCRIBE_ALL` before the session reaches `ESTABLISHED`; (2) `SUBSCRIBE_EVENT_TYPES` with `param1=0` always sets `SUBSCRIBE_NONE`, regardless of whether `SUBSCRIBE_ALL` was previously set. There is no protocol guard against this override. The library has no internal tracking of whether the current subscription was established via session policy or via explicit subscribe message.

**Evidence**:
- Code analysis: `libspdm_rsp_key_exchange.c:798-811` — `SUBSCRIBE_ALL` called at KEY_EXCHANGE (session in HANDSHAKE state, not ESTABLISHED)
- Code analysis: `libspdm_rsp_subscribe_event_types_ack.c:113-130` — `subscribe_event_group_count == 0` → `LIBSPDM_EVENT_SUBSCRIBE_NONE` with no check of prior state
- Code analysis: `libspdm_req_encap_subscribe_event_types_ack.c:113-130` — same mapping, same missing guard
- Code analysis: `eventlib.h:44-79` — only three subscribe types; no "re-subscribe to ALL" path via `SUBSCRIBE_EVENT_TYPES`

**Affected code paths**:
- `libspdm_get_response_subscribe_event_types_ack()` (`libspdm_rsp_subscribe_event_types_ack.c`)
- `libspdm_get_encap_subscribe_event_types_ack()` (`libspdm_req_encap_subscribe_event_types_ack.c`)
- `libspdm_get_response_key_exchange()` lines 798-811 (`libspdm_rsp_key_exchange.c`)

**Suggested modeling approach**:
- Variables: `subscription_state[session] ∈ {NONE, ALL, LIST}`, `session_policy_event_all[session] ∈ BOOL`
- Actions: `HandleKeyExchange` (sets `subscription_state = ALL` if `EVENT_ALL_POLICY`), `HandleSubscribeEventTypes` (can set `NONE` or `LIST` unconditionally), `HandleSendEvent` (requires `subscription_state ≠ NONE`)
- Invariant: if `session_policy_event_all = true` and no `SUBSCRIBE_EVENT_TYPES` has been sent, `subscription_state = ALL`

**Priority**: High
**Rationale**: SPDM 1.3 event subscription is under active development (issue #3169 open). The interaction between session-policy-driven subscription and message-driven re-subscription is a state machine question with no explicit spec text guarding against SUBSCRIBE_NONE overriding SESSION_POLICY.

---

### Family 3: Event Delivery Before Subscription Acknowledgment

**Mechanism**: The responder can invoke `libspdm_init_send_event_encap_state()` and begin sending encapsulated `SEND_EVENT` messages without checking whether a subscription is active for the target session. The only subscription guarantee is that either `EVENT_ALL_POLICY` was set at `KEY_EXCHANGE` or `SUBSCRIBE_EVENT_TYPES` was received. If the responder sends events based on the former and the requester subsequently sends `SUBSCRIBE_EVENT_TYPES` with `param1=0` (NONE), the responder could be mid-flight with a `SEND_EVENT` for a session where the subscription is now `NONE`.

**Evidence**:
- Code analysis: `libspdm_rsp_encap_response.c:246-266` — `libspdm_init_send_event_encap_state()` takes no subscription state parameter
- Code analysis: `libspdm_rsp_encap_send_event.c:14-63` — `libspdm_get_encap_request_send_event()` calls `libspdm_generate_event_list()` without checking subscription state
- Code analysis: `libspdm_req_encap_event_ack.c` — EVENT_ACK handler does not validate that the session has an active subscription

**Affected code paths**:
- `libspdm_get_encap_request_send_event()` (`libspdm_rsp_encap_send_event.c:14`)
- `libspdm_init_send_event_encap_state()` (`libspdm_rsp_encap_response.c:246`)

**Suggested modeling approach**:
- Variables: `subscription_state[session]`, `encap_event_in_flight[session] ∈ BOOL`
- Invariant: `encap_event_in_flight[session] ⇒ subscription_state[session] ≠ NONE`
- Model `SubscribeNone` during an in-flight encap SEND_EVENT as a potential violation

**Priority**: Medium
**Rationale**: The subscription state is fully integrator-managed; libspdm itself has no such guard. TLA+ can determine if a valid message sequence leads to delivery of an event to an unsubscribed recipient.

---

### Family 4: SEND_EVENT `crypto_request` Flag Inconsistency

**Mechanism**: `libspdm_req_send_event.c` sets `context->crypto_request = false` before the retry loop, while `libspdm_req_get_supported_event_types.c` sets `context->crypto_request = true`. The `crypto_request` flag controls whether a BUSY response triggers a retry. Setting it to `false` for `SEND_EVENT` means the event is not retried on BUSY, while `GET_SUPPORTED_EVENT_TYPES` is retried. Since SEND_EVENT is the only message in the event flow where a missed delivery is significant (event data is lost on BUSY), the non-retry behavior may be inconsistent with event delivery guarantees.

**Evidence**:
- Code analysis: `libspdm_req_send_event.c:135` — `context->crypto_request = false`
- Code analysis: `libspdm_req_get_supported_event_types.c:152` — `context->crypto_request = true`
- Code analysis: `libspdm_req_subscribe_event_types.c:156` — `context->crypto_request = true`

**Affected code paths**:
- `libspdm_send_event()` (`libspdm_req_send_event.c:132`)

**Priority**: Low (for TLA+ modeling — better suited for code review)

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Response state machine with PROCESSING_ENCAP | Family 1: check-order inconsistency means SEND_EVENT bypasses state guard | Variable `response_state ∈ {NORMAL, PROCESSING_ENCAP}`; split `HandleSendEvent` to show the missing check |
| Session subscription state transitions | Family 2: SUBSCRIBE_NONE can override EVENT_ALL_POLICY; no guard | Variable `subscription_state[session]`; actions `KeyExchangeWithEventAll`, `SubscribeNone`, `SubscribeList` |
| Dual event flow (direct SEND_EVENT + encap SEND_EVENT) | Family 1+3: both directions can be active simultaneously; issue #3169 is OPEN | Two independent event action families: direct `SendEventRequester` and encap `SendEventResponder` |
| Session lifecycle (HANDSHAKE → ESTABLISHED → terminated) | Family 2: subscription set in HANDSHAKE, events sent only in ESTABLISHED | `session_state ∈ {NOT_STARTED, HANDSHAKE, ESTABLISHED}`; subscription actions gated on session_state |
| Encapsulated flow state (`PROCESSING_ENCAP`) | Family 1: `PROCESSING_ENCAP` should block direct SEND_EVENT with REQUEST_IN_FLIGHT | Track `encap_in_flight` per session; check state before dispatching SEND_EVENT |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Non-sequential event ID validation | The range-check and search loop in `event_ack.c` is implementation-level parsing; no protocol state depends on it; better verified by fuzzing |
| Cryptographic operations (HMAC, signatures) | Pure cryptographic correctness is outside TLA+ scope; libspdm delegates to integrator HAL anyway |
| `libspdm_event_subscribe()` integrator internals | HAL callback is not implemented by libspdm; behavior is integrator-defined |
| BUSY retry semantics (`crypto_request` flag) | Implementation detail of the retry loop; no protocol state machine impact |
| Multi-session management | Adds state space without targeting event-specific bugs; single session sufficient |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Subscription state tracking | `subscription_state[session] ∈ {NONE, ALL, LIST}` | Track transitions across KEY_EXCHANGE and SUBSCRIBE_EVENT_TYPES | Family 2 |
| Response state machine | `response_state ∈ {NORMAL, PROCESSING_ENCAP}` | Expose PROCESSING_ENCAP state to model check ordering | Family 1 |
| Session policy flag | `event_all_policy[session] ∈ BOOL` | Track whether KEY_EXCHANGE requested ALL subscription | Family 2 |
| Encap event in-flight | `encap_event_in_flight[session] ∈ BOOL` | Track whether responder has active encap SEND_EVENT | Family 1, 3 |
| Event flow direction | `direct_send_active ∈ BOOL`, `encap_send_active ∈ BOOL` | Distinguish simultaneous event flows | Family 1 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| RequestInFlightGuard | Safety | If `response_state = PROCESSING_ENCAP`, any incoming `SEND_EVENT` must return `REQUEST_IN_FLIGHT` | Family 1 |
| SubscribeNoneBlocksEvents | Safety | If `subscription_state[session] = NONE`, no `SEND_EVENT` should be delivered for that session | Family 2, 3 |
| EventAllPolicyImpliesSubscribeAll | Safety | After `KEY_EXCHANGE` with `EVENT_ALL_POLICY` and before any `SUBSCRIBE_EVENT_TYPES`, `subscription_state = ALL` | Family 2 |
| EncapInFlightSessionValid | Safety | `encap_event_in_flight[session] = true` only while `session_state = ESTABLISHED` | Family 3 |
| NoDualInFlightConflict | Safety | `direct_send_active` and `encap_send_active` cannot both be true for the same session if `response_state = PROCESSING_ENCAP` | Family 1 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC-1 | When `response_state = PROCESSING_ENCAP` (responder sending encap events), direct `SEND_EVENT` from requester does not receive `REQUEST_IN_FLIGHT` — version check fires first | RequestInFlightGuard | 1 |
| MC-2 | A session established with `EVENT_ALL_POLICY` can have its subscription silently zeroed to `NONE` via `SUBSCRIBE_EVENT_TYPES` with `param1=0`, allowing the notifier to subsequently send events to an unsubscribed recipient | SubscribeNoneBlocksEvents, EventAllPolicyImpliesSubscribeAll | 2 |
| MC-3 | If the responder initiates encap `SEND_EVENT` while the requester concurrently sends `SUBSCRIBE_EVENT_TYPES` with `param1=0`, the subscription state transitions to NONE mid-flight | EncapInFlightSessionValid, SubscribeNoneBlocksEvents | 2, 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV-1 | `SEND_EVENT` with `crypto_request = false` is not retried on BUSY response; event data is lost | Integration test: mock transport to return BUSY on first SEND_EVENT, verify retry does not occur |
| TV-2 | `SUBSCRIBE_EVENT_TYPES` with `param1=0` after `EVENT_ALL_POLICY` session causes subscription state to be NONE | Integration test: establish session with EVENT_ALL_POLICY, send SUBSCRIBE with count=0, verify notifier stops sending events |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `libspdm_rsp_event_ack.c` checks version before `response_state` unlike all other event handlers | Reorder checks to match `libspdm_rsp_supported_event_types.c` pattern: response_state → connection_state → version → version mismatch |
| CR-2 | `libspdm_req_send_event.c:135` sets `crypto_request = false`; all other event requester functions set `crypto_request = true` | Review whether SEND_EVENT should retry on BUSY; update comment to explain intentional difference if by design |
| CR-3 | Issue #3169 (OPEN): Requester as Event Initiator / Responder as Event Recipient not fully implemented | No direct SPDM version check for when Responder sends `GET_SUPPORTED_EVENT_TYPES` / `SUBSCRIBE_EVENT_TYPES` via encapsulation to a Requester-as-Notifier |

---

## 7. Reference Pointers

**Key source files**:
- `library/spdm_responder_lib/libspdm_rsp_event_ack.c` — Family 1 root cause (response_state ordering)
- `library/spdm_responder_lib/libspdm_rsp_subscribe_event_types_ack.c` — Family 2 (SUBSCRIBE_NONE transition)
- `library/spdm_requester_lib/libspdm_req_encap_subscribe_event_types_ack.c` — Family 2 (reverse direction)
- `library/spdm_responder_lib/libspdm_rsp_key_exchange.c:798-815` — Family 2 (EVENT_ALL_POLICY at KEY_EXCHANGE)
- `library/spdm_responder_lib/libspdm_rsp_encap_response.c:246-266` — Family 3 (encap state init)
- `library/spdm_responder_lib/libspdm_rsp_encap_send_event.c` — Family 3 (encap event generation)
- `library/spdm_responder_lib/libspdm_rsp_handle_response_state.c:53-56` — PROCESSING_ENCAP → REQUEST_IN_FLIGHT
- `library/spdm_responder_lib/libspdm_rsp_receive_send.c:97-104` — top-level dispatch table (SEND_EVENT routing)
- `library/spdm_common_lib/libspdm_com_event.c` — event parsing and search helpers
- `include/hal/library/eventlib.h` — integrator HAL interface for event subscription
- `include/industry_standard/spdm.h:1547-1585` — SPDM 1.3 event message structures and constants

**GitHub issues**:
- #3589 (CLOSED, fixed by PR #3594): `SPDM_SEND_EVENT` was not routed in responder top-level dispatch — fixed, now present at `libspdm_rsp_receive_send.c:102-104`
- #3267 (CLOSED): `UnsupportedError` response to `SEND_EVENT` used incorrect `RequestResponseCode`
- #3169 (OPEN): Requester as Event Initiator and Responder as Event Recipient not fully implemented — confirms reverse event direction is still being developed
- #3483 (CLOSED): Responder did not perform SPDM version check on encapsulated messages from Requester

**Reference algorithm**: SPDM DSP0274 specification version 1.3.x, Section on Event Subscription (new in 1.3)
