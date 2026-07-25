# Confirmed Bugs — libspdm SPDM 1.3 Event Subscription

**Target**: libspdm (DMTF SPDM 1.3 event subscription)
**Phase**: Bug confirmation (Phase 4)
**Input**: spec/bug-report.md (3 MC-found bugs)
**Date**: 2026-06-08

---

## Summary

All three bugs from the Phase 3 bug report were confirmed. Each was reproduced at
escalation Level 0 (pure black-box, public API only, no code modification).

| Bug ID | Status | Level | Severity |
|--------|--------|-------|----------|
| BUG-1  | REPRODUCED | 0 | High |
| BUG-2  | REPRODUCED | 0 | High |
| BUG-3  | REPRODUCED | 0 | Medium |

---

## BUG-1: Response-state check order in SEND_EVENT handler

**Source**: MC  
**Status**: REPRODUCED  
**Severity**: High  
**Location**: `library/spdm_responder_lib/libspdm_rsp_event_ack.c:47-68`

### Code audit findings

`libspdm_get_response_event_ack()` checks `spdm_request->header.spdm_version` (line 47)
before checking `spdm_context->response_state` (line 68). Every other SPDM 1.3 event
handler (e.g. `libspdm_rsp_subscribe_event_types_ack.c:38`) guards on `response_state`
first under a `/* -=[Verify State Phase]=- */` comment. The `event_ack.c` handler is
missing that phase: it jumps from `/* -=[Check Parameters Phase]=- */` (line 37) directly
to the version check at line 47, only reaching `response_state` at line 68 — after the
version check can already return early.

Call chain: `libspdm_get_response_event_ack` → version check at line 47 → returns
`SPDM_ERROR_CODE_VERSION_MISMATCH` (line 56) without ever reaching the response_state
check at line 68.

No caller safeguard was found: `spdm_context->response_state` is a pure state variable
set by the encap flow; callers cannot prevent the mismatch.

Trigger scenario: Requester opens an SPDM 1.3 session, sends KEY_EXCHANGE and FINISH to
establish the session. Integrator calls `libspdm_init_send_event_encap_state()` to start
an encap flow (response_state → PROCESSING_ENCAP). Requester simultaneously sends a
SEND_EVENT with the wrong SPDM version header (e.g. 0x12 instead of 0x13 — any version
mismatch). The handler fires VERSION_MISMATCH instead of REQUEST_IN_FLIGHT.

### Developer intent investigation

No git history available (snapshot repository). No TODO/FIXME comments appear near the
bug site. The TLA trace instrumentation added at lines 48-55 explicitly reads and logs
`response_state` at the version-mismatch early-exit point — confirming the developers
were aware of the ordering question (they instrumented it) but did not move the
`response_state` check to precede the version check.

`libspdm_rsp_subscribe_event_types_ack.c` at lines 37-43 demonstrates the correct
pattern with an explicit `/* -=[Verify State Phase]=- */` block that precedes the version
check (line 88). The asymmetry between the two handlers indicates `event_ack.c` received
the ordering wrong when first written, before the TLA+ instrumentation was added.

No existing unit test in `unit_test/test_spdm_responder/event_ack.c` sets
`response_state = PROCESSING_ENCAP` with a version-mismatched request, so the buggy
path was never tested.

Conclusion: no developer commentary found confirming this ordering as intentional.
Engineering principle violated: request-in-flight guard must fire before per-field
validation — a handler that returns VERSION_MISMATCH while an encap flow is active
leaks the encap state to the requester and fails to properly serialize access.

### Reproduction test

**File**: `repro/test_bug1_response_state_check_order.c`  
**Command**: `./test_bug1`  
**Escalation level reached**: 0 (pure black-box)

**Output**:
```
=== BUG-1: Response-state check order in SEND_EVENT handler ===

Setup:    response_state=PROCESSING_ENCAP, request version=0x12 (connection version=0x13)
Expected: SPDM_ERROR_CODE_REQUEST_IN_FLIGHT (0x08) — encap in flight
Actual:   error_code=0x41  (response_code=0x7f)

BUG CONFIRMED: returned VERSION_MISMATCH (0x41) instead of REQUEST_IN_FLIGHT (0x08)
RESULT: REPRODUCED (Level 0)
```

Observable anomalous behaviour: `error_code=0x41` (`SPDM_ERROR_CODE_VERSION_MISMATCH`)
instead of `0x08` (`SPDM_ERROR_CODE_REQUEST_IN_FLIGHT`). This matches the MC
counterexample's `last_mismatch_response_state=PROCESSING_ENCAP` invariant violation.

### Recommendation

In `libspdm_get_response_event_ack()`, move the `response_state` check to **before** the
version check (following the `/* -=[Verify State Phase]=- */` pattern used in all peer
handlers). Add a unit test case that sets `response_state=PROCESSING_ENCAP` and sends a
version-mismatched SEND_EVENT, asserting `SPDM_ERROR_CODE_REQUEST_IN_FLIGHT`.

---

## BUG-2: SUBSCRIBE_NONE silently overrides EVENT_ALL_POLICY subscription

**Source**: MC  
**Status**: REPRODUCED  
**Severity**: High  
**Location**: `library/spdm_responder_lib/libspdm_rsp_subscribe_event_types_ack.c:124-134`  
**Secondary**: `os_stub/spdm_device_secret_lib_sample/event.c:79-87`

### Code audit findings

`libspdm_get_response_subscribe_event_types_ack()` sets `subscribe_type =
LIBSPDM_EVENT_SUBSCRIBE_NONE` unconditionally at line 125 when
`subscribe_event_group_count == 0`, then calls `libspdm_event_subscribe(...
LIBSPDM_EVENT_SUBSCRIBE_NONE ...)` at line 134 — with no guard checking whether the
session was established with `SESSION_POLICY_EVENT_ALL_POLICY`.

The integrator's `libspdm_event_subscribe()` sample implementation (`event.c:79-87`)
clears `g_event_all_subscribe = false` and sets `g_event_all_unsubscribe = true`
unconditionally for `SUBSCRIBE_NONE`, with no per-session policy check.

The activation path is `libspdm_get_response_key_exchange()` at lines 802-813 of
`libspdm_rsp_key_exchange.c`, where `libspdm_event_subscribe(... SUBSCRIBE_ALL ...)` is
called when `session_policy & EVENT_ALL_POLICY` is set. This establishes the ALL
subscription. The subscribe handler does not consult the session's policy when
subsequently downgrading it.

No safeguard was found: no check guards the state transition `SUB_ALL → SUB_NONE`.

Trigger scenario: Requester sends KEY_EXCHANGE with SESSION_POLICY_EVENT_ALL_POLICY bit
set. Responder establishes session with full event subscription. Requester then sends
SUBSCRIBE_EVENT_TYPES with param1=0 (subscribe_event_group_count=0). Responder silently
clears the EVENT_ALL subscription with success. Subsequent events are dropped.

### Developer intent investigation

No git history. No TODO/FIXME comments. The critical evidence is in the existing unit
test: `unit_test/test_spdm_responder/subscribe_event_types_ack.c` case 1 (line 60) sends
SUBSCRIBE_EVENT_TYPES with count=0 and at line 96 asserts `!g_event_all_subscribe &&
g_event_all_unsubscribe`. However, `set_standard_state()` (line 15) does **not** set
`g_event_all_subscribe = true` before the call — the test only covers the normal "start
from no subscription, send SUBSCRIBE_NONE" path. The test does not set up an
EVENT_ALL_POLICY session and then attempt a downgrade, so the bug path was never exercised.

This means the developer test validates the normal subscribe-none use case but does not
consider the guard requirement for EVENT_ALL_POLICY sessions. No developer evidence
was found that the override is intentional.

Conclusion: no developer commentary confirms this as a design choice.
Engineering principle violated: a policy established by a session negotiation parameter
(EVENT_ALL_POLICY) should only be alterable via explicit renegotiation, not silently
overridden by a subsequent message that was not intended to affect policy. The SPDM 1.3
spec (§10.34) notes EVENT_ALL_POLICY is session-level; a SUBSCRIBE_EVENT_TYPES request
from the requester should not override it.

### Reproduction test

**File**: `repro/test_bug2_subscribe_none_overrides_event_all.c`  
**Command**: `./test_bug2`  
**Escalation level reached**: 0 (pure black-box)

**Output**:
```
=== BUG-2: SUBSCRIBE_NONE silently overrides EVENT_ALL_POLICY ===

Subscribing to all events for session ID 0xffffffff.
Step 1 — KEY_EXCHANGE EVENT_ALL_POLICY: libspdm_event_subscribe(ALL) = success
         g_event_all_subscribe = true  (should be true)
Unsubscribing from all events for session ID 0xffffffff.

Step 2 — SUBSCRIBE_EVENT_TYPES(count=0): status=0x0
         response_code=0x70  error_code=0x00
         g_event_all_subscribe = false  (should still be true if fixed)

BUG CONFIRMED: SUBSCRIBE_NONE with count=0 succeeded and cleared EVENT_ALL_POLICY
subscription without error.
  g_event_all_subscribe: true -> false (subscription lost silently)
RESULT: REPRODUCED (Level 0)
```

Observable anomalous behaviour: `response_code=0x70` (SUBSCRIBE_EVENT_TYPES_ACK =
success) with `g_event_all_subscribe` transitioning `true → false`. This matches the
MC counterexample's `MCEventAllOverriddenToNone` invariant violation.

### Recommendation

In `libspdm_get_response_subscribe_event_types_ack()`, add a guard at line 124:

```c
if (subscribe_event_group_count == 0) {
    if (session_info->session_policy &
        SPDM_KEY_EXCHANGE_REQUEST_SESSION_POLICY_EVENT_ALL_POLICY) {
        return libspdm_generate_error_response(spdm_context,
                                               SPDM_ERROR_CODE_INVALID_REQUEST, 0,
                                               response_size, response);
    }
    subscribe_type = LIBSPDM_EVENT_SUBSCRIBE_NONE;
}
```

Add a unit test that establishes EVENT_ALL_POLICY via key exchange, then sends
SUBSCRIBE_EVENT_TYPES with count=0, asserting INVALID_REQUEST is returned.

---

## BUG-3: Encap SEND_EVENT initiated without subscription check

**Source**: MC  
**Status**: REPRODUCED  
**Severity**: Medium  
**Location**: `library/spdm_responder_lib/libspdm_rsp_encap_response.c:249-272`

### Code audit findings

`libspdm_init_send_event_encap_state()` (line 249) sets `context->response_state =
LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP` (line 262) without consulting the session's
subscription state. It accesses only the `session_id` to store in
`encap_context.session_id` but never looks up the session_info to check whether the
requester subscribed to events.

`libspdm_get_encap_request_send_event()` (`libspdm_rsp_encap_send_event.c:14`) similarly
calls `libspdm_generate_event_list()` (line 54) with no subscription guard.

Call chain (integrator-initiated): Integrator calls
`libspdm_init_send_event_encap_state(ctx, session_id)` → sets PROCESSING_ENCAP
unconditionally → requester receives GET_ENCAPSULATED_REQUEST → responder sends
SEND_EVENT encap request → event delivered to unsubscribed requester.

No safeguard in callers: `libspdm_init_send_event_encap_state()` is a public API
callable by any integrator; its contract does not specify that the caller must check
subscription state first. Per SPDM 1.3 §10.35, the Responder MUST NOT initiate
encapsulated event delivery to a requester that has not subscribed.

Trigger scenario: Requester sends KEY_EXCHANGE without EVENT_ALL_POLICY (no subscription
established). Session reaches ESTABLISHED with `subscription_state=NONE`. Integrator
calls `libspdm_init_send_event_encap_state()` to push an event. The encap flow starts
and the responder sends SEND_EVENT to the unsubscribed requester.

### Developer intent investigation

No git history. No TODO/FIXME comments. Searching for "subscription" or "subscribe" in
`libspdm_rsp_encap_response.c` returns no results — the function was written without
considering the subscription state.

By contrast, the `event.c` sample's `libspdm_generate_event_list()` is session-ID-aware
but does not check the subscription state either. The omission is consistent: when the
encap event subsystem was implemented, subscription state was not threaded into the
initiation path.

No existing unit test exercises the "call init_send_event_encap_state on session with
SUBSCRIBE_NONE" path. The existing `encap_send_event.c` test calls the function in
`set_standard_state` which zeroed context (SUB_NONE) but treats the state change as
expected.

Conclusion: no developer commentary. Engineering principle violated: an API whose
contract requires a precondition (active subscription) must enforce or document that
precondition. Callers cannot reliably check it externally because the subscription state
is encapsulated in the integrator's data, not in the visible libspdm session_info API.

### Reproduction test

**File**: `repro/test_bug3_encap_no_subscription_check.c`  
**Command**: `./test_bug3`  
**Escalation level reached**: 0 (pure black-box)

**Output**:
```
=== BUG-3: Encap SEND_EVENT initiated without subscription check ===

Setup: response_state=NORMAL (0), session subscription=NONE
Expected (correct): libspdm_init_send_event_encap_state() should
                    refuse to start encap when subscription is NONE.
                    response_state should remain NORMAL.

After libspdm_init_send_event_encap_state():
  response_state = PROCESSING_ENCAP (4)

BUG CONFIRMED: response_state transitioned to PROCESSING_ENCAP even though session
has no active subscription (SUBSCRIBE_NONE).
  The responder will now attempt to push an event to an unsubscribed requester.
RESULT: REPRODUCED (Level 0)
```

Observable anomalous behaviour: `response_state` transitions to `PROCESSING_ENCAP`
(value 4) despite no active subscription. This matches the MC counterexample's
`MCSubscribeNoneBlocksEvents` invariant violation.

### Recommendation

In `libspdm_init_send_event_encap_state()`, add a subscription check via a new
integration callback or by storing subscription state in `libspdm_session_info_t`:

```c
void libspdm_init_send_event_encap_state(void *spdm_context, uint32_t session_id)
{
    libspdm_context_t *context = spdm_context;

    /* Guard: only initiate encap if integrator confirms an active subscription. */
    if (!libspdm_is_event_subscribed(spdm_context, session_id)) {
        return;
    }

    /* ... existing setup ... */
    context->response_state = LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP;
    ...
}
```

Alternatively, expose `subscription_state` in `libspdm_session_info_t` and check it
directly. Add a unit test that calls `libspdm_init_send_event_encap_state()` on a
session with `SUBSCRIBE_NONE` and asserts `response_state` remains `NORMAL`.
